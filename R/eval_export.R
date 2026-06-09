# Build the (tournament, year) eval table consumed by the Python diagnostic harness.
# Output contract: output/eval/predictions_<tournament>_<year>.parquet
#
# Run pattern:
#   op run --env-file=.env.template -- Rscript R/eval_export.R memorial 2026
#
# Requires:
#   - output/eval/predictions_<tournament>_<year>_preview.rds  (from 07_pga_preview.R)
#   - data/cache/historical_raw/pga_<year>.rds                 (from 01_pull_historical.R)

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(purrr)
  library(readr)
  library(arrow)
  library(here)
})

source(here("R", "00_config.R"))
source(here("R", "datagolf_api.R"))

# ---- helpers ----------------------------------------------------------------

# Convert a tournament slug back to a grep-friendly pattern
# "memorial_tournament" -> "memorial tournament"
.slug_pattern <- function(slug) gsub("_", " ", slug)

# Find the matching event in a historical data list by slug
.find_event <- function(hist, tournament) {
  pat <- .slug_pattern(tournament)
  matches <- keep(hist, ~ grepl(pat, .x$event_name, ignore.case = TRUE))
  if (length(matches) == 0) {
    stop(
      "No event found matching slug '", tournament, "'. ",
      "Available events: ", paste(sapply(hist, `[[`, "event_name"), collapse = ", ")
    )
  }
  if (length(matches) > 1) {
    cli::cli_alert_warning(
      "Multiple events match '{tournament}'; using '{matches[[1]]$event_name}'"
    )
  }
  matches[[1]]
}

# ---- loaders ----------------------------------------------------------------

load_pretournament_predictions <- function(tournament, year) {
  snap_path <- file.path(
    here(), "output", "eval",
    sprintf("predictions_%s_%d_preview.rds", tournament, year)
  )
  if (!file.exists(snap_path)) {
    stop(
      "Preview snapshot not found: ", snap_path,
      "\nRun R/07_pga_preview.R for this event first."
    )
  }
  df <- readRDS(snap_path)

  required <- c("player_name", "win_prob", "top10_prob", "predicted_sg_total",
                "form_residual_mean_8")
  missing  <- setdiff(required, names(df))
  if (length(missing) > 0) {
    stop("Preview snapshot missing columns: ", paste(missing, collapse = ", "))
  }

  if (!"dg_id" %in% names(df)) {
    cli::cli_alert_warning("Snapshot missing dg_id — recovering from player_rounds_hist via name join")
    hist_rounds <- readRDS(file.path(PATH_DATA, "02_player_rounds.rds"))
    name_lookup <- hist_rounds |>
      distinct(dg_id, player_name) |>
      mutate(player_name = as.character(player_name))
    n_before <- nrow(df)
    df <- left_join(df, name_lookup, by = "player_name")
    n_matched <- sum(!is.na(df$dg_id))
    cli::cli_alert_info("Matched {n_matched}/{n_before} players by name")
    if (n_matched < n_before * 0.90) {
      stop("Name join matched only ", n_matched, "/", n_before,
           " players — snapshot player_name format may differ from historical data")
    }
  }

  df |>
    transmute(
      player_id       = as.integer(dg_id),
      player_name,
      pred_win_prob   = as.double(win_prob),
      pred_top10_prob = as.double(top10_prob),
      pred_score      = as.double(predicted_sg_total),
      is_in_form      = !is.na(form_residual_mean_8) & form_residual_mean_8 > 0
    )
}

load_actuals <- function(tournament, year) {
  hist <- dg_historical_raw(tour = "pga", year = year, force_refresh = TRUE)
  event <- .find_event(hist, tournament)

  scores    <- event$scores
  round_cols <- intersect(paste0("round_", 1:4), names(scores))
  player_cols <- setdiff(names(scores), paste0("round_", 1:4))

  player_info <- as_tibble(scores[, player_cols, drop = FALSE]) |>
    select(dg_id, fin_text) |>
    mutate(dg_id = as.integer(dg_id))

  # Per-round sg_total for actual_score (average SG per round played)
  round_sg <- map_dfc(seq_along(round_cols), function(i) {
    rd <- scores[[round_cols[[i]]]]
    sg <- if (is.data.frame(rd) && "sg_total" %in% names(rd)) rd$sg_total else NA_real_
    tibble(!!paste0("sg_r", i) := as.double(sg))
  })

  bind_cols(player_info, round_sg) |>
    mutate(
      actual_made_cut        = !fin_text %in% c("MC", "CUT", "WD", "DQ"),
      actual_score           = rowMeans(pick(starts_with("sg_r")), na.rm = TRUE),
      actual_score           = if_else(is.nan(actual_score), NA_real_, actual_score),
      actual_score           = if_else(actual_made_cut, actual_score, NA_real_),
      # Parse "T12" -> 12, "1" -> 1, "MC" -> NA
      actual_finish_position = suppressWarnings(
        as.integer(sub("^T", "", fin_text))
      ),
      actual_finish_position = if_else(actual_made_cut, actual_finish_position, NA_integer_)
    ) |>
    select(
      player_id = dg_id,
      actual_finish_position,
      actual_made_cut,
      actual_score
    )
}

# DG pre-tournament win probabilities from the snapshot saved by 07_pga_preview.R.
# Returns empty tibble (nullable in schema) if no snapshot exists for this event.
load_dg_baseline <- function(tournament, year) {
  snap_path <- file.path(
    here(), "output", "eval",
    sprintf("dg_predictions_%s_%d.rds", tournament, year)
  )
  if (!file.exists(snap_path)) {
    cli::cli_alert_warning("No DG predictions snapshot for {tournament} {year} — baseline will be NA")
    return(tibble(player_id = integer(0), pred_dg_win_prob = double(0)))
  }
  d <- readRDS(snap_path)
  baseline <- d[["baseline"]]
  if (!is.data.frame(baseline) || !"win" %in% names(baseline) || !"dg_id" %in% names(baseline)) {
    cli::cli_alert_warning("DG snapshot has unexpected structure — baseline will be NA")
    return(tibble(player_id = integer(0), pred_dg_win_prob = double(0)))
  }
  baseline |>
    transmute(
      player_id       = as.integer(dg_id),
      pred_dg_win_prob = as.double(win)
    )
}

load_owgr_baseline <- function(tournament, year) {
  tibble(player_id = integer(0), pred_owgr_win_prob = double(0))
}

# Normalize "Last, First" or "First Last" -> lowercase "first last" for joining
.normalize_player_name <- function(x) {
  x <- tolower(trimws(x))
  x <- ifelse(grepl(",", x), sub("^(.+),\\s*(.+)$", "\\2 \\1", x), x)
  gsub("[^a-z ]", "", x) |> trimws() |> gsub("\\s+", " ", x = _)
}

load_vegas_baseline <- function(tournament, year) {
  empty <- tibble(player_id = integer(0), pred_vegas_win_prob = double(0))

  odds_path <- file.path(
    here(), "output", "eval",
    sprintf("odds_%s_%d.rds", tournament, year)
  )
  if (!file.exists(odds_path)) {
    cli::cli_alert_warning("No odds snapshot for {tournament} {year} — vegas baseline will be NA")
    return(empty)
  }

  preview_path <- file.path(
    here(), "output",
    sprintf("%s_preview_%d.csv", tournament, year)
  )
  if (!file.exists(preview_path)) {
    cli::cli_alert_warning("No preview CSV for name->dg_id join — vegas baseline will be NA")
    return(empty)
  }

  odds    <- readRDS(odds_path)
  preview <- readr::read_csv(preview_path, show_col_types = FALSE) |>
    dplyr::select(dg_id, player_name) |>
    dplyr::mutate(player_name_norm = .normalize_player_name(player_name))

  joined <- preview |>
    dplyr::left_join(
      dplyr::select(odds, player_name_norm, implied_prob_fair),
      by = "player_name_norm"
    ) |>
    dplyr::filter(!is.na(implied_prob_fair))

  n_matched <- nrow(joined)
  n_total   <- nrow(preview)
  cli::cli_alert_info("Odds join: {n_matched}/{n_total} players matched by name")

  joined |>
    dplyr::transmute(
      player_id           = as.integer(dg_id),
      pred_vegas_win_prob = as.double(implied_prob_fair)
    )
}

get_course_metadata <- function(tournament, year) {
  taxonomy <- readr::read_csv(
    file.path(here(), "config", "course_taxonomy_weighted.csv"),
    col_types = readr::cols(course_num = readr::col_integer(), .default = readr::col_guess()),
    show_col_types = FALSE
  )

  hist  <- dg_historical_raw(tour = "pga", year = year, force_refresh = TRUE)
  event <- .find_event(hist, tournament)

  # course_num lives in the round data, not the event header
  scores    <- event$scores
  round_cols <- intersect(paste0("round_", 1:4), names(scores))
  course_num <- NA_integer_
  for (col in round_cols) {
    rd <- scores[[col]]
    if (is.data.frame(rd) && "course_num" %in% names(rd)) {
      course_num <- as.integer(rd$course_num[[1]])
      break
    }
  }

  if (is.na(course_num)) return(list(course_type = "other"))

  course_row <- filter(taxonomy, course_num == !!course_num)
  if (nrow(course_row) == 0) return(list(course_type = "other"))

  style <- course_row$course_style[[1]]
  allowed <- c("links", "parkland", "desert", "heathland", "coastal", "mountain", "other")
  list(course_type = if (!is.na(style) && style %in% allowed) style else "other")
}

# ---- player tier bucketing --------------------------------------------------

bucket_player_tier <- function(pred_win_prob) {
  case_when(
    pred_win_prob >= 0.03 ~ "favorite",
    pred_win_prob >= 0.01 ~ "mid",
    TRUE                  ~ "longshot"
  )
}

# ---- contract enforcement ---------------------------------------------------

ALLOWED_COURSE_TYPES <- c("links", "parkland", "desert", "heathland", "coastal", "mountain", "other")
ALLOWED_PLAYER_TIERS <- c("favorite", "mid", "longshot")

enforce_contract <- function(df, tournament, year) {
  required_non_nullable <- c(
    "player_id", "player_name", "tournament", "year",
    "pred_win_prob", "pred_top10_prob", "pred_score",
    "actual_made_cut", "actual_won", "actual_top10",
    "course_type", "player_tier", "is_in_form"
  )
  for (col in required_non_nullable) {
    if (!col %in% names(df)) stop("missing required column: ", col)
    if (any(is.na(df[[col]]))) stop("nulls in non-nullable column: ", col)
  }

  if (nrow(df) < 50 || nrow(df) > 250) {
    stop("field size ", nrow(df), " is outside expected range 50-250")
  }
  if (anyDuplicated(df$player_id)) stop("duplicate player_id")

  win_sum <- sum(df$pred_win_prob)
  if (win_sum < 0.90 || win_sum > 1.10) {
    stop(sprintf("pred_win_prob sums to %.3f, expected ~1.0", win_sum))
  }
  top10_sum <- sum(df$pred_top10_prob)
  if (top10_sum < 9.0 || top10_sum > 11.0) {
    stop(sprintf("pred_top10_prob sums to %.3f, expected ~10.0", top10_sum))
  }
  finish_coverage <- mean(!is.na(df$actual_finish_position))
  if (finish_coverage < 0.70) {
    stop(sprintf("only %.0f%% of field has actuals — likely a join bug or stale cache",
                 100 * finish_coverage))
  }
  if (!all(df$course_type %in% ALLOWED_COURSE_TYPES)) {
    stop("unknown course_type values: ",
         paste(setdiff(df$course_type, ALLOWED_COURSE_TYPES), collapse = ", "))
  }
  if (!all(df$player_tier %in% ALLOWED_PLAYER_TIERS)) {
    stop("unknown player_tier values")
  }
  invisible(df)
}

# ---- main -------------------------------------------------------------------

build_eval_table <- function(tournament, year) {
  cli::cli_h1("Building eval table: {tournament} {year}")

  cli::cli_alert_info("Loading pre-tournament predictions")
  preds <- load_pretournament_predictions(tournament, year)

  cli::cli_alert_info("Loading actuals")
  actuals <- load_actuals(tournament, year)

  cli::cli_alert_info("Loading baselines")
  dg    <- load_dg_baseline(tournament, year)
  owgr  <- load_owgr_baseline(tournament, year)
  vegas <- load_vegas_baseline(tournament, year)

  cli::cli_alert_info("Loading course metadata")
  course <- get_course_metadata(tournament, year)

  df <- preds |>
    left_join(actuals, by = "player_id") |>
    left_join(owgr,    by = "player_id") |>
    left_join(dg,      by = "player_id") |>
    left_join(vegas,   by = "player_id") |>
    mutate(
      tournament   = tournament,
      year         = as.integer(year),
      course_type  = course$course_type,
      player_tier  = bucket_player_tier(pred_win_prob),
      actual_won   = !is.na(actual_finish_position) & actual_finish_position == 1L,
      actual_top10 = !is.na(actual_finish_position) & actual_finish_position <= 10L,
      actual_made_cut = if_else(is.na(actual_made_cut), FALSE, actual_made_cut),
      player_id    = as.integer(player_id),
      actual_finish_position = as.integer(actual_finish_position)
    ) |>
    select(
      player_id, player_name, tournament, year,
      pred_win_prob, pred_top10_prob, pred_score,
      pred_owgr_win_prob, pred_dg_win_prob, pred_vegas_win_prob,
      actual_finish_position, actual_made_cut, actual_won, actual_top10, actual_score,
      course_type, player_tier, is_in_form
    )

  enforce_contract(df, tournament, year)
  cli::cli_alert_success("Contract passed: {nrow(df)} players, {sum(df$actual_made_cut)} made cut")

  out_dir  <- here("output", "eval")
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)
  out_path <- file.path(out_dir, sprintf("predictions_%s_%d.parquet", tournament, year))
  write_parquet(df, out_path)
  cli::cli_alert_success("Wrote {out_path}")
  invisible(df)
}

# ---- CLI --------------------------------------------------------------------

args <- commandArgs(trailingOnly = TRUE)
if (length(args) == 2) {
  build_eval_table(args[[1]], as.integer(args[[2]]))
} else if (length(args) != 0) {
  stop("Usage: Rscript R/eval_export.R <tournament_slug> <year>\n",
       "Example: Rscript R/eval_export.R memorial 2026")
}

# Build the (tournament, year) eval table consumed by the Python diagnostic harness.
# Output contract: output/eval/predictions_<tournament>_<year>.parquet
#
# Run pattern:
#   op run --env-file=.env.template -- Rscript R/eval_export.R us_open 2024
#
# The stub loaders below need to be wired up to the existing pipeline:
#   - load_pretournament_predictions: probably from output/<tournament>_<year>_preds.rds or the brms stack output
#   - load_owgr_baseline / load_dg_baseline / load_vegas_baseline: see R/datagolf_api.R for DG; OWGR + Vegas TBD
#   - load_actuals: DataGolf results endpoint
#   - get_course_metadata: config/course_taxonomy_weighted.csv

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(readr)
  library(arrow)
  library(here)
})

# ---- stub loaders (wire to real data sources) ----

load_pretournament_predictions <- function(tournament, year) {
  # Expected columns: player_id (int), player_name (chr),
  #                   pred_win_prob (dbl), pred_top10_prob (dbl), pred_score (dbl),
  #                   is_in_form (lgl)
  stop("TODO: wire load_pretournament_predictions for ", tournament, " ", year)
}

load_owgr_baseline <- function(tournament, year) {
  # Expected columns: player_id (int), pred_owgr_win_prob (dbl, nullable)
  stop("TODO: wire load_owgr_baseline for ", tournament, " ", year)
}

load_dg_baseline <- function(tournament, year) {
  # Expected columns: player_id (int), pred_dg_win_prob (dbl, nullable)
  stop("TODO: wire load_dg_baseline for ", tournament, " ", year)
}

load_vegas_baseline <- function(tournament, year) {
  # Expected columns: player_id (int), pred_vegas_win_prob (dbl, nullable)
  stop("TODO: wire load_vegas_baseline for ", tournament, " ", year)
}

load_actuals <- function(tournament, year) {
  # Expected columns: player_id (int),
  #                   actual_finish_position (int, nullable),
  #                   actual_made_cut (lgl),
  #                   actual_score (dbl, nullable)
  stop("TODO: wire load_actuals for ", tournament, " ", year)
}

get_course_metadata <- function(tournament, year) {
  # Expected: list with $course_type (chr scalar)
  stop("TODO: wire get_course_metadata for ", tournament, " ", year)
}

# ---- player tier bucketing ----

bucket_player_tier <- function(pred_win_prob) {
  case_when(
    pred_win_prob >= 0.03 ~ "favorite",
    pred_win_prob >= 0.01 ~ "mid",
    TRUE                  ~ "longshot"
  )
}

# ---- contract: column order, types, nullability ----

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

  if (nrow(df) < 100 || nrow(df) > 200) {
    stop("field size ", nrow(df), " is suspicious for a major")
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
    stop(sprintf("only %.0f%% of field has actuals — likely a join bug", 100 * finish_coverage))
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

# ---- main ----

build_eval_table <- function(tournament, year) {
  preds   <- load_pretournament_predictions(tournament, year)
  owgr    <- load_owgr_baseline(tournament, year)
  dg      <- load_dg_baseline(tournament, year)
  vegas   <- load_vegas_baseline(tournament, year)
  actuals <- load_actuals(tournament, year)
  course  <- get_course_metadata(tournament, year)

  df <- preds |>
    left_join(owgr,    by = "player_id") |>
    left_join(dg,      by = "player_id") |>
    left_join(vegas,   by = "player_id") |>
    left_join(actuals, by = "player_id") |>
    mutate(
      tournament   = tournament,
      year         = as.integer(year),
      course_type  = course$course_type,
      player_tier  = bucket_player_tier(pred_win_prob),
      actual_won   = !is.na(actual_finish_position) & actual_finish_position == 1L,
      actual_top10 = !is.na(actual_finish_position) & actual_finish_position <= 10L,
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

  out_dir <- here("output", "eval")
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)
  out_path <- file.path(out_dir, sprintf("predictions_%s_%d.parquet", tournament, year))
  write_parquet(df, out_path)
  message("wrote ", out_path, " (", nrow(df), " rows)")
  invisible(df)
}

# ---- CLI ----

args <- commandArgs(trailingOnly = TRUE)
if (length(args) == 2) {
  build_eval_table(args[[1]], as.integer(args[[2]]))
}

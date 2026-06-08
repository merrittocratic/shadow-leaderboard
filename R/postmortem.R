# R/postmortem.R — tournament-agnostic pre-tournament model postmortem
#
# Loads the pre-tournament preview snapshot for a completed event, fetches
# actual finishing positions from the DataGolf historical API, and prints a
# human-readable calibration summary + player-level CSV.
#
# Optionally compares an OLD vs NEW mid-tournament stack if per-tournament
# round-2 snapshots exist (see note on naming convention below).
#
# Run pattern:
#   op run --env-file=.env.template -- Rscript R/postmortem.R memorial 2026
#   op run --env-file=.env.template -- Rscript R/postmortem.R rbc_canadian_open 2026
#
# Requires:
#   output/eval/predictions_<tournament>_<year>_preview.rds   (07_pga_preview.R)
#
# Optional (old vs new stack comparison):
#   output/live_leaderboard_<tournament>_after_r2.rds
#   output/live_leaderboard_<tournament>_after_r2_OLDSTACK.rds
#   (08_live_leaderboard.R saves these as output/live_leaderboard_after_r2*.rds —
#    rename or copy with the tournament slug before the next event overwrites them.)

suppressPackageStartupMessages({
  library(dplyr)
  library(purrr)
  library(readr)
  library(here)
  library(cli)
})

source(here("R", "00_config.R"))
source(here("R", "datagolf_api.R"))

# ---- CLI args ---------------------------------------------------------------

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2) {
  cli_abort(c(
    "Usage: Rscript R/postmortem.R <tournament_slug> <year>",
    "i" = "Example: Rscript R/postmortem.R memorial 2026",
    "i" = "Slug should match the pattern used by 07_pga_preview.R"
  ))
}

TOURNAMENT <- args[[1]]
YEAR       <- as.integer(args[[2]])

cli_h1("Post-mortem: {TOURNAMENT} {YEAR}")

# ---- Helpers ----------------------------------------------------------------

brier <- function(p, y) mean((p - y)^2, na.rm = TRUE)

logloss <- function(p, y, eps = 1e-6) {
  p <- pmin(pmax(p, eps), 1 - eps)
  -mean(y * log(p) + (1 - y) * log(1 - p), na.rm = TRUE)
}

# Uniform-field baseline Brier (naive benchmark)
brier_uniform <- function(n_field, n_outcome) {
  brier(rep(n_outcome / n_field, n_field), c(rep(1, n_outcome), rep(0, n_field - n_outcome)))
}

slug_pattern <- function(slug) gsub("_", " ", slug, fixed = TRUE)

find_event <- function(hist, tournament) {
  pat     <- slug_pattern(tournament)
  matches <- keep(hist, ~ grepl(pat, .x$event_name, ignore.case = TRUE))
  if (length(matches) == 0) {
    cli_abort(c(
      "No event found matching slug '{tournament}'.",
      "i" = "Available: {paste(sapply(hist, `[[`, 'event_name'), collapse = ', ')}"
    ))
  }
  if (length(matches) > 1) {
    cli_alert_warning("Multiple matches; using '{matches[[1]]$event_name}'")
  }
  matches[[1]]
}

# ---- Load pre-tournament predictions ----------------------------------------

cli_h2("Loading pre-tournament predictions")

snap_path <- file.path(
  PATH_OUTPUT, "eval",
  sprintf("predictions_%s_%d_preview.rds", TOURNAMENT, YEAR)
)

if (!file.exists(snap_path)) {
  cli_abort(c(
    "Preview snapshot not found: {snap_path}",
    "i" = "Run R/07_pga_preview.R for this event first."
  ))
}

preds <- readRDS(snap_path)

# Normalise column names: rank column may or may not exist
if (!"rank" %in% names(preds)) {
  preds <- preds |> mutate(rank = row_number())
} else {
  preds <- preds |> arrange(rank)
}

required_cols <- c("player_name", "win_prob", "top5_prob", "top10_prob",
                   "predicted_sg_total")
missing_cols  <- setdiff(required_cols, names(preds))
if (length(missing_cols) > 0) {
  cli_abort("Preview snapshot missing columns: {paste(missing_cols, collapse=', ')}")
}

cli_alert_success("Loaded {nrow(preds)} pre-tournament predictions")

# ---- Pull actuals from DataGolf ---------------------------------------------

cli_h2("Pulling actuals from DataGolf historical API")

hist  <- dg_historical_raw(tour = "pga", year = YEAR, force_refresh = FALSE)
event <- find_event(hist, TOURNAMENT)

cli_alert_info("Matched event: '{event$event_name}' (completed {event$event_completed})")

scores     <- event$scores
round_cols <- intersect(paste0("round_", 1:4), names(scores))

player_base <- as_tibble(scores[, setdiff(names(scores), round_cols), drop = FALSE]) |>
  select(player_name, fin_text)

actuals <- player_base |>
  mutate(
    pos_num  = suppressWarnings(as.integer(sub("^T", "", fin_text))),
    made_cut = !fin_text %in% c("MC", "CUT", "WD", "DQ"),
    pos_num  = if_else(made_cut, pos_num, NA_integer_)
  )

n_made_cut <- sum(actuals$made_cut, na.rm = TRUE)
cli_alert_success("{nrow(actuals)} players in field, {n_made_cut} made cut")

# ---- Join predictions to actuals --------------------------------------------

joined <- preds |>
  left_join(actuals, by = "player_name") |>
  mutate(
    pos_num  = replace_na(as.integer(pos_num), 999L),
    made_cut = replace_na(made_cut, FALSE),
    fin_text = replace_na(fin_text, "N/A"),
    won      = pos_num == 1L,
    top5     = pos_num <= 5L,
    top10    = pos_num <= 10L
  )

n_matched    <- sum(joined$fin_text != "N/A")
n_actual     <- nrow(actuals)
pct_coverage <- n_matched / n_actual
cli_alert_info(
  "{n_matched}/{n_actual} actual field players found in model predictions ({round(pct_coverage*100)}%)"
)
if (pct_coverage < 0.60) {
  cli_alert_warning(
    "Coverage below 60% — preview may have been generated before the final field was confirmed."
  )
}

# ---- Winner -----------------------------------------------------------------

cli_h2("Winner(s)")

winners <- actuals |> filter(pos_num == 1L) |> pull(player_name)

for (w in winners) {
  w_row <- joined |> filter(player_name == w)
  if (nrow(w_row) == 0) {
    cli_alert_warning("{w}: winner not found in model field")
  } else {
    cli_alert_success(
      "{w} — Model rank: #{w_row$rank[1]} | Win {round(w_row$win_prob[1]*100,1)}% | Top-5 {round(w_row$top5_prob[1]*100,1)}% | Top-10 {round(w_row$top10_prob[1]*100,1)}%"
    )
  }
}

# ---- Actual top-10 table ----------------------------------------------------

cli_h2("Actual top-10 vs model predictions")

top10_names <- actuals |>
  filter(!is.na(pos_num), pos_num <= 10L) |>
  arrange(pos_num) |>
  pull(player_name)

# Catch T10 ties that push past 10 rows
tie_cutoff <- actuals |>
  filter(!is.na(pos_num)) |>
  slice_min(pos_num, n = 10, with_ties = TRUE) |>
  pull(player_name)

top10_names <- union(top10_names, tie_cutoff)

cat(sprintf("\n  %-32s %6s %8s %8s %9s\n",
            "Player", "Actual", "Model#", "Win%", "Top10%"))
cat("  ", strrep("-", 67), "\n", sep = "")

for (nm in top10_names) {
  row <- joined |> filter(player_name == nm)
  fin <- actuals  |> filter(player_name == nm) |> pull(fin_text)
  fin <- if (length(fin) == 0) "?" else fin[[1]]

  if (nrow(row) > 0) {
    cat(sprintf("  %-32s %6s %8d %7.1f%% %8.1f%%\n",
      nm, fin, row$rank[[1]],
      row$win_prob[[1]] * 100, row$top10_prob[[1]] * 100))
  } else {
    cat(sprintf("  %-32s %6s %8s %8s %9s\n", nm, fin, "N/A", "N/A", "N/A"))
  }
}

# ---- Model top-10 table -----------------------------------------------------

cli_h2("Model top-10 vs actual results")

cat(sprintf("\n  %-32s %8s %10s\n", "Player", "Model#", "Actual"))
cat("  ", strrep("-", 52), "\n", sep = "")

joined |>
  arrange(rank) |>
  head(10) |>
  rowwise() |>
  group_walk(~ {
    fin_display <- if (.x$pos_num == 999) "MC/WD" else .x$fin_text
    cat(sprintf("  %-32s %8d %10s\n",
                .x$player_name, .x$rank, fin_display))
  })

# ---- Calibration metrics ----------------------------------------------------

cli_h2("Calibration metrics (pre-tournament predictions)")

n <- nrow(joined)

metrics <- tibble(
  outcome       = c("win",   "top5",   "top10"),
  model_brier   = c(brier(joined$win_prob,   joined$won),
                    brier(joined$top5_prob,  joined$top5),
                    brier(joined$top10_prob, joined$top10)),
  model_logloss = c(logloss(joined$win_prob,   joined$won),
                    logloss(joined$top5_prob,  joined$top5),
                    logloss(joined$top10_prob, joined$top10)),
  uniform_brier = c(brier_uniform(n, sum(joined$won)),
                    brier_uniform(n, sum(joined$top5)),
                    brier_uniform(n, sum(joined$top10)))
) |>
  mutate(
    brier_skill_score = round(1 - model_brier / uniform_brier, 3),
    model_brier       = round(model_brier, 4),
    model_logloss     = round(model_logloss, 4),
    uniform_brier     = round(uniform_brier, 4)
  )

cat("\n")
print(metrics, n = Inf)

# ---- Mean probability on actual finishers -----------------------------------

cli_h2("Mean predicted probability assigned to actual finishers")

for (cfg in list(
  list(n = 1L,  col = "win_prob",   label = "winner"),
  list(n = 5L,  col = "top5_prob",  label = "top-5"),
  list(n = 10L, col = "top10_prob", label = "top-10")
)) {
  actual_set <- joined |> filter(pos_num <= cfg$n)
  if (nrow(actual_set) == 0) next

  mean_prob <- mean(actual_set[[cfg$col]], na.rm = TRUE)
  mean_rank <- mean(actual_set$rank,       na.rm = TRUE)

  cli_alert_info(
    "{cfg$label} (n={nrow(actual_set)}): mean {cfg$col} = {round(mean_prob*100,1)}%, mean model rank = {round(mean_rank,1)}"
  )
}

# ---- Optional: old vs new stack comparison ----------------------------------
# Looks for per-tournament named snapshots. Falls back to the generic names
# for backward compatibility with the Memorial 2026 run.

cli_h2("Old vs New stack comparison (optional)")

r2_new_paths <- c(
  file.path(PATH_OUTPUT, sprintf("live_leaderboard_%s_after_r2.rds", TOURNAMENT)),
  file.path(PATH_OUTPUT, "live_leaderboard_after_r2.rds")        # legacy fallback
)
r2_old_paths <- c(
  file.path(PATH_OUTPUT, sprintf("live_leaderboard_%s_after_r2_OLDSTACK.rds", TOURNAMENT)),
  file.path(PATH_OUTPUT, "live_leaderboard_after_r2_OLDSTACK.rds")
)

r2_new <- Find(file.exists, r2_new_paths)
r2_old <- Find(file.exists, r2_old_paths)

if (is.null(r2_new) || is.null(r2_old)) {
  cli_alert_info(
    "Skipping stack comparison — per-round R2 snapshots not found. Save output/live_leaderboard_{TOURNAMENT}_after_r2[_OLDSTACK].rds before the next event overwrites the generic names."
  )
} else {
  old_pred <- readRDS(r2_old) |>
    select(player_name,
           win_prob_old   = win_prob,
           top5_prob_old  = top5_prob,
           top10_prob_old = top10_prob)

  new_pred <- readRDS(r2_new) |>
    select(player_name,
           win_prob_new   = win_prob,
           top5_prob_new  = top5_prob,
           top10_prob_new = top10_prob)

  outcomes <- joined |>
    select(player_name, won, top5, top10)

  stk <- old_pred |>
    inner_join(new_pred, by = "player_name") |>
    left_join(outcomes,  by = "player_name") |>
    mutate(across(c(won, top5, top10), ~ replace_na(.x, FALSE)))

  cli_alert_info("Stack comparison: {nrow(stk)} players")

  stack_metrics <- tibble(
    outcome      = c("win", "top5", "top10"),
    old_brier    = c(brier(stk$win_prob_old,   stk$won),
                     brier(stk$top5_prob_old,  stk$top5),
                     brier(stk$top10_prob_old, stk$top10)),
    new_brier    = c(brier(stk$win_prob_new,   stk$won),
                     brier(stk$top5_prob_new,  stk$top5),
                     brier(stk$top10_prob_new, stk$top10)),
    old_logloss  = c(logloss(stk$win_prob_old,   stk$won),
                     logloss(stk$top5_prob_old,  stk$top5),
                     logloss(stk$top10_prob_old, stk$top10)),
    new_logloss  = c(logloss(stk$win_prob_new,   stk$won),
                     logloss(stk$top5_prob_new,  stk$top5),
                     logloss(stk$top10_prob_new, stk$top10))
  ) |>
    mutate(
      across(where(is.numeric), ~ round(.x, 4)),
      brier_diff   = round(old_brier   - new_brier,   4),   # positive = NEW better
      logloss_diff = round(old_logloss - new_logloss, 4)
    )

  cat("\n  (positive diff = new stack better)\n\n")
  print(stack_metrics, n = Inf)

  # Winner probability in each stack
  winner_rows <- stk |> filter(won)
  if (nrow(winner_rows) > 0) {
    cat("\n  Winner probabilities:\n")
    for (i in seq_len(nrow(winner_rows))) {
      w <- winner_rows[i, ]
      cat(sprintf("  %s  old=%.1f%%  new=%.1f%%  delta=%+.1f%%\n",
        w$player_name,
        w$win_prob_old * 100,
        w$win_prob_new * 100,
        (w$win_prob_new - w$win_prob_old) * 100))
    }
  }
}

# ---- Save player-level CSV --------------------------------------------------

out_dir  <- file.path(PATH_OUTPUT, "eval")
if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

out_path <- file.path(out_dir,
  sprintf("postmortem_%s_%d.csv", TOURNAMENT, YEAR))

joined |>
  arrange(pos_num) |>
  select(
    pos_num, player_name, fin_text,
    model_rank  = rank,
    win_prob, top5_prob, top10_prob,
    made_cut, won, top5, top10
  ) |>
  write_csv(out_path)

cli_alert_success("Saved: {out_path}")

cli_h1("Done — {TOURNAMENT} {YEAR}")

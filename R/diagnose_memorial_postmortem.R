source("R/00_config.R")
source("R/datagolf_api.R")

# Post-Memorial diagnostic: compare OLD vs NEW stack win / top5 / top10
# probabilities against actual final positions.
#
# Run after R4 completes and DataGolf shows final positions in
# the live tournament stats event_cumulative response.
#
#   op run --env-file=.env.template -- Rscript R/diagnose_memorial_postmortem.R

cli_h1("Memorial 2026 post-mortem -- OLD vs NEW stack calibration")

# ---- Load both R2-state predictions ----------------------------------------
# Both files are "predicted from after R2 to end of tournament", so their
# win_prob / top5_prob / top10_prob are directly comparable on the same
# event-level outcome.

old_file <- file.path(PATH_OUTPUT, "live_leaderboard_after_r2_OLDSTACK.rds")
new_file <- file.path(PATH_OUTPUT, "live_leaderboard_after_r2.rds")

if (!file.exists(old_file)) cli_abort("Missing {old_file}.")
if (!file.exists(new_file)) cli_abort("Missing {new_file}.")

old_pred <- readRDS(old_file) |>
  select(player_name,
         win_prob_old   = win_prob,
         top5_prob_old  = top5_prob,
         top10_prob_old = top10_prob)

new_pred <- readRDS(new_file) |>
  select(player_name,
         win_prob_new   = win_prob,
         top5_prob_new  = top5_prob,
         top10_prob_new = top10_prob)

cli_alert_info("OLD: {nrow(old_pred)} players | NEW: {nrow(new_pred)} players")

# ---- Pull final cumulative positions ---------------------------------------

cli_h2("Pulling final cumulative tournament stats")

final_raw <- dg_live_tournament_stats(round = "event_cumulative", force_refresh = TRUE)
final_players <- final_raw[["live_stats"]] %||% final_raw[["rankings"]] %||%
                 final_raw[["data"]] %||% final_raw[[1]]
if (!is.data.frame(final_players)) cli_abort("Unexpected live stats response.")

final_df <- as_tibble(final_players) |>
  select(any_of(c("dg_id", "player_name", "position"))) |>
  mutate(
    dg_id   = as.integer(dg_id),
    pos_num = suppressWarnings(as.integer(stringr::str_remove(position, "^T")))
  ) |>
  filter(!is.na(pos_num))

cli_alert_info("{nrow(final_df)} players with parseable final positions")

# ---- Outcome flags ---------------------------------------------------------
# pos_num <= N treats ties as expanding the count (T5 with 3 players → 3
# players counted as "top 5"). That matches how Brier/logloss should treat
# tied finishes — the underlying event "finished top-N" is what we predicted.

outcomes <- final_df |>
  mutate(
    won_tournament = pos_num == 1L,
    top5           = pos_num <= 5L,
    top10          = pos_num <= 10L
  ) |>
  select(player_name, pos_num, won_tournament, top5, top10)

cli_alert_info(
  "Actual: {sum(outcomes$won_tournament)} winner(s), ",
  "{sum(outcomes$top5)} in top-5, {sum(outcomes$top10)} in top-10 ",
  "(ties expand counts)"
)

# ---- Join predictions to outcomes ------------------------------------------

joined <- old_pred |>
  inner_join(new_pred, by = "player_name") |>
  left_join(outcomes,  by = "player_name") |>
  mutate(across(c(won_tournament, top5, top10), ~ replace_na(.x, FALSE)))

cli_alert_info("Joined: {nrow(joined)} players")

# ---- Metric helpers --------------------------------------------------------

brier <- function(p, y) mean((p - y)^2, na.rm = TRUE)

logloss <- function(p, y, eps = 1e-6) {
  p <- pmin(pmax(p, eps), 1 - eps)
  -mean(y * log(p) + (1 - y) * log(1 - p), na.rm = TRUE)
}

# ---- Calibration metrics ---------------------------------------------------

metrics <- tibble::tribble(
  ~outcome, ~old_brier,                                       ~new_brier,                                       ~old_logloss,                                       ~new_logloss,
  "win",    brier(joined$win_prob_old,   joined$won_tournament), brier(joined$win_prob_new,   joined$won_tournament), logloss(joined$win_prob_old,   joined$won_tournament), logloss(joined$win_prob_new,   joined$won_tournament),
  "top5",   brier(joined$top5_prob_old,  joined$top5),           brier(joined$top5_prob_new,  joined$top5),           logloss(joined$top5_prob_old,  joined$top5),           logloss(joined$top5_prob_new,  joined$top5),
  "top10",  brier(joined$top10_prob_old, joined$top10),          brier(joined$top10_prob_new, joined$top10),          logloss(joined$top10_prob_old, joined$top10),          logloss(joined$top10_prob_new, joined$top10)
) |>
  mutate(
    across(where(is.numeric), ~ round(.x, 4)),
    brier_diff   = old_brier   - new_brier,
    logloss_diff = old_logloss - new_logloss
  )

cli_h2("Calibration metrics")
cli_alert_info(
  "Lower brier / logloss = better. Positive diff = NEW stack better calibrated."
)
print(metrics)

# ---- Probability mass on actual outcomes -----------------------------------

cli_h2("Probability assigned to actual winner(s)")

winners <- joined |>
  filter(won_tournament) |>
  select(player_name, win_prob_old, win_prob_new) |>
  mutate(
    delta             = round(win_prob_new - win_prob_old, 3),
    rank_old_among_53 = rank(-joined$win_prob_old, ties.method = "min")[match(player_name, joined$player_name)],
    rank_new_among_53 = rank(-joined$win_prob_new, ties.method = "min")[match(player_name, joined$player_name)]
  )
print(winners)

cli_h2("Mean top-5 probability assigned to actual top-5 finishers")
top5_means <- joined |>
  filter(top5) |>
  summarise(
    old = round(mean(top5_prob_old), 3),
    new = round(mean(top5_prob_new), 3),
    n   = n()
  )
print(top5_means)

cli_h2("Mean top-10 probability assigned to actual top-10 finishers")
top10_means <- joined |>
  filter(top10) |>
  summarise(
    old = round(mean(top10_prob_old), 3),
    new = round(mean(top10_prob_new), 3),
    n   = n()
  )
print(top10_means)

# ---- Save player-level table -----------------------------------------------

out_csv <- file.path(PATH_OUTPUT, "memorial_2026_postmortem.csv")
write_csv(
  joined |>
    arrange(pos_num) |>
    select(pos_num, player_name,
           won_tournament, top5, top10,
           win_prob_old, win_prob_new,
           top5_prob_old, top5_prob_new,
           top10_prob_old, top10_prob_new),
  out_csv
)
cli_alert_success("Saved player-level table to {out_csv}")

cli_h1("Done")
cli_alert_info(
  "Caveats: n=~53 post-cut field. Brier diffs < 0.001 are noise; ",
  "the 'probability to actual winner' table is the most intuitive single comparison."
)

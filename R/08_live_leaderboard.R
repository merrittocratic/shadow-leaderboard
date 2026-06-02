source("R/00_config.R")
source("R/datagolf_api.R")
source("R/03_model_spec.R")

# Live end-of-round leaderboard for the current PGA Tour event.
# Re-scores the remaining field for the NEXT round using actual SG from
# completed rounds as in-tournament features.
#
# Run after each round completes:
#   op run --env-file=.env.template -- Rscript R/08_live_leaderboard.R [completed_round]
#
# completed_round: integer 1–3 (which round just finished).
#   Default: auto-detected from live data.

library(slider)

cli_h1("Shadow Leaderboard -- live end-of-round update")

# ---- Parse args / detect completed round ----------------------------------

args            <- commandArgs(trailingOnly = TRUE)
completed_round <- if (length(args) >= 1L) as.integer(args[[1L]]) else NA_integer_

# ---- Load trained model ---------------------------------------------------

best_model_name <- readLines(file.path(PATH_OUTPUT, "models", "best_model.txt"))
model_file      <- file.path(PATH_OUTPUT, "models", paste0(best_model_name, "_tuned.rds"))

if (!file.exists(model_file)) {
  cli_abort("Tuned model not found at {model_file}. Run 05_tune.R first.")
}
tuned_model <- readRDS(model_file)
cli_alert_success("Loaded tuned {toupper(best_model_name)} model")

# ---- Pull live tournament stats -------------------------------------------
# We always force_refresh here — this is a live scoring run.

cli_h2("Pulling live tournament stats")

# Pull each completed round individually so we get per-round SG (not cumulative).
# Auto-detect completed_round if not supplied: pull r1, r2, r3 and see which
# return non-empty player data.

detect_completed_round <- function() {
  for (r in 3:1) {
    tryCatch({
      d <- dg_live_tournament_stats(round = r, force_refresh = TRUE)
      players <- d[["live_stats"]] %||% d[["rankings"]] %||% d[["data"]] %||% d[[1]]
      if (is.data.frame(players) && nrow(players) > 0) return(r)
    }, error = function(e) NULL)
  }
  cli_abort("Could not detect completed round from live data. Pass it explicitly.")
}

if (is.na(completed_round)) {
  completed_round <- detect_completed_round()
  cli_alert_info("Auto-detected completed round: {completed_round}")
} else {
  cli_alert_info("Completed round (from args): {completed_round}")
}

next_round <- completed_round + 1L

if (next_round > 4L) {
  cli_abort("completed_round = {completed_round}; no round {next_round} to predict.")
}

cli_alert_info("Scoring field for Round {next_round}")

# Pull each completed round's SG
pull_round_sg <- function(r) {
  raw     <- dg_live_tournament_stats(
    stats         = "sg_putt,sg_arg,sg_app,sg_ott,sg_total",
    round         = r,
    force_refresh = TRUE
  )
  players <- raw[["live_stats"]] %||% raw[["rankings"]] %||% raw[["data"]] %||% raw[[1]]
  if (!is.data.frame(players)) {
    cli_abort("Unexpected response structure from live-tournament-stats (round {r}).")
  }
  as_tibble(players) |>
    select(dg_id, sg_total) |>
    mutate(dg_id = as.integer(dg_id)) |>
    rename(!!paste0("sg_r", r) := sg_total)
}

if (completed_round == 0L) {
  live_sg <- tibble(dg_id = integer())
} else {
  round_sg_list <- purrr::map(seq_len(completed_round), pull_round_sg)
  live_sg <- purrr::reduce(round_sg_list, full_join, by = "dg_id")
}

cli_alert_success(
  "Live SG pulled for rounds 1–{completed_round}: {nrow(live_sg)} players"
)

# ---- Get current field ----------------------------------------------------

cli_h2("Fetching current field")

field_raw     <- dg_field_tee_times(tour = "pga", force_refresh = TRUE)
field_players <- as_tibble(field_raw$field) |>
  select(dg_id, player_name) |>
  mutate(dg_id = as.integer(dg_id))

cli_alert_info("{nrow(field_players)} players in field")

# For rounds 3–4, filter to players who made the cut.
# DataGolf does not return an explicit "MC" flag — positions are numeric strings
# ("T83", "T96", etc.) for all players including those who missed. Filter to
# position ≤ 70 using the cached R2 data (no extra API call).
if (completed_round >= 2L) {
  r2_raw     <- dg_live_tournament_stats(round = 2L, force_refresh = FALSE)
  r2_players <- r2_raw[["live_stats"]] %||% r2_raw[["rankings"]] %||%
                r2_raw[["data"]] %||% r2_raw[[1]]
  made_cut <- as_tibble(r2_players) |>
    mutate(dg_id   = as.integer(dg_id),
           pos_num = as.integer(stringr::str_remove(position, "^T"))) |>
    filter(!is.na(pos_num), pos_num <= 70L) |>
    pull(dg_id)
  field_players <- field_players |> filter(dg_id %in% made_cut)
  cli_alert_info(
    "{nrow(field_players)} players remain after cut filter (position ≤ 70)"
  )
}

# ---- Build pre-tournament features ----------------------------------------
# Mirrors 07_pga_preview.R: pull fresh 2026 YTD data, stack with historical,
# recompute form features so this week's results (e.g. Truist) flow through.

cli_h2("Building pre-tournament features (including 2026 YTD)")

player_rounds_hist <- readRDS(file.path(PATH_DATA, "02_player_rounds.rds"))

skill_priors_latest <- player_rounds_hist |>
  group_by(dg_id) |>
  filter(year == max(year)) |>
  summarise(
    player_skill_prior       = first(na.omit(player_skill_prior)),
    player_skill_prior_decay = first(na.omit(player_skill_prior_decay)),
    n_prior_rounds           = first(na.omit(n_prior_rounds)),
    sg_ott_prior             = first(na.omit(sg_ott_prior)),
    sg_app_prior             = first(na.omit(sg_app_prior)),
    sg_arg_prior             = first(na.omit(sg_arg_prior)),
    sg_putt_prior            = first(na.omit(sg_putt_prior)),
    .groups = "drop"
  )

# Pull current-year data fresh — force_refresh captures this week's results
current_year <- as.integer(format(Sys.Date(), "%Y"))
cli_alert_info("Pulling {current_year} YTD data (force_refresh = TRUE)...")
data_ytd <- tryCatch(
  dg_historical_raw(tour = "pga", year = current_year, force_refresh = TRUE),
  error = function(e) {
    cli_alert_warning("Could not pull {current_year} YTD data: {conditionMessage(e)}")
    list()
  }
)
cli_alert_success("{length(data_ytd)} events retrieved for {current_year}")

flatten_event_simple <- function(event) {
  scores     <- event$scores
  round_cols <- intersect(paste0("round_", 1:4), names(scores))
  player_info <- as_tibble(scores[, setdiff(names(scores), round_cols), drop = FALSE])
  purrr::map_dfr(seq_along(round_cols), function(i) {
    rd <- scores[[round_cols[[i]]]]
    if (!is.data.frame(rd)) return(NULL)
    bind_cols(player_info, as_tibble(rd),
              tibble(round_num = i, year = event$year,
                     event_id = event$event_id, event_name = event$event_name,
                     event_completed = as.Date(event$event_completed))) |>
      filter(!is.na(sg_total))
  })
}

rounds_ytd <- if (length(data_ytd) > 0) {
  purrr::map_dfr(data_ytd, flatten_event_simple) |>
    left_join(skill_priors_latest, by = "dg_id") |>
    mutate(field_mean_sg = NA_real_, sg_residual = NA_real_)
} else {
  tibble()
}

# Stack historical + YTD for form computation
all_rounds <- bind_rows(
  select(player_rounds_hist, dg_id, event_id, year, event_completed,
         sg_total, player_skill_prior),
  if (nrow(rounds_ytd) > 0)
    select(rounds_ytd, dg_id, event_id, year, event_completed,
           sg_total, player_skill_prior)
)

# Recompute form features through the most recent completed event
.slope <- function(x) {
  x <- x[!is.na(x)]; n <- length(x)
  if (n < 2L) return(NA_real_)
  t <- seq_len(n); sum((t - mean(t)) * (x - mean(x))) / sum((t - mean(t))^2)
}

event_sg_all <- all_rounds |>
  group_by(dg_id, event_id, year, event_completed) |>
  summarise(event_sg_mean = mean(sg_total, na.rm = TRUE),
            player_skill_prior = first(na.omit(player_skill_prior)),
            .groups = "drop") |>
  mutate(event_residual = event_sg_mean - player_skill_prior) |>
  arrange(dg_id, event_completed)

form_latest <- event_sg_all |>
  filter(dg_id %in% field_players$dg_id) |>
  group_by(dg_id) |>
  summarise(
    form_residual_mean_8  = { x <- tail(event_residual[!is.na(event_residual)], 8);  if (!length(x)) NA_real_ else mean(x) },
    form_residual_slope_8 = { x <- tail(event_residual[!is.na(event_residual)], 8);  .slope(x) },
    form_residual_mean_4  = { x <- tail(event_residual[!is.na(event_residual)], 4);  if (!length(x)) NA_real_ else mean(x) },
    form_residual_slope_4 = { x <- tail(event_residual[!is.na(event_residual)], 4);  .slope(x) },
    form_residual_mean_12 = { x <- tail(event_residual[!is.na(event_residual)], 12); if (!length(x)) NA_real_ else mean(x) },
    form_residual_slope_12= { x <- tail(event_residual[!is.na(event_residual)], 12); .slope(x) },
    form_residual_mean_16 = { x <- tail(event_residual[!is.na(event_residual)], 16); if (!length(x)) NA_real_ else mean(x) },
    form_residual_slope_16= { x <- tail(event_residual[!is.na(event_residual)], 16); .slope(x) },
    n_events_available    = sum(!is.na(event_residual)),
    .groups = "drop"
  )

# ---- Course-fit score -------------------------------------------------------
# Detect tournament course_num from the live R1 stats data.

r1_raw     <- dg_live_tournament_stats(round = 1L, force_refresh = FALSE)
r1_players <- r1_raw[["live_stats"]] %||% r1_raw[["rankings"]] %||%
              r1_raw[["data"]] %||% r1_raw[[1]]
live_course_num <- if (is.data.frame(r1_players) && "course_num" %in% names(r1_players)) {
  as.integer(r1_players$course_num[1])
} else NA_integer_

course_weights_df <- readr::read_csv(
  file.path(here::here(), "config", "course_taxonomy_weighted.csv"),
  col_types = readr::cols(course_num = readr::col_integer(), .default = readr::col_guess()),
  show_col_types = FALSE
) |>
  filter(course_num == live_course_num) |>
  select(weight_ott, weight_app, weight_arg, weight_putt)

if (nrow(course_weights_df) == 0) {
  cli_alert_warning("course_num {live_course_num} not in taxonomy — course_fit_score will be imputed")
  course_weights_df <- tibble(
    weight_ott = NA_real_, weight_app = NA_real_,
    weight_arg = NA_real_, weight_putt = NA_real_
  )
} else {
  cli_alert_info(
    "Course weights (course_num {live_course_num}): ",
    "OTT={round(course_weights_df$weight_ott,3)} ",
    "APP={round(course_weights_df$weight_app,3)} ",
    "ARG={round(course_weights_df$weight_arg,3)} ",
    "PUTT={round(course_weights_df$weight_putt,3)}"
  )
}

# ---- Assemble scoring frame -----------------------------------------------

score_frame <- field_players |>
  left_join(skill_priors_latest, by = "dg_id") |>
  left_join(form_latest,         by = "dg_id") |>
  left_join(live_sg,             by = "dg_id") |>
  mutate(
    wave      = factor("AM"),
    round_num = next_round,
    is_major  = TRUE,
    course_id = factor(paste0("live_", format(Sys.Date(), "%Y"))),
    year      = as.integer(format(Sys.Date(), "%Y")),
    player_id = factor(dg_id),
    course_fit_score =
      course_weights_df$weight_ott  * sg_ott_prior  +
      course_weights_df$weight_app  * sg_app_prior  +
      course_weights_df$weight_arg  * sg_arg_prior  +
      course_weights_df$weight_putt * sg_putt_prior
  ) |>
  mutate(across(
    c(player_skill_prior, player_skill_prior_decay,
      n_prior_rounds, course_fit_score,
      sg_ott_prior, sg_app_prior,
      sg_arg_prior, sg_putt_prior,
      starts_with("form_residual"),
      starts_with("sg_r")),
    ~ replace_na(.x, mean(.x, na.rm = TRUE))
  ))

# Ensure sg_r columns exist even if only r1 was played
for (col in c("sg_r1", "sg_r2", "sg_r3")) {
  if (!col %in% names(score_frame)) score_frame[[col]] <- NA_real_
}

# ---- Score ----------------------------------------------------------------

cli_h2("Scoring field for Round {next_round}")

score_frame$.pred <- predict(tuned_model, score_frame)$.pred

# ---- Build ranked table ---------------------------------------------------

ranked_table <- score_frame |>
  mutate(predicted_sg_total = .pred + player_skill_prior) |>
  arrange(desc(predicted_sg_total)) |>
  mutate(rank = row_number()) |>
  select(
    rank,
    player_name,
    predicted_sg_total,
    predicted_sg_residual = .pred,
    player_skill_prior,
    any_of(c("sg_r1", "sg_r2", "sg_r3")),
    form_residual_mean_8,
    n_events_available
  ) |>
  mutate(across(where(is.double), ~ round(.x, 3)))

# ---- Win probabilities via stacked brms posterior ----------------------------

stack_model_file <- file.path(PATH_OUTPUT, "models", "brms_stack.rds")

if (file.exists(stack_model_file)) {
  cli_h2("Computing win / top-5 / top-10 probabilities (posterior simulation)")

  brms_stack <- readRDS(stack_model_file)

  # Actual cumulative SG from rounds already played
  actual_total_sg <- if (completed_round > 0L) {
    score_frame |>
      select(all_of(paste0("sg_r", seq_len(completed_round)))) |>
      rowSums(na.rm = TRUE)
  } else {
    rep(0, nrow(score_frame))
  }

  score_frame_brms <- score_frame |>
    mutate(
      gbdt_pred     = .pred,
      player_season = factor(paste(dg_id, year))
    )

  N_DRAWS          <- 2000L
  remaining_rounds <- 4L - completed_round

  # Simulate remaining rounds, then anchor to actual completed-round SG
  future_sg <- if (remaining_rounds > 0L) {
    Reduce("+", lapply(seq_len(remaining_rounds), function(r) {
      posterior_predict(
        brms_stack,
        newdata          = score_frame_brms,
        ndraws           = N_DRAWS,
        allow_new_levels = TRUE
      )
    }))
  } else {
    matrix(0, nrow = N_DRAWS, ncol = nrow(score_frame_brms))
  }

  tournament_totals <- sweep(future_sg, 2, actual_total_sg, "+")

  ranks_mat  <- t(apply(tournament_totals, 1, function(row) rank(-row, ties.method = "random")))
  win_prob   <- colMeans(ranks_mat == 1L)
  top5_prob  <- colMeans(ranks_mat <= 5L)
  top10_prob <- colMeans(ranks_mat <= 10L)

  ranked_table <- ranked_table |>
    left_join(
      tibble(
        player_name = score_frame_brms$player_name,
        win_prob    = round(win_prob,   3),
        top5_prob   = round(top5_prob,  3),
        top10_prob  = round(top10_prob, 3)
      ),
      by = "player_name"
    )

  cli_alert_success(
    "Win probabilities computed ({N_DRAWS} simulations, {remaining_rounds} rounds remaining)"
  )
} else {
  cli_alert_warning(
    "brms_stack.rds not found — skipping win probabilities. Run 06b_brms_stack.R to enable."
  )
}

# ---- Save and print ----------------------------------------------------------

out_stem <- file.path(PATH_OUTPUT, paste0("live_leaderboard_after_r", completed_round))
out_csv  <- paste0(out_stem, ".csv")
out_rds  <- paste0(out_stem, ".rds")

write_csv(ranked_table, out_csv)
saveRDS(ranked_table, out_rds)
cli_alert_success("Saved: {out_csv}")
cli_alert_success("Saved: {out_rds}")

cli_h2(
  "Shadow Leaderboard — Round {next_round} projections ",
  "(after Round {completed_round} | model: {toupper(best_model_name)})"
)
print(slice(ranked_table, 1:20), n = 20)

cli_alert_info(
  "Re-run after Round {next_round} completes: ",
  "Rscript R/08_live_leaderboard.R {next_round}"
)

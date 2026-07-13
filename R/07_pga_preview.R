source("R/00_config.R")
source("R/datagolf_api.R")
source("R/odds_api.R")
source("R/03_model_spec.R")
source("R/weather_forecast.R")

# PGA Championship 2026 pre-tournament ranked table.
# Requires 05_tune.R to have completed first.
#
# Pulls 2026 YTD data, recomputes form features through the most recent
# event before the championship, scores the field with the best tuned model,
# and outputs a ranked table to output/pga_preview_2026.csv.
#
#   op run --env-file=.env.template -- Rscript R/07_pga_preview.R

library(slider)
library(gt)

source("tests/test_form_features.R")

cli_h1("PGA Championship 2026 -- pre-tournament ranked table")

# ---- Load trained model ---------------------------------------------------

best_model_name <- readLines(file.path(PATH_OUTPUT, "models", "best_model.txt"))
model_file      <- file.path(PATH_OUTPUT, "models", paste0(best_model_name, "_tuned.rds"))

if (!file.exists(model_file)) {
  cli_abort("Tuned model not found at {model_file}. Run 05_tune.R first.")
}

tuned_model <- readRDS(model_file)
cli_alert_success("Loaded tuned {toupper(best_model_name)} model")

# ---- Pull 2026 YTD data ---------------------------------------------------
# Extends the training data pull into the current season.

cli_h2("Pulling 2026 YTD data")

data_2026 <- tryCatch(
  dg_historical_raw(tour = "pga", year = 2026L),
  error = function(e) {
    cli_abort("Failed to pull 2026 data: {conditionMessage(e)}")
  }
)

cli_alert_success("2026 events retrieved: {length(data_2026)}")

# ---- Get PGA Championship field -------------------------------------------

cli_h2("Fetching PGA Championship field")

field_raw <- dg_field_tee_times(tour = "pga")

# DataGolf field endpoint returns the current/next event's players
# Confirm we have the right event
cli_alert_info(
  "Field event: {field_raw$event_name %||% 'unknown'} | ",
  "{length(field_raw$field)} players"
)

field_players <- as_tibble(field_raw$field) |>
  select(dg_id, player_name) |>
  mutate(dg_id = as.integer(dg_id))

cli_alert_info("{nrow(field_players)} players in field")

# ---- Build scoring dataset ------------------------------------------------
# Combine historical training data with 2026 YTD for form feature computation.
# Then score only the PGA Championship field players.

cli_h2("Building scoring dataset")

# Load historical player_rounds
player_rounds_hist <- readRDS(file.path(PATH_DATA, "02_player_rounds.rds"))

# Residual anchor travels as the player_anchor column (stamped by 02).
# Pre-anchor rds files lack it — fall back to the static prior (old behavior).
if (!"player_anchor" %in% names(player_rounds_hist)) {
  cli_alert_warning("player_anchor column missing (pre-anchor rds) -- using player_skill_prior")
  player_rounds_hist$player_anchor <- player_rounds_hist$player_skill_prior
}
cli_alert_info("Residual anchor: {attr(player_rounds_hist, 'skill_anchor') %||% 'static'}")

# Flatten 2026 YTD using the same logic as 02_feature_engineering.R
flatten_event_simple <- function(event) {
  scores    <- event$scores
  round_cols  <- intersect(paste0("round_", 1:4), names(scores))
  player_cols <- setdiff(names(scores), paste0("round_", 1:4))
  player_info <- as_tibble(scores[, player_cols, drop = FALSE])

  purrr::map_dfr(seq_along(round_cols), function(i) {
    col      <- round_cols[[i]]
    round_df <- scores[[col]]
    if (!is.data.frame(round_df)) return(NULL)
    bind_cols(
      player_info,
      as_tibble(round_df),
      tibble(
        round_num       = i,
        year            = event$year,
        event_id        = event$event_id,
        event_name      = event$event_name,
        event_completed = as.Date(event$event_completed)
      )
    ) |>
      filter(!is.na(sg_total))
  })
}

rounds_2026 <- purrr::map_dfr(data_2026, flatten_event_simple) |>
  mutate(
    wave      = case_when(
      str_detect(teetime, stringr::fixed("am")) ~ "AM",
      str_detect(teetime, stringr::fixed("pm")) ~ "PM",
      TRUE ~ NA_character_
    ) |> factor(),
    is_major  = event_name %in% c(
      "Masters Tournament", "U.S. Open",
      "The Open Championship", "PGA Championship"
    ),
    player_id = factor(dg_id),
    course_id = factor(course_num),
    round_num = as.integer(round_num)
  )

# Carry forward skill priors from the training set (2025 year-end values)
skill_priors_latest <- player_rounds_hist |>
  group_by(dg_id) |>
  filter(year == max(year)) |>
  summarise(
    player_skill_prior       = first(na.omit(player_skill_prior)),
    player_skill_prior_decay = first(na.omit(player_skill_prior_decay)),
    player_anchor            = first(na.omit(player_anchor)),
    n_prior_rounds           = first(na.omit(n_prior_rounds)),
    sg_ott_prior             = first(na.omit(sg_ott_prior)),
    sg_app_prior             = first(na.omit(sg_app_prior)),
    sg_arg_prior             = first(na.omit(sg_arg_prior)),
    sg_putt_prior            = first(na.omit(sg_putt_prior)),
    .groups = "drop"
  )

# Course-fit weights, weather pull, and eval-harness snapshot — all derived from field_raw
taxonomy_full <- readr::read_csv(
  file.path(here::here(), "config", "course_taxonomy_weighted.csv"),
  col_types = readr::cols(course_num = readr::col_integer(), .default = readr::col_guess()),
  show_col_types = FALSE
)

TOURNAMENT_START_DATE <- as.Date(field_raw$date_start)
TOURNAMENT_YEAR       <- as.integer(format(TOURNAMENT_START_DATE, "%Y"))
TOURNAMENT_SLUG       <- gsub("^_|_$", "", gsub("[^a-z0-9]+", "_", tolower(field_raw$event_name)))
TOURNAMENT_IS_MAJOR   <- field_raw$event_name %in% c(
  "Masters Tournament", "U.S. Open", "The Open Championship", "PGA Championship"
)

course_row <- taxonomy_full |> filter(venue_name == field_raw$course_name)
if (nrow(course_row) == 0) {
  TOURNAMENT_COURSE_NUM <- NA_integer_
} else {
  TOURNAMENT_COURSE_NUM <- course_row$course_num[[1]]
}

cli_alert_info("Derived slug: {TOURNAMENT_SLUG} | course_num: {TOURNAMENT_COURSE_NUM %||% 'NA (will impute)'}")

if (nrow(course_row) == 0) {
  cli_alert_warning(
    "Course '{field_raw$course_name}' not in taxonomy — course_fit_score and weather will be imputed"
  )
  course_weights_df <- tibble(
    weight_ott = NA_real_, weight_app = NA_real_,
    weight_arg = NA_real_, weight_putt = NA_real_
  )
  course_lat <- NA_real_
  course_lon <- NA_real_
} else {
  course_weights_df <- course_row |> select(weight_ott, weight_app, weight_arg, weight_putt)
  course_lat        <- course_row$lat[[1]]
  course_lon        <- course_row$lon[[1]]
}

# ---- Cache DG model predictions + Vegas implied odds ----------------------
# Day-keyed on the DataGolf side — must be captured now or the window is gone.
dg_preds_raw <- tryCatch(
  dg_model_predictions(tour = "pga", odds_format = "percent"),
  error = function(e) {
    cli_alert_warning("Could not fetch DG model predictions: {conditionMessage(e)}")
    NULL
  }
)
if (!is.null(dg_preds_raw)) {
  dg_snap_path <- file.path(
    PATH_OUTPUT, "eval",
    sprintf("dg_predictions_%s_%d.rds", TOURNAMENT_SLUG, TOURNAMENT_YEAR)
  )
  if (!dir.exists(dirname(dg_snap_path))) dir.create(dirname(dg_snap_path), recursive = TRUE)
  saveRDS(dg_preds_raw, dg_snap_path)
  cli_alert_success("DG predictions snapshot saved to {dg_snap_path}")
}

cli_alert_info(glue::glue(
  "Course weights (course_num {TOURNAMENT_COURSE_NUM}): ",
  "OTT={round(course_weights_df$weight_ott,3)} ",
  "APP={round(course_weights_df$weight_app,3)} ",
  "ARG={round(course_weights_df$weight_arg,3)} ",
  "PUTT={round(course_weights_df$weight_putt,3)}"
))

cli_h2("Pulling Round 1 weather forecast (lat={round(course_lat,3)}, lon={round(course_lon,3)}, date={TOURNAMENT_START_DATE})")
r1_weather <- pull_round_weather(course_lat, course_lon, TOURNAMENT_START_DATE)
cli_alert_info(glue::glue(
  "R1 forecast: wind {round(r1_weather$wind_speed_tee,1)} mph @ {round(r1_weather$wind_dir_tee,0)}°, ",
  "temp {round(r1_weather$temp_tee,1)}°F, precip {round(r1_weather$precip_tee,2)} in, ",
  "precision={r1_weather$weather_precision %||% 'NA'}"
))

rounds_2026 <- rounds_2026 |>
  left_join(skill_priors_latest, by = "dg_id") |>
  mutate(field_mean_sg = NA_real_, sg_residual = NA_real_)  # not needed for scoring

# Stack historical + 2026 for form feature computation
all_rounds <- bind_rows(
  select(player_rounds_hist, dg_id, event_id, year, event_completed,
         sg_total, sg_ott, sg_app, sg_arg, sg_putt,
         player_skill_prior, player_anchor, sg_ott_prior, sg_app_prior,
         sg_arg_prior, sg_putt_prior, player_skill_prior_decay, n_prior_rounds),
  select(rounds_2026, dg_id, event_id, year, event_completed,
         sg_total, sg_ott, sg_app, sg_arg, sg_putt,
         player_skill_prior, player_anchor, sg_ott_prior, sg_app_prior,
         sg_arg_prior, sg_putt_prior, player_skill_prior_decay, n_prior_rounds)
)

# ---- Recompute form features through most recent 2026 event ---------------

cli_h2("Computing form features for PGA field (2026 YTD included)")

.slope <- function(x) {
  x <- x[!is.na(x)]
  n <- length(x)
  if (n < 2L) return(NA_real_)
  t <- seq_len(n); t_mean <- mean(t); x_mean <- mean(x)
  sum((t - t_mean) * (x - x_mean)) / sum((t - t_mean)^2)
}

event_sg_all <- all_rounds |>
  group_by(dg_id, event_id, year, event_completed) |>
  summarise(
    event_sg_mean      = mean(sg_total, na.rm = TRUE),
    event_ott_mean     = mean(sg_ott,   na.rm = TRUE),
    event_app_mean     = mean(sg_app,   na.rm = TRUE),
    event_arg_mean     = mean(sg_arg,   na.rm = TRUE),
    event_putt_mean    = mean(sg_putt,  na.rm = TRUE),
    player_anchor      = first(na.omit(player_anchor)),
    .groups            = "drop"
  ) |>
  mutate(event_residual = event_sg_mean - player_anchor) |>
  arrange(dg_id, event_completed)

# For each PGA field player, compute form features as of the most recent
# event they've played (which will be before the PGA Championship)
pga_form <- event_sg_all |>
  filter(dg_id %in% field_players$dg_id) |>
  group_by(dg_id) |>
  summarise(
    # Last N events before PGA Championship (use all available 2026 history)
    form_residual_mean_8  = {
      x <- tail(event_residual[!is.na(event_residual)], 8)
      if (length(x) == 0) NA_real_ else mean(x)
    },
    form_residual_slope_8 = {
      x <- tail(event_residual[!is.na(event_residual)], 8)
      .slope(x)
    },
    form_residual_mean_4  = {
      x <- tail(event_residual[!is.na(event_residual)], 4)
      if (length(x) == 0) NA_real_ else mean(x)
    },
    form_residual_slope_4 = {
      x <- tail(event_residual[!is.na(event_residual)], 4)
      .slope(x)
    },
    form_residual_mean_12 = {
      x <- tail(event_residual[!is.na(event_residual)], 12)
      if (length(x) == 0) NA_real_ else mean(x)
    },
    form_residual_slope_12 = {
      x <- tail(event_residual[!is.na(event_residual)], 12)
      .slope(x)
    },
    form_residual_mean_16 = {
      x <- tail(event_residual[!is.na(event_residual)], 16)
      if (length(x) == 0) NA_real_ else mean(x)
    },
    form_residual_slope_16 = {
      x <- tail(event_residual[!is.na(event_residual)], 16)
      .slope(x)
    },
    n_events_available = sum(!is.na(event_residual)),
    form_ott_mean_8 = {
      x <- tail(event_ott_mean[!is.na(event_ott_mean)], 8)
      if (length(x) == 0) NA_real_ else mean(x)
    },
    form_app_mean_8 = {
      x <- tail(event_app_mean[!is.na(event_app_mean)], 8)
      if (length(x) == 0) NA_real_ else mean(x)
    },
    form_arg_mean_8 = {
      x <- tail(event_arg_mean[!is.na(event_arg_mean)], 8)
      if (length(x) == 0) NA_real_ else mean(x)
    },
    form_putt_mean_8 = {
      x <- tail(event_putt_mean[!is.na(event_putt_mean)], 8)
      if (length(x) == 0) NA_real_ else mean(x)
    },
    form_putt_sd_8 = {
      x <- tail(event_putt_mean[!is.na(event_putt_mean)], 8)
      if (length(x) < 2L) NA_real_ else sd(x)
    },
    .groups = "drop"
  )

# ---- Build scoring frame --------------------------------------------------
# One row per field player. Use round 1 as the representative round for
# prediction (model predicts per-round residual; pre-tournament = round 1).

score_frame <- field_players |>
  left_join(skill_priors_latest, by = "dg_id") |>
  left_join(pga_form,            by = "dg_id") |>
  mutate(
    wave      = factor("AM"),
    round_num = 1L,
    is_major  = TOURNAMENT_IS_MAJOR,
    course_id = factor(paste0(TOURNAMENT_SLUG, "_", TOURNAMENT_YEAR)),
    year      = TOURNAMENT_YEAR,
    player_id = factor(dg_id),
    sg_r1      = NA_real_,
    sg_r2      = NA_real_,
    sg_r3      = NA_real_,
    sg_ott_r1  = NA_real_, sg_ott_r2  = NA_real_, sg_ott_r3  = NA_real_,
    sg_app_r1  = NA_real_, sg_app_r2  = NA_real_, sg_app_r3  = NA_real_,
    sg_arg_r1  = NA_real_, sg_arg_r2  = NA_real_, sg_arg_r3  = NA_real_,
    sg_putt_r1 = NA_real_, sg_putt_r2 = NA_real_, sg_putt_r3 = NA_real_,
    # Course-fit score using tournament venue weights
    course_fit_score =
      course_weights_df$weight_ott  * sg_ott_prior  +
      course_weights_df$weight_app  * sg_app_prior  +
      course_weights_df$weight_arg  * sg_arg_prior  +
      course_weights_df$weight_putt * sg_putt_prior,
    # Tournament-window weather (broadcast to all players for R1)
    wind_speed_tee    = r1_weather$wind_speed_tee,
    wind_dir_tee      = r1_weather$wind_dir_tee,
    temp_tee          = r1_weather$temp_tee,
    precip_tee        = r1_weather$precip_tee,
    weather_precision = r1_weather$weather_precision
  ) |>
  mutate(across(
    c(player_skill_prior, player_skill_prior_decay, player_anchor,
      course_fit_score,
      sg_ott_prior, sg_app_prior, sg_arg_prior, sg_putt_prior,
      starts_with("form_residual"),
      starts_with("form_ott_mean"), starts_with("form_app_mean"),
      starts_with("form_arg_mean"), starts_with("form_putt_mean")),
    ~ replace_na(.x, mean(.x, na.rm = TRUE))
  )) |>
  mutate(n_prior_rounds = replace_na(n_prior_rounds, as.integer(round(mean(n_prior_rounds, na.rm = TRUE)))))

# ---- Score ----------------------------------------------------------------

cli_h2("Scoring PGA Championship field")

score_frame$.pred <- predict(tuned_model, score_frame)$.pred

# ---- Output ranked table --------------------------------------------------

ranked_table <- score_frame |>
  mutate(predicted_sg_total = .pred + player_anchor) |>
  arrange(desc(predicted_sg_total)) |>
  mutate(rank = row_number()) |>
  select(
    rank,
    dg_id,
    player_name,
    predicted_sg_total,
    predicted_sg_residual = .pred,
    player_skill_prior,
    player_anchor,
    form_residual_mean_8,
    form_residual_slope_8,
    n_events_available
  ) |>
  mutate(across(where(is.double), ~ round(.x, 3)))

# ---- Win probabilities via stacked brms posterior ----------------------------

stack_model_file <- file.path(PATH_OUTPUT, "models", "brms_stack.rds")

if (file.exists(stack_model_file)) {
  cli_h2("Computing win / top-5 / top-10 probabilities (posterior simulation)")

  brms_stack <- readRDS(stack_model_file)

  score_frame_brms <- score_frame |>
    mutate(
      gbdt_pred     = .pred,
      player_season = factor(paste(dg_id, year))
    )

  N_DRAWS <- 2000L

  # Each posterior draw is one simulated tournament: the player's expected
  # residual (posterior_epred: parameter + player-RE uncertainty) persists
  # across all 4 rounds, while observation noise (sigma) is drawn fresh per
  # round. Summing independent posterior_predict calls per round would let
  # skill uncertainty average out across rounds, sharpening totals around
  # the point estimate. player_anchor (the residual anchor from 02) must be
  # added back before ranking so that a club pro +2 above their -4.8 baseline
  # loses to a tour pro +1 above +1.2.
  skill_priors <- score_frame_brms$player_anchor

  n_sim    <- min(N_DRAWS, ndraws(brms_stack))
  draw_ids <- round(seq(1L, ndraws(brms_stack), length.out = n_sim))
  mu_draws <- posterior_epred(
    brms_stack,
    newdata          = score_frame_brms,
    draw_ids         = draw_ids,
    allow_new_levels = TRUE
  )
  sigma_draws <- stack_sigma_draws(brms_stack, score_frame_brms, draw_ids)

  # round noise: 4 independent N(0, sigma) rounds sum to N(0, 2 * sigma);
  # sigma_draws is [n_sim x n_players] (per-player when the stack models
  # sigma); as.vector() aligns column-major with the matrix() fill
  round_noise <- matrix(
    rnorm(n_sim * ncol(mu_draws), sd = 2 * as.vector(sigma_draws)),
    nrow = n_sim
  )
  tournament_totals <- 4 * sweep(mu_draws, 2, skill_priors, "+") + round_noise
  # [N_DRAWS x n_players], units: sg_total above field average

  ranks_mat  <- t(apply(tournament_totals, 1, function(row) rank(-row, ties.method = "random")))
  win_prob   <- colMeans(ranks_mat == 1L)
  top5_prob  <- colMeans(ranks_mat <= 5L)
  top10_prob <- colMeans(ranks_mat <= 10L)

  # Per-round SG credible interval (10th–90th percentile of tournament total / 4)
  pred_lo <- apply(tournament_totals, 2, quantile, probs = 0.10) / 4
  pred_hi <- apply(tournament_totals, 2, quantile, probs = 0.90) / 4

  ranked_table <- ranked_table |>
    left_join(
      tibble(
        player_name = score_frame_brms$player_name,
        win_prob    = round(win_prob,   3),
        top5_prob   = round(top5_prob,  3),
        top10_prob  = round(top10_prob, 3),
        pred_sg_lo  = round(pred_lo,    3),
        pred_sg_hi  = round(pred_hi,    3)
      ),
      by = "player_name"
    )

  cli_alert_success("Win probabilities computed ({N_DRAWS} tournament simulations)")
} else {
  cli_alert_warning(
    "brms_stack.rds not found — skipping win probabilities. Run 06b_brms_stack.R to enable."
  )
}

# ---- Save CSV ----------------------------------------------------------------

out_csv <- file.path(PATH_OUTPUT, sprintf("%s_preview_%d.csv", TOURNAMENT_SLUG, TOURNAMENT_YEAR))
write_csv(ranked_table, out_csv)
cli_alert_success("Saved ranked table to {out_csv}")

# ---- Snapshot for retrospective eval harness ---------------------------------
# Versioned per event so harness/eval_export.R can find this run later, no
# matter what TOURNAMENT_SLUG points at next week.

eval_dir <- file.path(PATH_OUTPUT, "eval")
if (!dir.exists(eval_dir)) dir.create(eval_dir, recursive = TRUE)
snapshot_file <- file.path(
  eval_dir,
  sprintf("predictions_%s_%d_preview.rds", TOURNAMENT_SLUG, TOURNAMENT_YEAR)
)
saveRDS(ranked_table, snapshot_file)
cli_alert_success("Eval snapshot saved to {snapshot_file}")

# ---- Odds snapshot (Pinnacle sharp line) ------------------------------------
# Majors only — returns NULL silently for regular-tour events.
fetch_odds_snapshot(TOURNAMENT_SLUG, TOURNAMENT_YEAR)

# Print top 20
cli_h2("Top 20 — PGA Championship 2026 (model: {toupper(best_model_name)}, ranked by predicted SG total)")
print(slice(ranked_table, 1:30), n = 30)

cli_alert_info(
  "Note: model in active development. Target variable and hyperparameters ",
  "will be refined before US Open. This table signals direction, not final predictions."
)

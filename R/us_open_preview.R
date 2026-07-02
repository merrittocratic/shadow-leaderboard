source("R/00_config.R")
source("R/datagolf_api.R")
source("R/odds_api.R")
source("R/03_model_spec.R")
source("R/weather_forecast.R")

# US Open 2026 pre-tournament ranked table.
# Uses the PGA Championship field as a proxy for the US Open field (the full
# US Open field is not yet available from DataGolf). Course overridden to
# Shinnecock Hills; weather pulled from the Open-Meteo 16-day forecast.
#
# Run this after 05_tune.R and 06b_brms_stack.R have completed.
# If the LIV calibration pipeline (02e -> 04 -> 05 -> 06b) was re-run after
# the most recent LIV weight fix, rebuild model artifacts first.
#
#   op run --env-file=.env.template -- Rscript R/us_open_preview.R

library(slider)
library(gt)

source("tests/test_form_features.R")

cli_h1("US Open 2026 -- pre-tournament ranked table (PGA Championship proxy field)")

# ---- Course / tournament constants ----------------------------------------
# Shinnecock Hills, course_num 618, links/penal archetype, style-only weights.

TOURNAMENT_START_DATE <- as.Date("2026-06-18")
TOURNAMENT_YEAR       <- 2026L
TOURNAMENT_SLUG       <- "us_open"
TOURNAMENT_IS_MAJOR   <- TRUE
TOURNAMENT_COURSE_NUM <- 618L
COURSE_NAME           <- "Shinnecock Hills GC"
COURSE_LAT            <- 40.8941028
COURSE_LON            <- -72.4397956

# ---- Load course weights from taxonomy ------------------------------------

taxonomy_full <- readr::read_csv(
  file.path(here::here(), "config", "course_taxonomy_weighted.csv"),
  col_types = readr::cols(course_num = readr::col_integer(), .default = readr::col_guess()),
  show_col_types = FALSE
)

course_row <- taxonomy_full |> filter(course_num == TOURNAMENT_COURSE_NUM)
if (nrow(course_row) == 0) cli_abort("Shinnecock Hills (course_num 618) not found in taxonomy.")

course_weights_df <- course_row |> select(weight_ott, weight_app, weight_arg, weight_putt)
cli_alert_info(glue::glue(
  "Shinnecock weights: ",
  "OTT={round(course_weights_df$weight_ott,3)} ",
  "APP={round(course_weights_df$weight_app,3)} ",
  "ARG={round(course_weights_df$weight_arg,3)} ",
  "PUTT={round(course_weights_df$weight_putt,3)}"
))

# ---- Load historical rounds (needed for skill priors) ---------------------

player_rounds_hist <- readRDS(file.path(PATH_DATA, "02_player_rounds.rds"))

# ---- Load trained model ---------------------------------------------------

best_model_name <- readLines(file.path(PATH_OUTPUT, "models", "best_model.txt"))
model_file      <- file.path(PATH_OUTPUT, "models", paste0(best_model_name, "_tuned.rds"))
if (!file.exists(model_file)) cli_abort("Tuned model not found. Run 05_tune.R first.")

tuned_model <- readRDS(model_file)
cli_alert_success("Loaded tuned {toupper(best_model_name)} model")

# ---- Pull 2026 YTD data ---------------------------------------------------

cli_h2("Pulling 2026 YTD data")

data_2026 <- tryCatch(
  dg_historical_raw(tour = "pga", year = 2026L),
  error = function(e) cli_abort("Failed to pull 2026 data: {conditionMessage(e)}")
)
cli_alert_success("2026 events retrieved: {length(data_2026)}")

# ---- Flatten 2026 rounds --------------------------------------------------

flatten_event_simple <- function(event) {
  scores      <- event$scores
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
    ) |> filter(!is.na(sg_total))
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

# ---- Extract PGA Championship field from 2026 historical data -------------

field_players <- rounds_2026 |>
  filter(str_detect(event_name, regex("pga championship", ignore_case = TRUE))) |>
  distinct(dg_id, player_name) |>
  mutate(dg_id = as.integer(dg_id))

if (nrow(field_players) == 0) {
  cli_abort("No PGA Championship rounds found in 2026 data. Check event_name values in rounds_2026.")
}

cli_alert_success(
  "Proxy field: {nrow(field_players)} players from PGA Championship 2026 (actual participants)"
)

# ---- Skill priors from training set (2025 year-end) -----------------------

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

rounds_2026 <- rounds_2026 |>
  left_join(skill_priors_latest, by = "dg_id") |>
  mutate(field_mean_sg = NA_real_, sg_residual = NA_real_)

# ---- Form features through most recent pre-US-Open event ------------------

cli_h2("Computing form features (2026 YTD included)")

.slope <- function(x) {
  x <- x[!is.na(x)]
  n <- length(x)
  if (n < 2L) return(NA_real_)
  t <- seq_len(n); t_mean <- mean(t); x_mean <- mean(x)
  sum((t - t_mean) * (x - x_mean)) / sum((t - t_mean)^2)
}

all_rounds <- bind_rows(
  select(player_rounds_hist, dg_id, event_id, year, event_completed,
         sg_total, sg_ott, sg_app, sg_arg, sg_putt,
         player_skill_prior, sg_ott_prior, sg_app_prior,
         sg_arg_prior, sg_putt_prior, player_skill_prior_decay, n_prior_rounds),
  select(rounds_2026, dg_id, event_id, year, event_completed,
         sg_total, sg_ott, sg_app, sg_arg, sg_putt,
         player_skill_prior, sg_ott_prior, sg_app_prior,
         sg_arg_prior, sg_putt_prior, player_skill_prior_decay, n_prior_rounds)
)

event_sg_all <- all_rounds |>
  group_by(dg_id, event_id, year, event_completed) |>
  summarise(
    event_sg_mean      = mean(sg_total, na.rm = TRUE),
    event_ott_mean     = mean(sg_ott,   na.rm = TRUE),
    event_app_mean     = mean(sg_app,   na.rm = TRUE),
    event_arg_mean     = mean(sg_arg,   na.rm = TRUE),
    event_putt_mean    = mean(sg_putt,  na.rm = TRUE),
    player_skill_prior = first(na.omit(player_skill_prior)),
    .groups            = "drop"
  ) |>
  mutate(event_residual = event_sg_mean - player_skill_prior) |>
  arrange(dg_id, event_completed)

field_form <- event_sg_all |>
  filter(dg_id %in% field_players$dg_id) |>
  group_by(dg_id) |>
  summarise(
    form_residual_mean_8   = { x <- tail(event_residual[!is.na(event_residual)], 8);  if (!length(x)) NA_real_ else mean(x) },
    form_residual_slope_8  = { x <- tail(event_residual[!is.na(event_residual)], 8);  .slope(x) },
    form_residual_mean_4   = { x <- tail(event_residual[!is.na(event_residual)], 4);  if (!length(x)) NA_real_ else mean(x) },
    form_residual_slope_4  = { x <- tail(event_residual[!is.na(event_residual)], 4);  .slope(x) },
    form_residual_mean_12  = { x <- tail(event_residual[!is.na(event_residual)], 12); if (!length(x)) NA_real_ else mean(x) },
    form_residual_slope_12 = { x <- tail(event_residual[!is.na(event_residual)], 12); .slope(x) },
    form_residual_mean_16  = { x <- tail(event_residual[!is.na(event_residual)], 16); if (!length(x)) NA_real_ else mean(x) },
    form_residual_slope_16 = { x <- tail(event_residual[!is.na(event_residual)], 16); .slope(x) },
    n_events_available     = sum(!is.na(event_residual)),
    form_ott_mean_8  = { x <- tail(event_ott_mean[!is.na(event_ott_mean)],  8); if (!length(x)) NA_real_ else mean(x) },
    form_app_mean_8  = { x <- tail(event_app_mean[!is.na(event_app_mean)],  8); if (!length(x)) NA_real_ else mean(x) },
    form_arg_mean_8  = { x <- tail(event_arg_mean[!is.na(event_arg_mean)],  8); if (!length(x)) NA_real_ else mean(x) },
    form_putt_mean_8 = { x <- tail(event_putt_mean[!is.na(event_putt_mean)],8); if (!length(x)) NA_real_ else mean(x) },
    form_putt_sd_8   = { x <- tail(event_putt_mean[!is.na(event_putt_mean)],8); if (length(x) < 2L) NA_real_ else sd(x) },
    .groups = "drop"
  )

# ---- Weather forecast for R1 (June 18) ------------------------------------

cli_h2("Pulling R1 weather forecast (Shinnecock Hills, {TOURNAMENT_START_DATE})")
r1_weather <- pull_round_weather(COURSE_LAT, COURSE_LON, TOURNAMENT_START_DATE)
cli_alert_info(glue::glue(
  "R1 forecast: wind {round(r1_weather$wind_speed_tee,1)} mph @ {round(r1_weather$wind_dir_tee,0)}, ",
  "temp {round(r1_weather$temp_tee,1)}F, precip {round(r1_weather$precip_tee,2)} in, ",
  "precision={r1_weather$weather_precision %||% 'NA'}"
))

# ---- Build scoring frame --------------------------------------------------

score_frame <- field_players |>
  left_join(skill_priors_latest, by = "dg_id") |>
  left_join(field_form,          by = "dg_id") |>
  mutate(
    wave      = factor("AM"),
    round_num = 1L,
    is_major  = TOURNAMENT_IS_MAJOR,
    course_id = factor(paste0(TOURNAMENT_SLUG, "_", TOURNAMENT_YEAR)),
    year      = TOURNAMENT_YEAR,
    player_id = factor(dg_id),
    tournament_form = 0,
    sg_r1  = NA_real_, sg_r2  = NA_real_, sg_r3  = NA_real_,
    sg_ott_r1  = NA_real_, sg_ott_r2  = NA_real_, sg_ott_r3  = NA_real_,
    sg_app_r1  = NA_real_, sg_app_r2  = NA_real_, sg_app_r3  = NA_real_,
    sg_arg_r1  = NA_real_, sg_arg_r2  = NA_real_, sg_arg_r3  = NA_real_,
    sg_putt_r1 = NA_real_, sg_putt_r2 = NA_real_, sg_putt_r3 = NA_real_,
    course_fit_score =
      course_weights_df$weight_ott  * sg_ott_prior  +
      course_weights_df$weight_app  * sg_app_prior  +
      course_weights_df$weight_arg  * sg_arg_prior  +
      course_weights_df$weight_putt * sg_putt_prior,
    wind_speed_tee    = r1_weather$wind_speed_tee,
    wind_dir_tee      = r1_weather$wind_dir_tee,
    temp_tee          = r1_weather$temp_tee,
    precip_tee        = r1_weather$precip_tee,
    weather_precision = r1_weather$weather_precision
  ) |>
  mutate(across(
    c(player_skill_prior, player_skill_prior_decay,
      course_fit_score,
      sg_ott_prior, sg_app_prior, sg_arg_prior, sg_putt_prior,
      starts_with("form_residual"),
      starts_with("form_ott_mean"), starts_with("form_app_mean"),
      starts_with("form_arg_mean"), starts_with("form_putt_mean")),
    ~ replace_na(.x, mean(.x, na.rm = TRUE))
  )) |>
  mutate(n_prior_rounds = replace_na(n_prior_rounds, as.integer(round(mean(n_prior_rounds, na.rm = TRUE)))))

# ---- Score ----------------------------------------------------------------

cli_h2("Scoring field")
score_frame$.pred <- predict(tuned_model, score_frame)$.pred

ranked_table <- score_frame |>
  mutate(predicted_sg_total = .pred + player_skill_prior) |>
  arrange(desc(predicted_sg_total)) |>
  mutate(rank = row_number()) |>
  select(
    rank, dg_id, player_name,
    predicted_sg_total, predicted_sg_residual = .pred,
    player_skill_prior, form_residual_mean_8, form_residual_slope_8,
    n_events_available
  ) |>
  mutate(across(where(is.double), ~ round(.x, 3)))

# ---- Win probabilities via stacked brms -----------------------------------

stack_model_file <- file.path(PATH_OUTPUT, "models", "brms_stack.rds")

if (file.exists(stack_model_file)) {
  cli_h2("Computing win / top-5 / top-10 probabilities ({2000L} tournament simulations)")

  brms_stack <- readRDS(stack_model_file)

  score_frame_brms <- score_frame |>
    mutate(
      gbdt_pred     = .pred,
      player_season = factor(paste(dg_id, year))
    )

  N_DRAWS <- 2000L

  # posterior_predict returns sg_residual samples (deviation above player's own
  # baseline). player_skill_prior must be added back before ranking so that a
  # club pro +2 above their -4.8 baseline loses to a tour pro +1 above +1.2.
  skill_priors <- score_frame_brms$player_skill_prior

  tournament_totals <- Reduce("+", lapply(seq_len(4L), function(r) {
    draws <- posterior_predict(
      brms_stack,
      newdata          = score_frame_brms,
      ndraws           = N_DRAWS,
      allow_new_levels = TRUE
    )
    sweep(draws, 2, skill_priors, "+")
  }))  # [N_DRAWS x n_players], units: sg_total above field average

  ranks_mat  <- t(apply(tournament_totals, 1, function(row) rank(-row, ties.method = "random")))
  win_prob   <- colMeans(ranks_mat == 1L)
  top5_prob  <- colMeans(ranks_mat <= 5L)
  top10_prob <- colMeans(ranks_mat <= 10L)

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

  cli_alert_success("Win probabilities computed")
} else {
  cli_alert_warning("brms_stack.rds not found -- skipping win probabilities.")
}

# ---- Save -----------------------------------------------------------------

out_csv <- file.path(PATH_OUTPUT, "us_open_preview_2026.csv")
write_csv(ranked_table, out_csv)
cli_alert_success("Saved to {out_csv}")

eval_dir <- file.path(PATH_OUTPUT, "eval")
if (!dir.exists(eval_dir)) dir.create(eval_dir, recursive = TRUE)
saveRDS(ranked_table, file.path(eval_dir, "predictions_us_open_2026_preview.rds"))
cli_alert_success("Eval snapshot saved")

fetch_odds_snapshot(TOURNAMENT_SLUG, TOURNAMENT_YEAR)

cli_h2("Top 20 -- US Open 2026 proxy (Shinnecock Hills, {toupper(best_model_name)})")
print(slice(ranked_table, 1:20), n = 20)

cli_alert_info(
  "Field note: 147-player PGA Championship proxy. ",
  "Actual US Open field (156 players) available next week from DataGolf."
)

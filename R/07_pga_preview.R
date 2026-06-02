source("R/00_config.R")
source("R/datagolf_api.R")
source("R/03_model_spec.R")

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
    n_prior_rounds           = first(na.omit(n_prior_rounds)),
    sg_ott_prior             = first(na.omit(sg_ott_prior)),
    sg_app_prior             = first(na.omit(sg_app_prior)),
    sg_arg_prior             = first(na.omit(sg_arg_prior)),
    sg_putt_prior            = first(na.omit(sg_putt_prior)),
    .groups = "drop"
  )

# Course-fit weights for the tournament venue
TOURNAMENT_COURSE_NUM <- 241L   # Quail Hollow — PGA Championship; update per event

course_weights_df <- readr::read_csv(
  file.path(here::here(), "config", "course_taxonomy_weighted.csv"),
  col_types = readr::cols(course_num = readr::col_integer(), .default = readr::col_guess()),
  show_col_types = FALSE
) |>
  filter(course_num == TOURNAMENT_COURSE_NUM) |>
  select(weight_ott, weight_app, weight_arg, weight_putt)

if (nrow(course_weights_df) == 0) {
  cli_alert_warning(
    "course_num {TOURNAMENT_COURSE_NUM} not found in taxonomy — course_fit_score will be imputed"
  )
  course_weights_df <- tibble(
    weight_ott = NA_real_, weight_app = NA_real_,
    weight_arg = NA_real_, weight_putt = NA_real_
  )
}
cli_alert_info(glue::glue(
  "Course weights (course_num {TOURNAMENT_COURSE_NUM}): ",
  "OTT={round(course_weights_df$weight_ott,3)} ",
  "APP={round(course_weights_df$weight_app,3)} ",
  "ARG={round(course_weights_df$weight_arg,3)} ",
  "PUTT={round(course_weights_df$weight_putt,3)}"
))

rounds_2026 <- rounds_2026 |>
  left_join(skill_priors_latest, by = "dg_id") |>
  mutate(field_mean_sg = NA_real_, sg_residual = NA_real_)  # not needed for scoring

# Stack historical + 2026 for form feature computation
all_rounds <- bind_rows(
  select(player_rounds_hist, dg_id, event_id, year, event_completed,
         sg_total, player_skill_prior, sg_ott_prior, sg_app_prior,
         sg_arg_prior, sg_putt_prior, player_skill_prior_decay, n_prior_rounds),
  select(rounds_2026, dg_id, event_id, year, event_completed,
         sg_total, player_skill_prior, sg_ott_prior, sg_app_prior,
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
    player_skill_prior = first(na.omit(player_skill_prior)),
    .groups            = "drop"
  ) |>
  mutate(event_residual = event_sg_mean - player_skill_prior) |>
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
    is_major  = TRUE,
    course_id = factor("pga_champ_2026"),
    year      = 2026L,
    player_id = factor(dg_id),
    sg_r1     = NA_real_,
    sg_r2     = NA_real_,
    sg_r3     = NA_real_,
    # Course-fit score using tournament venue weights
    course_fit_score =
      course_weights_df$weight_ott  * sg_ott_prior  +
      course_weights_df$weight_app  * sg_app_prior  +
      course_weights_df$weight_arg  * sg_arg_prior  +
      course_weights_df$weight_putt * sg_putt_prior
  ) |>
  mutate(across(
    c(player_skill_prior, player_skill_prior_decay,
      course_fit_score,
      sg_ott_prior, sg_app_prior, sg_arg_prior, sg_putt_prior,
      starts_with("form_residual")),
    ~ replace_na(.x, mean(.x, na.rm = TRUE))
  )) |>
  mutate(n_prior_rounds = replace_na(n_prior_rounds, as.integer(round(mean(n_prior_rounds, na.rm = TRUE)))))

# ---- Score ----------------------------------------------------------------

cli_h2("Scoring PGA Championship field")

score_frame$.pred <- predict(tuned_model, score_frame)$.pred

# ---- Output ranked table --------------------------------------------------

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

  # Simulate 4-round tournament. Each call draws fresh posterior samples so
  # rounds are conditionally independent — slight overstatement of cross-round
  # uncertainty, negligible effect on win-probability ranking.
  tournament_totals <- Reduce("+", lapply(seq_len(4L), function(r) {
    posterior_predict(
      brms_stack,
      newdata          = score_frame_brms,
      ndraws           = N_DRAWS,
      allow_new_levels = TRUE
    )
  }))  # [N_DRAWS x n_players]

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

out_csv <- file.path(PATH_OUTPUT, "pga_preview_2026.csv")
write_csv(ranked_table, out_csv)
cli_alert_success("Saved ranked table to {out_csv}")

# Print top 20
cli_h2("Top 20 — PGA Championship 2026 (model: {toupper(best_model_name)}, ranked by predicted SG total)")
print(slice(ranked_table, 1:30), n = 30)

cli_alert_info(
  "Note: model in active development. Target variable and hyperparameters ",
  "will be refined before US Open. This table signals direction, not final predictions."
)

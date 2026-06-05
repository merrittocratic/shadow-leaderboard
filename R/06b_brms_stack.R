source("R/00_config.R")
source("R/03_model_spec.R")

# Stacked brms model: LGBM/XGB point predictions as a fixed effect,
# with player / player-season / course random effects capturing residual
# uncertainty.  Outputs a posterior predictive distribution per player,
# enabling win-probability and credible-interval computation in 07/08.
#
# Requires 05_tune.R to have completed first.
#
#   Rscript R/06b_brms_stack.R

library(brms)
library(finetune)

cli_h1("Stacked brms — GBDT point prediction + Bayesian residual uncertainty")

# ---- Load training data ------------------------------------------------------

player_rounds_base <- readRDS(file.path(PATH_DATA, "02_player_rounds.rds"))
form_features      <- readRDS(file.path(PATH_DATA, "02b_form_features.rds"))
weather_features   <- readRDS(file.path(PATH_DATA, "02d_weather_features.rds"))

player_rounds <- player_rounds_base |>
  left_join(
    select(form_features, -event_completed),
    by = c("dg_id", "event_id", "year")
  ) |>
  left_join(
    select(weather_features, dg_id, event_id, year, round_num,
           wind_speed_tee, wind_dir_tee, temp_tee, precip_tee, weather_precision),
    by = c("dg_id", "event_id", "year", "round_num")
  )

holdout_ids <- player_rounds |>
  filter(
    (year == 2025 & str_detect(event_name, regex("u\\.?s\\.? open", ignore_case = TRUE))) |
    (year == 2026 & str_detect(event_name, regex("masters",          ignore_case = TRUE)))
  ) |>
  mutate(key = paste(event_id, year)) |>
  pull(key) |>
  unique()

train_data <- player_rounds |>
  filter(year <= 2023) |>
  filter(!paste(event_id, year) %in% holdout_ids)

cli_alert_info("Training rows: {scales::comma(nrow(train_data))}")

# ---- Load best GBDT model ----------------------------------------------------

best_model_name <- readLines(file.path(PATH_OUTPUT, "models", "best_model.txt"))
model_file      <- file.path(PATH_OUTPUT, "models", paste0(best_model_name, "_tuned.rds"))

if (!file.exists(model_file)) {
  cli_abort("Tuned model not found at {model_file}. Run 05_tune.R first.")
}
tuned_model <- readRDS(model_file)
cli_alert_success("Loaded tuned {toupper(best_model_name)} model")

# ---- Generate OOF predictions ------------------------------------------------
# Refit the finalized workflow (best hyperparameters, no grid search) across
# the same sliding-window folds used in 05_tune.R to get proper OOF predictions.
# Cached to disk so re-runs are instant.

oof_cache <- file.path(PATH_OUTPUT, "models", paste0(best_model_name, "_oof_preds.rds"))

if (file.exists(oof_cache)) {
  cli_alert_info("Loading cached OOF predictions from {oof_cache}")
  oof_df <- readRDS(oof_cache)
} else {
  cli_h2("Generating OOF predictions via 5-fold sliding-window CV")

  val_years <- 2019:2023
  cv_splits <- purrr::map(val_years, function(val_yr) {
    rsample::make_splits(
      list(
        analysis   = which(train_data$year <  val_yr),
        assessment = which(train_data$year == val_yr)
      ),
      data = train_data
    )
  }) |>
    rsample::manual_rset(ids = paste0("Val_", val_years))

  tune_res_file <- file.path(PATH_OUTPUT, "models", paste0(best_model_name, "_tune_results.rds"))
  if (!file.exists(tune_res_file)) {
    cli_abort("Tune results not found at {tune_res_file}. Run 05_tune.R first.")
  }
  tune_res    <- readRDS(tune_res_file)
  best_params <- select_best(tune_res, metric = "rmse")

  base_spec <- if (best_model_name == "lgbm") lgbm_spec_tune else xgb_spec_tune

  wf_final <- workflow() |>
    add_recipe(gbdt_recipe(train_data)) |>
    add_model(base_spec) |>
    finalize_workflow(best_params)

  cli_alert_info("Refitting finalized workflow across {nrow(cv_splits)} folds...")
  oof_res <- fit_resamples(
    wf_final,
    resamples = cv_splits,
    control   = control_resamples(save_pred = TRUE)
  )

  oof_df <- collect_predictions(oof_res) |>
    select(.row, gbdt_pred = .pred)

  saveRDS(oof_df, oof_cache)
  cli_alert_success("OOF predictions cached to {oof_cache}")
}

cli_alert_info("OOF predictions: {scales::comma(nrow(oof_df))} rows")

# ---- Build stacking training frame -------------------------------------------
# Rows limited to the 5 validation years (2019-2023) — only those have OOF preds.
# inner_join drops pre-2019 training rows; that's correct for stacking.

stack_train <- train_data |>
  mutate(.row = row_number()) |>
  inner_join(oof_df, by = ".row") |>
  mutate(
    player_id     = factor(dg_id),
    player_season = factor(paste(dg_id, year)),
    course_id     = factor(course_num)
  )

cli_alert_info(
  "Stack training frame: {scales::comma(nrow(stack_train))} rows ",
  "({scales::percent(nrow(stack_train) / nrow(train_data))} of training set, years 2019-2023)"
)

# ---- brms stacked formula + priors -------------------------------------------
# Prior on gbdt_pred: centered at 1.0 — if the GBDT is well-calibrated the
# coefficient should be near-unit, not arbitrary.  SD=0.3 is permissive enough
# to let the data move it but tight enough to regularize against overfitting the
# second stage.
# Remaining random effects absorb player / season / venue residual variance that
# the GBDT missed.

brms_formula_stack <- bf(
  sg_residual ~ gbdt_pred +
    (1 | player_id) +
    (1 | player_season) +
    (1 | course_id)
)

brms_priors_stack <- c(
  prior(normal(1, 0.3),   class = b,         coef = gbdt_pred),
  prior(normal(0, 0.5),   class = Intercept),
  prior(exponential(1),   class = sd),
  prior(exponential(1),   class = sigma)
)

# ---- Fit ---------------------------------------------------------------------

cli_h2("Fitting stacked brms model ({brms_ctrl$chains} chains x {brms_ctrl$iter} iter)")

brms_stack_fit <- do.call(brm, c(
  list(
    formula = brms_formula_stack,
    data    = stack_train,
    prior   = brms_priors_stack
  ),
  brms_ctrl
))

# ---- Diagnostics -------------------------------------------------------------

cli_h2("Posterior diagnostics")

# gbdt_pred coefficient — should sit near 1.0
cli_alert_info("Fixed effects:")
print(fixef(brms_stack_fit))

# Residual random-effect SDs — how much variance the GBDT left on the table
cli_alert_info("Random-effect SDs (residual variance after GBDT):")
print(VarCorr(brms_stack_fit))

# Posterior predictive check
pp_check_plot <- pp_check(brms_stack_fit, ndraws = 100)
ggplot2::ggsave(
  file.path(PATH_OUTPUT, "brms_stack_ppcheck.png"),
  pp_check_plot, width = 8, height = 5
)
cli_alert_success(
  "PP check saved to {file.path(PATH_OUTPUT, 'brms_stack_ppcheck.png')}"
)

# ---- Save --------------------------------------------------------------------

stack_model_file <- file.path(PATH_OUTPUT, "models", "brms_stack.rds")
saveRDS(brms_stack_fit, stack_model_file)
cli_alert_success("Saved stacked brms model to {stack_model_file}")

cli_h1("Done — use brms_stack.rds in 07/08 for posterior predictive win probabilities")
cli_alert_info(
  "Usage in scoring scripts: ",
  "posterior_predict(brms_stack_fit, newdata = score_frame, ndraws = 1000) ",
  "returns a [1000 x n_players] matrix — rows are tournament simulations."
)

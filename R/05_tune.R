source("R/00_config.R")
source("R/03_model_spec.R")

# Tune XGBoost and LightGBM via tune_race_anova() on sliding-window CV folds.
# CV strategy: 5 cumulative folds, validation years 2019–2023.
# Grid: 50-point Latin hypercube over trees, tree_depth, learn_rate,
#       min_n, sample_size.
#
#   Rscript R/05_tune.R

library(finetune)
library(doParallel)

cli_h1("Week 3 tuning -- XGBoost and LightGBM")

# ---- Load data ------------------------------------------------------------

player_rounds_base <- readRDS(file.path(PATH_DATA, "02_player_rounds.rds"))
form_features      <- readRDS(file.path(PATH_DATA, "02b_form_features.rds"))

player_rounds <- left_join(
  player_rounds_base,
  select(form_features, -event_completed),
  by = c("dg_id", "event_id", "year")
)

# Exclude held-out validation events
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

# ---- Sliding-window CV folds ----------------------------------------------
# Cumulative training sets: all years < val_yr; assessment: val_yr.
# 5 folds: validate 2019, 2020, 2021, 2022, 2023.

cli_h2("Building CV folds (sliding window, 2019-2023)")

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

cli_alert_success(
  "CV folds: {nrow(cv_splits)} | ",
  "training sizes: {paste(map_int(cv_splits$splits, ~nrow(analysis(.))), collapse = ' / ')}"
)

# ---- Tuning grid ----------------------------------------------------------

tune_grid <- dials::grid_latin_hypercube(
  dials::trees(          range = c(200L,  2000L)),
  dials::tree_depth(     range = c(2L,    10L)),
  dials::learn_rate(     range = c(-3,    -0.7), trans = scales::log10_trans()),
  dials::min_n(          range = c(2L,    40L)),
  dials::sample_prop(    range = c(0.5,   1.0)),
  size = 50
)

cli_alert_info("Tuning grid: {nrow(tune_grid)} candidates x {nrow(cv_splits)} folds")

# ---- Register parallel backend --------------------------------------------

n_cores <- min(parallel::detectCores() - 1L, nrow(cv_splits))
cl <- makeCluster(n_cores)
registerDoParallel(cl)
cli_alert_info("Parallel: {n_cores} workers")

tune_ctrl <- control_race(
  verbose       = TRUE,
  save_pred     = FALSE,
  parallel_over = "resamples"
)

metric_set <- yardstick::metric_set(yardstick::rmse)

# ---- XGBoost tuning -------------------------------------------------------

cli_h2("XGBoost -- tune_race_anova()")

xgb_wf_tune <- workflow() |>
  add_recipe(gbdt_recipe(train_data)) |>
  add_model(xgb_spec_tune)

xgb_tune_res <- tune_race_anova(
  xgb_wf_tune,
  resamples = cv_splits,
  grid      = tune_grid,
  metrics   = metric_set,
  control   = tune_ctrl
)

xgb_best   <- select_best(xgb_tune_res, metric = "rmse")
xgb_wf_fit <- finalize_workflow(xgb_wf_tune, xgb_best) |> fit(train_data)

saveRDS(xgb_tune_res, file.path(PATH_OUTPUT, "models", "xgb_tune_results.rds"))
saveRDS(xgb_wf_fit,  file.path(PATH_OUTPUT, "models", "xgb_tuned.rds"))

cli_alert_success("XGBoost best hyperparameters:")
print(xgb_best)

# ---- LightGBM tuning ------------------------------------------------------

cli_h2("LightGBM -- tune_race_anova()")

lgbm_wf_tune <- workflow() |>
  add_recipe(gbdt_recipe(train_data)) |>
  add_model(lgbm_spec_tune)

lgbm_tune_res <- tune_race_anova(
  lgbm_wf_tune,
  resamples = cv_splits,
  grid      = tune_grid,
  metrics   = metric_set,
  control   = tune_ctrl
)

lgbm_best   <- select_best(lgbm_tune_res, metric = "rmse")
lgbm_wf_fit <- finalize_workflow(lgbm_wf_tune, lgbm_best) |> fit(train_data)

saveRDS(lgbm_tune_res, file.path(PATH_OUTPUT, "models", "lgbm_tune_results.rds"))
saveRDS(lgbm_wf_fit,  file.path(PATH_OUTPUT, "models", "lgbm_tuned.rds"))

cli_alert_success("LightGBM best hyperparameters:")
print(lgbm_best)

stopCluster(cl)
registerDoSEQ()

# ---- lme4 (no hyperparameter tuning — fit once on full training set) ------
# Run after parallel tuning so it doesn't compete for cores.

cli_h2("lme4 -- fit with updated formula (random slopes on form)")

train_lme4 <- prep_for_lme(train_data)

lmer_fit <- lme4::lmer(lmer_formula, data = train_lme4, REML = TRUE)
saveRDS(lmer_fit, file.path(PATH_OUTPUT, "models", "lmer_wk3.rds"))
cli_alert_success("lme4 fit complete")

# ---- Compare all three on held-out 2024 -----------------------------------

cli_h2("Comparing all models on 2024")

sanity_data      <- player_rounds |>
  filter(year == 2024) |>
  filter(!paste(event_id, year) %in% holdout_ids)

sanity_lme4 <- prep_for_lme(sanity_data, ref_df = train_data)

xgb_rmse  <- yardstick::rmse_vec(
  truth    = sanity_data$sg_residual,
  estimate = predict(xgb_wf_fit,  sanity_data)$.pred
)
lgbm_rmse <- yardstick::rmse_vec(
  truth    = sanity_data$sg_residual,
  estimate = predict(lgbm_wf_fit, sanity_data)$.pred
)
lmer_rmse <- yardstick::rmse_vec(
  truth    = sanity_lme4$sg_residual,
  estimate = predict(lmer_fit, newdata = sanity_lme4, allow.new.levels = TRUE)
)

results <- tibble::tibble(
  model     = c("XGBoost (tuned)", "LightGBM (tuned)", "lme4 (random slopes)"),
  rmse_2024 = c(xgb_rmse, lgbm_rmse, lmer_rmse)
) |>
  dplyr::arrange(rmse_2024)
print(results)

best_gbdt <- if (xgb_rmse <= lgbm_rmse) "xgb" else "lgbm"
cli_alert_success("Best tuned GBDT for PGA preview: {best_gbdt}")

writeLines(best_gbdt, file.path(PATH_OUTPUT, "models", "best_model.txt"))

cli_h1("Tuning complete")

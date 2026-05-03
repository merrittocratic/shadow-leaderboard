source("R/00_config.R")
source("R/03_model_spec.R")

# Week 2 sanity check: fit all four model skeletons with default
# hyperparameters, evaluate on 2024, inspect residual distributions.
#
#   Rscript R/04_train_evaluate.R
#
# brms runs on a 3-event subsample from 2023 to validate model structure
# before scaling up in Week 3.

library(ggplot2)
library(scales)
library(yardstick)

cli_h1("Week 2 -- four model skeletons, default hyperparameters")

# ---- Load and split data --------------------------------------------------

player_rounds <- readRDS(file.path(PATH_DATA, "02_player_rounds.rds"))

# Confirm held-out event names by checking what's in 2025/2026
holdout_events <- player_rounds |>
  filter(
    (year == 2025 & str_detect(event_name, regex("u\\.?s\\.? open", ignore_case = TRUE))) |
    (year == 2026 & str_detect(event_name, regex("masters", ignore_case = TRUE)))
  ) |>
  distinct(year, event_id, event_name)

cli_alert_info("Identified holdout events:")
print(holdout_events)

holdout_ids <- holdout_events |>
  mutate(key = paste(event_id, year)) |>
  pull(key)

# Training: 2010–2023, no holdouts
train_data <- player_rounds |>
  filter(year < 2024) |>
  filter(!paste(event_id, year) %in% holdout_ids)

# Sanity check: 2024, no holdouts
sanity_data <- player_rounds |>
  filter(year == 2024) |>
  filter(!paste(event_id, year) %in% holdout_ids)

cli_alert_info("Training rows:      {comma(nrow(train_data))}")
cli_alert_info("Sanity check rows:  {comma(nrow(sanity_data))} (2024)")

dir.create(file.path(PATH_OUTPUT, "models"), recursive = TRUE, showWarnings = FALSE)

# ---- Helper: RMSE ---------------------------------------------------------

report_rmse <- function(truth, estimate, label) {
  r <- rmse_vec(truth = truth, estimate = estimate)
  cli_alert_success("{label} RMSE: {round(r, 4)}")
  tibble(model = label, rmse = r)
}

# ---- 1 / 4  XGBoost -------------------------------------------------------

cli_h2("1/4  XGBoost")

xgb_wf  <- workflow() |> add_recipe(gbdt_recipe(train_data)) |> add_model(xgb_spec)
xgb_fit <- fit(xgb_wf, train_data)

saveRDS(xgb_fit, file.path(PATH_OUTPUT, "models", "xgb_wk2.rds"))

xgb_preds <- augment(xgb_fit, sanity_data) |> mutate(model = "XGBoost")
xgb_metrics <- report_rmse(xgb_preds$sg_residual, xgb_preds$.pred, "XGBoost")

# ---- 2 / 4  LightGBM ------------------------------------------------------

cli_h2("2/4  LightGBM")

lgbm_wf  <- workflow() |> add_recipe(gbdt_recipe(train_data)) |> add_model(lgbm_spec)
lgbm_fit <- fit(lgbm_wf, train_data)

saveRDS(lgbm_fit, file.path(PATH_OUTPUT, "models", "lgbm_wk2.rds"))

lgbm_preds <- augment(lgbm_fit, sanity_data) |> mutate(model = "LightGBM")
lgbm_metrics <- report_rmse(lgbm_preds$sg_residual, lgbm_preds$.pred, "LightGBM")

# ---- 3 / 4  lme4 ----------------------------------------------------------

cli_h2("3/4  lme4 (mixed effects)")

train_lme4  <- prep_for_lme(train_data)
sanity_lme4 <- prep_for_lme(sanity_data, ref_df = train_data)

lmer_fit <- lmer(lmer_formula, data = train_lme4, REML = TRUE)

saveRDS(lmer_fit, file.path(PATH_OUTPUT, "models", "lmer_wk2.rds"))

lmer_preds <- sanity_lme4 |>
  mutate(
    .pred = predict(lmer_fit, newdata = sanity_lme4, allow.new.levels = TRUE),
    model = "lme4"
  )
lmer_metrics <- report_rmse(lmer_preds$sg_residual, lmer_preds$.pred, "lme4")

# ---- 4 / 4  brms (3-event subsample from 2023) ----------------------------

cli_h2("4/4  brms (subsample: 3 events, 2023)")
cli_alert_info("This validates model structure only -- full data in Week 3")

set.seed(42)
brms_event_ids <- player_rounds |>
  filter(year == 2023) |>
  distinct(event_id) |>
  slice_sample(n = 3) |>
  pull(event_id)

brms_train <- player_rounds |>
  filter(year == 2023, event_id %in% brms_event_ids) |>
  prep_for_lme()

cli_alert_info(
  "brms subsample: {nrow(brms_train)} rows | ",
  "events: {paste(brms_event_ids, collapse = ', ')}"
)

options(mc.cores = 4)

brms_fit <- do.call(
  brm,
  c(list(formula = brms_formula, data = brms_train, prior = brms_priors),
    brms_ctrl)
)

saveRDS(brms_fit, file.path(PATH_OUTPUT, "models", "brms_wk2_subsample.rds"))

# Posterior predictive check — primary diagnostic for Week 2
pp_plot <- pp_check(brms_fit, ndraws = 50) +
  labs(
    title    = "brms: posterior predictive check",
    subtitle = glue::glue("Subsample: 3 events, 2023 ({nrow(brms_train)} player-rounds)")
  ) +
  theme_minimal()

ggsave(
  file.path(PATH_GRAPHICS, "brms_pp_check_wk2.png"),
  pp_plot, width = 8, height = 5, dpi = 150
)
cli_alert_success("Saved pp_check plot")

# brms in-sample fitted values for residual plot
brms_preds <- brms_train |>
  mutate(
    .pred = fitted(brms_fit)[, "Estimate"],
    model = "brms (subsample)"
  )
brms_metrics <- report_rmse(brms_preds$sg_residual, brms_preds$.pred, "brms (subsample, in-sample)")

# ---- Summary table --------------------------------------------------------

cli_h2("RMSE summary")

# Note: brms is in-sample on subsample; others are out-of-sample on 2024
metrics_table <- bind_rows(xgb_metrics, lgbm_metrics, lmer_metrics) |>
  mutate(eval_set = "2024 (out-of-sample)") |>
  bind_rows(
    brms_metrics |> mutate(eval_set = "2023 subsample (in-sample, structure check only)")
  )

print(metrics_table)

# ---- Residual distribution plots ------------------------------------------

cli_h2("Residual distribution plots")

all_preds <- bind_rows(
  select(xgb_preds,  model, sg_residual, .pred),
  select(lgbm_preds, model, sg_residual, .pred),
  select(lmer_preds, model, sg_residual, .pred)
) |>
  mutate(residual_error = sg_residual - .pred)

resid_plot <- ggplot(all_preds, aes(x = residual_error, fill = model)) +
  geom_density(alpha = 0.4) +
  facet_wrap(~model, ncol = 1) +
  labs(
    title    = "Week 2 sanity check: residual error distributions (2024 eval)",
    subtitle = "residual_error = sg_residual - .pred",
    x        = "Residual error",
    y        = "Density"
  ) +
  theme_minimal() +
  theme(legend.position = "none")

ggsave(
  file.path(PATH_GRAPHICS, "residual_distributions_wk2.png"),
  resid_plot, width = 8, height = 8, dpi = 150
)
cli_alert_success("Saved residual distribution plot")

pred_vs_actual <- ggplot(all_preds, aes(x = .pred, y = sg_residual, colour = model)) +
  geom_point(alpha = 0.15, size = 0.6) +
  geom_abline(slope = 1, intercept = 0, linetype = "dashed", colour = "grey40") +
  facet_wrap(~model) +
  labs(
    title = "Week 2: predicted vs. actual SG residual (2024)",
    x     = "Predicted",
    y     = "Actual"
  ) +
  theme_minimal() +
  theme(legend.position = "none")

ggsave(
  file.path(PATH_GRAPHICS, "pred_vs_actual_wk2.png"),
  pred_vs_actual, width = 10, height = 4, dpi = 150
)
cli_alert_success("Saved predicted vs. actual plot")

cli_h1("Week 2 complete")
cli_alert_info("Next: Week 3 -- tuning, brms prior refinement, full data run")

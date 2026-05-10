source("R/00_config.R")
source("R/03_model_spec.R")

# Quick out-of-sample evaluation of the full brms model on 2024.
# Run after 06_brms_full.R completes.
#
#   Rscript R/06b_brms_eval.R

cli_h1("brms out-of-sample evaluation -- 2024")

# ---- Load model -----------------------------------------------------------

checkpoint_file <- file.path(PATH_OUTPUT, "models", "brms_full_v2_checkpoint.rds")

if (!file.exists(checkpoint_file)) {
  cli_abort("brms model not found at {checkpoint_file}. Run 06_brms_full.R first.")
}

brms_fit_full <- readRDS(checkpoint_file)

# ---- Load 2024 data -------------------------------------------------------

player_rounds_base <- readRDS(file.path(PATH_DATA, "02_player_rounds.rds"))
form_features      <- readRDS(file.path(PATH_DATA, "02b_form_features.rds"))

player_rounds <- left_join(
  player_rounds_base,
  select(form_features, -event_completed),
  by = c("dg_id", "event_id", "year")
)

holdout_ids <- player_rounds |>
  filter(
    (year == 2025 & str_detect(event_name, regex("u\\.?s\\.? open", ignore_case = TRUE))) |
    (year == 2026 & str_detect(event_name, regex("masters",          ignore_case = TRUE)))
  ) |>
  mutate(key = paste(event_id, year)) |>
  pull(key) |>
  unique()

# Training data needed for imputation reference in prep_for_lme
train_data <- player_rounds |>
  filter(year <= 2023) |>
  filter(!paste(event_id, year) %in% holdout_ids)

sanity_data <- player_rounds |>
  filter(year == 2024) |>
  filter(!paste(event_id, year) %in% holdout_ids)

sanity_brms <- prep_for_lme(sanity_data, ref_df = train_data) |>
  mutate(player_season = factor(paste0(as.character(player_id), "_", year)))

cli_alert_info("2024 eval rows: {scales::comma(nrow(sanity_brms))}")

# ---- Predict --------------------------------------------------------------
# Use posterior mean (Estimate) as the point prediction.
# allow_new_levels = TRUE handles new player_seasons in 2024.

cli_alert_info("Generating posterior predictions (this takes a moment)...")

preds <- fitted(
  brms_fit_full,
  newdata          = sanity_brms,
  allow_new_levels = TRUE,
  re_formula       = NULL    # include all random effects
)[, "Estimate"]

brms_rmse <- yardstick::rmse_vec(
  truth    = sanity_brms$sg_residual,
  estimate = preds
)

# ---- Load GBDT RMSEs for comparison ---------------------------------------

gbdt_results_file <- file.path(PATH_OUTPUT, "models", "best_model.txt")

cli_h2("Full model comparison -- 2024 out-of-sample RMSE")

results <- tibble::tibble(
  model     = c("brms (full, player-season RE)"),
  rmse_2024 = brms_rmse
)

cli_alert_success("brms RMSE (2024, out-of-sample): {round(brms_rmse, 4)}")
cli_alert_info(
  "Compare against: XGBoost (tuned) 2.81, LightGBM (tuned) 2.81, lme4 (random slopes) — see 05_tune.R output"
)

print(results)

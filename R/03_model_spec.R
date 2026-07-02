# Model specifications for all four Tier 1 candidates.
# Source this file from 04_train_evaluate.R — not meant to run standalone.
#
# XGBoost, LightGBM: tidymodels workflows (tuning via tune_race_anova in Week 3)
# lme4, brms: direct model calls — random effects structure is cleaner outside
#             the parsnip abstraction layer
#
# Week 2: default hyperparameter specs (xgb_spec, lgbm_spec) used by 04_train_evaluate.R
# Week 3: tunable specs (xgb_spec_tune, lgbm_spec_tune) used by 05_tune.R

library(tidymodels)
library(bonsai)       # LightGBM parsnip engine
library(lme4)         # mixed-effects
library(brms)         # hierarchical Bayesian

tidymodels_prefer()

# ---- Shared recipe (GBDT models: XGBoost, LightGBM) ----------------------
# Random effects structure is not used here — course and player enter as
# dummy-encoded features for the tree models.

gbdt_recipe <- function(train_data) {
  recipe(
    sg_residual ~ player_skill_prior + player_skill_prior_decay +
      n_prior_rounds + course_fit_score +
      sg_ott_prior + sg_app_prior +
      sg_arg_prior + sg_putt_prior + wave + round_num + is_major +
      course_id + year +
      sg_r1 + sg_r2 + sg_r3 +
      sg_ott_r1 + sg_ott_r2 + sg_ott_r3 +
      sg_app_r1 + sg_app_r2 + sg_app_r3 +
      sg_arg_r1 + sg_arg_r2 + sg_arg_r3 +
      sg_putt_r1 + sg_putt_r2 + sg_putt_r3 +
      form_residual_mean_4  + form_residual_mean_8  +
      form_residual_mean_12 +
      form_residual_slope_4  + form_residual_slope_8  +
      form_residual_slope_12 + form_residual_slope_16 +
      form_ott_mean_8 + form_app_mean_8 + form_arg_mean_8 + form_putt_mean_8 + form_putt_sd_8 +
      wind_speed_tee + wind_dir_tee + temp_tee + precip_tee +
      weather_precision,
    data = train_data
  ) |>
    step_mutate(is_major = as.integer(is_major)) |>  # logical -> 0/1 for tree models
    step_mutate(
      slope_x_mean8        = form_residual_mean_8 * form_residual_slope_8,
      form_slope8_nonmajor = form_residual_slope_8 * (1L - is_major)
    ) |>
    step_impute_mean(all_numeric_predictors()) |>     # NAs in first-year priors / pre-coord events
    step_unknown(wave, weather_precision, new_level = "unknown") |>
    step_novel(course_id) |>
    step_dummy(all_nominal_predictors(), one_hot = TRUE)
}

# ---- XGBoost spec ---------------------------------------------------------
# Default hyperparameters for Week 2. tune_race_anova grid in Week 3.

xgb_spec <- boost_tree(
  trees      = 500,
  learn_rate = 0.05
) |>
  set_engine("xgboost", nthread = parallel::detectCores()) |>
  set_mode("regression")

# ---- LightGBM spec --------------------------------------------------------

lgbm_spec <- boost_tree(
  trees      = 500,
  learn_rate = 0.05
) |>
  set_engine("lightgbm", num_threads = parallel::detectCores()) |>
  set_mode("regression")

# ---- lme4 formula ---------------------------------------------------------
# Random intercepts for player and course.
# Random slope on form_residual_mean_8 | player_id: each player can respond
# differently to being in form — the simplified structural-break analog for lme4.

lmer_formula <- sg_residual ~ player_skill_prior + player_skill_prior_decay +
  n_prior_rounds + course_fit_score + sg_ott_prior + sg_app_prior +
  sg_arg_prior + sg_putt_prior + wave + round_num + is_major +
  sg_r1 + sg_r2 + sg_r3 +
  sg_ott_r1 + sg_ott_r2 + sg_ott_r3 +
  sg_app_r1 + sg_app_r2 + sg_app_r3 +
  sg_arg_r1 + sg_arg_r2 + sg_arg_r3 +
  sg_putt_r1 + sg_putt_r2 + sg_putt_r3 +
  form_ott_mean_8 + form_app_mean_8 + form_arg_mean_8 + form_putt_mean_8 + form_putt_sd_8 +
  form_residual_mean_4 + form_residual_mean_8 + form_residual_slope_8 +
  form_residual_mean_8:form_residual_slope_8 +
  wind_speed_tee + wind_dir_tee + temp_tee + precip_tee + weather_precision +
  (1 + form_residual_mean_8 | player_id) + (1 | course_id)

# ---- Tunable GBDT specs (used by 05_tune.R) --------------------------------
# tune() placeholders for tune_race_anova(). Do not use with fit() directly.

xgb_spec_tune <- boost_tree(
  trees       = tune(),
  tree_depth  = tune(),
  learn_rate  = tune(),
  min_n       = tune(),
  sample_size = tune()
) |>
  set_engine("xgboost", nthread = parallel::detectCores()) |>
  set_mode("regression")

lgbm_spec_tune <- boost_tree(
  trees       = tune(),
  tree_depth  = tune(),
  learn_rate  = tune(),
  min_n       = tune(),
  sample_size = tune()
) |>
  set_engine("lightgbm", num_threads = parallel::detectCores()) |>
  set_mode("regression")

# ---- brms formula + priors ------------------------------------------------
# Mirrors lme4 structure. Weakly informative priors — SG residuals are
# centred near 0 with SD ~2, so normal(0,1) on coefficients is conservative.
# Week 3: posterior predictive checks will guide prior refinement.

# Subsample formula (04_train_evaluate.R — structure validation only)
brms_formula <- bf(
  sg_residual ~ player_skill_prior + player_skill_prior_decay +
    n_prior_rounds + course_fit_score + sg_ott_prior + sg_app_prior +
    sg_arg_prior + sg_putt_prior + wave + round_num + is_major +
    sg_r1 + sg_r2 + sg_r3 +
    sg_ott_r1 + sg_ott_r2 + sg_ott_r3 +
    sg_app_r1 + sg_app_r2 + sg_app_r3 +
    sg_arg_r1 + sg_arg_r2 + sg_arg_r3 +
    sg_putt_r1 + sg_putt_r2 + sg_putt_r3 +
    form_residual_mean_4 + form_residual_mean_8 + form_residual_slope_8 +
    form_residual_mean_8:form_residual_slope_8 +
    form_ott_mean_8 + form_app_mean_8 + form_arg_mean_8 + form_putt_mean_8 + form_putt_sd_8 +
    wind_speed_tee + wind_dir_tee + temp_tee + precip_tee + weather_precision +
    (1 | player_id) + (1 | course_id)
)

# Full-data formula (06_brms_full.R) — adds player-season structural break.
# player_season = factor(paste(player_id, year)) — created in 06_brms_full.R.
# player_skill_prior dropped: coefficient was -0.99, signal fully absorbed by
# (1 | player_id) random effects. Keeping it degraded out-of-sample RMSE.
brms_formula_full <- bf(
  sg_residual ~ sg_ott_prior + sg_app_prior +
    sg_arg_prior + sg_putt_prior + wave + round_num + is_major +
    sg_r1 + sg_r2 + sg_r3 +
    sg_ott_r1 + sg_ott_r2 + sg_ott_r3 +
    sg_app_r1 + sg_app_r2 + sg_app_r3 +
    sg_arg_r1 + sg_arg_r2 + sg_arg_r3 +
    sg_putt_r1 + sg_putt_r2 + sg_putt_r3 +
    form_residual_mean_4 + form_residual_mean_8 + form_residual_slope_8 +
    form_residual_mean_8:form_residual_slope_8 +
    form_ott_mean_8 + form_app_mean_8 + form_arg_mean_8 + form_putt_mean_8 + form_putt_sd_8 +
    wind_speed_tee + wind_dir_tee + temp_tee + precip_tee + weather_precision +
    (1 | player_id) +        # population-level player intercept
    (1 | player_season) +    # structural break: per-player-year deviation
    (1 | course_id)
)

brms_priors <- c(
  prior(normal(0, 1),   class = b),
  prior(normal(0, 1),   class = Intercept),
  prior(exponential(1), class = sd),
  prior(exponential(1), class = sigma)
)

brms_ctrl <- list(
  chains  = 4,
  cores   = 4,          # parallel chains on M2
  iter    = 2000,
  warmup  = 500,
  backend = "cmdstanr", # faster compilation on ARM
  seed    = 42,
  control = list(adapt_delta = 0.9)
)

# ---- Helper: prep data for lme4 / brms ------------------------------------
# Imputes first-year skill prior NAs with training-set column means and
# coerces wave to factor. Pass ref_df = train_data when prepping test data
# so imputation uses training statistics only.

prep_for_lme <- function(df, ref_df = NULL) {
  if (is.null(ref_df)) ref_df <- df

  prior_cols <- c("player_skill_prior", "player_skill_prior_decay",
                  "n_prior_rounds", "course_fit_score",
                  "sg_ott_prior", "sg_app_prior",
                  "sg_arg_prior", "sg_putt_prior",
                  "form_residual_mean_4", "form_residual_mean_8", "form_residual_slope_8",
                  "sg_r1", "sg_r2", "sg_r3",
                  "sg_ott_r1", "sg_ott_r2", "sg_ott_r3",
                  "sg_app_r1", "sg_app_r2", "sg_app_r3",
                  "sg_arg_r1", "sg_arg_r2", "sg_arg_r3",
                  "sg_putt_r1", "sg_putt_r2", "sg_putt_r3",
                  "form_ott_mean_8", "form_app_mean_8",
                  "form_arg_mean_8", "form_putt_mean_8", "form_putt_sd_8",
                  "wind_speed_tee", "wind_dir_tee", "temp_tee", "precip_tee")

  for (col in prior_cols) {
    fill_val  <- mean(ref_df[[col]], na.rm = TRUE)
    df[[col]] <- replace(df[[col]], is.na(df[[col]]), fill_val)
  }

  df |>
    mutate(
      wave              = factor(replace_na(as.character(wave),              "unknown")),
      weather_precision = factor(replace_na(as.character(weather_precision), "unknown")),
      player_id         = factor(player_id),
      course_id         = factor(course_id)
    )
}

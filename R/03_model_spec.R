# Model specifications for all four Tier 1 candidates.
# Source this file from 04_train_evaluate.R — not meant to run standalone.
#
# XGBoost, LightGBM: tidymodels workflows (tuning via tune_race_anova in Week 3)
# lme4, brms: direct model calls — random effects structure is cleaner outside
#             the parsnip abstraction layer
#
# Week 2: all default hyperparameters. Tuning is Week 3.

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
    sg_residual ~ player_skill_prior + sg_ott_prior + sg_app_prior +
      sg_arg_prior + sg_putt_prior + wave + round_num + is_major +
      course_id + year,
    data = train_data
  ) |>
    step_mutate(is_major = as.integer(is_major)) |>  # logical -> 0/1 for tree models
    step_impute_mean(all_numeric_predictors()) |>     # NAs in first-year priors
    step_unknown(wave, new_level = "unknown") |>
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
# Random intercepts for player and course — the minimal two-level structure.
# Week 3 sensitivity: add random slopes for round_num and is_major.

lmer_formula <- sg_residual ~ player_skill_prior + sg_ott_prior + sg_app_prior +
  sg_arg_prior + sg_putt_prior + wave + round_num + is_major +
  (1 | player_id) + (1 | course_id)

# ---- brms formula + priors ------------------------------------------------
# Mirrors lme4 structure. Weakly informative priors — SG residuals are
# centred near 0 with SD ~2, so normal(0,1) on coefficients is conservative.
# Week 3: posterior predictive checks will guide prior refinement.

brms_formula <- bf(
  sg_residual ~ player_skill_prior + sg_ott_prior + sg_app_prior +
    sg_arg_prior + sg_putt_prior + wave + round_num + is_major +
    (1 | player_id) + (1 | course_id)
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

  prior_cols <- c("player_skill_prior", "sg_ott_prior", "sg_app_prior",
                  "sg_arg_prior", "sg_putt_prior")

  for (col in prior_cols) {
    fill_val  <- mean(ref_df[[col]], na.rm = TRUE)
    df[[col]] <- replace(df[[col]], is.na(df[[col]]), fill_val)
  }

  df |>
    mutate(
      wave      = factor(replace_na(as.character(wave), "unknown")),
      player_id = factor(player_id),
      course_id = factor(course_id)
    )
}

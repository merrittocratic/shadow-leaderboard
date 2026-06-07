source("R/00_config.R")

# Diagnostic: why is the gbdt_pred coefficient in brms_stack.rds ~0.50
# when the prior is N(1, 0.3)?
#
# Two competing hypotheses:
#   (A) OOF predictions are mis-scaled — early sliding-window folds (val_2019
#       trained on 2010-2018 only) are too noisy, dragging the slope down.
#   (B) Random effects in the stack are stealing variance from gbdt_pred —
#       most likely (1|course_id), since course_id is already a GBDT feature.
#
# This script runs five fast tests using the saved brms_stack.rds + lme4.
# No brms refit needed. ~1 minute total.
#
#   Rscript R/diagnose_stack_calibration.R

library(lme4)

cli_h1("brms_stack calibration diagnostic")

# ---- Load stack training frame from saved brms fit ------------------------

stack_file <- file.path(PATH_OUTPUT, "models", "brms_stack.rds")
if (!file.exists(stack_file)) {
  cli_abort("brms_stack.rds not found at {stack_file}.")
}
brms_stack <- readRDS(stack_file)

df <- brms_stack$data |>
  mutate(
    player_id     = factor(player_id),
    player_season = factor(player_season),
    course_id     = factor(course_id),
    year          = as.integer(as.character(player_season)
                              |> stringr::str_extract("\\d{4}$"))
  )

cli_alert_info("Stack training rows: {scales::comma(nrow(df))}")
cli_alert_info("Year range: {min(df$year)}-{max(df$year)}")

# ---- 1. Variance + correlation -------------------------------------------

cli_h2("1. Variance + correlation")

var_pred <- var(df$gbdt_pred)
var_y    <- var(df$sg_residual)
cor_xy   <- cor(df$gbdt_pred, df$sg_residual)
ols_ub   <- cor_xy * sqrt(var_y / var_pred)

cli_alert_info(glue::glue(
  "var(gbdt_pred) = {round(var_pred, 3)} | ",
  "var(sg_residual) = {round(var_y, 3)} | ",
  "cor = {round(cor_xy, 3)}"
))
cli_alert_info(glue::glue(
  "Implied naive OLS slope = cor * sd(y)/sd(x) = {round(ols_ub, 3)}"
))
cli_alert_info(
  "If implied slope is already ~0.5, the GBDT predictions are over-dispersed ",
  "relative to the target — the stack can't help."
)

# ---- 2. Naive OLS — no random effects ------------------------------------

cli_h2("2. Naive OLS — no random effects")

fit_naive <- lm(sg_residual ~ gbdt_pred, data = df)
print(round(coef(summary(fit_naive)), 4))

# ---- 3. OLS + year fixed effect ------------------------------------------

cli_h2("3. OLS + year fixed effect")

fit_year <- lm(sg_residual ~ gbdt_pred + factor(year), data = df)
cli_alert_info(glue::glue(
  "gbdt_pred coef (with year FE): ",
  "{round(coef(fit_year)['gbdt_pred'], 3)}"
))
cli_alert_info(
  "If this is ~1.0 but naive is ~0.5, early folds are noisier (year-level shift)."
)

# ---- 4. By-fold (val_year) breakdown -------------------------------------

cli_h2("4. By-fold breakdown")

by_year <- df |>
  group_by(year) |>
  summarise(
    n         = n(),
    cor       = round(cor(gbdt_pred, sg_residual), 3),
    ols_slope = round(coef(lm(sg_residual ~ gbdt_pred))[[2L]], 3),
    var_pred  = round(var(gbdt_pred), 3),
    var_y     = round(var(sg_residual), 3),
    ratio     = round(var(gbdt_pred) / var(sg_residual), 3),
    .groups   = "drop"
  )
print(by_year)

cli_alert_info(
  "If val_2019 has dramatically lower slope/cor than val_2023, ",
  "sliding-window training set size is the issue."
)

# ---- 5. lme4 ablation across RE structures -------------------------------

cli_h2("5. lme4 RE ablation — which RE is stealing variance?")

specs <- list(
  "naive_OLS"                          = sg_residual ~ gbdt_pred,
  "+ (1|player_id)"                    = sg_residual ~ gbdt_pred + (1 | player_id),
  "+ (1|player_season)"                = sg_residual ~ gbdt_pred + (1 | player_season),
  "+ (1|course_id)"                    = sg_residual ~ gbdt_pred + (1 | course_id),
  "+ player + course"                  = sg_residual ~ gbdt_pred + (1 | player_id) + (1 | course_id),
  "+ player + player_season"           = sg_residual ~ gbdt_pred + (1 | player_id) + (1 | player_season),
  "+ course + player_season"           = sg_residual ~ gbdt_pred + (1 | course_id) + (1 | player_season),
  "+ player + course + player_season"  = sg_residual ~ gbdt_pred + (1 | player_id) + (1 | course_id) + (1 | player_season)
)

fit_spec <- function(f, name) {
  if (name == "naive_OLS") {
    fit  <- lm(f, data = df)
    beta <- coef(fit)[["gbdt_pred"]]
    sig  <- summary(fit)$sigma
    return(tibble(spec = name, gbdt_beta = round(beta, 3),
                  sigma = round(sig, 3), re_sds = ""))
  }
  fit  <- lmer(f, data = df, REML = TRUE)
  vc   <- VarCorr(fit)
  beta <- fixef(fit)[["gbdt_pred"]]
  sig  <- attr(vc, "sc")
  sds  <- sapply(vc, function(x) sqrt(unname(x[1L])))
  tibble(
    spec      = name,
    gbdt_beta = round(beta, 3),
    sigma     = round(sig, 3),
    re_sds    = paste0(names(sds), "=", round(sds, 3), collapse = ", ")
  )
}

results <- purrr::imap_dfr(specs, fit_spec)
print(results, n = Inf)

cli_alert_info(
  "Interpretation: the RE structure where gbdt_beta is closest to 1.0 ",
  "is what the brms stack should mirror."
)
cli_alert_info(
  "Watch for: a single RE that drops gbdt_beta by >0.3 vs. naive OLS ",
  "— that's the variance thief."
)

cli_h1("Diagnostic complete")

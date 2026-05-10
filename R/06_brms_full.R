source("R/00_config.R")
source("R/03_model_spec.R")

# Full-data brms run with player-season structural break.
# Designed to run overnight. Uses cmdstanr file-based checkpointing so the
# run can be safely interrupted and resumed.
#
# On M2 with cmdstanr: 4 parallel chains, ~4-8 hours on full training set.
#
#   Rscript R/06_brms_full.R

cli_h1("brms full-data run (player-season structural break)")

# ---- Load data ------------------------------------------------------------

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

train_data <- player_rounds |>
  filter(year <= 2023) |>
  filter(!paste(event_id, year) %in% holdout_ids) |>
  prep_for_lme() |>
  mutate(
    # player_season: unique ID for each player × year segment
    # This is the structural break grouping variable
    player_season = factor(paste0(as.character(player_id), "_", year))
  )

cli_alert_info("Training rows: {scales::comma(nrow(train_data))}")
cli_alert_info("Unique player-seasons: {n_distinct(train_data$player_season)}")

# ---- Refined priors -------------------------------------------------------
# Informed by Week 2 pp_check. SG residuals have SD ~2-3, so:
# - Fixed effects: normal(0, 1) is still appropriate (predictors are ~unit scale)
# - Player intercept SD: half-normal(0, 1) — most players cluster near mean
# - Player-season SD: half-normal(0, 0.5) — season deviations smaller than
#   career-level variation; if structural breaks are rare, this shrinks hard
# - Course SD: half-normal(0, 0.5)
# - Residual sigma: exponential(1)

brms_priors_full <- c(
  prior(normal(0, 1),   class = b),
  prior(normal(0, 1),   class = Intercept),
  prior(normal(0, 1),   class = sd, group = player_id),     # sd > 0, so effectively half-normal
  prior(normal(0, 0.5), class = sd, group = player_season), # tighter: season deviations < career
  prior(normal(0, 0.5), class = sd, group = course_id),
  prior(exponential(1), class = sigma)
)

# ---- Checkpointing --------------------------------------------------------
# brms saves MCMC progress to a file. If the run is interrupted, re-running
# this script with the same file path will resume from the checkpoint.

checkpoint_dir  <- file.path(PATH_OUTPUT, "models")
checkpoint_file <- file.path(checkpoint_dir, "brms_full_v2_checkpoint")
dir.create(checkpoint_dir, recursive = TRUE, showWarnings = FALSE)

cli_alert_info("Checkpoint file: {checkpoint_file}")
cli_alert_info(
  "Estimated runtime: 4-8 hours on M2. Run overnight or in background."
)

# ---- Fit ------------------------------------------------------------------

options(mc.cores = 4)

brms_fit_full <- brm(
  formula  = brms_formula_full,
  data     = train_data,
  prior    = brms_priors_full,
  chains   = 4,
  cores    = 4,
  iter     = 4000,
  warmup   = 1000,
  backend  = "cmdstanr",
  seed     = 42,
  file     = checkpoint_file,   # saves + resumes from this path
  control  = list(adapt_delta = 0.92, max_treedepth = 12)
)

# ---- Posterior predictive check -------------------------------------------

pp_plot <- pp_check(brms_fit_full, ndraws = 100) +
  ggplot2::labs(
    title    = "brms full-data: posterior predictive check",
    subtitle = glue::glue(
      "Full training set ({scales::comma(nrow(train_data))} rows), ",
      "player-season structural break"
    )
  ) +
  ggplot2::theme_minimal()

ggplot2::ggsave(
  file.path(PATH_GRAPHICS, "brms_pp_check_full.png"),
  pp_plot, width = 8, height = 5, dpi = 150
)

# ---- Summary --------------------------------------------------------------

cli_h2("Model summary")
summary(brms_fit_full)

cli_alert_success("brms full-data run complete")
cli_alert_info("Model saved to {checkpoint_file}.rds")
cli_alert_info("Use in Week 4 validation: readRDS('{checkpoint_file}.rds')")

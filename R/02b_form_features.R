source("R/00_config.R")

# Compute form features (a) and (b) for all candidate lookback windows.
# Must run after 02_feature_engineering.R.
#
# Output: data/02b_form_features.rds
#   One row per player-event. Join to player_rounds on (dg_id, event_id, year).
#
# Cache: data/cache/form/form_features_N{N}.rds — one file per N value.
#   Re-run is idempotent; cached N values are skipped.
#
#   Rscript R/02b_form_features.R

library(slider)
library(glue)

source("tests/test_form_features.R")

N_CANDIDATES <- c(4L, 8L, 12L, 16L)

cli_h1("Form feature engineering (features a + b)")

# ---- 1. Load player-round data and aggregate to event level ---------------
# One row per player-event. Missed cuts contribute their completed rounds.

cli_h2("Aggregating to event level")

player_rounds <- readRDS(file.path(PATH_DATA, "02_player_rounds.rds"))

event_sg <- player_rounds |>
  group_by(dg_id, event_id, year, event_completed) |>
  summarise(
    event_sg_mean      = mean(sg_total, na.rm = TRUE),
    # player_skill_prior is constant within player-year; take first non-NA
    player_skill_prior = first(na.omit(player_skill_prior)),
    n_rounds           = n(),
    .groups            = "drop"
  ) |>
  mutate(
    # The residual the form features are built on:
    # how much did the player outperform their skill prior at this event?
    event_residual = event_sg_mean - player_skill_prior
  ) |>
  arrange(dg_id, event_completed)

cli_alert_success(
  "Event-level table: {scales::comma(nrow(event_sg))} player-events | ",
  "{n_distinct(event_sg$dg_id)} players"
)

na_resid_pct <- round(mean(is.na(event_sg$event_residual)) * 100, 1)
cli_alert_info(
  "event_residual NA rate: {na_resid_pct}% ",
  "(first-year players have no skill prior)"
)

# ---- 2. Slope helper -------------------------------------------------------
# OLS slope via sufficient statistics — faster than lm() inside a slide window.

.slope <- function(x) {
  x <- x[!is.na(x)]
  n <- length(x)
  if (n < 2L) return(NA_real_)
  t      <- seq_len(n)
  t_mean <- mean(t)
  x_mean <- mean(x)
  sum((t - t_mean) * (x - x_mean)) / sum((t - t_mean)^2)
}

# ---- 3. Compute form features for each N ----------------------------------

cache_dir <- file.path(PATH_CACHE, "form")
if (!dir.exists(cache_dir)) dir.create(cache_dir, recursive = TRUE)

form_list <- vector("list", length(N_CANDIDATES))
names(form_list) <- as.character(N_CANDIDATES)

for (N in N_CANDIDATES) {
  cache_file <- file.path(cache_dir, paste0("form_features_N", N, ".rds"))

  if (file.exists(cache_file)) {
    cli_alert_info("N={N}: cache hit -- loading")
    form_list[[as.character(N)]] <- readRDS(cache_file)
    next
  }

  cli_alert_info("N={N}: computing...")

  feat <- event_sg |>
    group_by(dg_id) |>
    mutate(
      # .after = -1L excludes the current event — strictly point-in-time
      # .complete = FALSE allows shorter windows for early-career players
      !!paste0("form_residual_mean_",  N) := slide_dbl(
        event_residual,
        ~ mean(.x, na.rm = TRUE),
        .before    = N,
        .after     = -1L,
        .complete  = FALSE
      ),
      !!paste0("form_residual_slope_", N) := slide_dbl(
        event_residual,
        .slope,
        .before    = N,
        .after     = -1L,
        .complete  = FALSE
      )
    ) |>
    ungroup() |>
    select(dg_id, event_id, year, event_completed,
           starts_with(paste0("form_residual_mean_",  N)),
           starts_with(paste0("form_residual_slope_", N)))

  # Replace NaN (empty window → mean of nothing) with NA
  feat <- feat |>
    mutate(across(starts_with("form_residual"), ~ if_else(is.nan(.x), NA_real_, .x)))

  saveRDS(feat, cache_file)
  cli_alert_success("N={N}: done, cached")
  form_list[[as.character(N)]] <- feat
}

# ---- 4. Join all N tables -------------------------------------------------

cli_h2("Joining N tables")

form_features <- form_list[[1]]
for (N in N_CANDIDATES[-1]) {
  form_features <- left_join(
    form_features,
    select(form_list[[as.character(N)]], -event_completed),
    by = c("dg_id", "event_id", "year")
  )
}

cli_alert_success(
  "form_features: {nrow(form_features)} rows x {ncol(form_features)} cols"
)

# ---- 5. Leakage unit test -------------------------------------------------
# Hard abort on failure — do not proceed to save if the test fails.

cli_h2("Running leakage unit test")

# Test against N=8 (middle of the range, good coverage)
test_form_leakage(form_features, event_sg, N = 8L, n_checks = 50L)

# ---- 6. Save --------------------------------------------------------------

out_file <- file.path(PATH_DATA, "02b_form_features.rds")
saveRDS(form_features, out_file)

col_summary <- form_features |>
  summarise(across(starts_with("form_residual"), ~ mean(is.na(.x)))) |>
  pivot_longer(everything(), names_to = "feature", values_to = "na_rate") |>
  mutate(na_rate = scales::percent(na_rate, accuracy = 0.1))

cli_alert_success("Saved to {out_file}")
cli_alert_info("NA rates by feature (expected for early-career players):")
print(col_summary, n = Inf)

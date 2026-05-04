source("R/00_config.R")

# Flatten the cached per-year DataGolf JSON into a tidy player-round table,
# compute features and the Week 2 baseline residual target.
#
# Target (Week 2 baseline):
#   sg_residual = sg_total - field_mean_sg  (within event × round stratum)
#   Week 3 replaces this with the proper player × conditions joint baseline.
#
# Run directly — no API key required:
#   Rscript R/02_feature_engineering.R

library(purrr)

cli_h1("Feature engineering")

# ---- 1. Flatten nested per-year caches ------------------------------------
# Each cached RDS is a list of events. Each event$scores is a data frame
# where round_1..round_4 are nested data frame columns (25 cols each) and
# dg_id / player_name / fin_text are player-level columns.

flatten_event <- function(event) {
  scores <- event$scores

  round_cols  <- intersect(paste0("round_", 1:4), names(scores))
  player_cols <- setdiff(names(scores), paste0("round_", 1:4))
  player_info <- as_tibble(scores[, player_cols, drop = FALSE])

  map_dfr(seq_along(round_cols), function(i) {
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
      filter(!is.na(sg_total))  # drop rounds player didn't play (WD / post-cut)
  })
}

years <- seq(TRAIN_YEAR_START, TRAIN_YEAR_END)
cli_h2("Loading and flattening {length(years)} years")

player_rounds_raw <- map_dfr(years, function(yr) {
  cache_file <- file.path(PATH_CACHE, "historical_raw", paste0("pga_", yr, ".rds"))
  if (!file.exists(cache_file)) {
    cli_alert_warning("No cache for {yr} -- skipping")
    return(NULL)
  }
  year_data <- readRDS(cache_file)
  cli_alert_info("{yr}: {length(year_data)} events")
  map_dfr(year_data, flatten_event)
})

cli_alert_success(
  "Flattened: {scales::comma(nrow(player_rounds_raw))} player-rounds | ",
  "{n_distinct(player_rounds_raw$dg_id)} players | ",
  "{n_distinct(paste(player_rounds_raw$event_id, player_rounds_raw$year))} event-years"
)

# ---- 2. Feature computation -----------------------------------------------

cli_h2("Computing features")

player_rounds <- player_rounds_raw |>
  mutate(
    # AM / PM wave from tee time string ("7:15am", "1:35pm")
    wave = case_when(
      str_detect(teetime, stringr::fixed("am")) ~ "AM",
      str_detect(teetime, stringr::fixed("pm")) ~ "PM",
      TRUE                             ~ NA_character_
    ) |> factor(),

    # Major flag (The Players is elite but not a major)
    is_major = event_name %in% c(
      "Masters Tournament", "U.S. Open",
      "The Open Championship", "PGA Championship"
    ),

    # Stable factor IDs for random effects
    player_id = factor(dg_id),
    course_id = factor(course_num),

    round_num = as.integer(round_num)
  )

# ---- 3. Player skill priors -----------------------------------------------
# Year-level expanding mean, leave-current-year-out.
# For a player's first year the prior is NA — imputed in model recipes.

cli_h2("Computing player skill priors")

year_sg_means <- player_rounds |>
  group_by(dg_id, year) |>
  summarise(
    sg_total_yr = mean(sg_total, na.rm = TRUE),
    sg_ott_yr   = mean(sg_ott,   na.rm = TRUE),
    sg_app_yr   = mean(sg_app,   na.rm = TRUE),
    sg_arg_yr   = mean(sg_arg,   na.rm = TRUE),
    sg_putt_yr  = mean(sg_putt,  na.rm = TRUE),
    .groups     = "drop"
  ) |>
  arrange(dg_id, year)

skill_priors <- year_sg_means |>
  group_by(dg_id) |>
  mutate(
    # cummean up through year t-1 via lag — expanding window, no leakage
    player_skill_prior = dplyr::lag(cummean(sg_total_yr)),
    sg_ott_prior       = dplyr::lag(cummean(sg_ott_yr)),
    sg_app_prior       = dplyr::lag(cummean(sg_app_yr)),
    sg_arg_prior       = dplyr::lag(cummean(sg_arg_yr)),
    sg_putt_prior      = dplyr::lag(cummean(sg_putt_yr))
  ) |>
  ungroup() |>
  select(dg_id, year,
         player_skill_prior, sg_ott_prior, sg_app_prior,
         sg_arg_prior, sg_putt_prior)

player_rounds <- player_rounds |>
  left_join(skill_priors, by = c("dg_id", "year"))

# ---- 4. Target: field-average SG residual ---------------------------------
# Residual vs. field mean within each event × round stratum.
# This is the Week 2 baseline; Week 3 refines to player × conditions baseline.

player_rounds <- player_rounds |>
  group_by(event_id, year, round_num) |>
  mutate(
    field_mean_sg = mean(sg_total, na.rm = TRUE),
    sg_residual   = sg_total - field_mean_sg
  ) |>
  ungroup()

# ---- 5. Data quality checks -----------------------------------------------

cli_h2("Data quality checks")

sg_range <- range(player_rounds$sg_total, na.rm = TRUE)
cli_alert_info("sg_total range: [{round(sg_range[1], 2)}, {round(sg_range[2], 2)}]")

n_extreme <- sum(abs(player_rounds$sg_total) > 15, na.rm = TRUE)
if (n_extreme > 0) {
  cli_alert_warning("{n_extreme} rows with |sg_total| > 15 -- inspect before modeling")
} else {
  cli_alert_success("No extreme sg_total values (> 15)")
}

na_prior_pct <- round(mean(is.na(player_rounds$player_skill_prior)) * 100, 1)
cli_alert_info(
  "player_skill_prior NA rate: {na_prior_pct}% ",
  "(expected ~{round(1 / length(years) * 100, 0)}% for first-year players)"
)

events_per_year <- player_rounds |>
  distinct(year, event_id) |>
  count(year, name = "n_events")
cli_alert_info("Events per year (spot check first/last 3):")
print(slice(events_per_year, c(1:3, (nrow(events_per_year) - 2):nrow(events_per_year))))

# ---- 6. Save --------------------------------------------------------------

out_file <- file.path(PATH_DATA, "02_player_rounds.rds")
saveRDS(player_rounds, out_file)

cli_alert_success("Saved {scales::comma(nrow(player_rounds))} rows to {out_file}")
cli_alert_info("Columns: {paste(names(player_rounds), collapse = ', ')}")

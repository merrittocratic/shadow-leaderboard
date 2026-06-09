source("R/00_config.R")
source("R/datagolf_api.R")

# Pull LIV Golf historical raw data for every year since the inaugural season.
# Designed to be re-run: already-cached years are skipped.
# Raw JSON preserved as data/cache/historical_raw/liv_YYYY.rds.
#
#   op run --env-file=.env.template -- Rscript R/01b_pull_liv.R

LIV_YEAR_START <- 2022L   # LIV Golf inaugural season
LIV_YEAR_END   <- TRAIN_YEAR_END

years <- seq(LIV_YEAR_START, LIV_YEAR_END)

cli_h1("LIV Golf historical data pull {LIV_YEAR_START}--{LIV_YEAR_END}")
cli_alert_info("{length(years)} years to check")

for (yr in years) {
  cache_file <- file.path(PATH_CACHE, "historical_raw", paste0("liv_", yr, ".rds"))

  if (file.exists(cache_file)) {
    cli_alert_info("  {yr}: already cached -- skipping")
    next
  }

  cli_alert_info("  {yr}: fetching...")
  tryCatch({
    data <- dg_historical_raw(tour = "liv", year = yr, force_refresh = TRUE)
    cli_alert_success("  {yr}: {length(data)} events")
  }, error = function(e) {
    cli_alert_warning("  {yr}: FAILED -- {conditionMessage(e)}")
  })
  Sys.sleep(3)
}

cli_h2("Pull complete")

cached_files <- list.files(
  file.path(PATH_CACHE, "historical_raw"),
  pattern = "^liv_\\d{4}\\.rds$",
  full.names = FALSE
)
cached_years <- sort(as.integer(sub("liv_(\\d{4})\\.rds", "\\1", cached_files)))
cli_alert_success("LIV cached years: {paste(cached_years, collapse = ', ')}")

# Spot-check: show events and player count for most recent cached year
if (length(cached_years) > 0) {
  yr_check   <- max(cached_years)
  check_data <- readRDS(file.path(PATH_CACHE, "historical_raw",
                                  paste0("liv_", yr_check, ".rds")))
  cli_alert_info("{yr_check}: {length(check_data)} events")
  for (ev in check_data) cli_alert_info("  {ev$event_name}")
}

source("R/00_config.R")
source("R/datagolf_api.R")

# Pull PGA Tour historical raw data for every year in the training window.
# Designed to be re-run: already-cached years are skipped.
# Raw JSON is preserved as .rds in data/cache/historical_raw/ before any
# transformation. Run this script via op run so GOLF_API_KEY is injected:
#
#   op run --env-file=.env.template -- Rscript R/01_pull_historical.R

# Retry a call up to max_tries times, backing off on 429
.fetch_with_retry <- function(expr, yr, max_tries = 5) {
  wait <- 5  # seconds; doubles on each 429
  for (attempt in seq_len(max_tries)) {
    result <- tryCatch(
      list(ok = TRUE, value = expr),
      error = function(e) list(ok = FALSE, msg = conditionMessage(e))
    )
    if (result$ok) return(result$value)
    if (grepl("429", result$msg)) {
      cli_alert_warning("  {yr}: rate limited (attempt {attempt}/{max_tries}), waiting {wait}s...")
      Sys.sleep(wait)
      wait <- wait * 2
    } else {
      cli_abort(result$msg)
    }
  }
  cli_abort("  {yr}: gave up after {max_tries} attempts")
}

years <- seq(TRAIN_YEAR_START, TRAIN_YEAR_END)

cli_h1("Historical raw data pull — PGA Tour {TRAIN_YEAR_START}--{TRAIN_YEAR_END}")
cli_alert_info("{length(years)} years to check")

for (yr in years) {
  key        <- paste0("pga_", yr)
  cache_file <- file.path(PATH_CACHE, "historical_raw", paste0(key, ".rds"))

  if (file.exists(cache_file)) {
    cli_alert_info("  {yr}: already cached -- skipping")
    next
  }

  cli_alert_info("  {yr}: fetching...")

  tryCatch(
    {
      data <- .fetch_with_retry(dg_historical_raw(tour = "pga", year = yr), yr)
      cli_alert_success("  {yr}: done")
    },
    error = function(e) {
      cli_alert_warning("  {yr}: FAILED -- {conditionMessage(e)}")
    }
  )

  # Pause between successful fetches to stay well under rate limits
  Sys.sleep(3)
}

cli_h2("Pull complete")

# Summarise what we have on disk
cached_files <- list.files(
  file.path(PATH_CACHE, "historical_raw"),
  pattern = "^pga_\\d{4}\\.rds$",
  full.names = FALSE
)
cached_years  <- sort(as.integer(sub("pga_(\\d{4})\\.rds", "\\1", cached_files)))
missing_years <- setdiff(years, cached_years)
missing_str   <- if (length(missing_years) == 0) "none" else paste(missing_years, collapse = ", ")

cli_alert_success("Cached years:  {paste(cached_years, collapse = ', ')}")
cli_alert_info(   "Missing years: {missing_str}")

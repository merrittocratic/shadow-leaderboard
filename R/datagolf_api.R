# DataGolf API wrapper
# Source this file after 00_config.R. All functions check the on-disk cache
# before hitting the API. Cache lives at data/cache/{endpoint}/{key}.rds.
#
# Usage:
#   source("R/00_config.R")
#   source("R/datagolf_api.R")
#   df <- dg_historical_raw(tour = "pga", year = 2023)

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

.dg_cache_path <- function(endpoint, key) {
  dir <- file.path(PATH_CACHE, endpoint)
  if (!dir.exists(dir)) dir.create(dir, recursive = TRUE)
  file.path(dir, paste0(key, ".rds"))
}

.dg_get <- function(path, params = list()) {
  # Always inject the API key; caller supplies everything else
  params[["key"]] <- DG_API_KEY

  req <- request(DG_BASE_URL) |>
    req_url_path_append(path) |>
    req_url_query(!!!params) |>
    req_error(is_error = \(resp) FALSE)  # handle errors explicitly below

  resp <- req_perform(req)

  if (resp_status(resp) != 200L) {
    cli_abort(c(
      "DataGolf API returned HTTP {resp_status(resp)}.",
      "i" = "Path: {path}",
      "i" = "Params: {paste(names(params), params, sep = '=', collapse = ', ')}"
    ))
  }

  resp_body_json(resp, simplifyVector = TRUE)
}

.dg_read_cache <- function(cache_file) {
  readRDS(cache_file)
}

.dg_write_cache <- function(data, cache_file) {
  saveRDS(data, cache_file)
  invisible(data)
}

# ---------------------------------------------------------------------------
# Public functions
# ---------------------------------------------------------------------------

#' Historical raw strokes-gained data
#'
#' @param tour  Tour code. Default "pga".
#' @param year  Integer year.
#' @param event_id  Event filter. "all" returns every event in the year (default).
#'   Pass a specific DataGolf event_id string to fetch a single event.
#' @param force_refresh  If TRUE, bypass cache and re-fetch.
#'
#' @return Data frame of player-rounds.
dg_historical_raw <- function(tour = "pga", year, event_id = "all", force_refresh = FALSE) {
  key <- paste0(tour, "_", year, if (event_id != "all") paste0("_", event_id) else "")
  cache_file <- .dg_cache_path("historical_raw", key)

  if (!force_refresh && file.exists(cache_file)) {
    cli_alert_info("Cache hit: historical_raw/{key}")
    return(.dg_read_cache(cache_file))
  }

  cli_alert_info("Fetching historical_raw: tour={tour} year={year} event_id={event_id}")

  params <- list(tour = tour, event_id = event_id, year = year, file_format = "json")

  data <- .dg_get("historical-raw-data/rounds", params)

  .dg_write_cache(data, cache_file)
  cli_alert_success("Cached: historical_raw/{key}")
  data
}

#' Pre-tournament model predictions
#'
#' @param tour  Tour code. Default "pga".
#' @param odds_format  "percent", "american", or "decimal". Default "percent".
#' @param force_refresh  If TRUE, bypass cache.
#'
#' @return Data frame of player predictions for the current/next event.
dg_model_predictions <- function(tour = "pga", odds_format = "percent", force_refresh = FALSE) {
  key <- paste0(tour, "_", odds_format, "_", format(Sys.Date(), "%Y%m%d"))
  cache_file <- .dg_cache_path("model_predictions", key)

  if (!force_refresh && file.exists(cache_file)) {
    cli_alert_info("Cache hit: model_predictions/{key}")
    return(.dg_read_cache(cache_file))
  }

  cli_alert_info("Fetching model_predictions: tour={tour}")

  data <- .dg_get(
    "preds/pre-tournament",
    list(tour = tour, odds_format = odds_format, file_format = "json")
  )

  .dg_write_cache(data, cache_file)
  cli_alert_success("Cached: model_predictions/{key}")
  data
}

#' Field and tee times for the current event
#'
#' @param tour  Tour code. Default "pga".
#' @param force_refresh  If TRUE, bypass cache.
#'
#' @return Data frame with player, tee time, and round info.
dg_field_tee_times <- function(tour = "pga", force_refresh = FALSE) {
  key <- paste0(tour, "_", format(Sys.Date(), "%Y%m%d"))
  cache_file <- .dg_cache_path("field_tee_times", key)

  if (!force_refresh && file.exists(cache_file)) {
    cli_alert_info("Cache hit: field_tee_times/{key}")
    return(.dg_read_cache(cache_file))
  }

  cli_alert_info("Fetching field_tee_times: tour={tour}")

  data <- .dg_get(
    "field-updates",
    list(tour = tour, file_format = "json")
  )

  .dg_write_cache(data, cache_file)
  cli_alert_success("Cached: field_tee_times/{key}")
  data
}

#' Historical event-level strokes-gained stats
#'
#' @param tour  Tour code. Default "pga".
#' @param year  Integer year.
#' @param event_id  Specific DataGolf event_id string. Required by the API.
#' @param force_refresh  If TRUE, bypass cache.
#'
#' @return Data frame of per-player event stats.
dg_historical_event_stats <- function(tour = "pga", year, event_id, force_refresh = FALSE) {
  key <- paste0(tour, "_", year, "_", event_id)
  cache_file <- .dg_cache_path("historical_event_stats", key)

  if (!force_refresh && file.exists(cache_file)) {
    cli_alert_info("Cache hit: historical_event_stats/{key}")
    return(.dg_read_cache(cache_file))
  }

  cli_alert_info("Fetching historical_event_stats: tour={tour} year={year} event_id={event_id}")

  params <- list(tour = tour, event_id = event_id, year = year, file_format = "json")

  data <- .dg_get("historical-event-data/events", params)

  .dg_write_cache(data, cache_file)
  cli_alert_success("Cached: historical_event_stats/{key}")
  data
}

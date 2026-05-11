# DataGolf API wrapper
# Source this file after 00_config.R. All functions check the on-disk cache
# before hitting the API. Cache lives at data/cache/{endpoint}/{key}.rds.
#
# Usage:
#   source("R/00_config.R")
#   source("R/datagolf_api.R")
#   df <- dg_historical_raw(tour = "pga", year = 2023)

# Validate API key on source — only scripts that source datagolf_api.R need it
if (nchar(DG_API_KEY) == 0) {
  cli_abort(c(
    "GOLF_API_KEY is not set.",
    "i" = "Run via: op run --env-file=.env.template -- Rscript R/<script>.R"
  ))
}

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

#' Live tournament strokes-gained (current event in progress)
#'
#' Returns cumulative SG by category for all players in the current event.
#' Cache key is per-hour so re-runs within the same hour hit cache; pass
#' force_refresh = TRUE for the freshest data during a live round.
#'
#' @param sg  Comma-separated SG stats to return.
#' @param force_refresh  If TRUE, bypass cache.
#'
#' @return List with tournament metadata and a data frame of player SG.
dg_live_strokes_gained <- function(
    sg            = "sg_putt,sg_arg,sg_app,sg_ott,sg_t2g,sg_total",
    force_refresh = FALSE) {
  key        <- paste0("live_sg_", format(Sys.time(), "%Y%m%d_%H"))
  cache_file <- .dg_cache_path("live_sg", key)

  if (!force_refresh && file.exists(cache_file)) {
    cli_alert_info("Cache hit: live_sg/{key}")
    return(.dg_read_cache(cache_file))
  }

  cli_alert_info("Fetching live strokes-gained")
  data <- .dg_get("preds/live-strokes-gained", list(sg = sg, file_format = "json"))
  .dg_write_cache(data, cache_file)
  cli_alert_success("Cached: live_sg/{key}")
  data
}

#' Live per-round or cumulative tournament stats (current event)
#'
#' Use round = 1, 2, 3, or 4 to get a specific completed round's SG data.
#' Use round = "event_cumulative" for totals through the latest completed round.
#' Cache key is per-hour — pass force_refresh = TRUE during live scoring.
#'
#' @param stats   Comma-separated stats to return.
#' @param round   Round number (1-4), "event_cumulative", or "event_avg".
#' @param display "value" (default) or "rank".
#' @param force_refresh  If TRUE, bypass cache.
#'
#' @return List with tournament metadata and a data frame of player stats.
dg_live_tournament_stats <- function(
    stats         = "sg_putt,sg_arg,sg_app,sg_ott,sg_total",
    round         = "event_cumulative",
    display       = "value",
    force_refresh = FALSE) {
  key        <- paste0("live_stats_r", round, "_", format(Sys.time(), "%Y%m%d_%H"))
  cache_file <- .dg_cache_path("live_tournament_stats", key)

  if (!force_refresh && file.exists(cache_file)) {
    cli_alert_info("Cache hit: live_tournament_stats/{key}")
    return(.dg_read_cache(cache_file))
  }

  cli_alert_info("Fetching live tournament stats: round={round}")
  data <- .dg_get(
    "preds/live-tournament-stats",
    list(stats = stats, round = round, display = display, file_format = "json")
  )
  .dg_write_cache(data, cache_file)
  cli_alert_success("Cached: live_tournament_stats/{key}")
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

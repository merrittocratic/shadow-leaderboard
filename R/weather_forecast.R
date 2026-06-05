# Open-Meteo tournament-window weather helper for scoring scripts (07/08).
# Returns a one-row tibble with daily-avg weather for the given round_date,
# matching the schema 02d_weather_features.R produces during training.
#
# Routing:
#   round_date within today ± 16 days → forecast API
#   round_date in the past, >16 days  → historical archive API (same source 02d uses)
#   round_date > today + 16           → NA-filled row (the model's step_impute_mean
#                                       handles the gap; weather_precision = NA → "unknown")
#
# weather_precision is set to "daily_avg" on success so the trained model treats
# forecast/historical signal with the same down-weighting it learned for the
# pre-2017 daily-avg fallback path in training data.

weather_na_row <- function() {
  tibble::tibble(
    round_date        = as.Date(NA),
    wind_speed_tee    = NA_real_,
    wind_dir_tee      = NA_real_,
    temp_tee          = NA_real_,
    precip_tee        = NA_real_,
    weather_precision = NA_character_
  )
}

circular_mean_deg <- function(deg) {
  rad <- deg[!is.na(deg)] * pi / 180
  if (!length(rad)) return(NA_real_)
  (atan2(mean(sin(rad)), mean(cos(rad))) * 180 / pi) %% 360
}

# Returns a tibble with one row per UTC hour for the given round_date.
# Columns: time (POSIXct UTC), wind_speed, wind_dir, temp, precip.
# Empty tibble on failure or out-of-window.
pull_round_weather_hourly <- function(lat, lon, round_date) {
  empty <- tibble::tibble(
    time       = as.POSIXct(character(), tz = "UTC"),
    wind_speed = double(), wind_dir = double(),
    temp       = double(), precip   = double()
  )

  if (is.na(lat) || is.na(lon)) {
    cli::cli_alert_warning("Missing course coordinates — returning empty hourly weather")
    return(empty)
  }

  today <- Sys.Date()
  if (round_date > today + 16L) {
    cli::cli_alert_warning(
      "round_date {round_date} is >16 days from today; Open-Meteo forecast does not cover."
    )
    return(empty)
  }

  base_url <- if (round_date >= today - 1L) {
    "https://api.open-meteo.com/v1/forecast"
  } else {
    "https://archive-api.open-meteo.com/v1/archive"
  }

  raw <- tryCatch({
    httr2::request(base_url) |>
      httr2::req_url_query(
        latitude           = round(lat, 4),
        longitude          = round(lon, 4),
        start_date         = format(round_date, "%Y-%m-%d"),
        end_date           = format(round_date, "%Y-%m-%d"),
        hourly             = "wind_speed_10m,wind_direction_10m,temperature_2m,precipitation",
        wind_speed_unit    = "mph",
        temperature_unit   = "fahrenheit",
        precipitation_unit = "inch",
        timezone           = "UTC"
      ) |>
      httr2::req_retry(max_tries = 3, backoff = ~ 5) |>
      httr2::req_perform() |>
      httr2::resp_body_json()
  }, error = function(e) {
    cli::cli_alert_warning("Weather API call failed: {conditionMessage(e)} — returning empty hourly")
    NULL
  })

  if (is.null(raw) || is.null(raw$hourly)) return(empty)

  h <- raw$hourly
  tibble::tibble(
    time       = lubridate::ymd_hm(unlist(h$time), tz = "UTC"),
    wind_speed = as.double(unlist(h$wind_speed_10m)),
    wind_dir   = as.double(unlist(h$wind_direction_10m)),
    temp       = as.double(unlist(h$temperature_2m)),
    precip     = as.double(unlist(h$precipitation))
  )
}

# Aggregate hourly weather over a local-time window into a one-row tibble
# matching the player_rounds weather schema. `local_tz` is an IANA timezone
# string; `local_hours` is an integer vector of local hours to include.
summarize_weather_window <- function(hourly, local_tz, local_hours, precision) {
  if (!nrow(hourly)) {
    out <- weather_na_row()
    out$weather_precision <- precision
    return(out)
  }
  win <- hourly |>
    dplyr::mutate(local_hour = lubridate::hour(lubridate::with_tz(time, local_tz))) |>
    dplyr::filter(local_hour %in% local_hours)
  tibble::tibble(
    round_date        = as.Date(min(win$time, na.rm = TRUE)),
    wind_speed_tee    = mean(win$wind_speed, na.rm = TRUE),
    wind_dir_tee      = circular_mean_deg(win$wind_dir),
    temp_tee          = mean(win$temp,       na.rm = TRUE),
    precip_tee        = sum( win$precip,     na.rm = TRUE),
    weather_precision = precision
  )
}

# Back-compat: daily-avg row over the original UTC 10–22 playing window.
pull_round_weather <- function(lat, lon, round_date) {
  hourly <- pull_round_weather_hourly(lat, lon, round_date)
  if (!nrow(hourly)) {
    out <- weather_na_row()
    return(out)
  }
  win <- hourly |>
    dplyr::mutate(utc_hour = lubridate::hour(time)) |>
    dplyr::filter(utc_hour >= 10L, utc_hour <= 22L)
  tibble::tibble(
    round_date        = round_date,
    wind_speed_tee    = mean(win$wind_speed, na.rm = TRUE),
    wind_dir_tee      = circular_mean_deg(win$wind_dir),
    temp_tee          = mean(win$temp,       na.rm = TRUE),
    precip_tee        = sum( win$precip,     na.rm = TRUE),
    weather_precision = "daily_avg"
  )
}

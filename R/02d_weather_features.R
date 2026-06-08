source("R/00_config.R")

# Pull ERA5 weather data for every historical PGA Tour event and join to
# player-rounds at tee-time granularity.
#
# Outputs:
#   config/course_taxonomy_weighted.csv  — updated in-place with lat / lon columns
#   data/weather/era5_{event_id}_{year}.rds  — per-event ERA5 cache
#   data/02d_weather_features.rds        — per-round weather features
#
# New columns added to player-rounds downstream:
#   wind_speed_tee  (mph)
#   wind_dir_tee    (degrees)
#   temp_tee        (°F)
#   precip_tee      (inches, hourly)
#
#   Rscript R/02d_weather_features.R

if (!requireNamespace("tidygeocoder", quietly = TRUE)) install.packages("tidygeocoder", repos = "https://cloud.r-project.org")
if (!requireNamespace("lutz",         quietly = TRUE)) install.packages("lutz",         repos = "https://cloud.r-project.org")

library(lubridate)
library(tidygeocoder)
library(lutz)

TAXONOMY_PATH <- file.path(here::here(), "config", "course_taxonomy_weighted.csv")
CACHE_WEATHER <- file.path(PATH_DATA, "weather")
dir.create(CACHE_WEATHER, showWarnings = FALSE, recursive = TRUE)

cli_h1("Weather feature pipeline — ERA5 × PGA Tour events")

# ---- Load player_rounds ------------------------------------------------------

player_rounds <- readRDS(file.path(PATH_DATA, "02_player_rounds.rds"))
cli_alert_info(
  "{scales::comma(nrow(player_rounds))} player-rounds | ",
  "{n_distinct(paste(player_rounds$event_id, player_rounds$year))} event-years"
)

# ---- Step 1: Geocode course venues -------------------------------------------
# Adds lat / lon to course_taxonomy_weighted.csv on first run.
# Subsequent runs load directly from the updated CSV.

taxonomy <- readr::read_csv(
  TAXONOMY_PATH,
  col_types = readr::cols(course_num = readr::col_integer(), .default = readr::col_guess()),
  show_col_types = FALSE
)

if (!all(c("lat", "lon") %in% names(taxonomy))) {
  cli_h2("Geocoding {nrow(taxonomy)} course venues via OSM (first run only)")

  geocoded <- tidygeocoder::geocode(
    taxonomy |>
      mutate(search_str = paste(venue_name, "golf course United States")),
    address  = search_str,
    method   = "osm",
    min_time = 1,     # OSM rate limit: 1 req/sec
    verbose  = FALSE
  )

  taxonomy <- taxonomy |>
    left_join(
      geocoded |> select(venue_name, lat, long) |> rename(lon = long),
      by = "venue_name"
    )

  n_ok   <- sum(!is.na(taxonomy$lat))
  n_fail <- nrow(taxonomy) - n_ok
  cli_alert_success("Geocoded {n_ok} / {nrow(taxonomy)} venues")
  if (n_fail > 0) {
    cli_alert_warning(
      "{n_fail} venues failed geocoding — weather will be NA for those courses"
    )
    print(filter(taxonomy, is.na(lat)) |> select(course_num, venue_name))
  }

  readr::write_csv(taxonomy, TAXONOMY_PATH)
  cli_alert_success("Updated taxonomy saved to {TAXONOMY_PATH}")
} else {
  cli_alert_info("lat / lon already in taxonomy — skipping geocoding")
}

course_coords <- taxonomy |>
  select(course_num, lat, lon) |>
  filter(!is.na(lat), !is.na(lon))

cli_alert_info("{nrow(course_coords)} courses with coordinates")

# ---- Step 2: Compute round dates per player-round ----------------------------
# Standard PGA Tour: event_completed is the Sunday (final round) date.
# n_rounds = max round_num per event; round_date = event_completed - (n_rounds - round_num).

player_rounds <- player_rounds |>
  group_by(event_id, year) |>
  mutate(
    n_rounds   = max(round_num, na.rm = TRUE),
    round_date = event_completed - (n_rounds - round_num)
  ) |>
  ungroup()

# ---- Step 3: Get course timezones via lutz -----------------------------------

cli_h2("Looking up course timezones")

course_tz <- course_coords |>
  mutate(tz = lutz::tz_lookup_coords(lat, lon, method = "fast")) |>
  select(course_num, tz)

cli_alert_success("{nrow(course_tz)} course timezones resolved")

# ---- Step 4: Parse tee times → UTC hour --------------------------------------

parse_tee_hour <- function(teetime_str) {
  clean <- stringr::str_to_lower(stringr::str_trim(teetime_str))
  h     <- as.integer(stringr::str_extract(clean, "^\\d+"))
  dplyr::case_when(
    stringr::str_detect(clean, "am") & h == 12L ~ 0L,
    stringr::str_detect(clean, "am")            ~ h,
    stringr::str_detect(clean, "pm") & h == 12L ~ 12L,
    stringr::str_detect(clean, "pm")            ~ h + 12L,
    TRUE                                         ~ NA_integer_
  )
}

local_to_utc_hour <- function(date, hour_local, tz_str) {
  if (is.na(date) || is.na(hour_local) || is.na(tz_str)) return(NA_real_)
  dt_local <- as.POSIXct(
    paste0(format(date), sprintf(" %02d:00:00", hour_local)),
    tz = tz_str
  )
  as.numeric(lubridate::with_tz(dt_local, "UTC"))
}

player_rounds <- player_rounds |>
  left_join(course_coords, by = "course_num") |>
  left_join(course_tz,     by = "course_num") |>
  mutate(
    tee_hour_local = parse_tee_hour(teetime),
    tee_utc_epoch  = mapply(local_to_utc_hour, round_date, tee_hour_local, tz),
    tee_utc_hour   = as.POSIXct(tee_utc_epoch, tz = "UTC", origin = "1970-01-01")
  )

n_parsed <- sum(!is.na(player_rounds$tee_utc_hour))
cli_alert_info(
  "Tee-time UTC parsed: {scales::comma(n_parsed)} / {scales::comma(nrow(player_rounds))} rounds ",
  "({round(100 * n_parsed / nrow(player_rounds), 1)}%)"
)

# ---- Step 5: Pull ERA5 per event window --------------------------------------

pull_era5_event <- function(event_id, year, start_date, end_date, lat, lon) {
  cache_file <- file.path(CACHE_WEATHER, paste0("era5_", event_id, "_", year, ".rds"))
  if (file.exists(cache_file)) return(readRDS(cache_file))

  tryCatch({
    raw <- httr2::request("https://archive-api.open-meteo.com/v1/archive") |>
      httr2::req_url_query(
        latitude           = round(lat, 4),
        longitude          = round(lon, 4),
        start_date         = format(start_date, "%Y-%m-%d"),
        end_date           = format(end_date,   "%Y-%m-%d"),
        hourly             = "wind_speed_10m,wind_direction_10m,temperature_2m,precipitation",
        wind_speed_unit    = "mph",
        temperature_unit   = "fahrenheit",
        precipitation_unit = "inch",
        timezone           = "UTC"
      ) |>
      httr2::req_throttle(rate = 3, realm = "open-meteo") |>
      httr2::req_retry(max_tries = 3, backoff = ~ 5) |>
      httr2::req_perform() |>
      httr2::resp_body_json()

    saveRDS(raw, cache_file)
    raw
  }, error = function(e) {
    cli_alert_warning("ERA5 failed [{event_id} {year}]: {conditionMessage(e)}")
    NULL
  })
}

parse_era5_hourly <- function(raw, event_id, year) {
  if (is.null(raw)) return(tibble::tibble())
  h <- raw$hourly
  tibble::tibble(
    tee_utc_hour = as.POSIXct(
      as.numeric(lubridate::ymd_hm(unlist(h$time), tz = "UTC")),
      tz = "UTC", origin = "1970-01-01"
    ),
    wind_speed_tee = as.double(unlist(h$wind_speed_10m)),
    wind_dir_tee   = as.double(unlist(h$wind_direction_10m)),
    temp_tee       = as.double(unlist(h$temperature_2m)),
    precip_tee     = as.double(unlist(h$precipitation)),
    event_id       = event_id,
    year           = year
  )
}

# Unique event windows with coordinates
event_windows <- player_rounds |>
  filter(!is.na(lat), !is.na(lon)) |>
  group_by(event_id, year) |>
  summarise(
    lat        = first(lat),
    lon        = first(lon),
    start_date = min(round_date, na.rm = TRUE),
    end_date   = max(round_date, na.rm = TRUE),
    .groups    = "drop"
  )

n_events       <- nrow(event_windows)
n_no_coords    <- n_distinct(paste(player_rounds$event_id, player_rounds$year)) - n_events
cli_alert_info("{n_events} event windows to pull | {n_no_coords} events skipped (no coordinates)")

cli_h2("Pulling ERA5 ({n_events} events — cached after first run)")

era5_raw <- purrr::pmap(
  list(event_windows$event_id, event_windows$year,
       event_windows$start_date, event_windows$end_date,
       event_windows$lat, event_windows$lon),
  pull_era5_event
)

era5_df <- purrr::map2_dfr(
  era5_raw,
  seq_len(nrow(event_windows)),
  function(raw, i) parse_era5_hourly(raw, event_windows$event_id[i], event_windows$year[i])
)

cli_alert_success(
  "ERA5 hourly records: {scales::comma(nrow(era5_df))} across {n_distinct(era5_df$event_id)} events"
)

# ---- Step 6: Primary join — ERA5 at tee-time UTC hour -----------------------
# Covers 2017+ where tee times are available.

cli_h2("Joining ERA5 to player-rounds")

weather_features <- player_rounds |>
  left_join(era5_df, by = c("event_id", "year", "tee_utc_hour")) |>
  mutate(weather_precision = if_else(!is.na(wind_speed_tee), "hourly", NA_character_))

# ---- Step 7: Daily-average fallback for rounds with no tee time -------------
# Covers 2010-2015 (no tee times) and any 2016 partial-coverage rounds.
# Group ERA5 by (event_id, year, UTC date) and take the daytime window
# (UTC hours 10-22 ≈ local 6am-6pm across US time zones), then join on
# (event_id, year, round_date).

circular_mean_deg <- function(deg) {
  rad <- deg[!is.na(deg)] * pi / 180
  if (!length(rad)) return(NA_real_)
  (atan2(mean(sin(rad)), mean(cos(rad))) * 180 / pi) %% 360
}

era5_daily <- era5_df |>
  mutate(
    utc_hour   = lubridate::hour(tee_utc_hour),
    round_date = as.Date(tee_utc_hour)
  ) |>
  filter(utc_hour >= 10L, utc_hour <= 22L) |>   # daytime playing window in UTC
  group_by(event_id, year, round_date) |>
  summarise(
    wind_speed_daily = mean(wind_speed_tee, na.rm = TRUE),
    wind_dir_daily   = circular_mean_deg(wind_dir_tee),
    temp_daily       = mean(temp_tee,       na.rm = TRUE),
    precip_daily     = sum(precip_tee,      na.rm = TRUE),
    .groups = "drop"
  )

weather_features <- weather_features |>
  left_join(era5_daily, by = c("event_id", "year", "round_date")) |>
  mutate(
    wind_speed_tee    = dplyr::coalesce(wind_speed_tee, wind_speed_daily),
    wind_dir_tee      = dplyr::coalesce(wind_dir_tee,   wind_dir_daily),
    temp_tee          = dplyr::coalesce(temp_tee,        temp_daily),
    precip_tee        = dplyr::coalesce(precip_tee,      precip_daily),
    weather_precision = dplyr::coalesce(
      weather_precision,
      if_else(!is.na(wind_speed_daily), "daily_avg", NA_character_)
    )
  ) |>
  select(
    dg_id, event_id, year, round_num,
    round_date, tee_utc_hour, weather_precision,
    wind_speed_tee, wind_dir_tee, temp_tee, precip_tee
  )

# ---- Step 8: Coverage diagnostics -------------------------------------------

cli_h2("Coverage diagnostics")

n_total   <- nrow(weather_features)
n_hourly  <- sum(weather_features$weather_precision == "hourly",    na.rm = TRUE)
n_daily   <- sum(weather_features$weather_precision == "daily_avg", na.rm = TRUE)
n_missing <- sum(is.na(weather_features$wind_speed_tee))

cli_alert_info(glue::glue(
  "Coverage: {scales::comma(n_hourly)} hourly | ",
  "{scales::comma(n_daily)} daily-avg | ",
  "{scales::comma(n_missing)} NA ",
  "({round(100 * (n_hourly + n_daily) / n_total, 1)}% total)"
))

by_year <- weather_features |>
  group_by(year) |>
  summarise(
    n_rounds  = n(),
    n_hourly  = sum(weather_precision == "hourly",    na.rm = TRUE),
    n_daily   = sum(weather_precision == "daily_avg", na.rm = TRUE),
    pct_total = round(100 * (n_hourly + n_daily) / n_rounds, 1),
    .groups   = "drop"
  )

print(by_year, n = 25)

wind_summary <- weather_features |>
  filter(!is.na(wind_speed_tee)) |>
  summarise(
    mean_wind = round(mean(wind_speed_tee), 1),
    p25_wind  = round(quantile(wind_speed_tee, 0.25), 1),
    p75_wind  = round(quantile(wind_speed_tee, 0.75), 1),
    max_wind  = round(max(wind_speed_tee), 1),
    mean_temp = round(mean(temp_tee, na.rm = TRUE), 1)
  )
cli_alert_info(glue::glue(
  "Wind speed — mean: {wind_summary$mean_wind} mph | ",
  "IQR: {wind_summary$p25_wind}–{wind_summary$p75_wind} | ",
  "max: {wind_summary$max_wind} | mean temp: {wind_summary$mean_temp}°F"
))

# ---- Save --------------------------------------------------------------------

out_file <- file.path(PATH_DATA, "02d_weather_features.rds")
saveRDS(weather_features, out_file)
cli_alert_success("Saved {scales::comma(nrow(weather_features))} rows to {out_file}")

cli_h1("Done")
cli_alert_info(
  "Next: join 02d_weather_features.rds in 04_train_evaluate.R / 05_tune.R, ",
  "then add wind_speed_tee, wind_dir_tee, temp_tee, precip_tee to gbdt_recipe() in 03_model_spec.R"
)

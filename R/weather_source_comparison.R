source("R/00_config.R")

# Compare two weather data sources at Shinnecock Hills across the three most
# recent US Opens held there (1995, 2004, 2018).
#
#   Source 1: Open-Meteo ERA5 reanalysis (archive-api.open-meteo.com)
#   Source 2: ASOS station KFOK (East Hampton Airport, ~30 mi from venue)
#             via the riem package (Iowa State Mesonet)
#
# Outputs:
#   data/weather/openmeteo_raw_{year}.rds   — raw API response
#   data/weather/asos_raw_{year}.rds        — raw riem tibble
#   graphics/weather_wind_scatter.png       — ERA5 vs KFOK wind speed scatter
#
#   Rscript scripts/weather_source_comparison.R

if (!requireNamespace("riem",     quietly = TRUE)) install.packages("riem",     repos = "https://cloud.r-project.org")
if (!requireNamespace("circular", quietly = TRUE)) install.packages("circular", repos = "https://cloud.r-project.org")

library(riem)
library(lubridate)
library(ggplot2)

CACHE_WEATHER <- file.path(PATH_DATA, "weather")

LAT <- 40.8903
LON <- -72.4412

# Thursday–Sunday for each Shinnecock US Open
tournaments <- tibble::tribble(
  ~year, ~start,       ~end,
  1995L, "1995-06-15", "1995-06-18",
  2004L, "2004-06-17", "2004-06-20",
  2018L, "2018-06-14", "2018-06-17"
)

cli_h1("Weather source comparison — Shinnecock Hills US Opens")

# ---- Helpers -----------------------------------------------------------------

circular_mean <- function(deg) {
  rad <- deg[!is.na(deg)] * pi / 180
  if (!length(rad)) return(NA_real_)
  (atan2(mean(sin(rad)), mean(cos(rad))) * 180 / pi) %% 360
}

circ_mae <- function(a, b) {
  complete <- !is.na(a) & !is.na(b)
  if (!any(complete)) return(NA_real_)
  d <- abs(a[complete] - b[complete]) %% 360
  mean(pmin(d, 360 - d))
}

# ---- Source 1: Open-Meteo ERA5 -----------------------------------------------

pull_openmeteo <- function(year, start, end) {
  cache_file <- file.path(CACHE_WEATHER, paste0("openmeteo_raw_", year, ".rds"))
  if (file.exists(cache_file)) {
    cli_alert_info("Open-Meteo {year}: loading from cache")
    return(readRDS(cache_file))
  }
  cli_alert_info("Open-Meteo {year}: pulling {start} → {end}")
  resp <- httr2::request("https://archive-api.open-meteo.com/v1/archive") |>
    httr2::req_url_query(
      latitude           = LAT,
      longitude          = LON,
      start_date         = start,
      end_date           = end,
      hourly             = "wind_speed_10m,wind_direction_10m,temperature_2m,precipitation",
      wind_speed_unit    = "mph",
      temperature_unit   = "fahrenheit",
      precipitation_unit = "inch",
      timezone           = "UTC"
    ) |>
    httr2::req_perform()
  raw <- httr2::resp_body_json(resp)
  saveRDS(raw, cache_file)
  cli_alert_success("Open-Meteo {year}: cached to {cache_file}")
  raw
}

parse_openmeteo <- function(raw, year) {
  h <- raw$hourly
  tibble::tibble(
    time        = lubridate::ymd_hm(unlist(h$time), tz = "UTC"),
    ws_era5     = as.double(unlist(h$wind_speed_10m)),
    wd_era5     = as.double(unlist(h$wind_direction_10m)),
    temp_era5   = as.double(unlist(h$temperature_2m)),
    precip_era5 = as.double(unlist(h$precipitation)),
    year        = year
  )
}

cli_h2("Pulling Open-Meteo ERA5")
om_raw  <- purrr::pmap(tournaments, pull_openmeteo)
om_df   <- purrr::map2_dfr(om_raw, tournaments$year, parse_openmeteo)
cli_alert_success("ERA5: {nrow(om_df)} hourly rows across {n_distinct(om_df$year)} years")

# ---- Source 2: ASOS KFOK -----------------------------------------------------

pull_asos <- function(year, start, end, station = "KFOK") {
  cache_file <- file.path(CACHE_WEATHER, paste0("asos_raw_", station, "_", year, ".rds"))
  # Accept legacy cache filenames (KFOK pulls from earlier runs)
  legacy_file <- file.path(CACHE_WEATHER, paste0("asos_raw_", year, ".rds"))
  if (file.exists(cache_file)) {
    cli_alert_info("ASOS {station} {year}: loading from cache")
    return(readRDS(cache_file))
  }
  if (station == "KFOK" && file.exists(legacy_file)) {
    cli_alert_info("ASOS {station} {year}: loading from legacy cache")
    return(readRDS(legacy_file))
  }
  cli_alert_info("ASOS {station} {year}: pulling {start} → {end}")
  raw <- riem::riem_measures(
    station    = station,
    date_start = start,
    date_end   = as.character(as.Date(end) + 1L)
  )
  if (is.null(raw) || nrow(raw) == 0) {
    cli_alert_warning("ASOS {station} {year}: no data returned")
    raw <- tibble::tibble()
  }
  saveRDS(raw, cache_file)
  cli_alert_success("ASOS {station} {year}: {nrow(raw)} obs cached to {cache_file}")
  raw
}

parse_asos <- function(raw, year, start, end) {
  if (is.null(raw) || nrow(raw) == 0) return(tibble::tibble())

  start_dt <- lubridate::as_datetime(start, tz = "UTC")
  end_dt   <- lubridate::as_datetime(end,   tz = "UTC") + lubridate::hours(23)

  raw |>
    dplyr::filter(valid >= start_dt, valid <= end_dt) |>
    dplyr::mutate(
      hour        = lubridate::floor_date(valid, "hour"),
      ws_raw      = as.double(sknt) * 1.15078,   # knots → mph
      wd_raw      = as.double(drct),
      temp_raw    = as.double(tmpf),
      precip_raw  = as.double(p01i)
    ) |>
    dplyr::group_by(hour) |>
    dplyr::summarise(
      ws_asos     = mean(ws_raw,    na.rm = TRUE),
      wd_asos     = circular_mean(wd_raw),
      temp_asos   = mean(temp_raw,  na.rm = TRUE),
      precip_asos = sum(precip_raw, na.rm = TRUE),
      n_obs       = dplyr::n(),
      .groups     = "drop"
    ) |>
    dplyr::rename(time = hour) |>
    dplyr::mutate(year = year)
}

cli_h2("Pulling ASOS KFOK")
kfok_raw <- purrr::pmap(tournaments, pull_asos, station = "KFOK")
kfok_df  <- purrr::pmap_dfr(
  list(kfok_raw, tournaments$year, tournaments$start, tournaments$end),
  parse_asos
)

if (nrow(kfok_df) == 0) {
  cli_abort("No ASOS data returned for KFOK. Check station availability.")
}
cli_alert_success("KFOK: {nrow(kfok_df)} hourly rows across {n_distinct(kfok_df$year)} years")

# ---- Pull ASOS KHWV (Brookhaven Airport, ~15 mi from Shinnecock) -------------

cli_h2("Pulling ASOS KHWV (Brookhaven — closer reference)")
khwv_raw <- purrr::pmap(tournaments, pull_asos, station = "KHWV")
khwv_df  <- purrr::pmap_dfr(
  list(khwv_raw, tournaments$year, tournaments$start, tournaments$end),
  parse_asos
)
cli_alert_success("KHWV: {nrow(khwv_df)} hourly rows across {n_distinct(khwv_df$year)} years")

# ---- Join each source on UTC hour --------------------------------------------

cli_h2("Joining on UTC hour")

join_source <- function(obs_df, label) {
  dplyr::inner_join(om_df, obs_df, by = c("time", "year")) |>
    dplyr::filter(!is.na(ws_era5), !is.na(ws_asos),
                  !is.na(temp_era5), !is.na(temp_asos)) |>
    dplyr::mutate(source = label)
}

joined_kfok      <- join_source(kfok_df,                      "KFOK (all hours)")
joined_kfok_calm <- join_source(dplyr::filter(kfok_df, ws_asos > 0), "KFOK (calms removed)")
joined_khwv      <- join_source(khwv_df,                      "KHWV")

for (df in list(joined_kfok, joined_kfok_calm, joined_khwv)) {
  src <- unique(df$source)
  yrs <- paste(df |> dplyr::count(year) |>
                 dplyr::mutate(s = paste0(year, "=", n)) |>
                 dplyr::pull(s), collapse = ", ")
  cli_alert_info("{src}: {nrow(df)} matched hours | {yrs}")
}

# ---- Comparison metrics helper -----------------------------------------------

compute_metrics <- function(df) {
  by_year <- df |>
    dplyr::group_by(source, year) |>
    dplyr::summarise(
      n_hours        = dplyr::n(),
      ws_pearson_r   = cor(ws_era5,   ws_asos,   use = "complete.obs") |> round(3),
      ws_rmse        = sqrt(mean((ws_era5 - ws_asos)^2, na.rm = TRUE)) |> round(2),
      wd_circ_mae    = circ_mae(wd_era5, wd_asos) |> round(1),
      temp_pearson_r = cor(temp_era5, temp_asos,  use = "complete.obs") |> round(3),
      temp_rmse      = sqrt(mean((temp_era5 - temp_asos)^2, na.rm = TRUE)) |> round(2),
      .groups = "drop"
    )
  overall <- df |>
    dplyr::summarise(
      source         = unique(source),
      year           = "All",
      n_hours        = dplyr::n(),
      ws_pearson_r   = cor(ws_era5,   ws_asos,   use = "complete.obs") |> round(3),
      ws_rmse        = sqrt(mean((ws_era5 - ws_asos)^2, na.rm = TRUE)) |> round(2),
      wd_circ_mae    = circ_mae(wd_era5, wd_asos) |> round(1),
      temp_pearson_r = cor(temp_era5, temp_asos,  use = "complete.obs") |> round(3),
      temp_rmse      = sqrt(mean((temp_era5 - temp_asos)^2, na.rm = TRUE)) |> round(2)
    )
  dplyr::bind_rows(dplyr::mutate(by_year, year = as.character(year)), overall)
}

# ---- Print metrics for all three comparisons ---------------------------------

cli_h2("Source comparison metrics")
cli_alert_info("wind speed: Pearson r | RMSE (mph) | wind direction: circ MAE (deg) | temp: Pearson r | RMSE (°F)")

metrics_all <- dplyr::bind_rows(
  compute_metrics(joined_kfok),
  compute_metrics(joined_kfok_calm),
  compute_metrics(joined_khwv)
)

print(metrics_all, n = Inf)

# ---- Combined wind speed scatter plot ----------------------------------------

cli_h2("Building combined wind speed scatter plot")

plot_data <- dplyr::bind_rows(joined_kfok, joined_kfok_calm, joined_khwv) |>
  dplyr::mutate(source = factor(source, levels = c(
    "KFOK (all hours)", "KFOK (calms removed)", "KHWV"
  )))

axis_max <- max(c(plot_data$ws_era5, plot_data$ws_asos), na.rm = TRUE) * 1.05

label_df <- metrics_all |>
  dplyr::filter(year != "All") |>
  dplyr::mutate(
    source  = factor(source, levels = levels(plot_data$source)),
    label   = paste0("r=", ws_pearson_r, "\nRMSE=", ws_rmse),
    ws_era5 = axis_max * 0.03,
    ws_asos = axis_max * 0.95,
    year    = as.integer(year)
  )

p <- ggplot(plot_data, aes(x = ws_era5, y = ws_asos)) +
  geom_abline(slope = 1, intercept = 0, linetype = "dashed", colour = "grey60") +
  geom_point(alpha = 0.45, size = 1.5, colour = "#2c7bb6") +
  geom_smooth(method = "lm", se = FALSE, colour = "#d7191c", linewidth = 0.7) +
  geom_text(
    data    = label_df,
    aes(label = label),
    hjust   = 0, vjust = 1, size = 2.6, colour = "grey20"
  ) +
  facet_grid(source ~ year) +
  scale_x_continuous(limits = c(0, axis_max)) +
  scale_y_continuous(limits = c(0, axis_max)) +
  coord_fixed() +
  labs(
    title    = "ERA5 vs ASOS wind speed — Shinnecock Hills US Opens",
    subtitle = "Rows: KFOK all | KFOK calms removed | KHWV (closer station)  ·  Dashed = perfect agreement",
    x        = "ERA5 wind speed (mph)",
    y        = "ASOS observed wind speed (mph)",
    caption  = "Sources: Open-Meteo ERA5 reanalysis; Iowa State ASOS via riem"
  ) +
  theme_minimal(base_size = 11) +
  theme(
    strip.text       = element_text(face = "bold", size = 9),
    plot.title       = element_text(face = "bold"),
    panel.grid.minor = element_blank()
  )

out_plot <- file.path(here::here("graphics"), "weather_wind_scatter.png")
ggsave(out_plot, p, width = 10, height = 9, dpi = 150)
cli_alert_success("Plot saved to {out_plot}")

cli_h1("Done")
cli_alert_info(
  "Decision guide: ws_pearson_r >= 0.85 and ws_rmse <= 3 mph → ERA5 reliable as pipeline source. ",
  "If calms-removed metrics are substantially better, KFOK zero-censoring was the main noise source."
)

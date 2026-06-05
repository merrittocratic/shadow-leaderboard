source("R/00_config.R")

# One-off: geocode the venues that the original 02d_weather_features.R pass
# missed. Iterates a sequence of search-string strategies per venue, keeps the
# first hit. Updates config/course_taxonomy_weighted.csv in place and writes an
# audit CSV to output/geocoding_audit.csv for inspection.
#
#   Rscript R/02d_geocode_fill.R

if (!requireNamespace("tidygeocoder", quietly = TRUE)) install.packages("tidygeocoder", repos = "https://cloud.r-project.org")

library(tidygeocoder)

TAXONOMY_PATH <- file.path(here::here(), "config", "course_taxonomy_weighted.csv")
AUDIT_PATH    <- file.path(here::here(), "output", "geocoding_audit.csv")
dir.create(dirname(AUDIT_PATH), showWarnings = FALSE, recursive = TRUE)

tax <- readr::read_csv(
  TAXONOMY_PATH,
  col_types = readr::cols(course_num = readr::col_integer(), .default = readr::col_guess()),
  show_col_types = FALSE
)

if (!all(c("lat", "lon") %in% names(tax))) {
  cli_abort("Taxonomy has no lat/lon columns yet — run 02d_weather_features.R first")
}

missing <- tax |>
  filter(is.na(lat) | is.na(lon)) |>
  distinct(venue_name)
cli_h1("Re-geocoding {nrow(missing)} unique venues with missing coordinates")

# ---- Search-string strategies ------------------------------------------------

clean_venue <- function(name) {
  name |>
    stringr::str_replace_all("\\s*\\(.*?\\)", "") |>     # drop parentheticals
    stringr::str_replace_all("\\bG&CC\\b",  "Golf & Country Club") |>
    stringr::str_replace_all("\\bGC\\b",    "Golf Club") |>
    stringr::str_replace_all("\\bGL\\b",    "Golf Links") |>
    stringr::str_replace_all("\\bCC\\b",    "Country Club") |>
    stringr::str_replace_all("\\bG\\.?C\\.?\\b", "Golf Club") |>
    stringr::str_squish()
}

clean_aggressive <- function(name) {
  name |>
    stringr::str_replace_all("\\s*\\(.*?\\)", "") |>            # parentheticals
    stringr::str_replace("\\s*-\\s*PGA\\s+Championship.*$", "") |>  # event tag
    stringr::str_replace("\\s*-\\s*US\\s+Open.*$", "") |>           # event tag
    stringr::str_replace("^The\\s+", "") |>                          # leading "The"
    stringr::str_replace_all("\\bG&CC\\b",  "Golf & Country Club") |>
    stringr::str_replace_all("\\bGC\\b",    "Golf Club") |>
    stringr::str_replace_all("\\bGL\\b",    "Golf Links") |>
    stringr::str_replace_all("\\bCC\\b",    "Country Club") |>
    stringr::str_replace("\\s+\\d+\\s*$", "") |>                    # trailing digit
    stringr::str_squish()
}

# "TPC Blue Monster at Doral" → "Doral";  "Plantation Course at Kapalua" → "Kapalua"
after_at <- function(name) {
  c <- clean_aggressive(name)
  m <- stringr::str_match(c, "\\bat\\s+(.+)$")[, 2]
  if (!is.na(m)) stringr::str_squish(m) else c
}

# "Bay Hill Club & Lodge" → "Bay Hill Club";  "Silverado Resort and Spa North" → "Silverado"
strip_resort_suffix <- function(name) {
  clean_aggressive(name) |>
    stringr::str_replace("\\s+(&\\s+Lodge|Resort\\s+(and|&)\\s+Spa.*|Resort\\s+and\\s+Lodge.*)$", "") |>
    stringr::str_squish()
}

strategies <- list(
  clean         = function(n) clean_venue(n),
  aggressive    = function(n) clean_aggressive(n),
  after_at      = function(n) after_at(n),
  strip_resort  = function(n) strip_resort_suffix(n),
  clean_golf    = function(n) paste(clean_venue(n), "golf"),
  clean_USA     = function(n) paste0(clean_venue(n), ", USA"),
  raw_golf      = function(n) paste(n, "golf course")
)

# ---- Per-venue lookup --------------------------------------------------------

geocode_one <- function(venue_name) {
  for (strat_name in names(strategies)) {
    q <- strategies[[strat_name]](venue_name)
    Sys.sleep(1.1)   # OSM Nominatim: 1 req/sec
    res <- tryCatch(
      tidygeocoder::geo(address = q, method = "osm", quiet = TRUE),
      error = function(e) NULL
    )
    if (!is.null(res) && nrow(res) > 0 && !is.na(res$lat[1])) {
      return(tibble::tibble(
        venue_name = venue_name,
        strategy   = strat_name,
        search_str = q,
        lat        = res$lat[1],
        lon        = res$long[1]
      ))
    }
  }
  tibble::tibble(
    venue_name = venue_name,
    strategy   = NA_character_,
    search_str = NA_character_,
    lat        = NA_real_,
    lon        = NA_real_
  )
}

results <- purrr::map_dfr(
  missing$venue_name,
  function(v) {
    out <- geocode_one(v)
    status <- if (is.na(out$lat)) "FAIL" else paste0("ok [", out$strategy, "]")
    cli_alert_info("{status}: {v}")
    out
  }
)

n_ok   <- sum(!is.na(results$lat))
n_fail <- sum(is.na(results$lat))
cli_h2("Result: {n_ok} succeeded, {n_fail} still missing")

# ---- Audit CSV ---------------------------------------------------------------

audit <- tax |>
  filter(is.na(lat) | is.na(lon)) |>
  select(course_num, venue_name) |>
  left_join(results, by = "venue_name", relationship = "many-to-one")

readr::write_csv(audit, AUDIT_PATH)
cli_alert_success("Audit written to {AUDIT_PATH}")

# ---- Update taxonomy ---------------------------------------------------------

tax_new <- tax |>
  left_join(
    results |> select(venue_name, lat_new = lat, lon_new = lon),
    by = "venue_name",
    relationship = "many-to-one"
  ) |>
  mutate(
    lat = dplyr::coalesce(lat, lat_new),
    lon = dplyr::coalesce(lon, lon_new)
  ) |>
  select(-lat_new, -lon_new)

readr::write_csv(tax_new, TAXONOMY_PATH)
cli_alert_success(
  "Updated taxonomy — {sum(!is.na(tax_new$lat))} / {nrow(tax_new)} venues now have coords"
)

if (n_fail > 0) {
  cli_alert_warning("Still missing — review {AUDIT_PATH} and add manually if needed:")
  print(audit |> filter(is.na(lat)), n = n_fail)
}

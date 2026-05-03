library(tidyverse)
library(httr2)
library(jsonlite)
library(here)
library(cli)

# DataGolf API
DG_BASE_URL <- "https://feeds.datagolf.com"
DG_API_KEY  <- Sys.getenv("GOLF_API_KEY")

# Training window
TRAIN_YEAR_START <- 2010L
TRAIN_YEAR_END   <- 2025L

# Tours in scope
TOURS_IN_SCOPE <- c("pga")

# Held-out validation events (do not touch until Week 4)
HOLDOUT_EVENTS <- list(
  list(tour = "pga", event_id = "us_open", year = 2025L),  # Oakmont
  list(tour = "pga", event_id = "masters", year = 2026L)   # Augusta
)

# Paths
PATH_CACHE  <- here::here("data", "cache")
PATH_DATA   <- here::here("data")
PATH_OUTPUT <- here::here("output")
PATH_CONFIG <- here::here("config")

# Validate that the API key was injected — fail loudly at startup
if (nchar(DG_API_KEY) == 0) {
  cli_abort(c(
    "GOLF_API_KEY is not set.",
    "i" = "Run scripts via: op run --env-file=.env.template -- Rscript R/<script>.R"
  ))
}

library(tidyverse)
library(httr2)
library(jsonlite)
library(here)
library(cli)

# DataGolf API
DG_BASE_URL  <- "https://feeds.datagolf.com"
DG_API_KEY   <- Sys.getenv("GOLF_API_KEY")

# The Odds API (Pinnacle sharp line — sourced in odds_api.R)
ODDS_API_KEY <- Sys.getenv("ODDS_API_KEY")

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
PATH_CACHE    <- here::here("data", "cache")
PATH_DATA     <- here::here("data")
PATH_OUTPUT   <- here::here("output")
PATH_CONFIG   <- here::here("config")
PATH_GRAPHICS <- here::here("graphics")

# API key validation lives in datagolf_api.R, not here, so that scripts
# which read from cache (02, 03, 04) can source 00_config.R without
# requiring op run.

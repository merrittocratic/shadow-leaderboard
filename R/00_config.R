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

# Skill anchor for the residual target (decay-prior anchor experiment).
# "static" = expanding-mean prior (production baseline)
# "decay"  = decay-weighted prior (PRIOR_DECAY in 02, ~2.4-year half-life)
# Only 02_feature_engineering.R reads this; the chosen anchor is baked into
# data/02_player_rounds.rds as the player_anchor column and travels as data.
# Switching anchors requires the full retrain chain: 02 -> 02b -> 05 -> 06b.
SKILL_ANCHOR <- Sys.getenv("SKILL_ANCHOR", unset = "static")
stopifnot(SKILL_ANCHOR %in% c("static", "decay"))

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

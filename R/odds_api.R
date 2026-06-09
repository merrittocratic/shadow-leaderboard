# R/odds_api.R
# Fetches pre-tournament outright winner odds from The Odds API.
# Uses Betfair Exchange (EU) as the sharp-line reference — exchange prices
# reflect true market consensus with no bookmaker vig.
#
# Source after 00_config.R. Validates ODDS_API_KEY on source.
#
# Usage:
#   source("R/00_config.R")
#   source("R/odds_api.R")
#   snap <- fetch_odds_snapshot("us_open", 2026)

ODDS_API_BASE <- "https://api.the-odds-api.com/v4"

if (nchar(ODDS_API_KEY) == 0) {
  cli_abort(c(
    "ODDS_API_KEY is not set.",
    "i" = "Run via: op run --env-file=.env.template -- Rscript R/<script>.R"
  ))
}

# DG slug -> Odds API sport key (majors only; non-majors silently return NULL)
.ODDS_SPORT_KEYS <- c(
  "masters"               = "golf_masters_tournament_winner",
  "pga_championship"      = "golf_pga_championship",
  "us_open"               = "golf_us_open_winner",
  "the_open_championship" = "golf_the_open_championship"
)

.odds_get <- function(path, params = list()) {
  params[["apiKey"]] <- ODDS_API_KEY
  req <- request(ODDS_API_BASE) |>
    req_url_path_append(path) |>
    req_url_query(!!!params) |>
    req_error(is_error = \(resp) FALSE)
  resp <- req_perform(req)
  if (resp_status(resp) != 200L) {
    cli_abort("The Odds API returned HTTP {resp_status(resp)} for path: {path}")
  }
  resp_body_json(resp, simplifyVector = FALSE)
}

# American odds -> raw implied probability (before vig removal)
.american_to_prob <- function(odds) {
  ifelse(odds < 0, abs(odds) / (abs(odds) + 100), 100 / (odds + 100))
}

# Normalize player name to lowercase "first last" for cross-source joining.
# Handles "Last, First" (DG) and "First Last" (Odds API) inputs.
.normalize_player_name <- function(x) {
  x <- tolower(trimws(x))
  x <- ifelse(
    grepl(",", x),
    sub("^(.+),\\s*(.+)$", "\\2 \\1", x),
    x
  )
  gsub("[^a-z ]", "", x) |> trimws() |> gsub("\\s+", " ", x = _)
}

#' Fetch Pinnacle win-market odds snapshot for a tournament.
#'
#' Saves to output/eval/odds_<slug>_<year>.rds alongside the other eval
#' artifacts. Call this at the end of 07_pga_preview.R.
#'
#' @param slug  DG tournament slug (e.g. "us_open").
#' @param year  Integer year.
#' @param force_refresh  Bypass on-disk cache and re-fetch.
#'
#' @return Tibble with columns: player_name_raw, player_name_norm,
#'   odds_american, implied_prob_raw, implied_prob_fair. Returns NULL
#'   if the slug has no sport key mapping or Pinnacle returns no data.
fetch_odds_snapshot <- function(slug, year, force_refresh = FALSE) {
  eval_dir   <- file.path(PATH_OUTPUT, "eval")
  if (!dir.exists(eval_dir)) dir.create(eval_dir, recursive = TRUE)
  cache_file <- file.path(eval_dir, sprintf("odds_%s_%d.rds", slug, year))

  if (!force_refresh && file.exists(cache_file)) {
    cli_alert_info("Cache hit: odds_{slug}_{year}")
    return(readRDS(cache_file))
  }

  sport_key <- .ODDS_SPORT_KEYS[[slug]]
  if (is.null(sport_key)) {
    cli_alert_warning(
      "No Odds API sport key for slug '{slug}' — only majors are mapped. Skipping."
    )
    return(NULL)
  }

  cli_alert_info("Fetching Betfair Exchange odds: {sport_key}")
  events <- tryCatch(
    .odds_get(
      paste0("sports/", sport_key, "/odds"),
      list(
        regions     = "uk,eu",
        markets     = "outrights",
        bookmakers  = "betfair_ex_eu",
        oddsFormat  = "american"
      )
    ),
    error = function(e) {
      cli_alert_warning("Odds API fetch failed: {conditionMessage(e)}")
      NULL
    }
  )

  if (is.null(events) || length(events) == 0) {
    cli_alert_warning("No events returned for {sport_key}")
    return(NULL)
  }

  # Match event to target year; fall back to first event if no match
  year_match <- Filter(
    function(e) startsWith(as.character(e$commence_time), as.character(year)),
    events
  )
  ev <- if (length(year_match) > 0) year_match[[1]] else events[[1]]

  # Navigate bookmakers -> betfair_ex_eu -> markets -> outrights -> outcomes
  betfair <- Filter(function(b) identical(b$key, "betfair_ex_eu"), ev$bookmakers)
  if (length(betfair) == 0) {
    cli_alert_warning("Betfair Exchange absent from {sport_key} response")
    return(NULL)
  }

  outrights <- Filter(function(m) identical(m$key, "outrights"), betfair[[1]]$markets)
  if (length(outrights) == 0) {
    cli_alert_warning("No outrights market found for Betfair / {sport_key}")
    return(NULL)
  }

  outcomes <- outrights[[1]]$outcomes
  if (length(outcomes) == 0) return(NULL)

  result <- tibble(
    player_name_raw = purrr::map_chr(outcomes, "name"),
    odds_american   = purrr::map_dbl(outcomes, "price")
  ) |>
    mutate(
      player_name_norm  = .normalize_player_name(player_name_raw),
      implied_prob_raw  = .american_to_prob(odds_american),
      implied_prob_fair = implied_prob_raw / sum(implied_prob_raw, na.rm = TRUE)
    ) |>
    arrange(desc(implied_prob_fair))

  saveRDS(result, cache_file)
  cli_alert_success(
    "Odds snapshot saved: {nrow(result)} players, Betfair Exchange, {sport_key}"
  )
  result
}

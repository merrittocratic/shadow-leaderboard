source("R/00_config.R")

# Calibrate the LIV-to-PGA SG translation weight via OLS.
# Same methodology as the Euro weight (0.5): regress PGA sg_total on LIV
# sg_total for players who appear in both, then use the coefficient as the
# discount factor applied when blending LIV rounds into player_skill_prior.
#
# Requires:
#   - data/cache/historical_raw/liv_YYYY.rds  (from 01b_pull_liv.R)
#   - data/02_player_rounds.rds               (from 02_feature_engineering.R)
#
# Output:
#   - config/liv_round_weight.rds   — scalar used by 02_feature_engineering.R
#   - printed diagnostic table
#
#   Rscript R/02e_liv_weight.R

library(purrr)

cli_h1("LIV round weight calibration")

# ---- 1. Flatten LIV rounds --------------------------------------------------

# Events to exclude from calibration: non-competitive LIV formats
LIV_EXCLUDE_EVENTS <- c("Promotions Event", "Dallas (Team Final--Stroke Play)",
                         "Dallas (Team Final-Stroke Play)")

flatten_liv_sg <- function(event) {
  # Skip non-competitive LIV formats
  if (any(sapply(LIV_EXCLUDE_EVENTS, function(x) grepl(x, event$event_name, fixed = TRUE)))) {
    return(NULL)
  }
  scores     <- event$scores
  round_cols <- intersect(paste0("round_", 1:3), names(scores))
  player_info <- as_tibble(scores[, c("dg_id", "player_name"), drop = FALSE]) |>
    mutate(dg_id = as.integer(dg_id))
  purrr::map_dfr(seq_along(round_cols), function(i) {
    rd <- scores[[round_cols[[i]]]]
    if (!is.data.frame(rd) || !"sg_total" %in% names(rd)) return(NULL)
    bind_cols(player_info,
              tibble(sg_total = rd$sg_total, year = event$year,
                     event_name = event$event_name)) |>
      filter(!is.na(sg_total))
  })
}

liv_files <- list.files(
  file.path(PATH_CACHE, "historical_raw"),
  pattern = "^liv_\\d{4}\\.rds$",
  full.names = TRUE
)

if (length(liv_files) == 0) {
  cli_abort("No LIV cache files found. Run 01b_pull_liv.R first.")
}

liv_rounds <- purrr::map_dfr(liv_files, \(f) purrr::map_dfr(readRDS(f), flatten_liv_sg))
cli_alert_success(
  "LIV rounds: {scales::comma(nrow(liv_rounds))} across years ",
  "{paste(sort(unique(liv_rounds$year)), collapse=', ')}"
)

# ---- 2. Player-year means for LIV ------------------------------------------

liv_yr <- liv_rounds |>
  group_by(dg_id, year) |>
  summarise(
    liv_sg_mean  = mean(sg_total, na.rm = TRUE),
    n_rounds_liv = n(),
    .groups      = "drop"
  )

cli_alert_info(
  "LIV player-years: {nrow(liv_yr)} | unique players: {n_distinct(liv_yr$dg_id)}"
)

# ---- 3. Crossover: LIV players in PGA events --------------------------------
# Load PGA rounds (must exist), filter to LIV-active players from 2022 onward.
# Crossover data is almost exclusively majors (the only PGA events LIV players
# could enter during the 2022-2024 moratorium period).

pga_rounds_path <- file.path(PATH_DATA, "02_player_rounds.rds")
if (!file.exists(pga_rounds_path)) {
  cli_abort("02_player_rounds.rds not found. Run 02_feature_engineering.R first.")
}

pga_rounds <- readRDS(pga_rounds_path)

liv_player_ids <- unique(liv_yr$dg_id)

crossover <- pga_rounds |>
  filter(dg_id %in% liv_player_ids, year >= 2022L) |>
  group_by(dg_id, year) |>
  summarise(
    pga_sg_mean  = mean(sg_total, na.rm = TRUE),
    n_rounds_pga = n(),
    events       = paste(unique(event_name), collapse = "; "),
    .groups      = "drop"
  )

cli_alert_info(
  "Crossover player-years (LIV players in PGA, 2022+): {nrow(crossover)} | ",
  "players: {n_distinct(crossover$dg_id)}"
)

# ---- 4. OLS: pga_sg ~ liv_sg -----------------------------------------------

# Minimum rounds filter: require meaningful sample on both sides.
# Fringe players (Open qualifiers, one-off invitees) with <10 LIV rounds or
# <4 PGA rounds add noise without signal — exclude them from the OLS.
MIN_LIV_ROUNDS <- 10L
MIN_PGA_ROUNDS <-  4L

cal_data <- inner_join(liv_yr, crossover, by = c("dg_id", "year")) |>
  filter(
    !is.na(liv_sg_mean), !is.na(pga_sg_mean),
    n_rounds_liv >= MIN_LIV_ROUNDS,
    n_rounds_pga >= MIN_PGA_ROUNDS
  )

cli_alert_info(
  "Calibration rows after quality filter ",
  "(>={MIN_LIV_ROUNDS} LIV rounds, >={MIN_PGA_ROUNDS} PGA rounds): {nrow(cal_data)}"
)

if (nrow(cal_data) < 5) {
  cli_abort(
    "Too few crossover player-years ({nrow(cal_data)}) to calibrate reliably. ",
    "Check that 02_player_rounds.rds is current and LIV data is loaded."
  )
}

# With-intercept regression (consistent with euro calibration approach)
fit <- lm(pga_sg_mean ~ liv_sg_mean, data = cal_data)
coef_summary <- summary(fit)

liv_weight_raw  <- coef(fit)[["liv_sg_mean"]]
r_squared       <- coef_summary$r.squared
n_obs           <- nrow(cal_data)
ci              <- confint(fit)["liv_sg_mean", ]

cli_h2("OLS result: pga_sg_mean ~ liv_sg_mean")
cli_alert_info("Coefficient (raw):  {round(liv_weight_raw, 3)}")
cli_alert_info("95% CI:             [{round(ci[1], 3)}, {round(ci[2], 3)}]")
cli_alert_info("R-squared:          {round(r_squared, 3)}")
cli_alert_info("N obs:              {n_obs}")
cli_alert_info("Euro weight (ref):  0.500")

# Clamp to [0.2, 0.8] — don't allow extreme values from thin data to blow up
LIV_ROUND_WEIGHT <- round(max(0.2, min(0.8, liv_weight_raw)), 3)

if (abs(LIV_ROUND_WEIGHT - liv_weight_raw) > 0.001) {
  cli_alert_warning(
    "Raw coefficient {round(liv_weight_raw, 3)} clamped to [{0.2}, {0.8}] -> {LIV_ROUND_WEIGHT}"
  )
}

cli_alert_success("LIV_ROUND_WEIGHT: {LIV_ROUND_WEIGHT}")

# ---- 5. Diagnostic table ----------------------------------------------------

cli_h2("Crossover player detail")

player_detail <- cal_data |>
  left_join(
    pga_rounds |> distinct(dg_id, player_name) |> distinct(dg_id, .keep_all = TRUE),
    by = "dg_id"
  ) |>
  select(player_name, year, liv_sg_mean, n_rounds_liv, pga_sg_mean, n_rounds_pga, events) |>
  arrange(player_name, year)

print(player_detail, n = Inf)

# ---- 6. Save weight ---------------------------------------------------------

saveRDS(LIV_ROUND_WEIGHT, file.path(PATH_CONFIG, "liv_round_weight.rds"))
cli_alert_success(
  "Saved LIV_ROUND_WEIGHT = {LIV_ROUND_WEIGHT} to config/liv_round_weight.rds"
)
cli_alert_info(
  "Re-run 02_feature_engineering.R -> 02b -> 06b -> 07 to apply."
)

# ------------------------------------------------------------------------------
# 03_course_weights.R
#
# Compute per-course strokes-gained component weights via variance-share.
#
# Logic: at each course, the variance of each SG component across all rounds
# measures how much that skill differentiated players at that venue. Higher
# variance = more discriminating = matters more. Normalize the four component
# variances to sum to 1 → drop-in weights for course_taxonomy.csv.
#
# Courses below `min_rounds` default to equal weights (0.25 each).
# ------------------------------------------------------------------------------

library(tidyverse)
library(cli)

# ---- Config ------------------------------------------------------------------
input_rounds   <- "data/02_player_rounds.rds"
input_taxonomy <- "config/course_taxonomy.csv"
output_path    <- "config/course_taxonomy_weighted.csv"
min_rounds     <- 40  # Below this, default to equal weights

cli_h1("Course Weight Computation — Variance Share")

# ---- Load --------------------------------------------------------------------
rounds   <- readRDS(input_rounds)
taxonomy <- read_csv(input_taxonomy, show_col_types = FALSE)

cli_alert_info(
  "Loaded {nrow(rounds)} rounds across {n_distinct(rounds$course_num)} courses"
)

# ---- Per-course variance of each SG component --------------------------------
# Drop rows missing any of the four components so all variances use the same
# row set. Keeps the components comparable within a course.
course_variance <- rounds |>
  filter(
    !is.na(sg_ott), !is.na(sg_app), !is.na(sg_arg), !is.na(sg_putt)
  ) |>
  group_by(course_num) |>
  summarise(
    n_rounds = n(),
    var_ott  = var(sg_ott),
    var_app  = var(sg_app),
    var_arg  = var(sg_arg),
    var_putt = var(sg_putt),
    .groups  = "drop"
  )

# ---- Normalize to weights — relative variance --------------------------------
# Raw variance-share always favors putting because putting has higher baseline
# volatility at every course. Relative variance corrects for this: divide each
# course's component variance by the cross-course mean for that component, then
# normalize the four ratios to sum to 1. The weight now reflects how much MORE
# discriminating a skill is at this course vs. a typical tour stop — not its
# raw magnitude.

# Cross-course mean variance (baseline volatility per component)
baseline <- course_variance |>
  filter(n_rounds >= min_rounds) |>
  summarise(
    mean_var_ott  = mean(var_ott),
    mean_var_app  = mean(var_app),
    mean_var_arg  = mean(var_arg),
    mean_var_putt = mean(var_putt)
  )

cli_alert_info(glue::glue(
  "Baseline variance — OTT: {round(baseline$mean_var_ott,3)}  ",
  "APP: {round(baseline$mean_var_app,3)}  ",
  "ARG: {round(baseline$mean_var_arg,3)}  ",
  "PUTT: {round(baseline$mean_var_putt,3)}"
))

course_weights <- course_variance |>
  mutate(
    # Relative variance: how far above/below baseline is each component?
    rel_ott  = var_ott  / baseline$mean_var_ott,
    rel_app  = var_app  / baseline$mean_var_app,
    rel_arg  = var_arg  / baseline$mean_var_arg,
    rel_putt = var_putt / baseline$mean_var_putt,
    rel_sum         = rel_ott + rel_app + rel_arg + rel_putt,
    weight_ott_raw  = rel_ott  / rel_sum,
    weight_app_raw  = rel_app  / rel_sum,
    weight_arg_raw  = rel_arg  / rel_sum,
    weight_putt_raw = rel_putt / rel_sum,
    sufficient_sample = n_rounds >= min_rounds,
    weight_ott  = if_else(sufficient_sample, weight_ott_raw,  0.25),
    weight_app  = if_else(sufficient_sample, weight_app_raw,  0.25),
    weight_arg  = if_else(sufficient_sample, weight_arg_raw,  0.25),
    weight_putt = if_else(sufficient_sample, weight_putt_raw, 0.25)
  )

n_sufficient <- sum(course_weights$sufficient_sample)
n_thin       <- sum(!course_weights$sufficient_sample)

cli_alert_success(
  "Computed data-driven weights for {n_sufficient} courses (>= {min_rounds} rounds)"
)
if (n_thin > 0) {
  cli_alert_warning(
    "Defaulted {n_thin} courses to equal weights (< {min_rounds} rounds)"
  )
}

# ---- Sanity diagnostics ------------------------------------------------------
# Which component is the top driver at each course? This is the quick-look
# sanity check — if 90% of courses come back "putt", something is off.
cli_h2("Distribution of top variance-driver across courses")

top_driver_summary <- course_weights |>
  filter(sufficient_sample) |>
  mutate(
    top_weight = pmax(weight_ott, weight_app, weight_arg, weight_putt),
    top_driver = case_when(
      top_weight == weight_ott  ~ "ott",
      top_weight == weight_app  ~ "app",
      top_weight == weight_arg  ~ "arg",
      top_weight == weight_putt ~ "putt"
    )
  ) |>
  count(top_driver, sort = TRUE) |>
  mutate(pct = round(100 * n / sum(n), 1))

print(top_driver_summary)

# ---- Merge empirical weights into taxonomy -----------------------------------
taxonomy_updated <- taxonomy |>
  select(-any_of(c("weight_ott", "weight_app", "weight_arg", "weight_putt"))) |>
  left_join(
    course_weights |>
      select(course_num, n_rounds, sufficient_sample,
             weight_ott, weight_app, weight_arg, weight_putt),
    by = "course_num"
  )

# ---- Group-level imputation for gap venues -----------------------------------
# Courses missing SG component data (USGA/R&A/Augusta venues, international
# events) get weights imputed from peers sharing course_style × architect_school.
# Fallback: course_style alone if no style×school match exists.

empirical <- taxonomy_updated |>
  filter(sufficient_sample == TRUE) |>
  select(course_num, course_style, architect_school,
         weight_ott, weight_app, weight_arg, weight_putt)

n_empirical <- nrow(empirical)

# Level 1: style × school
group_ss <- empirical |>
  group_by(course_style, architect_school) |>
  summarise(
    imp_ott_ss  = mean(weight_ott,  na.rm = TRUE),
    imp_app_ss  = mean(weight_app,  na.rm = TRUE),
    imp_arg_ss  = mean(weight_arg,  na.rm = TRUE),
    imp_putt_ss = mean(weight_putt, na.rm = TRUE),
    n_ss        = n(),
    .groups     = "drop"
  )

# Level 2: style only (fallback)
group_s <- empirical |>
  group_by(course_style) |>
  summarise(
    imp_ott_s  = mean(weight_ott,  na.rm = TRUE),
    imp_app_s  = mean(weight_app,  na.rm = TRUE),
    imp_arg_s  = mean(weight_arg,  na.rm = TRUE),
    imp_putt_s = mean(weight_putt, na.rm = TRUE),
    n_s        = n(),
    .groups    = "drop"
  )

taxonomy_updated <- taxonomy_updated |>
  left_join(group_ss, by = c("course_style", "architect_school")) |>
  left_join(group_s,  by = "course_style") |>
  mutate(
    weight_source = case_when(
      sufficient_sample == TRUE ~ "empirical",
      !is.na(imp_ott_ss)       ~ paste0("style_x_school (n=", n_ss, ")"),
      !is.na(imp_ott_s)        ~ paste0("style_only (n=", n_s, ")"),
      TRUE                      ~ "grand_mean"
    ),
    weight_ott  = case_when(
      sufficient_sample == TRUE ~ weight_ott,
      !is.na(imp_ott_ss)       ~ imp_ott_ss,
      !is.na(imp_ott_s)        ~ imp_ott_s,
      TRUE                      ~ 0.25
    ),
    weight_app  = case_when(
      sufficient_sample == TRUE ~ weight_app,
      !is.na(imp_app_ss)       ~ imp_app_ss,
      !is.na(imp_app_s)        ~ imp_app_s,
      TRUE                      ~ 0.25
    ),
    weight_arg  = case_when(
      sufficient_sample == TRUE ~ weight_arg,
      !is.na(imp_arg_ss)       ~ imp_arg_ss,
      !is.na(imp_arg_s)        ~ imp_arg_s,
      TRUE                      ~ 0.25
    ),
    weight_putt = case_when(
      sufficient_sample == TRUE ~ weight_putt,
      !is.na(imp_putt_ss)      ~ imp_putt_ss,
      !is.na(imp_putt_s)       ~ imp_putt_s,
      TRUE                      ~ 0.25
    )
  ) |>
  select(-starts_with("imp_"), -n_ss, -n_s)

# ---- Diagnostics -------------------------------------------------------------
cli_h2("Weight source breakdown")
taxonomy_updated |>
  count(weight_source, sort = TRUE) |>
  print()

cli_h2("Spot-check: 15 courses with most empirical rounds")
taxonomy_updated |>
  filter(sufficient_sample == TRUE) |>
  arrange(desc(n_rounds)) |>
  slice_head(n = 15) |>
  select(venue_name, course_style, architect_school, n_rounds,
         weight_ott, weight_app, weight_arg, weight_putt) |>
  mutate(across(starts_with("weight"), \(x) round(x, 3))) |>
  print(n = 15)

cli_h2("Spot-check: key gap venues and their imputed weights")
gap_venues <- c("Shinnecock Hills GC", "Augusta National GC", "Oakmont Country Club",
                "Pinehurst Resort & Country Club (Course No. 2)", "Winged Foot GC",
                "Bethpage Black", "St. Andrews GC (Old Course)", "Carnoustie GC")
taxonomy_updated |>
  filter(venue_name %in% gap_venues) |>
  select(venue_name, course_style, architect_school, weight_source,
         weight_ott, weight_app, weight_arg, weight_putt) |>
  mutate(across(starts_with("weight_o") | starts_with("weight_a") | starts_with("weight_p"),
                \(x) round(x, 3))) |>
  print(n = 10)

# ---- Write output ------------------------------------------------------------
write_csv(taxonomy_updated, output_path)
cli_alert_success(
  "Wrote {output_path} — {n_empirical} empirical, ",
  "{sum(taxonomy_updated$weight_source != 'empirical')} imputed"
)
cli_h1("Done")

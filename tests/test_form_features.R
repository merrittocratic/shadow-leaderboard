# Leakage unit test for form features.
# Sourced by R/02b_form_features.R — also runnable standalone.
#
# For a sample of player-events, manually recomputes form_residual_mean_N
# using only events strictly prior to the current one and asserts the value
# matches the cached result to floating-point precision.
#
# Hard aborts on failure — a leakage bug silently inflates CV accuracy
# and is brutal to catch post-hoc.

test_form_leakage <- function(form_features, event_sg, N = 8, n_checks = 50) {
  col_mean  <- paste0("form_residual_mean_",  N)
  col_slope <- paste0("form_residual_slope_", N)

  stopifnot(col_mean  %in% names(form_features))
  stopifnot(col_slope %in% names(form_features))
  stopifnot(all(c("dg_id", "event_id", "year", "event_completed",
                   "event_residual") %in% names(event_sg)))

  # Only test rows where the feature is non-NA (players with prior history)
  testable <- form_features |>
    filter(!is.na(.data[[col_mean]]))

  if (nrow(testable) == 0) {
    cli_abort("No non-NA rows found for {col_mean} — cannot run leakage test")
  }

  set.seed(42)
  sample_rows <- slice_sample(testable, n = min(n_checks, nrow(testable)))

  slope_fn <- function(x) {
    x <- x[!is.na(x)]
    if (length(x) < 2) return(NA_real_)
    t      <- seq_along(x)
    t_mean <- mean(t)
    x_mean <- mean(x)
    sum((t - t_mean) * (x - x_mean)) / sum((t - t_mean)^2)
  }

  failures <- character(0)

  for (i in seq_len(nrow(sample_rows))) {
    row <- sample_rows[i, ]

    # Ground truth: all events for this player STRICTLY before current event
    prior <- event_sg |>
      filter(dg_id == row$dg_id,
             event_completed < row$event_completed) |>
      arrange(event_completed) |>
      tail(N)

    expected_mean  <- if (nrow(prior) == 0) NA_real_ else mean(prior$event_residual, na.rm = TRUE)
    expected_slope <- if (nrow(prior) < 2)  NA_real_ else slope_fn(prior$event_residual)

    actual_mean  <- row[[col_mean]]
    actual_slope <- row[[col_slope]]

    mean_ok  <- (is.na(expected_mean)  && is.na(actual_mean))  ||
                (!is.na(expected_mean) && !is.na(actual_mean)  &&
                 abs(expected_mean  - actual_mean)  < 1e-8)

    slope_ok <- (is.na(expected_slope) && is.na(actual_slope)) ||
                (!is.na(expected_slope) && !is.na(actual_slope) &&
                 abs(expected_slope - actual_slope) < 1e-8)

    if (!mean_ok) {
      failures <- c(failures, glue::glue(
        "MEAN mismatch: player {row$dg_id} event {row$event_id} {row$year} | ",
        "expected {round(expected_mean, 6)} got {round(actual_mean, 6)}"
      ))
    }
    if (!slope_ok) {
      failures <- c(failures, glue::glue(
        "SLOPE mismatch: player {row$dg_id} event {row$event_id} {row$year} | ",
        "expected {round(expected_slope, 6)} got {round(actual_slope, 6)}"
      ))
    }
  }

  if (length(failures) > 0) {
    cli_abort(c(
      "Leakage test FAILED for N={N} ({length(failures)} mismatches):",
      setNames(failures, rep("x", length(failures)))
    ))
  }

  cli_alert_success(
    "Leakage test PASSED: N={N}, {nrow(sample_rows)} rows verified, no leakage detected"
  )
}

source("R/00_config.R")
library(ggrepel)

# Skill prior vs. rolling 8-event form scatter for the US Open 2026 preview.
# X = player_skill_prior (career reputation / talent estimate)
# Y = form_residual_mean_8 (recent form: last 8 events above/below expectation)
# Illustrates the "Now the Model Knows Why" section: who the model trusts on
# reputation, who on recent form, and who it's skeptical of on both axes.
#
#   Rscript R/graphics_us_open_skill_form_scatter.R

data <- readr::read_csv(
  file.path(PATH_OUTPUT, "us_open_preview_2026.csv"),
  show_col_types = FALSE
) |>
  filter(!is.na(n_events_available), n_events_available > 0)

# ---- Palette -----------------------------------------------------------------
COL_ANCHOR  <- "#1C1C1C"   # Scheffler
COL_FADE    <- "#E63946"   # strong-prior players with cold/flat form
COL_HEAT    <- "#2166AC"   # hot-form players outrunning their prior
COL_GRAY    <- "#BBBBBB"
COL_REFLINE <- "#DDDDDD"
COL_QUAD    <- "#CCCCCC"

# ---- Highlighted players -----------------------------------------------------
# COL_ANCHOR: consensus pick (strong prior + decent form)
# COL_FADE:   strong prior, cold or flat form — broadcast darlings the model is lukewarm on
# COL_HEAT:   weak prior, hot form — running on current form more than reputation
highlight <- tribble(
  ~player_name,           ~color,
  "Scheffler, Scottie",   COL_ANCHOR,
  "Fitzpatrick, Matt",    COL_ANCHOR,
  "McIlroy, Rory",        COL_FADE,
  "Spieth, Jordan",       COL_FADE,
  "Thomas, Justin",       COL_FADE,
  "Scott, Adam",          COL_FADE,
  "Young, Cameron",       COL_HEAT,
  "Hatton, Tyrrell",      COL_HEAT,
  "Burns, Sam",           COL_HEAT,
  "Kim, Si Woo",          COL_HEAT
)

hi_data <- data |>
  inner_join(highlight, by = "player_name") |>
  mutate(
    last_name = stringr::str_extract(player_name, "^[^,]+"),
    label     = paste0(last_name, " (#", rank, ")")
  )

base_data <- data |> filter(!player_name %in% highlight$player_name)

# ---- Axis limits & quadrant labels -------------------------------------------
x_lo <- floor(  min(data$player_skill_prior,   na.rm = TRUE)) - 0.15
x_hi <- ceiling(max(data$player_skill_prior,   na.rm = TRUE)) + 0.15
y_lo <- floor(  min(data$form_residual_mean_8, na.rm = TRUE)) - 0.15
y_hi <- ceiling(max(data$form_residual_mean_8, na.rm = TRUE)) + 0.15

x_inset <- (x_hi - x_lo) * 0.04
y_inset <- (y_hi - y_lo) * 0.04

quad <- tibble(
  x     = c(x_lo + x_inset, x_hi - x_inset, x_lo + x_inset, x_hi - x_inset),
  y     = c(y_hi - y_inset, y_hi - y_inset, y_lo + y_inset, y_lo + y_inset),
  label = c("Running Hot", "Skill + Form", "Long Shots", "Fading Names"),
  hjust = c(0, 1, 0, 1)
)

# ---- Plot --------------------------------------------------------------------
p <- ggplot(base_data, aes(x = player_skill_prior, y = form_residual_mean_8)) +
  geom_vline(xintercept = 0, color = COL_REFLINE, linewidth = 0.7) +
  geom_hline(yintercept = 0, color = COL_REFLINE, linewidth = 0.7) +
  geom_text(
    data  = quad,
    aes(x = x, y = y, label = label, hjust = hjust),
    color    = COL_QUAD,
    fontface = "italic",
    size     = 3.2,
    vjust    = 0.5
  ) +
  geom_point(color = COL_GRAY, size = 1.5, alpha = 0.45) +
  geom_point(
    data  = hi_data,
    aes(color = color),
    size  = 3.6,
    alpha = 0.92
  ) +
  scale_color_identity() +
  geom_label_repel(
    data          = hi_data,
    aes(label = label, color = color),
    size               = 3.1,
    fontface           = "bold",
    fill               = "white",
    label.size         = NA,
    box.padding        = 0.45,
    point.padding      = 0.3,
    segment.color      = "#AAAAAA",
    segment.size       = 0.4,
    min.segment.length = 0.2,
    show.legend        = FALSE,
    seed               = 42
  ) +
  coord_cartesian(xlim = c(x_lo, x_hi), ylim = c(y_lo, y_hi)) +
  labs(
    title    = "Reputation vs. Form — 2026 US Open Field (PGA Championship Proxy)",
    subtitle = "X: career skill prior  |  Y: rolling 8-event SG residual  |  Right of zero = model trusts the name; above zero = player is outrunning expectation",
    caption  = "Merrittocracy | Field: PGA Championship 2026 proxy; course weights: Shinnecock Hills",
    x        = "Player Skill Prior (career talent estimate)",
    y        = "Recent Form (8-event SG residual mean)"
  ) +
  theme_minimal(base_size = 13) +
  theme(
    plot.title       = element_text(face = "bold", size = 15, margin = margin(b = 4)),
    plot.subtitle    = element_text(color = "#666666", size = 10, margin = margin(b = 10)),
    plot.caption     = element_text(color = "#999999", size = 9, hjust = 1),
    plot.margin      = margin(16, 20, 12, 16),
    panel.grid.major = element_line(color = "#F0F0F0", linewidth = 0.4),
    panel.grid.minor = element_blank(),
    axis.title       = element_text(color = "#444444", size = 11),
    axis.text        = element_text(color = "#666666", size = 10)
  )

# ---- Save --------------------------------------------------------------------
dir.create(PATH_GRAPHICS, showWarnings = FALSE, recursive = TRUE)
out_path <- file.path(PATH_GRAPHICS, "us_open_skill_form_scatter.png")

ggsave(
  out_path,
  plot   = p,
  width  = 1600 / 150,
  height = 1000 / 150,
  dpi    = 150
)

cli_alert_success("Saved: {out_path}")

source("R/00_config.R")
library(ggrepel)

data <- read_csv(file.path(PATH_OUTPUT, "pga_preview_2026.csv"), show_col_types = FALSE)

# Drop mean-imputed no-history players (n_events_available = 0 or NA)
data <- data |> filter(!is.na(n_events_available), n_events_available > 0)

# ---- Palette ------------------------------------------------------------------
COL_FLAG    <- "#E63946"   # Reitan — flagged outlier
COL_ACCENT  <- "#2166AC"   # Aberg, Hatton
COL_MUTED   <- "#8B9DB0"   # Young
COL_ANCHOR  <- "#1C1C1C"   # Scheffler, McIlroy
COL_GRAY    <- "#BBBBBB"   # field background dots
COL_REFLINE <- "#CCCCCC"   # quadrant reference lines
COL_QUAD    <- "#CCCCCC"   # quadrant corner labels

# ---- Highlighted players ------------------------------------------------------
highlight <- tribble(
  ~player_name,           ~color,
  "Reitan, Kristoffer",   COL_FLAG,
  "Aberg, Ludvig",        COL_ACCENT,
  "Hatton, Tyrrell",      COL_ACCENT,
  "Young, Cameron",       COL_MUTED,
  "Scheffler, Scottie",   COL_ANCHOR,
  "McIlroy, Rory",        COL_ANCHOR
)

hi_data   <- data |>
  inner_join(highlight, by = "player_name") |>
  mutate(label = paste0(player_name, " (#", rank, ")"))

base_data <- data |> filter(!player_name %in% highlight$player_name)

# ---- Axis limits (leave breathing room around Reitan) -------------------------
x_lo <- floor(min(data$form_residual_mean_8,  na.rm = TRUE)) - 0.3
x_hi <- ceiling(max(data$form_residual_mean_8, na.rm = TRUE)) + 0.3
y_lo <- floor(min(data$form_residual_slope_8,  na.rm = TRUE)) - 0.1
y_hi <- ceiling(max(data$form_residual_slope_8, na.rm = TRUE)) + 0.1

# Quadrant label positions (10% inset from each corner)
x_inset <- (x_hi - x_lo) * 0.10
y_inset <- (y_hi - y_lo) * 0.07

quad <- tibble(
  x     = c(x_lo + x_inset, x_hi - x_inset, x_lo + x_inset, x_hi - x_inset),
  y     = c(y_hi - y_inset, y_hi - y_inset, y_lo + y_inset, y_lo + y_inset),
  label = c("Cold & Heating Up", "Hot & Heating Up", "Cold & Cooling", "Hot & Cooling"),
  hjust = c(0, 1, 0, 1)
)

# ---- Plot ---------------------------------------------------------------------
p <- ggplot(base_data, aes(x = form_residual_mean_8, y = form_residual_slope_8)) +
  geom_vline(xintercept = 0, color = COL_REFLINE, linewidth = 0.7) +
  geom_hline(yintercept = 0, color = COL_REFLINE, linewidth = 0.7) +
  geom_text(
    data = quad,
    aes(x = x, y = y, label = label, hjust = hjust),
    color    = COL_QUAD,
    fontface = "italic",
    size     = 3.4,
    vjust    = 0.5
  ) +
  geom_point(color = COL_GRAY, size = 1.6, alpha = 0.45) +
  geom_point(
    data = hi_data,
    aes(color = color),
    size  = 3.8,
    alpha = 0.92
  ) +
  scale_color_identity() +
  geom_label_repel(
    data          = hi_data,
    aes(label = label, color = color),
    size          = 3.1,
    fontface      = "bold",
    fill          = "white",
    label.size    = NA,
    box.padding   = 0.45,
    point.padding = 0.3,
    segment.color = "#AAAAAA",
    segment.size  = 0.4,
    min.segment.length = 0.2,
    show.legend   = FALSE,
    seed          = 42
  ) +
  coord_cartesian(xlim = c(x_lo, x_hi), ylim = c(y_lo, y_hi)) +
  labs(
    title    = "Form Level vs. Form Trajectory — 2026 PGA Championship Field",
    subtitle = "Rolling 8-event SG residuals; slope estimated via linear trend over same window",
    caption  = "Merrittocracy | Model: player_skill_prior anchored to 2025 year-end values",
    x        = "Recent Form (8-event SG residual mean)",
    y        = "Form Trajectory (8-event residual slope)"
  ) +
  theme_minimal(base_size = 13) +
  theme(
    plot.title       = element_text(face = "bold", size = 15, margin = margin(b = 4)),
    plot.subtitle    = element_text(color = "#666666", size = 11, margin = margin(b = 10)),
    plot.caption     = element_text(color = "#999999", size = 9,  hjust = 1),
    plot.margin      = margin(16, 20, 12, 16),
    panel.grid.major = element_line(color = "#F0F0F0", linewidth = 0.4),
    panel.grid.minor = element_blank(),
    axis.title       = element_text(color = "#444444", size = 11),
    axis.text        = element_text(color = "#666666", size = 10)
  )

# ---- Save ---------------------------------------------------------------------
dir.create(PATH_GRAPHICS, showWarnings = FALSE, recursive = TRUE)
out_path <- file.path(PATH_GRAPHICS, "pga_form_scatter.png")

ggsave(
  out_path,
  plot   = p,
  width  = 1600 / 150,
  height = 1000 / 150,
  dpi    = 150
)

cli_alert_success("Saved: {out_path}")

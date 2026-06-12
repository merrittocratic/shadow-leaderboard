source("R/00_config.R")
library(ggrepel)

# Win probability vs. skill prior scatter — US Open 2026 preview.
# X = player_skill_prior (career reputation / talent estimate)
# Y = win probability (log scale)
# Story: skill prior and win prob correlate, but form-driven players
# (Hatton, Young) punch well above their prior weight, while reputation
# players with flat form (McIlroy) sit lower than their x-position implies.
#
#   Rscript R/graphics_us_open_winprob_prior.R

data <- readr::read_csv(
  file.path(PATH_OUTPUT, "us_open_preview_2026.csv"),
  show_col_types = FALSE
) |>
  filter(!is.na(win_prob), win_prob >= 0.001) |>
  filter(player_skill_prior >= -0.5)

N_FIELD   <- 156L
field_avg <- 1 / N_FIELD

# ---- Palette -----------------------------------------------------------------
COL_ANCHOR  <- "#1C1C1C"   # Scheffler — skill + form
COL_FADE    <- "#E63946"   # strong prior, flat/cold form
COL_HEAT    <- "#2166AC"   # weak prior, hot form
COL_GRAY    <- "#BBBBBB"
COL_REFLINE <- "#DDDDDD"

# ---- Highlighted players -----------------------------------------------------
highlight <- tribble(
  ~player_name,           ~color,
  "Scheffler, Scottie",   COL_ANCHOR,
  "Fitzpatrick, Matt",    COL_ANCHOR,
  "Rahm, Jon",            COL_ANCHOR,
  "McIlroy, Rory",        COL_FADE,
  "Thomas, Justin",       COL_FADE,
  "Spieth, Jordan",       COL_FADE,
  "DeChambeau, Bryson",   COL_ANCHOR,
  "Fleetwood, Tommy",     COL_ANCHOR,
  "Hatton, Tyrrell",      COL_HEAT,
  "Young, Cameron",       COL_HEAT,
  "Burns, Sam",           COL_HEAT,
  "Kim, Si Woo",          COL_HEAT,
  "Poston, J.T.",         COL_HEAT,
  "Spaun, J.J.",          COL_HEAT
)

hi_data <- data |>
  inner_join(highlight, by = "player_name") |>
  mutate(
    last_name = stringr::str_extract(player_name, "^[^,]+"),
    label     = paste0(last_name, " (#", rank, ")")
  )

base_data <- data |> filter(!player_name %in% highlight$player_name)

# ---- Axis limits -------------------------------------------------------------
x_lo <- floor(min(data$player_skill_prior, na.rm = TRUE) * 4) / 4
x_hi <- ceiling(max(data$player_skill_prior, na.rm = TRUE) * 4) / 4

# ---- Plot --------------------------------------------------------------------
p <- ggplot(base_data, aes(x = player_skill_prior, y = win_prob)) +
  geom_hline(
    yintercept = field_avg,
    color      = COL_REFLINE,
    linewidth  = 0.6,
    linetype   = "dashed"
  ) +
  annotate(
    "text",
    x      = x_hi - 0.05,
    y      = field_avg * 1.15,
    label  = "Field average",
    hjust  = 1,
    size   = 3,
    color  = "#BBBBBB",
    fontface = "italic"
  ) +
  geom_point(color = COL_GRAY, size = 1.5, alpha = 0.5) +
  geom_point(
    data  = hi_data,
    aes(color = color),
    size  = 3.6,
    alpha = 0.92
  ) +
  scale_color_identity() +
  scale_y_log10(
    labels = scales::percent_format(accuracy = 0.1),
    breaks = c(0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1)
  ) +
  geom_label_repel(
    data               = hi_data,
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
  coord_cartesian(xlim = c(x_lo, x_hi)) +
  labs(
    title    = "Reputation vs. Win Probability — 2026 US Open",
    subtitle = "X: career skill prior  |  Y: win probability (log scale)  |  Dashed line: field average (1/156)",
    caption  = "Merrittocracy | PGA Championship proxy field; Shinnecock Hills course weights; 2,000 tournament simulations",
    x        = "Player Skill Prior (career SG above field average, per round)",
    y        = "Win Probability"
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
out_path <- file.path(PATH_GRAPHICS, "us_open_winprob_prior.png")

ggsave(
  out_path,
  plot   = p,
  width  = 1600 / 150,
  height = 1000 / 150,
  dpi    = 150
)

cli_alert_success("Saved: {out_path}")

source("R/00_config.R")
library(ggrepel)

# ---- Data -------------------------------------------------------------------
# Model ranks from R3 leaderboard (entering Sunday).
# Final positions confirmed post-tournament.

results <- tribble(
  ~player,            ~model_rank, ~final_pos,  ~story,
  "Aaron Rai",                41,          1,   "outlier",
  "Alex Smalley",             13,          2,   "outperformed",
  "Ludvig Aberg",             16,          4,   "outperformed",
  "Rory McIlroy",              2,          7,   "underperformed",
  "Cameron Young",            11,         31,   "underperformed",
  "Scottie Scheffler",         1,         14,   "underperformed"
)

# ---- Palette ----------------------------------------------------------------

story_colors <- c(
  "outlier"        = "#E63946",   # Rai — dramatic, red
  "outperformed"   = "#2166AC",   # Smalley, Aberg — blue
  "underperformed" = "#666666"    # Scheffler, McIlroy, Young — neutral
)

story_sizes <- c(
  "outlier"        = 5.5,
  "outperformed"   = 4.5,
  "underperformed" = 4.0
)

# ---- Axis limits & diagonal -------------------------------------------------

ax_max <- 48   # enough room for Rai at x=41

# ---- Plot -------------------------------------------------------------------

p <- ggplot(results, aes(x = model_rank, y = final_pos,
                          color = story, size = story)) +
  # Diagonal reference: model rank == actual finish
  geom_segment(aes(x = 1, xend = ax_max, y = 1, yend = ax_max),
               color     = "#AAAAAA",
               linewidth = 0.9,
               linetype  = "dashed",
               inherit.aes = FALSE) +
  # Quadrant annotations
  annotate("text", x = ax_max * 0.78, y = 2.5,
           label = "Outperformed model", color = "#CCCCCC",
           fontface = "italic", size = 3.2, hjust = 0) +
  annotate("text", x = 2, y = ax_max * 0.88,
           label = "Underperformed model", color = "#CCCCCC",
           fontface = "italic", size = 3.2, hjust = 0) +
  # Points
  geom_point(alpha = 0.9) +
  # Labels
  geom_label_repel(
    aes(label = player),
    size           = 3.4,
    fontface       = "bold",
    fill           = "white",
    label.size     = NA,
    box.padding    = 0.5,
    point.padding  = 0.4,
    segment.color  = "#AAAAAA",
    segment.size   = 0.4,
    min.segment.length = 0.2,
    show.legend    = FALSE,
    seed           = 42
  ) +
  scale_color_manual(values = story_colors, guide = "none") +
  scale_size_manual(values  = story_sizes,  guide = "none") +
  scale_x_continuous(
    name   = "Model Rank Entering Sunday",
    limits = c(0, ax_max),
    breaks = c(1, 10, 20, 30, 40),
    expand = c(0.02, 0)
  ) +
  scale_y_reverse(
    name   = "Final Tournament Position",
    limits = c(ax_max, 1),
    breaks = c(1, 5, 10, 15, 20, 25, 30),
    expand = c(0.02, 0)
  ) +
  labs(
    title    = "Model Rank vs. Final Finish — 2026 PGA Championship",
    subtitle = "Dashed line = model was right. Above it = outperformed. Below it = underperformed.",
    caption  = "Merrittocracy | Model rank from post-R3 Round 4 projections"
  ) +
  theme_minimal(base_size = 13) +
  theme(
    plot.title       = element_text(face = "bold", size = 15, margin = margin(b = 4)),
    plot.subtitle    = element_text(color = "#555555", size = 11, margin = margin(b = 10)),
    plot.caption     = element_text(color = "#999999", size = 9, hjust = 1),
    plot.margin      = margin(16, 20, 12, 16),
    panel.grid.major = element_line(color = "#F0F0F0", linewidth = 0.4),
    panel.grid.minor = element_blank(),
    axis.title       = element_text(color = "#444444", size = 11),
    axis.text        = element_text(color = "#666666", size = 10)
  )

# ---- Save -------------------------------------------------------------------

dir.create(PATH_GRAPHICS, showWarnings = FALSE, recursive = TRUE)
out_path <- file.path(PATH_GRAPHICS, "model_vs_finish.png")

ggsave(out_path, plot = p, width = 1600 / 150, height = 1000 / 150, dpi = 150)
cli_alert_success("Saved: {out_path}")

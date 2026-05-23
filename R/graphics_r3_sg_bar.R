source("R/00_config.R")
library(stringr)

# ---- Data -------------------------------------------------------------------

r3_raw <- readRDS(
  list.files("data/cache/live_tournament_stats", full.names = TRUE, pattern = "r3") |>
    sort() |> tail(1)
)[["live_stats"]] |>
  as_tibble() |>
  mutate(dg_id = as.integer(dg_id))

r2_raw <- readRDS(
  list.files("data/cache/live_tournament_stats", full.names = TRUE, pattern = "r2") |>
    sort() |> tail(1)
)[["live_stats"]] |>
  as_tibble() |>
  mutate(dg_id = as.integer(dg_id))

ranks <- readRDS("output/live_leaderboard_after_r3.rds") |> as_tibble()

# Cut survivors (still from R2 — one cut in a major)
made_cut_ids <- r2_raw |>
  mutate(pos_num = as.integer(str_remove(position, "^T"))) |>
  filter(!is.na(pos_num), pos_num <= 70L) |>
  pull(dg_id)

base <- r3_raw |>
  filter(dg_id %in% made_cut_ids) |>
  select(dg_id, player_name, sg_r3 = sg_total) |>
  left_join(ranks |> select(rank, player_name, sg_r1, sg_r2), by = "player_name") |>
  arrange(desc(sg_r3), rank)

# Top 8 by R3 SG + Smalley forced in
plot_data <- bind_rows(
  slice(base, 1:8),
  filter(base, player_name == "Smalley, Alex")
) |>
  distinct(player_name, .keep_all = TRUE) |>
  arrange(sg_r3, desc(rank)) |>
  mutate(
    display_name = str_replace(player_name, "^(.*?),\\s*(.*?)$", "\\2 \\1"),
    rank_label   = paste0("#", rank),
    rank_tier    = case_when(
      player_name == "Smalley, Alex" ~ "Weekend pick — prior & form aligned",
      rank <= 15                     ~ "Top 15 — model agrees",
      rank <= 30                     ~ "Ranks 16–30 — cautious",
      TRUE                           ~ "Rank 31+ — prior anchor"
    ) |> factor(levels = c("Top 15 — model agrees",
                           "Ranks 16–30 — cautious",
                           "Rank 31+ — prior anchor",
                           "Weekend pick — prior & form aligned"))
  )

# ---- Palette ----------------------------------------------------------------

COL_AGREES  <- "#1C1C1C"
COL_CAUTION <- "#2166AC"
COL_MISSED  <- "#E63946"
COL_PICK    <- "#C0792A"   # amber — Smalley

tier_colors <- c(
  "Top 15 — model agrees"               = COL_AGREES,
  "Ranks 16–30 — cautious"              = COL_CAUTION,
  "Rank 31+ — prior anchor"             = COL_MISSED,
  "Weekend pick — prior & form aligned" = COL_PICK
)

# Smalley annotation
smalley_row  <- plot_data |> filter(player_name == "Smalley, Alex")
smalley_note <- sprintf(
  "leads tournament  ·  R1: +%.2f  R2: +%.2f",
  smalley_row$sg_r1, smalley_row$sg_r2
)

# ---- Plot -------------------------------------------------------------------

x_max <- max(plot_data$sg_r3) + 2.8

p <- ggplot(plot_data,
            aes(x    = sg_r3,
                y    = reorder(display_name, sg_r3),
                fill = rank_tier)) +
  geom_col(width = 0.65, alpha = 0.88) +
  # SG value inside bar
  geom_text(
    aes(label = sprintf("+%.0f", sg_r3),
        x     = sg_r3 - 0.12),
    hjust    = 1,
    color    = "white",
    fontface = "bold",
    size     = 3.8
  ) +
  # Model rank to the right of bar
  geom_text(
    aes(label = rank_label,
        x     = sg_r3 + 0.15,
        color = rank_tier),
    hjust    = 0,
    fontface = "bold",
    size     = 3.8
  ) +
  # Smalley callout
  geom_text(
    data     = smalley_row,
    aes(x = sg_r3 + 0.75, y = display_name, label = smalley_note),
    hjust    = 0,
    color    = COL_PICK,
    fontface = "italic",
    size     = 3.2
  ) +
  scale_fill_manual(values  = tier_colors, name = "Model rank") +
  scale_color_manual(values = tier_colors, guide = "none") +
  scale_x_continuous(
    limits = c(0, x_max),
    expand = c(0, 0),
    breaks = 0:7,
    labels = function(x) ifelse(x == 0, "0", paste0("+", x))
  ) +
  labs(
    title    = "Round 3 Strokes Gained vs. Model's Round 4 Ranking",
    subtitle = "Moving Day leaders — and where the model sees them heading into Sunday",
    caption  = "Merrittocracy | PGA Championship 2026 | Model rank = post-R3 projection for Round 4",
    x        = "Round 3 SG Total",
    y        = NULL
  ) +
  theme_minimal(base_size = 13) +
  theme(
    plot.title         = element_text(face = "bold", size = 15, margin = margin(b = 4)),
    plot.subtitle      = element_text(color = "#555555", size = 11, margin = margin(b = 10)),
    plot.caption       = element_text(color = "#999999", size = 9, hjust = 1),
    plot.margin        = margin(16, 24, 12, 16),
    legend.position    = "bottom",
    legend.title       = element_text(size = 10, face = "bold"),
    legend.text        = element_text(size = 9),
    panel.grid.major.y = element_blank(),
    panel.grid.major.x = element_line(color = "#F0F0F0", linewidth = 0.4),
    panel.grid.minor   = element_blank(),
    axis.text.y        = element_text(size = 11, face = "bold", color = "#1C1C1C"),
    axis.text.x        = element_text(size = 10, color = "#666666")
  )

# ---- Save -------------------------------------------------------------------

dir.create(PATH_GRAPHICS, showWarnings = FALSE, recursive = TRUE)
out_path <- file.path(PATH_GRAPHICS, "r3_sg_bar.png")

ggsave(out_path, plot = p, width = 1600 / 150, height = 1000 / 150, dpi = 150)
cli_alert_success("Saved: {out_path}")

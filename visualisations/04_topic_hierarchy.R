#!/usr/bin/env Rscript

# LivingEvidenceMap topic hierarchy visualisations
#
# Creates:
#   1. One high-level bar chart using UNIQUE RECORD counts.
#   2. One vertical icicle plot for each top-level topic.
#
# The icicles use topic-assignment frequency as width. Level 2 is the parent
# band and Level 3 is the terminal band. Terminal labels are deliberately
# separated from the geometry: each leaf gets a short numbered key in the
# icicle, with the full Level 2 > Level 3 taxonomy printed in a clean label
# key beneath it. This avoids the unreadable label collisions of dense
# icicles while retaining an explicit label for every category.

required <- c("dplyr", "ggplot2", "readr", "tidyr", "stringr", "scales")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing) > 0) stop("Install required packages: ", paste(missing, collapse = ", "))

library(dplyr)
library(ggplot2)
library(readr)
library(tidyr)
library(stringr)
library(scales)
library(here)

master_path <- here::here("data", "master", "current", "living_evidence_map_master CORRECTED.csv")
out_dir <- here::here("visualisations", "topic_hierarchy")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

# LivingEvidenceMap palette.
palette <- c("#2c454a", "#577c84", "#a8bdbe", "#e2b8a2", "#ff9d78", "#e55634")

master <- readr::read_csv(master_path, show_col_types = FALSE, progress = FALSE)
if (!"topic_hierarchy_paths" %in% names(master)) {
  stop("Required column missing from master: topic_hierarchy_paths")
}

raw_paths <- master %>%
  transmute(record_id = row_number(), raw_path = as.character(topic_hierarchy_paths)) %>%
  filter(!is.na(raw_path), str_trim(raw_path) != "") %>%
  mutate(path = str_split(raw_path, "\\s*;\\s*")) %>%
  unnest(path) %>%
  mutate(path = str_squish(path)) %>%
  filter(path != "") %>%
  distinct(record_id, path)

parts <- str_split(raw_paths$path, "\\s*>\\s*")
max_depth <- max(lengths(parts))
for (i in seq_len(max_depth)) {
  raw_paths[[paste0("level", i)]] <- vapply(
    parts,
    function(x) if (length(x) >= i) str_squish(x[i]) else NA_character_,
    character(1)
  )
}

# -------------------------------------------------------------------------
# 1. HIGH-LEVEL OVERVIEW: UNIQUE RECORDS
# -------------------------------------------------------------------------

top_counts <- raw_paths %>%
  distinct(record_id, level1) %>%
  count(level1, name = "unique_records") %>%
  arrange(unique_records)

overview <- ggplot(top_counts, aes(x = unique_records, y = reorder(level1, unique_records))) +
  geom_col(fill = palette[1], width = 0.68) +
  geom_text(aes(label = comma(unique_records)), hjust = -0.12, size = 3.5, colour = palette[1]) +
  scale_x_continuous(labels = comma, expand = expansion(mult = c(0, .10))) +
  labs(
    title = "LivingEvidenceMap: topic distribution",
    subtitle = "Unique records assigned to each top-level topic",
    x = "Unique records", y = NULL,
    caption = "Each record is counted once within each top-level topic; records may be assigned to multiple topics."
  ) +
  theme_minimal(base_size = 11) +
  theme(
    panel.grid.major.y = element_blank(), panel.grid.minor = element_blank(),
    axis.text.y = element_text(colour = palette[1], face = "bold"),
    axis.text.x = element_text(colour = palette[2]), axis.title.x = element_text(colour = palette[2]),
    plot.title = element_text(face = "bold", size = 16, colour = palette[1]),
    plot.subtitle = element_text(colour = palette[2]),
    plot.caption = element_text(colour = palette[2], hjust = 0),
    plot.margin = margin(12, 30, 12, 12)
  )

ggsave(file.path(out_dir, "figure_04a_top_level_topics.pdf"), overview, width = 190, height = 125, units = "mm")
ggsave(file.path(out_dir, "figure_04a_top_level_topics.png"), overview, width = 190, height = 125, units = "mm", dpi = 600)
write_csv(top_counts, file.path(out_dir, "topic_top_level_unique_record_counts.csv"))

# -------------------------------------------------------------------------
# 2. VERTICAL ICICLE PLOTS
# -------------------------------------------------------------------------

make_icicle <- function(root, dat, file_stub) {
  d <- dat %>%
    filter(level1 == root) %>%
    mutate(
      terminal = case_when(
        !is.na(level3) & level3 != "" ~ paste(level2, level3, sep = " > "),
        !is.na(level2) & level2 != "" ~ level2,
        TRUE ~ level1
      )
    ) %>%
    count(level2, level3, terminal, name = "assignments") %>%
    arrange(level2, desc(assignments), terminal)

  if (nrow(d) == 0) return(invisible(NULL))

  parent_order <- d %>%
    group_by(level2) %>%
    summarise(parent_assignments = sum(assignments), .groups = "drop") %>%
    arrange(desc(parent_assignments), level2) %>%
    mutate(parent_index = row_number())

  d <- d %>%
    left_join(parent_order, by = "level2") %>%
    arrange(parent_index, desc(assignments), terminal) %>%
    mutate(
      xmin = lag(cumsum(assignments), default = 0),
      xmax = cumsum(assignments),
      leaf_id = row_number()
    )

  parents <- d %>%
    group_by(level2, parent_index) %>%
    summarise(
      xmin = min(xmin), xmax = max(xmax), assignments = sum(assignments),
      .groups = "drop"
    ) %>%
    arrange(xmin)

  total <- max(d$xmax)
  n_leaf <- nrow(d)

  parent_cols <- setNames(
    rep(palette, length.out = nrow(parent_order)),
    as.character(parent_order$parent_index)
  )

  # -----------------------------------------------------------------------
  # The key is the important design change. Dense terminal labels do not fit
  # inside their proportional rectangles. Instead each rectangle carries a
  # compact leaf number, and the full taxonomy is printed once in an ordered,
  # two-column key beneath the icicle. This keeps every label readable while
  # preserving an exact one-to-one mapping to the plotted leaf.
  # -----------------------------------------------------------------------

  d <- d %>%
    mutate(
      id_label = as.character(leaf_id),
      full_label = terminal
    )

  # Allocate the label key in two columns, with roughly equal numbers of rows.
  n_left <- ceiling(n_leaf / 2)
  d <- d %>%
    mutate(
      key_col = if_else(leaf_id <= n_left, 1L, 2L),
      key_row = if_else(leaf_id <= n_left, leaf_id, leaf_id - n_left)
    )

  n_rows <- max(d$key_row)
  key_height <- max(2.8, n_rows * 0.20 + 0.55)
  icicle_height <- 5.0

  # Parent band and leaf band occupy the upper part of the figure.
  parent_ymin <- 3.72
  parent_ymax <- 4.55
  leaf_ymin <- 0.28
  leaf_ymax <- 3.62

  p <- ggplot() +
    # Level 2 parent band.
    geom_rect(
      data = parents,
      aes(xmin = xmin, xmax = xmax, ymin = parent_ymin, ymax = parent_ymax,
          fill = factor(parent_index)),
      colour = "white", linewidth = 0.9
    ) +
    # Level 3 terminal band.
    geom_rect(
      data = d,
      aes(xmin = xmin, xmax = xmax, ymin = leaf_ymin, ymax = leaf_ymax,
          fill = factor(parent_index)),
      colour = "white", linewidth = 0.45, alpha = 0.52
    ) +
    # Level 2 labels: only these are placed inside the rectangles.
    geom_text(
      data = parents,
      aes(x = (xmin + xmax) / 2, y = (parent_ymin + parent_ymax) / 2,
          label = level2),
      colour = "white", fontface = "bold", size = 3.0,
      lineheight = 0.9, check_overlap = FALSE
    ) +
    # Compact leaf numbers. Every leaf has one and only one number.
    geom_text(
      data = d,
      aes(x = (xmin + xmax) / 2, y = (leaf_ymin + leaf_ymax) / 2,
          label = id_label),
      colour = palette[1], fontface = "bold", size = 2.3,
      check_overlap = FALSE
    ) +
    scale_fill_manual(values = parent_cols, guide = "none") +
    scale_x_continuous(limits = c(0, total), expand = expansion(mult = c(0.008, 0.008))) +
    scale_y_continuous(limits = c(-0.05, icicle_height), expand = c(0, 0)) +
    labs(
      title = root,
      subtitle = "Topic-assignment frequency; width represents the number of assignments",
      x = NULL, y = NULL
    ) +
    theme_void(base_size = 10) +
    theme(
      plot.title = element_text(face = "bold", size = 18, colour = palette[1], hjust = 0,
                                margin = margin(b = 3)),
      plot.subtitle = element_text(size = 10, colour = palette[2], hjust = 0,
                                   margin = margin(b = 12)),
      plot.margin = margin(18, 18, 8, 18)
    )

  # -----------------------------------------------------------------------
  # Add the label key below the icicle in figure coordinates. The key uses
  # evenly spaced x positions rather than assignment coordinates, so long
  # taxonomy labels never collide merely because their topic is small.
  # -----------------------------------------------------------------------

  key_left <- d %>% filter(key_col == 1)
  key_right <- d %>% filter(key_col == 2)
  key_x1 <- total * 0.02
  key_x2 <- total * 0.52
  row_gap <- min(0.24, (icicle_height - 4.75) / max(1, n_rows))
  # Use a dedicated lower coordinate range; rows are evenly spaced.
  key_top <- -0.28
  key_bottom <- -(0.55 + n_rows * 0.23)

  key_left <- key_left %>% mutate(
    x = key_x1,
    y = key_top - (key_row - 1) * 0.23,
    key_text = paste0(leaf_id, ".  ", full_label)
  )
  key_right <- key_right %>% mutate(
    x = key_x2,
    y = key_top - (key_row - 1) * 0.23,
    key_text = paste0(leaf_id, ".  ", full_label)
  )

  # Extend the plotting range to include the key. The key is horizontal,
  # wrapped manually so very long taxonomy strings remain readable.
  wrap_width <- 58
  key_left$key_text <- str_wrap(key_left$key_text, width = wrap_width)
  key_right$key_text <- str_wrap(key_right$key_text, width = wrap_width)

  p <- p +
    geom_text(data = key_left, aes(x = x, y = y, label = key_text),
              inherit.aes = FALSE, hjust = 0, vjust = 1,
              colour = palette[1], size = 2.45, lineheight = 0.9) +
    geom_text(data = key_right, aes(x = x, y = y, label = key_text),
              inherit.aes = FALSE, hjust = 0, vjust = 1,
              colour = palette[1], size = 2.45, lineheight = 0.9) +
    annotate("text", x = key_x1, y = 0.02,
             label = "Leaf key — full Level 2 > Level 3 taxonomy",
             hjust = 0, vjust = 0, fontface = "bold", size = 2.8, colour = palette[2])

  # A restrained assignment scale remains below the icicle but above the key.
  breaks <- pretty(c(0, total), n = 5)
  breaks <- breaks[breaks >= 0 & breaks <= total]
  if (length(breaks) >= 2) {
    p <- p +
      geom_segment(
        data = data.frame(x = breaks, xend = breaks, y = 0.16, yend = 0.05),
        aes(x = x, xend = xend, y = y, yend = yend),
        inherit.aes = FALSE, colour = "grey65", linewidth = 0.35
      ) +
      annotate("text", x = breaks, y = 0.10, label = comma(breaks),
               colour = "grey55", size = 2.4, vjust = 1)
  }

  # Portrait publication layout. The full taxonomy key is deliberately given
  # substantial space; readability takes precedence over compactness.
  plot_height <- 155 + n_rows * 4.0
  ggsave(file.path(out_dir, paste0(file_stub, ".pdf")),
         p, width = 210, height = plot_height, units = "mm", device = cairo_pdf)
  ggsave(file.path(out_dir, paste0(file_stub, ".png")),
         p, width = 210, height = plot_height, units = "mm", dpi = 600)

  write_csv(d %>% select(leaf_id, level2, level3, terminal, assignments),
            file.path(out_dir, paste0(file_stub, "_assignments.csv")))

  invisible(p)
}

roots <- top_counts %>% arrange(desc(unique_records)) %>% pull(level1)

for (i in seq_along(roots)) {
  root <- roots[i]
  safe_root <- str_replace_all(str_to_lower(root), "[^a-z0-9]+", "_")
  stub <- paste0("figure_04", letters[i], "_icicle_", safe_root)
  make_icicle(root, raw_paths, stub)
}

message("Topic visualisations written to: ", out_dir)

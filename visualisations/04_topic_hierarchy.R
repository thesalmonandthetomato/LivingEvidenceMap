#!/usr/bin/env Rscript

# LivingEvidenceMap topic hierarchy visualisations
#
# Creates:
#   1. One high-level bar chart using UNIQUE RECORD counts.
#   2. One vertical icicle plot for each top-level topic.
#
# The icicles use topic-assignment frequency as width. Level 2 is the parent
# band and Level 3 is the terminal band. Every terminal category is labelled.
# The vertical orientation follows the conventional icicle layout and gives
# long taxonomy labels substantially more room.

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

# Expand semicolon-delimited topic paths. A record contributes once to each
# exact topic path, which is the assignment-frequency denominator for icicles.
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
#
# Conventional vertical icicle orientation:
#   root / title
#   Level 2 parent band
#   Level 3 terminal band
#
# Width is proportional to assignment frequency. Level 3 labels are rotated
# vertically so every taxonomy path can be printed without the severe
# horizontal collisions produced by the previous landscape implementation.
# This follows the standard icicle design: children occupy exactly the width
# of their parent and descend from it in successive rows.

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

  # Largest Level 2 branches first; alphabetical order breaks ties.
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
      xmax = cumsum(assignments)
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

  # Labels are full paths as requested. They are rotated 90 degrees in the
  # terminal band; this uses vertical space rather than competing for the
  # narrow horizontal widths of small leaves.
  d <- d %>%
    mutate(
      label = terminal,
      label_size = case_when(
        nchar(label) > 65 ~ 2.0,
        nchar(label) > 48 ~ 2.15,
        TRUE ~ 2.35
      )
    )

  # Give the child band enough height for the longest rotated label. This is
  # deliberately generous: readability is more important than compactness.
  child_height <- 1.35
  parent_height <- 0.48

  p <- ggplot() +
    # Level 2 parent band.
    geom_rect(
      data = parents,
      aes(xmin = xmin, xmax = xmax, ymin = child_height + 0.10,
          ymax = child_height + 0.10 + parent_height, fill = factor(parent_index)),
      colour = "white", linewidth = 0.9
    ) +
    # Level 3 terminal band.
    geom_rect(
      data = d,
      aes(xmin = xmin, xmax = xmax, ymin = 0.08, ymax = child_height,
          fill = factor(parent_index)),
      colour = "white", linewidth = 0.55, alpha = 0.48
    ) +
    # Level 2 labels are horizontal and centred in their parent rectangles.
    geom_text(
      data = parents,
      aes(x = (xmin + xmax) / 2,
          y = child_height + 0.10 + parent_height / 2,
          label = level2),
      colour = "white", fontface = "bold", size = 3.0,
      lineheight = 0.9, check_overlap = FALSE
    ) +
    # Every terminal taxonomy path gets one vertical label.
    geom_text(
      data = d,
      aes(x = (xmin + xmax) / 2, y = 0.02, label = label, size = label_size),
      angle = 90,
      hjust = 0,
      vjust = 0.5,
      colour = palette[1],
      lineheight = 0.9,
      check_overlap = FALSE,
      show.legend = FALSE
    ) +
    scale_fill_manual(values = parent_cols, guide = "none") +
    scale_size_identity() +
    scale_x_continuous(limits = c(0, total), expand = expansion(mult = c(0.008, 0.008))) +
    scale_y_continuous(limits = c(-0.12, child_height + parent_height + 0.28), expand = c(0, 0)) +
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
      plot.margin = margin(18, 22, 28, 22)
    )

  # A restrained numeric scale is placed beneath the taxonomy, keeping the
  # hierarchy itself uncluttered.
  breaks <- pretty(c(0, total), n = 5)
  breaks <- breaks[breaks >= 0 & breaks <= total]
  if (length(breaks) >= 2) {
    p <- p +
      geom_segment(
        data = data.frame(x = breaks, xend = breaks, y = -0.02, yend = -0.07),
        aes(x = x, xend = xend, y = y, yend = yend),
        inherit.aes = FALSE, colour = "grey65", linewidth = 0.35
      ) +
      annotate("text", x = breaks, y = -0.10, label = comma(breaks),
               colour = "grey55", size = 2.5, vjust = 1)
  }

  # Portrait publication layout: the conventional top-to-bottom icicle is
  # intentionally taller than wide so the rotated labels have room to breathe.
  ggsave(file.path(out_dir, paste0(file_stub, ".pdf")),
         p, width = 210, height = 297, units = "mm", device = cairo_pdf)
  ggsave(file.path(out_dir, paste0(file_stub, ".png")),
         p, width = 210, height = 297, units = "mm", dpi = 600)

  write_csv(d %>% select(level2, level3, terminal, assignments),
            file.path(out_dir, paste0(file_stub, "_assignments.csv")))

  invisible(p)
}

# Largest high-level topics first, matching the overview's substantive order.
roots <- top_counts %>% arrange(desc(unique_records)) %>% pull(level1)

for (i in seq_along(roots)) {
  root <- roots[i]
  safe_root <- str_replace_all(str_to_lower(root), "[^a-z0-9]+", "_")
  stub <- paste0("figure_04", letters[i], "_icicle_", safe_root)
  make_icicle(root, raw_paths, stub)
}

message("Topic visualisations written to: ", out_dir)

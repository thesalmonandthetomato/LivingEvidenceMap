#!/usr/bin/env Rscript

# LivingEvidenceMap topic hierarchy visualisations
#
# Creates:
#   1. One high-level bar chart using UNIQUE RECORD counts.
#   2. One hierarchical horizontal bar plot for each top-level topic.
#
# The secondary figures deliberately use horizontal bars rather than forcing
# dense taxonomy labels into an icicle. Each Level 3 topic is a readable row;
# bar length represents topic-assignment frequency and colour identifies the
# Level 2 parent.

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

palette <- c("#2c454a", "#577c84", "#a8bdbe", "#e2b8a2", "#ff9d78", "#e55634")

master <- readr::read_csv(master_path, show_col_types = FALSE, progress = FALSE)
if (!"topic_hierarchy_paths" %in% names(master)) stop("Required column missing from master: topic_hierarchy_paths")

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
  raw_paths[[paste0("level", i)]] <- vapply(parts, function(x) if (length(x) >= i) str_squish(x[i]) else NA_character_, character(1))
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
  labs(title = "LivingEvidenceMap: topic distribution", subtitle = "Unique records assigned to each top-level topic", x = "Unique records", y = NULL,
       caption = "Each record is counted once within each top-level topic; records may be assigned to multiple topics.") +
  theme_minimal(base_size = 11) +
  theme(panel.grid.major.y = element_blank(), panel.grid.minor = element_blank(),
        axis.text.y = element_text(colour = palette[1], face = "bold"),
        axis.text.x = element_text(colour = palette[2]), axis.title.x = element_text(colour = palette[2]),
        plot.title = element_text(face = "bold", size = 16, colour = palette[1]),
        plot.subtitle = element_text(colour = palette[2]), plot.caption = element_text(colour = palette[2], hjust = 0),
        plot.background = element_rect(fill = "white", colour = NA), panel.background = element_rect(fill = "white", colour = NA),
        plot.margin = margin(12, 30, 12, 12))

ggsave(file.path(out_dir, "figure_04a_top_level_topics.pdf"), overview, width = 190, height = 125, units = "mm")
ggsave(file.path(out_dir, "figure_04a_top_level_topics.png"), overview, width = 190, height = 125, units = "mm", dpi = 600)
write_csv(top_counts, file.path(out_dir, "topic_top_level_unique_record_counts.csv"))

# -------------------------------------------------------------------------
# 2. HIERARCHICAL HORIZONTAL BAR PLOTS
# -------------------------------------------------------------------------
#
# Each row is one Level 2 > Level 3 category.
#   - bar length = number of topic assignments
#   - colour = Level 2 parent
#   - label = full Level 2 > Level 3 taxonomy path
#
# Rows are grouped by Level 2 and separated visually. Level 2 parents are
# ordered by total assignments; children are ordered within each group by
# assignment frequency. The figure height expands with the number of rows.

make_hierarchy <- function(root, dat, file_stub) {
  d <- dat %>%
    filter(level1 == root) %>%
    mutate(level2 = if_else(is.na(level2) | level2 == "", level1, level2),
           level3 = if_else(is.na(level3) | level3 == "", level2, level3)) %>%
    count(level2, level3, name = "assignments")

  if (nrow(d) == 0) return(invisible(NULL))

  parent_order <- d %>%
    group_by(level2) %>%
    summarise(parent_assignments = sum(assignments), .groups = "drop") %>%
    arrange(desc(parent_assignments), level2) %>%
    mutate(parent_index = row_number())

  d <- d %>%
    left_join(parent_order, by = "level2") %>%
    arrange(parent_index, desc(assignments), level3) %>%
    mutate(full_label = if_else(level3 == level2, level2, paste0(level2, " > ", level3)),
           label = factor(full_label, levels = rev(full_label)),
           parent_factor = factor(level2, levels = parent_order$level2))

  n_rows <- nrow(d)
  plot_height <- max(150, 52 + n_rows * 5.2)
  parent_cols <- setNames(rep(palette, length.out = nrow(parent_order)), parent_order$level2)

  p <- ggplot(d, aes(x = assignments, y = label, fill = parent_factor)) +
    geom_col(width = 0.72, show.legend = FALSE) +
    geom_text(aes(label = comma(assignments)), hjust = -0.12, size = 2.7, colour = palette[1], show.legend = FALSE) +
    scale_fill_manual(values = parent_cols, drop = FALSE) +
    scale_x_continuous(labels = comma, expand = expansion(mult = c(0, 0.10))) +
    labs(title = root, subtitle = "Topic-assignment frequency by Level 2 > Level 3 category", x = "Topic assignments", y = NULL,
         caption = "Bar length represents assignment frequency; colour identifies the Level 2 parent.") +
    theme_minimal(base_size = 10.5) +
    theme(panel.grid.major.y = element_blank(), panel.grid.minor = element_blank(),
          panel.grid.major.x = element_line(colour = "#e5e8e9", linewidth = 0.35),
          axis.text.y = element_text(colour = palette[1], size = 7.2, lineheight = 0.95),
          axis.text.x = element_text(colour = palette[2], size = 8.5),
          axis.title.x = element_text(colour = palette[2], size = 9.5, margin = margin(t = 7)),
          plot.title = element_text(face = "bold", size = 18, colour = palette[1], margin = margin(b = 3)),
          plot.subtitle = element_text(colour = palette[2], size = 10.5, margin = margin(b = 12)),
          plot.caption = element_text(colour = palette[2], size = 7.5, hjust = 0, margin = margin(t = 8)),
          plot.background = element_rect(fill = "white", colour = NA), panel.background = element_rect(fill = "white", colour = NA),
          plot.margin = margin(16, 28, 16, 12))

  group_sizes <- d %>% count(parent_index, name = "n") %>% arrange(parent_index)
  boundaries <- cumsum(group_sizes$n) + 0.5
  boundaries <- boundaries[-length(boundaries)]
  if (length(boundaries)) {
    p <- p + geom_hline(yintercept = boundaries, colour = "#cfd6d7", linewidth = 0.7, inherit.aes = FALSE)
  }

  write_csv(d %>% select(level2, level3, full_label, assignments), file.path(out_dir, paste0(file_stub, "_assignments.csv")))

  ggsave(file.path(out_dir, paste0(file_stub, ".pdf")), p, width = 220, height = plot_height, units = "mm", device = cairo_pdf)
  ggsave(file.path(out_dir, paste0(file_stub, ".png")), p, width = 220, height = plot_height, units = "mm", dpi = 600)
  invisible(p)
}

roots <- top_counts %>% arrange(desc(unique_records)) %>% pull(level1)
for (i in seq_along(roots)) {
  root <- roots[i]
  safe_root <- str_replace_all(str_to_lower(root), "[^a-z0-9]+", "_")
  stub <- paste0("figure_04", letters[i], "_hierarchy_", safe_root)
  make_hierarchy(root, raw_paths, stub)
}

message("Topic visualisations written to: ", out_dir)

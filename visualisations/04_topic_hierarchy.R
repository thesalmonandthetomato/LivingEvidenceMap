#!/usr/bin/env Rscript

# LivingEvidenceMap topic hierarchy visualisations
#
# Creates:
#   1. One high-level bar chart using UNIQUE RECORD counts, with species
#      composition shown by stacked colour segments.
#   2. One hierarchical horizontal bar plot for each top-level topic.
#
# Plotting/layout logic is retained from the agreed manuscript script.
# Only the data layer has been migrated from the legacy CSV master to the
# authoritative Workflow 08 included-only canonical JSONL.

required <- c("dplyr", "ggplot2", "readr", "tidyr", "stringr", "scales", "here", "jsonlite")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing) > 0) stop("Install required packages: ", paste(missing, collapse = ", "))

library(dplyr)
library(ggplot2)
library(readr)
library(tidyr)
library(stringr)
library(scales)
library(here)

source(here::here("visualisations", "canonical_figure_data.R"))

out_dir <- here::here("visualisations", "topic_hierarchy")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

palette <- c("#2c454a", "#577c84", "#a8bdbe", "#e2b8a2", "#ff9d78", "#e55634")

# Keep species colouring and ordering exactly aligned with Figures 1 and 2.
canonical_species <- c("Atlantic salmon", "Chinook salmon", "Chum salmon", "Coho salmon", "Masu salmon", "Pink salmon", "Sockeye salmon", "Rainbow trout", "Unspecified species")

normalise_species <- function(x) {
  x <- trimws(x); x_lower <- tolower(x)
  dplyr::case_when(
    x_lower == "atlantic salmon" ~ "Atlantic salmon",
    x_lower == "chinook salmon" ~ "Chinook salmon",
    x_lower == "chum salmon" ~ "Chum salmon",
    x_lower == "coho salmon" ~ "Coho salmon",
    x_lower == "masu salmon" ~ "Masu salmon",
    x_lower == "pink salmon" ~ "Pink salmon",
    x_lower == "sockeye salmon" ~ "Sockeye salmon",
    x_lower %in% c("rainbow salmon", "rainbow trout", "steelhead", "steelhead trout") ~ "Rainbow trout",
    x_lower %in% c("unspecified species", "unspecified farmed salmon", "unspecified salmon", "farmed salmon") ~ "Unspecified species",
    TRUE ~ x
  )
}

master <- load_figure_master()
required_master <- c("record_id", "topic_hierarchy_paths", "final_species")
missing_master <- setdiff(required_master, names(master))
if (length(missing_master) > 0) stop("Required columns missing from canonical reporting layer: ", paste(missing_master, collapse = ", "))

raw_paths <- master %>%
  transmute(record_id = as.character(record_id), raw_path = as.character(topic_hierarchy_paths)) %>%
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

# Canonical record-species observations, following the same multi-species
# expansion used in Figures 1 and 2.
record_species <- master %>%
  transmute(record_id = as.character(record_id), species = trimws(as.character(final_species))) %>%
  separate_rows(species, sep = ";") %>%
  mutate(
    species = normalise_species(species),
    species = if_else(is.na(species) | species == "", "Unspecified species", species)
  ) %>%
  distinct(record_id, species)

unexpected_species <- setdiff(unique(record_species$species), canonical_species)
if (length(unexpected_species) > 0L) stop("Unexpected species categories after normalisation: ", paste(sort(unexpected_species), collapse = ", "))

record_species <- record_species %>%
  mutate(species = factor(species, levels = canonical_species))

pacific_values <- grDevices::colorRampPalette(palette[1:3])(7L)
species_fill_values <- c("Atlantic salmon" = "#e55634", setNames(pacific_values, canonical_species[2:8]), "Unspecified species" = "#e2b8a2")

# -------------------------------------------------------------------------
# 1. HIGH-LEVEL OVERVIEW: UNIQUE RECORDS + SPECIES
# -------------------------------------------------------------------------

top_counts <- raw_paths %>%
  distinct(record_id, level1) %>%
  count(level1, name = "unique_records") %>%
  arrange(unique_records)

top_levels <- top_counts %>% pull(level1)

top_species_counts <- raw_paths %>%
  distinct(record_id, level1) %>%
  left_join(record_species, by = "record_id") %>%
  count(level1, species, name = "species_records") %>%
  mutate(
    level1 = factor(level1, levels = top_levels),
    species = factor(species, levels = canonical_species)
  )

top_counts <- top_counts %>%
  mutate(level1 = factor(level1, levels = top_levels))

# Position the unique-record labels just beyond the actual end of each
# stacked bar. This keeps the visual gap constant across bars, while avoiding
# the large variable gap created by anchoring every label to the unique-record
# count itself when species-record observations exceed that count.
bar_end <- top_species_counts %>%
  group_by(level1) %>%
  summarise(bar_end = sum(species_records), .groups = "drop")
label_gap <- max(bar_end$bar_end, na.rm = TRUE) * 0.012
label_data <- top_counts %>%
  left_join(bar_end, by = "level1") %>%
  mutate(label_x = bar_end + label_gap)

overview <- ggplot(top_species_counts, aes(x = species_records, y = level1, fill = species)) +
  geom_col(width = 0.68, colour = "white", linewidth = 0.2) +
  geom_text(
    data = label_data,
    aes(x = label_x, y = level1, label = comma(unique_records)),
    inherit.aes = FALSE,
    hjust = 0,
    size = 3.5,
    colour = palette[1]
  ) +
  scale_fill_manual(values = species_fill_values, breaks = canonical_species, drop = FALSE) +
  scale_x_continuous(labels = comma, limits = c(0, 12000), expand = expansion(mult = c(0, 0))) +
  labs(
    x = NULL,
    y = NULL,
    fill = "Species"
  ) +
  theme_minimal(base_size = 11) +
  theme(
    panel.grid.major.y = element_blank(), panel.grid.minor = element_blank(),
    axis.text.y = element_text(colour = palette[1], face = "bold"),
    axis.text.x = element_text(colour = palette[2]),
    axis.title.x = element_blank(),
    legend.title = element_text(face = "bold", colour = palette[1]),
    legend.text = element_text(colour = palette[1]),
    plot.background = element_rect(fill = "white", colour = NA), panel.background = element_rect(fill = "white", colour = NA),
    plot.margin = margin(4, 30, 4, 12)
  )

ggsave(file.path(out_dir, "figure_04a_top_level_topics.pdf"), overview, width = 190, height = 125, units = "mm")
ggsave(file.path(out_dir, "figure_04a_top_level_topics.png"), overview, width = 190, height = 125, units = "mm", dpi = 600)
write_csv(top_counts %>% mutate(level1 = as.character(level1)), file.path(out_dir, "topic_top_level_unique_record_counts.csv"))
write_csv(top_species_counts %>% mutate(level1 = as.character(level1), species = as.character(species)), file.path(out_dir, "topic_top_level_species_counts.csv"))

# -------------------------------------------------------------------------
# 2. HIERARCHICAL HORIZONTAL BAR PLOTS
# -------------------------------------------------------------------------
#
# Each row is one Level 3 category.
#   - bar length = number of included records assigned to that Level 3 topic
#   - colour = Level 2 parent
#   - label = Level 3 category
#
# Rows are grouped by Level 2 and separated visually. Level 2 parents are
# ordered by total assignments; children are ordered within each group by
# assignment frequency. The approved manuscript design deliberately omits
# vertical grid lines and uses separators only between Level 2 groups.
# APPROVED / LOCKED for Workflow 09 on 2026-09-28.

make_hierarchy <- function(root, dat, file_stub) {
  d <- dat %>%
    filter(level1 == root) %>%
    mutate(
      level2 = if_else(is.na(level2) | level2 == "", level1, level2),
      level3 = if_else(is.na(level3) | level3 == "", level2, level3)
    ) %>%
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
    mutate(
      full_label = if_else(level3 == level2, level2, level3),
      label = factor(full_label, levels = rev(full_label)),
      parent_factor = factor(level2, levels = parent_order$level2)
    )

  n_rows <- nrow(d)
  plot_height <- max(135, 40 + n_rows * 5.2)
  parent_cols <- setNames(rep(palette, length.out = nrow(parent_order)), parent_order$level2)

  p <- ggplot(d, aes(x = assignments, y = label, fill = parent_factor)) +
    geom_col(width = 0.72) +
    geom_text(aes(label = comma(assignments)), hjust = -0.12, size = 2.7, colour = palette[1], show.legend = FALSE) +
    scale_fill_manual(values = parent_cols, drop = FALSE, name = "Level 2") +
    scale_x_continuous(labels = comma, expand = expansion(mult = c(0, 0.10))) +
    labs(
      x = NULL,
      y = NULL
    ) +
    theme_minimal(base_size = 10.5) +
    theme(
      panel.grid = element_blank(),
      axis.text.y = element_text(colour = palette[1], size = 7.2, lineheight = 0.95),
      axis.text.x = element_text(colour = palette[2], size = 8.5),
      axis.title.x = element_blank(),
      legend.position = "right",
      legend.title = element_text(face = "bold", colour = "black"),
      legend.text = element_text(colour = "black"),
      plot.background = element_rect(fill = "white", colour = NA),
      panel.background = element_rect(fill = "white", colour = NA),
      plot.margin = margin(4, 28, 4, 12)
    )

  group_sizes <- d %>% count(parent_index, name = "n") %>% arrange(parent_index)
  boundaries <- n_rows - cumsum(group_sizes$n) + 0.5
  boundaries <- boundaries[-length(boundaries)]
  if (length(boundaries)) {
    p <- p + geom_hline(yintercept = boundaries, colour = "#cfd6d7", linewidth = 1.1, inherit.aes = FALSE)
  }

  write_csv(
    d %>% select(level2, level3, full_label, assignments),
    file.path(out_dir, paste0(file_stub, "_assignments.csv"))
  )

  ggsave(file.path(out_dir, paste0(file_stub, ".pdf")), p, width = 220, height = plot_height, units = "mm", device = cairo_pdf)
  ggsave(file.path(out_dir, paste0(file_stub, ".png")), p, width = 220, height = plot_height, units = "mm", dpi = 600)
  invisible(p)
}

roots <- c(
  "Production",
  "Environment",
  "Methods",
  "Industry and governance",
  "Product",
  "People and society",
  "Inputs and resources"
)
missing_roots <- setdiff(roots, unique(raw_paths$level1))
if (length(missing_roots)) {
  stop("Expected manuscript topic roots missing from canonical data: ", paste(missing_roots, collapse = ", "))
}
for (i in seq_along(roots)) {
  root <- roots[i]
  safe_root <- str_replace_all(str_to_lower(root), "[^a-z0-9]+", "_")
  stub <- paste0("figure_04", letters[i], "_hierarchy_", safe_root)
  make_hierarchy(root, raw_paths, stub)
}

message("Topic visualisations written to: ", out_dir)

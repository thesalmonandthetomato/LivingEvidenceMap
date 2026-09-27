#!/usr/bin/env Rscript

# Figure 4: Topic hierarchy visualisations from the included-only canonical JSONL.
# Creates one high-level topic-by-species figure and one theme-specific
# horizontal hierarchy figure per high-level topic.

required <- c("dplyr", "ggplot2", "readr", "tidyr", "stringr", "scales", "here", "jsonlite")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing) > 0) stop("Install required packages: ", paste(missing, collapse = ", "))

library(dplyr); library(ggplot2); library(readr); library(tidyr); library(stringr); library(scales); library(here)
source(here::here("visualisations", "canonical_figure_data.R"))

out_dir <- here::here("visualisations", "topic_hierarchy")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
palette <- c("#2c454a", "#577c84", "#a8bdbe", "#e2b8a2", "#ff9d78", "#e55634")
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
    x_lower %in% c("unspecified species", "unspecified farmed salmon", "unspecified salmon", "farmed salmon", "") ~ "Unspecified species",
    TRUE ~ x
  )
}
slug <- function(x) gsub("_+", "_", gsub("[^a-z0-9]+", "_", tolower(x)))

master <- load_figure_master()
raw_paths <- master %>%
  transmute(record_id, raw_path = as.character(topic_hierarchy_paths)) %>%
  filter(!is.na(raw_path), str_trim(raw_path) != "") %>%
  mutate(path = str_split(raw_path, "\\s*;\\s*")) %>%
  unnest(path) %>%
  mutate(path = str_squish(path)) %>% filter(path != "") %>% distinct(record_id, path)
if (!nrow(raw_paths)) stop("No topic paths found in canonical JSONL.", call. = FALSE)
parts <- str_split(raw_paths$path, "\\s*>\\s*")
raw_paths$level1 <- vapply(parts, function(x) if (length(x) >= 1) str_squish(x[1]) else NA_character_, character(1))
raw_paths$level2 <- vapply(parts, function(x) if (length(x) >= 2) str_squish(x[2]) else "Other", character(1))
raw_paths$level3 <- vapply(parts, function(x) if (length(x) >= 3) str_squish(x[3]) else str_squish(x[length(x)]), character(1))

record_species <- master %>%
  transmute(record_id, species = final_species) %>%
  separate_rows(species, sep = ";") %>%
  mutate(species = normalise_species(species), species = if_else(is.na(species) | species == "", "Unspecified species", species)) %>%
  distinct(record_id, species) %>% mutate(species = factor(species, levels = canonical_species))
unexpected_species <- setdiff(unique(as.character(record_species$species)), canonical_species)
if (length(unexpected_species) > 0L) stop("Unexpected species categories after normalisation: ", paste(sort(unexpected_species), collapse = ", "))

pacific_values <- grDevices::colorRampPalette(palette[1:3])(7L)
species_fill_values <- c("Atlantic salmon" = "#e55634", setNames(pacific_values, canonical_species[2:8]), "Unspecified species" = "#e2b8a2")

top_counts <- raw_paths %>% distinct(record_id, level1) %>% count(level1, name = "unique_records") %>% arrange(unique_records)
top_levels <- top_counts$level1
top_species_counts <- raw_paths %>% distinct(record_id, level1) %>% left_join(record_species, by = "record_id") %>% count(level1, species, name = "species_records") %>% mutate(level1 = factor(level1, levels = top_levels), species = factor(species, levels = canonical_species))
readr::write_csv(top_species_counts, file.path(out_dir, "topic_top_level_species_counts.csv"))
readr::write_csv(top_counts, file.path(out_dir, "topic_top_level_unique_record_counts.csv"))

p_top <- ggplot(top_species_counts, aes(x = level1, y = species_records, fill = species)) +
  geom_col(width = 0.75, colour = "white", linewidth = 0.15) + coord_flip() +
  scale_fill_manual(values = species_fill_values, drop = FALSE) +
  scale_y_continuous(labels = label_comma(), expand = expansion(mult = c(0, 0.06))) +
  labs(x = NULL, y = "Included record-species observations", fill = "Species") +
  theme_classic(base_size = 11) +
  theme(legend.position = "right", legend.title = element_text(face = "bold"), axis.title = element_text(face = "bold"), axis.text = element_text(colour = "black"), panel.grid = element_blank())
ggsave(file.path(out_dir, "figure_04a_top_level_topics.pdf"), p_top, width = 210, height = 130, units = "mm", device = cairo_pdf)
ggsave(file.path(out_dir, "figure_04a_top_level_topics.png"), p_top, width = 210, height = 130, units = "mm", dpi = 600)

level1_order <- c("Production", "Environment", "Methods", "Industry and governance", "Product", "People and society", "Inputs and resources")
level1_order <- c(intersect(level1_order, unique(raw_paths$level1)), setdiff(unique(raw_paths$level1), level1_order))
letters <- letters[seq_along(level1_order)]
for (i in seq_along(level1_order)) {
  theme_name <- level1_order[[i]]
  dat <- raw_paths %>% filter(level1 == theme_name) %>% distinct(record_id, level2, level3, path) %>% count(level2, level3, name = "records") %>% arrange(records)
  if (!nrow(dat)) next
  dat <- dat %>% mutate(label = stringr::str_wrap(level3, 42), label = factor(label, levels = label), level2 = factor(level2))
  level2_cols <- setNames(grDevices::colorRampPalette(palette)(length(unique(dat$level2))), levels(dat$level2))
  p <- ggplot(dat, aes(x = label, y = records, fill = level2)) +
    geom_col(width = 0.72, colour = "white", linewidth = 0.12) + coord_flip() +
    scale_fill_manual(values = level2_cols, name = "Level 2") +
    scale_y_continuous(labels = label_comma(), expand = expansion(mult = c(0, 0.06))) +
    labs(x = NULL, y = "Included records", title = theme_name) +
    theme_classic(base_size = 10.5) +
    theme(plot.title = element_text(face = "bold", colour = palette[1], size = 15), legend.position = "right", legend.title = element_text(face = "bold"), axis.title = element_text(face = "bold"), axis.text = element_text(colour = "black"), panel.grid = element_blank())
  fname <- sprintf("figure_04%s_hierarchy_%s", letters[[i]], slug(theme_name))
  h <- max(110, min(230, 45 + 4.2 * nrow(dat)))
  ggsave(file.path(out_dir, paste0(fname, ".pdf")), p, width = 225, height = h, units = "mm", device = cairo_pdf)
  ggsave(file.path(out_dir, paste0(fname, ".png")), p, width = 225, height = h, units = "mm", dpi = 600)
  readr::write_csv(dat %>% mutate(label = as.character(label), level2 = as.character(level2)), file.path(out_dir, paste0(fname, "_assignments.csv")))
}
message("Topic hierarchy figures written to: ", out_dir)

#!/usr/bin/env Rscript

# Figure 6: Rapidly emerging topics relative to background evidence-base growth.
# The 12 topic clusters were identified from the corrected master evidence-map
# database as rapidly growing themes. Each panel shows the annual number of
# records for the topic as an index (100 = the mean annual topic count in the
# earliest five-year baseline with >=3 non-zero years). A dashed line shows the
# corresponding background database-growth index, normalised to the same
# baseline period. Values above the background line indicate growth faster than
# the evidence base as a whole.
# Source: corrected master evidence-map database.

required <- c("dplyr", "ggplot2", "readr", "tidyr", "stringr", "scales")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing) > 0) stop("Install required packages: ", paste(missing, collapse = ", "))

library(dplyr)
library(ggplot2)
library(readr)
library(tidyr)
library(stringr)
library(scales)

project_root <- tryCatch(
  here::here(),
  error = function(e) normalizePath(file.path(dirname(sys.frame(1)$ofile %||% ""), ".."), mustWork = FALSE)
)

# Keep the same repository-relative paths used by the other visualisation
# scripts. The script is intended to be run from the repository root.
master_path <- file.path("data", "master", "current", "living_evidence_map_master CORRECTED.csv")
out_dir <- "visualisations"
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

if (!file.exists(master_path)) {
  stop("Master database not found at: ", master_path,
       ". Run this script from the repository root.")
}

# Rapidly emerging topic clusters (n = 12). Welfare assessment and welfare
# risks/consequences are combined because they represent the same emerging
# welfare evidence cluster for this figure.
rapid_topics <- tibble::tribble(
  ~topic, ~leaf_topic,
  "Monitoring and sampling methods", "Monitoring and sampling methods",
  "Automation and precision aquaculture", "Automation and precision aquaculture",
  "Smoltification and smolt quality", "Smoltification and smolt quality",
  "Novel feed resources", "Novel feed resources",
  "Welfare assessment and risks", "Welfare assessment",
  "Welfare assessment and risks", "Welfare risks and consequences",
  "Climate change", "Climate change",
  "Sensors, imaging and measurement", "Sensors, imaging and measurement methods",
  "Statistical and modelling methods", "Statistical and modelling methods",
  "Antimicrobial resistance and One Health", "Antimicrobial resistance and One Health",
  "Energy, greenhouse gases and life-cycle footprint", "Energy, greenhouse gases and life-cycle footprint",
  "By-products and waste as inputs", "By-products and waste as inputs",
  "Plastics and solid waste", "Plastics and solid waste"
) %>%
  distinct()

topic_order <- c(
  "Monitoring and sampling methods",
  "Automation and precision aquaculture",
  "Smoltification and smolt quality",
  "Novel feed resources",
  "Welfare assessment and risks",
  "Climate change",
  "Sensors, imaging and measurement",
  "Statistical and modelling methods",
  "Antimicrobial resistance and One Health",
  "Energy, greenhouse gases and life-cycle footprint",
  "By-products and waste as inputs",
  "Plastics and solid waste"
)

master <- readr::read_csv(master_path, show_col_types = FALSE, progress = FALSE)
required_master <- c("record_id", "year", "topic_hierarchy_paths")
missing_master <- setdiff(required_master, names(master))
if (length(missing_master) > 0) {
  stop("Required columns missing from master: ", paste(missing_master, collapse = ", "))
}

# Expand canonical topic paths to leaf topics, retaining one record-topic
# observation per record. This mirrors the record-level deduplication logic in
# the other topic visualisations.
expanded <- master %>%
  transmute(
    record_id = as.character(record_id),
    publication_year = suppressWarnings(as.integer(year)),
    raw_paths = as.character(topic_hierarchy_paths)
  ) %>%
  filter(!is.na(publication_year), !is.na(raw_paths), str_trim(raw_paths) != "") %>%
  mutate(path = str_split(raw_paths, "\\s*;\\s*")) %>%
  unnest(path) %>%
  mutate(path = str_squish(path)) %>%
  filter(path != "") %>%
  mutate(
    leaf_topic = str_squish(str_split_fixed(path, "\\s*>\\s*", 2)[, 2])
  ) %>%
  filter(leaf_topic != "") %>%
  distinct(record_id, publication_year, leaf_topic)

# Background is the annual number of unique records in the master database.
background <- master %>%
  transmute(
    record_id = as.character(record_id),
    publication_year = suppressWarnings(as.integer(year))
  ) %>%
  filter(!is.na(publication_year)) %>%
  distinct(record_id, publication_year) %>%
  count(publication_year, name = "background_records")

all_years <- seq(
  min(background$publication_year, na.rm = TRUE),
  max(background$publication_year, na.rm = TRUE),
  by = 1
)

background <- tibble(publication_year = all_years) %>%
  left_join(background, by = "publication_year") %>%
  mutate(background_records = replace_na(background_records, 0L))

# Count records in each rapid topic cluster. A record assigned to both welfare
# leaf topics is counted only once in the combined welfare cluster.
topic_records <- expanded %>%
  inner_join(rapid_topics, by = "leaf_topic") %>%
  distinct(record_id, publication_year, topic) %>%
  count(topic, publication_year, name = "topic_records")

plot_data <- tidyr::expand_grid(
  topic = topic_order,
  publication_year = all_years
) %>%
  left_join(topic_records, by = c("topic", "publication_year")) %>%
  mutate(topic_records = replace_na(topic_records, 0L)) %>%
  left_join(background, by = "publication_year")

# Determine a topic-specific baseline: the earliest five-year period from
# 2000 onward containing at least three non-zero topic years. This avoids
# making the index dependent on a single unusually small publication year and
# allows very recent themes (e.g. plastics and solid waste) to be included.
baselines <- plot_data %>%
  group_by(topic) %>%
  group_modify(~ {
    d <- .x %>% filter(publication_year >= 2000)
    candidate_starts <- seq(2000, max(d$publication_year) - 4, by = 1)
    candidates <- lapply(candidate_starts, function(start_year) {
      w <- d %>% filter(publication_year >= start_year,
                        publication_year <= start_year + 4)
      if (sum(w$topic_records > 0) >= 3) {
        tibble(
          baseline_start = start_year,
          baseline_end = start_year + 4,
          topic_baseline = mean(w$topic_records),
          background_baseline = mean(w$background_records)
        )
      } else {
        NULL
      }
    })
    bind_rows(candidates) %>% slice_head(n = 1)
  }) %>%
  ungroup()

if (nrow(baselines) != length(topic_order)) {
  missing_baselines <- setdiff(topic_order, baselines$topic)
  stop("Could not establish a baseline for: ", paste(missing_baselines, collapse = ", "))
}

plot_data <- plot_data %>%
  left_join(baselines, by = "topic") %>%
  mutate(
    topic_index = 100 * topic_records / topic_baseline,
    background_index = 100 * background_records / background_baseline
  )

# Summarise the end-period acceleration relative to background. This is saved
# with the plotting data so the thresholding and interpretation can be audited.
summary_data <- plot_data %>%
  group_by(topic) %>%
  summarise(
    baseline_start = first(baseline_start),
    baseline_end = first(baseline_end),
    baseline_topic_mean = first(topic_baseline),
    baseline_background_mean = first(background_baseline),
    mean_topic_2021_2025 = mean(topic_records[publication_year >= 2021 & publication_year <= 2025]),
    mean_background_2021_2025 = mean(background_records[publication_year >= 2021 & publication_year <= 2025]),
    topic_growth_ratio_2021_2025 = mean_topic_2021_2025 / baseline_topic_mean,
    background_growth_ratio_2021_2025 = mean_background_2021_2025 / baseline_background_mean,
    relative_growth_vs_background = topic_growth_ratio_2021_2025 / background_growth_ratio_2021_2025,
    .groups = "drop"
  ) %>%
  arrange(desc(relative_growth_vs_background))

# Keep all 12 panels readable while using the repository's established visual
# language. The solid line is observed topic output; the dashed line is the
# background evidence-base growth rate, both indexed to 100 at the topic's
# baseline period.
p <- ggplot(plot_data, aes(x = publication_year)) +
  geom_line(
    aes(y = background_index),
    colour = "#B8B8B8",
    linewidth = 0.65,
    linetype = "dashed"
  ) +
  geom_line(
    aes(y = topic_index),
    colour = "#E55634",
    linewidth = 0.85
  ) +
  geom_point(
    aes(y = topic_index),
    colour = "#E55634",
    size = 0.9
  ) +
  facet_wrap(~ factor(topic, levels = topic_order), ncol = 3, scales = "free_y") +
  scale_x_continuous(
    breaks = scales::breaks_pretty(n = 7),
    expand = expansion(mult = c(0.01, 0.02))
  ) +
  scale_y_continuous(
    labels = function(x) paste0(x, "%"),
    expand = expansion(mult = c(0, 0.08))
  ) +
  labs(
    title = "Rapidly emerging topics in the evidence base",
    subtitle = "Observed topic growth relative to background database growth",
    x = "Publication year",
    y = "Growth index",
    caption = "Solid line = topic output; dashed line = background evidence-base growth. Each panel is indexed to the topic's earliest eligible five-year baseline (100)."
  ) +
  theme_classic(base_size = 10.5) +
  theme(
    strip.background = element_rect(fill = "#EEF2F2", colour = NA),
    strip.text = element_text(face = "bold", colour = "#29434A", size = 9.5),
    axis.title = element_text(face = "bold", colour = "#45616A"),
    axis.text = element_text(colour = "#29434A", size = 8.5),
    plot.title = element_text(face = "bold", size = 17, colour = "#29434A"),
    plot.subtitle = element_text(colour = "#45616A", size = 10.5),
    plot.caption = element_text(colour = "#5B6D72", size = 8.5, hjust = 0),
    panel.grid = element_blank(),
    panel.spacing = grid::unit(1.1, "lines"),
    plot.background = element_rect(fill = "white", colour = NA),
    panel.background = element_rect(fill = "white", colour = NA)
  )

ggsave(
  file.path(out_dir, "figure_06_rapidly_emerging_topics.pdf"),
  p,
  width = 190,
  height = 235,
  units = "mm",
  device = cairo_pdf
)

ggsave(
  file.path(out_dir, "figure_06_rapidly_emerging_topics.png"),
  p,
  width = 190,
  height = 235,
  units = "mm",
  dpi = 600
)

write_csv(
  plot_data %>% arrange(topic, publication_year),
  file.path(out_dir, "figure_06_rapidly_emerging_topics_data.csv")
)

write_csv(
  summary_data,
  file.path(out_dir, "figure_06_rapidly_emerging_topics_summary.csv")
)

message("Figure 6 written to: ", out_dir)

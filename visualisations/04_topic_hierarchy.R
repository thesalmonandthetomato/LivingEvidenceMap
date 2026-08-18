#!/usr/bin/env Rscript

# LivingEvidenceMap topic hierarchy visualisations
# Creates one unique-record high-level bar chart and one data-driven radial
# hierarchy plot for each top-level topic.

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

# ---- High-level overview: UNIQUE RECORDS -------------------------------
top_counts <- raw_paths %>%
  distinct(record_id, level1) %>%
  count(level1, name = "unique_records") %>%
  arrange(unique_records)

overview <- ggplot(top_counts, aes(x = unique_records, y = reorder(level1, unique_records))) +
  geom_col(fill = palette[1], width = 0.72) +
  geom_text(aes(label = comma(unique_records)), hjust = -0.12, size = 3.4, colour = palette[1]) +
  scale_x_continuous(labels = comma, expand = expansion(mult = c(0, .10))) +
  labs(title = "LivingEvidenceMap: topic distribution",
       subtitle = "Unique records assigned to each top-level topic", x = "Unique records", y = NULL,
       caption = "Each record is counted once within each top-level topic; records may be assigned to multiple topics.") +
  theme_minimal(base_size = 11) +
  theme(panel.grid.major.y = element_blank(), panel.grid.minor = element_blank(),
        axis.text.y = element_text(colour = palette[1], face = "bold"),
        axis.text.x = element_text(colour = palette[2]), axis.title.x = element_text(colour = palette[2]),
        plot.title = element_text(face = "bold", size = 16, colour = palette[1]),
        plot.subtitle = element_text(colour = palette[2]), plot.caption = element_text(colour = palette[2], hjust = 0),
        plot.margin = margin(12, 30, 12, 12))

ggsave(file.path(out_dir, "figure_04a_top_level_topics.pdf"), overview, width = 190, height = 125, units = "mm")
ggsave(file.path(out_dir, "figure_04a_top_level_topics.png"), overview, width = 190, height = 125, units = "mm", dpi = 600)
write_csv(top_counts, file.path(out_dir, "topic_top_level_unique_record_counts.csv"))

# ---- Radial hierarchy: topic-assignment frequency ------------------------
# Every spoke is a terminal Level-2 > Level-3 category. Its radial length is
# proportional to the number of record-topic assignments to that category.
# Labels contain the taxonomy only (no counts).
make_radial <- function(root, dat, file_stub) {
  d <- dat %>%
    filter(level1 == root) %>%
    mutate(terminal = case_when(
      !is.na(level3) & level3 != "" ~ paste(level2, level3, sep = " > "),
      !is.na(level2) & level2 != "" ~ level2,
      TRUE ~ level1
    )) %>%
    count(level2, level3, terminal, name = "assignments") %>%
    arrange(level2, desc(assignments), terminal)

  if (nrow(d) == 0) return(invisible(NULL))

  parents <- d %>%
    distinct(level2) %>%
    arrange(level2) %>%
    mutate(parent_index = row_number())
  d <- d %>% left_join(parents, by = "level2") %>% arrange(parent_index, desc(assignments), terminal)

  # Equal angular slots keep every taxonomy label readable. Radial length is
  # the quantitative encoding. Square-root scaling is used to preserve small
  # categories without allowing the largest category to dominate the figure.
  d <- d %>% mutate(value = sqrt(assignments), index = row_number(), n = n())
  d$angle <- 2 * pi * (d$index - 0.5) / d$n
  max_value <- max(d$value)

  label_df <- d %>%
    mutate(
      label = terminal,
      label_radius = max_value * 1.18,
      angle_deg = (90 - angle * 180 / pi) %% 360,
      hjust = if_else(angle_deg > 90 & angle_deg < 270, 1, 0),
      rotation = if_else(hjust == 1, angle_deg + 180, angle_deg)
    )

  p <- ggplot(d, aes(x = angle, y = value)) +
    geom_col(aes(fill = factor(parent_index)),
             width = 2 * pi / d$n * 0.84,
             colour = "white", linewidth = 0.35) +
    scale_fill_manual(values = setNames(rep(palette, length.out = nrow(parents)), seq_len(nrow(parents))), guide = "none") +
    coord_polar(theta = "x", start = pi / 2, direction = -1, clip = "off") +
    scale_y_continuous(
      limits = c(0, max_value * 1.34), expand = c(0, 0),
      breaks = pretty(c(0, max_value), n = 4),
      labels = function(x) comma(round(x^2))
    ) +
    labs(title = root,
         subtitle = "Radial length represents topic-assignment frequency; labels show the taxonomy.") +
    theme_minimal(base_size = 10) +
    theme(
      axis.title = element_blank(), axis.text.x = element_blank(), axis.ticks = element_blank(),
      panel.grid.major.x = element_blank(), panel.grid.minor = element_blank(),
      panel.grid.major.y = element_line(colour = "grey85", linewidth = 0.3),
      plot.title = element_text(face = "bold", size = 16, colour = palette[1]),
      plot.subtitle = element_text(size = 9.5, colour = palette[2]),
      plot.margin = margin(30, 125, 30, 125)
    ) +
    geom_text(data = label_df,
              aes(x = angle, y = label_radius, label = label, angle = rotation, hjust = hjust),
              inherit.aes = FALSE, size = 2.55, colour = palette[1])

  ggsave(file.path(out_dir, paste0(file_stub, ".pdf")), p,
         width = 250, height = 250, units = "mm", device = cairo_pdf)
  ggsave(file.path(out_dir, paste0(file_stub, ".png")), p,
         width = 250, height = 250, units = "mm", dpi = 600)
  write_csv(d %>% select(level2, level3, terminal, assignments),
            file.path(out_dir, paste0(file_stub, "_assignments.csv")))
  invisible(p)
}

roots <- top_counts %>% arrange(desc(unique_records)) %>% pull(level1)
for (i in seq_along(roots)) {
  root <- roots[i]
  safe_root <- str_replace_all(str_to_lower(root), "[^a-z0-9]+", "_")
  stub <- paste0("figure_04", letters[i], "_radial_", safe_root)
  make_radial(root, raw_paths, stub)
}

message("Topic visualisations written to: ", out_dir)

#!/usr/bin/env Rscript

# LivingEvidenceMap topic hierarchy visualisations
# Creates one unique-record high-level bar chart and one readable, data-driven
# radial hierarchy plot for each top-level topic.

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

# ---- Radial hierarchy: assignment frequency + fully external labels ------
# Every terminal Level-2 > Level-3 category is a spoke. Angular position is
# categorical; radial length encodes assignment frequency. A square-root
# transform prevents the largest categories from overwhelming small ones.
# Labels are deliberately placed in two external columns with leader lines:
# this avoids the severe collision produced by placing long taxonomy strings
# around the circumference.
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

  parents <- d %>% distinct(level2) %>% arrange(level2) %>% mutate(parent_index = row_number())
  d <- d %>% left_join(parents, by = "level2") %>% arrange(parent_index, desc(assignments), terminal)

  # Equal angular positions make the taxonomy legible; length is the data.
  d <- d %>% mutate(value = sqrt(assignments), index = row_number(), n = n())
  d$angle <- 2 * pi * (d$index - 0.5) / d$n
  max_value <- max(d$value)
  d$x_end <- d$value * sin(d$angle)
  d$y_end <- d$value * cos(d$angle)

  # Put labels in two vertical columns. Within each side, preserve the angular
  # ordering so the leader lines remain easy to follow.
  left <- d %>% filter(x_end < 0) %>% arrange(desc(y_end))
  right <- d %>% filter(x_end >= 0) %>% arrange(desc(y_end))

  assign_label_y <- function(x, min_gap) {
    if (!length(x)) return(numeric())
    y <- x
    if (length(y) > 1) {
      for (i in 2:length(y)) y[i] <- min(y[i], y[i - 1] - min_gap)
      if (min(y) < -max_value) y <- y + (-max_value - min(y))
      if (max(y) > max_value) y <- y - (max(y) - max_value)
    }
    y
  }

  min_gap <- max(max_value * 0.085, 0.55)
  left$label_y <- assign_label_y(left$y_end, min_gap)
  right$label_y <- assign_label_y(right$y_end, min_gap)
  left$label_x <- -max_value * 1.20
  right$label_x <- max_value * 1.20
  left$hjust <- 1
  right$hjust <- 0
  labels <- bind_rows(left, right) %>% mutate(label = terminal)

  # Leader lines terminate at the appropriate label column.
  leaders <- labels %>%
    mutate(x_knee = if_else(x_end < 0, -max_value * 0.98, max_value * 0.98))

  # Radial grid rings labelled in the original count scale.
  grid_values <- pretty(c(0, max_value), n = 5)
  grid_values <- grid_values[grid_values >= 0 & grid_values <= max_value]
  if (length(grid_values) < 2) grid_values <- c(0, max_value)

  p <- ggplot() +
    # concentric reference circles
    geom_hline(yintercept = 0, colour = "transparent") +
    geom_path(data = tidyr::expand_grid(r = grid_values, theta = seq(0, 2*pi, length.out = 361)) %>%
                mutate(x = r * sin(theta), y = r * cos(theta), r = factor(r)),
              aes(x = x, y = y, group = r), colour = "grey85", linewidth = 0.35) +
    # data spokes
    geom_segment(data = d,
                 aes(x = 0, y = 0, xend = x_end, yend = y_end, colour = factor(parent_index)),
                 linewidth = 2.2, lineend = "round") +
    geom_point(data = d,
               aes(x = x_end, y = y_end, fill = factor(parent_index)),
               shape = 21, size = 2.7, stroke = 0.45, colour = "white") +
    # leader lines and labels
    geom_segment(data = leaders,
                 aes(x = x_end, y = y_end, xend = x_knee, yend = label_y),
                 colour = "grey65", linewidth = 0.35) +
    geom_segment(data = leaders,
                 aes(x = x_knee, y = label_y, xend = label_x, yend = label_y),
                 colour = "grey65", linewidth = 0.35) +
    geom_text(data = labels,
              aes(x = label_x, y = label_y, label = label, hjust = hjust),
              colour = palette[1], size = 2.55, lineheight = 0.95) +
    scale_colour_manual(values = setNames(rep(palette, length.out = nrow(parents)), seq_len(nrow(parents))), guide = "none") +
    scale_fill_manual(values = setNames(rep(palette, length.out = nrow(parents)), seq_len(nrow(parents))), guide = "none") +
    coord_equal(xlim = c(-max_value * 1.55, max_value * 1.55),
                ylim = c(-max_value * 1.22, max_value * 1.22), clip = "off") +
    labs(title = root,
         subtitle = "Each spoke is a Level 2 > Level 3 topic; radial length represents assignment frequency.") +
    theme_void(base_size = 10) +
    theme(plot.title = element_text(face = "bold", size = 17, colour = palette[1], hjust = 0.5),
          plot.subtitle = element_text(size = 9.5, colour = palette[2], hjust = 0.5),
          plot.margin = margin(20, 25, 20, 25))

  # Add count labels to the radial grid without cluttering the spokes.
  p <- p + annotate("text", x = 0, y = grid_values, label = comma(round(grid_values^2)),
                    colour = "grey55", size = 2.4, vjust = -0.45)

  ggsave(file.path(out_dir, paste0(file_stub, ".pdf")), p,
         width = 320, height = 250, units = "mm", device = cairo_pdf)
  ggsave(file.path(out_dir, paste0(file_stub, ".png")), p,
         width = 320, height = 250, units = "mm", dpi = 600)
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

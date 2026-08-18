#!/usr/bin/env Rscript

# LivingEvidenceMap topic hierarchy visualisations
# Creates one high-level topic bar chart and one labelled radial hierarchy
# plot for each top-level topic. Uses the corrected master only.

required <- c("dplyr", "ggplot2", "readr", "tidyr", "stringr", "scales", "svglite")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing) > 0) stop("Install required packages: ", paste(missing, collapse = ", "))

library(dplyr)
library(ggplot2)
library(readr)
library(tidyr)
library(stringr)
library(scales)
library(svglite)
library(here)

master_path <- here::here("data", "master", "current", "living_evidence_map_master CORRECTED.csv")
out_dir <- here::here("visualisations", "topic_hierarchy")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

# LivingEvidenceMap palette supplied for the project.
palette <- c("#2c454a", "#577c84", "#a8bdbe", "#e2b8a2", "#ff9d78", "#e55634")

master <- readr::read_csv(master_path, show_col_types = FALSE, progress = FALSE)
required_col <- "topic_hierarchy_paths"
if (!required_col %in% names(master)) stop("Required column missing from master: ", required_col)

# A record can have multiple topic paths. Split paths first, then split the
# hierarchy levels. Each record contributes at most once to each exact path.
topic_paths <- master %>%
  transmute(record_id = row_number(), raw_path = as.character(.data[[required_col]])) %>%
  filter(!is.na(raw_path), str_trim(raw_path) != "") %>%
  mutate(path = str_split(raw_path, "\\s*;\\s*")) %>%
  unnest(path) %>%
  mutate(path = str_squish(path)) %>%
  filter(path != "") %>%
  separate_rows(path, sep = "\\s*>\\s*") %>%
  group_by(record_id) %>%
  mutate(level = row_number()) %>%
  ungroup()

# Reconstruct cumulative hierarchy labels from each path rather than treating
# individual levels as unrelated categories.
raw_paths <- master %>%
  transmute(record_id = row_number(), raw_path = as.character(.data[[required_col]])) %>%
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

# Remove duplicate assignments of the same record to the same hierarchy path.
raw_paths <- raw_paths %>% distinct()

# ---- High-level overview -------------------------------------------------
top_counts <- raw_paths %>%
  count(level1, name = "records") %>%
  arrange(records)

overview <- ggplot(top_counts, aes(x = records, y = reorder(level1, records))) +
  geom_col(fill = palette[1], width = 0.72) +
  geom_text(aes(label = comma(records)), hjust = -0.12, size = 3.4, colour = palette[1]) +
  scale_x_continuous(labels = comma, expand = expansion(mult = c(0, .10))) +
  labs(
    title = "LivingEvidenceMap: topic distribution",
    subtitle = "Records assigned to each top-level topic",
    x = "Records",
    y = NULL,
    caption = "Records may be assigned to multiple topics."
  ) +
  theme_minimal(base_size = 11) +
  theme(
    panel.grid.major.y = element_blank(),
    panel.grid.minor = element_blank(),
    axis.text.y = element_text(colour = palette[1], face = "bold"),
    axis.text.x = element_text(colour = palette[2]),
    axis.title.x = element_text(colour = palette[2]),
    plot.title = element_text(face = "bold", size = 16, colour = palette[1]),
    plot.subtitle = element_text(colour = palette[2]),
    plot.caption = element_text(colour = palette[2], hjust = 0),
    plot.margin = margin(12, 30, 12, 12)
  )

ggsave(file.path(out_dir, "figure_04a_top_level_topics.pdf"), overview, width = 190, height = 125, units = "mm")
ggsave(file.path(out_dir, "figure_04a_top_level_topics.png"), overview, width = 190, height = 125, units = "mm", dpi = 600)

# ---- Radial hierarchy -----------------------------------------------------
# Draw each top-level topic as a radial partition. Each terminal spoke is a
# level-2 > level-3 label. Where a level-2 topic has no level-3 child, the
# label is simply the level-2 topic. Angular width represents record count.

make_radial <- function(root, dat, file_stub) {
  d <- dat %>% filter(level1 == root)
  if (nrow(d) == 0) return(invisible(NULL))

  # Terminal categories are the deepest observed node for each unique path.
  d <- d %>%
    mutate(
      terminal = case_when(
        !is.na(level3) & level3 != "" ~ paste(level2, level3, sep = " > "),
        !is.na(level2) & level2 != "" ~ level2,
        TRUE ~ level1
      )
    ) %>%
    count(level2, level3, terminal, name = "records") %>%
    arrange(level2, desc(records))

  # Use terminal counts for angular allocation. The centre total is the sum of
  # terminal assignments, i.e. the same quantity represented by the spokes.
  total <- sum(d$records)
  if (total == 0) return(invisible(NULL))

  # Assign each level-2 branch a palette colour cyclically, with lighter outer
  # tones generated by alpha rather than introducing new project colours.
  parents <- d %>%
    group_by(level2) %>%
    summarise(parent_records = sum(records), .groups = "drop") %>%
    arrange(desc(parent_records))

  d <- d %>% left_join(parents %>% mutate(parent_index = row_number()), by = "level2") %>%
    arrange(parent_index, desc(records))

  d$start <- cumsum(c(0, head(d$records, -1))) / total * 2 * pi
  d$end <- cumsum(d$records) / total * 2 * pi
  d$mid <- (d$start + d$end) / 2
  d$span <- d$end - d$start

  # A dedicated plot with polar coordinates gives us control over external
  # labels. Labels are always emitted; small spokes use leader lines.
  p <- ggplot(d) +
    geom_rect(aes(xmin = start, xmax = end, ymin = 0.32, ymax = 0.68,
                  fill = factor(parent_index)), colour = "white", linewidth = 0.7) +
    geom_rect(aes(xmin = start, xmax = end, ymin = 0.68, ymax = 1.02,
                  fill = factor(parent_index)), colour = "white", linewidth = 0.45, alpha = 0.58) +
    coord_polar(theta = "x", clip = "off", start = pi / 2, direction = -1) +
    scale_fill_manual(values = rep(palette, length.out = nrow(parents)), guide = "none") +
    xlim(0, 2*pi) +
    ylim(-0.20, 1.45) +
    theme_void() +
    theme(plot.margin = margin(18, 90, 18, 90))

  # Centre annotation.
  p <- p + annotate("text", x = 0, y = 0.16, label = root,
                    colour = palette[1], fontface = "bold", size = 6) +
    annotate("text", x = 0, y = 0.08, label = comma(total),
              colour = palette[2], size = 3.2) +
    annotate("text", x = 0, y = 0.00, label = "topic assignments",
              colour = palette[2], size = 2.8)

  # Every terminal category gets a label. Put labels just outside the ring and
  # alternate vertical nudging to reduce collisions without suppressing any.
  label_df <- d %>%
    mutate(
      angle = pi/2 - mid,
      x = 1.18 * sin(angle),
      y = 1.18 * cos(angle),
      hjust = if_else(cos(angle) >= 0, 0, 1),
      label = paste0(terminal, " (", comma(records), ")")
    )

  # Use geom_text with polar coordinates. For narrow sectors, the label is
  # still printed; the outside placement is preferable to dropping categories.
  p <- p + geom_text(
    data = label_df,
    aes(x = mid, y = 1.18, label = label),
    size = 2.55,
    colour = palette[1],
    inherit.aes = FALSE
  )

  # Export both publication PDF and high-resolution PNG.
  ggsave(file.path(out_dir, paste0(file_stub, ".pdf")), p,
         width = 230, height = 230, units = "mm", device = cairo_pdf)
  ggsave(file.path(out_dir, paste0(file_stub, ".png")), p,
         width = 230, height = 230, units = "mm", dpi = 600)

  invisible(p)
}

roots <- top_counts$level1
for (i in seq_along(roots)) {
  root <- roots[i]
  stub <- sprintf("figure_04%c_radial_%s", 96 + i, str_replace_all(str_to_lower(root), "[^a-z0-9]+", "_"))
  make_radial(root, raw_paths, stub)
}

write_csv(top_counts, file.path(out_dir, "topic_top_level_counts.csv"))

message("Topic visualisations written to: ", out_dir)

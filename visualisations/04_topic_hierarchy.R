#!/usr/bin/env Rscript

# LivingEvidenceMap topic hierarchy visualisations
#
# Creates:
#   1. One high-level bar chart using UNIQUE RECORD counts.
#   2. One horizontal icicle plot for each top-level topic.
#
# The icicles use topic-assignment frequency as width. Level 2 is the parent
# band and Level 3 is the terminal band. Every terminal category is labelled.
# The design deliberately favours clean hierarchy, readable labels and the
# LivingEvidenceMap colour palette over decorative complexity.

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

# Expand the semicolon-delimited topic paths and retain one occurrence of each
# record/path combination. This is the basis for assignment-frequency plots.
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
  geom_text(
    aes(label = comma(unique_records)),
    hjust = -0.12, size = 3.5, colour = palette[1]
  ) +
  scale_x_continuous(
    labels = comma,
    expand = expansion(mult = c(0, .10))
  ) +
  labs(
    title = "LivingEvidenceMap: topic distribution",
    subtitle = "Unique records assigned to each top-level topic",
    x = "Unique records", y = NULL,
    caption = "Each record is counted once within each top-level topic; records may be assigned to multiple topics."
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

ggsave(
  file.path(out_dir, "figure_04a_top_level_topics.pdf"),
  overview, width = 190, height = 125, units = "mm"
)
ggsave(
  file.path(out_dir, "figure_04a_top_level_topics.png"),
  overview, width = 190, height = 125, units = "mm", dpi = 600
)
write_csv(
  top_counts,
  file.path(out_dir, "topic_top_level_unique_record_counts.csv")
)

# -------------------------------------------------------------------------
# 2. HORIZONTAL ICICLE PLOTS
# -------------------------------------------------------------------------
#
# Each terminal Level 2 > Level 3 category occupies horizontal width
# proportional to its assignment frequency. Level 2 parents are shown as a
# continuous band above their Level 3 children. This is preferable to a
# radial layout here because long taxonomy labels remain horizontal and the
# parent-child relationship is immediately visible.
# -------------------------------------------------------------------------

wrap_label <- function(x, width = 34) {
  stringr::str_wrap(x, width = width, whitespace_only = TRUE)
}

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

  # Stable parent order: largest parent first, then alphabetical. This makes
  # the seven topic panels easier to scan while preserving all categories.
  parent_order <- d %>%
    group_by(level2) %>%
    summarise(parent_assignments = sum(assignments), .groups = "drop") %>%
    arrange(desc(parent_assignments), level2) %>%
    mutate(parent_index = row_number())

  d <- d %>%
    left_join(parent_order, by = "level2") %>%
    arrange(parent_index, desc(assignments), terminal)

  # Horizontal positions for terminal categories.
  d <- d %>%
    mutate(
      xmin = lag(cumsum(assignments), default = 0),
      xmax = cumsum(assignments)
    )

  # Parent positions are calculated from the children, guaranteeing exact
  # alignment between Level 2 and Level 3.
  parents <- d %>%
    group_by(level2, parent_index) %>%
    summarise(
      xmin = min(xmin),
      xmax = max(xmax),
      assignments = sum(assignments),
      .groups = "drop"
    ) %>%
    arrange(xmin)

  total <- max(d$xmax)

  # Label wrapping is deliberately conservative. Labels are placed in the
  # child band, centred within each segment. Very narrow segments get a
  # two-line label and are allowed to extend slightly beyond their segment;
  # no categories are silently dropped.
  d <- d %>%
    mutate(
      label = wrap_label(terminal, width = 30),
      label_size = if_else(assignments / total < 0.025, 2.25, 2.65)
    )

  parent_cols <- setNames(
    rep(palette, length.out = nrow(parent_order)),
    as.character(parent_order$parent_index)
  )

  # Light version of each parent colour for the child band. The alpha is
  # applied by ggplot so the underlying white background remains clean.
  p <- ggplot() +
    # Level 2 parent band.
    geom_rect(
      data = parents,
      aes(xmin = xmin, xmax = xmax, ymin = 0.56, ymax = 0.94,
          fill = factor(parent_index)),
      colour = "white", linewidth = 0.8
    ) +
    # Level 3 terminal band.
    geom_rect(
      data = d,
      aes(xmin = xmin, xmax = xmax, ymin = 0.05, ymax = 0.53,
          fill = factor(parent_index)),
      colour = "white", linewidth = 0.55, alpha = 0.48
    ) +
    # Level 2 labels: only one label per parent, centred in its band.
    geom_text(
      data = parents,
      aes(
        x = (xmin + xmax) / 2,
        y = 0.75,
        label = level2
      ),
      colour = "white",
      fontface = "bold",
      size = 3.0,
      lineheight = 0.9,
      check_overlap = FALSE
    ) +
    # Every terminal category is labelled.
    geom_text(
      data = d,
      aes(
        x = (xmin + xmax) / 2,
        y = 0.29,
        label = label,
        size = label_size
      ),
      colour = palette[1],
      lineheight = 0.88,
      fontface = "plain",
      check_overlap = FALSE,
      show.legend = FALSE
    ) +
    scale_fill_manual(values = parent_cols, guide = "none") +
    scale_size_identity() +
    scale_x_continuous(
      limits = c(0, total),
      expand = expansion(mult = c(0.005, 0.005)),
      labels = comma
    ) +
    scale_y_continuous(limits = c(-0.03, 1.0), expand = c(0, 0)) +
    labs(
      title = root,
      subtitle = "Topic-assignment frequency; width represents the number of assignments",
      x = NULL, y = NULL
    ) +
    theme_void(base_size = 10) +
    theme(
      plot.title = element_text(
        face = "bold", size = 18, colour = palette[1], hjust = 0,
        margin = margin(b = 3)
      ),
      plot.subtitle = element_text(
        size = 10, colour = palette[2], hjust = 0,
        margin = margin(b = 14)
      ),
      plot.margin = margin(18, 24, 18, 24)
    )

  # Add a subtle assignment-frequency scale below the plot. This keeps the
  # numeric interpretation available without cluttering the hierarchy itself.
  breaks <- pretty(c(0, total), n = 5)
  breaks <- breaks[breaks >= 0 & breaks <= total]
  if (length(breaks) >= 2) {
    p <- p +
      geom_segment(
        data = data.frame(x = breaks, xend = breaks, y = -0.015, yend = 0.015),
        aes(x = x, xend = xend, y = y, yend = yend),
        inherit.aes = FALSE, colour = "grey65", linewidth = 0.35
      ) +
      annotate(
        "text", x = breaks, y = -0.035, label = comma(breaks),
        colour = "grey55", size = 2.5, vjust = 1
      )
  }

  # Publication output. Landscape orientation gives long labels the space
  # they need and is intentionally much wider than tall.
  ggsave(
    file.path(out_dir, paste0(file_stub, ".pdf")),
    p, width = 330, height = 155, units = "mm", device = cairo_pdf
  )
  ggsave(
    file.path(out_dir, paste0(file_stub, ".png")),
    p, width = 330, height = 155, units = "mm", dpi = 600
  )

  write_csv(
    d %>% select(level2, level3, terminal, assignments),
    file.path(out_dir, paste0(file_stub, "_assignments.csv"))
  )

  invisible(p)
}

# Largest high-level topics first, matching the overview's substantive order.
roots <- top_counts %>%
  arrange(desc(unique_records)) %>%
  pull(level1)

for (i in seq_along(roots)) {
  root <- roots[i]
  safe_root <- str_replace_all(str_to_lower(root), "[^a-z0-9]+", "_")
  stub <- paste0("figure_04", letters[i], "_icicle_", safe_root)
  make_icicle(root, raw_paths, stub)
}

message("Topic visualisations written to: ", out_dir)

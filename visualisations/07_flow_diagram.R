#!/usr/bin/env Rscript

# Workflow 09 manuscript flow diagram.
#
# Design source:
#   - recently approved PowerPoint flow template (five source databases across
#     the top; central vertical pathway; exclusion/status boxes at right)
#   - project palette and vertical phase-label treatment used in the Living
#     Evidence Map visualisations.
#
# Data source:
#   - Workflow 08 included-only canonical JSONL
#   - Workflow 08 exclusions CSV
#
# IMPORTANT:
#   Source-database retrieval totals and the pre-deduplication duplicate count
#   remain TBC until authoritative Workflow 00 source totals are restored.
#   All downstream counts are derived and validated here rather than typed into
#   the plot labels independently.

required <- c("dplyr", "ggplot2", "readr", "stringr", "here", "jsonlite")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing) > 0) stop("Install required packages: ", paste(missing, collapse = ", "))

library(dplyr)
library(ggplot2)
library(readr)
library(stringr)
library(here)

source(here::here("visualisations", "canonical_figure_data.R"))

out_dir <- here::here("visualisations")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

# -------------------------------------------------------------------------
# 1. AUTHORITATIVE COUNTS
# -------------------------------------------------------------------------

canonical <- load_figure_master()
n_final_included <- nrow(canonical)

exclusions_path <- canonical_arg("--exclusions-csv") %||%
  Sys.getenv("EXCLUSIONS_CSV", unset = "")

if (!nzchar(exclusions_path)) {
  candidates <- c(
    file.path("data", "master", "current", "workflow08_excluded_records.csv"),
    file.path("outputs", "workflow08_corrected", "workflow08_excluded_records.csv"),
    file.path("outputs", "workflow08", "workflow08_excluded_records.csv")
  )
  hit <- candidates[file.exists(candidates)]
  exclusions_path <- if (length(hit)) hit[[1L]] else ""
}

if (!nzchar(exclusions_path) || !file.exists(exclusions_path)) {
  stop(
    "Workflow 08 exclusions CSV is required for the manuscript flow diagram. ",
    "Provide --exclusions-csv or set EXCLUSIONS_CSV.",
    call. = FALSE
  )
}

exclusions <- readr::read_csv(exclusions_path, show_col_types = FALSE, progress = FALSE)
required_exclusion_cols <- c("record_id", "exclusion_stage")
missing_exclusion_cols <- setdiff(required_exclusion_cols, names(exclusions))
if (length(missing_exclusion_cols)) {
  stop("Exclusions CSV missing columns: ", paste(missing_exclusion_cols, collapse = ", "), call. = FALSE)
}

stage_counts <- exclusions %>%
  count(exclusion_stage, name = "n")

stage_n <- function(stage) {
  x <- stage_counts$n[match(stage, stage_counts$exclusion_stage)]
  if (!length(x) || is.na(x)) 0L else as.integer(x)
}

n_w03 <- stage_n("workflow03")
n_w04 <- stage_n("workflow04")
n_w07 <- stage_n("workflow07_late")
n_w08 <- stage_n("workflow08")
n_excluded <- nrow(exclusions)

n_deduplicated <- n_final_included + n_excluded
n_entered_w04 <- n_deduplicated - n_w03
n_w04_retained <- n_entered_w04 - n_w04
n_after_w07 <- n_w04_retained - n_w07
n_after_w08 <- n_after_w07 - n_w08

n_topic_uncoded <- sum(
  is.na(canonical$topic_hierarchy_paths) |
    stringr::str_trim(canonical$topic_hierarchy_paths) == ""
)
n_topic_coded <- n_final_included - n_topic_uncoded

# Assertions make the published flow reproducible and prevent accidental drift.
stopifnot(
  n_deduplicated == 32292L,
  n_w03 == 9L,
  n_entered_w04 == 32283L,
  n_w04 == 12876L,
  n_w04_retained == 19407L,
  n_w07 == 122L,
  n_w08 == 168L,
  n_after_w08 == 19117L,
  n_final_included == 19117L,
  n_topic_uncoded == 231L,
  n_topic_coded == 18886L
)

fmt <- function(x) format(as.integer(x), big.mark = ",", scientific = FALSE, trim = TRUE)

# -------------------------------------------------------------------------
# 2. OPTIONAL SOURCE COUNTS
# -------------------------------------------------------------------------
#
# Source counts must represent records retrieved from each database BEFORE
# deduplication. They are deliberately not substituted with canonical-source
# contribution counts. Until those authoritative Workflow 00 totals are
# restored, the source boxes and duplicate count remain TBC.

source_counts_path <- canonical_arg("--source-counts-csv") %||%
  Sys.getenv("SOURCE_COUNTS_CSV", unset = "")

source_order <- c("AGRICOLA", "The Lens", "OpenAlex", "Scopus", "WoSCC")
source_counts <- setNames(rep(NA_integer_, length(source_order)), source_order)
duplicates_removed <- NA_integer_

if (nzchar(source_counts_path)) {
  if (!file.exists(source_counts_path)) stop("Source-count CSV not found: ", source_counts_path, call. = FALSE)
  src <- readr::read_csv(source_counts_path, show_col_types = FALSE, progress = FALSE)
  if (!all(c("database", "records") %in% names(src))) {
    stop("Source-count CSV must contain database and records columns.", call. = FALSE)
  }
  src <- src %>%
    mutate(database = as.character(database), records = as.integer(records))

  missing_sources <- setdiff(source_order, src$database)
  if (length(missing_sources)) {
    stop("Source-count CSV missing databases: ", paste(missing_sources, collapse = ", "), call. = FALSE)
  }
  source_counts <- setNames(src$records[match(source_order, src$database)], source_order)

  if (any(is.na(source_counts)) || any(source_counts < 0)) {
    stop("Source-count CSV contains missing/invalid counts.", call. = FALSE)
  }
  duplicates_removed <- sum(source_counts) - n_deduplicated
  if (duplicates_removed < 0) {
    stop("Source counts sum to fewer records than the deduplicated canonical.", call. = FALSE)
  }
}

fmt_tbc <- function(x) ifelse(is.na(x), "TBC", fmt(x))

# -------------------------------------------------------------------------
# 3. DIAGRAM GEOMETRY
# -------------------------------------------------------------------------

box <- function(id, x, y, w, h, label, stage) {
  data.frame(id, x, y, w, h, label, stage, stringsAsFactors = FALSE)
}

# PowerPoint-template geometry: five source boxes, central pathway, right-hand
# exclusions/statuses, and four vertical phase labels.
boxes <- bind_rows(
  box("agricola", 2.65, 10.30, 1.50, 0.78, paste0("AGRICOLA\nn = ", fmt_tbc(source_counts[["AGRICOLA"]])), "source"),
  box("lens",     4.20, 10.30, 1.50, 0.78, paste0("The Lens\nn = ", fmt_tbc(source_counts[["The Lens"]])), "source"),
  box("openalex", 5.75, 10.30, 1.50, 0.78, paste0("OpenAlex\nn = ", fmt_tbc(source_counts[["OpenAlex"]])), "source"),
  box("scopus",   7.30, 10.30, 1.50, 0.78, paste0("Scopus\nn = ", fmt_tbc(source_counts[["Scopus"]])), "source"),
  box("wos",      8.85, 10.30, 1.50, 0.78, paste0("WoSCC\nn = ", fmt_tbc(source_counts[["WoSCC"]])), "source"),

  box("dedup", 5.75, 9.10, 2.40, 0.78, paste0("Deduplicated records\nn = ", fmt(n_deduplicated)), "screen"),
  box("dupes", 9.10, 9.10, 2.25, 0.78, paste0("Duplicates removed\nn = ", fmt_tbc(duplicates_removed)), "exclude"),

  box("w04in", 5.75, 7.95, 2.65, 0.78, paste0("Records entering title & abstract screening\nn = ", fmt(n_entered_w04)), "screen"),
  box("pubstatus", 9.10, 7.95, 2.25, 0.78, paste0("Publication-status exclusions\nn = ", fmt(n_w03)), "exclude"),

  box("w04retained", 5.75, 6.80, 2.65, 0.78, paste0("Records retained after title & abstract screening\nn = ", fmt(n_w04_retained)), "retain"),
  box("w04excluded", 9.10, 6.80, 2.55, 0.78, paste0("Records excluded at title & abstract\nn = ", fmt(n_w04)), "exclude"),

  box("species", 5.75, 5.55, 2.45, 0.78, paste0("Species annotation\nn = ", fmt(n_w04_retained)), "annotate"),
  box("geography", 5.75, 4.40, 2.45, 0.78, paste0("Geography annotation\nn = ", fmt(n_w04_retained)), "annotate"),
  box("topic", 5.75, 3.25, 2.45, 0.78, paste0("Topic classification\nn = ", fmt(n_w04_retained)), "annotate"),

  box("w07exclude", 9.10, 3.65, 2.25, 0.72, paste0("Workflow 07 late exclusions\nn = ", fmt(n_w07)), "exclude"),
  box("w08exclude", 9.10, 2.80, 2.25, 0.72, paste0("Workflow 08 exclusions\nn = ", fmt(n_w08)), "exclude"),

  box("topiccoded", 4.95, 2.05, 2.10, 0.78, paste0("Topic coded\nn = ", fmt(n_topic_coded)), "result"),
  box("topicuncoded", 7.20, 2.05, 2.10, 0.78, paste0("Included but uncoded\nn = ", fmt(n_topic_uncoded)), "result"),

  box("map", 5.75, 0.85, 2.65, 0.86, paste0("Living Evidence Map\nn = ", fmt(n_final_included)), "map")
)

# Connections. Horizontal source connectors meet a common trunk before dedup.
segments <- bind_rows(
  # source vertical drops
  data.frame(x=c(2.65,4.20,5.75,7.30,8.85), y=rep(9.91,5),
             xend=c(2.65,4.20,5.75,7.30,8.85), yend=rep(9.68,5), arrow=FALSE),
  # source horizontal collector
  data.frame(x=2.65, y=9.68, xend=8.85, yend=9.68, arrow=FALSE),
  # collector to dedup
  data.frame(x=5.75, y=9.68, xend=5.75, yend=9.49, arrow=TRUE),

  # central pathway
  data.frame(
    x=rep(5.75,7),
    y=c(8.71,7.56,6.41,5.16,4.01,2.86,1.66),
    xend=rep(5.75,7),
    yend=c(8.34,7.19,6.04,4.94,3.79,2.44,1.28),
    arrow=TRUE
  ),

  # side branches
  data.frame(
    x=c(6.95,7.08,7.08,6.98,6.98),
    y=c(9.10,7.95,6.80,3.48,3.02),
    xend=c(7.98,7.98,7.83,7.98,7.98),
    yend=c(9.10,7.95,6.80,3.48,3.02),
    arrow=FALSE
  ),

  # topic outcome split and recombine
  data.frame(x=5.75, y=2.86, xend=4.95, yend=2.44, arrow=TRUE),
  data.frame(x=5.75, y=2.86, xend=7.20, yend=2.44, arrow=TRUE),
  data.frame(x=4.95, y=1.66, xend=5.75, yend=1.28, arrow=TRUE),
  data.frame(x=7.20, y=1.66, xend=5.75, yend=1.28, arrow=TRUE)
)

phase <- data.frame(
  x = rep(1.05, 4),
  y = c(9.70, 7.40, 4.05, 0.85),
  w = rep(0.55, 4),
  h = c(1.65, 2.30, 3.50, 0.95),
  label = c("Searching", "Curation and screening", "Annotation and classification", "Map"),
  stringsAsFactors = FALSE
)

# -------------------------------------------------------------------------
# 4. PLOT
# -------------------------------------------------------------------------

stage_fill <- c(
  source = "#f5f4f0",
  screen = "#dce7e7",
  retain = "#e2b8a2",
  annotate = "#f6d6c6",
  exclude = "#f1efeb",
  result = "#dce7e7",
  map = "#e55634"
)
stage_text <- c(
  source = "#2c454a",
  screen = "#2c454a",
  retain = "#2c454a",
  annotate = "#2c454a",
  exclude = "#2c454a",
  result = "#2c454a",
  map = "white"
)

p <- ggplot() +
  geom_segment(
    data = segments,
    aes(x=x, y=y, xend=xend, yend=yend),
    colour = "#577c84",
    linewidth = 0.55,
    arrow = grid::arrow(length = grid::unit(2.4, "mm"), type = "closed")
  ) +
  # Overpaint arrowheads for segments that are purely connectors.
  geom_segment(
    data = segments %>% filter(!arrow),
    aes(x=x, y=y, xend=xend, yend=yend),
    colour = "#577c84",
    linewidth = 0.55
  ) +
  geom_rect(
    data = boxes,
    aes(
      xmin = x - w/2, xmax = x + w/2,
      ymin = y - h/2, ymax = y + h/2,
      fill = stage
    ),
    colour = "#2c454a",
    linewidth = 0.45
  ) +
  geom_text(
    data = boxes,
    aes(x=x, y=y, label=label, colour=stage),
    size = 3.0,
    lineheight = 0.92,
    fontface = "plain"
  ) +
  geom_rect(
    data = phase,
    aes(
      xmin = x - w/2, xmax = x + w/2,
      ymin = y - h/2, ymax = y + h/2
    ),
    fill = "#577c84",
    colour = "#2c454a",
    linewidth = 0.45
  ) +
  geom_text(
    data = phase,
    aes(x=x, y=y, label=label),
    angle = 90,
    colour = "white",
    fontface = "bold",
    size = 3.15
  ) +
  scale_fill_manual(values = stage_fill, guide = "none") +
  scale_colour_manual(values = stage_text, guide = "none") +
  coord_cartesian(xlim = c(0.55, 10.65), ylim = c(0.25, 10.90), expand = FALSE) +
  theme_void(base_size = 11) +
  theme(
    plot.background = element_rect(fill = "white", colour = NA),
    plot.margin = margin(8, 8, 8, 8)
  )

ggsave(
  file.path(out_dir, "figure_07_flow_diagram.pdf"),
  p,
  width = 210,
  height = 225,
  units = "mm",
  device = cairo_pdf
)
ggsave(
  file.path(out_dir, "figure_07_flow_diagram.png"),
  p,
  width = 210,
  height = 225,
  units = "mm",
  dpi = 600
)

readr::write_csv(
  boxes %>% select(id, label, stage),
  file.path(out_dir, "figure_07_flow_diagram_boxes.csv")
)
readr::write_csv(
  data.frame(
    metric = c(
      "deduplicated_records",
      "publication_status_exclusions",
      "entered_workflow04",
      "workflow04_exclusions",
      "workflow04_retained",
      "workflow07_late_exclusions",
      "workflow08_exclusions",
      "final_included",
      "final_topic_coded",
      "final_topic_uncoded"
    ),
    n = c(
      n_deduplicated,
      n_w03,
      n_entered_w04,
      n_w04,
      n_w04_retained,
      n_w07,
      n_w08,
      n_final_included,
      n_topic_coded,
      n_topic_uncoded
    )
  ),
  file.path(out_dir, "figure_07_flow_diagram_counts.csv")
)

message("Workflow 09 flow diagram written to: ", out_dir)

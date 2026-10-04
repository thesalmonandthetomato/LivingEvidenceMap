#!/usr/bin/env Rscript

# Workflow 09 manuscript flow diagram.
#
# Cross-workflow counts are read from the compact, version-controlled reporting
# handoff under docs/reporting/workflow_09_inputs/current. W09 therefore does
# not reconstruct W01 or restore W02 merely to draw the flow diagram.

required <- c("dplyr", "ggplot2", "readr", "stringr", "here", "jsonlite")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing) > 0) stop("Install required packages: ", paste(missing, collapse = ", "))

library(dplyr)
library(ggplot2)
library(readr)
library(stringr)
library(here)
library(jsonlite)

out_dir <- here::here("visualisations")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

input_dir <- Sys.getenv(
  "W09_INPUT_DIR",
  unset = here::here("docs", "reporting", "workflow_09_inputs", "current")
)
if (!dir.exists(input_dir)) stop("Workflow 09 compact input directory not found: ", input_dir, call. = FALSE)

read_stage <- function(stage) {
  p <- file.path(input_dir, paste0(tolower(stage), "_summary.json"))
  if (!file.exists(p)) stop("Missing compact Workflow 09 stage summary: ", p, call. = FALSE)
  x <- fromJSON(p, simplifyVector = FALSE)
  if (!identical(as.character(x$stage), stage)) stop("Stage mismatch in ", p, call. = FALSE)
  x
}
metric <- function(x, name) {
  z <- x$metrics[[name]]
  if (is.null(z) || !length(z)) stop("Missing metric ", name, " in ", x$stage, call. = FALSE)
  as.integer(z[[1L]])
}

w00 <- read_stage("W00")
w01 <- read_stage("W01")
w02 <- read_stage("W02")
w03 <- read_stage("W03")
w04 <- read_stage("W04")
w05 <- read_stage("W05")
w06 <- read_stage("W06")
w07 <- read_stage("W07")
w08 <- read_stage("W08")

source_path <- file.path(input_dir, "w01_source_summary.csv")
if (!file.exists(source_path)) stop("Missing W01 compact source summary: ", source_path, call. = FALSE)
source_meta <- read_csv(source_path, show_col_types = FALSE, progress = FALSE) |>
  transmute(
    code = as.character(source_code),
    database = as.character(database),
    hits = as.integer(manifestations),
    search_date = as.character(search_date)
  ) |>
  arrange(database)

if (!nrow(source_meta) || any(!nzchar(source_meta$code)) || anyDuplicated(source_meta$code)) {
  stop("Invalid W01 source summary", call. = FALSE)
}

n_combined <- metric(w01, "source_manifestations")
n_deduplicated <- metric(w01, "canonical_records")
n_duplicates_removed <- metric(w01, "duplicates_removed")
n_enriched <- metric(w02, "enriched_records")
n_w03 <- metric(w03, "retraction_exclusions")
n_screened_ta <- metric(w04, "records")
n_w04 <- metric(w04, "excluded")
n_w04_retained <- metric(w04, "retained")
n_species_none <- metric(w05, "none_records")
n_w07_late <- metric(w07, "late_automatic_exclusions")
n_final_included <- metric(w08, "canonical_records")
n_excluded <- metric(w08, "excluded_records")
n_geography_coded <- metric(w08, "geography_with")
n_geography_uncoded <- metric(w08, "geography_without")
n_topic_coded <- metric(w08, "topic_with")
n_topic_uncoded <- metric(w08, "topic_without")

# Final post-screening exclusions are recorded separately from W04 because they
# arise during species/topic/final adjudication rather than title/abstract screening.
n_post_w04_excluded <- n_w04_retained - n_final_included

stopifnot(
  sum(source_meta$hits) == n_combined,
  n_combined - n_deduplicated == n_duplicates_removed,
  n_deduplicated - n_w03 == n_screened_ta,
  n_w04 + n_w04_retained == n_screened_ta,
  n_w04_retained - n_post_w04_excluded == n_final_included,
  n_deduplicated == n_final_included + n_excluded,
  n_geography_coded + n_geography_uncoded == n_final_included,
  n_topic_coded + n_topic_uncoded == n_final_included,
  n_post_w04_excluded >= n_species_none + n_w07_late
)

source_counts <- setNames(source_meta$hits, source_meta$database)
valid_source_dates <- source_meta$search_date[grepl("^\\d{4}-\\d{2}-\\d{2}$", source_meta$search_date)]
search_update_date <- if (length(valid_source_dates)) max(valid_source_dates) else ""
fmt <- function(x) format(as.integer(x), big.mark = ",", scientific = FALSE, trim = TRUE)

# -------------------------------------------------------------------------
# 5. DIAGRAM GEOMETRY
# -------------------------------------------------------------------------

box <- function(id, x, y, w, h, label, stage) {
  data.frame(id, x, y, w, h, label, stage, stringsAsFactors = FALSE)
}

process_box_w <- 2.75

# The search-source panel is always one box. To keep a consistent visual
# grammar as the database set grows, it uses two columns for <=6 databases and
# three columns for >6 databases. Each entry retains the source-specific hit
# count and search date.
n_source_cols <- if (nrow(source_meta) <= 6L) 2L else 3L
n_source_rows <- ceiling(nrow(source_meta) / n_source_cols)
source_panel_left <- 1.35
source_panel_right <- 10.15
source_panel_width <- source_panel_right - source_panel_left
source_panel_bottom <- 11.55
source_row_h <- 0.38
source_panel_height <- 0.78 + n_source_rows * source_row_h
source_panel_top <- source_panel_bottom + source_panel_height
source_panel_y <- (source_panel_bottom + source_panel_top) / 2
source_col_width <- (source_panel_width - 0.34) / n_source_cols

source_layout <- source_meta |>
  mutate(
    item = row_number(),
    column = ((item - 1L) %/% n_source_rows) + 1L,
    row = ((item - 1L) %% n_source_rows) + 1L,
    col_left = source_panel_left + 0.17 + (column - 1L) * source_col_width,
    name_x = col_left,
    hits_x = col_left + source_col_width * 0.62,
    date_x = col_left + source_col_width * 0.75,
    y = source_panel_top - 0.63 - (row - 1L) * source_row_h,
    hits_label = fmt(hits)
  )

source_headers <- tibble::tibble(
  column = seq_len(n_source_cols),
  col_left = source_panel_left + 0.17 + (seq_len(n_source_cols) - 1L) * source_col_width,
  y = source_panel_top - 0.34
) |>
  mutate(
    name_x = col_left,
    hits_x = col_left + source_col_width * 0.62,
    date_x = col_left + source_col_width * 0.75
  )

source_dividers <- if (n_source_cols > 1L) {
  tibble::tibble(
    x = source_panel_left + 0.17 + (seq_len(n_source_cols - 1L)) * source_col_width - 0.08,
    y = source_panel_bottom + 0.12,
    xend = x,
    yend = source_panel_top - 0.18
  )
} else {
  tibble::tibble(x = numeric(), y = numeric(), xend = numeric(), yend = numeric())
}

boxes <- bind_rows(
  box("combined", 5.64, 10.88, process_box_w, 0.76, paste0("Combined search results\nn = ", fmt(n_combined)), "search"),
  box("dedup", 5.64, 9.78, process_box_w, 0.76, paste0("Deduplicated records\nn = ", fmt(n_deduplicated)), "screen"),
  box("dupes", 9.15, 9.78, process_box_w, 0.76, paste0("Duplicate records removed\nn = ", fmt(n_duplicates_removed)), "exclude"),

  box("enrichment", 5.64, 8.68, process_box_w, 0.76, paste0("Record repair and enrichment\nn enriched = ", fmt(n_enriched)), "repair"),

  box("status_sweep", 5.64, 7.58, process_box_w, 0.76, paste0("Records swept for retractions /\nwithdrawal notices\nn = ", fmt(n_deduplicated)), "screen"),
  box("retractions", 9.15, 7.58, process_box_w, 0.76, paste0("Retractions excluded\nn = ", fmt(n_w03)), "exclude"),

  box("screened", 5.64, 6.48, process_box_w, 0.76, paste0("Records screened at title and abstract\nn = ", fmt(n_screened_ta)), "screen"),
  box("excluded_ta", 9.15, 6.48, process_box_w, 0.76, paste0("Records excluded at title and abstract\nn = ", fmt(n_w04)), "exclude"),
  box("retained", 5.64, 5.38, process_box_w, 0.76, paste0("Records retained after title and abstract\nn = ", fmt(n_w04_retained)), "retain"),

  box("species", 5.64, 4.18, process_box_w, 0.76, paste0("Species annotation\nn = ", fmt(n_final_included)), "annotate"),
  box("geography", 5.64, 3.13, process_box_w, 0.76, paste0("Records with geography annotation\nn = ", fmt(n_geography_coded)), "annotate"),
  box("geo_uncoded", 9.15, 3.13, process_box_w, 0.76, paste0("Included but uncoded for geography\nn = ", fmt(n_geography_uncoded)), "result"),
  box("topic", 5.64, 2.08, process_box_w, 0.76, paste0("Records with topic annotation\nn = ", fmt(n_topic_coded)), "annotate"),
  box("uncoded", 9.15, 2.08, process_box_w, 0.76, paste0("Included but uncoded for topics\nn = ", fmt(n_topic_uncoded)), "result"),

  box("map", 5.64, 0.88, process_box_w, 0.86, paste0("Living Evidence Map\nn = ", fmt(n_final_included)), "map")
)

main_arrows <- data.frame(
  x = rep(5.64, 9),
  y = c(source_panel_bottom, 10.50, 9.40, 8.30, 7.20, 6.10, 5.00, 3.80, 2.75),
  xend = rep(5.64, 9),
  yend = c(11.26, 10.16, 9.06, 7.96, 6.86, 5.76, 4.56, 3.51, 2.46)
)
main_arrows <- bind_rows(
  main_arrows,
  data.frame(x = 5.64, y = 1.70, xend = 5.64, yend = 1.31)
)

side_connectors <- data.frame(
  x = rep(5.64 + process_box_w / 2, 5),
  y = c(9.78, 7.58, 6.48, 3.13, 2.08),
  xend = rep(9.15 - process_box_w / 2, 5),
  yend = c(9.78, 7.58, 6.48, 3.13, 2.08)
)

search_phase_bottom <- 10.42
search_phase_top <- source_panel_top + 0.05
phase <- data.frame(
  x = rep(0.92, 4),
  y = c(
    (search_phase_bottom + search_phase_top) / 2,
    7.20,
    3.20,
    0.88
  ),
  w = rep(0.54, 4),
  h = c(
    search_phase_top - search_phase_bottom,
    4.35,
    3.10,
    0.96
  ),
  label = c("Searching", "Curation and screening", "Annotation and classification", "Map"),
  stringsAsFactors = FALSE
)

# -------------------------------------------------------------------------
# 6. PLOT
# -------------------------------------------------------------------------

stage_fill <- c(
  search = "#dce7e7",
  screen = "#dce7e7",
  repair = "#a8bdbe",
  retain = "#e2b8a2",
  annotate = "#f6d6c6",
  exclude = "#f1efeb",
  result = "#dce7e7",
  map = "#e55634"
)
stage_text <- c(
  search = "#2c454a",
  screen = "#2c454a",
  repair = "#2c454a",
  retain = "#2c454a",
  annotate = "#2c454a",
  exclude = "#2c454a",
  result = "#2c454a",
  map = "white"
)

p <- ggplot() +
  geom_segment(
    data = main_arrows,
    aes(x=x, y=y, xend=xend, yend=yend),
    colour = "#577c84", linewidth = 0.55,
    arrow = grid::arrow(length = grid::unit(2.3, "mm"), type = "closed")
  ) +
  geom_segment(
    data = side_connectors,
    aes(x=x, y=y, xend=xend, yend=yend),
    colour = "#577c84", linewidth = 0.55
  ) +
  geom_rect(
    aes(
      xmin = source_panel_left, xmax = source_panel_right,
      ymin = source_panel_bottom, ymax = source_panel_top
    ),
    fill = "#f5f4f0", colour = "#2c454a", linewidth = 0.45
  ) +
  geom_segment(
    data = source_dividers,
    aes(x=x, y=y, xend=xend, yend=yend),
    colour = "#c6ccca", linewidth = 0.4
  ) +
  annotate(
    "text",
    x = (source_panel_left + source_panel_right) / 2,
    y = source_panel_top - 0.14,
    label = "Bibliographic database searches",
    colour = "#2c454a",
    fontface = "bold",
    size = 3.15
  ) +
  geom_text(
    data = source_headers,
    aes(x = name_x, y = y),
    label = "Database", hjust = 0, fontface = "bold",
    colour = "#2c454a", size = 2.35
  ) +
  geom_text(
    data = source_headers,
    aes(x = hits_x, y = y),
    label = "Hits", hjust = 1, fontface = "bold",
    colour = "#2c454a", size = 2.35
  ) +
  geom_text(
    data = source_headers,
    aes(x = date_x, y = y),
    label = "Search date", hjust = 0, fontface = "bold",
    colour = "#2c454a", size = 2.35
  ) +
  geom_text(
    data = source_layout,
    aes(x = name_x, y = y, label = database),
    hjust = 0, colour = "#2c454a", size = 2.25
  ) +
  geom_text(
    data = source_layout,
    aes(x = hits_x, y = y, label = hits_label),
    hjust = 1, colour = "#2c454a", size = 2.25
  ) +
  geom_text(
    data = source_layout,
    aes(x = date_x, y = y, label = search_date),
    hjust = 0, colour = "#2c454a", size = 2.25
  ) +
  geom_rect(
    data = boxes,
    aes(
      xmin = x - w/2, xmax = x + w/2,
      ymin = y - h/2, ymax = y + h/2,
      fill = stage
    ),
    colour = "#2c454a", linewidth = 0.45
  ) +
  geom_text(
    data = boxes,
    aes(x=x, y=y, label=label, colour=stage),
    size = 2.95, lineheight = 0.92
  ) +
  geom_rect(
    data = phase,
    aes(
      xmin = x - w/2, xmax = x + w/2,
      ymin = y - h/2, ymax = y + h/2
    ),
    fill = "#577c84", colour = "#2c454a", linewidth = 0.45
  ) +
  geom_text(
    data = phase,
    aes(x=x, y=y, label=label),
    angle = 90, colour = "white", fontface = "bold", size = 3.05
  ) +
  scale_fill_manual(values = stage_fill, guide = "none") +
  scale_colour_manual(values = stage_text, guide = "none") +
  coord_cartesian(
    xlim = c(0.45, 10.65),
    ylim = c(0.25, source_panel_top + 0.20),
    expand = FALSE
  ) +
  theme_void(base_size = 11) +
  theme(
    plot.background = element_rect(fill = "white", colour = NA),
    plot.margin = margin(8, 8, 8, 8)
  )

figure_height_mm <- 245 + max(0, source_panel_height - 1.55) * 18
ggsave(
  file.path(out_dir, "figure_07_flow_diagram.pdf"),
  p, width = 210, height = figure_height_mm, units = "mm", device = cairo_pdf
)
ggsave(
  file.path(out_dir, "figure_07_flow_diagram.png"),
  p, width = 210, height = figure_height_mm, units = "mm", dpi = 600
)

# Machine-readable output generated from the same compact reporting inputs.
n_w08_other_exclusions <- n_post_w04_excluded - n_species_none - n_w07_late
if (n_w08_other_exclusions < 0L) stop("Post-W04 exclusion accounting is negative", call. = FALSE)

counts <- list(
  schema = "living-evidence-map-workflow09-flow-counts-v3",
  generated_at_utc = format(Sys.time(), tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ"),
  search_update_date = if (nzchar(search_update_date)) search_update_date else NULL,
  input_mode = "compact_workflow_reporting_snapshots",
  input_directory = input_dir,
  source_runs = list(
    W00 = as.character(w00$source_run_id),
    W01 = as.character(w01$source_run_id),
    W02 = as.character(w02$source_run_id),
    W03 = as.character(w03$source_run_id),
    W04 = as.character(w04$source_run_id),
    W05 = as.character(w05$source_run_id),
    W06 = as.character(w06$source_run_id),
    W07 = as.character(w07$source_run_id),
    W08 = as.character(w08$source_run_id)
  ),
  counts = list(
    sources = as.list(source_counts),
    source_searches = lapply(seq_len(nrow(source_meta)), function(i) list(
      code = source_meta$code[[i]],
      database = source_meta$database[[i]],
      hits = as.integer(source_meta$hits[[i]]),
      search_date = if (nzchar(source_meta$search_date[[i]])) source_meta$search_date[[i]] else NULL
    )),
    combined_search_results = n_combined,
    duplicates_removed = n_duplicates_removed,
    deduplicated_records = n_deduplicated,
    records_enriched_workflow02 = n_enriched,
    retractions_excluded = n_w03,
    title_abstract_screened = n_screened_ta,
    workflow04_exclusions = n_w04,
    title_abstract_retained = n_w04_retained,
    species_none_deterministic_exclusions = n_species_none,
    workflow07_late_exclusions = n_w07_late,
    workflow08_other_exclusions = n_w08_other_exclusions,
    post_workflow04_exclusions_total = n_post_w04_excluded,
    final_geography_coded = n_geography_coded,
    final_geography_uncoded = n_geography_uncoded,
    final_topic_coded = n_topic_coded,
    final_topic_uncoded = n_topic_uncoded,
    final_included = n_final_included,
    final_excluded = n_excluded
  )
)

write_json(
  counts,
  file.path(out_dir, "figure_07_flow_diagram_counts.json"),
  pretty = TRUE, auto_unbox = TRUE, null = "null"
)

readr::write_csv(
  boxes %>% select(id, label, stage),
  file.path(out_dir, "figure_07_flow_diagram_boxes.csv")
)

readr::write_csv(
  data.frame(
    metric = c(
      paste0("source_", names(source_counts)),
      "combined_search_results",
      "duplicates_removed",
      "deduplicated_records",
      "records_enriched_workflow02",
      "retractions_excluded",
      "records_screened_title_abstract",
      "workflow04_exclusions",
      "records_retained_after_title_abstract",
      "species_none_deterministic_exclusions",
      "workflow07_late_exclusions",
      "workflow08_other_exclusions",
      "final_geography_coded",
      "final_geography_uncoded",
      "final_topic_coded",
      "final_topic_uncoded",
      "final_included"
    ),
    n = c(
      unname(source_counts),
      n_combined,
      n_duplicates_removed,
      n_deduplicated,
      n_enriched,
      n_w03,
      n_screened_ta,
      n_w04,
      n_w04_retained,
      n_species_none,
      n_w07_late,
      n_w08_other_exclusions,
      n_geography_coded,
      n_geography_uncoded,
      n_topic_coded,
      n_topic_uncoded,
      n_final_included
    )
  ),
  file.path(out_dir, "figure_07_flow_diagram_counts.csv")
)

message("Workflow 09 flow diagram written from compact reporting inputs: ", input_dir)

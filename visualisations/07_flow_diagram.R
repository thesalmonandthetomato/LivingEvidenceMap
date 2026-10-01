#!/usr/bin/env Rscript

# Workflow 09 manuscript flow diagram.
#
# Counts are derived at render time from authoritative pipeline outputs:
#   - Workflow 01 deduplicated canonical JSONL: source manifestations + deduplicated works
#   - Workflow 02 cumulative enrichment patch JSONL: records with metadata fields filled
#   - Workflow 08 final included canonical JSONL: final annotation state
#   - Workflow 08 exclusions CSV: screening/exclusion stages
#
# No manuscript count is hard-coded. The script fails if stage totals do not reconcile.

required <- c("dplyr", "ggplot2", "readr", "stringr", "here", "jsonlite", "digest")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing) > 0) stop("Install required packages: ", paste(missing, collapse = ", "))

library(dplyr)
library(ggplot2)
library(readr)
library(stringr)
library(here)
library(jsonlite)
library(digest)

source(here::here("visualisations", "canonical_figure_data.R"))

out_dir <- here::here("visualisations")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

# -------------------------------------------------------------------------
# 1. AUTHORITATIVE INPUTS
# -------------------------------------------------------------------------

final_path <- canonical_jsonl_path()
canonical <- load_figure_master(final_path)
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
  stop("Workflow 08 exclusions CSV is required. Provide --exclusions-csv or set EXCLUSIONS_CSV.", call. = FALSE)
}

prescreen_path <- canonical_arg("--prescreen-canonical") %||%
  Sys.getenv("PRESCREEN_CANONICAL_JSONL", unset = "")
if (!nzchar(prescreen_path) || !file.exists(prescreen_path)) {
  stop("Workflow 01 pre-screening canonical JSONL is required. Provide --prescreen-canonical or set PRESCREEN_CANONICAL_JSONL.", call. = FALSE)
}

w02_patch_path <- canonical_arg("--workflow02-patch") %||%
  Sys.getenv("WORKFLOW02_PATCH_JSONL", unset = "")
if (!nzchar(w02_patch_path) || !file.exists(w02_patch_path)) {
  stop("Workflow 02 cumulative enrichment patch JSONL is required. Provide --workflow02-patch or set WORKFLOW02_PATCH_JSONL.", call. = FALSE)
}

# -------------------------------------------------------------------------
# 2. WORKFLOW 01: SOURCE MANIFESTATIONS + DEDUPLICATED WORKS
# -------------------------------------------------------------------------

source_labels <- c(
  lens = "The Lens",
  scopus = "Scopus",
  openalex = "OpenAlex",
  agricola = "AGRICOLA",
  wos = "WoSCC",
  cab = "CAB Abstracts",
  proquest = "ProQuest/PQD&T"
)
source_counts_raw <- setNames(integer(length(source_labels)), names(source_labels))
n_deduplicated <- 0L
n_combined <- 0L
prescreen_ids <- character()

con <- file(prescreen_path, "rt", encoding = "UTF-8")
on.exit(close(con), add = TRUE)
repeat {
  line <- readLines(con, n = 1L, warn = FALSE)
  if (!length(line)) break
  if (!nzchar(trimws(line))) next

  rec <- jsonlite::fromJSON(line, simplifyVector = FALSE)
  rid <- as.character(rec$identity$record_id %||% "")
  if (!nzchar(rid)) stop("Workflow 01 canonical record missing identity.record_id.", call. = FALSE)

  mans <- rec$manifestations %||% list()
  if (!length(mans)) stop("Workflow 01 canonical record has no manifestations: ", rid, call. = FALSE)

  src <- vapply(mans, function(m) as.character(m$source %||% ""), character(1))
  if (any(!nzchar(src))) stop("Workflow 01 manifestation missing source in record: ", rid, call. = FALSE)
  unknown <- setdiff(unique(src), names(source_labels))
  if (length(unknown)) {
    stop("Unknown Workflow 01 manifestation source(s): ", paste(unknown, collapse = ", "), call. = FALSE)
  }

  n_deduplicated <- n_deduplicated + 1L
  n_combined <- n_combined + length(src)
  prescreen_ids <- c(prescreen_ids, rid)
  tab <- table(src)
  source_counts_raw[names(tab)] <- source_counts_raw[names(tab)] + as.integer(tab)
}
close(con)
on.exit(NULL, add = FALSE)

if (anyDuplicated(prescreen_ids)) stop("Workflow 01 canonical JSONL contains duplicate record_id values.", call. = FALSE)
source_counts <- setNames(as.integer(source_counts_raw[names(source_labels)]), unname(source_labels))
n_duplicates_removed <- n_combined - n_deduplicated

if (sum(source_counts) != n_combined) {
  stop("Source manifestation counts do not sum to combined search results.", call. = FALSE)
}

# -------------------------------------------------------------------------
# 3. WORKFLOW 02: RECORDS ACTUALLY ENRICHED
# -------------------------------------------------------------------------

enriched_ids <- character()
patch_ids <- character()

con <- file(w02_patch_path, "rt", encoding = "UTF-8")
on.exit(close(con), add = TRUE)
repeat {
  line <- readLines(con, n = 1L, warn = FALSE)
  if (!length(line)) break
  if (!nzchar(trimws(line))) next

  rec <- jsonlite::fromJSON(line, simplifyVector = FALSE)
  rid <- as.character(rec$record_id %||% "")
  if (!nzchar(rid)) stop("Workflow 02 patch record missing record_id.", call. = FALSE)
  patch_ids <- c(patch_ids, rid)

  meta <- rec$metadata_enrichment %||% list()
  filled <- meta$filled_fields %||% character()
  filled <- as.character(filled)
  filled <- filled[!is.na(filled) & nzchar(trimws(filled))]
  if (length(filled)) enriched_ids <- c(enriched_ids, rid)
}
close(con)
on.exit(NULL, add = FALSE)

if (anyDuplicated(patch_ids)) stop("Workflow 02 cumulative patch contains duplicate record_id values.", call. = FALSE)
if (length(setdiff(patch_ids, prescreen_ids))) {
  stop("Workflow 02 patch contains record IDs absent from the Workflow 01 canonical.", call. = FALSE)
}
n_enriched <- length(unique(enriched_ids))

# -------------------------------------------------------------------------
# 4. WORKFLOW 08: SCREENING + FINAL ANNOTATION STATE
# -------------------------------------------------------------------------

exclusions <- readr::read_csv(exclusions_path, show_col_types = FALSE, progress = FALSE)
if (!all(c("record_id", "exclusion_stage") %in% names(exclusions))) {
  stop("Exclusions CSV must contain record_id and exclusion_stage.", call. = FALSE)
}
if (anyDuplicated(exclusions$record_id)) stop("Workflow 08 exclusions CSV contains duplicate record_id values.", call. = FALSE)

stage_counts <- exclusions %>% count(exclusion_stage, name = "n")
stage_n <- function(stage) {
  x <- stage_counts$n[match(stage, stage_counts$exclusion_stage)]
  if (!length(x) || is.na(x)) 0L else as.integer(x)
}

n_w03 <- stage_n("workflow03")
n_w04 <- stage_n("workflow04")
n_w07 <- stage_n("workflow07_late")
n_w08 <- stage_n("workflow08")
n_excluded <- nrow(exclusions)

n_screened_ta <- n_deduplicated - n_w03
n_excluded_ta_total <- n_w04 + n_w07 + n_w08
n_retained_final <- n_screened_ta - n_excluded_ta_total

geo_status <- toupper(trimws(as.character(canonical$geography_status)))
unknown_geo <- setdiff(unique(geo_status), c("RESOLVED", "NONE"))
if (length(unknown_geo)) {
  stop("Unexpected final geography status value(s): ", paste(unknown_geo, collapse = ", "), call. = FALSE)
}
n_geography_coded <- sum(geo_status == "RESOLVED")
n_geography_uncoded <- sum(geo_status == "NONE")

n_topic_uncoded <- sum(
  is.na(canonical$topic_hierarchy_paths) |
    stringr::str_trim(canonical$topic_hierarchy_paths) == ""
)
n_topic_coded <- n_final_included - n_topic_uncoded

# Cross-stage reconciliation. These are relationships, not frozen manuscript counts.
if (n_deduplicated != n_final_included + n_excluded) {
  stop("Workflow 01 deduplicated total does not reconcile with Workflow 08 included + excluded totals.", call. = FALSE)
}
if (n_retained_final != n_final_included) {
  stop("Title/abstract screening flow does not reconcile to final included records.", call. = FALSE)
}
if (n_geography_coded + n_geography_uncoded != n_final_included) {
  stop("Final geography counts do not reconcile to final included records.", call. = FALSE)
}
if (n_topic_coded + n_topic_uncoded != n_final_included) {
  stop("Final topic counts do not reconcile to final included records.", call. = FALSE)
}

fmt <- function(x) format(as.integer(x), big.mark = ",", scientific = FALSE, trim = TRUE)

# -------------------------------------------------------------------------
# 5. DIAGRAM GEOMETRY
# -------------------------------------------------------------------------

box <- function(id, x, y, w, h, label, stage) {
  data.frame(id, x, y, w, h, label, stage, stringsAsFactors = FALSE)
}

source_box_w <- 1.18
process_box_w <- 2.75
source_x <- seq(1.75, 9.53, length.out = length(source_labels))
source_boxes <- bind_rows(lapply(seq_along(source_labels), function(i) {
  box(
    names(source_labels)[[i]], source_x[[i]], 12.00, source_box_w, 0.76,
    paste0(unname(source_labels[[i]]), "\nn = ", fmt(source_counts[[unname(source_labels[[i]])]])),
    "source"
  )
}))

boxes <- bind_rows(
  source_boxes,
  box("combined", 5.64, 10.88, process_box_w, 0.76, paste0("Combined search results\nn = ", fmt(n_combined)), "search"),
  box("dedup", 5.64, 9.78, process_box_w, 0.76, paste0("Deduplicated records\nn = ", fmt(n_deduplicated)), "screen"),
  box("dupes", 9.15, 9.78, process_box_w, 0.76, paste0("Duplicate records removed\nn = ", fmt(n_duplicates_removed)), "exclude"),

  box("enrichment", 5.64, 8.68, process_box_w, 0.76, paste0("Record repair and enrichment\nn enriched = ", fmt(n_enriched)), "repair"),

  box("status_sweep", 5.64, 7.58, process_box_w, 0.76, paste0("Records swept for retractions /\nwithdrawal notices\nn = ", fmt(n_deduplicated)), "screen"),
  box("retractions", 9.15, 7.58, process_box_w, 0.76, paste0("Retractions excluded\nn = ", fmt(n_w03)), "exclude"),

  box("screened", 5.64, 6.48, process_box_w, 0.76, paste0("Records screened at title and abstract\nn = ", fmt(n_screened_ta)), "screen"),
  box("excluded_ta", 9.15, 6.48, process_box_w, 0.76, paste0("Records excluded at title and abstract\nn = ", fmt(n_excluded_ta_total)), "exclude"),
  box("retained", 5.64, 5.38, process_box_w, 0.76, paste0("Records retained after title and abstract\nn = ", fmt(n_retained_final)), "retain"),

  box("species", 5.64, 4.18, process_box_w, 0.76, paste0("Species annotation\nn = ", fmt(n_final_included)), "annotate"),
  box("geography", 5.64, 3.13, process_box_w, 0.76, paste0("Records with geography annotation\nn = ", fmt(n_geography_coded)), "annotate"),
  box("geo_uncoded", 9.15, 3.13, process_box_w, 0.76, paste0("Included but uncoded for geography\nn = ", fmt(n_geography_uncoded)), "result"),
  box("topic", 5.64, 2.08, process_box_w, 0.76, paste0("Records with topic annotation\nn = ", fmt(n_topic_coded)), "annotate"),
  box("uncoded", 9.15, 2.08, process_box_w, 0.76, paste0("Included but uncoded for topics\nn = ", fmt(n_topic_uncoded)), "result"),

  box("map", 5.64, 0.88, process_box_w, 0.86, paste0("Living Evidence Map\nn = ", fmt(n_final_included)), "map")
)

source_vertical <- data.frame(
  x = source_x,
  y = rep(11.62, length(source_x)),
  xend = source_x,
  yend = rep(11.43, length(source_x))
)
source_collector <- data.frame(x = min(source_x), y = 11.43, xend = max(source_x), yend = 11.43)

main_arrows <- data.frame(
  x = rep(5.64, 9),
  y = c(11.43, 10.50, 9.40, 8.30, 7.20, 6.10, 5.00, 3.80, 2.75),
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

phase <- data.frame(
  x = rep(0.92, 4),
  y = c(11.35, 7.20, 3.20, 0.88),
  w = rep(0.54, 4),
  h = c(1.80, 4.35, 3.10, 0.96),
  label = c("Searching", "Curation and screening", "Annotation and classification", "Map"),
  stringsAsFactors = FALSE
)

# -------------------------------------------------------------------------
# 6. PLOT
# -------------------------------------------------------------------------

stage_fill <- c(
  source = "#f5f4f0",
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
  source = "#2c454a",
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
    data = source_vertical,
    aes(x=x, y=y, xend=xend, yend=yend),
    colour = "#577c84", linewidth = 0.55
  ) +
  geom_segment(
    data = source_collector,
    aes(x=x, y=y, xend=xend, yend=yend),
    colour = "#577c84", linewidth = 0.55
  ) +
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
  coord_cartesian(xlim = c(0.45, 10.65), ylim = c(0.25, 12.50), expand = FALSE) +
  theme_void(base_size = 11) +
  theme(
    plot.background = element_rect(fill = "white", colour = NA),
    plot.margin = margin(8, 8, 8, 8)
  )

ggsave(
  file.path(out_dir, "figure_07_flow_diagram.pdf"),
  p, width = 210, height = 245, units = "mm", device = cairo_pdf
)
ggsave(
  file.path(out_dir, "figure_07_flow_diagram.png"),
  p, width = 210, height = 245, units = "mm", dpi = 600
)

# Machine-readable output generated from the same analysis used for the figure.
search_update_date <- trimws(Sys.getenv("SEARCH_UPDATE_DATE", unset = ""))
if (nzchar(search_update_date) && !grepl("^\\d{4}-\\d{2}-\\d{2}$", search_update_date)) {
  stop("SEARCH_UPDATE_DATE must be YYYY-MM-DD when supplied.", call. = FALSE)
}

counts <- list(
  schema = "living-evidence-map-workflow09-flow-counts-v2",
  generated_at_utc = format(Sys.time(), tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ"),
  search_update_date = if (nzchar(search_update_date)) search_update_date else NULL,
  inputs = list(
    workflow01_canonical_jsonl = list(path = prescreen_path, sha256 = digest(prescreen_path, algo = "sha256", file = TRUE, serialize = FALSE)),
    workflow02_cumulative_patch_jsonl = list(path = w02_patch_path, sha256 = digest(w02_patch_path, algo = "sha256", file = TRUE, serialize = FALSE)),
    workflow08_final_canonical_jsonl = list(path = final_path, sha256 = digest(final_path, algo = "sha256", file = TRUE, serialize = FALSE)),
    workflow08_exclusions_csv = list(path = exclusions_path, sha256 = digest(exclusions_path, algo = "sha256", file = TRUE, serialize = FALSE))
  ),
  counts = list(
    sources = as.list(source_counts),
    combined_search_results = n_combined,
    duplicates_removed = n_duplicates_removed,
    deduplicated_records = n_deduplicated,
    records_enriched_workflow02 = n_enriched,
    retractions_excluded = n_w03,
    title_abstract_screened = n_screened_ta,
    title_abstract_excluded_total = n_excluded_ta_total,
    workflow04_exclusions = n_w04,
    workflow07_late_exclusions = n_w07,
    workflow08_exclusions = n_w08,
    title_abstract_retained_final = n_retained_final,
    final_geography_coded = n_geography_coded,
    final_geography_uncoded = n_geography_uncoded,
    final_topic_coded = n_topic_coded,
    final_topic_uncoded = n_topic_uncoded,
    final_included = n_final_included
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
      "records_excluded_title_abstract_total",
      "records_retained_final",
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
      n_excluded_ta_total,
      n_retained_final,
      n_geography_coded,
      n_geography_uncoded,
      n_topic_coded,
      n_topic_uncoded,
      n_final_included
    )
  ),
  file.path(out_dir, "figure_07_flow_diagram_counts.csv")
)

message("Workflow 09 flow diagram written to: ", out_dir)

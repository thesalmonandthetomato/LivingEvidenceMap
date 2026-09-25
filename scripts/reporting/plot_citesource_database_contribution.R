#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(jsonlite)
  library(dplyr)
  library(tidyr)
  library(CiteSource)
})

args <- commandArgs(trailingOnly = TRUE)
arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("Missing value after %s", flag), call. = FALSE)
  args[[i + 1L]]
}

input_path <- arg("--input")
output_dir <- arg("--output-dir", "outputs/citesource_contribution")
if (is.null(input_path)) stop("Required: --input", call. = FALSE)
if (!file.exists(input_path)) stop(sprintf("Canonical JSONL not found: %s", input_path), call. = FALSE)

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

source_labels <- c(
  lens = "Lens",
  scopus = "Scopus",
  openalex = "OpenAlex",
  agricola = "AGRICOLA",
  wos = "Web of Science"
)

# Read only the provenance needed for this analysis. One canonical work becomes
# one CiteSource citation row; cite_source contains every database manifestation
# represented in that deduplicated work.
con <- file(input_path, "rt", encoding = "UTF-8")
on.exit(close(con), add = TRUE)

rows <- vector("list", 0L)
n <- 0L
repeat {
  line <- readLines(con, n = 1L, warn = FALSE)
  if (!length(line)) break
  if (!nzchar(trimws(line))) next

  rec <- fromJSON(line, simplifyVector = FALSE)
  rid <- as.character(rec$identity$record_id)
  mans <- rec$manifestations

  if (is.null(rid) || !nzchar(rid)) stop("Canonical record missing identity.record_id", call. = FALSE)
  if (is.null(mans) || !length(mans)) stop(sprintf("Canonical record %s has no manifestations", rid), call. = FALSE)

  src <- unique(vapply(mans, function(m) as.character(m$source), character(1)))
  unknown <- setdiff(src, names(source_labels))
  if (length(unknown)) stop(sprintf("Unknown source(s) in %s: %s", rid, paste(unknown, collapse = ", ")), call. = FALSE)

  # Fixed source order makes outputs deterministic.
  src <- names(source_labels)[names(source_labels) %in% src]

  n <- n + 1L
  rows[[n]] <- data.frame(
    duplicate_id = rid,
    cite_source = paste(unname(source_labels[src]), collapse = ", "),
    cite_label = "search",
    cite_string = "canonical",
    stringsAsFactors = FALSE
  )
}
close(con)
on.exit(NULL, add = FALSE)

canonical_sources <- bind_rows(rows)
if (!nrow(canonical_sources)) stop("No canonical records parsed", call. = FALSE)
if (anyDuplicated(canonical_sources$duplicate_id)) stop("Duplicate canonical record IDs", call. = FALSE)

# Use CiteSource directly for source comparison and uniqueness classification.
comparison <- CiteSource::compare_sources(canonical_sources, comp_type = "sources")
classified <- CiteSource::count_unique(canonical_sources)

# Exact per-source contribution after deduplication.
source_summary <- classified |>
  distinct(duplicate_id, cite_source, type) |>
  group_by(cite_source) |>
  summarise(
    canonical_works = n_distinct(duplicate_id),
    unique_to_source = n_distinct(duplicate_id[type == "unique"]),
    shared_with_other_sources = n_distinct(duplicate_id[type == "duplicated"]),
    .groups = "drop"
  ) |>
  mutate(
    unique_share_of_source = unique_to_source / canonical_works,
    share_of_all_canonical_works = canonical_works / nrow(canonical_sources)
  ) |>
  arrange(desc(canonical_works))

# Validate summary against the logical source matrix produced by CiteSource.
matrix_counts <- comparison |>
  select(starts_with("source__")) |>
  summarise(across(everything(), sum)) |>
  pivot_longer(everything(), names_to = "source", values_to = "canonical_works") |>
  mutate(source = sub("^source__", "", source))

check <- left_join(
  source_summary |> select(cite_source, canonical_works),
  matrix_counts,
  by = c("cite_source" = "source"),
  suffix = c("_summary", "_matrix")
)
stopifnot(nrow(check) == length(source_labels))
stopifnot(all(check$canonical_works_summary == check$canonical_works_matrix))

write.csv(
  source_summary,
  file.path(output_dir, "source_contribution_summary.csv"),
  row.names = FALSE
)
write.csv(
  comparison,
  file.path(output_dir, "source_overlap_matrix.csv"),
  row.names = FALSE
)

# CiteSource's UpSet plot shows:
# - left bars: number of canonical works represented by each database;
# - top bars: exact unique/shared source combinations after deduplication.
png(
  file.path(output_dir, "database_contribution_upset.png"),
  width = 2600, height = 1600, res = 220
)
CiteSource::plot_source_overlap_upset(
  comparison,
  groups = "source",
  nsets = length(source_labels),
  sets.x.label = "Canonical works contributed",
  mainbar.y.label = "Canonical works in source intersection",
  order.by = c("freq", "degree"),
  decreasing = c(TRUE, TRUE),
  text.scale = 1.35
)
dev.off()

pdf(
  file.path(output_dir, "database_contribution_upset.pdf"),
  width = 12, height = 7.5,
  useDingbats = FALSE
)
CiteSource::plot_source_overlap_upset(
  comparison,
  groups = "source",
  nsets = length(source_labels),
  sets.x.label = "Canonical works contributed",
  mainbar.y.label = "Canonical works in source intersection",
  order.by = c("freq", "degree"),
  decreasing = c(TRUE, TRUE),
  text.scale = 1.35
)
dev.off()

report <- list(
  schema = "living-evidence-map-citesource-contribution-v1",
  status = "PASS",
  canonical_records = nrow(canonical_sources),
  databases = unname(source_labels),
  interpretation = list(
    source_set_size = "Number of deduplicated canonical works with at least one manifestation from the database",
    unique_intersection = "Canonical works found by one database only",
    shared_intersection = "Canonical works represented in two or more databases"
  ),
  outputs = list(
    figure_png = "database_contribution_upset.png",
    figure_pdf = "database_contribution_upset.pdf",
    summary_csv = "source_contribution_summary.csv",
    overlap_matrix_csv = "source_overlap_matrix.csv"
  )
)
writeLines(
  toJSON(report, auto_unbox = TRUE, pretty = TRUE, null = "null"),
  file.path(output_dir, "report.json"),
  useBytes = TRUE
)

cat(sprintf("PASS: CiteSource contribution analysis for %d canonical works\n", nrow(canonical_sources)))
print(source_summary)

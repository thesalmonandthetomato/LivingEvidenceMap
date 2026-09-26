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
included_ids_path <- arg("--included-ids")
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


included_ids <- character()
if (!is.null(included_ids_path)) {
  if (!file.exists(included_ids_path)) stop(sprintf("Included-ID file not found: %s", included_ids_path), call. = FALSE)
  included_ids <- readLines(included_ids_path, warn = FALSE, encoding = "UTF-8")
  included_ids <- included_ids[nzchar(trimws(included_ids))]
  if (anyDuplicated(included_ids)) stop("Included-ID file contains duplicate record_id values", call. = FALSE)
}

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


# Machine-readable provenance matrix: one row per canonical work, one logical
# indicator per database, plus the Workflow 04 inclusion state when supplied.
source_presence <- canonical_sources |>
  transmute(
    record_id = duplicate_id,
    cite_source = as.character(cite_source)
  )

source_membership <- strsplit(source_presence$cite_source, ", ", fixed = TRUE)
for (lab in unname(source_labels)) {
  source_presence[[lab]] <- vapply(source_membership, function(x) lab %in% x, logical(1))
}
source_presence$included_w04 <- source_presence$record_id %in% included_ids

if (length(included_ids)) {
  missing_included <- setdiff(included_ids, source_presence$record_id)
  if (length(missing_included)) {
    stop(sprintf("%d Workflow 04 included record_id values are absent from the canonical provenance matrix", length(missing_included)), call. = FALSE)
  }
  if (sum(source_presence$included_w04) != length(included_ids)) {
    stop("Workflow 04 included-record count does not match provenance matrix", call. = FALSE)
  }
}

write.csv(
  source_presence |> select(-cite_source),
  file.path(output_dir, "source_provenance_screening.csv"),
  row.names = FALSE
)

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


screening_summary <- tibble(
  database = unname(source_labels),
  deduplicated_records = vapply(unname(source_labels), function(lab) sum(source_presence[[lab]]), integer(1)),
  included_records = vapply(unname(source_labels), function(lab) sum(source_presence[[lab]] & source_presence$included_w04), integer(1))
) |>
  mutate(
    included_share_of_source = included_records / deduplicated_records,
    share_of_all_includes = if (length(included_ids)) included_records / length(included_ids) else NA_real_
  )

write.csv(
  screening_summary,
  file.path(output_dir, "source_contribution_screening_summary.csv"),
  row.names = FALSE
)

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
  workflow04_included_records = if (length(included_ids)) length(included_ids) else NULL,
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
    overlap_matrix_csv = "source_overlap_matrix.csv",
    provenance_screening_csv = "source_provenance_screening.csv",
    screening_summary_csv = "source_contribution_screening_summary.csv"
  )
)
writeLines(
  toJSON(report, auto_unbox = TRUE, pretty = TRUE, null = "null"),
  file.path(output_dir, "report.json"),
  useBytes = TRUE
)

cat(sprintf("PASS: CiteSource contribution analysis for %d canonical works\n", nrow(canonical_sources)))
print(source_summary)
if (length(included_ids)) print(screening_summary)

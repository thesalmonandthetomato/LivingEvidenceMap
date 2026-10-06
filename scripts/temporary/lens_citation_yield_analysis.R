#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(jsonlite)
})

args <- commandArgs(trailingOnly = TRUE)
`%||%` <- function(x, y) if (is.null(x)) y else x
arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("Missing value after %s", flag), call. = FALSE)
  args[[i + 1L]]
}

ranking_path <- arg("--ranking")
w04_path <- arg("--w04-results", "")
output_dir <- arg("--output-dir", "outputs/lens_citation_yield")
sample_stratum <- arg("--sample-stratum", "")
sample_n <- as.integer(arg("--sample-n", "0"))
sample_seed <- as.integer(arg("--sample-seed", "20261006"))

if (is.null(ranking_path) || !file.exists(ranking_path)) stop("--ranking CSV is required", call. = FALSE)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

ranking <- read.csv(ranking_path, stringsAsFactors = FALSE, check.names = FALSE)
if (!all(c("candidate_lens_id","n_unique_included_connections","connectivity_stratum","priority_rank") %in% names(ranking))) {
  stop("Ranking file lacks required columns", call. = FALSE)
}

if (nzchar(sample_stratum) && sample_n > 0L) {
  pool <- ranking[ranking$connectivity_stratum == sample_stratum, , drop = FALSE]
  if (!nrow(pool)) stop("Requested sample stratum is empty", call. = FALSE)
  set.seed(sample_seed)
  n <- min(sample_n, nrow(pool))
  samp <- pool[sample(seq_len(nrow(pool)), n), , drop = FALSE]
  samp <- samp[order(samp$priority_rank), , drop = FALSE]
  write.csv(samp, file.path(output_dir, "tail_validation_sample.csv"), row.names = FALSE)
  write_json(list(
    schema = "citation-gap-tail-sample-v1",
    connectivity_stratum = sample_stratum,
    population_n = nrow(pool),
    sample_n = n,
    random_seed = sample_seed,
    screening_status = "NOT_SCREENED"
  ), file.path(output_dir, "tail_validation_sample_manifest.json"),
  auto_unbox = TRUE, pretty = TRUE)
}

if (!nzchar(w04_path)) {
  cat("No W04 results supplied; sampling/preparation only.\n")
  quit(save = "no", status = 0L)
}
if (!file.exists(w04_path)) stop("--w04-results does not exist", call. = FALSE)

lines <- readLines(w04_path, warn = FALSE, encoding = "UTF-8")
lines <- lines[nzchar(trimws(lines))]
rows <- lapply(lines, function(x) fromJSON(x, simplifyVector = FALSE))
dec <- data.frame(
  candidate_lens_id = vapply(rows, function(x) {
    as.character(x$candidate_lens_id %||% x$lens_id %||% x$record_id %||% "")
  }, character(1)),
  decision = vapply(rows, function(x) {
    as.character(x$decision %||% (x$screening %||% list())$decision %||% "")
  }, character(1)),
  stringsAsFactors = FALSE
)
dec <- dec[nzchar(dec$candidate_lens_id), , drop = FALSE]
m <- merge(ranking, dec, by = "candidate_lens_id", all.x = TRUE)
m$screened <- !is.na(m$decision) & nzchar(m$decision)
m$retained <- m$decision == "retain"
m$excluded <- m$decision == "exclude"
m$unresolved <- m$decision == "uncertain"

strata <- unique(m$connectivity_stratum[order(-m$n_unique_included_connections)])
out <- lapply(strata, function(s) {
  z <- m[m$connectivity_stratum == s, , drop = FALSE]
  ns <- sum(z$screened)
  nr <- sum(z$retained, na.rm = TRUE)
  data.frame(
    connectivity_stratum = s,
    candidates = nrow(z),
    screened = ns,
    retained = nr,
    excluded = sum(z$excluded, na.rm = TRUE),
    unresolved = sum(z$unresolved, na.rm = TRUE),
    inclusion_rate = if (ns) nr/ns else NA_real_,
    stringsAsFactors = FALSE
  )
})
yield <- do.call(rbind, out)
yield$cumulative_screened <- cumsum(yield$screened)
yield$cumulative_retained <- cumsum(yield$retained)
yield$marginal_retained_per_1000_screened <- ifelse(yield$screened > 0, 1000 * yield$retained/yield$screened, NA_real_)
write.csv(yield, file.path(output_dir, "yield_by_connectivity.csv"), row.names = FALSE)

by_degree <- aggregate(
  cbind(screened = as.integer(m$screened), retained = as.integer(m$retained)) ~ n_unique_included_connections,
  data = m, FUN = sum
)
by_degree$inclusion_rate <- ifelse(by_degree$screened > 0, by_degree$retained/by_degree$screened, NA_real_)
by_degree <- by_degree[order(-by_degree$n_unique_included_connections), ]
write.csv(by_degree, file.path(output_dir, "yield_by_exact_connectivity.csv"), row.names = FALSE)

cat("PASS: citation-prioritisation yield analysis completed.\n")

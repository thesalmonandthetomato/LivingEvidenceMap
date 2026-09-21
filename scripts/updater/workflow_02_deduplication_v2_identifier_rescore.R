#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(data.table)
  library(jsonlite)
  library(stringi)
})

`%||%` <- function(x, y) if (is.null(x)) y else x

args <- commandArgs(trailingOnly = TRUE)
arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("Missing value after %s", flag), call. = FALSE)
  args[[i + 1L]]
}

input_dir <- arg("--input-dir")
output_dir <- arg("--output-dir")
source_run_id <- arg("--source-run-id", "35585544686")

if (is.null(input_dir) || is.null(output_dir)) {
  stop("Required: --input-dir --output-dir", call. = FALSE)
}
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

timestamp_utc <- function() format(Sys.time(), tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ")
progress <- function(stage, completed = NULL, total = NULL, extra = NULL) {
  msg <- paste0("[", timestamp_utc(), "] ", stage)
  if (!is.null(completed)) {
    msg <- paste0(msg, ": ", completed)
    if (!is.null(total)) msg <- paste0(msg, " / ", total)
  }
  if (!is.null(extra) && nzchar(extra)) msg <- paste0(msg, " | ", extra)
  cat(msg, "\n")
  flush.console()
}
checkpoint <- function(stage, completed = NULL, total = NULL, extra = list()) {
  x <- c(list(
    workflow = "02_deduplication_v2_identifier_rescore",
    updated_at = timestamp_utc(),
    stage = stage,
    completed = completed,
    total = total,
    source_benchmark_run_id = source_run_id
  ), extra)
  writeLines(
    toJSON(x, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null"),
    file.path(output_dir, "checkpoint_progress.json")
  )
}

scored_path <- file.path(input_dir, "scored_sample.csv")
if (!file.exists(scored_path)) {
  hits <- list.files(input_dir, pattern = "^scored_sample\\.csv$", recursive = TRUE, full.names = TRUE)
  if (!length(hits)) stop("scored_sample.csv not found in benchmark artefact", call. = FALSE)
  scored_path <- hits[[1L]]
}

progress("reading saved scored benchmark sample")
x <- fread(scored_path, na.strings = c("", "NA"))
if (!nrow(x)) stop("Saved scored sample is empty", call. = FALSE)
required <- c("title_i","title_j","classification","rule","record_i","record_j")
missing <- setdiff(required, names(x))
if (length(missing)) stop(sprintf("Missing required columns: %s", paste(missing, collapse = ", ")), call. = FALSE)
progress("saved sample loaded", nrow(x), nrow(x))
checkpoint("sample_loaded", nrow(x), nrow(x))

normalise_visible_title <- function(s) {
  if (is.na(s) || !nzchar(trimws(s))) return(NA_character_)
  s <- stri_trans_nfkc(s)
  stri_trans_tolower(s)
}

canonical_label <- function(x) {
  x <- tolower(x)
  map <- c(
    "pt" = "part", "part" = "part",
    "study" = "study",
    "experiment" = "experiment",
    "trial" = "trial",
    "report" = "report",
    "no" = "number", "number" = "number",
    "interview" = "interview",
    "episode" = "episode",
    "chapter" = "chapter",
    "section" = "section",
    "series" = "series",
    "vol" = "volume", "volume" = "volume",
    "issue" = "issue",
    "supplement" = "supplement",
    "appendix" = "appendix",
    "phase" = "phase"
  )
  unname(map[x])
}

labelled_ids <- function(s) {
  s <- normalise_visible_title(s)
  if (is.na(s)) return(list())
  pattern <- paste0(
    "(?i)(?<!\\p{L})",
    "(part|pt|study|experiment|trial|report|no|number|interview|episode|chapter|section|series|vol|volume|issue|supplement|appendix|phase)",
    "\\s*[\\.:#-]?\\s*",
    "([0-9]+(?:\\.[0-9]+)?|[ivxlcdm]+)",
    "(?!\\p{L})"
  )
  m <- stri_match_all_regex(s, pattern)[[1L]]
  if (is.matrix(m) && nrow(m) && !all(is.na(m))) {
    out <- list()
    for (i in seq_len(nrow(m))) {
      lab <- canonical_label(m[i,2])
      val <- toupper(m[i,3])
      if (is.na(lab) || is.na(val)) next
      out[[lab]] <- sort(unique(c(out[[lab]] %||% character(), val)))
    }
    return(out)
  }
  list()
}

years_in_title <- function(s) {
  s <- normalise_visible_title(s)
  if (is.na(s)) return(character())
  m <- stri_extract_all_regex(s, "(?<![0-9])(?:18|19|20|21)[0-9]{2}(?![0-9])")[[1L]]
  sort(unique(m[!is.na(m)]))
}

roman_ids <- function(s) {
  s <- normalise_visible_title(s)
  if (is.na(s)) return(character())
  # Exclude standalone I because it is frequently a pronoun; labelled Phase I/Part I
  # is already captured by labelled_ids().
  m <- stri_extract_all_regex(s, "(?i)(?<!\\p{L})(?:ii|iii|iv|v|vi|vii|viii|ix|x|xi|xii|xiii|xiv|xv|xvi|xvii|xviii|xix|xx)(?!\\p{L})")[[1L]]
  sort(unique(toupper(m[!is.na(m)])))
}

generic_numbers <- function(s) {
  s <- normalise_visible_title(s)
  if (is.na(s)) return(character())
  m <- stri_extract_all_regex(s, "(?<![\\p{L}0-9])[0-9]+(?:\\.[0-9]+)?(?![\\p{L}0-9])")[[1L]]
  sort(unique(m[!is.na(m)]))
}

set_differs <- function(a, b) {
  length(a) > 0L && length(b) > 0L && !identical(sort(unique(a)), sort(unique(b)))
}

identifier_conflict <- function(a, b) {
  reasons <- character()

  la <- labelled_ids(a)
  lb <- labelled_ids(b)
  common_labels <- intersect(names(la), names(lb))
  if (length(common_labels)) {
    for (lab in common_labels) {
      if (set_differs(la[[lab]], lb[[lab]])) {
        reasons <- c(reasons, paste0("label:", lab, "=", paste(la[[lab]], collapse = ","), " vs ", paste(lb[[lab]], collapse = ",")))
      }
    }
  }

  ya <- years_in_title(a); yb <- years_in_title(b)
  if (set_differs(ya, yb)) {
    reasons <- c(reasons, paste0("year=", paste(ya, collapse = ","), " vs ", paste(yb, collapse = ",")))
  }

  ra <- roman_ids(a); rb <- roman_ids(b)
  if (set_differs(ra, rb)) {
    reasons <- c(reasons, paste0("roman=", paste(ra, collapse = ","), " vs ", paste(rb, collapse = ",")))
  }

  na <- generic_numbers(a); nb <- generic_numbers(b)
  if (set_differs(na, nb)) {
    reasons <- c(reasons, paste0("numeric=", paste(na, collapse = ","), " vs ", paste(nb, collapse = ",")))
  }

  list(
    conflict = length(reasons) > 0L,
    reasons = paste(unique(reasons), collapse = "; ")
  )
}

# Regression checks from the observed false-positive patterns.
stopifnot(identifier_conflict("Mike and Drenda Bayliss Interview 08", "Mike and Drenda Bayliss Interview 03")$conflict)
stopifnot(identifier_conflict("Annual Report No. 60, 2015", "Annual Report No. 61, 2016")$conflict)
stopifnot(identifier_conflict("Studies on Viral Diseases of Japanese Fishes-III", "Studies on Viral Diseases of Japanese Fishes-V")$conflict)
stopifnot(identifier_conflict("Experiment Part 1", "Experiment Part 2")$conflict)
stopifnot(!identifier_conflict("A 3-dimensional positioning study", "A 3-dimensional positioning study")$conflict)

weak_auto_rules <- c(
  "title_containment_strong_abstract",
  "title_similarity_0.97_strong_abstract",
  "title_similarity_0.95_exact_author_year"
)

x[, identifier_conflict := FALSE]
x[, identifier_conflict_reason := ""]
x[, rescored_classification := classification]
x[, rescored_rule := rule]

eligible <- which(x$classification == "duplicate" & x$rule %in% weak_auto_rules)
progress("checking structured title identifiers", 0L, length(eligible))

for (n in seq_along(eligible)) {
  i <- eligible[[n]]
  z <- identifier_conflict(x$title_i[[i]], x$title_j[[i]])
  if (isTRUE(z$conflict)) {
    x$identifier_conflict[[i]] <- TRUE
    x$identifier_conflict_reason[[i]] <- z$reasons
    x$rescored_classification[[i]] <- "review"
    x$rescored_rule[[i]] <- "structured_title_identifier_conflict"
  }
  if (n == 1L || n %% 25L == 0L || n == length(eligible)) {
    progress("structured title identifiers checked", n, length(eligible))
    checkpoint("identifier_check", n, length(eligible), list(changed_so_far = sum(x$identifier_conflict)))
  }
}

x[, decision_changed := classification != rescored_classification | rule != rescored_rule]

fwrite(x, file.path(output_dir, "rescored_sample.csv"))
fwrite(x[decision_changed == TRUE], file.path(output_dir, "changed_decisions.csv"))
fwrite(
  x[classification == "duplicate" & rule %in% weak_auto_rules,
    .(record_i, record_j, title_i, title_j, original_rule = rule,
      identifier_conflict, identifier_conflict_reason,
      rescored_classification, rescored_rule)],
  file.path(output_dir, "weak_rule_audit.csv")
)

changed_by_rule <- x[decision_changed == TRUE, .N, by = rule][order(rule)]
remaining_auto_by_rule <- x[rescored_classification == "duplicate", .N, by = rescored_rule][order(rescored_rule)]

summary <- list(
  workflow = "02_deduplication_v2_identifier_rescore",
  status = "success",
  source_benchmark_run_id = source_run_id,
  sample_n = nrow(x),
  weak_auto_pairs_checked = length(eligible),
  decisions_changed_to_review = sum(x$decision_changed),
  original_classification_counts = as.list(table(x$classification)),
  rescored_classification_counts = as.list(table(x$rescored_classification)),
  changed_by_original_rule = if (nrow(changed_by_rule)) split(changed_by_rule$N, changed_by_rule$rule) else list(),
  remaining_automatic_by_rule = if (nrow(remaining_auto_by_rule)) split(remaining_auto_by_rule$N, remaining_auto_by_rule$rescored_rule) else list(),
  historic_human_adjudications_loaded = FALSE,
  candidate_generation_repeated = FALSE,
  source_candidate_artifact_reused = TRUE
)
writeLines(
  toJSON(summary, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null"),
  file.path(output_dir, "summary.json")
)
progress("rescore complete", nrow(x), nrow(x), paste("decisions changed:", sum(x$decision_changed)))
checkpoint("complete", nrow(x), nrow(x), list(status = "success", decisions_changed = sum(x$decision_changed)))
cat(toJSON(summary, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null"), "\n")

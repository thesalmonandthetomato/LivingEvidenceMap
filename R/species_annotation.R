# Run deterministic species annotation for an explicitly supplied target.
# File selection belongs to the target configuration, not this function.

annotate_species <- function(records, species_dictionary, progress = TRUE) {
  required <- c("record_sequence", "record_id", "title", "abstract")
  missing <- setdiff(required, names(records))
  if (length(missing) > 0L) stop("Records are missing: ", paste(missing, collapse = ", "), call. = FALSE)
  if (!is.data.frame(species_dictionary)) stop("species_dictionary must be a data frame.", call. = FALSE)

  n <- nrow(records)
  if (isTRUE(progress)) message(sprintf("Species annotation: preparing %d records.", n))

  annotate_one <- function(i) {
    mentions <- detect_species_mentions(records$title[[i]], records$abstract[[i]], species_dictionary)
    mentions <- filter_species_mentions(mentions, records$title[[i]], records$abstract[[i]])
    assignment <- assign_farmed_species(mentions[mentions$mention_eligible %in% TRUE, , drop = FALSE])
    if (nrow(mentions)) { mentions$record_sequence <- records$record_sequence[[i]]; mentions$record_id <- records$record_id[[i]] }
    assignment$record_sequence <- records$record_sequence[[i]]
    assignment$record_id <- records$record_id[[i]]
    list(mentions = mentions, assignment = assignment)
  }

  progress_step <- max(1L, min(100L, floor(max(1L, n) / 20L)))
  results <- lapply(seq_len(n), function(i) {
    result <- tryCatch(annotate_one(i), error = function(e) e)
    if (isTRUE(progress) && (i == 1L || i %% progress_step == 0L || i == n)) {
      message(sprintf("Species annotation: record %d/%d (%.0f%%).", i, n, 100 * i / max(1, n)))
    }
    result
  })

  if (isTRUE(progress)) message("Species annotation: record-level annotation complete; assembling outputs.")
  failed <- vapply(results, inherits, logical(1), what = "error")
  ok <- results[!failed]
  mentions <- if (length(ok)) do.call(rbind, lapply(ok, `[[`, "mentions")) else data.frame()
  assignments <- if (length(ok)) do.call(rbind, lapply(ok, `[[`, "assignment")) else data.frame()
  failures <- if (any(failed)) {
    data.frame(record_sequence = records$record_sequence[failed], record_id = records$record_id[failed], title = records$title[failed], error = vapply(results[failed], conditionMessage, character(1)), stringsAsFactors = FALSE)
  } else {
    data.frame(record_sequence = integer(), record_id = character(), title = character(), error = character(), stringsAsFactors = FALSE)
  }
  if (isTRUE(progress)) message(sprintf("Species annotation: complete (%d mentions, %d assignments, %d failures).", nrow(mentions), nrow(assignments), nrow(failures)))
  list(species_mentions = mentions, species_assignments = assignments, failures = failures)
}

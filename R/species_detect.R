# Detect species mentions in titles and abstracts.
#
# Validated rule: match dictionary terms case-insensitively on token boundaries
# and retain the longest term when dictionary matches overlap.

detect_species_mentions <- function(title = NA_character_, abstract = NA_character_, dictionary) {
  required <- c("species_id", "preferred_name", "scientific_name", "synonym", "synonym_type", "is_farmed_candidate", "default_group")
  missing <- setdiff(required, names(dictionary))
  if (length(missing) > 0L) stop("Species dictionary is missing: ", paste(missing, collapse = ", "), call. = FALSE)
  if (length(title) != 1L || length(abstract) != 1L) stop("title and abstract must each contain exactly one value.", call. = FALSE)

  empty <- data.frame(
    species_id = character(), preferred_name = character(), scientific_name = character(),
    matched_term = character(), synonym_type = character(), source = character(),
    match_start = integer(), match_end = integer(), is_farmed_candidate = logical(),
    default_group = character(), stringsAsFactors = FALSE
  )

  escape_regex <- function(x) gsub("([][{}()+*^$|\\\\?.])", "\\\\\\1", x, perl = TRUE)

  detect_in_text <- function(text, source) {
    if (is.na(text) || !nzchar(trimws(text))) return(empty)
    hits <- list(); k <- 0L
    for (i in seq_len(nrow(dictionary))) {
      term <- dictionary$synonym[[i]]
      if (is.na(term) || !nzchar(trimws(term))) next
      pattern <- paste0("(?<![[:alnum:]_])", escape_regex(trimws(term)), "(?![[:alnum:]_])")
      starts <- gregexpr(pattern, text, ignore.case = TRUE, perl = TRUE)[[1L]]
      if (starts[[1L]] == -1L) next
      lengths <- attr(starts, "match.length")
      for (j in seq_along(starts)) {
        k <- k + 1L; start <- starts[[j]]; len <- lengths[[j]]
        hits[[k]] <- data.frame(
          species_id = dictionary$species_id[[i]], preferred_name = dictionary$preferred_name[[i]],
          scientific_name = dictionary$scientific_name[[i]], matched_term = substr(text, start, start + len - 1L),
          synonym_type = dictionary$synonym_type[[i]], source = source, match_start = start,
          match_end = start + len - 1L, is_farmed_candidate = as.logical(dictionary$is_farmed_candidate[[i]]),
          default_group = dictionary$default_group[[i]], stringsAsFactors = FALSE
        )
      }
    }
    if (!length(hits)) return(empty)
    out <- do.call(rbind, hits)
    out$term_length <- nchar(out$matched_term)
    out <- out[order(out$match_start, -out$term_length, out$species_id), , drop = FALSE]

    # Resolve overlapping dictionary hits by retaining the longest span.
    keep <- rep(TRUE, nrow(out))
    for (i in seq_len(nrow(out))) {
      if (!keep[[i]]) next
      overlap <- which(seq_len(nrow(out)) != i & out$match_start <= out$match_end[[i]] & out$match_end >= out$match_start[[i]] & out$term_length <= out$term_length[[i]])
      keep[overlap] <- FALSE
      keep[[i]] <- TRUE
    }
    out <- unique(out[keep, setdiff(names(out), "term_length"), drop = FALSE])
    rownames(out) <- NULL
    out
  }

  out <- rbind(detect_in_text(title, "title"), detect_in_text(abstract, "abstract"))
  rownames(out) <- NULL
  out
}

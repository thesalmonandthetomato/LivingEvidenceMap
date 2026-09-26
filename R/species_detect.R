# Detect species mentions in titles and abstracts.
#
# Match dictionary terms case-insensitively on token boundaries.
# Lexical separators tolerate whitespace and hyphen variants. Overlap handling
# never allows a generic salmon phrase to erase an explicitly named species.

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

  lexical_pattern <- function(term, synonym_type) {
    term <- trimws(term)
    raw_parts <- strsplit(term, "[[:space:]-]+", perl = TRUE)[[1L]]
    raw_parts <- raw_parts[nzchar(raw_parts)]
    if (!length(raw_parts)) return("")
    abbreviation_first <- identical(tolower(as.character(synonym_type)), "abbreviation") &&
      length(raw_parts) >= 2L && grepl("^[[:alpha:]]\\.$", raw_parts[[1L]], perl = TRUE)
    parts <- vapply(raw_parts, escape_regex, character(1))

    # Genus abbreviations are often supplied without the full stop in older
    # bibliographic metadata (e.g. "S salar", "O mykiss").
    if (abbreviation_first) {
      genus_letter <- sub("\\.$", "", raw_parts[[1L]], perl = TRUE)
      parts[[1L]] <- paste0(escape_regex(genus_letter), "\\.?" )
    }

    # Treat ordinary whitespace and hyphen variants as equivalent lexical
    # separators. This captures forms such as RAINBOW-TROUT and SALMO-GAIRDNERI.
    separator <- "(?:[[:space:]\\u00A0\\u00AD\\-\\u2010\\u2011\\u2012\\u2013\\u2014]+)"
    paste(parts, collapse = separator)
  }

  detect_in_text <- function(text, source) {
    if (is.na(text) || !nzchar(trimws(text))) return(empty)
    hits <- list(); k <- 0L
    for (i in seq_len(nrow(dictionary))) {
      term <- dictionary$synonym[[i]]
      if (is.na(term) || !nzchar(trimws(term))) next
      core_pattern <- lexical_pattern(term, dictionary$synonym_type[[i]])
      if (!nzchar(core_pattern)) next
      pattern <- paste0("(?<![[:alnum:]_])", core_pattern, "(?![[:alnum:]_])")
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

    # Resolve overlaps without allowing a generic salmon phrase to erase an
    # explicitly named eligible species. For the same species ID, retain the
    # longest lexical match. Across different IDs, a specific species beats
    # UNSPEC_SALMON; otherwise retain both IDs.
    keep <- rep(TRUE, nrow(out))
    for (i in seq_len(nrow(out))) {
      if (!keep[[i]]) next
      for (j in seq_len(nrow(out))) {
        if (i == j || !keep[[j]]) next
        overlaps <- out$match_start[[j]] <= out$match_end[[i]] &&
          out$match_end[[j]] >= out$match_start[[i]]
        if (!overlaps) next

        same_id <- identical(out$species_id[[i]], out$species_id[[j]])
        i_generic <- identical(out$species_id[[i]], "UNSPEC_SALMON")
        j_generic <- identical(out$species_id[[j]], "UNSPEC_SALMON")

        if (same_id) {
          if (out$term_length[[j]] > out$term_length[[i]]) {
            keep[[i]] <- FALSE
            break
          }
          if (out$term_length[[j]] <= out$term_length[[i]]) keep[[j]] <- FALSE
        } else if (i_generic && !j_generic) {
          keep[[i]] <- FALSE
          break
        } else if (!i_generic && j_generic) {
          keep[[j]] <- FALSE
        }
      }
    }
    out <- unique(out[keep, setdiff(names(out), "term_length"), drop = FALSE])
    rownames(out) <- NULL
    out
  }

  out <- rbind(detect_in_text(title, "title"), detect_in_text(abstract, "abstract"))
  rownames(out) <- NULL
  out
}

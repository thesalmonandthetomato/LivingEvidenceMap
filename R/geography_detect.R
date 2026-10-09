# Detect geography mentions in a declared corpus.
# The detector is target-independent: callers provide records and gazetteer.
#
# Performance note: use moderately sized compiled regex chunks. A single
# 15k-term PCRE pattern exceeds PCRE's pattern-size limit; the old one-regex-
# per-term implementation is also prohibitively slow.

detect_geography_mentions <- function(records, gazetteer, progress = TRUE) {
  required_records <- c("record_sequence", "record_id", "title", "abstract")
  missing_records <- setdiff(required_records, names(records))
  if (length(missing_records) > 0L) stop("Records are missing: ", paste(missing_records, collapse = ", "), call. = FALSE)

  required_gazetteer <- c("matched_place", "normalised_match", "country_name", "iso3c", "region_name")
  missing_gazetteer <- setdiff(required_gazetteer, names(gazetteer))
  if (length(missing_gazetteer) > 0L) stop("Gazetteer is missing: ", paste(missing_gazetteer, collapse = ", "), call. = FALSE)
  if (anyDuplicated(records$record_id) || anyDuplicated(records$record_sequence)) stop("Records must contain unique record_id and record_sequence values.", call. = FALSE)

  n <- nrow(records)
  message(sprintf("Geography detection: preparing %d records against %d gazetteer terms.", n, nrow(gazetteer)))

  escape_regex <- function(x) gsub("([][{}()+*^$|\\\\?.])", "\\\\\\1", x, perl = TRUE)
  extract_context <- function(text, start, end, window = 100L) {
    stringr::str_squish(substr(text, max(1L, start - window), min(nchar(text), end + window)))
  }
  empty <- data.frame(record_sequence=integer(), record_id=character(), source=character(), matched_text=character(), matched_place=character(), normalised_match=character(), country_name=character(), iso3c=character(), region_name=character(), match_start=integer(), match_end=integer(), context=character(), stringsAsFactors=FALSE)

  gazetteer_work <- gazetteer
  gazetteer_work$matched_place <- trimws(as.character(gazetteer_work$matched_place))
  gazetteer_work <- gazetteer_work[!is.na(gazetteer_work$matched_place) & nzchar(gazetteer_work$matched_place), , drop = FALSE]
  gazetteer_work$normalised_match_key <- tolower(gazetteer_work$matched_place)
  matcher_terms <- unique(gazetteer_work$matched_place)
  matcher_terms <- matcher_terms[order(nchar(matcher_terms), matcher_terms, decreasing = TRUE)]

  # Keep each PCRE pattern comfortably below the engine's pattern-size limit.
  # 500 alternatives gives ~32 compiled matchers for the current 15,877-term
  # gazetteer: vastly fewer scans than the original one-regex-per-term design,
  # without risking another oversized-pattern failure.
  chunk_size <- 500L
  term_chunks <- split(matcher_terms, ceiling(seq_along(matcher_terms) / chunk_size))
  message(sprintf("Geography detection: compiling %d matcher chunks of up to %d terms.", length(term_chunks), chunk_size))
  compiled_patterns <- lapply(term_chunks, function(terms) {
    paste0("(?<![[:alnum:]_])(?:", paste(vapply(terms, escape_regex, character(1L)), collapse = "|"), ")(?![[:alnum:]_])")
  })
  message("Geography detection: matcher chunks compiled; beginning record scan.")

  mappings <- split(gazetteer_work, gazetteer_work$normalised_match_key)

  detect_field <- function(text, record_sequence, record_id, source) {
    if (is.na(text) || !nzchar(trimws(text))) return(empty)
    hits <- list(); k <- 0L

    for (chunk_i in seq_along(compiled_patterns)) {
      starts <- gregexpr(compiled_patterns[[chunk_i]], text, ignore.case = TRUE, perl = TRUE)[[1L]]
      if (starts[[1L]] == -1L) next
      lengths <- attr(starts, "match.length")
      matched_texts <- mapply(substr, list(text), starts, starts + lengths - 1L, USE.NAMES = FALSE)

      for (j in seq_along(matched_texts)) {
        matched <- matched_texts[[j]]
        mapping <- mappings[[tolower(matched)]]
        if (is.null(mapping) || !nrow(mapping)) next
        start <- starts[[j]]
        len <- lengths[[j]]
        end <- start + len - 1L
        context <- extract_context(text, start, end)
        for (m in seq_len(nrow(mapping))) {
          k <- k + 1L
          hits[[k]] <- data.frame(
            record_sequence=record_sequence, record_id=record_id, source=source,
            matched_text=matched, matched_place=as.character(mapping$matched_place[[m]]),
            normalised_match=as.character(mapping$normalised_match[[m]]),
            country_name=as.character(mapping$country_name[[m]]),
            iso3c=as.character(mapping$iso3c[[m]]),
            region_name=as.character(mapping$region_name[[m]]),
            match_start=start, match_end=end, context=context,
            stringsAsFactors=FALSE
          )
        }
      }
    }

    if (!k) return(empty)
    out <- do.call(rbind, hits[seq_len(k)])
    out$term_length <- nchar(out$matched_text)
    out <- out[order(out$match_start, -out$term_length, out$matched_place),,drop=FALSE]
    keep <- rep(TRUE,nrow(out))
    for (i in seq_len(nrow(out))) {
      if (!keep[[i]]) next
      overlap <- which(seq_len(nrow(out)) != i & out$match_start <= out$match_end[[i]] & out$match_end >= out$match_start[[i]] & out$term_length <= out$term_length[[i]])
      keep[overlap] <- FALSE
    }
    out <- out[keep,setdiff(names(out),"term_length"),drop=FALSE]
    rownames(out) <- NULL
    out
  }

  progress_step <- max(1L, min(100L, floor(max(1L, n) / 20L)))
  result <- lapply(seq_len(n), function(i) {
    out <- rbind(
      detect_field(records$title[[i]],records$record_sequence[[i]],records$record_id[[i]],"title"),
      detect_field(records$abstract[[i]],records$record_sequence[[i]],records$record_id[[i]],"abstract")
    )
    if (isTRUE(progress) && (i == 1L || i %% progress_step == 0L || i == n)) {
      message(sprintf("Geography detection: record %d/%d (%.0f%%).", i, n, 100 * i / max(1, n)))
    }
    out
  })
  message("Geography detection: record-level detection complete; assembling mentions.")
  result <- do.call(rbind, result)
  if (is.null(result) || !nrow(result)) {
    message("Geography detection: complete; no mentions found.")
    return(empty)
  }
  rownames(result) <- NULL
  message(sprintf("Geography detection: complete (%d mentions).", nrow(result)))
  result
}

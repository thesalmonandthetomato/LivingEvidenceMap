# Shared Workflow 06 geography grounding and auto-validation helpers.
# Raw model-evidence grounding is kept separate from substantive automated
# corroboration of the geography assignment.

normalise_geography_grounding_text <- function(z) {
  z <- as.character(z); z[is.na(z)] <- ""
  z <- gsub("\\\\n|\\\\r|\\\\t", " ", z, perl = TRUE)
  z <- gsub("&nbsp;|&#160;|&#xA0;", " ", z, ignore.case = TRUE, perl = TRUE)
  z <- gsub("&amp;", "&", z, ignore.case = TRUE, fixed = FALSE)
  z <- gsub("<[^>]+>", " ", z, perl = TRUE)
  z <- gsub("[\u00AD\u200B\uFEFF]", "", z, perl = TRUE)
  z <- gsub("[\u2018\u2019]", "'", z, perl = TRUE)
  z <- gsub("[\u201C\u201D]", '"', z, perl = TRUE)
  z <- gsub("[\u2010\u2011\u2012\u2013\u2014]", "-", z, perl = TRUE)
  z <- gsub("[[:punct:]]+", " ", z, perl = TRUE)
  z <- trimws(gsub("[[:space:]]+", " ", z, perl = TRUE))
  tolower(z)
}

geography_evidence_is_grounded <- function(evidence, title, abstract) {
  e_raw <- as.character(evidence)
  if (is.na(e_raw) || !nzchar(trimws(e_raw))) return(FALSE)
  txt <- normalise_geography_grounding_text(paste(title, abstract, sep = " "))
  e <- normalise_geography_grounding_text(e_raw)

  if (grepl(e, txt, fixed = TRUE)) return(TRUE)

  evidence_tokens <- strsplit(e, " ", fixed = TRUE)[[1L]]
  source_tokens <- strsplit(txt, " ", fixed = TRUE)[[1L]]
  evidence_tokens <- evidence_tokens[nzchar(evidence_tokens)]
  if (length(evidence_tokens) >= 4L) {
    j <- 1L
    for (tok in source_tokens) {
      if (j <= length(evidence_tokens) && identical(tok, evidence_tokens[[j]])) j <- j + 1L
    }
    if (j > length(evidence_tokens)) return(TRUE)
  }

  raw <- gsub("\u2026", "...", e_raw, fixed = TRUE)
  if (!grepl("...", raw, fixed = TRUE)) return(FALSE)
  parts <- strsplit(raw, "...", fixed = TRUE)[[1L]]
  parts <- vapply(parts, normalise_geography_grounding_text, character(1))
  parts <- trimws(gsub("^[. ]+|[. ]+$", "", parts, perl = TRUE))
  parts <- parts[nzchar(parts) & nchar(parts) >= 4L]
  if (length(parts) < 2L) return(FALSE)

  pos <- 1L
  for (part in parts) {
    remainder <- substr(txt, pos, nchar(txt))
    hit <- regexpr(part, remainder, fixed = TRUE)[[1L]]
    if (hit < 1L) return(FALSE)
    pos <- pos + hit - 1L + nchar(part)
  }
  TRUE
}

normalise_iso3_set <- function(x) {
  x <- as.character(x); x[is.na(x)] <- ""
  v <- trimws(unlist(strsplit(x, ";", fixed = TRUE), use.names = FALSE))
  v <- toupper(v[nzchar(v)])
  sort(unique(v))
}

strict_country_cue_terms <- function(iso3c, gazetteer) {
  allowed_types <- c("country", "country name", "country variant",
                     "country abbreviation", "demonym")
  g <- gazetteer[
    toupper(as.character(gazetteer$iso3c)) == toupper(as.character(iso3c)) &
      tolower(trimws(as.character(gazetteer$match_type))) %in% allowed_types &
      !(toupper(as.character(gazetteer$ambiguous)) %in% "TRUE"),
    , drop = FALSE
  ]
  if (!nrow(g)) return(character())
  unique(trimws(as.character(g$matched_place[nzchar(trimws(as.character(g$matched_place)))])))
}

strict_country_cue_present <- function(iso3c, title, abstract, gazetteer) {
  terms <- strict_country_cue_terms(iso3c, gazetteer)
  if (!length(terms)) return(FALSE)
  txt <- normalise_geography_grounding_text(paste(title, abstract, sep = " "))
  padded <- paste0(" ", txt, " ")

  any(vapply(terms, function(term) {
    mt <- gazetteer$match_type[
      toupper(as.character(gazetteer$iso3c)) == toupper(as.character(iso3c)) &
      tolower(as.character(gazetteer$matched_place)) == tolower(term)
    ][1L]
    cue <- normalise_geography_grounding_text(term)
    hit <- nzchar(cue) && grepl(paste0(" ", cue, " "), padded, fixed = TRUE)
    if (isTRUE(hit)) return(TRUE)

    # Standard punctuated abbreviations such as U.K. / U.S. / U.S.A. are
    # allowed to match their compact token forms UK / US / USA.
    if (!is.na(mt) && tolower(trimws(mt)) == "country abbreviation") {
      compact <- gsub("[^[:alnum:]]", "", tolower(term), perl = TRUE)
      if (nchar(compact) >= 2L) {
        tokens <- unlist(strsplit(txt, " ", fixed = TRUE), use.names = FALSE)
        return(compact %in% gsub("[^[:alnum:]]", "", tokens, perl = TRUE))
      }
    }
    FALSE
  }, logical(1)))
}

strict_country_cues_support_set <- function(iso3c_set, title, abstract, gazetteer) {
  iso <- normalise_iso3_set(iso3c_set)
  if (!length(iso)) return(FALSE)
  all(vapply(iso, strict_country_cue_present, logical(1),
             title = title, abstract = abstract, gazetteer = gazetteer))
}

geography_auto_validation <- function(status, llm_failed, luna_iso3c,
                                      deterministic_iso3c,
                                      evidence_all_grounded,
                                      title, abstract, gazetteer) {
  status <- as.character(status)
  if (isTRUE(llm_failed)) return(list(valid = FALSE, basis = "model_failure"))
  if (identical(status, "UNRESOLVED")) return(list(valid = FALSE, basis = "unresolved"))
  if (identical(status, "NONE")) return(list(valid = TRUE, basis = "model_none"))
  if (!identical(status, "RESOLVED")) return(list(valid = FALSE, basis = "invalid_status"))
  if (isTRUE(evidence_all_grounded)) return(list(valid = TRUE, basis = "evidence_grounded"))

  luna <- normalise_iso3_set(luna_iso3c)
  det <- normalise_iso3_set(deterministic_iso3c)
  if (length(luna) && identical(luna, det)) {
    return(list(valid = TRUE, basis = "deterministic_exact_agreement"))
  }
  if (strict_country_cues_support_set(luna_iso3c, title, abstract, gazetteer)) {
    return(list(valid = TRUE, basis = "explicit_country_cues"))
  }
  list(valid = FALSE, basis = "unvalidated")
}

# Filter species mentions before farmed-species assignment.
#
# Validated rules:
# - a generic salmon mention is not assigned to a farmed salmon group when a
#   nearby named non-target Salmo species supplies the apparent identity;
# - explicit farming phrases (e.g. salmon farm) override that filter.

filter_species_mentions <- function(mentions, title, abstract, non_target_context_chars = 120L) {
  required <- c("species_id", "preferred_name", "scientific_name", "matched_term", "synonym_type", "source", "match_start", "match_end", "is_farmed_candidate")
  missing <- setdiff(required, names(mentions))
  if (length(missing) > 0L) stop("Species mentions are missing: ", paste(missing, collapse = ", "), call. = FALSE)
  if (nrow(mentions) == 0L) {
    mentions$mention_eligible <- logical(0)
    mentions$filter_reason <- character(0)
    return(mentions)
  }

  title <- ifelse(is.na(title), "", as.character(title)); abstract <- ifelse(is.na(abstract), "", as.character(abstract))
  text_for <- function(source) if (tolower(source) == "title") title else if (tolower(source) == "abstract") abstract else ""
  is_generic <- function(i) {
    name <- tolower(ifelse(is.na(mentions$preferred_name[[i]]), "", mentions$preferred_name[[i]]))
    id <- tolower(ifelse(is.na(mentions$species_id[[i]]), "", mentions$species_id[[i]]))
    name == "unspecified farmed salmon" || grepl("unspecified.*salmon|generic.*salmon", id, perl = TRUE)
  }
  is_non_target_salmo <- function(i) {
    sci <- ifelse(is.na(mentions$scientific_name[[i]]), "", mentions$scientific_name[[i]])
    grepl("^Salmo\\s+[[:alpha:]-]+$", sci, ignore.case = TRUE, perl = TRUE) && !isTRUE(mentions$is_farmed_candidate[[i]])
  }

  mentions$mention_eligible <- TRUE
  mentions$filter_reason <- NA_character_

  for (i in seq_len(nrow(mentions))) {
    if (!is_generic(i)) next
    explicit <- tolower(mentions$matched_term[[i]]) %in% c("salmon farm", "salmon farms", "farmed salmon", "salmon aquaculture", "salmon cage", "salmon cages", "salmon pen", "salmon pens")
    if (explicit) next

    candidates <- which(mentions$source == mentions$source[[i]] & vapply(seq_len(nrow(mentions)), is_non_target_salmo, logical(1)))
    if (!length(candidates)) next
    distances <- abs(rowMeans(cbind(mentions$match_start[candidates], mentions$match_end[candidates])) - mean(c(mentions$match_start[[i]], mentions$match_end[[i]])))
    if (any(distances <= non_target_context_chars)) {
      mentions$mention_eligible[[i]] <- FALSE
      mentions$filter_reason[[i]] <- "Generic salmon mention located near a named non-target Salmo species"
    }
  }
  mentions
}

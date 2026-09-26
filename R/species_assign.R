# Assign detected species to farmed-species categories.
#
# The established rule is retained: if a specific farmed salmon species is
# present, the generic UNSPEC_SALMON assignment is suppressed. Multiple
# eligible farmed species are retained as co-primary rather than arbitrarily
# selecting one.

assign_farmed_species <- function(species_mentions) {
  required <- c("species_id", "preferred_name", "is_farmed_candidate")
  missing <- setdiff(required, names(species_mentions))
  if (length(missing) > 0L) stop("Species mentions are missing: ", paste(missing, collapse = ", "), call. = FALSE)

  none <- data.frame(
    farmed_species_id = NA_character_, farmed_species = NA_character_,
    assignment_role = "none", review_required = FALSE,
    assignment_reason = "No eligible species term detected",
    non_target_species = NA_character_, stringsAsFactors = FALSE
  )
  if (nrow(species_mentions) == 0L) return(none)

  species_mentions$is_farmed_candidate <- as.logical(species_mentions$is_farmed_candidate)
  unique_species <- unique(species_mentions[, c("species_id", "preferred_name", "is_farmed_candidate"), drop = FALSE])
  farmed <- unique_species[unique_species$is_farmed_candidate %in% TRUE, , drop = FALSE]
  non_target <- unique_species[unique_species$is_farmed_candidate %in% FALSE, , drop = FALSE]
  non_target_names <- if (nrow(non_target)) paste(sort(unique(non_target$preferred_name)), collapse = "; ") else NA_character_

  specific <- nrow(farmed) > 0L && any(farmed$species_id != "UNSPEC_SALMON")
  if (specific) farmed <- farmed[farmed$species_id != "UNSPEC_SALMON", , drop = FALSE]

  if (nrow(farmed) == 0L) {
    none$non_target_species <- non_target_names
    if (nrow(non_target) > 0L) none$assignment_reason <- "Only non-target species detected"
    return(none)
  }

  role <- if (nrow(farmed) == 1L) "primary" else "co-primary"
  reason <- if (nrow(farmed) == 1L) "One eligible farmed species detected" else paste0(nrow(farmed), " eligible farmed species detected; none treated as primary")
  out <- data.frame(
    farmed_species_id = farmed$species_id,
    farmed_species = farmed$preferred_name,
    assignment_role = role,
    review_required = FALSE,
    assignment_reason = reason,
    non_target_species = non_target_names,
    stringsAsFactors = FALSE
  )
  out[order(out$farmed_species), , drop = FALSE]
}

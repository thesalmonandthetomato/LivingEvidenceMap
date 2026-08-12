# Target configuration helpers
#
# A target is an explicit, named processing unit. Pipeline stages must receive
# a target rather than discovering an input corpus from an output directory.

read_target <- function(path) {
  stopifnot(length(path) == 1L, file.exists(path))

  target <- yaml::read_yaml(path)

  if (!is.list(target) || is.null(target$target$name)) {
    stop("Target configuration must contain target$name.", call. = FALSE)
  }

  required <- c("corpus", "output_dir")
  missing <- required[vapply(required, function(x) is.null(target$target[[x]]), logical(1))]

  if (length(missing) > 0L) {
    stop("Target configuration is missing: ", paste(missing, collapse = ", "), call. = FALSE)
  }

  target
}

validate_target_records <- function(records, target_name) {
  required <- c("record_sequence", "record_id", "title", "abstract")
  missing <- setdiff(required, names(records))

  if (length(missing) > 0L) {
    stop(
      "Target '", target_name, "' is missing required record columns: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }

  if (anyDuplicated(records$record_id)) {
    stop("Target '", target_name, "' contains duplicated record_id values.", call. = FALSE)
  }

  if (anyDuplicated(records$record_sequence)) {
    stop("Target '", target_name, "' contains duplicated record_sequence values.", call. = FALSE)
  }

  invisible(records)
}

assert_target_ids <- function(data, records, id_column = "record_id", label = "data") {
  if (!id_column %in% names(data)) {
    stop(label, " is missing required column '", id_column, "'.", call. = FALSE)
  }

  unknown <- setdiff(unique(as.character(data[[id_column]])), as.character(records$record_id))

  if (length(unknown) > 0L) {
    stop(
      label, " contains ", length(unknown),
      " record_id value(s) outside the declared target.",
      call. = FALSE
    )
  }

  invisible(data)
}

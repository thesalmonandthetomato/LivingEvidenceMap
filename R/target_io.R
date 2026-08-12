# Target-independent input handling.
#
# A target is a declared set of records plus paths to existing annotation
# tables that should be reused. This module performs no annotation itself.

validate_target_records <- function(records, target_name = "TARGET") {
  required <- c("record_sequence", "record_id", "title", "abstract")
  missing <- setdiff(required, names(records))
  if (length(missing) > 0L) stop("Target ", target_name, " is missing: ", paste(missing, collapse = ", "), call. = FALSE)
  if (!nrow(records)) stop("Target ", target_name, " contains no records.", call. = FALSE)
  if (anyNA(records$record_sequence) || anyDuplicated(records$record_sequence)) stop("Target ", target_name, " must contain unique, non-missing record_sequence values.", call. = FALSE)
  if (anyNA(records$record_id) || anyDuplicated(records$record_id)) stop("Target ", target_name, " must contain unique, non-missing record_id values.", call. = FALSE)
  invisible(records)
}

read_target_records <- function(path, target_name = "TARGET") {
  if (!file.exists(path)) stop("Target ", target_name, " records file does not exist: ", path, call. = FALSE)
  records <- readr::read_csv(path, show_col_types = FALSE)
  validate_target_records(records, target_name)
  records
}

read_target_config <- function(path) {
  if (!file.exists(path)) stop("Target configuration does not exist: ", path, call. = FALSE)
  config <- yaml::read_yaml(path)
  if (is.null(config$target)) stop("Target configuration must contain a 'target' section.", call. = FALSE)
  if (is.null(config$target$name) || !nzchar(config$target$name)) stop("Target configuration must specify target.name.", call. = FALSE)
  if (is.null(config$target$records_file) || !nzchar(config$target$records_file)) stop("Target configuration must specify target.records_file.", call. = FALSE)
  config_dir <- fs::path_dir(fs::path_abs(path))
  config$target$records_file <- fs::path_abs(fs::path(config_dir, config$target$records_file))
  if (!is.null(config$target$annotations)) {
    config$target$annotations <- lapply(config$target$annotations, function(x) {
      if (is.character(x) && length(x) == 1L && nzchar(x)) fs::path_abs(fs::path(config_dir, x)) else x
    })
  }
  config
}

load_target <- function(config_path) {
  config <- read_target_config(config_path)
  records <- read_target_records(config$target$records_file, config$target$name)
  list(config = config, records = records)
}

write_target_manifest <- function(target, config_path, output_dir) {
  fs::dir_create(output_dir)
  manifest <- tibble::tibble(
    target_name = target$config$target$name,
    config_file = fs::path_abs(config_path),
    records_file = target$config$records_file,
    n_records = nrow(target$records),
    min_record_sequence = min(target$records$record_sequence),
    max_record_sequence = max(target$records$record_sequence),
    created_at_utc = format(Sys.time(), tz = "UTC", usetz = TRUE)
  )
  out <- fs::path(output_dir, "target_manifest.csv")
  readr::write_csv(manifest, out)
  out
}

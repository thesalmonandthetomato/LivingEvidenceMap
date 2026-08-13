# Load the established salmon relevance model saved from the validated
# salmonscopingreview workflow.
#
# Production screening deliberately uses the saved model and does not retrain.
# Prediction is batched so a large Lens update cannot disappear into one opaque
# quanteda/glmnet operation.

load_relevance_model <- function(path = "models/relevance/salmon_farming_relevance_model.rds") {
  if (!file.exists(path)) {
    stop("Relevance model not found: ", path, call. = FALSE)
  }

  bundle <- readRDS(path)

  required <- c("model", "thresholds")
  missing <- setdiff(required, names(bundle))
  if (length(missing) > 0L) {
    stop("Relevance model bundle is missing required components: ", paste(missing, collapse = ", "), call. = FALSE)
  }

  model_required <- c("cv_fit", "features", "idf")
  model_missing <- setdiff(model_required, names(bundle$model))
  if (length(model_missing) > 0L) {
    stop("Relevance model is missing required components: ", paste(model_missing, collapse = ", "), call. = FALSE)
  }

  threshold_required <- c("exclude_threshold", "include_threshold")
  threshold_missing <- setdiff(threshold_required, names(bundle$thresholds))
  if (length(threshold_missing) > 0L) {
    stop("Relevance model bundle is missing validated thresholds: ", paste(threshold_missing, collapse = ", "), call. = FALSE)
  }

  bundle
}

# Batched production prediction. The previous implementation transformed the
# entire incoming Lens set through quanteda in one operation. That provided no
# useful progress signal and could retain a large sparse intermediate matrix.
predict_relevance_probability <- function(model, records, batch_size = 250L) {
  n <- nrow(records)
  if (n == 0L) return(numeric())

  batch_size <- as.integer(batch_size)
  if (is.na(batch_size) || batch_size < 1L) batch_size <- 250L

  starts <- seq.int(1L, n, by = batch_size)
  total <- length(starts)
  probabilities <- numeric(n)

  message(sprintf("Relevance screening: predicting %d records in %d batches.", n, total))

  for (i in seq_along(starts)) {
    first <- starts[[i]]
    last <- min(n, first + batch_size - 1L)
    message(sprintf("Relevance screening: batch %d/%d (%d records).", i, total, last - first + 1L))

    batch_text <- records$screening_text[first:last]
    x <- transform_with_model(batch_text, model)
    probabilities[first:last] <- as.numeric(
      stats::predict(
        model$cv_fit,
        newx = x,
        s = "lambda.1se",
        type = "response"
      )
    )

    rm(x, batch_text)
    invisible(gc(FALSE))
  }

  message("Relevance screening: prediction complete.")
  probabilities
}

screen_with_saved_relevance_model <- function(
    records,
    model_path = "models/relevance/salmon_farming_relevance_model.rds"
) {
  message(sprintf("Relevance screening: preparing %d new records.", nrow(records)))
  bundle <- load_relevance_model(model_path)
  message(sprintf("Relevance screening: loaded model with %d features.", length(bundle$model$features)))

  records <- add_screening_keys(records)
  message("Relevance screening: screening keys prepared.")

  probability <- predict_relevance_probability(bundle$model, records)

  records |>
    dplyr::mutate(
      relevance_probability = probability,
      relevance_decision = assign_screening_decision(
        relevance_probability,
        bundle$thresholds
      )
    )
}

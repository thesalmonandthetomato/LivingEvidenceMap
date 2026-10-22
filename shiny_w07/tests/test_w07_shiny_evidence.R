source("shiny_w07/R/w07_shiny_evidence.R")
stopifnot(w07_evidence_supported("crop-yield","Crop yield and quality",""))
stopifnot(w07_evidence_supported("irrigación","Estudio de irrigacion",""))
stopifnot(!w07_evidence_supported("invented results","Crop yield","Other"))
x <- list(assignments=list(list(path_id="ALM_001",evidence="Yield, and quality")))
stopifnot(!length(w07_validate_model_coding(x,"ALM_001","Yield and quality","")))
x$assignments[[1]]$evidence <- "unsupported outcome"
stopifnot(identical(w07_validate_model_coding(x,"ALM_001","Yield and quality",""),
                    "unsupported_evidence_assignment_1"))
stopifnot(!is.null(x$assignments))
cat("PASS W07 evidence normalisation and retained classification flags\n")

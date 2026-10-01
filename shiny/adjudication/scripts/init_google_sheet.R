#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(googlesheets4)
})

source("R/storage_sheets.R")

gs4_auth_from_env()
ss <- sheet_id_from_env()
tab <- sheet_decision_tab()

existing <- googlesheets4::sheet_names(ss)
if (!tab %in% existing) {
  googlesheets4::sheet_add(ss, sheet = tab)
}

header <- data.frame(
  decision_id=character(),
  review_case_id=character(),
  decision=character(),
  rationale=character(),
  reviewer=character(),
  resolved_at_utc=character(),
  queue_sha256=character(),
  supersedes_decision_id=character(),
  stringsAsFactors=FALSE
)

# Only write headers if the target tab is empty.
x <- tryCatch(googlesheets4::read_sheet(ss, sheet=tab, col_types="c"), error=function(e) data.frame())
if (nrow(x)==0L && ncol(x)==0L) {
  googlesheets4::sheet_write(header, ss=ss, sheet=tab)
}
cat(sprintf("PASS: Google Sheets decision tab ready: %s\n", tab))

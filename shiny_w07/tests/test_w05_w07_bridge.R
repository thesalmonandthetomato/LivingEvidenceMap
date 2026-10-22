# Read-only, offline W05 -> W07 Shiny bridge regression.
suppressPackageStartupMessages({library(jsonlite);library(digest)})
source("shiny_w07/R/w05_w07_bridge.R")
records <- list(
 list(identity=list(record_id="r-1"),canonical=list(title="Greenhouse irrigation",abstract="Water use in crops"),abstract_enrichment=list(status="pending_workflow02")),
 list(identity=list(record_id="r-2"),canonical=list(title="Working conditions",abstract="Labour conditions in greenhouses"))
)
lines <- vapply(records,function(x)jsonlite::toJSON(x,auto_unbox=TRUE),character(1))
bytes <- charToRaw(paste(lines,collapse="\n"))
manifest <- list(schema="lem-w05-crop-test-v1",mode="full_corpus",
 input_sha256=w07_bridge_sha(bytes),input_records=2L,processed_records=2L)
x <- w07_bridge_records(bytes,manifest)
stopifnot(nrow(x)==2L,identical(x$record_id,c("r-1","r-2")),
 identical(x$abstract[[1L]],"Water use in crops"))
receipt <- w07_bridge_receipt(x,"test-review","123",manifest$input_sha256)
stopifnot(isTRUE(receipt$w06_bypassed),identical(receipt$source_stage,"W05"))
broken <- manifest; broken$input_sha256 <- paste(rep("0",64),collapse="")
stopifnot(inherits(try(w07_bridge_records(bytes,broken),silent=TRUE),"try-error"))
broken <- manifest; broken$processed_records <- 1L
stopifnot(inherits(try(w07_bridge_records(bytes,broken),silent=TRUE),"try-error"))
duplicate <- records; duplicate[[2]]$identity$record_id <- "r-1"
dupe_bytes <- charToRaw(paste(vapply(duplicate,jsonlite::toJSON,character(1),auto_unbox=TRUE),collapse="\n"))
broken <- manifest; broken$input_sha256 <- w07_bridge_sha(dupe_bytes)
stopifnot(inherits(try(w07_bridge_records(dupe_bytes,broken),silent=TRUE),"try-error"))
cat("PASS read-only W05 to W07 record conversion, exact field access and guards\n")

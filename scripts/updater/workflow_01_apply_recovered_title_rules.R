#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(jsonlite)
  library(digest)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default=NULL){
  i <- match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop("Missing value after ",flag,call.=FALSE)
  args[[i+1L]]
}
input <- arg("--input")
resolved_path <- arg("--resolved")
remaining_path <- arg("--remaining")
summary_path <- arg("--summary")
source_run_id <- arg("--source-run-id","36049567027")
if(any(vapply(list(input,resolved_path,remaining_path,summary_path),is.null,logical(1)))) {
  stop("Required: --input --resolved --remaining --summary",call.=FALSE)
}

read_jsonl <- function(path){
  z <- readLines(path,warn=FALSE,encoding="UTF-8")
  z <- z[nzchar(trimws(z))]
  lapply(z,fromJSON,simplifyVector=FALSE)
}
write_jsonl <- function(xs,path){
  dir.create(dirname(path),recursive=TRUE,showWarnings=FALSE)
  con <- file(path,"wt",encoding="UTF-8"); on.exit(close(con))
  for(x in xs) writeLines(toJSON(x,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)
}
clean_title <- function(x){
  if(is.null(x)||!length(x)||is.na(x[[1L]])||!nzchar(trimws(as.character(x[[1L]])))) return("")
  trimws(as.character(x[[1L]]))
}
title_type <- function(x){
  s <- tolower(clean_title(x))
  if(!nzchar(s)) return("missing")
  if(grepl("^peer\\s*review\\b",s,perl=TRUE)) return("peer_review")
  if(grepl("^(supplementary|additional)\\s+file\\b",s,perl=TRUE)) return("supplementary_file")
  if(grepl("^table\\b",s,perl=TRUE)) return("table")
  if(grepl("^reviewer\\s+response\\b",s,perl=TRUE)) return("reviewer_response")
  if(grepl("^editor\\s+response\\b",s,perl=TRUE)) return("editor_response")
  if(grepl("^library\\s+guides?\\b",s,perl=TRUE)) return("library_guide")
  if(grepl("^data\\s+sheet\\b",s,perl=TRUE)) return("data_sheet")
  "ordinary"
}
pair_class <- function(a,b){
  z <- sort(c(a,b))
  paste(z,collapse="__")
}
rule_map <- c(
  "peer_review__peer_review"="peer_review_to_peer_review",
  "missing__peer_review"="peer_review_to_missing_title",
  "ordinary__supplementary_file"="supplementary_file_to_ordinary_title",
  "supplementary_file__table"="supplementary_file_to_table",
  "editor_response__reviewer_response"="reviewer_response_to_editor_response",
  "ordinary__reviewer_response"="reviewer_response_to_ordinary_title",
  "editor_response__ordinary"="editor_response_to_ordinary_title",
  "ordinary__peer_review"="peer_review_to_ordinary_title",
  "library_guide__library_guide"="library_guide_to_library_guide",
  "data_sheet__supplementary_file"="data_sheet_to_supplementary_file"
)
expected <- c(
  peer_review_to_peer_review=103L,
  peer_review_to_missing_title=71L,
  supplementary_file_to_ordinary_title=23L,
  supplementary_file_to_table=14L,
  reviewer_response_to_editor_response=12L,
  reviewer_response_to_ordinary_title=12L,
  editor_response_to_ordinary_title=8L,
  peer_review_to_ordinary_title=6L,
  library_guide_to_library_guide=6L,
  data_sheet_to_supplementary_file=3L
)

rows <- read_jsonl(input)
if(length(rows)!=277L) stop("Expected exactly 277 recovered human-review cases; found ",length(rows),call.=FALSE)
ids <- vapply(rows,function(x)as.character(x$review_case_id),character(1))
if(anyDuplicated(ids)) stop("Duplicate review_case_id in input",call.=FALSE)

resolved <- list(); remaining <- list()
counts <- setNames(integer(length(expected)),names(expected))
now <- format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")

for(x in rows){
  ti <- title_type(x$record_i$title)
  tj <- title_type(x$record_j$title)
  pc <- pair_class(ti,tj)
  rule <- unname(rule_map[[pc]])
  if(!is.null(rule) && nzchar(rule)){
    counts[[rule]] <- counts[[rule]] + 1L
    resolved[[length(resolved)+1L]] <- list(
      schema="living-evidence-map-workflow01-rule-decision-v1",
      review_case_id=x$review_case_id,
      pair_key=x$pair_key,
      decision="duplicate",
      decision_source="user_approved_title_class_rule",
      rule_id=rule,
      title_type_i=ti,
      title_type_j=tj,
      title_i=x$record_i$title,
      title_j=x$record_j$title,
      recovery_run_id=source_run_id,
      original_model_decision=x$model_decision,
      original_model_confidence=x$model_confidence,
      original_promotion=x$promotion,
      decided_at_utc=now
    )
  } else {
    remaining[[length(remaining)+1L]] <- x
  }
}

if(!identical(as.integer(counts[names(expected)]),as.integer(expected))) {
  stop(
    "Rule-count guard failed. Expected: ",
    paste(names(expected),expected,sep="=",collapse=", "),
    "; observed: ",
    paste(names(counts),counts,sep="=",collapse=", "),
    call.=FALSE
  )
}
if(length(resolved)!=258L) stop("Expected 258 rule-resolved duplicates; found ",length(resolved),call.=FALSE)
if(length(remaining)!=19L) stop("Expected 19 remaining cases; found ",length(remaining),call.=FALSE)

remaining_types <- table(vapply(remaining,function(x){
  pair_class(title_type(x$record_i$title),title_type(x$record_j$title))
},character(1)))
expected_remaining <- c("missing__missing"=10L,"missing__ordinary"=9L)
if(!identical(as.integer(remaining_types[names(expected_remaining)]),as.integer(expected_remaining))) {
  stop("Remaining-case guard failed",call.=FALSE)
}

write_jsonl(resolved,resolved_path)
write_jsonl(remaining,remaining_path)
summary <- list(
  schema="living-evidence-map-workflow01-recovered-title-rule-summary-v1",
  source_recovery_run_id=source_run_id,
  input_human_review_cases=length(rows),
  rule_resolved_duplicates=length(resolved),
  remaining_human_review=length(remaining),
  approved_rule_counts=as.list(counts),
  remaining_title_classes=as.list(remaining_types),
  input_sha256=digest(file=input,algo="sha256",serialize=FALSE),
  resolved_sha256=digest(file=resolved_path,algo="sha256",serialize=FALSE),
  remaining_sha256=digest(file=remaining_path,algo="sha256",serialize=FALSE),
  created_at_utc=now
)
dir.create(dirname(summary_path),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),summary_path,useBytes=TRUE)
cat(sprintf("PASS: 277 recovered human-review cases -> 258 rule-resolved duplicates + 19 remaining human-review cases\n"))
cat(paste(names(counts),counts,sep="=",collapse="; "),"\n")
cat("Remaining:",paste(names(remaining_types),remaining_types,sep="=",collapse="; "),"\n")

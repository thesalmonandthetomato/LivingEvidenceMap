#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(jsonlite)
  library(digest)
  library(readr)
  library(googlesheets4)
})

`%||%` <- function(x,y) if(is.null(x)||length(x)==0L) y else x

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}

queue_path <- arg("--queue")
species_config_path <- arg("--species-config")
ontology_path <- arg("--ontology")
sheet_id <- arg("--sheet-id", Sys.getenv("LEM_GOOGLE_SHEET_ID"))
credential_path <- arg("--credential", Sys.getenv("LEM_GOOGLE_SERVICE_ACCOUNT_JSON"))
tab <- arg("--tab","queue_w08_active")

req <- c(queue_path,species_config_path,ontology_path,sheet_id,credential_path)
if (any(vapply(req,function(x)is.null(x)||!nzchar(x),logical(1)))) stop("Missing required W08 Shiny publisher argument",call.=FALSE)
if (!file.exists(queue_path)||!file.exists(species_config_path)||!file.exists(ontology_path)||!file.exists(credential_path)) stop("Required W08 Shiny publisher file missing",call.=FALSE)

lines <- readLines(queue_path,warn=FALSE,encoding="UTF-8")
lines <- lines[nzchar(trimws(lines))]
if (!length(lines)) stop("W08 pending review queue is empty",call.=FALSE)

cases <- lapply(lines,fromJSON,simplifyVector=FALSE)
record_ids <- vapply(cases,function(z)as.character(z$record_id %||% ""),character(1))
if (any(!nzchar(record_ids))||anyDuplicated(record_ids)) stop("W08 queue has missing/duplicate record_id",call.=FALSE)

all_issue_keys <- unlist(lapply(cases,function(z){
  rid <- as.character(z$record_id)
  issues <- z$issues %||% list()
  if (!length(issues)) stop("W08 queue case has no issues: ",rid,call.=FALSE)
  vapply(issues,function(i){
    typ <- as.character(i$issue_type %||% "")
    h <- as.character(i$issue_state_sha256 %||% "")
    allowed <- as.character(i$allowed_human_outcomes %||% character())
    if (!nzchar(typ)||!nzchar(h)||!length(allowed)) stop("Malformed W08 issue in record ",rid,call.=FALSE)
    paste(rid,typ,sep="::")
  },character(1))
}),use.names=FALSE)
if (anyDuplicated(all_issue_keys)) stop("W08 queue contains duplicate issue keys",call.=FALSE)

queue_sha <- digest(file=queue_path,algo="sha256",serialize=FALSE)
batch_id <- paste0("w08-annotation-",substr(queue_sha,1,12))

species_config <- fromJSON(species_config_path,simplifyVector=FALSE)
species_labels <- names(species_config$code_map %||% list())
species_labels <- species_labels[nzchar(species_labels)]
if (!length(species_labels)) stop("Species config contains no code-map labels",call.=FALSE)

ontology <- read_csv(ontology_path,show_col_types=FALSE,progress=FALSE)
if (!all(c("path_id","hierarchy_path") %in% names(ontology))) stop("Topic ontology lacks path_id/hierarchy_path",call.=FALSE)
topic_options <- lapply(seq_len(nrow(ontology)),function(i)list(
  path_id=as.character(ontology$path_id[[i]]),
  hierarchy_path=as.character(ontology$hierarchy_path[[i]])
))

payload <- data.frame(
  batch_id=rep(batch_id,length(lines)),
  queue_sha256=rep(queue_sha,length(lines)),
  case_index=as.character(seq_along(lines)),
  record_id=record_ids,
  case_json=lines,
  species_options_json=c(toJSON(species_labels,auto_unbox=FALSE),rep("",max(0,length(lines)-1L))),
  topic_options_json=c(toJSON(topic_options,auto_unbox=TRUE),rep("",max(0,length(lines)-1L))),
  stringsAsFactors=FALSE
)

gs4_auth(path=credential_path,cache=FALSE)
tabs <- sheet_names(sheet_id)
if (!tab %in% tabs) sheet_add(sheet_id,sheet=tab)
sheet_write(payload,ss=sheet_id,sheet=tab)

verify <- read_sheet(sheet_id,sheet=tab,col_types="c")
required <- names(payload)
if (!all(required %in% names(verify))) stop("Published W08 queue missing required columns",call.=FALSE)
verify <- verify[,required,drop=FALSE]
if (nrow(verify)!=length(lines)) stop("Published W08 queue row count mismatch",call.=FALSE)
if (!identical(as.character(verify$record_id),record_ids)) stop("Published W08 queue record order mismatch",call.=FALSE)
reconstructed <- paste0(paste(verify$case_json,collapse="\n"),"\n")
if (!identical(digest(reconstructed,algo="sha256",serialize=FALSE),queue_sha)) stop("Published W08 queue SHA mismatch",call.=FALSE)

cat(sprintf("PASS: published W08 annotation queue: records=%d issues=%d batch=%s sha=%s\n",
            length(lines),length(all_issue_keys),batch_id,queue_sha))

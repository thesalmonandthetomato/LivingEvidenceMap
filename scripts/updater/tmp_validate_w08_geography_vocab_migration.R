#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(readr)})
args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop("Missing ",flag,call.=FALSE);args[[i+1L]]}
queue_path<-arg("--queue")
w05_path<-arg("--w05")
manifest_path<-arg("--manifest")
out_dir<-arg("--output-dir","outputs/validation")
if(any(vapply(c(queue_path,w05_path,manifest_path),function(x)is.null(x)||!file.exists(x),logical(1))))stop("Missing validation input",call.=FALSE)
dir.create(out_dir,recursive=TRUE,showWarnings=FALSE)

read_jsonl<-function(path){x<-readLines(path,warn=FALSE,encoding="UTF-8");x<-x[nzchar(trimws(x))];lapply(x,fromJSON,simplifyVector=FALSE)}
clean<-function(x){if(is.null(x)||!length(x))return("");z<-as.character(x[[1L]]);if(is.na(z))"" else z}

queue<-read_jsonl(queue_path)
w05<-read_csv(w05_path,show_col_types=FALSE,progress=FALSE)
m<-fromJSON(manifest_path,simplifyVector=FALSE)

none_ids<-unique(as.character(w05$record_id[w05$farmed_species_codes=="NONE"]))
queue_ids<-if(length(queue))vapply(queue,function(z)clean(z$record_id),character(1))else character()
issue_types<-if(length(queue))unlist(lapply(queue,function(z)vapply(z$issues%||%list(),function(i)clean(i$issue_type),character(1))),use.names=FALSE)else character()

if(any(none_ids%in%queue_ids))stop("A W05 species-NONE record remains in the W08 human-review queue",call.=FALSE)
if(any(issue_types=="species_none"))stop("Production W08 queue still emits species_none issues",call.=FALSE)
if(as.integer(m$w05_species_none_deterministic_exclusions)!=length(none_ids))stop("Manifest species-NONE deterministic exclusion count mismatch",call.=FALSE)
if(as.integer(m$w05_species_none_human_review_issues)!=0L)stop("Manifest reports species-NONE human review issues",call.=FALSE)

builder<-readLines("scripts/updater/workflow_08_build_review_queue_dynamic.R",warn=FALSE,encoding="UTF-8")
finalizer<-readLines("scripts/updater/workflow_08_finalize_canonical_dynamic.R",warn=FALSE,encoding="UTF-8")
invisible(parse("scripts/updater/workflow_08_build_review_queue_dynamic.R"))
invisible(parse("scripts/updater/workflow_08_finalize_canonical_dynamic.R"))

need_builder<-c(
  'w05_none_ids<-unique(as.character(w05_none$record_id))',
  'if(rid%in%w05_none_ids)return(invisible(NULL))',
  'w05_species_none_deterministic_exclusions=nrow(w05_none)',
  'w05_species_none_human_review_issues=0L'
)
miss<-need_builder[!vapply(need_builder,function(z)any(grepl(z,builder,fixed=TRUE)),logical(1))]
if(length(miss))stop("Missing builder contract: ",paste(miss,collapse=" | "),call.=FALSE)

need_finalizer<-c(
  'identical(scodes,"NONE")&&is.null(sd)',
  'screening$exclusion_reason<-"species_none_deterministic_exclusion"',
  'species_deterministic_exclusions<-species_deterministic_exclusions+1L',
  'species_deterministic_exclusions=species_deterministic_exclusions'
)
miss<-need_finalizer[!vapply(need_finalizer,function(z)any(grepl(z,finalizer,fixed=TRUE)),logical(1))]
if(length(miss))stop("Missing finalizer contract: ",paste(miss,collapse=" | "),call.=FALSE)

summary<-list(
  schema="living-evidence-map-w08-species-none-deterministic-exclusion-validation-v1",
  status="PASS",
  model_calls=0L,
  w05_species_none_records=length(none_ids),
  species_none_records_in_human_queue=sum(none_ids%in%queue_ids),
  species_none_issue_types_in_queue=sum(issue_types=="species_none"),
  deterministic_exclusion_reason="species_none_deterministic_exclusion",
  suppresses_all_w08_review_for_species_none=TRUE,
  legacy_species_none_finalizer_compatibility=TRUE,
  current_w08_review_records=length(queue),
  current_w08_review_issues=length(issue_types),
  validated_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
write_json(summary,file.path(out_dir,"summary.json"),auto_unbox=TRUE,pretty=TRUE)
cat(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),"\n")

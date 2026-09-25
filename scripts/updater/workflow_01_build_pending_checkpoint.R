#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(jsonlite)
  library(digest)
})


args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL){
  i <- match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}

previous_root <- arg("--previous-root")
current_seed_root <- arg("--current-seed-root")
incremental_rescore <- arg("--incremental-rescore")
adjudications <- arg("--adjudications")
review_package <- arg("--review-package")
pre_summary <- arg("--pre-summary")
previous_pointer <- arg("--previous-pointer")
workflow00_pointer <- arg("--workflow00-pointer")
output_dir <- arg("--output-dir")
run_id <- arg("--run-id")
required <- list(previous_root,current_seed_root,incremental_rescore,adjudications,review_package,
                 pre_summary,previous_pointer,workflow00_pointer,output_dir,run_id)
if(any(vapply(required,is.null,logical(1)))) stop("Missing required checkpoint argument",call.=FALSE)

dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)
dir.create(file.path(output_dir,"source_manifestations"),recursive=TRUE,showWarnings=FALSE)
sha <- function(path) digest(file=path,algo="sha256",serialize=FALSE)
read_nonempty <- function(path){
  x<-readLines(path,warn=FALSE,encoding="UTF-8")
  x[nzchar(trimws(x))]
}
write_lines <- function(x,path){
  if(length(x)) writeLines(x,path,useBytes=TRUE) else file.create(path)
}

source_files <- c(
  lens="lens_records_for_deduplication.jsonl",
  scopus="scopus_records_for_deduplication.jsonl",
  openalex="openalex_records_for_deduplication.jsonl",
  agricola="agricola_records_for_deduplication.jsonl",
  wos="wos_records_for_deduplication.jsonl"
)
source_counts <- list()
for(src in names(source_files)){
  prev <- file.path(previous_root,"workflow01_seed",source_files[[src]])
  cur <- file.path(current_seed_root,source_files[[src]])
  p <- read_nonempty(prev); z <- read_nonempty(cur)
  if(length(z)<length(p) || (length(p)&&!identical(z[seq_along(p)],p))){
    stop(sprintf("%s source state is not an append-only extension",src),call.=FALSE)
  }
  add <- if(length(z)>length(p)) z[(length(p)+1L):length(z)] else character()
  out <- file.path(output_dir,"source_manifestations",paste0(src,"_new.jsonl"))
  write_lines(add,out)
  source_counts[[src]] <- length(add)
}

file.copy(incremental_rescore,file.path(output_dir,"incremental_rescored_pairs.csv"),overwrite=TRUE)
file.copy(adjudications,file.path(output_dir,"all_adjudications.jsonl"),overwrite=TRUE)
file.copy(pre_summary,file.path(output_dir,"pre_adjudication_summary.json"),overwrite=TRUE)
file.copy(previous_pointer,file.path(output_dir,"previous_workflow01_pointer.json"),overwrite=TRUE)
file.copy(workflow00_pointer,file.path(output_dir,"workflow00_pointer.json"),overwrite=TRUE)
dir.create(file.path(output_dir,"human_review_package"),showWarnings=FALSE)
files <- list.files(review_package,full.names=TRUE,all.files=TRUE,no..=TRUE)
file.copy(files,file.path(output_dir,"human_review_package"),recursive=TRUE,overwrite=TRUE)

prev <- fromJSON(previous_pointer,simplifyVector=FALSE)
w00 <- fromJSON(workflow00_pointer,simplifyVector=FALSE)
review_manifest <- fromJSON(file.path(output_dir,"human_review_package","review_manifest.json"),simplifyVector=FALSE)
manifest <- list(
  schema="living-evidence-map-workflow01-pending-checkpoint-v1",
  workflow="01",
  state="pre_adjudication",
  github_run_id=as.character(run_id),
  previous_workflow01=list(
    github_run_id=as.character(prev$github_run_id),
    zenodo_record_id=as.character(prev$zenodo_record_id),
    manifest_sha256=as.character(prev$manifest_sha256)
  ),
  workflow00=list(
    github_run_id=as.character(w00$github_run_id %||% w00$run_id %||% ""),
    zenodo_record_id=as.character(w00$zenodo_record_id %||% ""),
    manifest_sha256=as.character(w00$manifest_sha256 %||% "")
  ),
  new_source_manifestations=sum(unlist(source_counts)),
  new_source_manifestations_by_source=source_counts,
  pending_human_cases=as.integer(review_manifest$pending_count),
  queue_sha256=as.character(review_manifest$queue_sha256),
  files=list(
    incremental_rescored_pairs_sha256=sha(file.path(output_dir,"incremental_rescored_pairs.csv")),
    adjudications_sha256=sha(file.path(output_dir,"all_adjudications.jsonl")),
    pre_summary_sha256=sha(file.path(output_dir,"pre_adjudication_summary.json"))
  ),
  created_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
writeLines(toJSON(manifest,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),
           file.path(output_dir,"checkpoint_manifest.json"),useBytes=TRUE)
cat(sprintf("PASS: pending Workflow 01 checkpoint: %d new manifestations, %d human-review cases\n",
            manifest$new_source_manifestations,manifest$pending_human_cases))

`%||%` <- function(x,y) if(is.null(x)) y else x

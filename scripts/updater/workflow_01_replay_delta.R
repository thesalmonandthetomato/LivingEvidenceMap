#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(data.table)
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
delta_dir <- arg("--delta-dir")
output_root <- arg("--output-root")
if(any(vapply(list(previous_root,delta_dir,output_root),is.null,logical(1)))) {
  stop("Required: --previous-root --delta-dir --output-root",call.=FALSE)
}

manifest_path <- file.path(delta_dir,"delta_manifest.json")
if(!file.exists(manifest_path)) stop("Delta manifest not found",call.=FALSE)
m <- fromJSON(manifest_path,simplifyVector=FALSE)
if(!identical(m$schema,"living-evidence-map-workflow01-delta-v1")) stop("Unsupported delta schema",call.=FALSE)

dir.create(output_root,recursive=TRUE,showWarnings=FALSE)
dir.create(file.path(output_root,"workflow01_seed"),recursive=TRUE,showWarnings=FALSE)
dir.create(file.path(output_root,"workflow01_full_five_source"),recursive=TRUE,showWarnings=FALSE)
dir.create(file.path(output_root,"canonical"),recursive=TRUE,showWarnings=FALSE)

sha <- function(path) digest(file=path,algo="sha256",serialize=FALSE)
read_nonempty <- function(path){
  x <- readLines(path,warn=FALSE,encoding="UTF-8")
  x[nzchar(trimws(x))]
}
append_file <- function(base,delta,out){
  in_con <- file(base,"rb"); on.exit(close(in_con),add=TRUE)
  out_con <- file(out,"wb"); on.exit(close(out_con),add=TRUE)
  repeat{
    buf <- readBin(in_con,"raw",n=1024L*1024L)
    if(!length(buf)) break
    writeBin(buf,out_con)
  }
  close(in_con); on.exit(NULL,add=FALSE)
  if(file.exists(delta) && file.info(delta)$size>0){
    # Delta JSONL files always contain complete newline-terminated records.
    d <- readBin(delta,"raw",n=file.info(delta)$size)
    writeBin(d,out_con)
  }
  close(out_con); on.exit(NULL,add=FALSE)
}

# 1. Replay append-only source manifestations.
source_files <- c(
  lens="lens_records_for_deduplication.jsonl",
  scopus="scopus_records_for_deduplication.jsonl",
  openalex="openalex_records_for_deduplication.jsonl",
  agricola="agricola_records_for_deduplication.jsonl",
  wos="wos_records_for_deduplication.jsonl"
)
for(src in names(source_files)){
  base <- file.path(previous_root,"workflow01_seed",source_files[[src]])
  delta <- file.path(delta_dir,"source_manifestations",paste0(src,"_new.jsonl"))
  out <- file.path(output_root,"workflow01_seed",source_files[[src]])
  if(!file.exists(base)||!file.exists(delta)) stop(sprintf("Missing source replay input for %s",src),call.=FALSE)
  append_file(base,delta,out)
  target <- m$target$source_files[[src]]
  if(!identical(tolower(sha(out)),tolower(as.character(target$current_sha256)))) {
    stop(sprintf("%s replay SHA-256 does not match target",src),call.=FALSE)
  }
}

align_cols <- function(a,b){
  cols <- union(names(a),names(b))
  for(nm in setdiff(cols,names(a))) a[[nm]] <- NA
  for(nm in setdiff(cols,names(b))) b[[nm]] <- NA
  list(a=a[,..cols],b=b[,..cols],cols=cols)
}

# 2. Replay pair-decision upserts.
prev_pairs <- fread(file.path(previous_root,"workflow01_full_five_source","final_pair_decisions.csv"),na.strings=c("","NA"))
up_pairs <- fread(file.path(delta_dir,"pair_decision_upserts.csv"),na.strings=c("","NA"))
if(nrow(up_pairs)){
  if(anyDuplicated(up_pairs$pair_key)) stop("Delta pair upserts contain duplicate pair_key",call.=FALSE)
  ab <- align_cols(prev_pairs,up_pairs); prev_pairs <- ab$a; up_pairs <- ab$b
  prev_pairs <- prev_pairs[!(pair_key %in% up_pairs$pair_key)]
  pairs <- rbindlist(list(prev_pairs,up_pairs),use.names=TRUE,fill=TRUE)
} else pairs <- prev_pairs
setorder(pairs,pair_key)
pair_out <- file.path(output_root,"workflow01_full_five_source","final_pair_decisions.csv")
fwrite(pairs,pair_out,na="")
if(!identical(tolower(sha(pair_out)),tolower(as.character(m$target$pair_decisions_sha256)))) {
  stop("Replayed pair-decision SHA-256 does not match target",call.=FALSE)
}

# 3. Replay cluster-map upserts.
prev_map <- fread(file.path(previous_root,"workflow01_full_five_source","manifestation_cluster_map.csv"),na.strings=c("","NA"))
up_map <- fread(file.path(delta_dir,"cluster_map_upserts.csv"),na.strings=c("","NA"))
prev_map[,manifestation_key:=paste(source,source_record_id,sep="::")]
if(nrow(up_map)){
  up_map[,manifestation_key:=paste(source,source_record_id,sep="::")]
  if(anyDuplicated(up_map$manifestation_key)) stop("Delta cluster-map upserts contain duplicate manifestation key",call.=FALSE)
  ab <- align_cols(prev_map,up_map); prev_map <- ab$a; up_map <- ab$b
  prev_map <- prev_map[!(manifestation_key %in% up_map$manifestation_key)]
  cmap <- rbindlist(list(prev_map,up_map),use.names=TRUE,fill=TRUE)
} else cmap <- prev_map
cmap[,manifestation_key:=NULL]
setorder(cmap,idx)
map_out <- file.path(output_root,"workflow01_full_five_source","manifestation_cluster_map.csv")
fwrite(cmap,map_out,na="")
if(!identical(tolower(sha(map_out)),tolower(as.character(m$target$cluster_map_sha256)))) {
  stop("Replayed cluster-map SHA-256 does not match target",call.=FALSE)
}

# Preserve target summary exactly.
file.copy(file.path(delta_dir,"target_summary.json"),
          file.path(output_root,"workflow01_full_five_source","summary.json"),overwrite=TRUE)

# 4. Replay canonical JSONL as a sorted merge of previous records and upserts.
record_id <- function(line){
  z <- fromJSON(line,simplifyVector=FALSE)
  as.character(z$identity$record_id)
}
prev_path <- file.path(previous_root,"canonical","records.jsonl")
up_path <- file.path(delta_dir,"canonical_upserts.jsonl")
retired <- read_nonempty(file.path(delta_dir,"canonical_retired_ids.txt"))
retired_set <- setNames(rep(TRUE,length(retired)),retired)

up_lines <- read_nonempty(up_path)
up_ids <- if(length(up_lines)) vapply(up_lines,record_id,character(1)) else character()
if(length(up_ids) && is.unsorted(up_ids,strictly=FALSE)) stop("Canonical upserts are not sorted by record ID",call.=FALSE)
if(anyDuplicated(up_ids)) stop("Canonical upserts contain duplicate record IDs",call.=FALSE)

canonical_out <- file.path(output_root,"canonical","records.jsonl")
pin <- file(prev_path,"rt",encoding="UTF-8")
pout <- file(canonical_out,"wt",encoding="UTF-8")
on.exit(close(pin),add=TRUE); on.exit(close(pout),add=TRUE)
u <- 1L
repeat{
  pl <- readLines(pin,n=1L,warn=FALSE)
  if(!length(pl)) break
  if(!nzchar(trimws(pl))) next
  pid <- record_id(pl)
  while(u<=length(up_ids) && up_ids[[u]] < pid){
    writeLines(up_lines[[u]],pout,useBytes=TRUE)
    u <- u+1L
  }
  if(u<=length(up_ids) && identical(up_ids[[u]],pid)){
    writeLines(up_lines[[u]],pout,useBytes=TRUE)
    u <- u+1L
  } else if(is.null(retired_set[[pid]])){
    writeLines(pl,pout,useBytes=TRUE)
  }
}
while(u<=length(up_ids)){
  writeLines(up_lines[[u]],pout,useBytes=TRUE)
  u <- u+1L
}
close(pin); close(pout); on.exit(NULL,add=FALSE)

target_canonical_sha <- as.character(m$target$canonical_jsonl_sha256)
if(!identical(tolower(sha(canonical_out)),tolower(target_canonical_sha))) {
  stop("Replayed canonical JSONL SHA-256 does not match target",call.=FALSE)
}
file.copy(file.path(delta_dir,"target_canonical_manifest.json"),
          file.path(output_root,"canonical","canonical_manifest.json"),overwrite=TRUE)

# Preserve current alias ledger and repair audit where supplied.
file.copy(file.path(delta_dir,"cluster_id_aliases.csv"),
          file.path(output_root,"workflow01_full_five_source","cluster_id_aliases.csv"),overwrite=TRUE)
if(file.exists(file.path(delta_dir,"data_quality_repair_application.jsonl"))){
  dir.create(file.path(output_root,"provenance"),showWarnings=FALSE)
  file.copy(file.path(delta_dir,"data_quality_repair_application.jsonl"),
            file.path(output_root,"provenance","data_quality_repair_application.jsonl"),overwrite=TRUE)
}

audit <- list(
  schema="living-evidence-map-workflow01-delta-replay-audit-v1",
  status="PASS",
  previous_github_run_id=as.character(m$previous$github_run_id),
  delta_github_run_id=as.character(m$github_run_id),
  source_manifestations=as.integer(m$target$source_manifestations),
  canonical_records=as.integer(m$target$canonical_records),
  canonical_jsonl_sha256=target_canonical_sha,
  pair_decisions_sha256=as.character(m$target$pair_decisions_sha256),
  cluster_map_sha256=as.character(m$target$cluster_map_sha256),
  replayed_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
writeLines(toJSON(audit,auto_unbox=TRUE,pretty=TRUE,null="null"),
           file.path(output_root,"workflow01_delta_replay_audit.json"),useBytes=TRUE)
cat(sprintf("PASS: replayed Workflow 01 delta to %d manifestations and %d canonical records with exact target checksums\n",
            audit$source_manifestations,audit$canonical_records))

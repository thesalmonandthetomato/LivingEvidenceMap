#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(jsonlite)
  library(digest)
  library(readr)
  library(httr2)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL){
  i <- match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}
`%||%` <- function(x,y) if(is.null(x)) y else x
clean <- function(x){
  if(is.null(x)||!length(x)) return("")
  z<-trimws(as.character(x[[1L]])); if(is.na(z)||!nzchar(z)) "" else z
}
read_jsonl <- function(path){
  x<-readLines(path,warn=FALSE,encoding="UTF-8"); x<-x[nzchar(trimws(x))]
  lapply(x,function(z)fromJSON(z,simplifyVector=FALSE))
}
status_path <- arg("--status","docs/current_run/current_run_status.json")
ids_path <- arg("--record-ids","docs/current_run/current_run_record_ids.txt")
force_stage <- toupper(arg("--force-stage",""))
changed_file <- arg("--changed-files","")
changed <- if(nzchar(changed_file) && file.exists(changed_file)) {
  trimws(readLines(changed_file,warn=FALSE))
} else character()
changed <- changed[nzchar(changed)]

load_status <- function(){
  if(!file.exists(status_path)) return(NULL)
  fromJSON(status_path,simplifyVector=FALSE)
}
save_status <- function(x){
  dir.create(dirname(status_path),recursive=TRUE,showWarnings=FALSE)
  x$last_updated_at_utc <- format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
  writeLines(toJSON(x,auto_unbox=TRUE,pretty=TRUE,null="null",na="null",digits=NA),status_path,useBytes=TRUE)
}
progress <- function(done,current=NULL){
  labs<-c("W00","W01","W02","W03","W04","W05","W06","W07","W08","W10")
  setNames(lapply(seq_along(labs),function(i){
    st<-if(i<=done)"complete" else if(!is.null(current)&&i==current)"active" else "pending"
    list(status=st)
  }),labs)
}
latest_row <- function(path){
  x<-read.csv(path,stringsAsFactors=FALSE,check.names=FALSE)
  if(!nrow(x)) stop("Registry is empty: ",path,call.=FALSE)
  x[nrow(x),,drop=FALSE]
}
authoritative_w08 <- function(){
  reg<-read.csv("docs/workflow08/zenodo_registry.csv",stringsAsFactors=FALSE,check.names=FALSE)
  hit<-reg[as.character(reg$status)=="authoritative",,drop=FALSE]
  if(nrow(hit)!=1L) stop(sprintf("Expected one authoritative W08 row, found %d",nrow(hit)),call.=FALSE)
  p<-sprintf("docs/workflow08/zenodo/run-%s.json",as.character(hit$source_run_id[[1L]]))
  x<-fromJSON(p,simplifyVector=FALSE)
  list(pointer=p,run_id=as.character(x$source_github_run_id),records=as.integer(x$canonical_records),
       sha256=as.character(x$final_canonical_jsonl_sha256))
}
stage_from_changed <- function(){
  if(nzchar(force_stage)) return(force_stage)
  if(any(grepl("^docs/search_record/(full_search|fortnightly_update|ad_hoc)/.*\\.json$",changed))) return("W00")
  if("docs/deduplication/zenodo_registry.csv" %in% changed) return("W01")
  if("docs/enrichment/zenodo_registry.csv" %in% changed) return("W02")
  if("docs/publication_status/zenodo_registry.csv" %in% changed) return("W03")
  if("docs/workflow04/zenodo_registry.csv" %in% changed) return("W04")
  if("docs/workflow05/zenodo_registry.csv" %in% changed) return("W05")
  if("docs/workflow06/zenodo_registry.csv" %in% changed) return("W06")
  if("docs/workflow07/zenodo_registry.csv" %in% changed) return("W07")
  if("docs/workflow08/zenodo_registry.csv" %in% changed) return("W08")
  ""
}
download_archive <- function(pointer_path,outdir){
  token<-Sys.getenv("ZENODO_ACCESS_TOKEN")
  if(!nzchar(token)) stop("ZENODO_ACCESS_TOKEN is required",call.=FALSE)
  p<-fromJSON(pointer_path,simplifyVector=FALSE)
  files<-p$archive_files
  if(is.data.frame(files)) files<-lapply(seq_len(nrow(files)),function(i)as.list(files[i,,drop=FALSE]))
  if(is.list(files)&&!is.null(files$filename)) files<-list(files)
  ars<-Filter(function(z)grepl("\\.tar\\.gz$",as.character(z$filename)),files)
  if(length(ars)!=1L) stop("Expected exactly one archive tar.gz in pointer ",pointer_path,call.=FALSE)
  a<-ars[[1L]]
  dep<-request(paste0("https://zenodo.org/api/deposit/depositions/",p$zenodo_deposition_id)) |>
    req_headers(Authorization=paste("Bearer",token)) |> req_timeout(120) |> req_perform() |> resp_body_json(simplifyVector=FALSE)
  bucket<-as.character(dep$links$bucket)
  dir.create(outdir,recursive=TRUE,showWarnings=FALSE)
  dest<-file.path(outdir,as.character(a$filename))
  resp<-request(paste0(sub("/$","",bucket),"/",URLencode(as.character(a$filename),reserved=TRUE))) |>
    req_headers(Authorization=paste("Bearer",token)) |> req_timeout(1800) |>
    req_error(is_error=function(resp)FALSE) |> req_perform(path=dest)
  if(resp_status(resp)!=200L) stop("Zenodo archive download failed",call.=FALSE)
  if(as.numeric(file.info(dest)$size)!=as.numeric(a$bytes)) stop("Archive byte mismatch",call.=FALSE)
  if(tolower(digest(file=dest,algo="sha256",serialize=FALSE))!=tolower(as.character(a$sha256))) stop("Archive SHA mismatch",call.=FALSE)
  ex<-file.path(outdir,"extract");dir.create(ex,showWarnings=FALSE);utils::untar(dest,exdir=ex);ex
}
cohort_ids <- function(){
  if(!file.exists(ids_path)) return(character())
  x<-trimws(readLines(ids_path,warn=FALSE));unique(x[nzchar(x)])
}
set_run <- function(s,stage,run_id,done,current,label){
  s$progress<-progress(done,current)
  s$progress$current_stage<-stage
  s$progress$completed_through<-done
  s$progress$active_position<-if(is.null(current))NULL else current
  s$progress$status_label<-label
  s$workflow_runs[[stage]]<-as.character(run_id)
  s
}
stage<-stage_from_changed()
if(!nzchar(stage)){
  cat("No relevant live-status stage detected; no-op.\n")
  quit(status=0)
}

if(stage=="W00"){
  ps<-changed[grepl("^docs/search_record/(full_search|fortnightly_update|ad_hoc)/.*\\.json$",changed)]
  recs<-list()
  for(p in ps){
    z<-tryCatch(fromJSON(p,simplifyVector=FALSE),error=function(e)NULL)
    if(!is.null(z)&&identical(as.character(z$schema_version),"1.2")&&!is.null(z$reported_search_results)) recs[[length(recs)+1L]]<-z
  }
  if(!length(recs)) stop("W00 change contained no v1.2 search records",call.=FALSE)
  parents<-vapply(recs,function(z)as.character(z$github$parent_workflow_run_id),character(1))
  tab<-sort(table(parents),decreasing=TRUE);parent<-names(tab)[[1L]]
  recs<-recs[parents==parent]
  baseline<-authoritative_w08()
  total<-sum(vapply(recs,function(z)as.integer(z$reported_search_results),integer(1)))
  dates<-as.Date(substr(vapply(recs,function(z)as.character(z$recorded_at_utc),character(1)),1,10))
  src<-setNames(lapply(recs,function(z)list(
    reported_search_results=as.integer(z$reported_search_results),
    successfully_downloaded_results=as.integer(z$successfully_downloaded_results)
  )),vapply(recs,function(z)as.character(z$source),character(1)))
  s<-list(
    schema="living-evidence-map-current-run-status-v1",
    update_id=paste0("w00-run-",parent),
    branch="workflow01-final-architecture",
    started_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ"),
    last_updated_at_utc=NULL,
    baseline=list(workflow08_pointer=baseline$pointer,workflow08_source_run_id=baseline$run_id,
                  canonical_records=baseline$records,canonical_sha256=baseline$sha256),
    search=list(workflow00_run_id=parent,search_date=as.character(max(dates,na.rm=TRUE)),
                search_results=total,sources=src),
    cohort=list(record_ids_path=ids_path,record_ids_sha256=NULL,deduplicated_records=NULL),
    counts=list(search_results=total,deduplicated_records=NULL,enriched_records=NULL,
                retraction_exclusions=NULL,screened_include=NULL,screened_exclude=NULL,
                geography=list(with=NULL,without=NULL),topics=list(with=NULL,without=NULL)),
    progress=progress(1L,2L),
    workflow_runs=list(W00=parent)
  )
  s$progress$current_stage<-"W00";s$progress$completed_through<-1L;s$progress$active_position<-2L
  s$progress$status_label<-"Search complete; awaiting deduplication"
  if(file.exists(ids_path)) unlink(ids_path)
  save_status(s)
  cat(sprintf("PASS: W00 live status initialised for %s with %d search results\n",parent,total))
  quit(status=0)
}

s<-load_status()
if(is.null(s)){
  cat(sprintf("No current_run_status.json exists; ignoring %s historical/provenance update.\n",stage))
  quit(status=0)
}

if(stage=="W01"){
  row<-latest_row("docs/deduplication/zenodo_registry.csv")
  if(!as.character(row$state[[1L]]) %in% c("delta","final")) stop("Latest W01 registry row is not final/delta",call.=FALSE)
  run_id<-as.character(row$github_run_id[[1L]])
  ptr<-sprintf("docs/deduplication/zenodo/run-%s.json",run_id)
  p<-fromJSON(ptr,simplifyVector=FALSE)
  if(!identical(as.character(p$state),"delta")) stop("Live cohort derivation currently requires a W01 delta",call.=FALSE)
  ex<-download_archive(ptr,tempfile("w01_delta_"))
  dm<-list.files(ex,pattern="^delta_manifest\\.json$",recursive=TRUE,full.names=TRUE)
  cm<-list.files(ex,pattern="^cluster_map_upserts\\.csv$",recursive=TRUE,full.names=TRUE)
  nf<-list.files(ex,pattern="_new\\.jsonl$",recursive=TRUE,full.names=TRUE)
  if(length(dm)!=1L||length(cm)!=1L||!length(nf)) stop("W01 delta lacks cohort derivation inputs",call.=FALSE)
  m<-fromJSON(dm[[1L]],simplifyVector=FALSE)
  keys<-character()
  for(f in nf){
    src<-sub("_new\\.jsonl$","",basename(f))
    rows<-read_jsonl(f)
    ids<-vapply(rows,function(r){
      if(identical(src,"lens")) clean((r$identity%||%list())$lens_id %||% (r$identity%||%list())$record_id)
      else clean((r$sidecar_identity%||%list())$sidecar_record_id)
    },character(1))
    if(any(!nzchar(ids))) stop("New W01 manifestation lacks source ID for ",src,call.=FALSE)
    keys<-c(keys,paste(src,ids,sep="::"))
  }
  map<-read.csv(cm[[1L]],stringsAsFactors=FALSE,check.names=FALSE)
  map$key<-paste(map$source,map$source_record_id,sep="::")
  hit<-map[map$key%in%keys,,drop=FALSE]
  if(nrow(hit)!=length(unique(keys))) stop(sprintf("Mapped %d/%d new manifestation keys to final clusters",nrow(hit),length(unique(keys))),call.=FALSE)
  ids<-sort(unique(as.character(hit$cluster_id)))
  dir.create(dirname(ids_path),recursive=TRUE,showWarnings=FALSE);writeLines(ids,ids_path,useBytes=TRUE)
  s$cohort$record_ids_sha256<-digest(file=ids_path,algo="sha256",serialize=FALSE)
  s$cohort$deduplicated_records<-length(ids)
  s$counts$deduplicated_records<-length(ids)
  s<-set_run(s,"W01",run_id,2L,3L,"Deduplication complete; awaiting enrichment")
  save_status(s)
  cat(sprintf("PASS: W01 current-run cohort = %d canonical record IDs from %d new manifestations\n",length(ids),length(unique(keys))))
  quit(status=0)
}

ids<-cohort_ids()
if(!length(ids)) stop("Current-run cohort is empty or missing before ",stage,call.=FALSE)

if(stage=="W02"){
  row<-latest_row("docs/enrichment/zenodo_registry.csv");run_id<-as.character(row$github_run_id[[1L]])
  ptr<-sprintf("docs/enrichment/zenodo/run-%s.json",run_id)
  out<-tempfile("w02_");dir.create(out)
  st<-system2("Rscript",c("scripts/updater/workflow_02_restore_state_from_zenodo.R","--pointer",ptr,"--output-dir",out))
  if(st!=0L) stop("Failed restoring W02 state",call.=FALSE)
  p<-list.files(out,pattern="^cumulative_patch\\.jsonl$",recursive=TRUE,full.names=TRUE)
  if(length(p)!=1L) stop("Restored W02 state lacks cumulative_patch.jsonl",call.=FALSE)
  rr<-read_jsonl(p[[1L]])
  enriched<-sum(vapply(rr,function(z){
    rid<-clean(z$record_id); rid%in%ids && (!is.null(z$title)||!is.null(z$abstract)||!is.null(z$author_keywords))
  },logical(1)))
  s$counts$enriched_records<-as.integer(enriched)
  s<-set_run(s,"W02",run_id,3L,4L,"Enrichment complete; awaiting retraction screening")
  save_status(s);cat(sprintf("PASS: W02 current-run enriched records = %d\n",enriched));quit(status=0)
}

if(stage=="W03"){
  row<-latest_row("docs/publication_status/zenodo_registry.csv");run_id<-as.character(row$source_github_run_id[[1L]])
  ptr<-sprintf("docs/publication_status/zenodo/run-%s.json",run_id)
  out<-tempfile("w03_");dir.create(out)
  st<-system2("Rscript",c("scripts/updater/workflow_03_restore_state_from_zenodo.R","--pointer",ptr,"--output-dir",out))
  if(st!=0L) stop("Failed restoring W03 state",call.=FALSE)
  rr<-read_jsonl(file.path(out,"publication_status.jsonl"))
  n<-sum(vapply(rr,function(z)clean(z$record_id)%in%ids && isTRUE(z$publication_status$exclude_from_workflow04),logical(1)))
  s$counts$retraction_exclusions<-as.integer(n)
  s<-set_run(s,"W03",run_id,4L,5L,"Retraction screening complete; awaiting relevance screening")
  save_status(s);cat(sprintf("PASS: W03 current-run retraction/withdrawal exclusions = %d\n",n));quit(status=0)
}

if(stage=="W04"){
  row<-latest_row("docs/workflow04/zenodo_registry.csv");run_id<-as.character(row$source_github_run_id[[1L]])
  ptr<-sprintf("docs/workflow04/zenodo/run-%s.json",run_id)
  out<-tempfile("w04_");dir.create(out)
  st<-system2("Rscript",c("scripts/updater/workflow_04_restore_state_from_zenodo.R","--pointer",ptr,"--output-dir",out))
  if(st!=0L) stop("Failed restoring W04 state",call.=FALSE)
  p<-list.files(out,pattern="^workflow04_final_screening_layer\\.jsonl$",recursive=TRUE,full.names=TRUE)
  if(length(p)!=1L) stop("Restored W04 state lacks final screening layer",call.=FALSE)
  rr<-read_jsonl(p[[1L]])
  keep<-Filter(function(z)clean(z$record_id)%in%ids,rr)
  dec<-vapply(keep,function(z)clean(z$decision),character(1))
  s$counts$screened_include<-sum(dec=="retain");s$counts$screened_exclude<-sum(dec=="exclude")
  s<-set_run(s,"W04",run_id,5L,6L,"Screening complete; awaiting species coding")
  save_status(s);cat(sprintf("PASS: W04 current-run screening include=%d exclude=%d\n",s$counts$screened_include,s$counts$screened_exclude));quit(status=0)
}

if(stage=="W05"){
  row<-latest_row("docs/workflow05/zenodo_registry.csv");run_id<-as.character(row$source_github_run_id[[1L]])
  s<-set_run(s,"W05",run_id,6L,7L,"Species coding complete; awaiting geography coding")
  save_status(s);cat("PASS: W05 live progress updated\n");quit(status=0)
}

if(stage=="W06"){
  row<-latest_row("docs/workflow06/zenodo_registry.csv");run_id<-as.character(row$source_github_run_id[[1L]])
  ptr<-sprintf("docs/workflow06/zenodo/run-%s.json",run_id)
  out<-tempfile("w06_");dir.create(out)
  st<-system2("Rscript",c("scripts/updater/workflow_06_restore_state_from_zenodo.R","--pointer",ptr,"--output-dir",out))
  if(st!=0L) stop("Failed restoring W06 state",call.=FALSE)
  p<-list.files(out,pattern="^workflow06_geography_layer\\.csv$",recursive=TRUE,full.names=TRUE)
  g<-read.csv(p[[1L]],stringsAsFactors=FALSE,check.names=FALSE);g<-g[as.character(g$record_id)%in%ids,,drop=FALSE]
  with<-sum(as.character(g$geography_status)=="RESOLVED");without<-nrow(g)-with
  s$counts$geography<-list(with=as.integer(with),without=as.integer(without))
  s<-set_run(s,"W06",run_id,7L,8L,"Geography coding complete; awaiting topic coding")
  save_status(s);cat(sprintf("PASS: W06 current-run geography With=%d Without=%d\n",with,without));quit(status=0)
}

if(stage=="W07"){
  row<-latest_row("docs/workflow07/zenodo_registry.csv");run_id<-as.character(row$source_github_run_id[[1L]])
  ptr<-sprintf("docs/workflow07/zenodo/run-%s.json",run_id)
  out<-tempfile("w07_");dir.create(out)
  st<-system2("Rscript",c("scripts/updater/workflow_07_restore_state_from_zenodo.R","--pointer",ptr,"--output-dir",out))
  if(st!=0L) stop("Failed restoring W07 state",call.=FALSE)
  p<-list.files(out,pattern="^workflow07_topic_record_qc\\.csv$",recursive=TRUE,full.names=TRUE)
  q<-read.csv(p[[1L]],stringsAsFactors=FALSE,check.names=FALSE);q<-q[as.character(q$record_id)%in%ids,,drop=FALSE]
  tc<-suppressWarnings(as.integer(q$topic_count_retained));tc[is.na(tc)]<-0L
  with<-sum(tc>0L);without<-sum(tc==0L)
  s$counts$topics<-list(with=as.integer(with),without=as.integer(without))
  s<-set_run(s,"W07",run_id,8L,9L,"Topic coding complete; awaiting final adjudication")
  save_status(s);cat(sprintf("PASS: W07 current-run topics With=%d Without=%d\n",with,without));quit(status=0)
}

if(stage=="W08"){
  reg<-read.csv("docs/workflow08/zenodo_registry.csv",stringsAsFactors=FALSE,check.names=FALSE)
  hit<-reg[as.character(reg$status)=="authoritative",,drop=FALSE]
  if(nrow(hit)!=1L) stop("Expected exactly one authoritative W08 row",call.=FALSE)
  run_id<-as.character(hit$source_run_id[[1L]])
  ptr<-sprintf("docs/workflow08/zenodo/run-%s.json",run_id)
  out<-tempfile("w08_");dir.create(out)
  canon<-file.path(out,"canonical.jsonl")
  st<-system2("Rscript",c("scripts/updater/workflow_10_restore_canonical_from_zenodo.R","--pointer",ptr,"--output",canon))
  if(st!=0L) stop("Failed restoring W08 canonical",call.=FALSE)
  rr<-read_jsonl(canon);rr<-Filter(function(z)clean((z$identity%||%list())$record_id)%in%ids,rr)
  gw<-sum(vapply(rr,function(z)identical(clean((z$geography%||%list())$status),"RESOLVED"),logical(1)))
  tw<-sum(vapply(rr,function(z)length((z$topics%||%list())$path_ids%||%character())>0L,logical(1)))
  s$counts$geography<-list(with=as.integer(gw),without=as.integer(length(rr)-gw))
  s$counts$topics<-list(with=as.integer(tw),without=as.integer(length(rr)-tw))
  s<-set_run(s,"W08",run_id,9L,10L,"Final adjudication complete; awaiting dashboard build")
  save_status(s);cat(sprintf("PASS: W08 final current-run geography With=%d Without=%d; topics With=%d Without=%d\n",gw,length(rr)-gw,tw,length(rr)-tw));quit(status=0)
}

if(stage=="W10"){
  s<-set_run(s,"W10",Sys.getenv("GITHUB_RUN_ID",""),10L,NULL,"Current update complete")
  save_status(s);cat("PASS: W10 current-run progress complete\n");quit(status=0)
}

stop("Unsupported stage: ",stage,call.=FALSE)

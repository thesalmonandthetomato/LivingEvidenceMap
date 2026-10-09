#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(readr);library(dplyr);library(jsonlite);library(digest)})

args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
current_path<-arg("--current")
prior_path<-arg("--prior-geography","")
prior_canonical_path<-arg("--prior-canonical","")
output_dir<-arg("--output-dir","outputs/workflow06_prepare")
if(is.null(current_path)||!file.exists(current_path))stop("--current records_for_geography.csv is required",call.=FALSE)
if(nzchar(prior_path)&&!file.exists(prior_path))stop("Prior geography layer not found",call.=FALSE)
if(nzchar(prior_canonical_path)&&!file.exists(prior_canonical_path))stop("Prior canonical input not found",call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

current<-read_csv(current_path,show_col_types=FALSE,progress=FALSE)
req<-c("record_sequence","record_id","title","abstract","geography_input_sha256",
       "deterministic_primary_countries","deterministic_primary_iso3c","geography_review_required","geography_review_reason")
miss<-setdiff(req,names(current));if(length(miss))stop("Current W06 input missing columns: ",paste(miss,collapse=", "),call.=FALSE)
if(any(!nzchar(current$record_id))||anyDuplicated(current$record_id)||anyDuplicated(current$record_sequence))stop("Current W06 identity/sequence invariant failed",call.=FALSE)

mode<-"first_run";prior<-tibble();prior_fp<-character()
if(nzchar(prior_path)){
  mode<-"update"
  prior<-read_csv(prior_path,show_col_types=FALSE,progress=FALSE)
  if(!"record_id"%in%names(prior)||any(!nzchar(prior$record_id))||anyDuplicated(prior$record_id))stop("Prior W06 identity invariant failed",call.=FALSE)
  if("geography_input_sha256"%in%names(prior)){
    prior_fp<-setNames(as.character(prior$geography_input_sha256),prior$record_id)
    prior_fp[is.na(prior_fp)]<-""
  }else prior_fp<-setNames(rep("",nrow(prior)),prior$record_id)

  missing_fp<-names(prior_fp)[!nzchar(prior_fp)]
  if(length(missing_fp)){
    if(!nzchar(prior_canonical_path))stop(sprintf("Prior W06 layer lacks fingerprints for %d records; --prior-canonical required for bootstrap",length(missing_fp)),call.=FALSE)
    lines<-readLines(prior_canonical_path,warn=FALSE,encoding="UTF-8");lines<-lines[nzchar(trimws(lines))]
    `%||%`<-function(x,y)if(is.null(x))y else x
    scalar<-function(x){if(is.null(x)||!length(x))return("");z<-as.character(x[[1L]]);if(is.na(z))"" else trimws(z)}
    fp<-function(t,a)digest(toJSON(list(title=t,abstract=a),auto_unbox=TRUE,null="null",na="null"),algo="sha256",serialize=FALSE)
    ids<-character(length(lines));fps<-character(length(lines))
    for(i in seq_along(lines)){
      r<-fromJSON(lines[[i]],simplifyVector=FALSE)
      ids[[i]]<-scalar((r$identity%||%list())$record_id)
      fps[[i]]<-fp(scalar((r$canonical%||%list())$title),scalar((r$canonical%||%list())$abstract))
    }
    if(any(!nzchar(ids))||anyDuplicated(ids))stop("Prior canonical identity invariant failed",call.=FALSE)
    fmap<-setNames(fps,ids)
    absent<-setdiff(missing_fp,names(fmap));if(length(absent))stop(sprintf("Prior canonical lacks %d W06 records needed for fingerprint bootstrap",length(absent)),call.=FALSE)
    prior_fp[missing_fp]<-fmap[missing_fp]
  }
}

current_fp<-setNames(as.character(current$geography_input_sha256),current$record_id)
prior_ids<-if(nrow(prior))as.character(prior$record_id)else character()
known<-intersect(current$record_id,prior_ids)
new_ids<-setdiff(current$record_id,prior_ids)
changed_ids<-known[current_fp[known]!=prior_fp[known]]
reuse_ids<-setdiff(known,changed_ids)
queue_ids<-c(new_ids,changed_ids)

queue<-current |> filter(record_id%in%queue_ids) |> arrange(record_sequence)

reuse<-if(length(reuse_ids)){
  p<-prior |> filter(record_id%in%reuse_ids)
  cur<-current |> filter(record_id%in%reuse_ids) |>
    select(record_id,record_sequence,title,abstract,geography_input_sha256,
           deterministic_primary_countries,deterministic_primary_iso3c,geography_review_required,geography_review_reason)
  semantic_cols<-setdiff(names(p),c("record_sequence","title","abstract","geography_input_sha256",
                                    "deterministic_primary_countries","deterministic_primary_iso3c",
                                    "geography_review_required","geography_review_reason"))
  p |> select(all_of(semantic_cols)) |> right_join(cur,by="record_id") |> arrange(record_sequence)
}else current[0,,drop=FALSE]

write_csv(queue,file.path(output_dir,"screen_queue_records.csv"),na="")
write_csv(queue |> select(record_id,deterministic_primary_countries,deterministic_primary_iso3c,geography_review_required,geography_review_reason),
          file.path(output_dir,"screen_queue_deterministic.csv"),na="")
write_csv(reuse,file.path(output_dir,"reused_geography.csv"),na="")

qreason<-tibble(record_id=queue$record_id,
                queue_reason=ifelse(queue$record_id%in%new_ids,"new_record_id","changed_title_abstract"),
                geography_input_sha256=queue$geography_input_sha256)
write_csv(qreason,file.path(output_dir,"screen_queue_manifest.csv"),na="")

manifest<-list(
  schema="living-evidence-map-workflow06-incremental-prepare-v1",
  status="PASS",mode=mode,current_records=nrow(current),prior_records=length(prior_ids),
  reusable_records=length(reuse_ids),screen_queue_records=nrow(queue),
  new_record_ids=length(new_ids),changed_title_abstract=length(changed_ids),
  prior_records_no_longer_current=length(setdiff(prior_ids,current$record_id)),
  fingerprint_fields=c("title","abstract"),
  current_input_sha256=digest(file=current_path,algo="sha256",serialize=FALSE),
  prior_geography_sha256=if(nzchar(prior_path))digest(file=prior_path,algo="sha256",serialize=FALSE)else NULL,
  generated_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
write_json(manifest,file.path(output_dir,"prepare_manifest.json"),auto_unbox=TRUE,pretty=TRUE)
cat(sprintf("PASS: W06 %s preparation current=%d reuse=%d screen=%d new=%d changed=%d\n",mode,nrow(current),length(reuse_ids),nrow(queue),length(new_ids),length(changed_ids)))

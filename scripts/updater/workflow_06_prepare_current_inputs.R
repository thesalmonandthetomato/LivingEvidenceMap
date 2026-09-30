#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(dplyr)
  library(jsonlite)
  library(readr)
  library(tibble)
  library(digest)
})

source("scripts/setup_pipeline.R")
source("R/geography_detect.R")
source("R/geography_primary_country.R")

args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
input_path<-arg("--input")
output_dir<-arg("--output-dir","outputs/workflow06_deterministic")
if(is.null(input_path)||!file.exists(input_path))stop("Valid --input canonical JSONL is required",call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

`%||%`<-function(x,y)if(is.null(x))y else x
scalar<-function(x){if(is.null(x)||!length(x))return("");z<-as.character(x[[1L]]);if(is.na(z))"" else trimws(z)}
read_jsonl<-function(path){
  x<-readLines(path,warn=FALSE,encoding="UTF-8");x<-x[nzchar(trimws(x))]
  lapply(seq_along(x),function(i)fromJSON(x[[i]],simplifyVector=FALSE))
}
fingerprint<-function(title,abstract){
  digest(toJSON(list(title=title,abstract=abstract),auto_unbox=TRUE,null="null",na="null"),algo="sha256",serialize=FALSE)
}

can<-read_jsonl(input_path)
if(!length(can))stop("Input canonical JSONL is empty",call.=FALSE)
records<-tibble(
  record_sequence=seq_along(can),
  record_id=vapply(can,function(r)scalar((r$identity%||%list())$record_id),character(1)),
  title=vapply(can,function(r)scalar((r$canonical%||%list())$title),character(1)),
  abstract=vapply(can,function(r)scalar((r$canonical%||%list())$abstract),character(1))
)
if(any(!nzchar(records$record_id))||anyDuplicated(records$record_id))stop("Stable record_id invariant failed",call.=FALSE)
records$geography_input_sha256<-mapply(fingerprint,records$title,records$abstract,USE.NAMES=FALSE)

gazetteer<-read_csv("config/global_country_gazetteer_v3.csv",show_col_types=FALSE,progress=FALSE)
mentions<-detect_geography_mentions(records |> select(record_sequence,record_id,title,abstract),gazetteer,progress=TRUE)
if(nrow(mentions)){
  geo<-assign_primary_country(mentions)
}else{
  geo<-list(summary=tibble(record_id=character(),review_required=logical(),review_reason=character(),primary_countries=character(),primary_iso3c=character()))
}

summary<-records |> select(record_id) |>
  left_join(
    geo$summary |>
      transmute(
        record_id=as.character(record_id),
        deterministic_primary_countries=coalesce(as.character(primary_countries),""),
        deterministic_primary_iso3c=coalesce(as.character(primary_iso3c),""),
        geography_review_required=review_required %in% TRUE,
        geography_review_reason=coalesce(as.character(review_reason),"")
      ),
    by="record_id"
  ) |>
  mutate(
    deterministic_primary_countries=coalesce(deterministic_primary_countries,""),
    deterministic_primary_iso3c=coalesce(deterministic_primary_iso3c,""),
    geography_review_required=coalesce(geography_review_required,FALSE),
    geography_review_reason=coalesce(geography_review_reason,"")
  )

out<-records |> left_join(summary,by="record_id")
stopifnot(nrow(out)==nrow(records),!anyDuplicated(out$record_id))
write_csv(out,file.path(output_dir,"records_for_geography.csv"),na="")
write_csv(mentions,file.path(output_dir,"geography_mentions.csv"),na="")
write_csv(out |> select(record_id,deterministic_primary_countries,deterministic_primary_iso3c,geography_review_required,geography_review_reason),
          file.path(output_dir,"deterministic_geography.csv"),na="")
write_json(list(
  schema="living-evidence-map-workflow06-deterministic-input-v1",
  records=nrow(out),
  canonical_input_sha256=digest(file=input_path,algo="sha256",serialize=FALSE),
  geography_fingerprint_fields=c("title","abstract"),
  generated_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
),file.path(output_dir,"manifest.json"),auto_unbox=TRUE,pretty=TRUE)
cat(sprintf("PASS: prepared deterministic geography comparator for %d records\n",nrow(out)))

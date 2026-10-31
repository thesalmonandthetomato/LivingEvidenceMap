#!/usr/bin/env Rscript
# W08b monthly release selector. Read-only, checksum/pointer consistency gate.
# Usage: resolve_monthly_release.R current_status.json w08_registry.csv w01_pointer_dir expected_YYYY-MM output.json
suppressPackageStartupMessages(library(jsonlite))
a<-commandArgs(trailingOnly=TRUE)
if(length(a)!=5L)stop("Usage: resolve_monthly_release.R status.json w08_registry.csv w01_pointer_dir YYYY-MM output.json")
status_path<-a[[1]];registry_path<-a[[2]];w01_dir<-a[[3]];month<-a[[4]];out<-a[[5]]
if(!grepl("^[0-9]{4}-(0[1-9]|1[0-2])$",month))stop("Expected month must be YYYY-MM")
if(!file.exists(status_path)||!file.exists(registry_path)||!dir.exists(w01_dir))stop("Missing current release inputs")
status<-fromJSON(status_path,simplifyVector=FALSE)
scalar<-function(x){z<-as.character(unlist(x,recursive=TRUE,use.names=FALSE));if(length(z)!=1L||is.na(z)||!nzchar(z))stop("Missing or invalid release scalar");z}
if(!identical(scalar(status$branch),"workflow01-final-architecture"))stop("Unexpected production working branch")
date<-scalar(status$search$search_date)
if(!grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$",date)||substr(date,1,7)!=month)stop("Refusing to use a release outside the requested month")
update_id<-scalar(status$update_id)
if(!grepl("^[A-Za-z0-9._-]+$",update_id))stop("Invalid monthly update ID")
run01<-scalar(status$workflow_runs$W01)
run08<-scalar(status$workflow_runs$W08)
if(!grepl("^[0-9]+$",run01)||!grepl("^[0-9]+$",run08))stop("Invalid workflow run identifier")
p01<-file.path(w01_dir,paste0("run-",run01,".json"))
if(!file.exists(p01))stop("Published W01 pointer missing")
w01<-fromJSON(p01,simplifyVector=FALSE)
reg<-read.csv(registry_path,stringsAsFactors=FALSE,check.names=FALSE)
chosen<-reg[reg$status=="authoritative",,drop=FALSE]
if(nrow(chosen)!=1L||as.character(chosen$source_run_id[[1]])!=run08)stop("W08 authority does not match current-run status")
p08<-file.path(dirname(registry_path),"zenodo",paste0("run-",run08,".json"))
if(!file.exists(p08))stop("Published authoritative W08 pointer missing")
w08<-fromJSON(p08,simplifyVector=FALSE)
if(!identical(scalar(w01$status),"published") ||
   !identical(scalar(w08$status),"published") ||
   !identical(scalar(w08$state),"corrected_final_adjudicated_canonical") ||
   !identical(scalar(w08$source_github_run_id),run08))stop("Release pointer status/identity mismatch")
w01_n<-as.integer(scalar(w01$canonical_records))
included<-as.integer(scalar(w08$canonical_records))
excluded<-as.integer(scalar(w08$excluded_records))
total<-as.integer(scalar(w08$source_canonical_population))
if(anyNA(c(w01_n,included,excluded,total))||included<1L||excluded<0L||
   total!=w01_n||included+excluded!=total)stop("W01/W08 record counts do not reconcile")
sha<-tolower(scalar(w08$final_canonical_jsonl_sha256))
if(!grepl("^[0-9a-f]{64}$",sha)||
   !identical(tolower(scalar(chosen$canonical_sha256[[1]])),sha))stop("W08 canonical checksum mismatch")
result<-list(schema="workflow08b-monthly-release-selection-v1",
  mode="preflight_only",update_id=update_id,update_month=month,
  search_date=date,w01_pointer=p01,w08_pointer=p08,
  w01_run_id=run01,w08_run_id=run08,
  w01_canonical_records=w01_n,w08_included_seeds=included,
  w08_excluded_records=excluded,w08_canonical_sha256=sha,
  source_records_unchanged=TRUE,provider_calls_authorised=FALSE,
  w01_handoff_authorised=FALSE)
dir.create(dirname(out),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(result,auto_unbox=TRUE,pretty=TRUE,null="null"),out)
cat("PASS: verified W08b source snapshot for ",month,": ",included,
    " seeds, W01 ",w01_n,", W08 SHA ",sha,"\n",sep="")

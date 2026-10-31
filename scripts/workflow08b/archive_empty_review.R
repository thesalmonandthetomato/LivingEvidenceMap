#!/usr/bin/env Rscript
# Archive a verified zero-ambiguity W08b review as a restricted, zero-decision
# receipt, allowing automated W01 canonical handoff without fake human decisions.
suppressPackageStartupMessages({library(jsonlite);library(httr2)})
a<-commandArgs(trailingOnly=TRUE)
if(length(a)!=2L)stop("Usage: archive_empty_review.R review_queue_manifest.json receipt.json")
q<-fromJSON(a[[1]],simplifyVector=FALSE)
if(!identical(q$schema,"w08b-human-review-queue-v1")||
 !identical(q$status,"no_review_required")||as.integer(q$case_count)!=0L)
 stop("This script is only for verified zero-ambiguity W08b batches")
batch<-as.character(q$batch_id)
sha<-as.character(q$queue_sha256)
if(!grepl("^w08b-no-human-review-[a-f0-9]{12}$",batch)||
 !grepl("^[a-f0-9]{64}$",sha)||!identical(substr(sha,1L,12L),sub("^w08b-no-human-review-","",batch)))
 stop("Invalid deterministic empty queue identity")
stage<-tempfile("w08b-empty-review-")
dir.create(stage);on.exit(unlink(stage,recursive=TRUE),add=TRUE)
write.csv(data.frame(batch_id=character(),queue_sha256=character(),
 case_index=character(),review_case_id=character(),case_json=character()),
 file.path(stage,"queue.csv"),row.names=FALSE)
write.csv(data.frame(review_case_id=character(),decision=character(),
 target_w01_id=character(),queue_sha256=character()),
 file.path(stage,"decisions.csv"),row.names=FALSE)
write.csv(data.frame(review_case_id=character(),source_kind=character(),
 source_record_id=character(),action=character(),value=character(),
 queue_sha256=character()),
 file.path(stage,"abstract_repairs.csv"),row.names=FALSE)
manifest<-list(schema="w08b-human-decision-export-v1",batch_id=batch,
 queue_sha256=sha,cases=0L,decision_count=0L,abstract_repairs=0L,
 no_human_review_required=TRUE,provider_bibliographies_unchanged=TRUE)
writeLines(toJSON(manifest,auto_unbox=TRUE,pretty=TRUE),
 file.path(stage,"manifest.json"))
if(identical(Sys.getenv("W08B_TEST_EMPTY_REVIEW",""),"1")){
 dir.create(dirname(a[[2]]),recursive=TRUE,showWarnings=FALSE)
 writeLines(toJSON(list(schema="w08b-empty-review-fixture-v1",
  status="fixture_only_no_zenodo_upload",manifest=manifest),
  auto_unbox=TRUE,pretty=TRUE),a[[2]])
 cat("PASS: validated zero-review export schema; no Zenodo call\n")
 quit(status=0L)
}
token<-Sys.getenv("ZENODO_ACCESS_TOKEN","")
if(!nzchar(token))stop("Missing restricted Zenodo token")
zipfile<-tempfile(fileext=".zip");on.exit(unlink(zipfile),add=TRUE)
old<-setwd(stage)
tryCatch(utils::zip(zipfile,files=c("queue.csv","decisions.csv",
 "abstract_repairs.csv","manifest.json")),finally=setwd(old))
if(!file.exists(zipfile)||file.info(zipfile)$size<100L)stop("Cannot package zero-review receipt")
base<-"https://zenodo.org/api/deposit/depositions"
post<-request(base)|>req_auth_bearer_token(token)|>
 req_body_json(list(metadata=list(title=paste("W08b zero-review verified handoff",batch),
  upload_type="dataset",
  description="Restricted verified W08b zero-ambiguity export. No human decisions or repairs were needed.",
  creators=list(list(name="LivingEvidenceMap project")),
  access_right="restricted",access_conditions="Derived publisher metadata source identifiers.")))|>
 req_timeout(120)|>req_perform()|>resp_body_json(simplifyVector=FALSE)
bucket<-as.character(post$links$bucket %||% "")
if(!nzchar(bucket))stop("Zenodo did not return an upload bucket")
`%||%`<-function(x,y)if(is.null(x)||!length(x))y else x
r<-request(paste0(sub("/$","",bucket),"/w08b-human-decisions.zip"))|>
 req_method("PUT")|>req_auth_bearer_token(token)|>
 req_body_file(zipfile,type="application/octet-stream")|>
 req_timeout(900)|>req_perform()
if(resp_status(r)>=300L)stop("Restricted empty review upload failed")
published<-request(paste0(base,"/",post$id,"/actions/publish"))|>
 req_method("POST")|>req_auth_bearer_token(token)|>
 req_headers(`Content-Type`="application/json")|>
 req_body_raw(charToRaw("{}"),type="application/json")|>
 req_timeout(180)|>req_perform()|>resp_body_json(simplifyVector=FALSE)
id<-as.character(published$id %||% "")
if(!grepl("^[0-9]+$",id))stop("Invalid restricted review publication receipt")
receipt<-list(schema="w08b-human-decision-receipt-v1",
 batch_id=batch,queue_sha256=sha,cases=0L,decisions=0L,
 restricted_zenodo_record_id=id,zero_review_verified=TRUE,status="published")
dir.create(dirname(a[[2]]),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(receipt,auto_unbox=TRUE,pretty=TRUE),a[[2]])
cat("PASS: restricted, zero-review W08b handoff archived; no human decision was fabricated\n")

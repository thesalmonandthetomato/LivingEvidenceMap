#!/usr/bin/env Rscript
# Authoritative W08b decision export. No historical W01 mutation or upstream rerun.
suppressPackageStartupMessages({
  library(googlesheets4); library(jsonlite); library(digest); library(httr2)
})
`%||%` <- function(x,y) if(is.null(x) || length(x)==0L) y else x
env <- function(k) { x <- Sys.getenv(k,""); if(!nzchar(x)) stop("Missing environment variable: ",k); x }
batch <- env("W08B_BATCH_ID")
sha <- env("W08B_QUEUE_SHA")
if(!grepl("^[0-9a-f]{64}$",sha) || !grepl("^[A-Za-z0-9._-]{5,160}$",batch))
  stop("Invalid immutable queue identifiers")
credential <- env("LEM_GOOGLE_SERVICE_ACCOUNT_JSON")
tmp <- tempfile("w08b_credentials_")
on.exit(unlink(tmp),add=TRUE)
if(!file.exists(credential)) { writeLines(credential,tmp); Sys.chmod(tmp,"0600"); credential <- tmp }
gs4_auth(path=credential,cache=FALSE)
ss <- env("LEM_GOOGLE_SHEET_ID")
q <- as.data.frame(read_sheet(ss,sheet="queue_w08b_dedup_active",col_types="c"))
required_q <- c("batch_id","queue_sha256","case_index","review_case_id","case_json")
stopifnot(all(required_q %in% names(q)),nrow(q)>0L,all(q$batch_id==batch),all(q$queue_sha256==sha),
          !anyDuplicated(q$review_case_id),!anyNA(as.integer(q$case_index)))
q <- q[order(as.integer(q$case_index)),,drop=FALSE]
computed <- digest(paste0(paste(q$case_json,collapse="\n"),"\n"),algo="sha256",serialize=FALSE)
if(!identical(computed,sha))stop("Queue checksum mismatch")
decisions <- as.data.frame(read_sheet(ss,sheet="decisions_w08b_dedup",col_types="c"))
need <- c("queue_sha256","review_case_id","decision","reviewer","decided_at_utc","target_w01_id")
if(!all(need %in% names(decisions)))stop("Decision registry schema mismatch")
d <- decisions[decisions$queue_sha256==sha,,drop=FALSE]
if(nrow(d)!=nrow(q) || anyDuplicated(d$review_case_id) ||
   !setequal(d$review_case_id,q$review_case_id) ||
   any(!d$decision %in% c("same_publication","different_publications","unable_to_determine")))
   stop("Incomplete or duplicated W08b decisions; export denied")
tabs <- googlesheets4::sheet_names(ss)
repairs <- if("repairs_w08b_dedup" %in% tabs)
  as.data.frame(read_sheet(ss,sheet="repairs_w08b_dedup",col_types="c")) else data.frame()
if(nrow(repairs)){
  if(!all(c("queue_sha256","review_case_id","source_kind","source_record_id","action","value")%in%names(repairs)))
    stop("Abstract repair schema mismatch")
  repairs <- repairs[repairs$queue_sha256==sha,,drop=FALSE]
  if(any(!repairs$review_case_id %in% q$review_case_id))stop("Abstract repair references unknown case")
}
stage <- tempfile("w08b_private_")
dir.create(stage)
on.exit(unlink(stage,recursive=TRUE),add=TRUE)
write.csv(q,file.path(stage,"queue.csv"),row.names=FALSE,na="")
write.csv(d,file.path(stage,"decisions.csv"),row.names=FALSE,na="")
write.csv(repairs,file.path(stage,"abstract_repairs.csv"),row.names=FALSE,na="")
manifest <- list(schema="w08b-human-decision-export-v1",batch_id=batch,queue_sha256=sha,
                 cases=nrow(q),decision_count=nrow(d),abstract_repairs=nrow(repairs),
                 exported_at_utc=format(Sys.time(),"%Y-%m-%dT%H:%M:%SZ",tz="UTC"))
writeLines(toJSON(manifest,auto_unbox=TRUE,pretty=TRUE),file.path(stage,"manifest.json"))
zipfile <- tempfile(fileext=".zip")
on.exit(unlink(zipfile),add=TRUE)
old <- setwd(stage)
tryCatch(utils::zip(zipfile,files=c("queue.csv","decisions.csv","abstract_repairs.csv","manifest.json")),
         finally=setwd(old))
if(!file.exists(zipfile)||file.info(zipfile)$size<100L)stop("Failed to create private export archive")
token <- env("ZENODO_ACCESS_TOKEN")
base <- "https://zenodo.org/api/deposit/depositions"
message("ZENODO_STAGE=create_deposition")
post <- request(base) |> req_auth_bearer_token(token) |> req_body_json(list(metadata=list(
  title=paste("W08b citation-chasing human adjudication",batch),
  upload_type="dataset",description="Restricted adjudication, audited abstract repairs and queue provenance.",
  creators=list(list(name="LivingEvidenceMap project")),
  access_right="closed"))) |> req_perform() |> resp_body_json(simplifyVector=FALSE)
bucket <- as.character(post$links$bucket %||% "")
if(!nzchar(bucket))stop("Zenodo deposition did not return a bucket")
message("ZENODO_STAGE=upload_file")
upload <- request(paste0(bucket,"/w08b-human-decisions.zip")) |>
  req_method("PUT") |> req_auth_bearer_token(token) |>
  req_body_file(zipfile,type="application/octet-stream") |> req_perform()
if(resp_status(upload) >= 300L)stop("Zenodo upload failed")
message("ZENODO_STAGE=publish_deposition")
publish <- request(paste0(base,"/",post$id,"/actions/publish")) |>
  req_method("POST") |> req_auth_bearer_token(token) |>
  req_headers(`Content-Type`="application/json") |>
  req_body_raw(charToRaw("{}"),type="application/json") |> req_perform() |> resp_body_json(simplifyVector=FALSE)
receipt <- list(schema="w08b-human-decision-receipt-v1",batch_id=batch,queue_sha256=sha,
  cases=nrow(q),decisions=nrow(d),restricted_zenodo_record_id=publish$id,
  doi=publish$doi %||% "",status=publish$state %||% "")
writeLines(toJSON(receipt,pretty=TRUE,auto_unbox=TRUE), "w08b_export_receipt.json")
cat("PASS: verified",nrow(d),"human decisions, archived in restricted Zenodo record",publish$id,"\n")

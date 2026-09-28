#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(httr2);library(jsonlite);library(digest)})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
canonical <- arg("--canonical")
exclusions <- arg("--exclusions")
ledger <- arg("--ledger")
manifest <- arg("--manifest")
source_run_id <- arg("--source-run-id")
repository <- arg("--repository")
output_dir <- arg("--output-dir")
supersedes_doi <- arg("--supersedes-doi","10.5281/zenodo.22998934")
if(any(vapply(list(canonical,exclusions,ledger,manifest,source_run_id,repository,output_dir),is.null,logical(1)))) stop("Required W08 resume arguments missing",call.=FALSE)
for(p in c(canonical,exclusions,ledger,manifest)) if(!file.exists(p)) stop("Missing W08 resume file: ",p,call.=FALSE)

m <- fromJSON(manifest,simplifyVector=FALSE)
if(!identical(m$status,"PASS") ||
   as.integer(m$canonical_records)!=19117L ||
   as.integer(m$excluded_records)!=13175L ||
   as.integer(m$w08_decision_issues)!=811L ||
   !identical(m$canonical_contains_excluded_records,FALSE)) stop("Workflow 08 manifest is not validated",call.=FALSE)

actual_sha <- tolower(digest(file=canonical,algo="sha256",serialize=FALSE))
expected_sha <- tolower(as.character(m$final_canonical_jsonl_sha256))
if(!identical(actual_sha,expected_sha)) stop(sprintf("Canonical SHA mismatch: expected %s found %s",expected_sha,actual_sha),call.=FALSE)
if(unname(file.info(canonical)$size)!=as.numeric(m$final_canonical_jsonl_bytes)) stop("Canonical byte-count mismatch",call.=FALSE)

dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)
gz_path <- file.path(output_dir,paste0(basename(canonical),".gz"))
cat(sprintf("Compressing canonical JSONL: %.1f MB\n",unname(file.info(canonical)$size)/1e6))
in_con <- file(canonical,"rb")
out_con <- gzfile(gz_path,"wb",compression=9)
on.exit({try(close(in_con),silent=TRUE);try(close(out_con),silent=TRUE)},add=TRUE)
repeat {
  buf <- readBin(in_con,"raw",n=1024L*1024L)
  if(!length(buf)) break
  writeBin(buf,out_con)
}
close(in_con); close(out_con); on.exit(NULL,add=FALSE)
gz_sha <- tolower(digest(file=gz_path,algo="sha256",serialize=FALSE))
cat(sprintf("Compressed canonical: %.1f MB; SHA256=%s\n",unname(file.info(gz_path)$size)/1e6,gz_sha))

token <- Sys.getenv("ZENODO_ACCESS_TOKEN")
if(!nzchar(token)) stop("ZENODO_ACCESS_TOKEN is not set",call.=FALSE)
api <- "https://zenodo.org/api/deposit/depositions"
auth <- function(req) req |> req_headers(Authorization=paste("Bearer",token))
perform <- function(req,expected,label,timeout=600){
  resp <- req |> req_timeout(timeout) |> req_error(is_error=function(resp)FALSE) |> req_perform()
  st <- resp_status(resp)
  if(!(st %in% expected)){
    body <- tryCatch(resp_body_string(resp),error=function(e)"")
    stop(sprintf("Zenodo %s HTTP %d: %s",label,st,body),call.=FALSE)
  }
  resp
}

metadata <- list(metadata=list(
  title=sprintf("Living Evidence Map Workflow 08 lossless final canonical dataset | source run %s",source_run_id),
  upload_type="dataset",
  publication_date=format(Sys.Date(),"%Y-%m-%d"),
  description=paste0(
    "<p>Lossless definitive post-adjudication output for the Living Evidence Map after Workflows 03-08.</p>",
    "<p>The final canonical contains ",m$canonical_records," included records and preserves upstream publication-status, species, geography and topic annotation provenance. ",
    "The canonical JSONL is gzip-compressed for transfer; its uncompressed SHA-256 is recorded in the manifest and receipt.</p>",
    "<p>The ",m$excluded_records," excluded records are supplied separately as bibliographic metadata plus final exclusion stage and reason.</p>",
    "<p>This deposit supersedes the previous Workflow 08 canonical (",supersedes_doi,").</p>"
  ),
  creators=list(list(name="Haddaway, Neal")),
  access_right="restricted",
  access_conditions="The canonical dataset contains bibliographic metadata and provider-derived content whose redistribution may be restricted by source terms.",
  keywords=list("Living Evidence Map","Workflow 08","canonical JSONL","lossless provenance","salmon aquaculture",paste0("LivingEvidenceMap-workflow08-lossless-source-run-",source_run_id))
))

created <- perform(
  request(api) |> req_method("POST") |> auth() |> req_headers("Content-Type"="application/json") |> req_body_raw(charToRaw("{}"),type="application/json"),
  201L,"draft creation",60
) |> resp_body_json(simplifyVector=FALSE)
dep_id <- as.character(created$id)
bucket <- as.character(created$links$bucket)
cat(sprintf("Created Zenodo draft deposition %s\n",dep_id))

perform(
  request(paste0(api,"/",dep_id)) |> req_method("PUT") |> auth() |> req_headers("Content-Type"="application/json") |> req_body_json(metadata,auto_unbox=TRUE),
  200L,"metadata update",60
)

files <- c(gz_path,exclusions,ledger,manifest)
uploaded <- vector("list",length(files))
for(i in seq_along(files)){
  p <- files[[i]]
  fn <- basename(p)
  cat(sprintf("Uploading %s (%.1f MB)\n",fn,unname(file.info(p)$size)/1e6))
  ok <- NULL
  for(attempt in seq_len(6L)){
    cat(sprintf("  attempt %d/6...\n",attempt))
    resp <- request(paste0(bucket,"/",URLencode(fn,reserved=TRUE))) |>
      req_method("PUT") |> auth() |> req_headers(Expect="") |> req_body_file(p) |>
      req_timeout(900) |> req_error(is_error=function(resp)FALSE) |> req_perform()
    st <- resp_status(resp)
    if(st %in% c(200L,201L)){ok<-resp;cat(sprintf("  uploaded %s successfully\n",fn));break}
    cat(sprintf("  Zenodo returned HTTP %d for %s\n",st,fn))
    if(!(st %in% c(408L,429L,500L,502L,503L,504L))||attempt==6L) stop(sprintf("W08 resume upload failed for %s HTTP %d",fn,st),call.=FALSE)
    Sys.sleep(min(90,5*2^(attempt-1L)))
  }
  uploaded[[i]] <- resp_body_json(ok,simplifyVector=FALSE)
}

published <- perform(
  request(paste0(api,"/",dep_id,"/actions/publish")) |> req_method("POST") |> auth(),
  c(200L,201L,202L),"publish",120
) |> resp_body_json(simplifyVector=FALSE)

record_id <- as.character(if(is.null(published$record_id)) published$id else published$record_id)
receipt <- list(
  status="published",
  workflow="08",
  state="corrected_final_adjudicated_canonical",
  annotation_preservation=as.character(m$annotation_preservation),
  supersedes_zenodo_record_id="22998934",
  supersedes_doi=supersedes_doi,
  source_github_run_id=as.character(source_run_id),
  source_github_run_url=sprintf("https://github.com/%s/actions/runs/%s",repository,source_run_id),
  publication_github_run_id=Sys.getenv("GITHUB_RUN_ID"),
  publication_github_run_url=sprintf("https://github.com/%s/actions/runs/%s",repository,Sys.getenv("GITHUB_RUN_ID")),
  source_canonical_population=as.integer(m$source_canonical_population),
  canonical_records=as.integer(m$canonical_records),
  excluded_records=as.integer(m$excluded_records),
  w08_decision_issues=as.integer(m$w08_decision_issues),
  final_canonical_jsonl_sha256=expected_sha,
  final_canonical_jsonl_bytes=as.numeric(m$final_canonical_jsonl_bytes),
  canonical_archive_filename=basename(gz_path),
  canonical_archive_compression="gzip",
  canonical_archive_sha256=gz_sha,
  canonical_archive_bytes=unname(file.info(gz_path)$size),
  excluded_records_csv_sha256=as.character(m$excluded_records_csv_sha256),
  adjudication_ledger_sha256=as.character(m$adjudication_ledger_sha256),
  zenodo_record_id=record_id,
  zenodo_deposition_id=dep_id,
  doi=if(is.null(published$doi)) NA_character_ else published$doi,
  record_url=if(!is.null(published$links$html)) published$links$html else paste0("https://zenodo.org/records/",record_id),
  visibility="restricted",
  files=lapply(seq_along(files),function(i){
    p<-files[[i]];z<-uploaded[[i]]
    list(filename=basename(p),bytes=unname(file.info(p)$size),sha256=digest(file=p,algo="sha256",serialize=FALSE),zenodo_checksum=if(is.null(z$checksum))NULL else z$checksum)
  }),
  published_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
writeLines(toJSON(receipt,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),file.path(output_dir,"zenodo_receipt.json"),useBytes=TRUE)
cat(sprintf("PASS: published lossless Workflow 08 archive as Zenodo record %s; DOI=%s\n",record_id,receipt$doi))

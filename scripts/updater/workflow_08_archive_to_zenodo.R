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
supersedes_doi <- arg("--supersedes-doi","10.5281/zenodo.22998606")
if(any(vapply(list(canonical,exclusions,ledger,manifest,source_run_id,repository,output_dir),is.null,logical(1)))) stop("Required W08 Zenodo arguments missing",call.=FALSE)
for(p in c(canonical,exclusions,ledger,manifest)) if(!file.exists(p)) stop("Missing W08 archive file: ",p,call.=FALSE)

m <- fromJSON(manifest,simplifyVector=FALSE)
source_n <- suppressWarnings(as.integer(m$source_canonical_population))
included_n <- suppressWarnings(as.integer(m$canonical_records))
excluded_n <- suppressWarnings(as.integer(m$excluded_records))
decision_n <- suppressWarnings(as.integer(m$w08_decision_issues))
if(!identical(m$status,"PASS") ||
   any(is.na(c(source_n,included_n,excluded_n,decision_n))) ||
   any(c(source_n,included_n,excluded_n,decision_n) < 0L) ||
   source_n != included_n + excluded_n ||
   !identical(m$canonical_contains_excluded_records,FALSE)) {
  stop("Workflow 08 manifest failed dynamic publication invariants",call.=FALSE)
}
expected_sha <- c(
  canonical=as.character(m$final_canonical_jsonl_sha256),
  exclusions=as.character(m$excluded_records_csv_sha256),
  ledger=as.character(m$adjudication_ledger_sha256)
)
actual_sha <- c(
  canonical=digest(file=canonical,algo="sha256",serialize=FALSE),
  exclusions=digest(file=exclusions,algo="sha256",serialize=FALSE),
  ledger=digest(file=ledger,algo="sha256",serialize=FALSE)
)
if(any(!nzchar(expected_sha)) || !identical(tolower(actual_sha),tolower(expected_sha))) {
  stop("Workflow 08 archive inputs do not match manifest checksums",call.=FALSE)
}

token <- Sys.getenv("ZENODO_ACCESS_TOKEN")
if(!nzchar(token)) stop("ZENODO_ACCESS_TOKEN is not set",call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)
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
  title=sprintf("Living Evidence Map Workflow 08 corrected final canonical dataset | run %s",source_run_id),
  upload_type="dataset",
  publication_date=format(Sys.Date(),"%Y-%m-%d"),
  description=paste0(
    "<p>Corrected definitive post-adjudication output for the Living Evidence Map after Workflows 03-08.</p>",
    "<p>The canonical JSONL contains only the ",m$canonical_records," final included records. ",
    "The ",m$excluded_records," excluded records are supplied separately as bibliographic metadata plus final exclusion stage and reason.</p>",
    "<p>This archive supersedes Workflow 08 Zenodo record 22998606 (",supersedes_doi,"), whose canonical JSONL incorrectly retained excluded records.</p>",
    "<p>The deposit also contains the complete machine-readable Workflow 08 adjudication ledger and checksum/provenance manifest.</p>"
  ),
  creators=list(list(name="Haddaway, Neal")),
  access_right="restricted",
  access_conditions="The canonical dataset contains bibliographic metadata and provider-derived content whose redistribution may be restricted by source terms.",
  keywords=list("Living Evidence Map","Workflow 08","human adjudication","canonical JSONL","exclusions","salmon aquaculture",paste0("LivingEvidenceMap-workflow08-corrected-run-",source_run_id))
))

created <- perform(
  request(api) |> req_method("POST") |> auth() |> req_headers("Content-Type"="application/json") |> req_body_raw(charToRaw("{}"),type="application/json"),
  201L,"draft creation",60
) |> resp_body_json(simplifyVector=FALSE)
dep_id <- as.character(created$id)
bucket <- as.character(created$links$bucket)

perform(
  request(paste0(api,"/",dep_id)) |> req_method("PUT") |> auth() |> req_headers("Content-Type"="application/json") |> req_body_json(metadata,auto_unbox=TRUE),
  200L,"metadata update",60
)

files <- c(canonical,exclusions,ledger,manifest)
uploaded <- vector("list",length(files))
for(i in seq_along(files)){
  p <- files[[i]]
  fn <- basename(p)
  ok <- NULL
  for(attempt in seq_len(5L)){
    resp <- request(paste0(bucket,"/",URLencode(fn,reserved=TRUE))) |>
      req_method("PUT") |> auth() |> req_headers(Expect="") |> req_body_file(p) |>
      req_timeout(1800) |> req_error(is_error=function(resp)FALSE) |> req_perform()
    st <- resp_status(resp)
    if(st %in% c(200L,201L)){ok<-resp;break}
    if(!(st %in% c(429L,500L,502L,503L,504L))||attempt==5L) stop(sprintf("W08 archive upload failed for %s HTTP %d",fn,st),call.=FALSE)
    Sys.sleep(min(60,5*2^(attempt-1L)))
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
  supersedes_zenodo_record_id="22998606",
  supersedes_doi=supersedes_doi,
  source_github_run_id=as.character(source_run_id),
  source_github_run_url=sprintf("https://github.com/%s/actions/runs/%s",repository,source_run_id),
  source_canonical_population=as.integer(m$source_canonical_population),
  canonical_records=as.integer(m$canonical_records),
  excluded_records=as.integer(m$excluded_records),
  w08_decision_issues=as.integer(m$w08_decision_issues),
  final_canonical_jsonl_sha256=as.character(m$final_canonical_jsonl_sha256),
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
cat(sprintf("PASS: published corrected Workflow 08 archive as Zenodo record %s; DOI=%s\n",record_id,receipt$doi))

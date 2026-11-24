#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
  library(digest)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}

pointer_path <- arg("--pointer")
output_root <- arg("--output-root")
if (is.null(pointer_path)||is.null(output_root)) stop("Required: --pointer --output-root",call.=FALSE)
if (!file.exists(pointer_path)) stop("Workflow 01 Zenodo pointer not found",call.=FALSE)
token <- Sys.getenv("ZENODO_ACCESS_TOKEN")
if (!nzchar(token)) stop("ZENODO_ACCESS_TOKEN is required",call.=FALSE)

x <- fromJSON(pointer_path,simplifyVector=FALSE)
if (!identical(x$status,"published")) stop("Workflow 01 pointer is not published",call.=FALSE)
if (!identical(x$visibility,"restricted")) stop("Expected restricted Workflow 01 archive",call.=FALSE)
dep_id <- as.character(x$zenodo_deposition_id)
if (!nzchar(dep_id)) stop("Pointer lacks zenodo_deposition_id",call.=FALSE)

files <- x$archive_files
if (is.data.frame(files)) files <- lapply(seq_len(nrow(files)),function(i)as.list(files[i,,drop=FALSE]))
if (is.list(files)&&!is.null(files$filename)) files <- list(files)
if (!length(files)) stop("Pointer lacks archive_files",call.=FALSE)

expected <- lapply(files,function(z)list(
  filename=as.character(z$filename),
  bytes=as.numeric(z$bytes),
  sha256=as.character(z$sha256),
  zenodo_checksum=if(is.null(z$zenodo_checksum)) NA_character_ else as.character(z$zenodo_checksum)
))
names(expected) <- vapply(expected,function(z)z$filename,character(1))

api <- paste0("https://zenodo.org/api/deposit/depositions/",dep_id)
auth <- function(req) req |> req_headers(Authorization=paste("Bearer",token))

# Retry transient Zenodo deposition API errors (including 502/504), not just
# archive-file transfers. Never retry permission/record errors such as 401/404.
zenodo_get_deposition <- function(api, label) {
  max_attempts <- 5L
  for (attempt in seq_len(max_attempts)) {
    failure <- NULL
    response <- tryCatch(
      request(api) |> auth() |> req_timeout(120) |>
        req_error(is_error=function(resp)FALSE) |> req_perform(),
      error=function(e) {failure <<- conditionMessage(e); NULL}
    )
    status <- if(is.null(response)) NA_integer_ else resp_status(response)
    if(!is.null(response) && status==200L){
      dep <- tryCatch(resp_body_json(response,simplifyVector=FALSE),
                      error=function(e) stop(sprintf("Invalid Zenodo deposition JSON for %s: %s",
                                  label,conditionMessage(e)),call.=FALSE))
      if(!is.list(dep)) stop(sprintf("Unexpected Zenodo deposition response for %s",label),call.=FALSE)
      cat(sprintf("PASS: Zenodo deposition metadata %s attempt=%d/%d\\n",
                  label,attempt,max_attempts))
      return(dep)
    }
    if(is.null(failure)) failure <- sprintf("HTTP %s",if(is.na(status))"unknown" else as.character(status))
    transient <- is.na(status) || status %in% c(408L,425L,429L,500L,502L,503L,504L)
    if(identical(status,403L)) return(NULL)
    if(!transient || attempt==max_attempts){
      stop(sprintf("Zenodo deposition metadata %s failed after %d attempt(s): %s",
                   label,attempt,failure),call.=FALSE)
    }
    retry_after <- if(!is.null(response)) suppressWarnings(as.numeric(resp_header(response,"retry-after"))) else NA_real_
    delay <- if(length(retry_after)==1L && is.finite(retry_after) && retry_after>0) min(120,retry_after) else min(60,3*2^(attempt-1L))
    cat(sprintf("RETRY: Zenodo deposition metadata %s attempt=%d/%d reason=%s delay_seconds=%s\\n",
                label,attempt,max_attempts,failure,format(delay)))
    flush.console()
    Sys.sleep(delay)
  }
}

dep <- zenodo_get_deposition(api,dep_id)
if (!is.null(dep) && !isTRUE(dep$submitted)) stop("Zenodo Workflow 01 deposition is not published",call.=FALSE)
bucket <- if(is.null(dep$links$bucket)) "" else as.character(dep$links$bucket)
record_id <- as.character(x$zenodo_record_id)
stopifnot(length(record_id)==1L,grepl("^[0-9]+$",record_id))
if(!grepl("^https://zenodo[.]org/api/files/",bucket)) bucket <- ""

dir.create(output_root,recursive=TRUE,showWarnings=FALSE)
download_dir <- file.path(output_root,".workflow01_zenodo_download")
dir.create(download_dir,recursive=TRUE,showWarnings=FALSE)

download_one <- function(e) {
  dest <- file.path(download_dir,e$filename)
  record_url <- paste0("https://zenodo.org/api/records/",record_id,"/files/",URLencode(e$filename,reserved=TRUE),"/content")
  url <- if(nzchar(bucket)) paste0(sub("/$","",bucket),"/",URLencode(e$filename,reserved=TRUE)) else record_url
  max_attempts <- 5L
  for(attempt in seq_len(max_attempts)){
    if(file.exists(dest)) unlink(dest)
    failure <- NULL
    response <- tryCatch(
      request(url) |> req_method("GET") |> auth() |> req_timeout(1800) |>
        req_error(is_error=function(resp)FALSE) |> req_perform(path=dest),
      error=function(err){failure <<- conditionMessage(err);NULL}
    )
    status <- if(is.null(response)) NA_integer_ else resp_status(response)
    if(identical(status,403L) && !identical(url,record_url)){
      message("Legacy file endpoint refused access; trying authenticated published-record endpoint")
      url <- record_url
      if(file.exists(dest)) unlink(dest)
      next
    }
    transient <- is.na(status) || status %in% c(200L,408L,425L,429L,500L,502L,503L,504L)
    if(!is.null(response) && status==200L && file.exists(dest)){
      bytes <- unname(file.info(dest)$size)
      if(!identical(as.numeric(bytes),as.numeric(e$bytes))){
        failure <- sprintf("byte-size mismatch expected=%s actual=%s",e$bytes,bytes)
      } else {
        actual_sha <- digest(file=dest,algo="sha256",serialize=FALSE)
        if(!identical(tolower(actual_sha),tolower(e$sha256))){
          failure <- sprintf("SHA-256 mismatch expected=%s actual=%s",e$sha256,actual_sha)
        } else if(!is.na(e$zenodo_checksum)&&nzchar(e$zenodo_checksum)){
          expected_md5 <- sub("^md5:","",tolower(e$zenodo_checksum))
          actual_md5 <- digest(file=dest,algo="md5",serialize=FALSE)
          if(!identical(actual_md5,expected_md5)){
            failure <- sprintf("MD5 mismatch expected=%s actual=%s",expected_md5,actual_md5)
          }
        }
      }
      if(is.null(failure)){
        cat(sprintf("PASS: verified Zenodo W01 baseline file %s attempt=%d/%d\\n",
                    e$filename,attempt,max_attempts))
        return(dest)
      }
    } else if(is.null(failure)){
      failure <- sprintf("HTTP %s",if(is.na(status))"unknown" else as.character(status))
    }
    if(file.exists(dest)) unlink(dest)
    if(!transient || attempt==max_attempts){
      stop(sprintf("Zenodo W01 baseline file %s failed after %d attempt(s): %s",
                   e$filename,attempt,failure),call.=FALSE)
    }
    retry_after <- if(!is.null(response)) suppressWarnings(as.numeric(resp_header(response,"retry-after"))) else NA_real_
    delay <- if(length(retry_after)==1L && is.finite(retry_after) && retry_after>0) min(120,retry_after) else min(60,3*2^(attempt-1L))
    cat(sprintf("RETRY: Zenodo W01 baseline file %s attempt=%d/%d reason=%s delay_seconds=%s\\n",
                e$filename,attempt,max_attempts,failure,format(delay)))
    flush.console()
    Sys.sleep(delay)
  }
  stop(sprintf("Zenodo W01 baseline file %s was not verified",e$filename),call.=FALSE)
}

local <- lapply(expected,download_one)
manifest_ix <- grep("_manifest\\.json$",basename(unlist(local)))
if (length(manifest_ix)!=1L) stop("Expected exactly one Workflow 01 manifest",call.=FALSE)
manifest_path <- unlist(local)[manifest_ix]
manifest_sha <- digest(file=manifest_path,algo="sha256",serialize=FALSE)
if (!is.null(x$manifest_sha256)&&!identical(tolower(manifest_sha),tolower(as.character(x$manifest_sha256)))) {
  stop("Workflow 01 manifest SHA-256 does not match repository pointer",call.=FALSE)
}

tar_paths <- unlist(local)[grepl("\\.tar\\.gz$",unlist(local))]
for (p in tar_paths) utils::untar(p,exdir=output_root)

audit <- list(
  schema="living-evidence-map-workflow01-zenodo-restore-audit-v1",
  status="success",
  state=as.character(x$state),
  source_workflow01_run_id=as.character(x$github_run_id),
  zenodo_record_id=as.character(x$zenodo_record_id),
  doi=as.character(x$doi),
  pointer=basename(pointer_path),
  manifest_sha256=manifest_sha,
  restored_files=vapply(expected,function(z)z$filename,character(1))
)
writeLines(toJSON(audit,auto_unbox=TRUE,pretty=TRUE,null="null"),
           file.path(output_root,"workflow01_zenodo_restore_audit.json"))
cat(sprintf("PASS: restored Workflow 01 %s state from Zenodo record %s\n",
            audit$state,audit$zenodo_record_id))

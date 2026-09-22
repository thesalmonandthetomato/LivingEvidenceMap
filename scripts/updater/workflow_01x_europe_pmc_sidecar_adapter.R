#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(jsonlite))

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}
input_dir <- arg("--input-dir","inputs/europe_pmc_ingestion")
output_dir <- arg("--output-dir","outputs/updater/europe_pmc_sidecar_adapter")
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

`%||%` <- function(x,y) if (is.null(x)) y else x
now_utc <- function() format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
scalar <- function(x) {
  if (is.null(x)||length(x)==0L) return(NULL)
  y <- trimws(as.character(x[[1L]]))
  if (!nzchar(y)) NULL else y
}
extract_values <- function(x,child) {
  if (is.null(x)||!is.list(x)||is.null(x[[child]])) return(NULL)
  vals <- x[[child]]
  out <- unname(vapply(vals,function(z) if(is.list(z)) scalar(z)%||%"" else as.character(z),character(1)))
  out <- out[nzchar(out)]
  if(!length(out)) NULL else out
}

raw_files <- sort(list.files(file.path(input_dir,"raw"),pattern="^response_[0-9]{6}\\.json$",full.names=TRUE))
if(!length(raw_files)) stop("No Europe PMC raw JSON files found",call.=FALSE)
records <- list()
for(rf in raw_files) {
  x <- fromJSON(rf,simplifyVector=FALSE)
  records <- c(records,x$resultList$result %||% list())
}
if(!length(records)) stop("No Europe PMC records to adapt",call.=FALSE)

adapted_at <- now_utc()
out <- vector("list",length(records))
rows <- vector("list",length(records))
for(i in seq_along(records)) {
  r <- records[[i]]
  src <- scalar(r$source)
  id <- scalar(r$id)
  if(is.null(src)||is.null(id)) stop(sprintf("Missing source/id at record %d",i),call.=FALSE)
  doi <- scalar(r$doi)
  title <- scalar(r$title)
  abstract <- scalar(r$abstractText)
  year <- scalar(r$pubYear)
  journal <- scalar(r$journalTitle)
  if(is.null(journal)&&is.list(r$journalInfo)) journal <- scalar(r$journalInfo$journal$title)
  pubtype <- extract_values(r$pubTypeList,"pubType")
  keywords <- extract_values(r$keywordList,"keyword")
  authors <- NULL
  if(is.list(r$authorList)&&!is.null(r$authorList$author)) {
    authors <- lapply(r$authorList$author,function(a) list(
      full_name=scalar(a$fullName)%||%scalar(a$collectiveName),
      first_name=scalar(a$firstName),
      last_name=scalar(a$lastName),
      initials=scalar(a$initials),
      author_id=scalar(a$authorId)
    ))
  }
  key <- paste(src,id,sep=":")
  sidecar_id <- paste0("europe_pmc:",tolower(src),":",id)
  out[[i]] <- list(
    sidecar_identity=list(sidecar_record_id=sidecar_id,europe_pmc_source=src,europe_pmc_id=id,source_record_key=key,doi=doi),
    source=list(provider="europe_pmc",source_format="europe_pmc_rest_core_json",source_collection="Europe PMC publications"),
    europe_pmc=list(raw_payload=r),
    mapped_fields=list(
      title=title,abstract=abstract,authors=authors,year=year,source=journal,doi=doi,
      keywords=keywords,publication_type=pubtype,author_string=scalar(r$authorString),
      affiliation=scalar(r$affiliation),language=scalar(r$language),
      first_publication_date=scalar(r$firstPublicationDate),pmid=scalar(r$pmid),pmcid=scalar(r$pmcid)
    ),
    provenance=list(adapter_workflow="workflow_01x_europe_pmc_sidecar_adapter",
                    implementation_language="R",adapted_at=adapted_at,
                    canonical_json_modified=FALSE,downstream_workflows_modified=FALSE)
  )
  rows[[i]] <- data.frame(
    sidecar_record_id=sidecar_id,source_record_key=key,doi=doi%||%NA_character_,
    title=title%||%NA_character_,abstract_present=!is.null(abstract),
    authors_present=!is.null(authors)&&length(authors)>0L,year=year%||%NA_character_,
    source=journal%||%NA_character_,keywords_present=!is.null(keywords)&&length(keywords)>0L,
    stringsAsFactors=FALSE
  )
}
ids <- vapply(out,function(x)x$sidecar_identity$sidecar_record_id,character(1))
if(anyDuplicated(ids)) stop("Duplicate Europe PMC sidecar IDs",call.=FALSE)

con <- file(file.path(output_dir,"europe_pmc_sidecar_records.jsonl"),"wt",encoding="UTF-8")
for(r in out) writeLines(toJSON(r,auto_unbox=TRUE,null="null",na="null",digits=NA),con)
close(con)
cov <- do.call(rbind,rows)
write.csv(cov,file.path(output_dir,"field_coverage_records.csv"),row.names=FALSE,na="")
present <- function(x)!is.na(x)&nzchar(as.character(x))
pct <- function(x)round(100*mean(x),1)
audit <- list(
  workflow="workflow_01x_europe_pmc_sidecar_adapter",status="success",created_at=adapted_at,
  input=list(source="Europe PMC REST API",records_read=length(records)),
  output=list(sidecar_jsonl="europe_pmc_sidecar_records.jsonl",field_coverage_csv="field_coverage_records.csv",
              canonical_json_modified=FALSE,canonical_branch_written=FALSE,downstream_workflows_modified=FALSE),
  identifier_checks=list(unique_sidecar_ids=length(unique(ids)),duplicate_sidecar_ids=anyDuplicated(ids),
                         doi_present_n=sum(present(cov$doi)),doi_missing_n=sum(!present(cov$doi))),
  mapped_field_coverage_percent=list(title=pct(present(cov$title)),abstract=pct(cov$abstract_present),
                                     authors=pct(cov$authors_present),year=pct(present(cov$year)),
                                     source=pct(present(cov$source)),doi=pct(present(cov$doi)),
                                     keywords=pct(cov$keywords_present)),
  canonical_schema_compatibility=list(
    safely_mappable_now=c("title","abstract","authors","year","source","doi","keywords","publication_type"),
    source_specific_identity="Europe PMC source + id",
    note="Europe PMC remains a distinct source manifestation namespace; no canonical schema change is required."
  )
)
writeLines(toJSON(audit,auto_unbox=TRUE,pretty=TRUE,null="null"),file.path(output_dir,"compatibility_audit.json"))
message(sprintf("PASS: wrote %d Europe PMC sidecar records; canonical JSON untouched.",length(out)))

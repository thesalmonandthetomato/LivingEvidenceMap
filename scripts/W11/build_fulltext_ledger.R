#!/usr/bin/env Rscript
# W11 independent, read-only canonical-to-full-text ledger builder.
# No publication, retrieval, pipeline dispatch or edits to canonical records.
suppressPackageStartupMessages(library(jsonlite))
argv <- commandArgs(trailingOnly=TRUE)
option <- function(flag,default="") { p<-match(flag,argv); if(is.na(p)||p==length(argv)) default else argv[p+1L] }
canonical_path<-option("--canonical")
retrieval_path<-option("--retrieval")
outdir<-option("--output","outputs/W11/ledger")
if(!file.exists(canonical_path)) stop("Canonical JSONL must be supplied via --canonical")
if(!file.exists(retrieval_path)) stop("Historical DOI manifest missing: ",retrieval_path)
dir.create(outdir,recursive=TRUE,showWarnings=FALSE)
normalize_doi<-function(z) {
 if(is.null(z)||!length(z)) return("")
 z<-as.character(z[[1]])
 z<-tolower(trimws(z))
 z<-sub("^https?://(dx\\.)?doi\\.org/","",z)
 z<-sub("^doi:\\s*","",z)
 sub("[[:space:]]+$","",z)
}
scalar<-function(z) if(is.null(z)||!length(z)) "" else if(is.list(z)) scalar(z[[1]]) else as.character(z[1])
find_first<-function(r,keys) {
 for(k in keys) if(!is.null(r[[k]])&&nzchar(scalar(r[[k]]))) return(scalar(r[[k]]))
 ""
}
extract_meta<-function(r) {
 nested<-r$canonical
 if(is.null(nested)||!is.list(nested)) nested<-r$metadata
 if(is.null(nested)||!is.list(nested)) nested<-list()
 doi<-find_first(r,c("doi","DOI","publication_doi","article_doi"))
 if(!nzchar(doi)) doi<-find_first(nested,c("doi","DOI"))
 title<-find_first(r,c("title","Title","record_title","publication_title"))
 if(!nzchar(title)) title<-find_first(nested,c("title","Title"))
 year<-find_first(r,c("year","publication_year","pub_year"))
 if(!nzchar(year)) year<-find_first(nested,c("year","publication_year"))
 oa<-find_first(r,c("openalex_id","openalex_work_id"))
 if(!nzchar(oa)) oa<-find_first(nested,c("openalex_id","openalex_work_id"))
 id<-find_first(r,c("canonical_id","canonical_record_id","record_id","record_uuid","id","unique_id"))
 if(!nzchar(id)) id<-find_first(r$identity,c("record_id","id"))
 if(!nzchar(id)) id<-find_first(nested,c("canonical_id","record_id","id"))
 list(doi=normalize_doi(doi),title=title,year=year,openalex_id=sub("^https?://openalex.org/","",oa),record_id=id)
}
lines<-readLines(canonical_path,warn=FALSE,encoding="UTF-8")
lines<-lines[nzchar(trimws(lines))]
if(!length(lines)) stop("Empty canonical JSONL")
`%||%`<-function(x,y) if(is.null(x)) y else x
records<-lapply(seq_along(lines),function(i) {
 x<-tryCatch(fromJSON(lines[[i]],simplifyVector=FALSE),error=function(e) stop("JSONL line ",i,": ",conditionMessage(e)))
 if(!is.list(x)) stop("Non-object JSONL at line ",i)
 m<-extract_meta(x)
 m$line<-i
 m$manifestation_dois<-unique(Filter(nzchar,vapply(x$manifestations %||% list(),function(z) normalize_doi(z$doi),character(1))))
 m$manifestation_openalex<-unique(Filter(nzchar,vapply(x$manifestations %||% list(),function(z) scalar((z$manifestation_metadata$identifiers %||% list())$openalex_id),character(1))))
 m
})
retrieval<-read.csv(retrieval_path,stringsAsFactors=FALSE,check.names=FALSE,colClasses="character")
required<-c("batch","github_run_id","zenodo_deposit_id","record_index","doi","openalex_id","format","source_url","status","bytes","sha256","filename")
if(!all(required %in% names(retrieval))) stop("Missing retrieval columns: ",paste(setdiff(required,names(retrieval)),collapse=", "))
retrieval$doi<-vapply(retrieval$doi,normalize_doi,character(1))
retrieval$openalex_id<-sub("^https?://openalex.org/","",retrieval$openalex_id)
retrieval$archive_filename<-sprintf("LivingEvidenceMap_fulltext_batch_%03d_run-%s.zip",as.integer(retrieval$batch),retrieval$github_run_id)
# Historical batches 1–5 used a different file naming convention in their earliest uploads.
early<-as.integer(retrieval$batch)<=5L
retrieval$archive_filename[early]<-sprintf("openalex_fulltext_batch_%03d.zip",as.integer(retrieval$batch[early]))
retrieval$zenodo_deposit_url<-paste0("https://zenodo.org/deposit/",retrieval$zenodo_deposit_id)
retrieval$zenodo_record_doi<-"" # Deposit ID is not a DOI. Populate only from independently verified Zenodo metadata.
retrieval$within_zip_filename<-retrieval$filename
retrieval$available<-retrieval$status %in% c("downloaded","already_present")
# One row per canonical record, including records without a matched full text.
items<-vector("list",length(records))
for(i in seq_along(records)) {
 r<-records[[i]]
 known_dois<-unique(Filter(nzchar,c(r$doi,r$manifestation_dois)))
 candidates<-which(retrieval$doi %in% known_dois & nzchar(retrieval$doi))
 method<-if(length(candidates)&&nzchar(r$doi)&&any(retrieval$doi[candidates]==r$doi)) "exact_normalized_doi" else if(length(candidates)) "manifestation_doi" else "unmatched"
 # OpenAlex ID is a supplementary identifier; never equate unverified ID matches with a verified DOI match.
 if(!length(candidates)&&nzchar(r$openalex_id)) {
   candidates<-which(retrieval$openalex_id==r$openalex_id)
   if(length(candidates)) method<-"openalex_id_needs_bibliographic_review"
 }
 confirmed<-length(candidates)==1L && retrieval$available[candidates] && method %in% c("exact_normalized_doi","manifestation_doi")
 if(length(candidates)>1L) method<-"ambiguous_multiple_retrievals"
 idx<-if(length(candidates)==1L) candidates else NA_integer_
 f<-function(col) if(is.na(idx)) "" else scalar(retrieval[[col]][idx])
 id<-if(nzchar(r$record_id)) r$record_id else sprintf("jsonl_line_%d",r$line)
 items[[i]]<-data.frame(canonical_record_id=id,canonical_jsonl_line=r$line,
   canonical_doi=r$doi,canonical_title=r$title,canonical_year=r$year,
   canonical_manifestation_dois=paste(r$manifestation_dois,collapse=";"),
   canonical_openalex_id=r$openalex_id,
   retrieval_doi=f("doi"),retrieval_openalex_id=f("openalex_id"),
   match_method=method,metadata_verification=if(confirmed) "canonical_or_manifestation_doi_verified_metadata_pending" else "needs_review",
   match_status=if(confirmed) "matched" else if(length(candidates)>1) "ambiguous" else "unmatched_or_review",
   retrieval_status=f("status"),source_format=f("format"),source_url=f("source_url"),
   zenodo_deposit_id=f("zenodo_deposit_id"),zenodo_record_doi=f("zenodo_record_doi"),
   zenodo_deposit_url=f("zenodo_deposit_url"),archive_filename=f("archive_filename"),
   within_zip_filename=f("within_zip_filename"),sha256=f("sha256"),
   retrieval_github_run_id=f("github_run_id"),retrieval_batch=f("batch"),
   fulltext_access_state=if(confirmed) "archive_location_recorded_not_content_reverified" else "not_linked",
   stringsAsFactors=FALSE)
}
ledger<-do.call(rbind,items)
# Strong metadata validation beyond DOI requires independent canonical/title/author/year source data;
# never fabricate a "verified" title match from DOI alone.
write.csv(ledger,file.path(outdir,"canonical_fulltext_ledger.csv"),row.names=FALSE,na="")
unmatched<-ledger[ledger$match_status!="matched",,drop=FALSE]
write.csv(unmatched,file.path(outdir,"review_queue.csv"),row.names=FALSE,na="")
matched<-ledger[ledger$match_status=="matched",,drop=FALSE]
used<-unique(paste(matched$retrieval_doi,matched$retrieval_openalex_id))
unused<-retrieval[!paste(retrieval$doi,retrieval$openalex_id) %in% used,,drop=FALSE]
write.csv(unused,file.path(outdir,"unlinked_retrievals.csv"),row.names=FALSE,na="")
summary<-list(canonical_jsonl=canonical_path,retrieval_manifest=retrieval_path,
 canonical_records=nrow(ledger),verified_doi_links=nrow(matched),
 metadata_review_required=nrow(unmatched),xml_links=sum(matched$source_format=="grobid_xml"),
 pdf_links=sum(matched$source_format=="pdf"),unlinked_retrieval_rows=nrow(unused),
 important_limitations=c(
 "DOI-only identity confirmation does not establish independent title/author verification.",
 "Canonical metadata matching by strong title/author/year evidence requires such metadata in a retrieval-side source.",
 "Zenodo deposition identifiers are recorded; Zenodo record DOI remains blank unless independently verified.",
 "ZIP filenames for early batches require verification against each Zenodo deposition's files.",
 "No source full texts were downloaded or modified."))
write_json(summary,file.path(outdir,"summary.json"),pretty=TRUE,auto_unbox=TRUE)
cat(toJSON(summary,pretty=TRUE,auto_unbox=TRUE),"\n")

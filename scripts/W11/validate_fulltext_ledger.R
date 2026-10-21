#!/usr/bin/env Rscript
# Validate links without re-downloading canonical records or full texts.
suppressPackageStartupMessages(library(jsonlite))
suppressPackageStartupMessages(library(httr2))
infile<-"initial/ledger/canonical_fulltext_ledger.csv"
if(!file.exists(infile)) stop("Missing initial canonical ledger artifact")
out<-"outputs/W11/validated"
dir.create(out,recursive=TRUE,showWarnings=FALSE)
x<-read.csv(infile,stringsAsFactors=FALSE,check.names=FALSE,colClasses="character")
if(nrow(x)!=50440L) stop("Canonical snapshot unexpectedly changed")
x[is.na(x)]<-""
linked<-x$match_status=="matched"
counts<-table(x$retrieval_doi[linked & nzchar(x$retrieval_doi)])
collision_dois<-names(counts[counts>1])
collision<-linked & x$retrieval_doi %in% collision_dois
ambiguous<-x$match_status=="ambiguous"
x$ledger_link_status<-ifelse(collision,"requires_review_cross_canonical_doi_collision",
  ifelse(ambiguous,"requires_review_multiple_retrieval_candidates",
    ifelse(linked,"accepted_doi_identity","no_confirmed_link")))
x$metadata_evidence_level<-ifelse(linked & x$canonical_openalex_id!="" &
 tolower(x$canonical_openalex_id)==tolower(x$retrieval_openalex_id),
 "doi_plus_openalex_work_id",
 ifelse(linked & x$canonical_doi!="" & tolower(x$canonical_doi)==tolower(x$retrieval_doi),
 "exact_canonical_doi_only",
 ifelse(linked,"manifestation_doi_only","not_verified")))
x$canonical_metadata_verified_independently<-FALSE
x$archive_file_verified_in_zenodo_metadata<-FALSE
x$archive_member_verified_within_zip<-FALSE
x$zenodo_record_doi_status<-"not_assessed"
x$zenodo_record_doi<-""
x$zenodo_record_url<-""
x$zenodo_record_state<-""
x$zenodo_archive_download_url<-""
token_candidates<-unique(Filter(nzchar,c(Sys.getenv("ZENODO_ACCESS_TOKEN"),Sys.getenv("ZENODO_TOKEN"))))
if(!length(token_candidates)) stop("No Zenodo read credential available")
get_deposit<-function(id) {
 for(tok in token_candidates) {
  u<-paste0("https://zenodo.org/api/deposit/depositions/",id)
  r<-tryCatch(req_perform(request(u) |> req_headers(Authorization=paste("Bearer",tok)) |> req_timeout(35)),error=function(e) NULL)
  if(!is.null(r)&&resp_status(r)<300) return(fromJSON(resp_body_string(r),simplifyVector=FALSE))
 }
 NULL
}
safe<-function(z) if(is.null(z)||!length(z)) "" else as.character(z[[1]])
ids<-sort(unique(x$zenodo_deposit_id[nzchar(x$zenodo_deposit_id)]))
archive<-vector("list",length(ids))
for(j in seq_along(ids)) {
 id<-ids[j]
 d<-get_deposit(id)
 fns<-if(is.null(d)||is.null(d$files)) character() else vapply(d$files,function(z)safe(z$filename),character(1))
 zips<-fns[grepl("\\.(zip|tar\\.gz)$",fns,ignore.case=TRUE)]
 doi<-if(is.null(d)) "" else safe(d$doi)
 status<-if(is.null(d)) "inaccessible" else if(nzchar(doi)) "minted" else "not_minted_or_not_returned"
 row<-which(x$zenodo_deposit_id==id)
 if(length(zips)==1L) {
  # Use file name from Zenodo itself, not a constructed guess.
  x$archive_filename[row]<-zips[[1]]
  x$archive_file_verified_in_zenodo_metadata[row]<-TRUE
  if(!is.null(d$files)) {
   idx<-match(zips[[1]],fns)
   if(!is.na(idx)) x$zenodo_archive_download_url[row]<-safe(d$files[[idx]]$links$download)
  }
 }
 x$zenodo_record_doi[row]<-doi
 x$zenodo_record_doi_status[row]<-status
 x$zenodo_record_url[row]<-paste0("https://zenodo.org/records/",id)
 x$zenodo_record_state[row]<-if(is.null(d)) "" else safe(d$state)
 archive[[j]]<-data.frame(zenodo_deposit_id=id,deposit_accessible=!is.null(d),
  zenodo_record_doi=doi,doi_status=status,verified_archive_filename=if(length(zips)==1L) zips[[1]] else "",
  file_count=length(fns),state=if(is.null(d)) "" else safe(d$state),
  stringsAsFactors=FALSE)
 if(j%%10L==0L) message("Verified Zenodo deposit metadata ",j,"/",length(ids))
}
arc<-do.call(rbind,archive)
# A one-to-one DOI match is accepted only when Zenodo confirms the archive file.
x$ledger_link_status[x$ledger_link_status=="accepted_doi_identity" & !x$archive_file_verified_in_zenodo_metadata]<-"requires_review_archive_unverified"
x$analysis_eligible<-x$ledger_link_status=="accepted_doi_identity" &
  x$source_format %in% c("grobid_xml","pdf")
x$analysis_preferred_format<-ifelse(x$analysis_eligible,x$source_format,"")
review<-x[grepl("^requires_review",x$ledger_link_status),,drop=FALSE]
write.csv(x,file.path(out,"canonical_fulltext_ledger.csv"),row.names=FALSE,na="")
write.csv(review,file.path(out,"identity_and_archive_review_queue.csv"),row.names=FALSE,na="")
write.csv(arc,file.path(out,"zenodo_archive_registry.csv"),row.names=FALSE,na="")
file.copy("initial/ledger/unlinked_retrievals.csv",file.path(out,"unlinked_retrievals.csv"),overwrite=TRUE)
summary<-list(canonical_records=nrow(x),
 accepted_links=sum(x$ledger_link_status=="accepted_doi_identity"),
 accepted_xml_links=sum(x$analysis_eligible & x$source_format=="grobid_xml"),
 accepted_pdf_links=sum(x$analysis_eligible & x$source_format=="pdf"),
 cross_canonical_conflicting_dois=length(collision_dois),
 canonical_rows_with_doi_collisions=sum(collision),
 multiple_retrieval_candidates=sum(ambiguous),
 manual_review_rows=nrow(review),
 unmatched_or_review=sum(x$ledger_link_status!="accepted_doi_identity"),
 zenodo_deposits_checked=nrow(arc),
 zenodo_deposits_with_minted_doi=sum(nzchar(arc$zenodo_record_doi)),
 archive_member_checks="not independently performed; member filenames retained from retrieval manifests",
 matching_policy="no cross-canonical DOI collision auto-accepted; explicit review queue",
 snapshot="W01 final canonical JSONL from Zenodo 23211736")
write_json(summary,file.path(out,"summary.json"),auto_unbox=TRUE,pretty=TRUE)
cat(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),"\n")

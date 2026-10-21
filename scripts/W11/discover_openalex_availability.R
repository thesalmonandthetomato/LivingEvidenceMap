#!/usr/bin/env Rscript
# W11 OpenAlex availability-only refresh. No full-text download, no Zenodo write.
suppressPackageStartupMessages(library(jsonlite))
suppressPackageStartupMessages(library(httr2))
input <- "input/ledger/canonical_fulltext_ledger.csv"
if(!file.exists(input)) stop("Missing pinned 22,911-record W11 ledger")
x <- read.csv(input,stringsAsFactors=FALSE,check.names=FALSE,colClasses="character")
x[is.na(x)] <- ""
if(nrow(x)!=22911L) stop("Unexpected canonical count: ",nrow(x))
key <- Sys.getenv("OPENALEX_API_KEY")
if(!nzchar(key)) stop("OPENALEX_API_KEY secret required")
out <- "outputs/W11/openalex_discovery"; dir.create(out,recursive=TRUE,showWarnings=FALSE)
normalize <- function(z) {
 z <- tolower(trimws(as.character(z)))
 z <- sub("^https?://(dx\\.)?doi\\.org/","",z)
 z <- sub("^doi:\\s*","",z)
 z
}
x$canonical_doi <- normalize(x$canonical_doi)
x$original_archive_known <- x$match_status=="matched" & nzchar(x$zenodo_deposit_id) &
   nzchar(x$within_zip_filename) & x$retrieval_status %in% c("downloaded","already_present")
# Detect reused DOI across canonical records, and do not treat these as definitive archive links.
ct <- table(x$retrieval_doi[x$original_archive_known])
bad <- names(ct)[ct>1L & nzchar(names(ct))]
x$historical_link_conflict <- x$retrieval_doi %in% bad & x$original_archive_known
x$historical_archive_link_accepted <- x$original_archive_known & !x$historical_link_conflict
x$requires_openalex_search <- !x$historical_archive_link_accepted
target <- which(x$requires_openalex_search)
x$openalex_search_status <- ifelse(x$requires_openalex_search,"not_attempted","existing_archive")
x$openalex_matched_doi <- "";x$openalex_discovered_work_id <- ""
x$openalex_title <- ""; x$openalex_publication_year <- ""
x$openalex_has_xml <- "";x$openalex_has_pdf <- ""
x$openalex_xml_url <- ""; x$openalex_pdf_url <- ""
x$openalex_identity_status <- "";x$next_action <- ""
# For DOI absent from canonical, use an explicit manifestation DOI only if exactly one unique DOI.
manifestation <- strsplit(x$canonical_manifestation_dois,";",fixed=TRUE)
lookup_doi <- character(nrow(x))
for(i in target) {
 opts <- unique(Filter(nzchar,c(x$canonical_doi[i],normalize(manifestation[[i]]))))
 if(length(opts)==1L) lookup_doi[i] <- opts
}
x$openalex_query_doi <- lookup_doi
x$openalex_search_status[target[!nzchar(lookup_doi[target])]] <- "no_unambiguous_doi"
valid <- target[nzchar(lookup_doi[target])]
# Query each DOI once; identical bibliographic DOIs are independently linked back to canonical identities.
queries <- unique(lookup_doi[valid])
chunk_size <- 50L
chunks <- split(queries,ceiling(seq_along(queries)/chunk_size))
results <- list()
fetch_chunk <- function(ds) {
 filter <- paste0("doi:",paste(paste0("https://doi.org/",ds),collapse="|"))
 request("https://api.openalex.org/works") |>
  req_url_query(filter=filter,per_page=100,
     select="id,doi,display_name,publication_year,has_content,content_urls",api_key=key) |>
  req_timeout(90) |> req_retry(max_tries=5,backoff=function(tries) min(30,2^tries)) |>
  req_perform() |> resp_body_json(simplifyVector=FALSE)
}
seen <- 0L
for (j in seq_along(chunks)) {
 ds <- chunks[[j]]
 answer <- tryCatch(fetch_chunk(ds),error=function(e) e)
 if(inherits(answer,"error")) {
   message("Batch ",j,"/",length(chunks)," OpenAlex failure: ",conditionMessage(answer))
   # Fail closed; preserve completed chunks rather than saying no availability.
   saveRDS(results,file.path(out,"completed_chunk_cache.rds"))
   write_json(list(query_total=length(queries),completed_chunks=j-1L,
     failed_chunk=j,error=conditionMessage(answer)),file.path(out,"incomplete.json"),pretty=TRUE,auto_unbox=TRUE)
   stop("OpenAlex discovery incomplete at chunk ",j)
 }
 works <- answer$results
 if(length(works)) for(w in works) {
   d <- normalize(if(is.null(w$doi)) "" else as.character(w$doi))
   if(!nzchar(d)||!(d %in% ds)) next
   hc <- if(is.null(w$has_content)) list() else w$has_content
   urls <- if(is.null(w$content_urls)) list() else w$content_urls
   results[[d]] <- list(doi=d,openalex_work_id=as.character(w$id),
    title=if(is.null(w$display_name)) "" else as.character(w$display_name),
    year=if(is.null(w$publication_year)) "" else as.character(w$publication_year),
    has_xml=isTRUE(hc$grobid_xml),has_pdf=isTRUE(hc$pdf),
    xml_url=if(is.null(urls$grobid_xml)) "" else as.character(urls$grobid_xml),
    pdf_url=if(is.null(urls$pdf)) "" else as.character(urls$pdf))
 }
 seen <- seen+length(ds)
 if(j %% 20L==0L || j==length(chunks)) {
   saveRDS(results,file.path(out,"completed_chunk_cache.rds"))
   message("OpenAlex queried ",seen,"/",length(queries)," unique DOI values (",j,"/",length(chunks)," calls)")
 }
 Sys.sleep(0.10)
}
for(i in valid) {
 d <- lookup_doi[i]
 w <- results[[d]]
 if(is.null(w)) {x$openalex_search_status[i]<-"no_exact_openalex_doi";next}
 x$openalex_matched_doi[i]<-d
 x$openalex_discovered_work_id[i]<-w$openalex_work_id
 x$openalex_title[i]<-w$title
 x$openalex_publication_year[i]<-w$year
 x$openalex_has_xml[i]<-as.character(w$has_xml)
 x$openalex_has_pdf[i]<-as.character(w$has_pdf)
 x$openalex_xml_url[i]<-w$xml_url
 x$openalex_pdf_url[i]<-w$pdf_url
 normalize_text<-function(z) gsub("[^a-z0-9]","",tolower(z))
 title_support <- nzchar(x$canonical_title[i]) && nzchar(w$title) &&
   (normalize_text(x$canonical_title[i])==normalize_text(w$title))
 year_support <- nzchar(x$canonical_year[i]) && nzchar(w$year) && x$canonical_year[i]==w$year
 oid_support <- nzchar(x$canonical_openalex_id[i]) &&
   tolower(sub("^https?://openalex.org/","",x$canonical_openalex_id[i])) ==
   tolower(sub("^https?://openalex.org/","",w$openalex_work_id))
 x$openalex_identity_status[i]<-if(oid_support||title_support) "doi_plus_independent_metadata" else if(year_support) "doi_plus_year" else "doi_only_needs_metadata_review"
 x$openalex_search_status[i]<-if(w$has_xml) "xml_available" else if(w$has_pdf) "pdf_only_available" else "no_cached_fulltext"
}
x$next_action[x$historical_archive_link_accepted]<-"already_archived"
x$next_action[x$requires_openalex_search & x$openalex_search_status=="xml_available"]<-"retrieve_xml_later"
x$next_action[x$requires_openalex_search & x$openalex_search_status=="pdf_only_available"]<-"retrieve_pdf_later"
x$next_action[x$requires_openalex_search & x$openalex_search_status=="no_cached_fulltext"]<-"no_openalex_fulltext"
x$next_action[x$requires_openalex_search & !nzchar(x$next_action)]<-"identity_or_doi_review"
write.csv(x,file.path(out,"canonical_w11_fulltext_availability_ledger.csv"),row.names=FALSE,na="")
write.csv(x[x$next_action %in% c("retrieve_xml_later","retrieve_pdf_later"),,drop=FALSE],
 file.path(out,"openalex_available_not_yet_archived.csv"),row.names=FALSE,na="")
write.csv(x[x$next_action=="identity_or_doi_review",,drop=FALSE],
 file.path(out,"identity_review_queue.csv"),row.names=FALSE,na="")
summary<-list(canonical_records=nrow(x),original_archive_links_accepted=sum(x$historical_archive_link_accepted),
 remaining_canonical_records=length(target),unique_doi_values_queried=length(queries),
 xml_available=sum(x$openalex_search_status=="xml_available"),
 pdf_only_available=sum(x$openalex_search_status=="pdf_only_available"),
 no_cached_fulltext=sum(x$openalex_search_status=="no_cached_fulltext"),
 no_exact_openalex_doi=sum(x$openalex_search_status=="no_exact_openalex_doi"),
 no_unambiguous_doi=sum(x$openalex_search_status=="no_unambiguous_doi"),
 next_stage_downloads_not_started=TRUE,
 archive_file_content_not_revalidated=TRUE)
write_json(summary,file.path(out,"summary.json"),pretty=TRUE,auto_unbox=TRUE)
cat(toJSON(summary,pretty=TRUE,auto_unbox=TRUE),"\n")

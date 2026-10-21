#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(jsonlite))
suppressPackageStartupMessages(library(httr2))
out<-"outputs/W11/identifier_discovery";dir.create(out,recursive=TRUE,showWarnings=FALSE)
ledger<-read.csv("input/canonical_w11_fulltext_availability_ledger.csv",stringsAsFactors=FALSE,colClasses="character")
ledger[is.na(ledger)]<-""
stopifnot(nrow(ledger)==22911L)
target<-which(ledger$openalex_search_status=="no_unambiguous_doi")
tokens<-Filter(nzchar,c(Sys.getenv("ZENODO_ACCESS_TOKEN"),Sys.getenv("ZENODO_TOKEN")))
if(!length(tokens))stop("No Zenodo credential")
get_dep<-function(id){
 for(t in tokens){
  r<-tryCatch(req_perform(request(paste0("https://zenodo.org/api/deposit/depositions/",id)) |> req_headers(Authorization=paste("Bearer",t)) |> req_timeout(45)),error=function(e)NULL)
  if(!is.null(r))return(list(dep=resp_body_json(r,simplifyVector=FALSE),token=t))
 }
 stop("W08 canonical deposit unavailable")
}
d<-get_dep("23459613")
fs<-d$dep$files
names<-vapply(fs,function(f)as.character(f$filename),character(1))
candidate<-which(grepl("canonical",names,ignore.case=TRUE)&grepl("\\.jsonl$",names))
stopifnot(length(candidate)==1L)
f<-fs[[candidate]]
urls<-Filter(nzchar,c(f$links$download,f$links$self,if(is.null(d$dep$links$bucket))"" else paste0(d$dep$links$bucket,"/",utils::URLencode(f$filename,reserved=TRUE))))
path<-tempfile(fileext=".jsonl")
success<-FALSE
for(url in urls){
 r<-tryCatch(req_perform(request(url)|>req_headers(Authorization=paste("Bearer",d$token))|>req_timeout(1500),path=path),error=function(e)NULL)
 if(!is.null(r)&&file.exists(path)&&file.info(path)$size>0){success<-TRUE;break}
}
if(!success)stop("Could not download W08 canonical JSONL")
raw<-readLines(path,warn=FALSE,encoding="UTF-8")
stopifnot(length(raw)==nrow(ledger))
scalar<-function(z) if(is.null(z)||!length(z))"" else if(is.list(z))scalar(z[[1]]) else as.character(z[[1]])
values<-function(z) {
 if(is.null(z))return(character())
 if(is.list(z))return(unlist(lapply(z,values),use.names=FALSE))
 as.character(z)
}
clean_openalex<-function(z) sub("^https?://openalex.org/","",trimws(z),ignore.case=TRUE)
clean_pmid<-function(z) sub("^https?://pubmed.ncbi.nlm.nih.gov/","",trimws(z),ignore.case=TRUE)
ids<-vector("list",length(target))
for(k in seq_along(target)){
 i<-target[[k]];rec<-fromJSON(raw[[i]],simplifyVector=FALSE)
 if(!identical(scalar(rec$identity$record_id),ledger$canonical_record_id[[i]]))stop("Canonical record/order mismatch at ",i)
 mans<-rec$manifestations
 openalex<-character();pmid<-values(rec$canonical$pmid)
 if(length(mans))for(m in mans){
  meta<-m$manifestation_metadata
  openalex<-c(openalex,values(meta$identifiers$openalex_id),values(meta$source_identity$openalex_id))
  pmid<-c(pmid,values(meta$identifiers$pmid))
 }
 openalex<-unique(grep("^W[0-9]+$",clean_openalex(openalex),value=TRUE))
 pmid<-unique(grep("^[0-9]+$",clean_pmid(pmid),value=TRUE))
 ids[[k]]<-data.frame(index=i,canonical_record_id=ledger$canonical_record_id[[i]],openalex_ids=paste(openalex,collapse=";"),pmids=paste(pmid,collapse=";"),stringsAsFactors=FALSE)
}
idx<-do.call(rbind,ids)
write.csv(idx,file.path(out,"canonical_identifier_crosswalk.csv"),row.names=FALSE)
key<-Sys.getenv("OPENALEX_API_KEY")
if(!nzchar(key))stop("OpenAlex API key missing")
# Direct verified indexed identifiers; ambiguous multiple IDs are retained for review.
lookup<-data.frame(index=integer(),kind=character(),value=character())
for(k in seq_len(nrow(idx))){
 a<-strsplit(idx$openalex_ids[[k]],";",fixed=TRUE)[[1]];a<-a[nzchar(a)]
 p<-strsplit(idx$pmids[[k]],";",fixed=TRUE)[[1]];p<-p[nzchar(p)]
 if(length(a)==1L)lookup<-rbind(lookup,data.frame(index=idx$index[[k]],kind="openalex_id",value=a))
 else if(length(a)==0L&&length(p)==1L)lookup<-rbind(lookup,data.frame(index=idx$index[[k]],kind="pmid",value=p))
}
unique_keys<-unique(paste(lookup$kind,lookup$value,sep=":"))
results<-list()
for(j in seq_along(unique_keys)){
 entry<-strsplit(unique_keys[[j]],":",fixed=TRUE)[[1]]
 kind<-entry[[1]];v<-entry[[2]]
 endpoint<-if(kind=="openalex_id")paste0("https://api.openalex.org/works/",v) else paste0("https://api.openalex.org/works/pmid:",v)
 result<-tryCatch({
  resp<-req_perform(request(endpoint)|>req_url_query(api_key=key,select="id,doi,ids,display_name,publication_year,has_content,content_urls")|>req_timeout(35)|>req_retry(max_tries=3))
  resp_body_json(resp,simplifyVector=FALSE)
 },error=function(e)NULL)
 if(!is.null(result)){
  hc<-result$has_content
  cu<-result$content_urls
  results[[unique_keys[[j]]]]<-list(id=scalar(result$id),doi=scalar(result$doi),
   title=scalar(result$display_name),year=scalar(result$publication_year),
   xml=isTRUE(hc$grobid_xml),pdf=isTRUE(hc$pdf),xml_url=scalar(cu$grobid_xml),
   pdf_url=scalar(cu$pdf),pmid=scalar(result$ids$pmid))
 }
 if(j%%100L==0L){
  saveRDS(results,file.path(out,"checkpoint.rds"))
  message("Identifier search ",j,"/",length(unique_keys)," matched ",length(results))
 }
 Sys.sleep(0.05)
}
ledger$identifier_search_status<-"not_applicable"
ledger$identifier_search_status[target]<-"no_unique_indexed_id"
ledger$identifier_lookup_kind<-"";ledger$identifier_lookup_value<-""
ledger$identifier_discovered_openalex_id<-"";ledger$identifier_discovered_doi<-""
ledger$identifier_has_xml<-"";ledger$identifier_has_pdf<-""
ledger$identifier_xml_url<-"";ledger$identifier_pdf_url<-""
ledger$identifier_title_match<-"";ledger$identifier_year_match<-""
ledger$identifier_identity_review<-""
for(k in seq_len(nrow(lookup))){
 i<-lookup$index[[k]];kind<-lookup$kind[[k]];v<-lookup$value[[k]]
 w<-results[[paste(kind,v,sep=":")]]
 ledger$identifier_lookup_kind[[i]]<-kind;ledger$identifier_lookup_value[[i]]<-v
 if(is.null(w)){ledger$identifier_search_status[[i]]<-"not_found_or_api_error";next}
 ledger$identifier_discovered_openalex_id[[i]]<-w$id
 ledger$identifier_discovered_doi[[i]]<-w$doi
 ledger$identifier_has_xml[[i]]<-as.character(w$xml)
 ledger$identifier_has_pdf[[i]]<-as.character(w$pdf)
 ledger$identifier_xml_url[[i]]<-w$xml_url
 ledger$identifier_pdf_url[[i]]<-w$pdf_url
 norm<-function(s)gsub("[^a-z0-9]","",tolower(s))
 title_ok<-nzchar(w$title)&&nzchar(ledger$canonical_title[[i]])&&identical(norm(w$title),norm(ledger$canonical_title[[i]]))
 year_ok<-nzchar(w$year)&&nzchar(ledger$canonical_year[[i]])&&identical(w$year,ledger$canonical_year[[i]])
 ledger$identifier_title_match[[i]]<-as.character(title_ok)
 ledger$identifier_year_match[[i]]<-as.character(year_ok)
 if(kind=="pmid"&&nzchar(w$pmid)&&!grepl(paste0("/",v,"/?$"),w$pmid)){ledger$identifier_identity_review[[i]]<-"pmid_mismatch";next}
 if(!title_ok&&!year_ok){ledger$identifier_search_status[[i]]<-"match_requires_metadata_review";next}
 ledger$identifier_search_status[[i]]<-if(w$xml)"xml_available" else if(w$pdf)"pdf_only_available" else "no_cached_fulltext"
}
write.csv(ledger,file.path(out,"canonical_ledger_with_indexed_id_search.csv"),row.names=FALSE)
candidates<-ledger[ledger$identifier_search_status %in% c("xml_available","pdf_only_available"),,drop=FALSE]
write.csv(candidates,file.path(out,"additional_available_by_indexed_id.csv"),row.names=FALSE)
summary<-list(canonical_records=nrow(ledger),previously_identified_fulltexts=sum(ledger$next_action %in% c("already_archived","retrieve_xml_later","retrieve_pdf_later")),
 without_doi_records=length(target),records_with_unique_openalex_or_pmid=nrow(lookup),unique_queries=length(unique_keys),
 indexed_id_matches=length(results),additional_xml=sum(ledger$identifier_search_status=="xml_available"),
 additional_pdf_only=sum(ledger$identifier_search_status=="pdf_only_available"),
 metadata_review=sum(ledger$identifier_search_status=="match_requires_metadata_review"),
 missing_or_ambiguous_identifier=sum(ledger$identifier_search_status=="no_unique_indexed_id"),
 no_cached_fulltext=sum(ledger$identifier_search_status=="no_cached_fulltext"))
write_json(summary,file.path(out,"summary.json"),pretty=TRUE,auto_unbox=TRUE)
cat(toJSON(summary,pretty=TRUE,auto_unbox=TRUE),"\n")

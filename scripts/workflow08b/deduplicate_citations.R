#!/usr/bin/env Rscript
# W08b-only conservative deterministic deduplication. No fuzzy pair generation.
# Usage: Rscript scripts/workflow08b/deduplicate_citations.R lens.jsonl openalex.jsonl historical_w01.jsonl lens_edges.csv openalex_edges.csv out_dir
suppressPackageStartupMessages({library(jsonlite);library(data.table);library(stringi)})
`%||%`<-function(x,y)if(is.null(x))y else x

a<-commandArgs(trailingOnly=TRUE)
if(length(a)!=6L)stop("Expected lens, openalex, historical W01, Lens edges, OpenAlex edges, output directory")
for(p in a[1:5])if(!file.exists(p))stop("Missing source: ",p)
dir.create(a[[6]],recursive=TRUE,showWarnings=FALSE)
scalar<-function(z){v<-unlist(z,use.names=FALSE);if(!length(v))return("");v<-trimws(as.character(v[[1]]));if(is.na(v))"" else v}
norm<-function(x){if(!nzchar(x))return("");v<-stri_trans_nfkc(x);v<-stri_trans_tolower(v);v<-gsub("[[:punct:]]+"," ",v,perl=TRUE);gsub("\\s+"," ",trimws(v),perl=TRUE)}
ndoi<-function(x){x<-tolower(trimws(x));sub("^doi:[[:space:]]*","",sub("^https?://(dx[.])?doi[.]org/","",x))}
year<-function(x){v<-suppressWarnings(as.integer(x));if(length(v)!=1L||is.na(v))NA_integer_ else v}
extract_author<-function(x){
 if(is.null(x)||!length(x))return("")
 z<-x[[1L]]
 if(is.list(z))return(norm(scalar(z$display_name%||%z$name%||%z$author$display_name)))
 norm(scalar(z))
}
records<-list();payload<-list();n<-0L
ingest<-function(path,provider){
 con<-file(path,"rt");on.exit(close(con))
 repeat{
  ls<-readLines(con,n=500L,warn=FALSE);if(!length(ls))break
  for(line in ls){
   if(!nzchar(line))next
   z<-fromJSON(line,simplifyVector=FALSE)
   can<-if(provider=="lens")z$canonical else z$mapped_fields
   sid<-if(provider=="lens")scalar(z$identity$lens_id) else scalar(z$sidecar_identity$openalex_id)
   sid<-if(provider=="openalex")toupper(sub("^https?://openalex[.]org/","",sid,ignore.case=TRUE)) else sid
   if(!nzchar(sid))stop("Missing provider ID")
   n<<-n+1L
   ab<-norm(scalar(can$abstract))
   ti<-norm(scalar(can$title))
   # Short/shared boilerplate is not an identity signal.
   safe_ab<-if(nchar(ab,type="chars")>=120L&&length(strsplit(ab," ",fixed=TRUE)[[1]])>=20L)ab else ""
   records[[n]]<<-data.table(idx=n,provider=provider,provider_id=sid,
      candidate_key=paste0(provider,":",sid),doi=ndoi(scalar(can$doi%||%z$sidecar_identity$doi)),
      title=ti,abstract=safe_ab,year=year(scalar(can$year)),author=extract_author(can$authors))
   payload[[n]]<<-line
  }
 }
}
ingest(a[[1]],"lens");ingest(a[[2]],"openalex")
d<-rbindlist(records,fill=TRUE);rm(records)
if(anyDuplicated(d$candidate_key))stop("Duplicate provider identities")
# Historical canonical records are read-only and indexed on strong identifiers and conservative text.
hist<-list();hn<-0L
con<-file(a[[3]],"rt")
repeat{
 ls<-readLines(con,n=300L,warn=FALSE);if(!length(ls))break
 for(line in ls){
  if(!nzchar(line))next
  z<-fromJSON(line,simplifyVector=FALSE);id<-scalar(z$identity$record_id)
  if(!nzchar(id))stop("Missing historical W01 ID")
  ca<-z$canonical%||%list()
  keys<-list()
  add<-function(kind,v){if(nzchar(v))keys[[length(keys)+1L]]<<-data.table(kind=kind,key=v,w01_record_id=id)}
  add("doi",ndoi(scalar(ca$doi)))
  title<-norm(scalar(ca$title));ab<-norm(scalar(ca$abstract))
  if(nzchar(title))add("title",title)
  if(nchar(ab)>=120L&&length(strsplit(ab," ",fixed=TRUE)[[1]])>=20L)add("abstract",ab)
  for(m in z$manifestations%||%list()){
   add("doi",ndoi(scalar(m$doi)))
   src<-scalar(m$source)
   if(src=="lens"){add("lens",scalar(m$source_record_id));add("lens",scalar(m$manifestation_metadata$source_identity$lens_id))}
   if(src=="openalex"){
    oa<-toupper(sub("^https?://openalex[.]org/","",scalar(m$source_record_id),ignore.case=TRUE))
    add("openalex",oa)
    oa<-toupper(sub("^https?://openalex[.]org/","",scalar(m$manifestation_metadata$source_identity$openalex_id),ignore.case=TRUE))
    add("openalex",oa)
   }
  }
  hn<-hn+1L;hist<-c(hist,keys)
 }
}
close(con)
h<-unique(rbindlist(hist,fill=TRUE))
# Ambiguous historical matches are held for targeted inspection, never assigned at random.
q<-rbindlist(list(
 d[nzchar(doi),.(idx,kind="doi",key=doi)],
 d[nzchar(title),.(idx,kind="title",key=title)],
 d[nzchar(abstract),.(idx,kind="abstract",key=abstract)],
 d[provider=="lens",.(idx,kind="lens",key=provider_id)],
 d[provider=="openalex",.(idx,kind="openalex",key=provider_id)]
))
hits<-merge(q,h,by=c("kind","key"),allow.cartesian=TRUE)
hits<-merge(hits,d[,.(idx,doi,title,year,author)],by="idx")
# Contradictory DOI is a hard stop to automatic text-based matching; DOI itself remains authoritative.
hist_doi<-unique(h[kind=="doi",.(w01_record_id,historical_doi=key)])
hits<-merge(hits,hist_doi,by="w01_record_id",all.x=TRUE,allow.cartesian=TRUE)
hits[,conflict:=kind%in%c("title","abstract") & nzchar(doi) & !is.na(historical_doi)&nzchar(historical_doi)&doi!=historical_doi]
hits<-hits[!conflict | kind%in%c("doi","lens","openalex")]
hist_match<-hits[,.(historical_ids=paste(sort(unique(w01_record_id)),collapse="|"),
 methods=paste(sort(unique(kind)),collapse="|"),n_history=uniqueN(w01_record_id)),by=idx]
d<-merge(d,hist_match,by="idx",all.x=TRUE,sort=FALSE)
d[is.na(n_history),n_history:=0L]
d[is.na(historical_ids),historical_ids:=""]
d[is.na(methods),methods:=""]
# Only merge within W08b on exact DOI, unambiguous title or substantial exact abstract.
# Conflicting nonempty DOIs are held separately and annotated rather than silently merged.
parent<-seq_len(nrow(d))
root<-function(x){while(parent[[x]]!=x)x<-parent[[x]];x}
join<-function(i,j){ri<-root(i);rj<-root(j);if(ri!=rj)parent[[max(ri,rj)]]<<-min(ri,rj)}
reason<-list();conflicts<-list()
for(kind in c("doi","abstract","title")){
 keys<-if(kind=="doi")d$doi else if(kind=="abstract")d$abstract else d$title
 groups<-split(which(nzchar(keys)),keys[nzchar(keys)])
 for(g in groups){
  if(length(g)<2L)next
  for(k in g[-1L]){
   i<-g[[1L]];j<-k
   contradictory<-nzchar(d$doi[[i]])&&nzchar(d$doi[[j]])&&d$doi[[i]]!=d$doi[[j]]
   incompatible_year<-!is.na(d$year[[i]])&&!is.na(d$year[[j]])&&abs(d$year[[i]]-d$year[[j]])>1L
   # Exact abstract can cross year/author differences but not contradictory DOI.
   inconsistent<-contradictory || (kind=="title" && incompatible_year)
   if(inconsistent){conflicts[[length(conflicts)+1L]]<-data.table(left=d$candidate_key[[i]],right=d$candidate_key[[j]],rule=kind,reason=if(contradictory)"conflicting_doi" else "incompatible_year");next}
   join(i,j)
   reason[[length(reason)+1L]]<-data.table(left=d$candidate_key[[i]],right=d$candidate_key[[j]],rule=kind)
  }
 }
}
d[,cluster:=vapply(idx,root,integer(1))]
# Prefer provider-specific Lens record if tied, then records with fullest metadata.
setorder(d,cluster,-n_history,provider,candidate_key)
d[,representative:=candidate_key[[1L]],by=cluster]
d[,status:=fifelse(n_history>1L,"ambiguous_historical",fifelse(n_history==1L,"existing_w01","new_candidate"))]
# Contradictory historical IDs within a group prevent automatic new-state materialisation.
d[,cluster_historical_ids:=paste(sort(unique(unlist(strsplit(historical_ids[nzchar(historical_ids)],"|",fixed=TRUE)))),collapse="|"),by=cluster]
d[nzchar(cluster_historical_ids)&grepl("|",cluster_historical_ids,fixed=TRUE),status:="ambiguous_historical"]
d[nzchar(cluster_historical_ids)&!grepl("|",cluster_historical_ids,fixed=TRUE),status:="existing_w01"]
# Historical DOI conflicts observed in text matches retained as review candidates.
fwrite(d[,.(candidate_key,provider,provider_id,doi,year,cluster,representative,status,matched_w01_ids=cluster_historical_ids,match_methods=methods)],file.path(a[[6]],"identity_crosswalk.csv"))
fwrite(if(length(reason))rbindlist(reason)else data.table(left=character(),right=character(),rule=character()),file.path(a[[6]],"merge_decisions.csv"))
fwrite(if(length(conflicts))unique(rbindlist(conflicts))else data.table(left=character(),right=character(),rule=character(),reason=character()),file.path(a[[6]],"identity_conflicts.csv"))
edges<-rbindlist(lapply(a[4:5],fread),fill=TRUE)
if(!all(c("provider","related_provider_id","seed_record_id","direction")%in%names(edges)))stop("Missing citation provenance columns")
edges[,candidate_key:=paste0(provider,":",related_provider_id)]
mapped<-merge(edges,d[,.(candidate_key,representative,status)],by="candidate_key",all.x=TRUE)
if(anyNA(mapped$representative))stop("Missing citation provenance target")
fwrite(mapped,file.path(a[[6]],"citation_provenance_crosswalk.csv"))
# Only output representative records that are not known historically and not ambiguous.
new<-unique(d[status=="new_candidate",.(representative)])
selected<-d[candidate_key%in%new$representative,idx]
fout<-file(file.path(a[[6]],"new_representative_records.jsonl"),"wt");on.exit(close(fout),add=TRUE)
for(i in selected)writeLines(payload[[i]],fout)
summary<-list(schema="w08b-deterministic-dedup-v1",historical_w01_records=hn,
 provider_manifestations=nrow(d),distinct_clusters=uniqueN(d$cluster),
 new_clusters=uniqueN(d[status=="new_candidate",cluster]),
 historical_clusters=uniqueN(d[status=="existing_w01",cluster]),
 ambiguous_clusters=uniqueN(d[status=="ambiguous_historical",cluster]),
 merge_decisions=length(reason),conflicts=length(conflicts),candidate_handoff_authorised=FALSE,
 methods=c("provider_id","doi","normalised_exact_title","normalised_exact_abstract"),
 fuzzy_pairs_generated=FALSE,llm_calls=0L)
writeLines(toJSON(summary,pretty=TRUE,auto_unbox=TRUE),file.path(a[[6]],"summary.json"))
cat("PASS: ",summary$new_clusters," new clusters; ",summary$historical_clusters," existing; ",summary$ambiguous_clusters," ambiguous\n",sep="")

#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(readr)
  library(jsonlite)
})

args <- commandArgs(trailingOnly=TRUE)
if(length(args)<5L) stop("Usage: build_legacy_projection.R corrected.csv scores.csv queue.csv manifest.json output.jsonl",call.=FALSE)
master_path<-args[[1]]; scores_path<-args[[2]]; queue_path<-args[[3]]; manifest_path<-args[[4]]; out_path<-args[[5]]

stopf<-function(...) stop(sprintf(...),call.=FALSE)
pick<-function(nms,cands){
  low<-setNames(nms,tolower(nms))
  for(x in cands) if(tolower(x)%in%names(low)) return(unname(low[[tolower(x)]]))
  NULL
}
splitvals<-function(x){
  if(is.null(x)||length(x)==0||is.na(x)||!nzchar(trimws(as.character(x)))) return(character())
  s<-trimws(as.character(x))
  if(grepl("^\\[.*\\]$",s)){
    z<-tryCatch(fromJSON(s),error=function(e)NULL)
    if(!is.null(z)) return(unique(trimws(as.character(z[nzchar(trimws(as.character(z)))]))))
  }
  unique(trimws(unlist(strsplit(s,"\\s*;\\s*|\\s*\\|\\s*",perl=TRUE))))
}
`%||%`<-function(x,y) if(is.null(x)||length(x)==0) y else x

m<-read_csv(master_path,show_col_types=FALSE,progress=FALSE)
q<-read_csv(queue_path,show_col_types=FALSE,progress=FALSE)
s<-read_csv(scores_path,show_col_types=FALSE,progress=FALSE)
man<-read_json(manifest_path,simplifyVector=FALSE)

id_col<-pick(names(m),c("record_id","lens_id","id","study_id"))
if(is.null(id_col)) stopf("Corrected master has no recognised record ID column")
fields<-list(
 title=pick(names(m),c("title","article_title","document_title")),
 doi=pick(names(m),c("doi","doi_url","digital_object_identifier")),
 abstract=pick(names(m),c("abstract","abstract_text")),
 year=pick(names(m),c("year","publication_year","date_year")),
 species=pick(names(m),c("final_species","species","farmed_species","deterministic_species","species_assigned")),
 country=pick(names(m),c("final_primary_country_iso3c","primary_country","country","country_name")),
 iso3=pick(names(m),c("final_primary_country_iso3c","iso3","iso3c","primary_iso3c","deterministic_primary_iso3c")),
 authors=pick(names(m),c("authors","author","author_string")),
 journal=pick(names(m),c("journal","source","publication_name")),
 volume=pick(names(m),c("volume")),
 issue=pick(names(m),c("issue")),
 pages=pick(names(m),c("pages","page_range"))
)

m[[id_col]]<-as.character(m[[id_col]])
q$record_id<-as.character(q$record_id)
if(anyDuplicated(q$record_id)) stopf("Topic queue contains duplicate record IDs")
if(anyDuplicated(m[[id_col]])) stopf("Corrected master contains duplicate record IDs")
missing<-setdiff(q$record_id,m[[id_col]])
extra<-setdiff(m[[id_col]],q$record_id)
if(length(missing)){
  writeLines(missing,paste0(out_path,".missing_from_master.txt"))
  stopf("Corrected master is missing %d topic-queue record IDs",length(missing))
}

m<-m[match(q$record_id,m[[id_col]]),,drop=FALSE]
stopifnot(identical(as.character(m[[id_col]]),q$record_id))

topic_by_record<-split(s,as.character(s$record_id))
vote_obj<-function(row,p){
 role<-as.character(row[[paste0("role_",p)]][[1]] %||% "")
 reason<-as.character(row[[paste0("reason_",p)]][[1]] %||% "")
 list(pass=p,assigned=nzchar(role),role=if(nzchar(role))role else NULL,reason=if(nzchar(reason))reason else NULL)
}
getv<-function(row,col){
 if(is.null(col)) return(NULL)
 z<-row[[col]]
 if(length(z)==0||is.na(z[[1]])||!nzchar(trimws(as.character(z[[1]])))) NULL else as.character(z[[1]])
}
con<-file(out_path,"wt",encoding="UTF-8"); on.exit(close(con),add=TRUE)
for(i in seq_len(nrow(m))){
 row<-m[i,,drop=FALSE]; rid<-q$record_id[[i]]
 z<-topic_by_record[[rid]]
 topics<-if(is.null(z)||!nrow(z)) list() else lapply(seq_len(nrow(z)),function(k){
   rr<-z[k,,drop=FALSE]
   list(
     path_id=as.character(rr$path_id[[1]]),
     hierarchy_path=as.character(rr$hierarchy_path[[1]]),
     stars=as.integer(rr$confidence_n[[1]]),
     confidence_label=as.character(rr$confidence_label[[1]]),
     votes=list(vote_obj(rr,"a"),vote_obj(rr,"b"),vote_obj(rr,"c"))
   )
 })
 rec<-list(
   record_id=rid,
   title=getv(row,fields$title),
   doi=getv(row,fields$doi),
   abstract=getv(row,fields$abstract),
   year=getv(row,fields$year),
   species=splitvals(getv(row,fields$species)),
   countries=splitvals(getv(row,fields$country)),
   iso3=splitvals(getv(row,fields$iso3)),
   authors=getv(row,fields$authors),
   journal=getv(row,fields$journal),
   volume=getv(row,fields$volume),
   issue=getv(row,fields$issue),
   pages=getv(row,fields$pages),
   topics=topics,
   provenance=list(
     projection_type="legacy_corrected_master_dashboard_projection",
     authoritative_canonical=FALSE,
     source_master=basename(master_path),
     topic_source_run_id="35524609662",
     queue_sha256=as.character(man$queue_sha256 %||% "")
   )
 )
 writeLines(toJSON(rec,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)
}
cat(sprintf("PASS: wrote legacy dashboard projection for %d exact topic-queue records; ignored %d extra master rows\n",nrow(m),length(extra)))

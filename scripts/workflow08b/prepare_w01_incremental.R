#!/usr/bin/env Rscript
# W08b human-decision -> existing W01 canonical builder preparation.
# No repeated deduplication, historical reclassification, or provider API calls.
suppressPackageStartupMessages({library(data.table);library(jsonlite);library(digest)})
`%||%` <- function(x,y) if(is.null(x)||!length(x)) y else x
a<-commandArgs(TRUE)
if(length(a)!=6L)stop("Usage: prepare_w01_incremental.R PREVIOUS_STATE CROSSWALK BIBLIOGRAPHY_DIR DECISIONS_CSV REPAIRS_CSV OUTPUT")
prev<-a[[1]]; cross<-a[[2]]; bib<-a[[3]]; decisions<-a[[4]]; repairs<-a[[5]]; out<-a[[6]]
dir.create(out,recursive=TRUE,showWarnings=FALSE)
dir.create(file.path(out,"workflow01_seed"),recursive=TRUE,showWarnings=FALSE)
dir.create(file.path(out,"final"),recursive=TRUE,showWarnings=FALSE)
dir.create(file.path(out,"canonical"),recursive=TRUE,showWarnings=FALSE)
oldseed<-file.path(prev,"workflow01_seed")
oldmap<-file.path(prev,"workflow01_full_five_source","manifestation_cluster_map.csv")
oldpairs<-file.path(prev,"workflow01_full_five_source","final_pair_decisions.csv")
stopifnot(file.exists(oldmap),file.exists(oldpairs))
map<-fread(oldmap,colClasses="character",na.strings=c("","NA"))
stopifnot(all(c("source","source_record_id","cluster_id","cluster_size","idx")%in%names(map)))
x<-fread(cross,colClasses="character",na.strings=c("","NA"))
stopifnot(all(c("candidate_key","provider","provider_id","cluster","status","matched_w01_ids")%in%names(x)))
if(anyDuplicated(x$candidate_key))stop("Duplicate candidate keys")
setkey(x,candidate_key)
d<-fread(decisions,colClasses="character",na.strings=c("","NA"))
stopifnot(all(c("review_case_id","decision","target_w01_id")%in%names(d)))
if(anyDuplicated(d$review_case_id))stop("Duplicated human decisions")
r<-if(file.exists(repairs)&&file.info(repairs)$size>0L)fread(repairs,header=TRUE,colClasses="character",na.strings=c("","NA"))else data.table()
repair_fields<-c("source_kind","source_record_id","action","value")
if(nrow(r) && !all(repair_fields %in% names(r))){
  # Empty data.frame() is serialised by write.csv as a one-column CSV.
  # fread may interpret its placeholder as a row. Ignore only an entirely
  # blank placeholder; never discard actual, unrecognised audit data.
  flattened<-unlist(r,use.names=FALSE)
  placeholder<-all(is.na(flattened) | !nzchar(trimws(as.character(flattened))))
  if(placeholder) {
    message("W08b abstract repairs: exported empty-table placeholder; no repairs to apply")
    r<-data.table()
  } else stop(sprintf("W08b abstract repair CSV schema mismatch; found columns: %s; first row: %s",
    paste(names(r),collapse=","),paste(utils::head(as.character(flattened),8L),collapse="|")))
}
existing_ids<-unique(map$cluster_id)
setindex(x,cluster)
clusters<-unique(x$cluster)
chosen<-setNames(character(length(clusters)),clusters)
for(cl in clusters){
  rows<-x[.(cl),on="cluster",nomatch=0L]
  categories<-unique(rows$status)
  if(length(categories)!=1L)stop("Mixed statuses in W08b cluster ",cl)
  status<-categories[[1L]]
  hist<-unique(unlist(strsplit(rows$matched_w01_ids[nzchar(rows$matched_w01_ids)],"|",fixed=TRUE),use.names=FALSE))
  hist<-hist[nzchar(hist)]
  if(status=="existing_w01"){
    if(length(hist)!=1L||!hist%in%existing_ids)stop("Unresolved historic identity in cluster ",cl)
    chosen[[cl]]<-hist
  }else if(status=="ambiguous_historical"){
    review_id<-paste0("w08b-ambiguous-",cl)
    decision<-d[review_case_id==review_id]
    if(nrow(decision)!=1L)stop("Missing decision ",review_id)
    if(decision$decision=="same_publication"){
      target<-decision$target_w01_id
      if(!nzchar(target)||!target%in%hist||!target%in%existing_ids)stop("Invalid human historical match ",review_id)
      chosen[[cl]]<-target
    }else if(decision$decision=="different_publications"){
      chosen[[cl]]<-paste0("work-",substr(digest(paste(sort(rows$candidate_key),collapse="|"),algo="sha256",serialize=FALSE),1L,24L))
    }else stop("W08b uncertainty requires adjudication before canonical handoff: ",review_id)
  }else if(status=="new_candidate"){
    chosen[[cl]]<-paste0("work-",substr(digest(paste(sort(rows$candidate_key),collapse="|"),algo="sha256",serialize=FALSE),1L,24L))
  }else stop("Unknown W08b classification: ",status)
}
if(anyDuplicated(unique(chosen[!chosen%in%existing_ids])))stop("New cluster ID collision")
if(any(chosen[!chosen%in%existing_ids]%in%existing_ids))stop("New ID overlaps historical state")
oldfiles<-list.files(oldseed,pattern="_records_for_deduplication\\.jsonl$",full.names=TRUE)
if(!length(oldfiles))stop("Missing historical W01 source manifestations")
for(p in oldfiles)if(!file.copy(p,file.path(out,"workflow01_seed",basename(p)),overwrite=TRUE))stop("Cannot copy source ",p)
paths<-c(lens=file.path(bib,"lens","records.jsonl"),openalex=file.path(bib,"openalex","openalex_sidecar_records.jsonl"))
if(any(!file.exists(paths)))stop("Missing W08b bibliography files")
map[,key__:=paste(source,source_record_id,sep="::")]
oldkeys<-map$key__
oldkeyset<-new.env(hash=TRUE,parent=emptyenv(),size=length(oldkeys)*2L)
for(k in oldkeys)assign(k,TRUE,envir=oldkeyset)
initial_max<-max(as.integer(map$idx),na.rm=TRUE)
nextidx<-initial_max
newrows<-list()
for(src in names(paths)){
  input<-file(paths[[src]],"rt")
  dest<-file.path(out,"workflow01_seed",paste0(src,"_records_for_deduplication.jsonl"))
  if(!file.exists(dest))file.create(dest)
  output<-file(dest,"at")
  seen<-new.env(hash=TRUE,parent=emptyenv())
  repeat{
    lines<-readLines(input,n=500L,warn=FALSE)
    if(!length(lines))break
    for(line in lines){
      z<-fromJSON(line,simplifyVector=FALSE)
      sid<-if(src=="lens")as.character(z$identity$lens_id%||%"")else as.character(z$sidecar_identity$sidecar_record_id%||%"")
      pid<-if(src=="lens")sid else as.character(z$sidecar_identity$openalex_id%||%"")
      cand<-paste0(src,":",pid)
      cl_rows<-x[J(cand),cluster]
      if(length(cl_rows)!=1L||is.na(cl_rows[[1L]]))stop("Bibliographic record absent from dedup crosswalk: ",cand)
      if(exists(cand,envir=seen,inherits=FALSE))stop("Duplicate W08b bibliography ID ",cand)
      assign(cand,TRUE,envir=seen)
      key<-paste(src,sid,sep="::")
      if(exists(key,envir=oldkeyset,inherits=FALSE))next
      cl<-cl_rows[[1L]]
      nextidx<-nextidx+1L
      row<-as.list(rep(NA_character_,length(names(map))-1L))
      names(row)<-setdiff(names(map),"key__")
      row$source<-src;row$source_record_id<-sid;row$cluster_id<-chosen[[cl]]
      row$idx<-as.character(nextidx)
      newrows[[length(newrows)+1L]]<-row
      writeLines(line,output,useBytes=TRUE)
    }
  }
  close(input);close(output)
  if(length(setdiff(x[provider==src,candidate_key],ls(seen,all.names=TRUE))))stop("Missing input bibliography IDs for ",src)
}
if(length(newrows)){
  adds<-rbindlist(newrows,fill=TRUE)
  map[,key__:=NULL]
  map<-rbindlist(list(map,adds),use.names=TRUE,fill=TRUE)
}else map[,key__:=NULL]
map[,cluster_size:=as.character(.N),by=cluster_id]
setorderv(map,c("idx","source","source_record_id"))
fwrite(map,file.path(out,"final","manifestation_cluster_map.csv"),na="")
file.copy(oldpairs,file.path(out,"final","final_pair_decisions.csv"),overwrite=TRUE)
for(nm in c("cluster_id_aliases.csv","abstract_strip_actions.jsonl")){
  src<-file.path(prev,"workflow01_full_five_source",nm)
  if(file.exists(src))file.copy(src,file.path(out,"final",nm),overwrite=TRUE)
}
if(!file.exists(file.path(out,"final","abstract_strip_actions.jsonl")))file.create(file.path(out,"final","abstract_strip_actions.jsonl"))
prior_repairs<-file.path(prev,"provenance","cumulative_data_quality_repairs.jsonl")
repair_out<-file.path(out,"final","cumulative_data_quality_repairs.jsonl")
if(file.exists(prior_repairs))file.copy(prior_repairs,repair_out,overwrite=TRUE)else file.create(repair_out)
# Historical repairs remain an audit, not a mutation of published W01 records.
# Candidate corrections are applied using their exact new manifestation identity.
if(nrow(r)){
  # The Sheets export preserves append order; timestamp is optional in older repairs.
  if("saved_at_utc"%in%names(r))setorderv(r,"saved_at_utc",na.last=TRUE)
  for(i in seq_len(nrow(r))){
    z<-r[i]
    if(z$source_kind!="candidate")next
    hit<-x[provider_id==z$source_record_id]
    if(nrow(hit)!=1L)stop("Repair source not uniquely identified")
    src<-hit$provider[[1L]]
    rid<-if(src=="openalex")paste0("openalex:",z$source_record_id) else z$source_record_id
    if(!paste(src,rid,sep="::")%in%paste(map$source,map$source_record_id,sep="::"))stop("Repair source not mapped")
    entry<-list(review_case_id=as.character(z$review_case_id%||%""),
      source=src,source_record_id=rid,action=as.character(z$action),
      value=if(z$action=="strip_abstract")"" else as.character(z$value%||%""))
    cat(toJSON(entry,auto_unbox=TRUE,null="null"),"\n",file=repair_out,append=TRUE,sep="")
  }
}
sourcefiles<-list.files(file.path(out,"workflow01_seed"),pattern="_records_for_deduplication\\.jsonl$",full.names=TRUE)
names(sourcefiles)<-sub("_records_for_deduplication\\.jsonl$","",basename(sourcefiles))
writeLines(toJSON(list(schema="living-evidence-map-workflow01-source-inputs-v1",
  sources=as.list(sourcefiles)),auto_unbox=TRUE,pretty=TRUE),file.path(out,"source_inputs.json"))
# Preserve existing summary fields; the canonical builder supplies revised record counts.
summary<-fromJSON(file.path(prev,"workflow01_full_five_source","summary.json"),simplifyVector=FALSE)
summary$source_manifestations<-nrow(map)
summary$clusters<-length(unique(map$cluster_id))
summary$manual_review_pairs<-0L
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null"),file.path(out,"final","summary.json"))
writeLines(toJSON(list(schema="w08b-w01-incremental-adapter-v1",new_manifestations=length(newrows),
  new_clusters=sum(!unique(chosen)%in%existing_ids),decision_count=nrow(d),
  prior_records=length(existing_ids),updated_records=length(unique(map$cluster_id)),
  status="prepared"),auto_unbox=TRUE,pretty=TRUE),file.path(out,"adapter_manifest.json"))
cat("PASS: W08b source-to-W01 incremental map prepared with",length(newrows),"new manifestations\n")

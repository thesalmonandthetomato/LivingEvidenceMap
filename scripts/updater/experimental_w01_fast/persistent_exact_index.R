#!/usr/bin/env Rscript
# Experimental local-only persistent exact posting index.
# Reuses the exact block definitions from build_exact_block_index.R.
# This does NOT implement rare-q-gram matching, classification or publication.
suppressPackageStartupMessages({library(data.table);library(digest);library(jsonlite)})
args<-commandArgs(trailingOnly=TRUE)
arg<-function(x,default=NULL){k<-match(x,args);if(is.na(k))return(default)
 if(k==length(args))stop(paste("Missing value for",x),call.=FALSE);args[[k+1L]]}
mode<-arg("--mode");input<-arg("--metadata");state_path<-arg("--state")
out<-arg("--output-dir")
if(is.null(mode)||!mode%in%c("init","append")||is.null(input)||is.null(state_path)||is.null(out))
 stop("Required --mode init|append --metadata --state --output-dir",call.=FALSE)
m<-fread(input,na.strings=c("","NA"))
required<-c("idx","source","source_record_id","title_norm","doi_norm","doi_family",
 "abstract_hash","author_norm","year","journal_norm","volume_norm","issue_norm","pages_norm")
stopifnot(all(required%in%names(m)),identical(as.integer(m$idx),seq_len(nrow(m))),
 !anyNA(m$source),!anyNA(m$source_record_id),
 !anyDuplicated(paste(m$source,m$source_record_id,sep="::")))
make_key<-function(...){xs<-list(...);z<-rep(NA_character_,length(xs[[1L]]))
 ok<-Reduce(`&`,lapply(xs,function(x)!is.na(x)&nzchar(as.character(x))))
 if(any(ok))z[ok]<-do.call(paste,c(lapply(xs,function(x)as.character(x[ok])),sep="::"))
 z}
blocks<-c("bramer_A","bramer_B","bramer_C","bramer_D","bramer_E","bramer_F",
 "bramer_G","doi_norm","doi_family","abstract_hash")
derive<-function(dt){
 dt<-copy(dt)
 dt[,bramer_A:=make_key(author_norm,year,title_norm,journal_norm)]
 dt[,bramer_B:=make_key(author_norm,year,title_norm,pages_norm)]
 dt[,bramer_C:=make_key(title_norm,volume_norm,pages_norm)]
 dt[,bramer_D:=make_key(author_norm,volume_norm,pages_norm)]
 dt[,bramer_E:=make_key(year,volume_norm,issue_norm,pages_norm)]
 dt[,bramer_F:=title_norm]
 dt[,bramer_G:=make_key(author_norm,year)]
 rbindlist(lapply(blocks,function(b){
   z<-dt[,.(idx,key=as.character(get(b)))][!is.na(key)&nzchar(key)]
   z[,block:=b];z
 }),use.names=TRUE)[,.(block,key,idx)]
}
empty_pairs<-function()data.table(record_i=integer(),record_j=integer(),blocks=character())
dir.create(out,recursive=TRUE,showWarnings=FALSE)
if(mode=="init"){
 if(file.exists(state_path))stop("Refusing to overwrite existing state",call.=FALSE)
 posting<-derive(m);setorder(posting,block,key,idx)
 state<-list(schema="experimental-w01-fast-persistent-exact-v1",
    identities=m[,.(source,source_record_id)],
    metadata_sha256=digest(file=input,algo="sha256",serialize=FALSE),
    postings=posting,blocks=blocks)
 pairs<-empty_pairs()
}else{
 if(!file.exists(state_path))stop("Missing authoritative experimental state",call.=FALSE)
 state<-readRDS(state_path)
 stopifnot(identical(state$schema,"experimental-w01-fast-persistent-exact-v1"),
   identical(state$blocks,blocks))
 old_n<-nrow(state$identities)
 if(nrow(m)<old_n)stop("Manifestation count decreased",call.=FALSE)
 if(!identical(as.character(m$source[seq_len(old_n)]),as.character(state$identities$source))||
    !identical(as.character(m$source_record_id[seq_len(old_n)]),as.character(state$identities$source_record_id)))
  stop("Historical manifestation identity/order changed",call.=FALSE)
 # Historical metadata mutations require separately reviewed affected-index rebuilding.
 # No silent restoration of stale postings after a historical repair.
 prior<-m[seq_len(old_n)]
 if(!identical(digest(prior,algo="sha256"),state$historical_rows_sha256))
   stop("Historical normalised metadata changed: bounded index rebuild required",call.=FALSE)
 new<-if(old_n<nrow(m))m[seq.int(old_n+1L,nrow(m))]else m[0L]
 add<-derive(new)
 old<-state$postings
 hits<-list()
 for(b in blocks){
   a<-old[block==b,.(key,old_idx=idx)]
   z<-add[block==b,.(key,new_idx=idx)]
   if(!nrow(z))next
   sizes<-rbindlist(list(a[,.(key)],z[,.(key)]))[, .N,by=key][N>1L&N<=500L,.(key)]
   a<-a[sizes,on="key",nomatch=0L];z<-z[sizes,on="key",nomatch=0L]
   oh<-merge(a,z,by="key",allow.cartesian=TRUE)[,.(record_i=old_idx,record_j=new_idx)]
   nn<-merge(z,z,by="key",allow.cartesian=TRUE)[new_idx.x<new_idx.y,
      .(record_i=new_idx.x,record_j=new_idx.y)]
   one<-rbindlist(list(oh,nn))
   if(nrow(one)){one[,block:=b];hits[[length(hits)+1L]]<-one}
 }
 if(length(hits)){
   raw<-rbindlist(hits)
   pairs<-raw[,.(blocks=paste(sort(unique(block)),collapse=";")),by=.(record_i,record_j)]
   setorder(pairs,record_i,record_j)
 } else pairs<-empty_pairs()
 state$postings<-rbindlist(list(old,add),use.names=TRUE);setorder(state$postings,block,key,idx)
 state$identities<-m[,.(source,source_record_id)]
 state$metadata_sha256<-digest(file=input,algo="sha256",serialize=FALSE)
}
# Store row fingerprint for fail-closed historical metadata repair detection.
# Both init and append emit a single successor snapshot; never write the input state.
state$historical_rows_sha256<-digest(m,algo="sha256")
# Do not overwrite input state. Append outputs to a separate, versioned path.
next_state<-file.path(out,"next_exact_index.rds")
if(normalizePath(dirname(state_path),mustWork=FALSE)==normalizePath(out,mustWork=FALSE)&&
 basename(state_path)==basename(next_state))stop("Output would overwrite input state",call.=FALSE)
saveRDS(state,next_state,compress="xz")
fwrite(pairs,file.path(out,"exact_block_candidates.csv"))
writeLines(toJSON(list(schema=state$schema,mode=mode,manifestations=nrow(m),
 pairs=nrow(pairs),postings=nrow(state$postings),production_publication_allowed=FALSE,
 includes_fuzzy=FALSE),auto_unbox=TRUE,pretty=TRUE),
 file.path(out,"manifest.json"))
cat(sprintf("PASS: %s; %d indexed manifestations; %d incremental exact candidates\n",
 mode,nrow(m),nrow(pairs)))

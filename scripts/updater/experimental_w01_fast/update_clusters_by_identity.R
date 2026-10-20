#!/usr/bin/env Rscript
# Experimental W01-Fast identity-keyed incremental clusters. Never writes to production.
# Union-find offsets are ephemeral and derived exclusively from stable identities.
suppressPackageStartupMessages({library(data.table);library(digest);library(jsonlite)})
args<-commandArgs(trailingOnly=TRUE)
arg<-function(x){i<-match(x,args);if(is.na(i)||i==length(args))stop(paste("Missing",x));args[[i+1L]]}
prior<-fread(arg("--prior-map"),colClasses=list(character=c("source","source_record_id","cluster_id")))
meta<-fread(arg("--metadata"),colClasses=list(character=c("source","source_record_id")))
dec<-fread(arg("--incremental-decisions"),colClasses=list(character=c(
 "source_i","source_record_id_i","source_j","source_record_id_j")))
out<-arg("--output-dir")
required_meta<-c("source","source_record_id")
required_dec<-c("source_i","source_record_id_i","source_j","source_record_id_j","rescored_classification")
if(!all(c(required_meta,"cluster_id")%in%names(prior))||
   !all(required_meta%in%names(meta))||!all(required_dec%in%names(dec)))
 stop("Stable identity fields are mandatory; numeric pair IDs are not accepted")
if(anyNA(meta[,..required_meta])||anyNA(prior[,..required_meta])||
 anyNA(prior$cluster_id)||any(!nzchar(prior$cluster_id))||
 anyNA(dec[,..required_dec]))stop("Blank identities or clusters")
key<-function(src,rid)paste0(nchar(src,type="bytes"),":",src,nchar(rid,type="bytes"),":",rid)
all_keys<-key(meta$source,meta$source_record_id)
old_keys<-key(prior$source,prior$source_record_id)
if(anyDuplicated(all_keys)||anyDuplicated(old_keys))stop("Duplicated manifestation identity")
if(any(!old_keys%in%all_keys))stop("Historical manifestation is missing")
# This mapping is local only. Never expose ephemeral offsets as identities.
old_positions<-match(old_keys,all_keys)
oldid_for_current<-prior$cluster_id[match(all_keys,old_keys)]
parent<-seq_along(all_keys);height<-integer(length(all_keys))
root<-function(x){while(parent[[x]]!=x){parent[[x]]<<-parent[[parent[[x]]]];x<-parent[[x]]};x}
unite<-function(x,y){x<-root(x);y<-root(y);if(x==y)return(invisible(NULL))
 if(height[[x]]<height[[y]])parent[[x]]<<-y
 else if(height[[x]]>height[[y]])parent[[y]]<<-x
 else{parent[[y]]<<-x;height[[x]]<<-height[[x]]+1L}}
# Historical clusters are authoritative; never recreate historical pair decisions.
by_cluster<-split(old_positions,prior$cluster_id)
for(members in by_cluster)if(length(members)>1L)
 for(k in members[-1L])unite(members[[1L]],k)
# Unordered pair keys are stable even if input rows or pair orientations change.
left<-if(nrow(dec))key(dec$source_i,dec$source_record_id_i)else character()
right<-if(nrow(dec))key(dec$source_j,dec$source_record_id_j)else character()
if(any(!left%in%all_keys)||any(!right%in%all_keys)||any(left==right))
 stop("Unknown or self-paired identity")
pair_keys<-paste0(nchar(pmin(left,right),type="bytes"),":",pmin(left,right),nchar(pmax(left,right),type="bytes"),":",pmax(left,right))
if(anyDuplicated(pair_keys))stop("Repeated incremental identity pair")
if(any(left%in%old_keys & right%in%old_keys))
 stop("Old-to-old decision is not an incremental edge")
approved<-which(dec$rescored_classification=="duplicate")
left_positions<-match(left,all_keys);right_positions<-match(right,all_keys)
for(i in approved)unite(left_positions[[i]],right_positions[[i]])
components<-split(seq_along(all_keys),vapply(seq_along(all_keys),root,integer(1)))
# Unambiguous component encoding. No row offsets and no delimiter collisions.
fingerprint<-function(loc){
 # Exact frozen W01 allocation rule. Identity lookups above remain length-prefixed.
 keys_colon<-paste(meta$source[loc],meta$source_record_id[loc],sep=":")
 paste0("work-",substr(digest(paste(sort(keys_colon),collapse="|"),
  algo="sha256",serialize=FALSE),1,16))
}
result<-meta[,.(source,source_record_id)]
result[,cluster_id:=NA_character_];result[,cluster_size:=NA_integer_]
for(loc in components){
 members<-all_keys[loc]
 original_ids<-oldid_for_current[loc]
 previous_ids<-unique(original_ids[!is.na(original_ids)])
 if(length(previous_ids)>1L)stop("Merger of distinct historical clusters requires explicit adjudication")
 # Preserve existing work IDs when a cluster gains new manifestations.
 preserved<-if(length(previous_ids)==1L)previous_ids else NULL
 result[loc,cluster_id:=if(is.null(preserved))fingerprint(loc)else preserved]
 result[loc,cluster_size:=length(members)]
}
if(dir.exists(out)||file.exists(out))stop("Refusing to replace prior cluster outputs")
dir.create(out,recursive=TRUE)
fwrite(result,file.path(out,"identity_cluster_map.csv"))
writeLines(toJSON(list(schema="w01-fast-identity-clusters-v1",
 historic_members=nrow(prior),current_members=nrow(meta),
 identity_decisions=nrow(dec),clusters=length(components),
 production_publication_allowed=FALSE),auto_unbox=TRUE,pretty=TRUE),
 file.path(out,"manifest.json"))
cat(sprintf("PASS: %d identity-based clusters, %d duplicate edges\n",
 length(components),length(approved)))

#!/usr/bin/env Rscript
# W01-Fast experimental append-only pair decisions keyed ONLY by stable source identity.
# Row numbers are never used for ledger lookup, matching or provenance.
suppressPackageStartupMessages({library(data.table);library(digest);library(jsonlite)})
a<-commandArgs(trailingOnly=TRUE)
arg<-function(k,optional=FALSE){i<-match(k,a);if(is.na(i)){if(optional)return(NULL);stop(paste("Missing",k))};if(i==length(a))stop(paste("Missing value",k));a[[i+1L]]}
historic<-arg("--historical-ledger",TRUE)
fresh_path<-arg("--new-decisions")
identity_path<-arg("--manifestations")
output<-arg("--output")
if(file.exists(output))stop("Refusing to overwrite authoritative ledger",call.=FALSE)
m<-fread(identity_path,na.strings=c("","NA"),colClasses=list(character=c("source","source_record_id")))
identity<-c("source","source_record_id")
if(!all(identity%in%names(m))||anyNA(m[,..identity])||
 any(!nzchar(m$source))||any(!nzchar(m$source_record_id))||
 anyDuplicated(m[,..identity]))stop("Invalid or duplicate source identities",call.=FALSE)
keycols<-c("source_i","source_record_id_i","source_j","source_record_id_j")
columns<-c(keycols,"rescored_classification")
read_ledger<-function(path){
 d<-fread(path,na.strings=c("","NA"),colClasses=list(character=keycols))
 if(!identical(names(d),columns))stop("Ledger must contain stable identity fields and classification only",call.=FALSE)
 d
}
fresh<-read_ledger(fresh_path)
old<-if(is.null(historic))fresh[0L]else read_ledger(historic)
identity_key<-function(src,id){
 # Unambiguous length-prefixed encoding; does not confuse ':' or '::' in source IDs.
 paste0(nchar(src,type="bytes"),":",src,nchar(id,type="bytes"),":",id)
}
known<-identity_key(m$source,m$source_record_id)
check<-function(d){
 if(!nrow(d))return(character())
 if(anyNA(d[,..columns])||any(!nzchar(as.character(unlist(d[,..columns])))))
   stop("Blank or missing identity/classification",call.=FALSE)
 left<-identity_key(d$source_i,d$source_record_id_i)
 right<-identity_key(d$source_j,d$source_record_id_j)
 if(any(!left%in%known)||any(!right%in%known))stop("Unknown record identity",call.=FALSE)
 if(any(left>=right))stop("Pair identities must be strictly ordered and distinct",call.=FALSE)
 pairkey<-paste0(nchar(left,type="bytes"),":",left,right)
 if(anyDuplicated(pairkey))stop("Duplicate pair in ledger",call.=FALSE)
 pairkey
}
oldkeys<-check(old);newkeys<-check(fresh)
if(any(newkeys%in%oldkeys))stop("Historical decision cannot be replaced",call.=FALSE)
merged<-rbindlist(list(old,fresh))
dir.create(dirname(output),recursive=TRUE,showWarnings=FALSE)
fwrite(merged,output)
writeLines(toJSON(list(schema="experimental-w01-fast-stable-identity-decisions-v2",
 historical_decisions=nrow(old),appended_decisions=nrow(fresh),
 total_decisions=nrow(merged),stable_identity_columns=keycols,
 manifestations_sha256=digest(file=identity_path,algo="sha256"),
 old_ledger_sha256=if(is.null(historic))NULL else digest(file=historic,algo="sha256"),
 production_publication_allowed=FALSE),auto_unbox=TRUE,pretty=TRUE),
 paste0(output,".manifest.json"))
cat(sprintf("PASS: %d historical and %d appended identity-keyed decisions\\n",nrow(old),nrow(fresh)))

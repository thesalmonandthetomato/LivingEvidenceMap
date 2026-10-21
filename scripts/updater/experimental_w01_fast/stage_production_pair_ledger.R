#!/usr/bin/env Rscript
# Fail-closed legacy W01 pair-ledger adapter. Verify the original idx map against
# immutable identities before carrying any historic numeric pair references.
suppressPackageStartupMessages({library(data.table);library(jsonlite);library(digest)})
a<-commandArgs(trailingOnly=TRUE)
arg<-function(k){i<-match(k,a);if(is.na(i)||i==length(a))stop("Missing ",k);a[[i+1L]]}
old_path<-arg("--previous-decisions");new_path<-arg("--scored-decisions")
meta_path<-arg("--metadata");prev_path<-arg("--previous-map");out<-arg("--output")
if(any(!file.exists(c(old_path,new_path,meta_path,prev_path)))||file.exists(out))
 stop("Inputs absent or output already exists")
m<-fread(meta_path,na.strings=c("","NA"),colClasses=list(character=c("source","source_record_id")))
prev<-fread(prev_path,na.strings=c("","NA"),colClasses=list(character=c("source","source_record_id")))
old<-fread(old_path,na.strings=c("","NA"))
fresh<-fread(new_path,na.strings=c("","NA"))
need<-c("record_i","record_j","rescored_classification","rescored_rule","review_route")
if(!all(c("idx","source","source_record_id")%in%names(m))||
 !all(c("idx","source","source_record_id")%in%names(prev))||
 !all(need%in%names(old))||!all(need%in%names(fresh))||
 nrow(prev)>nrow(m)||anyDuplicated(m[,.(source,source_record_id)])||
 anyDuplicated(prev[,.(source,source_record_id)])||
 !identical(as.integer(m$idx),seq_len(nrow(m)))||
 !identical(as.integer(prev$idx),seq_len(nrow(prev))))
 stop("Historical identity index is missing or invalid")
if(!identical(m$source[seq_len(nrow(prev))],prev$source)||
 !identical(m$source_record_id[seq_len(nrow(prev))],prev$source_record_id))
 stop("Previous W01 source identities shifted in current metadata; refusing historical decisions")
validate_index<-function(dt,limit){
 i<-as.integer(dt$record_i);j<-as.integer(dt$record_j)
 if(anyNA(i)||anyNA(j)||any(i<1L|j<1L|i>limit|j>limit|i==j))
 stop("Pair indices invalid for their original source-state revision")
 list(i=i,j=j)
}
oi<-validate_index(old,nrow(prev));ni<-validate_index(fresh,nrow(m))
if(!all(old$record_i==oi$i&old$record_j==oi$j))stop("Historical pair indices not integral")
for(side in c("i","j")){
 idx<-if(side=="i")oi$i else oi$j
 source_field<-paste0("source_",side)
 id_field<-paste0("source_record_id_",side)
 if(source_field%in%names(old) &&
 (anyNA(old[[source_field]])||any(old[[source_field]]!=m$source[idx])))
 stop("Historical source namespace does not match trusted original index")
 if(id_field%in%names(old) &&
 (anyNA(old[[id_field]])||any(old[[id_field]]!=m$source_record_id[idx])))
 stop("Historical source ID does not match trusted original index")
}
if(any(ni$i<=nrow(prev)&ni$j<=nrow(prev)))
 stop("Fast update rescored historical pair; abort")
if(anyNA(fresh$rescored_classification)||
 any(!fresh$rescored_classification%in%c("duplicate","unresolved","review"))||
 any(fresh$rescored_classification=="review")||
 any(fresh$review_route=="manual_review"))stop("Pending manual adjudication")
pairkey<-function(z)paste(pmin(z$record_i,z$record_j),pmax(z$record_i,z$record_j),sep="::")
old[,pair_key:=pairkey(old)];fresh[,pair_key:=pairkey(fresh)]
if(anyDuplicated(old$pair_key)||anyDuplicated(fresh$pair_key)||
 any(fresh$pair_key%in%old$pair_key))stop("Duplicate or reassigned historic pair key")
# The production ledger legitimately has no stable record-ID columns. If present
# as optional columns, attach only independently verified current metadata.
for(side in c("i","j")){
 source_field<-paste0("source_",side);id_field<-paste0("source_record_id_",side)
 idx<-if(side=="i")ni$i else ni$j
 if(source_field%in%names(old))fresh[[source_field]]<-m$source[idx]
 if(id_field%in%names(old))fresh[[id_field]]<-m$source_record_id[idx]
}
missing_fields<-setdiff(names(old),names(fresh))
# Null means not evaluated by Fast. It must NOT be described as a positive
# identifier/title-assist finding in publication provenance.
for(k in missing_fields)fresh[[k]]<-NA
discarded_fresh<-setdiff(names(fresh),names(old))
setcolorder(fresh,names(old))
all<-rbindlist(list(old,fresh[,..names(old)]),use.names=TRUE)
if(anyDuplicated(all$pair_key)||nrow(all)!=nrow(old)+nrow(fresh))
 stop("Cumulative ledger count or pair-key integrity failure")
dir.create(dirname(out),recursive=TRUE,showWarnings=FALSE)
fwrite(all,out,na="")
write_json(list(schema="w01-fast-production-ledger-stage-v2",
 historical_decisions=nrow(old),incremental_decisions=nrow(fresh),
 final_decisions=nrow(all),sha256=digest(file=out,algo="sha256"),
 verified_historical_index_prefix=nrow(prev),
 empty_unmeasured_fast_fields=as.list(missing_fields),
 unused_fresh_fields=as.list(discarded_fresh),
 full_identifier_assist_route_parity_proven=FALSE,
 production_publication_allowed=FALSE),
 paste0(out,".audit.json"),pretty=TRUE,auto_unbox=TRUE)
cat(sprintf("PASS: %d prior decisions and %d new; trusted historical numeric indices mapped to stable source identities\\n",nrow(old),nrow(fresh)))

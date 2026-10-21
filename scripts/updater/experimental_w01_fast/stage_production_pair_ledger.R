#!/usr/bin/env Rscript
# Preserve the authoritative W01 pair ledger and append independently rescored
# incremental pairs, verifying every numeric locator against immutable identities.
# No publication and no mutation of inputs.
suppressPackageStartupMessages({library(data.table);library(jsonlite);library(digest)})
a<-commandArgs(trailingOnly=TRUE)
arg<-function(k){i<-match(k,a);if(is.na(i)||i==length(a))stop("Missing ",k);a[[i+1L]]}
prior_path<-arg("--previous-decisions");new_path<-arg("--scored-decisions")
meta_path<-arg("--metadata");out<-arg("--output")
if(any(!file.exists(c(prior_path,new_path,meta_path)))||file.exists(out))
 stop("Missing inputs or output already exists")
identity<-c("source_i","source_record_id_i","source_j","source_record_id_j")
m<-fread(meta_path,na.strings=c("","NA"),colClasses=list(character=c("source","source_record_id")))
old<-fread(prior_path,na.strings=c("","NA"))
fresh<-fread(new_path,na.strings=c("","NA"))
required<-c("record_i","record_j",identity,"rescored_classification","rescored_rule","review_route")
if(!all(c("idx","source","source_record_id")%in%names(m))||
 !all(required%in%names(old))||
 !all(c("record_i","record_j","rescored_classification","rescored_rule","review_route")%in%names(fresh)))
 stop("Missing stable identity/decision fields")
if(anyDuplicated(m[,.(source,source_record_id)])||!identical(as.integer(m$idx),seq_len(nrow(m))))
 stop("Unstable metadata indexing")
lookup<-function(d){
 i<-match(as.integer(d$record_i),m$idx);j<-match(as.integer(d$record_j),m$idx)
 if(anyNA(i)||anyNA(j)||any(i==j))stop("Pair index cannot be resolved")
 list(i=i,j=j)
}
op<-lookup(old)
if(any(old$source_i!=m$source[op$i]|
 old$source_record_id_i!=m$source_record_id[op$i]|
 old$source_j!=m$source[op$j]|
 old$source_record_id_j!=m$source_record_id[op$j]))
 stop("Historical pair numeric identifiers do not agree with stable source identities; abort")
np<-lookup(fresh)
for(k in identity)if(k%in%names(fresh))fresh[[k]]<-NULL
fresh[,source_i:=m$source[np$i]]
fresh[,source_record_id_i:=m$source_record_id[np$i]]
fresh[,source_j:=m$source[np$j]]
fresh[,source_record_id_j:=m$source_record_id[np$j]]
if(anyNA(fresh$rescored_classification)||
 any(!fresh$rescored_classification%in%c("duplicate","unresolved","review"))||
 any(fresh$rescored_classification=="review")||
 any(fresh$review_route=="manual_review"))
 stop("Unresolved human review is not publishable via unattended ledger staging")
pairkey<-function(x)paste(pmin(x$record_i,x$record_j),pmax(x$record_i,x$record_j),sep="::")
old[,pair_key:=pairkey(old)];fresh[,pair_key:=pairkey(fresh)]
if(anyDuplicated(old$pair_key)||anyDuplicated(fresh$pair_key)||
 any(fresh$pair_key%in%old$pair_key))stop("Missing incremental-only pair uniqueness")
if(any(!fresh$record_i%in%m$idx)||any(!fresh$record_j%in%m$idx))stop("Invalid new pairs")
# Avoid filling scientific/provenance columns with invented defaults.
missing_fresh<-setdiff(names(old),names(fresh))
missing_old<-setdiff(names(fresh),names(old))
allowed_descriptive<-c("source_row_index","title_i","title_j","pair_key")
if(length(setdiff(missing_fresh,allowed_descriptive))||
 length(setdiff(missing_old,allowed_descriptive)))
 stop("Production decision contract differs: explicit mapping required; fail closed")
for(nm in missing_fresh)fresh[[nm]]<-NA
for(nm in missing_old)old[[nm]]<-NA
setcolorder(fresh,names(old))
all<-rbindlist(list(old,fresh),use.names=TRUE)
if(anyDuplicated(all$pair_key))stop("Final decision key collision")
dir.create(dirname(out),recursive=TRUE,showWarnings=FALSE)
fwrite(all,out,na="")
write_json(list(schema="w01-fast-production-ledger-stage-v1",
 historical_decisions=nrow(old),incremental_decisions=nrow(fresh),
 final_decisions=nrow(all),sha256=digest(file=out,algo="sha256"),
 production_publication_allowed=FALSE),
 paste0(out,".audit.json"),pretty=TRUE,auto_unbox=TRUE)
cat(sprintf("PASS: %d preserved decisions plus %d new decisions; original numeric locators verified against source identities\\n",nrow(old),nrow(fresh)))

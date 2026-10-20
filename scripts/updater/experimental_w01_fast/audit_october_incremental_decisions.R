#!/usr/bin/env Rscript
# Reconstruct only October incremental classifications from the verified 4MiB tail
# of W01's merged CSV, anchored to its separately recovered authentic header.
suppressPackageStartupMessages({library(data.table);library(jsonlite);library(digest)})
headerfile<-"header/outputs/workflow01_pre_adjudication/combined_pair_decisions.csv"
tailfile<-"tail/outputs/workflow01_pre_adjudication/combined_pair_decisions.csv"
metadatafile<-"metadata/outputs/workflow01_candidates/normalised_metadata.csv"
candidatefile<-"metadata/outputs/workflow01_candidates/all_candidate_pairs.csv"
stopifnot(all(file.exists(c(headerfile,tailfile,metadatafile,candidatefile))))
head<-readLines(headerfile,n=1L,warn=FALSE)
stopifnot(length(head)==1L,grepl("^record_i,record_j,",head))
size<-file.info(tailfile)$size
stopifnot(size<=4194304,size>100L)
con<-file(tailfile,"rb");raw<-readBin(con,"raw",n=size);close(con)
lf<-which(raw==as.raw(10))
if(length(lf)<2L)stop("Insufficient CSV rows in saved range")
# First row is incomplete: the range starts in the middle of the archived CSV.
body<-rawToChar(raw[(lf[[1L]]+1L):length(raw)])
d<-fread(text=paste0(head,"\n",body),colClasses=list(character=c("rescored_classification","rescored_rule","review_route")))
required<-c("record_i","record_j","rescored_classification","rescored_rule","review_route","pair_key")
if(!all(required%in%names(d)))stop("Production decision schema mismatch")
n_prior<-135997L
incremental<-d[pmax(record_i,record_j)>n_prior]
if(nrow(incremental)!=1719L)stop(sprintf("Expected 1719 incremental rows; recovered %d",nrow(incremental)))
m<-fread(metadatafile,colClasses=list(character=c("source","source_record_id")))
if(!all(c("idx","source","source_record_id")%in%names(m))||anyDuplicated(m$idx)||
 anyDuplicated(m[,.(source,source_record_id)]))stop("Invalid frozen manifestation metadata")
i<-match(incremental$record_i,m$idx);j<-match(incremental$record_j,m$idx)
if(anyNA(i)||anyNA(j))stop("Unmapped incremental pair")
encode<-function(s,id)paste0(nchar(s,type="bytes"),":",s,nchar(id,type="bytes"),":",id)
left<-encode(m$source[i],m$source_record_id[i])
right<-encode(m$source[j],m$source_record_id[j])
swapped<-left>right
out<-data.table(source_i=ifelse(swapped,m$source[j],m$source[i]),
 source_record_id_i=ifelse(swapped,m$source_record_id[j],m$source_record_id[i]),
 source_j=ifelse(swapped,m$source[i],m$source[j]),
 source_record_id_j=ifelse(swapped,m$source_record_id[i],m$source_record_id[j]),
 rescored_classification=incremental$rescored_classification,
 rescored_rule=incremental$rescored_rule,
 review_route=incremental$review_route,
 classification=incremental$classification,
 rule=incremental$rule)
pairkeys<-paste0(nchar(pmin(left,right),type="bytes"),":",pmin(left,right),
 nchar(pmax(left,right),type="bytes"),":",pmax(left,right))
if(anyDuplicated(pairkeys))stop("Duplicate stable pair")
candidates<-fread(candidatefile)
if(nrow(candidates)!=1719L||!all(c("record_i","record_j")%in%names(candidates)))
 stop("Unexpected frozen candidate set")
c_i<-match(candidates$record_i,m$idx);c_j<-match(candidates$record_j,m$idx)
if(anyNA(c_i)||anyNA(c_j))stop("Candidate source identity cannot be reconstructed")
cl<-encode(m$source[c_i],m$source_record_id[c_i])
cr<-encode(m$source[c_j],m$source_record_id[c_j])
ck<-paste0(nchar(pmin(cl,cr),type="bytes"),":",pmin(cl,cr),
 nchar(pmax(cl,cr),type="bytes"),":",pmax(cl,cr))
if(!setequal(ck,pairkeys))stop("Incremental decision identity does not equal actual candidate set")
setorder(out,source_i,source_record_id_i,source_j,source_record_id_j)
dir.create("october_decision_identity_audit")
fwrite(out,"october_decision_identity_audit/reference_decisions.csv")
tab<-incremental[,.(count=.N),by=.(rescored_classification,review_route)]
fwrite(tab,"october_decision_identity_audit/classification_counts.csv")
write_json(list(schema="w01-fast-october-stable-decision-reference-v1",
 candidate_pairs=nrow(candidates),decision_pairs=nrow(out),
 unique_stable_pairs=uniqueN(pairkeys),frozen_metadata_sha256=digest(file=metadatafile,algo="sha256"),
 independent_w01_fast_decision_parity=FALSE,production_publication_allowed=FALSE),
 "october_decision_identity_audit/report.json",pretty=TRUE,auto_unbox=TRUE)
cat(sprintf("PASS: %d incremental decisions mapped to immutable identities; no missing candidates\n",nrow(out)))

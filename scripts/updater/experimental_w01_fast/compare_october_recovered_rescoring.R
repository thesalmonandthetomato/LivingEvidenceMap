#!/usr/bin/env Rscript
# Verify unchanged production deterministic rescoring against October reference,
# explicitly distinguishing separately injected identifier-safe pair decisions.
suppressPackageStartupMessages({library(data.table);library(jsonlite)})
input <- "october_recovered_scoring/rescore/rescored_sample.csv"
meta <- "reference/outputs/workflow01_candidates/normalised_metadata.csv"
refdir <- "decision_reference"
if(!all(file.exists(c(input,meta)))||!dir.exists(refdir))stop("Missing independent rescoring or frozen source reference")
paths<-list.files(refdir,pattern="^reference_decisions\\.csv$",recursive=TRUE,full.names=TRUE)
if(length(paths)!=1L)stop("Expected one frozen reference decision table")
s<-fread(input,colClasses=list(character=c("rescored_classification","rescored_rule","review_route")))
m<-fread(meta,colClasses=list(character=c("source","source_record_id")))
r<-fread(paths,colClasses="character")
need<-c("record_i","record_j","rescored_classification","rescored_rule","review_route")
if(nrow(s)!=1719L||nrow(r)!=1719L||!all(need%in%names(s)))stop("Unexpected rescoring result schema")
l<-match(s$record_i,m$idx);ri<-match(s$record_j,m$idx)
if(anyNA(l)||anyNA(ri))stop("Unmapped rescored pair")
key<-function(src,id)paste0(nchar(src,type="bytes"),":",src,nchar(id,type="bytes"),":",id)
pair<-function(a,b)paste0(nchar(pmin(a,b),type="bytes"),":",pmin(a,b),nchar(pmax(a,b),type="bytes"),":",pmax(a,b))
s[,stable_pair:=pair(key(m$source[l],m$source_record_id[l]),key(m$source[ri],m$source_record_id[ri]))]
r[,stable_pair:=pair(key(source_i,source_record_id_i),key(source_j,source_record_id_j))]
if(anyDuplicated(s$stable_pair)||anyDuplicated(r$stable_pair))stop("Duplicate source identity pair")
fields<-c("rescored_classification","rescored_rule","review_route")
j<-merge(s[,c("stable_pair",fields),with=FALSE],r[,c("stable_pair",fields),with=FALSE],
 by="stable_pair",suffixes=c("_independent","_reference"),all=TRUE)
if(nrow(j)!=1719L||anyNA(j[,c("rescored_classification_independent","rescored_classification_reference"),with=FALSE]))stop("Missing frozen candidate pairs")
neq<-function(a,b) !((is.na(a)&is.na(b))|(!is.na(a)&!is.na(b)&a==b))
j[,class_mismatch:=neq(rescored_classification_independent,rescored_classification_reference)]
j[,rule_mismatch:=neq(rescored_rule_independent,rescored_rule_reference)]
j[,route_mismatch:=neq(review_route_independent,review_route_reference)]
j[,identifier_assisted:=rescored_rule_reference=="identifier_safe_preresolve" &
 review_route_reference=="resolved_identifier_assist"]
# A reference identifier decision is not independent merely because another
# scientific rule produced the same classification: keep it as an explicit gate.
j[,other_mismatch:=!identifier_assisted&(class_mismatch|rule_mismatch|route_mismatch)]
out<-"october_recovered_scoring/rescore_comparison"
dir.create(out)
fwrite(j[class_mismatch|rule_mismatch|route_mismatch],
 file.path(out,"rescoring_differences.csv"))
write_json(list(schema="w01-fast-october-independent-rescore-comparison-v1",
 compared_pairs=nrow(j),classification_mismatches=sum(j$class_mismatch),
 rule_mismatches=sum(j$rule_mismatch),route_mismatches=sum(j$route_mismatch),
 identifier_assisted_reference_pairs=sum(j$identifier_assisted),
 other_mismatching_pairs=sum(j$other_mismatch),
 other_pairs_exact_parity=sum(!j$identifier_assisted&!j$other_mismatch),
 complete_identifier_assist_independent_parity=FALSE,
 production_approval=FALSE),file.path(out,"report.json"),auto_unbox=TRUE,pretty=TRUE)
cat(sprintf("COMPARED rescoring: %d pairs, class differences=%d, rule differences=%d, route differences=%d, separately injected identifier pairs=%d, other disagreements=%d\\n",nrow(j),sum(j$class_mismatch),sum(j$rule_mismatch),sum(j$route_mismatch),sum(j$identifier_assisted),sum(j$other_mismatch)))
if(any(j$class_mismatch)||any(j$other_mismatch))stop("Independent deterministic rescoring differs from production outside identifier injection")

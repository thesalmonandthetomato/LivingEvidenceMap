#!/usr/bin/env Rscript
# Compare genuinely rescored October candidates against the preserved pre-adjudication
# base decisions; final identifier/title/rescore routing is a separate acceptance gate.
suppressPackageStartupMessages({library(data.table);library(jsonlite)})
score <- "october_recovered_scoring/base/scored_sample.csv"
meta <- "reference/outputs/workflow01_candidates/normalised_metadata.csv"
refdir <- "decision_reference"
if(!all(file.exists(c(score,meta)))||!dir.exists(refdir))stop("Missing reference or independent scores")
rpaths <- list.files(refdir,pattern="^reference_decisions\\.csv$",recursive=TRUE,full.names=TRUE)
if(length(rpaths)!=1L)stop("Expected exactly one frozen stable-identity decision file")
s <- fread(score,colClasses=list(character=c("classification","rule")))
m <- fread(meta,colClasses=list(character=c("source","source_record_id")))
r <- fread(rpaths,colClasses="character")
if(nrow(s)!=1719L||nrow(r)!=1719L||anyDuplicated(m$idx))stop("Unexpected frozen reference or scorer size")
needed <- c("source_i","source_record_id_i","source_j","source_record_id_j","classification","rule")
if(!all(needed%in%names(r)))stop("Reference decision fields unavailable")
l <- match(s$record_i,m$idx);rr <- match(s$record_j,m$idx)
if(anyNA(l)||anyNA(rr))stop("Independent scored pair has no frozen identity")
key <- function(source,id)paste0(nchar(source,type="bytes"),":",source,nchar(id,type="bytes"),":",id)
pair <- function(a,b)paste0(nchar(pmin(a,b),type="bytes"),":",pmin(a,b),nchar(pmax(a,b),type="bytes"),":",pmax(a,b))
s[, stable_pair := pair(key(m$source[l],m$source_record_id[l]),key(m$source[rr],m$source_record_id[rr]))]
r[, stable_pair := pair(key(source_i,source_record_id_i),key(source_j,source_record_id_j))]
if(anyDuplicated(s$stable_pair)||anyDuplicated(r$stable_pair))stop("Duplicate identity pairs")
joined <- merge(s[,.(stable_pair,score_classification=classification,score_rule=rule)],
 r[,.(stable_pair,reference_classification=classification,reference_rule=rule)],
 by="stable_pair",all=TRUE)
if(nrow(joined)!=1719L||anyNA(joined[,.(score_classification,reference_classification)]))stop("Missing pair identity in independent scoring")
different <- joined[is.na(score_classification)!=is.na(reference_classification)|
 is.na(score_rule)!=is.na(reference_rule)|
 (!is.na(score_classification)&!is.na(reference_classification)&score_classification!=reference_classification)|
 (!is.na(score_rule)&!is.na(reference_rule)&score_rule!=reference_rule)]
out<-"october_recovered_scoring/base_comparison"
dir.create(out)
fwrite(different,file.path(out,"base_score_differences.csv"))
write_json(list(schema="w01-fast-october-independent-base-score-comparison-v1",
 compared_pairs=nrow(joined),classification_or_rule_differences=nrow(different),
 base_score_parity_passed=nrow(different)==0L,
 final_scoring_and_review_route_parity_established=FALSE),
 file.path(out,"report.json"),pretty=TRUE,auto_unbox=TRUE)
cat(sprintf("COMPARED: %d base-scored pairs; differences=%d\\n",nrow(joined),nrow(different)))
# Differences are preserved as test output, with no false claim of final parity.

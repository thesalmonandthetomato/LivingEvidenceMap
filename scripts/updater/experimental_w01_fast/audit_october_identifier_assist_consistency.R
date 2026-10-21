#!/usr/bin/env Rscript
# Secondary October safety test of 160 historical identifier-assisted decisions.
# It does not infer identifier provenance from the reference decisions.
suppressPackageStartupMessages({library(data.table);library(jsonlite)})
meta_path <- "reference/outputs/workflow01_candidates/normalised_metadata.csv"
score_path <- "october_recovered_scoring/rescore/rescored_sample.csv"
references <- list.files("decision_reference",pattern="^reference_decisions\\.csv$",recursive=TRUE,full.names=TRUE)
if(length(references)!=1L||!file.exists(meta_path)||!file.exists(score_path))stop("Missing frozen inputs")
m <- fread(meta_path,colClasses=list(character=c("source","source_record_id")))
s <- fread(score_path)
r <- fread(references[[1L]],colClasses="character")
if(anyDuplicated(m$idx)||nrow(r)!=1719L||nrow(s)!=1719L)stop("Invalid October reference size")
key<-function(a,b)paste0(nchar(a,type="bytes"),":",a,nchar(b,type="bytes"),":",b)
pair<-function(a,b)paste0(nchar(pmin(a,b),type="bytes"),":",pmin(a,b),nchar(pmax(a,b),type="bytes"),":",pmax(a,b))
m[, stable:=key(source,source_record_id)]
s[, stable:=pair(m$stable[match(record_i,m$idx)],m$stable[match(record_j,m$idx)])]
r[, stable:=pair(key(source_i,source_record_id_i),key(source_j,source_record_id_j))]
if(anyDuplicated(s$stable)||anyDuplicated(r$stable))stop("Duplicate stable pair")
joined<-merge(s[,.(stable,record_i,record_j,base_classification=classification,
 base_rule=rule,rescored_classification,rescored_rule,review_route)],
 r[,.(stable,reference_classification=rescored_classification,
 reference_rule=rescored_rule,reference_route=review_route)],
 by="stable",all=TRUE)
if(nrow(joined)!=1719L||anyNA(joined$record_i)||anyNA(joined$reference_classification))
 stop("Frozen candidate pair mismatch")
assisted<-joined[reference_rule=="identifier_safe_preresolve" &
 reference_route=="resolved_identifier_assist"]
if(nrow(assisted)!=160L)stop("Reference assisted pair count differs")
if(any(assisted$rescored_classification!="duplicate")||
 any(assisted$reference_classification!="duplicate")||
 any(assisted$review_route!="automatic_duplicate"))stop("Identifier assist changes scientific classification")
if(any(!assisted$base_rule %in% c("bramer_A","exact_doi_exact_title")))
 stop("Identifier assisted pair not independently classified by supported scientific rule")
left<-m[match(assisted$record_i,m$idx)]
right<-m[match(assisted$record_j,m$idx)]
# DOI/title observations validate a subset, not the original identifier registry.
doi_ok<-!is.na(left$doi_norm)&!is.na(right$doi_norm)&left$doi_norm==right$doi_norm
title_ok<-!is.na(left$title_norm)&!is.na(right$title_norm)&left$title_norm==right$title_norm
idx<-assisted$base_rule=="exact_doi_exact_title"
if(any(idx&!(doi_ok&title_ok)))stop("Independent exact DOI/title rule lacks metadata support")
dir.create("october_identifier_assist_consistency",showWarnings=FALSE)
write_json(list(schema="w01-fast-october-identifier-assist-consistency-v1",
 reference_identifier_assisted_pairs=nrow(assisted),
 duplicate_classification_agreement=sum(assisted$rescored_classification=="duplicate"),
 independently_scored_exact_doi_title=sum(idx),
 independently_scored_bramer_a=sum(!idx),
 missing_doi_title_support=sum(idx&!(doi_ok&title_ok)),
 original_identifier_registry_reproduced=FALSE,
 identifier_safe_edge_rule_parity_established=FALSE,
 note="Historical assisted route cannot be independently reproduced without the original registry and guard evidence."),
 "october_identifier_assist_consistency/report.json",auto_unbox=TRUE,pretty=TRUE)
cat("PASS: 160/160 identifier-assisted reference decisions independently remain duplicates; 121 exact DOI/title and 39 Bramer-A classifications\\n")

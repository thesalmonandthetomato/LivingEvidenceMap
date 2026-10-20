#!/usr/bin/env Rscript
# Convert production's transient pair offsets to stable source identities,
# using the exact saved production metadata and refusing ambiguous mappings.
suppressPackageStartupMessages({library(data.table);library(digest);library(jsonlite)})
base<-commandArgs(trailingOnly=TRUE)
root<-if(length(base))base[[1]] else "reference"
meta_path<-file.path(root,"outputs/workflow01_candidates/normalised_metadata.csv")
pairs_path<-file.path(root,"outputs/workflow01_candidates/all_candidate_pairs.csv")
meta<-fread(meta_path,colClasses=list(character=c("source","source_record_id")))
pairs<-fread(pairs_path)
required<-c("idx","source","source_record_id")
if(!all(required%in%names(meta))||!all(c("record_i","record_j")%in%names(pairs)))
 stop("Missing reference metadata or candidate indices")
if(anyNA(meta[,..required])||anyDuplicated(meta$idx)||
 anyDuplicated(meta[,.(source,source_record_id)])||
 any(!nzchar(meta$source)|!nzchar(meta$source_record_id)))
 stop("Invalid authoritative metadata")
if(anyNA(pairs[,.(record_i,record_j)])||any(pairs$record_i==pairs$record_j))
 stop("Invalid candidate indices")
i<-match(pairs$record_i,meta$idx)
j<-match(pairs$record_j,meta$idx)
if(anyNA(i)||anyNA(j))stop("Candidate refers to unknown manifestation offset")
encode<-function(s,id)paste0(nchar(s,type="bytes"),":",s,nchar(id,type="bytes"),":",id)
ka<-encode(meta$source[i],meta$source_record_id[i])
kb<-encode(meta$source[j],meta$source_record_id[j])
a_first<-ka<kb
stable<-data.table(
 source_a=ifelse(a_first,meta$source[i],meta$source[j]),
 source_record_id_a=ifelse(a_first,meta$source_record_id[i],meta$source_record_id[j]),
 source_b=ifelse(a_first,meta$source[j],meta$source[i]),
 source_record_id_b=ifelse(a_first,meta$source_record_id[j],meta$source_record_id[i]))
evidence<-setdiff(names(pairs),c("record_i","record_j","idx","source_i","source_j","source_record_id_i","source_record_id_j"))
for(col in evidence)stable[[col]]<-as.character(pairs[[col]])
key<-paste0(nchar(pmin(ka,kb),type="bytes"),":",pmin(ka,kb),
 nchar(pmax(ka,kb),type="bytes"),":",pmax(ka,kb))
if(anyDuplicated(key))stop("Duplicate candidate stable identities")
setorder(stable,source_a,source_record_id_a,source_b,source_record_id_b)
dir.create("candidate_identity_audit",showWarnings=FALSE)
fwrite(stable,"candidate_identity_audit/reference_pairs.csv")
jsonlite::write_json(list(schema="w01-fast-october-candidate-reference-v1",
 metadata_rows=nrow(meta),candidate_pairs=nrow(pairs),
 unique_stable_pairs=uniqueN(key),
 metadata_sha256=digest(file=meta_path,algo="sha256"),
 candidate_sha256=digest(file=pairs_path,algo="sha256"),
 independently_generated_fast_pairs_compared=FALSE),
 "candidate_identity_audit/report.json",auto_unbox=TRUE,pretty=TRUE)
cat(sprintf("PASS: %d production pairs mapped to stable source identities against %d source records\n",nrow(pairs),nrow(meta)))

#!/usr/bin/env Rscript
# October independent scientific scoring -> incremental clusters, no reference
# decisions used as inputs to clustering. Reference is used only for comparison.
suppressPackageStartupMessages({library(data.table);library(jsonlite)})
meta_path <- "reference/outputs/workflow01_candidates/normalised_metadata.csv"
scored_path <- "october_recovered_scoring/rescore/rescored_sample.csv"
previous_path <- "reference/previous_state/workflow01_full_five_source/manifestation_cluster_map.csv"
final_path <- "reference/outputs/final/manifestation_cluster_map.csv"
if(!all(file.exists(c(meta_path,scored_path,previous_path,final_path))))stop("Missing frozen scientific inputs")
out <- "october_independent_scored_clusters"
if(file.exists(out)||dir.exists(out))stop("Refuse to overwrite independent cluster audit")
dir.create(out)
meta<-fread(meta_path,colClasses=list(character=c("source","source_record_id")))
sc<-fread(scored_path)
old<-fread(previous_path,colClasses=list(character=c("source","source_record_id","cluster_id")))
reference<-fread(final_path,colClasses=list(character=c("source","source_record_id","cluster_id")))
if(nrow(sc)!=1719L||nrow(meta)!=136057L||nrow(old)!=135997L||nrow(reference)!=136057L)
 stop("Unexpected historical October scientific counts")
i<-match(sc$record_i,meta$idx);j<-match(sc$record_j,meta$idx)
if(anyNA(i)||anyNA(j))stop("Scored pair not mapped to frozen manifestation")
dec<-data.table(source_i=meta$source[i],source_record_id_i=meta$source_record_id[i],
 source_j=meta$source[j],source_record_id_j=meta$source_record_id[j],
 rescored_classification=sc$rescored_classification,
 rescored_rule=sc$rescored_rule,review_route=sc$review_route)
if(anyNA(dec)||anyDuplicated(dec))stop("Unmapped or duplicated scored decisions")
fwrite(dec,file.path(out,"independently_scored_stable_decisions.csv"))
script<-"scripts/updater/experimental_w01_fast/update_clusters_by_identity.R"
cmd<-c(script,"--prior-map",previous_path,"--metadata",meta_path,
 "--incremental-decisions",file.path(out,"independently_scored_stable_decisions.csv"),
 "--output-dir",file.path(out,"clusters"))
start<-proc.time()[["elapsed"]]
messages<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),cmd,stdout=TRUE,stderr=TRUE))
code<-attr(messages,"status");if(is.null(code))code<-0L
if(code!=0L)stop("Independent identity clustering failed: ",paste(tail(messages,25L),collapse=" | "))
seconds<-unname(proc.time()[["elapsed"]]-start)
fast<-fread(file.path(out,"clusters","identity_cluster_map.csv"),
 colClasses=list(character=c("source","source_record_id","cluster_id")))
key<-function(d)paste0(nchar(d$source,type="bytes"),":",d$source,nchar(d$source_record_id,type="bytes"),":",d$source_record_id)
reference[,stable:=key(reference)]
fast[,stable:=key(fast)]
if(anyDuplicated(fast$stable)||anyDuplicated(reference$stable)||!setequal(reference$stable,fast$stable))
 stop("Independent clusters differ in manifestation identity coverage")
loc<-match(reference$stable,fast$stable)
different<-reference[cluster_id!=fast$cluster_id[loc]|
 cluster_size!=fast$cluster_size[loc],.(source,source_record_id,cluster_id,cluster_size)]
fwrite(different,file.path(out,"cluster_differences.csv"))
if(sum(dec$rescored_classification=="duplicate")!=176L)stop("Unexpected independently approved duplicate edge count")
write_json(list(schema="w01-fast-october-independent-scoring-to-cluster-v1",
 independently_scored_pairs=nrow(dec),
 independently_approved_duplicates=sum(dec$rescored_classification=="duplicate"),
 total_manifestations=nrow(fast),
 final_clusters=uniqueN(fast$cluster_id),
 mismatched_cluster_memberships=nrow(different),
 elapsed_cluster_seconds=round(seconds,3),
 original_identifier_route_provenance_parity_established=FALSE,
 original_raw_source_parity_established=FALSE,
 used_reference_decisions_to_construct_clusters=FALSE,
 ready_for_production=FALSE),
 file.path(out,"report.json"),auto_unbox=TRUE,pretty=TRUE)
if(nrow(different))stop("Independent scientific cluster map differs from original W01")
cat(sprintf("PASS: 1719 independently scored October pairs reproduce %d memberships and %d work IDs; clustering %.3f seconds\\n",
 nrow(fast),uniqueN(fast$cluster_id),seconds))

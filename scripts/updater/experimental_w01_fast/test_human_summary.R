#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(data.table);library(jsonlite)})
root<-tempfile("w01-human-summary-");dir.create(root)
on.exit(unlink(root,recursive=TRUE),add=TRUE)
at<-function(n)file.path(root,n)
m<-data.table(idx=1:3,source=c("a","b","c"),source_record_id=c("1","2","3"))
fwrite(m,at("meta.csv"))
prior<-copy(m[1:2]);prior[,cluster_id:=c("w1","w2")];prior[,cluster_size:=1L]
fwrite(prior,at("prior.csv"))
clusters<-copy(m);clusters[,cluster_id:=c("w1","w2","w1")];clusters[,cluster_size:=c(2L,1L,2L)]
fwrite(clusters,at("clusters.csv"))
dec<-data.table(record_i=c(1L,1L),record_j=c(2L,3L),
 rescored_classification=c("unresolved","duplicate"),
 rescored_rule=c("historic","human_duplicate"),
 review_route=c("non_duplicate","human_duplicate"),
 pair_key=c("1::2","1::3"))
fwrite(dec,at("decisions.csv"))
write_json(list(historical_decisions=1L,incremental_decisions=1L,final_decisions=2L),
 paste0(at("decisions.csv"),".audit.json"),auto_unbox=TRUE)
args<-c("scripts/updater/experimental_w01_fast/stage_production_final_map.R",
 "--metadata",at("meta.csv"),"--clusters",at("clusters.csv"),
 "--final-decisions",at("decisions.csv"),"--prior-map",at("prior.csv"),"--output-dir",at("final"))
z<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),args,stdout=TRUE,stderr=TRUE))
if(!is.null(attr(z,"status"))&&attr(z,"status")!=0L)stop(paste(z,collapse=" | "))
res<-fromJSON(at("final/summary.json"))
stopifnot(res$human_final_decisions==1L,res$adjudicated_cases==1L,
res$automatic_duplicate_edges==0L,res$manual_review_pairs==1L)
cat("PASS: human decisions correctly attributed; historic decisions not re-counted\n")

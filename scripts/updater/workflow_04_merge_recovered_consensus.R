#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(jsonlite))

args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
input_root<-arg("--input-root")
output_dir<-arg("--output-dir","outputs/workflow04_consensus_recovered")
expected_files<-as.integer(arg("--expected-files","11"))
if(is.null(input_root))stop("--input-root is required",call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

`%||%`<-function(x,y)if(is.null(x))y else x
scalar<-function(x){if(is.null(x)||!length(x))return("");z<-as.character(x[[1L]]);if(is.na(z))"" else trimws(z)}
read_jsonl<-function(path){x<-readLines(path,warn=FALSE,encoding="UTF-8");x<-x[nzchar(trimws(x))];lapply(seq_along(x),function(i)fromJSON(x[[i]],simplifyVector=FALSE))}
write_jsonl<-function(rows,path){con<-file(path,"wt",encoding="UTF-8");on.exit(close(con));for(x in rows)writeLines(toJSON(x,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)}

sum_files<-list.files(input_root,pattern="summary\\.json$",recursive=TRUE,full.names=TRUE)
layer_files<-list.files(input_root,pattern="workflow04_consensus_layer\\.jsonl$",recursive=TRUE,full.names=TRUE)
if(length(sum_files)!=expected_files||length(layer_files)!=expected_files){
  stop(sprintf("Expected %d summaries/layers; found %d/%d",expected_files,length(sum_files),length(layer_files)),call.=FALSE)
}
summaries<-lapply(sum_files,fromJSON,simplifyVector=FALSE)
expected_sha<-"ab71cad800996f2aea4cf1313c3ab749017f01094946830671f2f579a4710f69"
if(any(vapply(summaries,function(x)!identical(scalar(x$prompt_sha256),expected_sha),logical(1))))stop("Prompt SHA mismatch across inputs",call.=FALSE)
if(any(vapply(summaries,function(x)as.integer(x$workflow03_eligible)!=32283L,logical(1))))stop("W03 eligible count mismatch across inputs",call.=FALSE)

rows<-unlist(lapply(layer_files,read_jsonl),recursive=FALSE)
ids<-vapply(rows,function(x)scalar(x$record_id),character(1))
if(length(rows)!=32283L)stop(sprintf("Expected 32,283 consensus rows, found %d",length(rows)),call.=FALSE)
if(any(!nzchar(ids))||anyDuplicated(ids))stop("Recovered consensus record_id invariant failed",call.=FALSE)

dec<-vapply(rows,function(x)scalar((x$screening %||% list())$decision),character(1))
if(any(!dec%in%c("retain","exclude","uncertain")))stop("Invalid final decision in recovered layer",call.=FALSE)
pv<-vapply(rows,function(x)scalar((x$screening %||% list())$prompt_sha256),character(1))
if(any(pv!=expected_sha))stop("Recovered row prompt SHA mismatch",call.=FALSE)

ord<-order(ids);rows<-rows[ord];dec<-dec[ord]
write_jsonl(rows,file.path(output_dir,"workflow04_consensus_layer.jsonl"))

summary<-list(
 schema="living-evidence-map-workflow04-luna-consensus-recovered-v1",
 status=if(any(dec=="uncertain"))"HUMAN_REVIEW_REQUIRED" else "PASS",
 source_failed_run=36186630247,
 workflow03_eligible=32283L,
 consensus_records=length(rows),
 final_retain=sum(dec=="retain"),
 final_exclude=sum(dec=="exclude"),
 final_unresolved=sum(dec=="uncertain"),
 pass1_records=sum(vapply(summaries,function(x)as.integer(x$pass1_records),integer(1))),
 pass2_records=sum(vapply(summaries,function(x)as.integer(x$pass2_records),integer(1))),
 third_pass_records=sum(vapply(summaries,function(x)as.integer(x$third_pass_records),integer(1))),
 two_of_two_agreement=sum(vapply(summaries,function(x)as.integer(x$two_of_two_agreement),integer(1))),
 model=scalar(summaries[[1]]$model),
 prompt_version=scalar(summaries[[1]]$prompt_version),
 prompt_sha256=expected_sha,
 input_result_files=expected_files,
 created_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),file.path(output_dir,"summary.json"),useBytes=TRUE)
cat(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),"\n")

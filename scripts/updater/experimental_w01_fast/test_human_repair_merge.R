#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(jsonlite))
root<-tempfile("fast-repair-ledger-");dir.create(root)
on.exit(unlink(root,recursive=TRUE,force=TRUE),add=TRUE)
at<-function(n)file.path(root,n)
line<-function(id,action,value=NULL)toJSON(list(review_case_id=id,source="a",
 source_record_id="1",action=action,value=value,reason="fixture"),auto_unbox=TRUE,null="null")
writeLines(line("old","set_title","Previous"),at("previous.jsonl"))
writeLines(line("new","replace_abstract","Corrected"),at("new.jsonl"))
writeLines(toJSON(list(source="a",source_record_id="1",reason="historic"),auto_unbox=TRUE),at("previous_strips.jsonl"))
file.create(at("new_strips.jsonl"))
base<-c("scripts/updater/workflow_01_merge_cumulative_repairs.R",
 "--previous-repairs",at("previous.jsonl"),"--new-repairs",at("new.jsonl"),
 "--previous-strips",at("previous_strips.jsonl"),"--new-strips",at("new_strips.jsonl"),
 "--output-repairs",at("cumulative.jsonl"),"--output-strips",at("strips.jsonl"))
call<-function(a)system2(file.path(R.home("bin"),"Rscript"),a,stdout=TRUE,stderr=TRUE)
x<-suppressWarnings(call(base))
if(!is.null(attr(x,"status"))&&attr(x,"status")!=0L)stop(paste(x,collapse=" | "))
r<-lapply(readLines(at("cumulative.jsonl")),fromJSON)
stopifnot(length(r)==2L,setequal(vapply(r,function(z)z$action,character(1)),
 c("set_title","replace_abstract")),length(readLines(at("strips.jsonl")))==1L)
writeLines(c(readLines(at("new.jsonl")),readLines(at("new.jsonl"))),at("duplicate.jsonl"))
bad<-base;bad[match("--new-repairs",bad)+1L]<-at("duplicate.jsonl")
y<-suppressWarnings(call(bad))
stopifnot(!is.null(attr(y,"status")),attr(y,"status")!=0L)
cat("PASS: original W01 repair merger retains historic edits, adds review edits, and rejects duplicate keys\n")

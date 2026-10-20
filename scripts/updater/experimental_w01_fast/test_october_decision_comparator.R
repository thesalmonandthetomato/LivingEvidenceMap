#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(data.table))
dir<-tempfile("decision-parity-");dir.create(dir)
base<-data.table(source_i="cab",source_record_id_i="a|b",source_j="lens",
 source_record_id_j="c:d",rescored_classification="unresolved",rescored_rule="test",
 review_route="non_duplicate")
ref<-file.path(dir,"ref.csv");fast<-file.path(dir,"fast.csv")
fwrite(base,ref);fwrite(base,fast)
script<-"scripts/updater/experimental_w01_fast/compare_october_decision_classifications.R"
run<-function(label,should_pass){
 command<-c(script,"--reference",ref,"--fast",fast,"--output-dir",file.path(dir,label))
 x<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),command,stdout=TRUE,stderr=TRUE))
 code<-attr(x,"status");if(is.null(code))code<-0L
 if((code==0L)!=should_pass)stop(paste("Unexpected comparator status",label,code,paste(x,collapse=" | ")))
}
run("exact",TRUE)
reversed<-copy(base)
set(reversed,j="source_i",value="lens");set(reversed,j="source_record_id_i",value="c:d")
set(reversed,j="source_j",value="cab");set(reversed,j="source_record_id_j",value="a|b")
fwrite(reversed,fast);run("reversed",TRUE)
reversed[,review_route:="manual_review"];fwrite(reversed,fast);run("route-change",FALSE)
reversed[,review_route:="non_duplicate"];reversed[,rescored_classification:="not_duplicate"]
fwrite(reversed,fast);run("classification-change",FALSE)
reversed[,rescored_classification:="unresolved"];reversed[,record_i:=1L]
fwrite(reversed,fast);run("positional",FALSE)
cat("PASS: independent decision comparator accepts pair orientation only; rejects classification, route and positional changes\n")

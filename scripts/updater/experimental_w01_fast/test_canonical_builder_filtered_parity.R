#!/usr/bin/env Rscript
# Small end-to-end fixture: unchanged canonical builder on full corpus vs
# identity-filtered affected sources. Never accesses GitHub production state.
suppressPackageStartupMessages({library(data.table);library(jsonlite)})
root<-tempfile("canonical-parity-");dir.create(root)
runner<-file.path(R.home("bin"),"Rscript")
run<-function(script,args){
 log<-suppressWarnings(system2(runner,c(script,args),stdout=TRUE,stderr=TRUE))
 status<-attr(log,"status");if(is.null(status))status<-0L
 if(status!=0L)stop(sprintf("Script %s failed: %s",script,paste(log,collapse=" | ")))
}
record<-function(id)toJSON(list(identity=list(lens_id=id),
 canonical=list(title=paste("Article",id),abstract=paste("Abstract",id),
 year=2024,doi=paste0("10.1111/",id)),
 lens=list(raw_payload=list(title=paste("Article",id)))),auto_unbox=TRUE)
source<-file.path(root,"lens.jsonl")
writeLines(vapply(c("A","B","C"),record,character(1)),source)
im<-file.path(root,"inputs.json")
writeLines(toJSON(list(schema="living-evidence-map-workflow01-source-inputs-v1",
 sources=list(lens=list(source))),auto_unbox=TRUE),im)
map<-data.table(source="lens",source_record_id=c("A","B","C"),
 cluster_id=c("work-affected","work-affected","work-untouched"),
 cluster_size=c(2L,2L,1L))
fullmap<-file.path(root,"fullmap.csv");fwrite(map,fullmap)
scope<-file.path(root,"scope.csv");fwrite(map[cluster_id=="work-affected"],scope)
filter_out<-file.path(root,"filtered")
run("scripts/updater/experimental_w01_fast/filter_canonical_source_inputs.R",
 c("--affected-cluster-map",scope,"--input-manifest",im,"--output-dir",filter_out))
builder<-"scripts/updater/workflow_01_build_canonical_jsonl.R"
strips<-file.path(root,"strips.jsonl")
repairs<-file.path(root,"repairs.jsonl")
writeLines(toJSON(list(source="lens",source_record_id="A"),auto_unbox=TRUE),strips)
writeLines(toJSON(list(source="lens",source_record_id="B",action="set_title",value="Corrected B",review_case_id="fixture-1"),auto_unbox=TRUE),repairs)
directives<-file.path(root,"filtered-directives")
run("scripts/updater/experimental_w01_fast/filter_canonical_directives.R",
 c("--affected-cluster-map",scope,"--strip-actions",strips,
 "--data-quality-repairs",repairs,"--output-dir",directives))
canonical<-function(map_path,input_manifest,dir,strip_path,repairs_path){
 dir.create(dir)
 output<-file.path(dir,"canonical.jsonl")
 run(builder,c("--cluster-map",map_path,"--input-manifest",input_manifest,
 "--run-id","synthetic-test","--strip-actions",strip_path,
 "--data-quality-repairs",repairs_path,"--output",output,
 "--manifest",file.path(dir,"manifest.json"),
 "--repair-audit",file.path(dir,"repair_audit.jsonl")))
 lapply(readLines(output,warn=FALSE),function(line)fromJSON(line,simplifyVector=FALSE))
}
all<-canonical(fullmap,im,file.path(root,"full"),strips,repairs)
part<-canonical(scope,file.path(filter_out,"filtered_source_inputs.json"),
 file.path(root,"partial"),file.path(directives,"strip_actions.jsonl"),
 file.path(directives,"data_quality_repairs.jsonl"))
find_work<-function(records,id){
 hits<-Filter(function(rec)identical(rec$deduplication$cluster_id,id),records)
 if(length(hits)!=1L)stop("Missing or duplicate canonical work");hits[[1L]]
}
# The identical original scientific materialiser must produce the same work
# record whether invoked on the full corpus or on exact affected-source subset.
stopifnot(length(all)==2L,length(part)==1L,
 identical(find_work(all,"work-affected"),find_work(part,"work-affected")))
stopifnot(identical(readLines(file.path(root,"full","repair_audit.jsonl")),
 readLines(file.path(root,"partial","repair_audit.jsonl"))))
cat("PASS: unchanged canonical builder parity including strip action and approved repair\\n")

suppressPackageStartupMessages(library(jsonlite))
p<-tempfile(fileext=".json")
base<-list(status="published",review_id="almeria-map",github_run_id="1234",
  zenodo_record_id="5678",visibility="restricted",sources=c("lens","openalex"),
  manifest_sha256=paste(rep("a",64),collapse=""))
run<-function(x,review="almeria-map",id="1234",pass=TRUE){
  write_json(x,p,auto_unbox=TRUE)
  out<-suppressWarnings(system2("Rscript",c("scripts/updater/workflow_00_validate_shiny_handoff.R",
    "--receipt",p,"--review-id",review,"--run-id",id),stdout=TRUE,stderr=TRUE))
  success<-is.null(attr(out,"status")) || identical(as.integer(attr(out,"status")),0L)
  if(!identical(success,pass))stop(paste("Unexpected handoff outcome:",paste(out,collapse=" | ")),call.=FALSE)
}
run(base)
run(base,review="another-map",pass=FALSE)
run(base,id="9999",pass=FALSE)
x<-base;x$status<-"draft_created";run(x,pass=FALSE)
x<-base;x$visibility<-"public";run(x,pass=FALSE)
x<-base;x$zenodo_record_id<-"other";run(x,pass=FALSE)
x<-base;x$sources<-c("lens","lens");run(x,pass=FALSE)
x<-base;x$manifest_sha256<-"abc";run(x,pass=FALSE)
cat("PASS: synthetic review-specific W00 handoff contract and rejection cases\n")

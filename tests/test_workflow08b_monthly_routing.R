# Offline regression of production routing scripts; no provider or publication calls.
library(jsonlite)
root <- tempfile();dir.create(root)
r <- file.path(root,"release.json");g<-file.path(root,"registry.json");s<-file.path(root,"state.json");o<-file.path(root,"decision.json")
sha<-function(a)paste(rep(a,64),collapse="")
original<-list(update_id="w00-run-100",update_month="2026-12",w08_run_id="200",w08_canonical_sha256=sha("a"),w01_run_id="101")
supplemental<-original;supplemental$w08_run_id<-"300";supplemental$w08_canonical_sha256<-sha("b");supplemental$w01_run_id<-"201"
writej<-function(x,p)write_json(x,p,auto_unbox=TRUE,pretty=TRUE)
writej(list(schema="workflow08b-monthly-checkpoint-registry-v1",checkpoints=list(list(month="2026-11",status="verified_archive"))),g)
call<-function(script,args,ok=TRUE){
 result<-suppressWarnings(system2("Rscript",c(file.path("scripts/workflow08b",script),args),stdout=TRUE,stderr=TRUE))
 code<-attr(result,"status"); if(is.null(code))code<-0L
 if((code==0L)!=ok)stop(paste(result,collapse="\n"))
}
route<-function(x,gen,expected=NULL){
 writej(x,r);unlink(o)
 call("route_after_w08.R",c(r,g,s,gen,o),!is.null(expected))
 if(is.null(expected)){stopifnot(!file.exists(o));return(invisible(NULL))}
 z<-fromJSON(o)
 stopifnot(identical(z$transition,expected),isTRUE(z$second_citation_generation_forbidden),
   identical(z$dispatch_w08b,expected=="start_first_citation_generation"),
   identical(z$dispatch_w09,expected=="publish_final_w09_w10"))
}
event<-function(e,x,ok=TRUE,extra=character()){
 writej(x,r);call("record_routing_event.R",c(e,r,s,extra),ok)
}
route(original,"original","start_first_citation_generation")
route(supplemental,"supplemental")
event("init",original)
event("init",original,FALSE)
route(original,"original","await_existing_citation_generation")
route(supplemental,"supplemental")
wrong<-original;wrong$w08_canonical_sha256<-sha("c")
route(wrong,"original")
event("candidates_started",original)
event("supplemental_w01_started",original,extra="201")
event("supplemental_w01_started",original,FALSE,extra="202")
route(original,"original","await_existing_citation_generation")
route(supplemental,"supplemental","publish_final_w09_w10")
event("completed",supplemental)
route(supplemental,"supplemental","already_published")
wrong<-supplemental;wrong$w08_run_id<-"301"
route(wrong,"supplemental")
wrong<-supplemental;wrong$w08_canonical_sha256<-sha("c")
route(wrong,"supplemental")
route(original,"original")
event("completed",supplemental,FALSE)
unlink(s)
event("init",original)
event("no_supplemental",original)
route(original,"original","publish_final_w09_w10")
event("completed",original)
route(original,"original","already_published")
event("init",original,FALSE)
cat("PASS: December routing, duplicate triggers, no-candidate completion, exact final identity, single generation\n")

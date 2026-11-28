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


# Mandatory provider-side eligibility precedes the candidate safeguard and bibliography.
wf<-readLines(".github/workflows/workflow08b_monthly_candidates.yml",warn=FALSE)
at<-function(s){i<-grep(s,wf,fixed=TRUE);stopifnot(length(i)==1L);i}
stopifnot(at("id: lens_not")<at("id: eligibility"),
          at("id: openalex_not")<at("id: eligibility"),
          at("Post-NOT candidate safeguard exceeded")>at("id: eligibility"),
          at("Post-NOT candidate safeguard exceeded")<at("id: bibliographies"),
          at("steps.eligibility.outcome == 'success'")>at("id: bibliographies"))
lens<-readLines("scripts/workflow08b/lens_species_not_farming_ids.R",warn=FALSE)
oa<-readLines("scripts/workflow08b/harvest_openalex_eligible.R",warn=FALSE)
stopifnot(any(grepl("query=species",lens,fixed=TRUE)),
          any(grepl("must_not=list(list(query_string=list(query=farming)))",lens,fixed=TRUE)),
          any(grepl('paste0("(",sp,") NOT (",fm,")")',oa,fixed=TRUE)))
parse(file="scripts/workflow08b/lens_species_not_farming_ids.R")
parse(file="scripts/workflow08b/harvest_openalex_eligible.R")
# Exercise the actual inline eligibility R code, without provider calls.
start<-at("id: eligibility"); end<-at("id: bibliographies")
block<-wf[start:end]
lo<-grep("Rscript -e '",block,fixed=TRUE); hi<-grep("PASS: eligible provider IDs:",block,fixed=TRUE)
stopifnot(length(lo)==1L,length(hi)==1L,hi>lo)
code<-paste(c(block[(lo+1L):(hi-1L)],sub("'$","",block[hi])),collapse="\n")
fixture<-tempfile();dir.create(fixture)
for(d in c("lens_eligible","openalex_eligible","w08b_candidates"))dir.create(file.path(fixture,d))
writej(list(lens_candidates=400000L,openalex_candidates=91984L,require_provider_not_filter=491984L),file.path(fixture,"w08b_candidates/summary.json"))
provider<-function(p,n,eligible,flag=TRUE){
 d<-file.path(fixture,paste0(p,"_eligible"))
 write.csv(data.frame(provider=rep(p,eligible),related_provider_id=seq_len(eligible)),file.path(d,paste0("eligible_",p,"_ids.csv")),row.names=FALSE)
 writej(list(candidate_ids=n,eligible_ids=eligible,provider_side_species_and_not_farming=flag),file.path(d,"summary.json"))
}
check<-function(ok){
 z<-tryCatch({eval(parse(text=code),envir=new.env());TRUE},error=function(e)FALSE)
 stopifnot(identical(z,ok))
}
local({
 old<-Sys.getenv(c("RUNNER_TEMP","MAX_NOVEL"),unset=NA_character_)
 on.exit(for(k in names(old))if(is.na(old[[k]]))Sys.unsetenv(k)else do.call(Sys.setenv,setNames(list(old[[k]]),k)))
 Sys.setenv(RUNNER_TEMP=fixture,MAX_NOVEL="50000")
 provider("lens",400000L,200L);provider("openalex",91984L,300L);check(TRUE)
 provider("lens",400000L,50001L);check(FALSE)
 provider("lens",400000L,0L);provider("openalex",91984L,0L);check(TRUE)
 provider("lens",400000L,0L,FALSE);check(FALSE)
 provider("lens",399999L,0L);check(FALSE)
})
cat("PASS: monthly species AND NOT farming gate, post-filter cap, empty results and fail-closed cases\n")

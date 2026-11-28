# Offline test of the production Lens retrieval script.
library(jsonlite)
(function(){
 root<-tempfile("lens-coverage-");dir.create(root)
 on.exit(unlink(root,recursive=TRUE),add=TRUE)
 manifest<-file.path(root,"manifest.csv");fixture<-file.path(root,"response.json")
 write.csv(data.frame(seed_record_id=c("s1","s2","s3"),provider="lens",identifier_type="lens",query_identifier=c("L1","L1","L2")),manifest,row.names=FALSE)
 write_json(list(total=1L,data=list(list(lens_id="L1",references_count=14L,references_resolved_count=12L,references=list(list(lens_id="R1"),list(lens_id="R2"),list()),scholarly_citations_count=3L,scholarly_citations=list("C1")))),fixture,auto_unbox=TRUE)
 Sys.setenv(W08B_LENS_TEST_FIXTURE=fixture,W08B_TEST_MODE="1")
 script<-"scripts/workflow08b/run_lens_bulk_manifest.R"
 state<-file.path(root,"state")
 run<-function(out)system2("Rscript",c(script,shQuote(manifest),shQuote(out),"1","2026-11"))
 stopifnot(run(state)==0L)
 z<-lapply(readLines(file.path(state,"lens_seed_status.jsonl")),fromJSON)
 stopifnot(length(z)==2L,z[[1]]$status=="complete",z[[1]]$reference_count_discrepancy==12L,z[[1]]$resolved_count_discrepancy==10L,z[[1]]$citing_count_discrepancy==2L,z[[2]]$status=="not_found")
 e<-lapply(readLines(file.path(state,"lens_edges_input.jsonl")),fromJSON)
 stopifnot(length(e)==2L,all(vapply(e,function(x)setequal(x$backward_ids,c("R1","R2"))&&identical(x$forward_ids,"C1"),logical(1))))
 s<-fromJSON(file.path(state,"discovery_summary.json"));stopifnot(s$requests_this_execution==3L,s$coverage_discrepancies==1L,s$not_found_this_execution==1L)
 stopifnot(run(state)==0L,length(readLines(file.path(state,"lens_seed_status.jsonl")))==2L)
 # Previously complete seeds: no redundant backward edges for unchanged counts,
 # but full forward results are emitted again, including older citing IDs.
 monthly<-function(month)system2("Rscript",c(script,shQuote(manifest),shQuote(state),"1",month))
 response<-function(bc,rc,refs,cites){
   write_json(list(total=1L,data=list(list(lens_id="L1",references_count=bc,
     references_resolved_count=rc,references=lapply(refs,function(id)list(lens_id=id)),
     scholarly_citations_count=length(cites),scholarly_citations=as.list(cites)))),
     fixture,auto_unbox=TRUE)
 }
 response(14L,12L,c("R1","R2"),c("C1","C2"))
 stopifnot(monthly("2026-12")==0L)
 e<-tail(lapply(readLines(file.path(state,"lens_edges_input.jsonl")),fromJSON),2L)
 stopifnot(all(vapply(e,function(x)length(x$backward_ids)==0L&&setequal(x$forward_ids,c("C1","C2")),logical(1))))
 z<-lapply(readLines(file.path(state,"lens_seed_status.jsonl")),fromJSON)
 z<-tail(Filter(function(x)x$lens_id=="L1",z),1L)[[1]]
 stopifnot(!z$backward_refreshed,z$backward_ids==2L)
 # Total count increased.
 response(15L,13L,c("R1","R2","R3"),c("C1","C2"))
 stopifnot(monthly("2027-01")==0L)
 e<-tail(lapply(readLines(file.path(state,"lens_edges_input.jsonl")),fromJSON),2L)
 stopifnot(all(vapply(e,function(x)setequal(x$backward_ids,c("R1","R2","R3")),logical(1))))
 # Resolved coverage increased even though total reference count did not.
 response(15L,14L,c("R1","R2","R3","R4"),c("C1","C2"))
 stopifnot(monthly("2027-02")==0L)
 e<-tail(lapply(readLines(file.path(state,"lens_edges_input.jsonl")),fromJSON),2L)
 stopifnot(all(vapply(e,function(x)setequal(x$backward_ids,c("R1","R2","R3","R4")),logical(1))))
 # Actual Lens response shape: missing list, count field present. R's
 # partial matching used to interpret the numeric count as a relationship.
 write_json(list(total=2L,data=list(
   list(lens_id="L1",references_count=14L,scholarly_citations_count=3L,scholarly_citations=list("C1")),
   list(lens_id="L2",references_resolved_count=0L,scholarly_citations_count=4L))),fixture,auto_unbox=TRUE)
 exact<-file.path(root,"missing-lists");stopifnot(run(exact)==0L)
 z<-lapply(readLines(file.path(exact,"lens_seed_status.jsonl")),fromJSON)
 stopifnot(length(z)==2L,all(vapply(z,function(x)x$status=="complete",logical(1))),
   z[[1]]$backward_ids==0L,z[[1]]$forward_ids==1L,z[[2]]$forward_ids==0L)
 e<-lapply(readLines(file.path(exact,"lens_edges_input.jsonl")),fromJSON)
 stopifnot(length(e)==3L,all(vapply(e,function(x)length(x$backward_ids)==0L,logical(1))))
 # A genuinely malformed numeric relationship field is still rejected.
 write_json(list(total=1L,data=list(list(lens_id="L1",references=14L))),fixture,auto_unbox=TRUE)
 malformed<-file.path(root,"malformed");stopifnot(run(malformed)!=0L,!file.exists(file.path(malformed,"lens_seed_status.jsonl")))
 write_json(list(total=2L,data=list(list(lens_id="L1"))),fixture,auto_unbox=TRUE)
 bad<-file.path(root,"bad");stopifnot(run(bad)!=0L,!file.exists(file.path(bad,"lens_seed_status.jsonl")))
 cat("PASS: coverage gaps retained, shared seed associations, two targeted absence checks, idempotent retry and truncated search rejected\n")
})()

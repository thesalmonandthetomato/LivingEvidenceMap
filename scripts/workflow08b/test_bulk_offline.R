#!/usr/bin/env Rscript
# Offline integration regression: parse new W08b code; test prefilter against
# included and excluded W01 identities without any provider API calls.
parse(file="scripts/workflow08b/run_lens_bulk.R")
parse(file="scripts/workflow08b/filter_existing_w01.R")
parse(file="scripts/workflow08b/plan_monthly.R")
root<-tempfile("w08b-regression-");dir.create(root)
one<-list(identity=list(record_id="work-one"),canonical=list(doi="10.1000/one"),
 manifestations=list(list(source="lens",source_record_id="111-111-111-111-111",
 manifestation_metadata=list(source_identity=list(lens_id="111-111-111-111-111")))))
two<-list(identity=list(record_id="work-excluded"),canonical=list(doi="10.1000/two"),
 manifestations=list(list(source="lens",source_record_id="222-222-222-222-222",
 manifestation_metadata=list(source_identity=list(lens_id="222-222-222-222-222")))))
w01<-file.path(root,"w01.jsonl")
writeLines(c(jsonlite::toJSON(one,auto_unbox=TRUE),jsonlite::toJSON(two,auto_unbox=TRUE)),w01)
candidate<-data.frame(provider=rep("lens",3),related_provider_id=c(
 "111-111-111-111-111","222-222-222-222-222","333-333-333-333-333"))
csv<-file.path(root,"candidate.csv");write.csv(candidate,csv,row.names=FALSE)
target<-file.path(root,"out")
cmd<-system2("Rscript",c("scripts/workflow08b/filter_existing_w01.R",
 shQuote(w01),shQuote(csv),shQuote(target)))
stopifnot(cmd==0L)
z<-read.csv(file.path(target,"candidate_identity_precheck.csv"),stringsAsFactors=FALSE)
stopifnot(identical(z$identity_status,c("already_in_w01","already_in_w01",
 "needs_bibliographic_identity_check")))
stopifnot(z$existing_w01_record_id[[2L]]=="work-excluded")
cat("PASS: W08b bulk parser and historical-included/excluded identity precheck\n")

#!/usr/bin/env Rscript
# Offline integration regression: parse new W08b code; test prefilter against
# included and excluded W01 identities without any provider API calls.
parse(file="scripts/workflow08b/run_lens_bulk.R")
parse(file="scripts/workflow08b/filter_existing_w01.R")
parse(file="scripts/workflow08b/plan_monthly.R")
parse(file="scripts/workflow08b/resolve_lens_doi_bulk.R")
parse(file="scripts/workflow08b/apply_lens_doi_resolution.R")
parse(file="scripts/workflow08b/filter_original_strategy.R")
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

# Exercise actual strategy logic and incomplete-metadata quarantine.
metadata<-file.path(root,"sample_candidates.jsonl")
writeLines(c(
 jsonlite::toJSON(list(candidate_key="x1",title="Salmon aquaculture study",
  abstract="A systematic review",keywords=list("mariculture")),auto_unbox=TRUE),
 jsonlite::toJSON(list(candidate_key="x2",title="Road transport",
  abstract="Urban design",keywords=list("commuting")),auto_unbox=TRUE),
 jsonlite::toJSON(list(candidate_key="x3",title="Salmon farming review"),
  auto_unbox=TRUE)),metadata)
filtered<-file.path(root,"strategy.csv")
audit<-file.path(root,"strategy_audit.json")
exit<-system2("Rscript",c("scripts/workflow08b/filter_original_strategy.R",
 shQuote(metadata),shQuote("user_input/workflow00_search_strategy.json"),
 shQuote(filtered),shQuote(audit)))
stopifnot(exit==0L)
v<-read.csv(filtered,stringsAsFactors=FALSE)
stopifnot(identical(v$status,c("original_strategy_match","not_matched","metadata_incomplete")))
cat("PASS: bulk DOI parser and original search-strategy filter regression\\n")

#!/usr/bin/env Rscript
# Offline integration regression: parse new W08b code; test prefilter against
# included and excluded W01 identities without any provider API calls.
parse(file="scripts/workflow08b/run_lens_bulk.R")
parse(file="scripts/workflow08b/filter_existing_w01.R")
parse(file="scripts/workflow08b/plan_monthly.R")
parse(file="scripts/workflow08b/resolve_lens_doi_bulk.R")
parse(file="scripts/workflow08b/apply_lens_doi_resolution.R")
parse(file="scripts/workflow08b/filter_original_strategy.R")
parse(file="scripts/workflow08b/run_openalex_fallback.R")
parse(file="scripts/workflow08b/retrieve_lens_candidates_bulk.R")
parse(file="scripts/workflow08b/reconcile_lens_candidates.R")
parse(file="scripts/workflow08b/index_w01_dois.R")
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

# Cross-field integration check: known W01, original-search and missing DOI.
pre<-file.path(root,"precheck.csv")
write.csv(data.frame(provider=rep("lens",3),
 related_provider_id=c("111","222","333"),
 existing_w01_record_id=c("work-old","","")),pre,row.names=FALSE)
metadata2<-file.path(root,"metadata2.jsonl")
writeLines(c(
 jsonlite::toJSON(list(candidate_key="lens:111",doi="10.1/old"),auto_unbox=TRUE),
 jsonlite::toJSON(list(candidate_key="lens:222",doi="10.1/new"),auto_unbox=TRUE),
 jsonlite::toJSON(list(candidate_key="lens:333",title="Not indexed"),auto_unbox=TRUE)),metadata2)
screen<-file.path(root,"screen.csv")
write.csv(data.frame(candidate_key=c("lens:111","lens:222","lens:333"),
 status=c("original_strategy_match","not_matched","metadata_incomplete")),screen,row.names=FALSE)
out2<-file.path(root,"reconciled")
stopifnot(system2("Rscript",c("scripts/workflow08b/reconcile_lens_candidates.R",
 shQuote(pre),shQuote(metadata2),shQuote(screen),shQuote(out2)))==0L)
resolved<-read.csv(file.path(out2,"reconciliation.csv"),stringsAsFactors=FALSE)
stopifnot(identical(resolved$reconciliation_status,c(
 "already_in_w01_provider_id","pending_doi_crosscheck","doi_missing_require_further_identity_check")))
cat("PASS: metadata retrieval parser and candidate reconciliation quarantine\n")

# Historical DOI index matches excluded studies and new DOI identities.
idx<-file.path(root,"doi_index")
stopifnot(system2("Rscript",c("scripts/workflow08b/index_w01_dois.R",
 shQuote(w01),shQuote(idx)))==0L)
hi<-read.csv(file.path(idx,"historical_doi_index.csv"),stringsAsFactors=FALSE)
stopifnot(any(hi$doi=="10.1000/two" & hi$w01_record_ids=="work-excluded"))
meta3<-file.path(root,"metadata3.jsonl")
writeLines(jsonlite::toJSON(list(candidate_key="lens:222",doi="10.1000/two"),auto_unbox=TRUE),meta3)
pre3<-file.path(root,"pre3.csv")
write.csv(data.frame(provider="lens",related_provider_id="222",existing_w01_record_id=""),pre3,row.names=FALSE)
scr3<-file.path(root,"scr3.csv")
write.csv(data.frame(candidate_key="lens:222",status="not_matched"),scr3,row.names=FALSE)
out3<-file.path(root,"out3")
stopifnot(system2("Rscript",c("scripts/workflow08b/reconcile_lens_candidates.R",
 shQuote(pre3),shQuote(meta3),shQuote(scr3),shQuote(out3),
 shQuote(file.path(idx,"historical_doi_index.csv"))))==0L)
verified<-read.csv(file.path(out3,"reconciliation.csv"),stringsAsFactors=FALSE)
stopifnot(verified$reconciliation_status[[1]]=="already_in_w01_doi")
cat("PASS: excluded W01 record resolved through historical DOI identity\n")

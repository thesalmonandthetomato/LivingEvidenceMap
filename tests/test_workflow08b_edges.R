#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(jsonlite))
tmp<-tempfile("w08b-edges-");dir.create(tmp);on.exit(unlink(tmp,recursive=TRUE),add=TRUE)
input<-file.path(tmp,"input.jsonl");out<-file.path(tmp,"out")
cases<-list(
 list(seed_record_id="seed-a",provider="lens",backward_ids=c("L1","L1","L2"),forward_ids=c("L2","L3")),
 list(seed_record_id="seed-b",provider="lens",backward_ids=c("L2","L4"),forward_ids=character()),
 list(seed_record_id="seed-c",provider="openalex",backward_ids=c("W1"),forward_ids=c("W1","W2"))
)
writeLines(vapply(cases,function(x)toJSON(x,auto_unbox=TRUE),character(1)),input)
code<-system2(file.path(R.home("bin"),"Rscript"),c("scripts/workflow08b/merge_edges.R",shQuote(input),shQuote(out)))
stopifnot(code==0L)
x<-fromJSON(file.path(out,"summary.json"))
stopifnot(x$raw_edges==9,x$distinct_direction_edges==9,
 x$distinct_seed_candidate_pairs==7,x$distinct_provider_candidate_ids==6,
 x$pairs_both_directions==2,!x$candidate_bibliography_downloaded)
d<-read.csv(file.path(out,"seed_candidate_direction.csv"),stringsAsFactors=FALSE)
stopifnot(nrow(d)==7,sum(d$direction=="both")==2)
cat("PASS: W08b cross-seed, cross-direction, provider-specific edge deduplication\n")

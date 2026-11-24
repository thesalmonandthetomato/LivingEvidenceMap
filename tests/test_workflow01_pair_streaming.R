#!/usr/bin/env Rscript
# Pair diff/replay regression: full-fidelity CSV, >3k chunks, immutable columns,
# quoted multiline descriptions, SHA-256 state, and missing-history fail closure.
suppressPackageStartupMessages({library(data.table);library(digest)})
source("scripts/updater/workflow_01_pair_state_stream.R",local=TRUE)
td <- tempfile("w01-pair-state-");stopifnot(dir.create(td))
prev <- file.path(td,"previous.csv");cur <- file.path(td,"current.csv")
delta <- file.path(td,"upserts.csv");replayed <- file.path(td,"replayed.csv")
long <- paste(rep("two sentences with unicode é and quote \"",45),collapse="")
x <- data.table(
  record_i=rep(1L,4002L),record_j=2:4003,
  pair_key=paste(1,2:4003,sep="::"),
  rescored_classification="not_duplicate",
  rescored_rule="previous",
  review_route="none",
  title_i="Title with commas, a quote \" and apostrophe's",
  title_j="Title B",
  notes=rep(long,4002L))
x$notes[[3102L]] <- "An embedded, quoted newline\nfollowed by the second line"
fwrite(x,prev,na="")
y <- copy(x)
y[2L,rescored_rule:="human_adjudication"]
y[3L,title_i:="descriptive title was fixed"]
new <- data.table(record_i=c(1L,1L),record_j=c(4004L,4005L),
  pair_key=c("1::4004","1::4005"),rescored_classification=c("duplicate","not_duplicate"),
  rescored_rule=c("new","new"),review_route="none",
  title_i=c("new title A","new title B"),title_j="Title B",notes=c(long,"new record"))
y <- rbindlist(list(y,new),use.names=TRUE,fill=TRUE)
fwrite(y,cur,na="")
result <- w01_pair_diff(prev,cur,delta)
stopifnot(result$new==2L,result$changed==2L,result$upserts==4L,
  identical(result$hash_method,"row_sha256_sorted_v2"))
ups <- fread(delta,na.strings=c("","NA"))
stopifnot(setequal(ups$pair_key,c("1::3","1::4","1::4004","1::4005")))
w01_pair_replay(prev,delta,replayed,result$state_sha256)
actual <- fread(replayed,na.strings=c("","NA"))
expected <- fread(cur,na.strings=c("","NA"))
setorder(actual,pair_key);setorder(expected,pair_key)
stopifnot(identical(names(actual),names(expected)),nrow(actual)==nrow(expected))
for(nm in names(expected))stopifnot(identical(as.character(actual[[nm]]),as.character(expected[[nm]])))
stopifnot(identical(actual[pair_key=="1::3103",notes],fread(cur)[pair_key=="1::3103",notes]))
missing <- copy(y)[pair_key!="1::1000"]
fwrite(missing,file.path(td,"missing.csv"),na="")
err <- tryCatch(w01_pair_diff(prev,file.path(td,"missing.csv"),file.path(td,"bad.csv")),
                error=function(e)conditionMessage(e))
stopifnot(is.character(err),grepl("previous pair decisions disappeared",err,fixed=TRUE))
cat("ALL_W01_PAIR_DIFF_REPLAY_STREAMING_TESTS_PASS\n")
unlink(td,recursive=TRUE)

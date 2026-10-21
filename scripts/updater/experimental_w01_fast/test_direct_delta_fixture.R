#!/usr/bin/env Rscript
# Small independent fixture for the experimental direct delta path.
suppressPackageStartupMessages({library(data.table);library(jsonlite);library(digest)})
writer<-'scripts/updater/experimental_w01_fast/write_direct_delta.R'
stopifnot(length(parse(file=writer))>0L)
# Reuse the unmodified production delta fixture to create authoritative tiny states.
status<-system2('Rscript','scripts/updater/workflow_01_validate_delta_fixture.R')
stopifnot(identical(status,0L))
root<-'outputs/workflow01_delta_fixture'
t<-tempfile('direct-delta-test-');dir.create(t)
on.exit(unlink(t,recursive=TRUE),add=TRUE)
# Explicit affected successor record, no new pairs and no changed cluster identities.
fwrite(data.table(record_i=integer(),record_j=integer()),file.path(t,'scored.csv'))
fwrite(data.table(source='lens',source_record_id='L1'),file.path(t,'affected_map.csv'))
fwrite(data.table(stage=c('prior','successor'),cluster_id=c('work-a','work-a')),file.path(t,'affected_works.csv'))
current<-readLines(file.path(root,'target','records.jsonl'),warn=FALSE)
ids<-vapply(current,function(x)as.character(fromJSON(x)$identity$record_id),character(1))
writeLines(current[ids=='work-a'],file.path(t,'changed.jsonl'))
a<-c('--previous-root',file.path(root,'previous'),'--current-seed-root',file.path(root,'current_seed'),
 '--current-final-root',file.path(root,'current_final'),
 '--current-canonical',file.path(root,'target','records.jsonl'),
 '--current-canonical-manifest',file.path(root,'target','canonical_manifest.json'),
 '--previous-pointer',file.path(root,'previous_pointer.json'),
 '--new-decisions',file.path(t,'scored.csv'),'--affected-map',file.path(t,'affected_map.csv'),
 '--canonical-changes',file.path(t,'changed.jsonl'),'--affected-works',file.path(t,'affected_works.csv'),
 '--output-dir',file.path(t,'delta'),'--run-id','fixture-direct')
run<-function(script,args)system2('Rscript',c(script,shQuote(args)))
stopifnot(identical(run(writer,a),0L))
stopifnot(identical(run('scripts/updater/workflow_01_replay_delta.R',c(
 '--previous-root',file.path(root,'previous'),'--delta-dir',file.path(t,'delta'),
 '--output-root',file.path(t,'replayed'))),0L))
expected<-digest(file=file.path(root,'target','records.jsonl'),algo='sha256')
actual<-digest(file=file.path(t,'replayed','canonical','records.jsonl'),algo='sha256')
stopifnot(identical(expected,actual))
# Deliberate identity conflict must fail without modifying the previous state.
bad<-data.table(record_i=1L,record_j=2L)
fwrite(bad,file.path(t,'scored.csv'))
a[which(a=='--output-dir')+1L]<-file.path(t,'invalid')
stopifnot(run(writer,a)!=0L)
cat('PASS: direct delta reproduces production fixture and rejects historical pair overwrite\n')

# Explicit opt-in only: original legacy builder remains default.
parent<-'scripts/updater/experimental_w01_fast/run_full_incremental_update.R'
stopifnot(length(parse(file=parent))>0L)
source_text<-paste(readLines(parent,warn=FALSE),collapse='\\n')
stopifnot(grepl('delta_writer<-\"legacy\"',source_text,fixed=TRUE),
 grepl('if(delta_writer==\"direct\")',source_text,fixed=TRUE),
 grepl('write_direct_delta.R',source_text,fixed=TRUE),
 grepl('workflow_01_build_delta.R',source_text,fixed=TRUE))

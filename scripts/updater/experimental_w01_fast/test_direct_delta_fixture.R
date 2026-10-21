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

# Provenance: append new approved repair and strip action with stable identities.
fwrite(data.table(record_i=integer(),record_j=integer()),file.path(t,'scored.csv'))
a[which(a=='--output-dir')+1L]<-file.path(t,'with-provenance')
p<-file.path(root,'previous')
final<-file.path(t,'final-provenance');dir.create(final)
file.copy(list.files(file.path(root,'current_final'),full.names=TRUE),final)
repair<-list(review_case_id='approved-1',source='lens',source_record_id='L1',action='correct')
strip<-list(source='lens',source_record_id='L2',action='strip_abstract')
writeLines(toJSON(repair,auto_unbox=TRUE),file.path(final,'cumulative_data_quality_repairs.jsonl'))
writeLines(toJSON(strip,auto_unbox=TRUE),file.path(final,'abstract_strip_actions.jsonl'))
a[which(a=='--current-final-root')+1L]<-final
stopifnot(run(writer,a)==0L)
dm<-fromJSON(file.path(t,'with-provenance','delta_manifest.json'))
stopifnot(dm$delta$data_quality_repair_upserts==1L,dm$delta$abstract_strip_action_upserts==1L)
stopifnot(run('scripts/updater/workflow_01_replay_delta.R',c(
 '--previous-root',p,'--delta-dir',file.path(t,'with-provenance'),
 '--output-root',file.path(t,'replayed-provenance')))==0L)
stopifnot(length(readLines(file.path(t,'replayed-provenance','provenance','cumulative_data_quality_repairs.jsonl')))==1L)
stopifnot(length(readLines(file.path(t,'replayed-provenance','workflow01_full_five_source','abstract_strip_actions.jsonl')))==1L)

# Existing approvals and strip actions are immutable, even when identity keys agree.
dir.create(file.path(p,'provenance'),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(repair,auto_unbox=TRUE),
 file.path(p,'provenance','cumulative_data_quality_repairs.jsonl'))
modified_repair<-modifyList(repair,list(reason='silently changed historical approval'))
writeLines(toJSON(modified_repair,auto_unbox=TRUE),
 file.path(final,'cumulative_data_quality_repairs.jsonl'))
a[which(a=='--output-dir')+1L]<-file.path(t,'reject-modified-repair')
stopifnot(run(writer,a)!=0L)
# Restore repair; make an existing strip action disappear from successor.
writeLines(toJSON(repair,auto_unbox=TRUE),
 file.path(final,'cumulative_data_quality_repairs.jsonl'))
writeLines(toJSON(strip,auto_unbox=TRUE),
 file.path(p,'workflow01_full_five_source','abstract_strip_actions.jsonl'))
file.create(file.path(final,'abstract_strip_actions.jsonl'),showWarnings=FALSE)
writeLines(character(),file.path(final,'abstract_strip_actions.jsonl'))
a[which(a=='--output-dir')+1L]<-file.path(t,'reject-removed-strip')
stopifnot(run(writer,a)!=0L)
cat('PASS: historical provenance alteration and disappearance rejected\\n')

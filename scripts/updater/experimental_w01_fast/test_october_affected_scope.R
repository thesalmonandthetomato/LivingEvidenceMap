#!/usr/bin/env Rscript
# Read-only October acceptance: verify exact identity-scoped reconstruction set
# for historical works modified by the 60-record update.
suppressPackageStartupMessages({library(data.table);library(jsonlite)})
p<-"reference/previous_state/workflow01_full_five_source/manifestation_cluster_map.csv"
q<-"reference/outputs/final/manifestation_cluster_map.csv"
if(!all(file.exists(c(p,q))))stop("Missing frozen October cluster maps")
old<-fread(p,colClasses=list(character=c("source","source_record_id","cluster_id")))
new<-fread(q,colClasses=list(character=c("source","source_record_id","cluster_id")))
key<-function(d)paste0(nchar(d$source,type="bytes"),":",d$source,nchar(d$source_record_id,type="bytes"),":",d$source_record_id)
old[,k:=key(old)];new[,k:=key(new)]
if(anyDuplicated(old$k)||anyDuplicated(new$k)||any(!old$k%in%new$k))stop("Invalid stable identity preservation")
if(any(new[match(old$k,new$k),cluster_id]!=old$cluster_id))stop("Historical cluster identifiers reassigned")
app<-new[!k%in%old$k]
if(nrow(app)!=60L)stop("Wrong October delta size")
joined<-app[cluster_id%in%old$cluster_id]
singleton<-app[!cluster_id%in%old$cluster_id]
if(nrow(joined)!=44L||nrow(singleton)!=16L)stop("Unexpected original update partition")
affected<-sort(unique(joined$cluster_id))
prev_members<-old[cluster_id%in%affected]
next_members<-new[cluster_id%in%affected]
if(length(affected)!=44L||nrow(prev_members)!=177L||nrow(next_members)!=221L)
 stop("Actual historic affected-work scope disagrees with frozen October counts")
if(!identical(sort(next_members$k),sort(c(prev_members$k,joined$k))))
 stop("Affected set does not equal exact retained and appended source identities")
untouched<-setdiff(old$cluster_id,affected)
if(any(old[cluster_id%in%untouched]$k %in% joined$k))stop("Unaffected work received a new manifestation")
dir.create("october_affected_scope",showWarnings=FALSE)
fwrite(next_members[,.(source,source_record_id,cluster_id,cluster_size)],"october_affected_scope/affected_cluster_map.csv")
write_json(list(schema="w01-fast-october-affected-scope-v1",
 historic_manifestations=nrow(old),updated_manifestations=nrow(new),
 newly_appended=60L,new_singletons=16L,joined_existing_manifestations=44L,
 affected_existing_works=44L,affected_historical_manifestations=177L,
 affected_final_manifestations=221L,
 exact_scope_verified=TRUE,canonical_materialisation_verified=FALSE,
 production_changes_allowed=FALSE),
 "october_affected_scope/report.json",auto_unbox=TRUE,pretty=TRUE)
cat("PASS: real October affected scope exactly 44 existing works, 177 historical + 44 appended manifestations\\n")

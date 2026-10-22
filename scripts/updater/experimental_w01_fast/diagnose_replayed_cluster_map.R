#!/usr/bin/env Rscript
# Read-only bounded diagnostics for direct-delta replay; no production changes.
suppressPackageStartupMessages({library(data.table);library(jsonlite)})
root <- "outputs/experimental_w01_fast/full_update"
target <- file.path(root,"production_final","manifestation_cluster_map.csv")
actual <- file.path(root,"replayed","workflow01_full_five_source","manifestation_cluster_map.csv")
out <- file.path(root,"cluster_map_replay_diagnostic.json")
if(!file.exists(target) || !file.exists(actual)) stop("Replay comparison input missing")
a <- fread(target,na.strings=c("","NA"),colClasses="character")
b <- fread(actual,na.strings=c("","NA"),colClasses="character")
key <- c("source","source_record_id")
if(!all(key %in% names(a)) || !all(key %in% names(b)))stop("Missing stable identities")
setkeyv(a,key);setkeyv(b,key)
ka <- paste(a$source,a$source_record_id,sep="\u001f")
kb <- paste(b$source,b$source_record_id,sep="\u001f")
common <- intersect(ka,kb)
cols <- intersect(names(a),names(b))
diff_by_col <- list()
examples <- list()
for(nm in setdiff(cols,key)){
 x <- a[[nm]][match(common,ka)]
 y <- b[[nm]][match(common,kb)]
 different <- (is.na(x)!=is.na(y)) | (!is.na(x)&!is.na(y)&x!=y)
 diff_by_col[[nm]] <- sum(different)
 if(any(different)){
  ix <- head(which(different),5L)
  examples[[nm]] <- lapply(ix,function(i)list(identity=common[[i]],target=x[[i]],replayed=y[[i]]))
 }
}
report<-list(schema="w01-fast-replay-diagnostic-v1",target_rows=nrow(a),replayed_rows=nrow(b),
 target_cols=names(a),replayed_cols=names(b),
 missing_in_replay=head(setdiff(ka,kb),10L),extra_in_replay=head(setdiff(kb,ka),10L),
 mismatches_by_col=diff_by_col,examples=examples)
write_json(report,out,auto_unbox=TRUE,pretty=TRUE,null="null",na="null")
cat(toJSON(report,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),"\n")

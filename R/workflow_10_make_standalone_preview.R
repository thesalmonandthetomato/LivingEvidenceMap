#!/usr/bin/env Rscript
args <- commandArgs(trailingOnly=TRUE)
if(length(args)<3L) stop("Usage: Rscript workflow_10_make_standalone_preview.R <html> <data-js> <output>",call.=FALSE)
html_path<-args[[1L]]; js_path<-args[[2L]]; out_path<-args[[3L]]
for(p in c(html_path,js_path)) if(!file.exists(p)) stop("Missing input: ",p,call.=FALSE)

html<-paste(readLines(html_path,warn=FALSE,encoding="UTF-8"),collapse="\n")
js<-paste(readLines(js_path,warn=FALSE,encoding="UTF-8"),collapse="\n")
marker<-'<script src="./dashboard-data.js"></script>'
if(!grepl(marker,html,fixed=TRUE)) stop("Dashboard data script marker not found",call.=FALSE)
if(grepl("Evidence flow",html,fixed=TRUE)||grepl("evidence_flowdiagram.svg",html,fixed=TRUE)) stop("Flow diagram still present in dashboard HTML",call.=FALSE)
if(!startsWith(js,"window.LIVING_EVIDENCE_MAP_DASHBOARD_DATA=")) stop("Dashboard data JS has unexpected prefix",call.=FALSE)

embedded<-paste0("<script>\n",js,"\n</script>")
html<-sub(marker,embedded,html,fixed=TRUE)
dir.create(dirname(out_path),recursive=TRUE,showWarnings=FALSE)
writeLines(html,out_path,useBytes=TRUE)

check<-file.info(out_path)$size
if(is.na(check)||check<1000000) stop("Standalone preview is unexpectedly small",call.=FALSE)
cat(sprintf("PASS: standalone dashboard preview written: %s (%d bytes)\n",out_path,check))

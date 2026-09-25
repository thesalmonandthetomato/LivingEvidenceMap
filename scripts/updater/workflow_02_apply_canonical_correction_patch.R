#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(digest)})

args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
input_path<-arg("--input"); patch_path<-arg("--patch"); output_path<-arg("--output"); report_path<-arg("--report")
if(any(vapply(list(input_path,patch_path,output_path,report_path),is.null,logical(1)))) stop("Required: --input --patch --output --report",call.=FALSE)

`%||%`<-function(x,y) if(is.null(x)) y else x
clean<-function(x){if(is.null(x)||!length(x))return(NULL);s<-trimws(gsub("[[:space:]]+"," ",as.character(x[[1L]])));if(is.na(s)||!nzchar(s))NULL else s}
readjl<-function(p){x<-readLines(p,warn=FALSE,encoding="UTF-8");x<-x[nzchar(trimws(x))];lapply(x,fromJSON,simplifyVector=FALSE)}
patches<-readjl(patch_path)
ids<-vapply(patches,function(x)clean(x$record_id)%||%"",character(1))
if(any(!nzchar(ids))||anyDuplicated(ids)) stop("Correction patch has missing/duplicate record IDs",call.=FALSE)
pmap<-setNames(patches,ids)

dir.create(dirname(output_path),recursive=TRUE,showWarnings=FALSE)
pin<-file(input_path,"rt",encoding="UTF-8");pout<-file(output_path,"wt",encoding="UTF-8")
on.exit({try(close(pin),silent=TRUE);try(close(pout),silent=TRUE)},add=TRUE)
seen<-character(); changed<-character(); records<-0L
repeat{
  line<-readLines(pin,n=1L,warn=FALSE)
  if(!length(line)) break
  if(!nzchar(trimws(line))) next
  records<-records+1L
  r<-fromJSON(line,simplifyVector=FALSE)
  rid<-clean((r$identity%||%list())$record_id)
  if(is.null(rid)) stop(sprintf("Input line %d missing record_id",records),call.=FALSE)
  p<-pmap[[rid]]
  if(!is.null(p)){
    seen<-c(seen,rid)
    doi<-tolower(clean((r$canonical%||%list())$doi)%||%"")
    if(!identical(doi,tolower(clean(p$doi)%||%""))) stop(sprintf("DOI mismatch for %s",rid),call.=FALSE)
    if(is.null(r$canonical)) r$canonical<-list()
    if(!is.null(p$title)){
      expected<-clean(p$expected_title)
      current<-clean(r$canonical$title)
      if(!is.null(expected)&&!identical(current,expected)) stop(sprintf("Unexpected current title for %s",rid),call.=FALSE)
      r$canonical$title<-as.character(p$title)
    }
    if(!is.null(p$abstract)){
      if(!is.null(clean(r$canonical$abstract))) stop(sprintf("Abstract is not missing for %s",rid),call.=FALSE)
      r$canonical$abstract<-as.character(p$abstract)
    }
    changed<-c(changed,rid)
  }
  writeLines(toJSON(r,auto_unbox=TRUE,null="null",na="null",digits=NA),pout,useBytes=TRUE)
}
close(pin);close(pout);on.exit(NULL,add=FALSE)
missing_ids<-setdiff(ids,seen)
if(length(missing_ids)) stop(sprintf("Correction patch missing %d record IDs",length(missing_ids)),call.=FALSE)
report<-list(
  schema="living-evidence-map-workflow02-canonical-correction-application-v1",
  status="PASS",
  input_sha256=digest(file=input_path,algo="sha256",serialize=FALSE),
  patch_sha256=digest(file=patch_path,algo="sha256",serialize=FALSE),
  output_sha256=digest(file=output_path,algo="sha256",serialize=FALSE),
  records=records,
  patch_records=length(patches),
  changed_record_ids=changed
)
writeLines(toJSON(report,auto_unbox=TRUE,pretty=TRUE,null="null"),report_path,useBytes=TRUE)
cat(sprintf("PASS: applied %d Workflow 02 canonical corrections to %d records\n",length(patches),records))

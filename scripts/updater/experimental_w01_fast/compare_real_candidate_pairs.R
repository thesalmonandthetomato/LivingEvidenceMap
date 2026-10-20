#!/usr/bin/env Rscript
# Bounded, read-only parity of historical vs W01-Fast candidate evidence.
# Both inputs must already carry immutable source identity columns.
suppressPackageStartupMessages({library(data.table);library(jsonlite);library(digest)})
a<-commandArgs(trailingOnly=TRUE)
arg<-function(k){i<-match(k,a);if(is.na(i)||i==length(a))stop(paste("Missing",k));a[[i+1L]]}
reference<-arg("--reference");candidate<-arg("--candidate");output<-arg("--output-dir")
if(file.exists(output)||dir.exists(output))stop("Refusing overwrite")
read_pairs<-function(path){
 x<-fread(path,colClasses="character")
 required<-c("source_a","source_record_id_a","source_b","source_record_id_b")
 if(!all(required%in%names(x)))stop("Missing immutable source pair identities")
 if(anyNA(x[,..required])||any(!nzchar(unlist(x[,..required],use.names=FALSE))))
  stop("Null/empty identity")
 enc<-function(s,id)paste0(nchar(s,type="bytes"),":",s,nchar(id,type="bytes"),":",id)
 first<-enc(x$source_a,x$source_record_id_a)
 second<-enc(x$source_b,x$source_record_id_b)
 if(any(first==second))stop("Self-pairs forbidden")
 left<-pmin(first,second);right<-pmax(first,second)
 x[,canonical_pair:=paste0(nchar(left,type="bytes"),":",left,nchar(right,type="bytes"),":",right)]
 if(anyDuplicated(x$canonical_pair))stop("Duplicate pair identities")
 # Compare all named evidence columns, not only pair cardinality.
 evidence<-setdiff(names(x),c(required,"canonical_pair"))
 setorderv(x,"canonical_pair")
 list(table=x,evidence=evidence)
}
ref<-read_pairs(reference);fast<-read_pairs(candidate)
if(!setequal(ref$evidence,fast$evidence))
 stop("Evidence schemas differ; a parity claim would be invalid")
fields<-sort(ref$evidence)
canon<-function(z)z$table[,c("canonical_pair",fields),with=FALSE]
old<-canon(ref);new<-canon(fast)
removed<-setdiff(old$canonical_pair,new$canonical_pair)
added<-setdiff(new$canonical_pair,old$canonical_pair)
shared<-intersect(old$canonical_pair,new$canonical_pair)
i<-match(shared,old$canonical_pair);j<-match(shared,new$canonical_pair)
different<-shared[vapply(seq_along(shared),function(k){
 !identical(as.list(old[i[[k]],..fields]),as.list(new[j[[k]],..fields]))
},logical(1))]
dir.create(output,recursive=TRUE)
fwrite(data.table(canonical_pair=removed),file.path(output,"missing_pairs.csv"))
fwrite(data.table(canonical_pair=added),file.path(output,"extra_pairs.csv"))
fwrite(data.table(canonical_pair=different),file.path(output,"evidence_mismatches.csv"))
result<-list(schema="w01-fast-real-candidate-parity-v1",
 reference_pairs=nrow(old),fast_pairs=nrow(new),missing_pairs=length(removed),
 extra_pairs=length(added),evidence_mismatches=length(different),
 reference_sha256=digest(file=reference,algo="sha256"),
 candidate_sha256=digest(file=candidate,algo="sha256"),
 parity_passed=!length(removed)&&!length(added)&&!length(different))
writeLines(toJSON(result,pretty=TRUE,auto_unbox=TRUE),
 file.path(output,"parity_report.json"))
if(!result$parity_passed)stop("Candidate scientific parity failed")
cat(sprintf("PASS: %d stable-identity candidate pairs and evidence fields match\n",nrow(old)))

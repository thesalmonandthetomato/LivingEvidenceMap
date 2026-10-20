#!/usr/bin/env Rscript
# Read-only parity harness for a frozen normalised W01 metadata snapshot.
# This is NOT an integration with production and never fetches remote artifacts.
suppressPackageStartupMessages({library(data.table);library(jsonlite);library(digest)})
args<-commandArgs(trailingOnly=TRUE)
arg<-function(k){i<-match(k,args);if(is.na(i)||i==length(args))stop(paste("Missing",k));args[[i+1L]]}
input<-arg("--metadata");prior_n<-as.integer(arg("--prior-n"));out<-arg("--output-dir")
if(!file.exists(input)||is.na(prior_n)||prior_n<0L)stop("Invalid input or prior count")
m<-fread(input,na.strings=c("","NA"))
required<-c("idx","source","source_record_id","title_norm","doi_norm",
 "doi_family","abstract_hash","author_norm","year","journal_norm",
 "volume_norm","issue_norm","pages_norm")
stopifnot(all(required%in%names(m)),identical(as.integer(m$idx),seq_len(nrow(m))),
 prior_n<=nrow(m))
if(dir.exists(out)||file.exists(out))stop("Output must not exist; preserve prior validation artefacts")
dir.create(out,recursive=TRUE)
root<-"scripts/updater/experimental_w01_fast"
run<-function(file,a){
 z<-suppressWarnings(system2(file.path(R.home("bin"),"Rscript"),
  c(file.path(root,file),a),stdout=TRUE,stderr=TRUE))
 status<-attr(z,"status");if(is.null(status))status<-0L
 if(status!=0L)stop(sprintf("%s failed: %s",file,paste(z,collapse=" | ")))
}
ref_exact<-file.path(out,"reference_exact");ref_fuzzy<-file.path(out,"reference_fuzzy")
run("build_exact_block_index.R",c("--metadata",input,"--prior-n",prior_n,"--output-dir",ref_exact))
run("build_fuzzy_candidates.R",c("--metadata",input,"--prior-n",prior_n,"--output-dir",ref_fuzzy))
historic<-file.path(out,"historical.csv");fwrite(m[seq_len(prior_n)],historic)
exact_init<-file.path(out,"exact_initial")
run("persistent_exact_index.R",c("--mode","init","--metadata",historic,
 "--state",file.path(out,"nonexistent_index.rds"),"--output-dir",exact_init))
exact_append<-file.path(out,"exact_incremental")
run("persistent_exact_index.R",c("--mode","append","--metadata",input,
 "--state",file.path(exact_init,"next_exact_index.rds"),"--output-dir",exact_append))
q_init<-file.path(out,"qgram_initial.rds")
run("persistent_qgram_frequency.R",c("--mode","init","--metadata",historic,"--output",q_init))
q_append<-file.path(out,"qgram_appended.rds")
run("persistent_qgram_frequency.R",c("--mode","append","--metadata",input,
 "--state",q_init,"--output",q_append))
fast_fuzzy<-file.path(out,"fuzzy_incremental.csv")
run("persistent_qgram_candidates.R",c("--state",q_append,"--prior-n",prior_n,
 "--output",fast_fuzzy))
compare<-function(ref,fast,columns){
 a<-fread(ref);b<-fread(fast)
 stopifnot(all(columns%in%names(a)),all(columns%in%names(b)))
 setorderv(a,c("record_i","record_j"));setorderv(b,c("record_i","record_j"))
 # Fail closed on candidate identity/evidence, including zero-record datasets.
 if(nrow(a)!=nrow(b))stop(sprintf("Candidate count differs: %s %s",nrow(a),nrow(b)))
 for(field in columns)if(!isTRUE(all.equal(a[[field]],b[[field]],
   tolerance=1e-12,check.attributes=FALSE)))
   stop(sprintf("Candidate parity mismatch in %s",field))
 nrow(a)
}
n_exact<-compare(file.path(ref_exact,"exact_block_candidates.csv"),
 file.path(exact_append,"exact_block_candidates.csv"),
 c("record_i","record_j","blocks"))
n_fuzzy<-compare(file.path(ref_fuzzy,"fuzzy_candidates.csv"),fast_fuzzy,
 c("record_i","record_j","shared_rare_qgrams","len_ratio"))
manifest<-list(schema="experimental-w01-fast-persistent-candidate-parity-v1",
 original_metadata_sha256=digest(file=input,algo="sha256"),
 historical_manifestations=prior_n,new_manifestations=nrow(m)-prior_n,
 exact_candidate_pairs=n_exact,fuzzy_candidate_pairs=n_fuzzy,
 identities_and_evidence_equal=TRUE,includes_full_scientific_parity=FALSE,
 production_writes=FALSE)
writeLines(toJSON(manifest,pretty=TRUE,auto_unbox=TRUE),
 file.path(out,"validated_parity_manifest.json"))
cat(sprintf("PASS: frozen candidate parity; %d exact and %d fuzzy pairs\n",n_exact,n_fuzzy))

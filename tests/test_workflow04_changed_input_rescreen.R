suppressPackageStartupMessages(library(jsonlite))

td <- tempfile("w04-fingerprint-change-")
dir.create(td, recursive=TRUE)

write_jsonl <- function(xs,path){
  con <- file(path,"wt",encoding="UTF-8"); on.exit(close(con))
  for(x in xs) writeLines(toJSON(x,auto_unbox=TRUE,null="null",na="null"),con,useBytes=TRUE)
}

canonical_prior <- list(list(
  identity=list(record_id="work-test"),
  canonical=list(
    title="Same title",
    abstract="Old abstract",
    keywords="alpha",
    journal="Journal A",
    affiliations="Affiliation",
    funding="Funding"
  )
))
canonical_current <- list(list(
  identity=list(record_id="work-test"),
  canonical=list(
    title="Same title",
    abstract="Changed abstract",
    keywords="alpha",
    journal="Journal A",
    affiliations="Affiliation",
    funding="Funding"
  )
))

fingerprint <- function(r){
  c <- r$canonical
  digest::digest(
    toJSON(list(
      title=c$title,
      abstract=c$abstract,
      keywords=c$keywords,
      journal_source_title=c$journal,
      affiliations=c$affiliations,
      funding=c$funding
    ),auto_unbox=TRUE,null="null",na="null",digits=NA),
    algo="sha256",serialize=FALSE
  )
}

prior_fp <- fingerprint(canonical_prior[[1L]])
prior_w04 <- list(list(
  record_id="work-test",
  screening=list(
    decision="retain",
    screening_input_sha256=prior_fp,
    input_title_present=TRUE,
    input_abstract_present=TRUE
  )
))
w03 <- list(list(
  record_id="work-test",
  publication_status=list(exclude_from_workflow04=FALSE)
))

prior_can_path <- file.path(td,"prior.jsonl")
cur_can_path <- file.path(td,"current.jsonl")
prior_w04_path <- file.path(td,"prior_w04.jsonl")
w03_path <- file.path(td,"w03.jsonl")
out_dir <- file.path(td,"out")
write_jsonl(canonical_prior,prior_can_path)
write_jsonl(canonical_current,cur_can_path)
write_jsonl(prior_w04,prior_w04_path)
write_jsonl(w03,w03_path)

status <- system2(
  file.path(R.home("bin"),"Rscript"),
  c(
    "scripts/updater/workflow_04_prepare_incremental.R",
    "--canonical",cur_can_path,
    "--workflow03-status",w03_path,
    "--prior-workflow04",prior_w04_path,
    "--prior-canonical",prior_can_path,
    "--output-dir",out_dir
  ),
  stdout=FALSE,stderr=FALSE
)
stopifnot(status==0L)

queued <- trimws(readLines(file.path(out_dir,"screen_queue_record_ids.txt"),warn=FALSE))
reused <- trimws(readLines(file.path(out_dir,"reused_record_ids.txt"),warn=FALSE))
manifest <- fromJSON(file.path(out_dir,"prepare_manifest.json"),simplifyVector=FALSE)
queue_manifest <- read.csv(file.path(out_dir,"screen_queue_manifest.csv"),stringsAsFactors=FALSE)

stopifnot(
  identical(queued,"work-test"),
  !("work-test" %in% reused),
  as.integer(manifest$changed_screening_input)==1L,
  as.integer(manifest$changed_screening_input_reused)==0L,
  identical(as.character(manifest$scientific_input_refresh_rule),"any_screening_input_fingerprint_change"),
  identical(as.character(queue_manifest$queue_reason[[1L]]),"screening_input_changed")
)

cat("PASS: W04 changed screening fingerprint forces fresh screening\n")

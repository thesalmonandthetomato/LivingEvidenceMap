#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(readr)
  library(jsonlite)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default=NULL) {
  i <- match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop("Missing value after ",flag,call.=FALSE)
  args[[i+1L]]
}
zero_path <- arg("--zero")
records_path <- arg("--records")
ontology_path <- arg("--ontology")
out_dir <- arg("--output-dir","outputs/workflow07_zero_topic_deterministic")
if(any(vapply(list(zero_path,records_path,ontology_path),is.null,logical(1)))) stop("Required: --zero --records --ontology")
dir.create(out_dir,recursive=TRUE,showWarnings=FALSE)

Z <- read_csv(zero_path,show_col_types=FALSE,progress=FALSE)
R <- read_csv(records_path,show_col_types=FALSE,progress=FALSE)
O <- read_csv(ontology_path,show_col_types=FALSE,progress=FALSE)
stopifnot("record_id" %in% names(Z), "current_record_id" %in% names(R),
          all(c("title","abstract") %in% names(R)),
          all(c("path_id","hierarchy_path","required_subject_terms","required_focus_terms",
                "alternative_standalone_cues","supporting_terms_from_old_ontology") %in% names(O)))
if(nrow(Z)!=358L) stop("Expected 358 zero-topic records, found ",nrow(Z))
if(anyDuplicated(Z$record_id)) stop("Duplicate zero-topic record IDs")
if(anyDuplicated(R$current_record_id)) stop("Duplicate current_record_id in record source")

X <- merge(Z,R[,c("current_record_id","title","abstract")],
           by.x="record_id",by.y="current_record_id",all.x=TRUE,sort=FALSE)
if(any(is.na(X$title) & is.na(X$abstract))) stop("Missing title/abstract source for at least one zero-topic record")

norm <- function(x) {
  x[is.na(x)] <- ""
  x <- tolower(x)
  x <- gsub("<[^>]+>"," ",x)
  x <- gsub("[[:space:]]+"," ",x)
  trimws(x)
}
split_cues <- function(x) {
  if(is.na(x) || !nzchar(trimws(x))) return(character())
  z <- trimws(unlist(strsplit(as.character(x),",",fixed=TRUE)))
  z <- norm(z)
  z <- z[nchar(z)>=4L]
  unique(z[nzchar(z)])
}
matches <- function(text,cues) {
  if(!length(cues)) return(character())
  cues[vapply(cues,function(cue) grepl(cue,text,fixed=TRUE),logical(1))]
}

candidate_rows <- list()
record_rows <- vector("list",nrow(X))
for(i in seq_len(nrow(X))) {
  txt <- norm(paste(X$title[[i]],X$abstract[[i]],sep=" "))
  strong_ids <- character()
  weak_ids <- character()
  for(j in seq_len(nrow(O))) {
    subj <- split_cues(O$required_subject_terms[[j]])
    focus <- split_cues(O$required_focus_terms[[j]])
    alt <- split_cues(O$alternative_standalone_cues[[j]])
    supp <- split_cues(O$supporting_terms_from_old_ontology[[j]])

    ms <- matches(txt,subj)
    mf <- matches(txt,focus)
    ma <- matches(txt,alt)
    mp <- matches(txt,supp)

    strong <- length(ma)>0L || (length(subj)>0L && length(focus)>0L && length(ms)>0L && length(mf)>0L)
    weak <- !strong && (length(ms)+length(mf)+length(mp)>0L)

    if(strong || weak) {
      candidate_rows[[length(candidate_rows)+1L]] <- data.frame(
        record_id=X$record_id[[i]],path_id=O$path_id[[j]],hierarchy_path=O$hierarchy_path[[j]],
        cue_strength=if(strong) "clear" else "weak",
        matched_subject=paste(ms,collapse=" | "),
        matched_focus=paste(mf,collapse=" | "),
        matched_standalone=paste(ma,collapse=" | "),
        matched_supporting=paste(mp,collapse=" | "),
        stringsAsFactors=FALSE)
    }
    if(strong) strong_ids <- c(strong_ids,O$path_id[[j]])
    if(weak) weak_ids <- c(weak_ids,O$path_id[[j]])
  }
  category <- if(length(strong_ids)>0L) "clear_candidate_pathway" else if(length(weak_ids)>0L) "weak_or_ambiguous_cues" else "no_ontology_cues"
  record_rows[[i]] <- data.frame(
    record_id=X$record_id[[i]],title=X$title[[i]],
    deterministic_category=category,
    clear_candidate_count=length(unique(strong_ids)),
    weak_candidate_count=length(unique(weak_ids)),
    clear_candidate_path_ids=paste(unique(strong_ids),collapse=";"),
    stringsAsFactors=FALSE)
}

C <- if(length(candidate_rows)) do.call(rbind,candidate_rows) else data.frame()
Q <- do.call(rbind,record_rows)
write_csv(Q,file.path(out_dir,"zero_topic_deterministic_record_results.csv"),na="")
write_csv(C,file.path(out_dir,"zero_topic_deterministic_candidate_details.csv"),na="")

counts <- as.list(table(factor(Q$deterministic_category,
  levels=c("no_ontology_cues","weak_or_ambiguous_cues","clear_candidate_pathway"))))
names(counts) <- c("no_ontology_cues","weak_or_ambiguous_cues","clear_candidate_pathway")
summary <- list(
  schema="living-evidence-map-workflow07-zero-topic-deterministic-v1",
  zero_topic_records=nrow(Q),
  category_counts=counts,
  clear_candidate_definition="at least one alternative standalone cue OR at least one required-subject cue plus at least one required-focus cue for the same ontology pathway",
  weak_definition="one or more subject, focus, or supporting lexical cues without satisfying the clear-candidate rule",
  interpretation="deterministic lexical triage only; this does not add topic assignments or overturn the three-Luna result"
)
write_json(summary,file.path(out_dir,"summary.json"),pretty=TRUE,auto_unbox=TRUE,null="null")
writeLines("PASS",file.path(out_dir,"PASS.ok"))
cat(toJSON(summary,pretty=TRUE,auto_unbox=TRUE),"\n")

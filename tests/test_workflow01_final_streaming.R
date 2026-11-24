#!/usr/bin/env Rscript
# Regression for the wide-pair CSV memory-mapped failure (17.28 GiB in W01).
# Uses >4,000 records to cross a streaming chunk boundary, multiline/quoted
# descriptive fields, one locked human decision and an LLM decision.
suppressPackageStartupMessages({library(data.table);library(jsonlite);library(digest)})
td <- tempfile("w01-final-stream-");dir.create(td)
stopifnot(dir.exists(td))
meta <- data.table(idx=1:4203,source="lens",source_record_id=as.character(1:4203))
fwrite(meta,file.path(td,"meta.csv"))
wide <- paste(rep("wide descriptive field with comma, quote \" and unicode café ",85),collapse="")
rows <- data.table(
  record_i=seq_len(4200L),record_j=rep(4203L,4200L),
  pair_key=paste(seq_len(4200L),4203L,sep="::"),
  rescored_classification=c("duplicate","review","review",rep("not_duplicate",4197L)),
  rescored_rule=c("exact","requires_human","llm_review",rep("deterministic",4197L)),
  review_route=c("automatic","manual_review","manual_review",rep("none",4197L)),
  notes=rep(wide,4200L)
)
rows$notes[[4002L]] <- paste0("quoted \"phrase\", with newline\nand a second line")
fwrite(rows,file.path(td,"combined.csv"),na="")
gz_path <- file.path(td,"combined.csv.gz")
gz_status <- system2("gzip",c("-1","-c",file.path(td,"combined.csv")),stdout=gz_path)
stopifnot(identical(gz_status,0L),file.info(gz_path)$size>0L)
previous <- data.table(idx=c(1L,2L,4203L),source="lens",
  source_record_id=c("1","2","4203"),
  cluster_id=c("work-old-a","work-old-b","work-old-c"))
fwrite(previous,file.path(td,"previous.csv"))
llm <- list(
  list(pair_key="2::4203",review_case_id="human-1",promotion="human_review",
    model_decision="review",model_confidence=0.75,model_rationale="manual check"),
  list(pair_key="3::4203",review_case_id="model-1",promotion="not_duplicate",
    model_decision="not_duplicate",model_confidence=0.98,model_rationale="different study")
)
writeLines(vapply(llm,toJSON,character(1),auto_unbox=TRUE,null="null"),file.path(td,"llm.jsonl"))
human <- list(review_case_id="human-1",decision="duplicate",rationale="same publication")
writeLines(toJSON(human,auto_unbox=TRUE),file.path(td,"human.jsonl"))
writeLines(toJSON(list(resume_allowed=TRUE,active_decisions=1L),auto_unbox=TRUE),
  file.path(td,"integrity.json"))
out <- file.path(td,"out")
args <- c("scripts/updater/workflow_01_apply_adjudications_and_recluster.R",
  "--combined-decisions",gz_path,
  "--manifestation-map",file.path(td,"meta.csv"),
  "--llm-adjudications",file.path(td,"llm.jsonl"),
  "--human-decisions",file.path(td,"human.jsonl"),
  "--human-integrity-manifest",file.path(td,"integrity.json"),
  "--previous-cluster-map",file.path(td,"previous.csv"),
  "--output-dir",out)
run <- suppressWarnings(system2("Rscript",args,stdout=TRUE,stderr=TRUE))
status <- attr(run,"status")
if(is.null(status)) status <- 0L
cat(paste(run,collapse="\n"),"\n")
stopifnot(status==0L)
final <- fread(file.path(out,"final_pair_decisions.csv"),na.strings=c("","NA"))
stopifnot(nrow(final)==nrow(rows),setequal(final$pair_key,rows$pair_key))
stopifnot(identical(final[pair_key=="2::4203",rescored_classification],"duplicate"))
stopifnot(identical(final[pair_key=="2::4203",rescored_rule],"workflow01_human_adjudication"))
stopifnot(identical(final[pair_key=="3::4203",rescored_classification],"not_duplicate"))
stopifnot(identical(final[pair_key=="3::4203",rescored_rule],"workflow01_llm_adjudication"))
actual_note <- final[pair_key=="4002::4203",notes]
input_note <- fread(file.path(td,"combined.csv"),na.strings=c("","NA"))[pair_key=="4002::4203",notes]
stopifnot(identical(actual_note,input_note))
stopifnot(identical(final[pair_key=="1::4203",notes],
  fread(file.path(td,"combined.csv"),na.strings=c("","NA"))[pair_key=="1::4203",notes]))
summary <- fromJSON(file.path(out,"summary.json"))
stopifnot(summary$total_pair_decisions==4200L,summary$automatic_duplicate_edges==2L,
  summary$human_final_decisions==1L,summary$llm_final_decisions==1L,
  summary$unresolved_pair_decisions==0L)
map <- fread(file.path(out,"manifestation_cluster_map.csv"))
stopifnot(identical(unique(map[idx %in% c(1L,2L,4203L),cluster_id]),"work-old-a"))
stopifnot(all(map[idx %in% c(1L,2L,4203L),cluster_size]==3L))
aliases <- fread(file.path(out,"cluster_id_aliases.csv"))
stopifnot(setequal(aliases$retired_cluster_id,c("work-old-b","work-old-c")))
audit <- lapply(readLines(file.path(out,"adjudication_application_audit.jsonl")),fromJSON)
stopifnot(length(audit)==2L,all(vapply(audit,function(z)z$before=="review",logical(1))))
cat("ALL_W01_BOUNDED_MEMORY_FINALISATION_TESTS_PASS\n")
unlink(td,recursive=TRUE)

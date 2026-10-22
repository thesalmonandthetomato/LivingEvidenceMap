suppressPackageStartupMessages(library(digest))
source("shiny_w07/R/w07_shiny_trial_gate.R")
review <- "test-review"
ontology_text <- paste(c(
"path_id,level_1,level_2,level_3,definition",
"ALM_001,Production,Performance,Yield,Crop yield",
"ALM_002,Social,Labour,Conditions,Worker welfare"),collapse="\n")
prompt_text <- "Assign only independently substantive topics. Multiple codes allowed."
make_pair <- function(type,content) {
  sha <- w07_trial_sha(content)
  list(object=list(schema="lem-w07-shiny-configuration-v1",review_id=review,
                   type=type,sha256=sha,content=content),
       approval=list(schema="lem-w07-shiny-approval-v1",review_id=review,
                     type=type,sha256=sha,
                     filename=paste0("w07-",type,"-",sha,".json")),sha=sha)
}
ont <- make_pair("ontology",ontology_text)
prom <- make_pair("prompt",prompt_text)
parsed <- w07_trial_validate_version(ont$object,ont$approval,review,"ontology",ont$sha)
text <- w07_trial_validate_version(prom$object,prom$approval,review,"prompt",prom$sha)
stopifnot(nrow(parsed)==2L,identical(text,prompt_text))
bad <- prom$approval;bad$review_id <- "another-review"
stopifnot(inherits(try(w07_trial_validate_version(prom$object,bad,review,"prompt",prom$sha),silent=TRUE),"try-error"))
bad <- prom$object;bad$content <- paste0(bad$content," altered")
stopifnot(inherits(try(w07_trial_validate_version(bad,prom$approval,review,"prompt",prom$sha),silent=TRUE),"try-error"))
records <- data.frame(record_id=c("r1","r2"),title=c("First","Second"),
                      abstract=c("One","Two"),stringsAsFactors=FALSE)
trial <- w07_trial_prepare(records,1L,parsed,text,review,paste(rep("a",64),collapse=""),ont$sha,prom$sha)
stopifnot(nrow(trial$records)==1L,identical(trial$manifest$source_stage,"W05"),
          isTRUE(trial$manifest$w06_bypassed))
stopifnot(inherits(try(w07_trial_validate_size(3L,2L),silent=TRUE),"try-error"))
cat("PASS W07 approved-version gate, checksum checks, cross-review guard and subset preparation\n")

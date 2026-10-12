source("scripts/updater/workflow_00_review_transition_rules.R")
meta<-data.frame(key=c("review_id","latest_w00_run_id","latest_w00_status"),
                 value=c("almeria-map","",""),stringsAsFactors=FALSE)
events<-data.frame(event_id=character(),github_run_id=character(),
                   event_type=character(),zenodo_record_id=character())
expect_error<-function(expr) {
  got<-tryCatch({force(expr);FALSE},error=function(e) TRUE)
  if(!got)stop("Expected transition rejection",call.=FALSE)
}
stopifnot(w00_review_transition(meta,events,"almeria-map","100","start")$status=="running")
meta$value[2:3]<-c("100","running")
stopifnot(w00_review_transition(meta,events,"almeria-map","100","success","12345")$status=="success")
stopifnot(w00_review_transition(meta,events,"almeria-map","100","failure")$status=="failed")
expect_error(w00_review_transition(meta,events,"wrong-review","100","success","12345"))
expect_error(w00_review_transition(meta,events,"almeria-map","99","success","12345"))
expect_error(w00_review_transition(meta,events,"almeria-map","101","start"))
expect_error(w00_review_transition(meta,events,"almeria-map","100","success",""))
meta$value[3]<-"failed"
expect_error(w00_review_transition(meta,events,"almeria-map","100","success","12345"))
meta$value[3]<-"success"
expect_error(w00_review_transition(meta,events,"almeria-map","100","failure"))
meta$key<-c("review_id","review_id","latest_w00_status")
expect_error(w00_review_transition(meta,events,"almeria-map","100","start"))
cat("PASS: synthetic W00 start/success/failure and isolation transitions\n")

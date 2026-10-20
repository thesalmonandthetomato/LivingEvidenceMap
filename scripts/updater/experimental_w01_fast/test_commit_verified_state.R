#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(digest)})
root<-tempfile("state-commit-");dir.create(root)
artifact<-file.path(root,"object.csv");writeLines("v1",artifact)
runner<-file.path(R.home("bin"),"Rscript")
run<-function(script,args,ok=TRUE){
 z<-suppressWarnings(system2(runner,c(script,args),stdout=TRUE,stderr=TRUE))
 status<-attr(z,"status");if(is.null(status))status<-0L
 if((status==0L)!=ok)stop(paste(status,paste(z,collapse=" | ")))
}
create<-function(n){
 path<-file.path(root,paste0("s",n))
 run("scripts/updater/experimental_w01_fast/create_state_snapshot.R",
 c("--batch-id",paste0("batch-",n),"--artifact",paste0("clusters=",artifact),
 "--output-dir",path));path
}
first<-create(1);writeLines("v2",artifact);second<-create(2)
state<-file.path(root,"state")
commit<-"scripts/updater/experimental_w01_fast/commit_verified_state.R"
call<-function(s,parent,ok=TRUE)run(commit,c("--state-dir",state,
 "--snapshot-dir",s,"--expected-parent-sha256",parent),ok)
call(first,"NONE")
pointer<-file.path(state,"CURRENT.json")
original<-digest(file=pointer,algo="sha256")
call(second,"NONE",FALSE)
stopifnot(identical(original,digest(file=pointer,algo="sha256")))
call(second,original)
current<-fromJSON(pointer)
stopifnot(identical(current$batch_id,"batch-2"))
# Corrupted snapshot cannot advance pointer.
object<-fromJSON(file.path(first,"manifest.json"))$objects$clusters$object
writeLines("damaged",file.path(first,object))
before<-digest(file=pointer,algo="sha256")
call(first,before,FALSE)
stopifnot(identical(before,digest(file=pointer,algo="sha256")))
cat("PASS: guarded checkpoint advancement, stale parent rejection and corruption recovery\n")

# Verify current pointer references an intact, fully checked checkpoint.
check_current<-function(ok=TRUE){
 z<-suppressWarnings(system2(runner,c(
 "scripts/updater/experimental_w01_fast/verify_current_state.R",
 "--state-dir",state),stdout=TRUE,stderr=TRUE))
 code<-attr(z,"status");if(is.null(code))code<-0L
 if((code==0L)!=ok)stop(paste("Unexpected current-state verification",code))
}
check_current()
# A valid current pointer with a tampered content object must fail closed.
current_obj<-fromJSON(file.path(second,"manifest.json"))$objects$clusters$object
current_path<-file.path(second,current_obj)
saved<-readLines(current_path)
writeLines("tampered",current_path)
check_current(FALSE)
writeLines(saved,current_path)
check_current()

# A previous interrupted commit with an unresolved backup must not be
# overwritten or silently accepted as a successful state transition.
backup<-paste0(pointer,".bak")
stopifnot(file.copy(pointer,backup,overwrite=FALSE))
before_interruption<-digest(file=pointer,algo="sha256")
call(second,before_interruption,FALSE)
stopifnot(identical(before_interruption,digest(file=pointer,algo="sha256")),
 file.exists(backup))
unlink(backup)
check_current()

# Diagnostic must not change either pointer and must fail closed on ambiguity.
inspect<-function(ok=TRUE){
 z<-suppressWarnings(system2(runner,c(
 "scripts/updater/experimental_w01_fast/inspect_interrupted_state.R",
 "--state-dir",state),stdout=TRUE,stderr=TRUE))
 code<-attr(z,"status");if(is.null(code))code<-0L
 if((code==0L)!=ok)stop(paste("Unexpected diagnostic status",code))
}
inspect()
stopifnot(file.copy(pointer,backup,overwrite=FALSE))
current_hash<-digest(file=pointer,algo="sha256")
backup_hash<-digest(file=backup,algo="sha256")
inspect(FALSE)
stopifnot(identical(current_hash,digest(file=pointer,algo="sha256")),
 identical(backup_hash,digest(file=backup,algo="sha256")))
unlink(backup)
inspect()

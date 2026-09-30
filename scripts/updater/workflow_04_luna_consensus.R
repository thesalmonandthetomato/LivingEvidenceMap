#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
  library(stringi)
  library(digest)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
canonical_path <- arg("--canonical")
w03_path <- arg("--workflow03-status")
screening_config_path <- arg("--screening-config","user_input/workflow04_screening_config.json")
output_dir <- arg("--output-dir","outputs/workflow04_consensus")
model <- arg("--model",Sys.getenv("OPENAI_RELEVANCE_MODEL","gpt-5.6-luna"))
checkpoint_every <- as.integer(arg("--checkpoint-every","25"))
max_records <- as.integer(arg("--max-records","0"))
shard_index <- as.integer(arg("--shard-index","1"))
shard_count <- as.integer(arg("--shard-count","1"))
subshard_index <- as.integer(arg("--subshard-index","1"))
subshard_count <- as.integer(arg("--subshard-count","1"))
if(is.na(shard_index)||is.na(shard_count)||shard_count<1L||shard_index<1L||shard_index>shard_count) stop("Invalid shard index/count",call.=FALSE)
if(is.na(subshard_index)||is.na(subshard_count)||subshard_count<1L||subshard_index<1L||subshard_index>subshard_count) stop("Invalid subshard index/count",call.=FALSE)
if(is.null(canonical_path)||is.null(w03_path)) stop("Required: --canonical --workflow03-status",call.=FALSE)
if(!nzchar(Sys.getenv("OPENAI_API_KEY"))) stop("OPENAI_API_KEY is required",call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

`%||%` <- function(x,y) if(is.null(x)) y else x
now_utc <- function() format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
scalar <- function(x){if(is.null(x)||!length(x))return("");z<-as.character(x[[1L]]);if(is.na(z))"" else trimws(z)}
if(!file.exists(screening_config_path)) stop("Workflow 04 screening config is missing",call.=FALSE)
SCREENING_CONFIG <- fromJSON(screening_config_path,simplifyVector=FALSE)
PROMPT_PATH <- scalar(SCREENING_CONFIG$prompt_path)
PROMPT_VERSION <- scalar(SCREENING_CONFIG$prompt_version)
RESPONSE_SCHEMA_NAME <- scalar(SCREENING_CONFIG$response_schema_name)
EXPECTED_PROMPT_SHA256 <- scalar(SCREENING_CONFIG$expected_prompt_sha256)
if(!nzchar(PROMPT_PATH)||!file.exists(PROMPT_PATH)) stop("Workflow 04 screening prompt file is missing",call.=FALSE)
if(!nzchar(PROMPT_VERSION)) stop("Workflow 04 screening config lacks prompt_version",call.=FALSE)
if(!nzchar(RESPONSE_SCHEMA_NAME)) stop("Workflow 04 screening config lacks response_schema_name",call.=FALSE)
if(!grepl("^[0-9a-f]{64}$",EXPECTED_PROMPT_SHA256)) stop("Workflow 04 screening config has invalid expected_prompt_sha256",call.=FALSE)
SYSTEM_PROMPT <- paste(readLines(PROMPT_PATH,warn=FALSE,encoding="UTF-8"),collapse="\n")
PROMPT_SHA256 <- digest::digest(SYSTEM_PROMPT,algo="sha256",serialize=FALSE)
if(!identical(PROMPT_SHA256,EXPECTED_PROMPT_SHA256)){
  stop(sprintf("IMMUTABLE PROMPT CHECK FAILED: expected %s got %s",EXPECTED_PROMPT_SHA256,PROMPT_SHA256),call.=FALSE)
}

read_jsonl <- function(path){
  x<-readLines(path,warn=FALSE,encoding="UTF-8");x<-x[nzchar(trimws(x))]
  lapply(seq_along(x),function(i)tryCatch(fromJSON(x[[i]],simplifyVector=FALSE),error=function(e)stop(sprintf("Invalid JSONL %s line %d: %s",path,i,conditionMessage(e)),call.=FALSE)))
}
append_jsonl <- function(x,path){con<-file(path,"at",encoding="UTF-8");on.exit(close(con));writeLines(toJSON(x,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)}
write_jsonl <- function(rows,path){con<-file(path,"wt",encoding="UTF-8");on.exit(close(con));for(x in rows)writeLines(toJSON(x,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)}
textify <- function(x){
  if(is.null(x))return("")
  if(is.character(x))return(paste(x[nzchar(x)],collapse="; "))
  if(is.atomic(x))return(paste(as.character(x),collapse="; "))
  if(is.list(x))return(paste(Filter(nzchar,vapply(x,textify,character(1))),collapse="; "))
  as.character(x)
}
first_nonempty <- function(...){for(x in list(...)){z<-textify(x);if(nzchar(trimws(z)))return(trimws(z))};""}
record_id <- function(r) scalar((r$identity %||% list())$record_id)
canonical <- function(r){x<-r$canonical %||% list();if(is.list(x))x else list()}
screening_view <- function(r){
  c<-canonical(r)
  list(
    title=first_nonempty(c$title,r$title),
    abstract=first_nonempty(c$abstract,r$abstract),
    keywords=first_nonempty(c$keywords,r$keywords),
    journal_source_title=first_nonempty(c$source_title,c$journal,r$source_title,r$journal),
    affiliations=first_nonempty(c$affiliations,r$affiliations),
    funding=first_nonempty(c$funding,c$funders,r$funding,r$funders)
  )
}
record_view <- function(r)c(list(record_id=record_id(r)),screening_view(r))
screening_fingerprint <- function(r){
  digest(toJSON(screening_view(r),auto_unbox=TRUE,null="null",na="null",digits=NA),algo="sha256",serialize=FALSE)
}
extract_output_text <- function(resp){
  for(it in resp$output %||% list()) if(is.list(it)&&identical(it$type,"message"))
    for(ct in it$content %||% list()) if(is.list(ct)&&identical(ct$type,"output_text")&&!is.null(ct$text)) return(as.character(ct$text))
  stop("No output_text returned by Responses API")
}
w03_excluded <- function(x){
  isTRUE((x$publication_status %||% list())$exclude_from_workflow04 %||% x$exclude_from_workflow04 %||% FALSE)
}
schema <- list(
  type="object",additionalProperties=FALSE,
  properties=list(decision=list(type="string",enum=list("retain","exclude","uncertain")),reason=list(type="string")),
  required=list("decision","reason")
)
screen_one <- function(r,pass){
  view<-record_view(r)
  tryCatch({
    user_text<-paste0("SCREEN THIS RECORD USING ONLY THE SUPPLIED METADATA.\n\n",toJSON(view,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"))
    body<-list(
      model=model,store=FALSE,reasoning=list(effort="low"),
      input=list(
        list(role="system",content=list(list(type="input_text",text=SYSTEM_PROMPT))),
        list(role="user",content=list(list(type="input_text",text=user_text)))
      ),
      text=list(verbosity="low",format=list(type="json_schema",name=RESPONSE_SCHEMA_NAME,strict=TRUE,schema=schema))
    )
    resp<-request("https://api.openai.com/v1/responses") |>
      req_auth_bearer_token(Sys.getenv("OPENAI_API_KEY")) |>
      req_body_json(body,auto_unbox=TRUE) |> req_timeout(120) |>
      req_retry(max_tries=5,backoff=~min(30,2^.x)) |> req_perform() |>
      resp_body_json(simplifyVector=FALSE)
    parsed<-fromJSON(extract_output_text(resp),simplifyVector=FALSE)
    d<-scalar(parsed$decision); rr<-scalar(parsed$reason)
    if(!d %in% c("retain","exclude","uncertain")) stop("Invalid model decision")
    if(!nzchar(rr)) stop("Empty model reason")
    list(
      record_id=record_id(r),pass=pass,decision=d,reason=rr,
      technical_failure=FALSE,error=NULL,model_requested=model,
      model_returned=scalar(resp$model %||% model),response_id=scalar(resp$id),
      usage=resp$usage %||% NULL,prompt_version=PROMPT_VERSION,
      prompt_sha256=PROMPT_SHA256,screened_at=now_utc()
    )
  },error=function(e) list(
    record_id=record_id(r),pass=pass,decision="uncertain",
    reason="Technical screening failure; retry required.",technical_failure=TRUE,
    error=conditionMessage(e),model_requested=model,model_returned=NULL,response_id=NULL,
    usage=NULL,prompt_version=PROMPT_VERSION,prompt_sha256=PROMPT_SHA256,screened_at=now_utc()
  ))
}
run_pass <- function(records,pass,path){
  existing<-if(file.exists(path))read_jsonl(path) else list()
  done<-if(length(existing))vapply(existing,function(x)scalar(x$record_id),character(1)) else character()
  if(anyDuplicated(done))stop(sprintf("Duplicate record IDs in pass %d checkpoint",pass),call.=FALSE)
  ids<-vapply(records,record_id,character(1))
  if(any(!done %in% ids))stop(sprintf("Pass %d checkpoint contains IDs absent from queue",pass),call.=FALSE)
  total<-length(records)
  for(i in seq_along(records)){
    rid<-ids[[i]]
    if(rid %in% done)next
    row<-screen_one(records[[i]],pass)
    append_jsonl(row,path)
    done<-c(done,rid)
    if(length(done)%%checkpoint_every==0L || length(done)==total){
      cat(sprintf("PASS %d checkpoint: %d/%d\n",pass,length(done),total))
    }
  }
  read_jsonl(path)
}

canonical_records<-read_jsonl(canonical_path)
cids<-vapply(canonical_records,record_id,character(1))
if(any(!nzchar(cids))||anyDuplicated(cids))stop("Canonical record_id invariant failed",call.=FALSE)

w03<-read_jsonl(w03_path)
wids<-vapply(w03,function(x)scalar(x$record_id),character(1))
if(length(w03)!=length(canonical_records)||any(!nzchar(wids))||anyDuplicated(wids)||!setequal(cids,wids))stop("Workflow 03 identity invariant failed",call.=FALSE)
wm<-setNames(w03,wids)
eligible_idx<-which(!vapply(cids,function(id)w03_excluded(wm[[id]]),logical(1)))
eligible_all<-canonical_records[eligible_idx]
eligible_all_ids<-vapply(eligible_all,record_id,character(1))
ord<-order(eligible_all_ids)
eligible_all<-eligible_all[ord]
eligible_all_ids<-eligible_all_ids[ord]
shard_membership<-((seq_along(eligible_all)-1L) %% shard_count)+1L
eligible<-eligible_all[shard_membership==shard_index]
if(subshard_count>1L){
  parent_ids<-vapply(eligible,record_id,character(1))
  parent_ord<-order(parent_ids)
  eligible<-eligible[parent_ord]
  sub_membership<-((seq_along(eligible)-1L) %% subshard_count)+1L
  eligible<-eligible[sub_membership==subshard_index]
}
if(max_records>0L) eligible<-eligible[seq_len(min(max_records,length(eligible)))]

if(!length(eligible)){
  write_jsonl(list(),file.path(output_dir,"workflow04_consensus_layer.jsonl"))
  summary<-list(
    schema="living-evidence-map-workflow04-luna-consensus-v1",
    status="PASS",
    canonical_records=length(canonical_records),
    workflow03_excluded=length(canonical_records)-length(eligible_idx),
    workflow03_eligible=length(eligible_idx),
    shard_index=shard_index,shard_count=shard_count,
    subshard_index=subshard_index,subshard_count=subshard_count,
    records_screened=0L,pass1_records=0L,pass2_records=0L,
    third_pass_records=0L,two_of_two_agreement=0L,
    final_retain=0L,final_exclude=0L,final_unresolved=0L,
    model=model,prompt_version=PROMPT_VERSION,prompt_sha256=PROMPT_SHA256,
    prompt_immutable_check=TRUE,created_at_utc=now_utc()
  )
  writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),file.path(output_dir,"summary.json"),useBytes=TRUE)
  cat(sprintf("PASS: Workflow 04 shard %d/%d is empty for a %d-record queue\n",shard_index,shard_count,length(eligible_idx)))
  quit(save="no",status=0L)
}

p1_path<-file.path(output_dir,"pass1.jsonl")
p2_path<-file.path(output_dir,"pass2.jsonl")
p3_path<-file.path(output_dir,"pass3_conflicts.jsonl")

p1<-run_pass(eligible,1L,p1_path)
p2<-run_pass(eligible,2L,p2_path)

map_dec<-function(rows)setNames(vapply(rows,function(x)scalar(x$decision),character(1)),vapply(rows,function(x)scalar(x$record_id),character(1)))
map_fail<-function(rows)setNames(vapply(rows,function(x)isTRUE(x$technical_failure),logical(1)),vapply(rows,function(x)scalar(x$record_id),character(1)))
d1<-map_dec(p1);d2<-map_dec(p2);f1<-map_fail(p1);f2<-map_fail(p2)
ids<-vapply(eligible,record_id,character(1))
if(!setequal(names(d1),ids)||!setequal(names(d2),ids))stop("Pass 1/2 coverage invariant failed",call.=FALSE)

# Any disagreement, UNCERTAIN, or technical failure gets a third vote.
need3<-ids[(d1[ids]!=d2[ids]) | d1[ids]=="uncertain" | d2[ids]=="uncertain" | f1[ids] | f2[ids]]
queue3<-eligible[match(need3,ids)]
p3<-if(length(queue3))run_pass(queue3,3L,p3_path) else list()
d3<-if(length(p3))map_dec(p3) else character()
f3<-if(length(p3))map_fail(p3) else logical()

final<-vector("list",length(ids))
for(i in seq_along(ids)){
  id<-ids[[i]]
  votes<-c(d1[[id]],d2[[id]])
  failures<-c(f1[[id]],f2[[id]])
  if(id %in% need3){votes<-c(votes,d3[[id]]);failures<-c(failures,f3[[id]])}
  substantive<-votes[!failures & votes %in% c("retain","exclude")]
  nr<-sum(substantive=="retain"); ne<-sum(substantive=="exclude")
  decision<-if(nr>=2L)"retain" else if(ne>=2L)"exclude" else "uncertain"
  final[[i]]<-list(
    record_id=id,
    screening=list(
      decision=decision,
      decision_origin="luna_consensus",
      votes=as.list(votes),
      vote_count=length(votes),
      retain_votes=nr,
      exclude_votes=ne,
      agreement=if(length(votes)==2L && length(unique(votes))==1L && !any(failures))"2_of_2" else if(decision %in% c("retain","exclude"))"2_of_3" else "unresolved",
      requires_human_review=identical(decision,"uncertain"),
      technical_failure_present=any(failures),
      model=model,prompt_version=PROMPT_VERSION,prompt_sha256=PROMPT_SHA256,
      screening_input_sha256=screening_fingerprint(eligible[[i]])
    )
  )
}
write_jsonl(final,file.path(output_dir,"workflow04_consensus_layer.jsonl"))
final_dec<-vapply(final,function(x)scalar(x$screening$decision),character(1))
summary<-list(
  schema="living-evidence-map-workflow04-luna-consensus-v1",
  status=if(any(final_dec=="uncertain"))"HUMAN_REVIEW_REQUIRED" else "PASS",
  canonical_records=length(canonical_records),
  workflow03_excluded=length(canonical_records)-length(eligible_idx),
  workflow03_eligible=length(eligible_idx),
  shard_index=shard_index,shard_count=shard_count,
  subshard_index=subshard_index,subshard_count=subshard_count,
  records_screened=length(eligible),
  pass1_records=length(p1),pass2_records=length(p2),
  third_pass_records=length(need3),
  two_of_two_agreement=length(ids)-length(need3),
  final_retain=sum(final_dec=="retain"),
  final_exclude=sum(final_dec=="exclude"),
  final_unresolved=sum(final_dec=="uncertain"),
  model=model,prompt_version=PROMPT_VERSION,prompt_sha256=PROMPT_SHA256,
  prompt_immutable_check=TRUE,
  created_at_utc=now_utc()
)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),file.path(output_dir,"summary.json"),useBytes=TRUE)
cat(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),"\n")

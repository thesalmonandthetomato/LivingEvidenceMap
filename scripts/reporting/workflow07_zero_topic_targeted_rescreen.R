#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
  library(readr)
  library(digest)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
input_path <- arg("--input")
output_dir <- arg("--output-dir","outputs/workflow07_zero_topic_rescreen")
model <- arg("--model",Sys.getenv("OPENAI_RELEVANCE_MODEL","gpt-5.6-luna"))
shard_index <- as.integer(arg("--shard-index","1"))
shard_count <- as.integer(arg("--shard-count","1"))
checkpoint_every <- as.integer(arg("--checkpoint-every","10"))
if(is.null(input_path)) stop("Required: --input",call.=FALSE)
if(!nzchar(Sys.getenv("OPENAI_API_KEY"))) stop("OPENAI_API_KEY is required",call.=FALSE)
if(shard_count<1L||shard_index<1L||shard_index>shard_count) stop("Invalid shard index/count",call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

now_utc <- function() format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
scalar <- function(x){if(is.null(x)||!length(x))return("");z<-as.character(x[[1L]]);if(is.na(z))"" else trimws(z)}
append_jsonl <- function(x,path){con<-file(path,"at",encoding="UTF-8");on.exit(close(con));writeLines(toJSON(x,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)}
read_jsonl <- function(path){if(!file.exists(path))return(list());x<-readLines(path,warn=FALSE,encoding="UTF-8");x<-x[nzchar(trimws(x))];lapply(x,fromJSON,simplifyVector=FALSE)}
write_jsonl <- function(x,path){con<-file(path,"wt",encoding="UTF-8");on.exit(close(con));for(z in x)writeLines(toJSON(z,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)}

SYSTEM_PROMPT <- paste(
"You are carrying out a targeted eligibility re-screen for a living evidence map of commercial aquaculture of Atlantic salmon, Pacific salmon species, and rainbow trout.",
"",
"Every record in this queue previously passed the main relevance screen, but THREE independent topic-coding passes subsequently assigned ZERO topic codes.",
"This zero-topic result is a QC signal only. It is NOT itself evidence for exclusion, and you must not exclude a record merely because no topic was assigned.",
"",
"Your task is narrower than topic coding:",
"Does the supplied TITLE and ABSTRACT contain sufficient evidence that the record is genuinely linked to eligible commercial salmon or rainbow-trout farming under the evidence-map inclusion criteria?",
"",
"Return exactly one decision: include, exclude, or uncertain.",
"",
"INCLUDE when the title/abstract reasonably establish a real link to commercial farming of:",
"- Atlantic salmon (Salmo salar);",
"- Chinook, coho, sockeye, chum, pink or masu salmon;",
"- rainbow trout (Oncorhynchus mykiss); or",
"- unspecified salmon where salmon farming/aquaculture is explicitly established.",
"",
"Eligible linkage includes farming, production, feed, health, welfare, breeding, environmental effects, wild-population impacts caused by salmon farming, cleaner fish used in salmon farms, salmon-farm therapeutants, products/processing of farmed fish, economics, governance, labour, communities, consumers, or methods specifically applied to eligible salmon farming.",
"An eligible salmon or rainbow-trout species does not need to be the organism directly measured if the study explicitly investigates a consequence, exposure, interaction or process arising from eligible salmon farming.",
"Books, chapters, reports, reviews, policy papers and other non-primary document types are not excluded merely because of document type.",
"",
"EXCLUDE when the title/abstract show that:",
"- the work concerns only wild salmonids, capture fisheries, conservation, hatchery release/restocking or population supplementation;",
"- salmon farming is only background, context, motivation or a passing example rather than an exposure, system, process or subject actually investigated;",
"- only non-eligible aquaculture species are studied and there is no substantive salmon-farming connection;",
"- the work concerns basic salmon biology without a commercial farming connection;",
"- generic salmonid/trout/fish terminology is present but no eligible species or explicit salmon-farming context is established.",
"",
"IMPORTANT DISTINCTION:",
"A paper can mention salmon farming and still be EXCLUDE if farming merely explains why the authors care about another biological or ecological subject.",
"Conversely, a study of a non-salmon organism can be INCLUDE if salmon farming itself is the exposure, system or intervention being investigated.",
"",
"UNCERTAIN only when the supplied title and abstract genuinely do not contain enough information to decide whether the farming linkage is real.",
"Missing or very short abstracts may legitimately lead to UNCERTAIN.",
"",
"Use only the supplied title and abstract plus the stated fact that three topic-coding passes returned zero codes.",
"Do not infer from journal, author, country, DOI, or outside knowledge.",
"",
"For INCLUDE, identify the specific farming linkage in one concise sentence.",
"For EXCLUDE, identify why the apparent salmon/aquaculture mention is only contextual or otherwise fails eligibility.",
"For UNCERTAIN, identify exactly what evidence is missing.",
sep="\n"
)
PROMPT_VERSION <- "workflow07-zero-topic-targeted-rescreen-v1"
PROMPT_SHA256 <- digest::digest(SYSTEM_PROMPT,algo="sha256",serialize=FALSE)

schema <- list(
  type="object",additionalProperties=FALSE,
  properties=list(
    decision=list(type="string",enum=list("include","exclude","uncertain")),
    reason=list(type="string")
  ),
  required=list("decision","reason")
)

extract_output_text <- function(resp){
  for(it in resp$output %||% list()) if(is.list(it)&&identical(it$type,"message"))
    for(ct in it$content %||% list()) if(is.list(ct)&&identical(ct$type,"output_text")&&!is.null(ct$text)) return(as.character(ct$text))
  stop("No output_text returned")
}
`%||%` <- function(x,y) if(is.null(x)) y else x

screen_one <- function(row,pass){
  rid <- as.character(row$record_id)
  title <- ifelse(is.na(row$title),"",as.character(row$title))
  abstract <- ifelse(is.na(row$abstract),"",as.character(row$abstract))
  user_text <- paste0(
    "CODING CONTEXT\nThree independent Workflow 07 Luna topic-coding passes assigned zero topic codes to this record.\n\n",
    "TITLE\n",title,"\n\nABSTRACT\n",abstract,
    "\n\nAssess only whether there is sufficient evidence of linkage to eligible commercial salmon/rainbow-trout farming for inclusion."
  )
  tryCatch({
    body <- list(
      model=model,store=FALSE,reasoning=list(effort="low"),
      input=list(
        list(role="system",content=list(list(type="input_text",text=SYSTEM_PROMPT))),
        list(role="user",content=list(list(type="input_text",text=user_text)))
      ),
      text=list(verbosity="low",format=list(type="json_schema",name="zero_topic_eligibility_rescreen",strict=TRUE,schema=schema))
    )
    resp <- request("https://api.openai.com/v1/responses") |>
      req_auth_bearer_token(Sys.getenv("OPENAI_API_KEY")) |>
      req_body_json(body,auto_unbox=TRUE) |>
      req_timeout(120) |>
      req_retry(max_tries=5,backoff=~min(30,2^.x)) |>
      req_perform() |>
      resp_body_json(simplifyVector=FALSE)
    parsed <- fromJSON(extract_output_text(resp),simplifyVector=FALSE)
    d <- scalar(parsed$decision); reason <- scalar(parsed$reason)
    if(!d %in% c("include","exclude","uncertain")) stop("Invalid decision")
    if(!nzchar(reason)) stop("Empty reason")
    list(record_id=rid,pass=pass,decision=d,reason=reason,technical_failure=FALSE,error=NULL,
         model_requested=model,model_returned=scalar(resp$model %||% model),response_id=scalar(resp$id),
         usage=resp$usage %||% NULL,prompt_version=PROMPT_VERSION,prompt_sha256=PROMPT_SHA256,screened_at=now_utc())
  },error=function(e) list(record_id=rid,pass=pass,decision="uncertain",
      reason="Technical screening failure; retry required.",technical_failure=TRUE,error=conditionMessage(e),
      model_requested=model,model_returned=NULL,response_id=NULL,usage=NULL,
      prompt_version=PROMPT_VERSION,prompt_sha256=PROMPT_SHA256,screened_at=now_utc()))
}

run_pass <- function(records,pass,path){
  existing <- read_jsonl(path)
  done <- if(length(existing)) vapply(existing,function(x)scalar(x$record_id),character(1)) else character()
  ids <- as.character(records$record_id)
  if(anyDuplicated(done)||any(!done %in% ids)) stop("Invalid checkpoint")
  for(i in seq_len(nrow(records))){
    rid <- ids[[i]]
    if(rid %in% done) next
    z <- screen_one(records[i,,drop=FALSE],pass)
    append_jsonl(z,path)
    done <- c(done,rid)
    if(length(done)%%checkpoint_every==0L||length(done)==nrow(records))
      cat(sprintf("pass %d checkpoint: %d/%d\n",pass,length(done),nrow(records)))
  }
  read_jsonl(path)
}

X <- read_csv(input_path,show_col_types=FALSE,progress=FALSE)
stopifnot(all(c("record_id","title","abstract") %in% names(X)))
if(anyDuplicated(X$record_id)) stop("Duplicate record IDs")
X <- X[order(X$record_id),,drop=FALSE]
membership <- ((seq_len(nrow(X))-1L) %% shard_count)+1L
Q <- X[membership==shard_index,,drop=FALSE]
if(!nrow(Q)){
  write_jsonl(list(),file.path(output_dir,"final_rescreen.jsonl"))
  summary <- list(
    schema="living-evidence-map-workflow07-zero-topic-targeted-rescreen-v1",
    records=0L,shard_index=shard_index,shard_count=shard_count,
    third_pass_records=0L,final_include=0L,final_exclude=0L,final_uncertain=0L,
    human_review_candidates=0L,prompt_version=PROMPT_VERSION,prompt_sha256=PROMPT_SHA256,model=model,
    created_at_utc=now_utc()
  )
  write_json(summary,file.path(output_dir,"summary.json"),pretty=TRUE,auto_unbox=TRUE,null="null")
  cat(toJSON(summary,pretty=TRUE,auto_unbox=TRUE),"\n")
  quit(save="no",status=0L)
}

p1 <- run_pass(Q,1L,file.path(output_dir,"pass1.jsonl"))
p2 <- run_pass(Q,2L,file.path(output_dir,"pass2.jsonl"))
map_dec <- function(rows)setNames(vapply(rows,function(x)scalar(x$decision),character(1)),vapply(rows,function(x)scalar(x$record_id),character(1)))
map_fail <- function(rows)setNames(vapply(rows,function(x)isTRUE(x$technical_failure),logical(1)),vapply(rows,function(x)scalar(x$record_id),character(1)))
d1<-map_dec(p1); d2<-map_dec(p2); f1<-map_fail(p1); f2<-map_fail(p2)
ids<-as.character(Q$record_id)
need3 <- ids[(d1[ids]!=d2[ids])|d1[ids]=="uncertain"|d2[ids]=="uncertain"|f1[ids]|f2[ids]]
p3 <- if(length(need3)) run_pass(Q[match(need3,ids),,drop=FALSE],3L,file.path(output_dir,"pass3_conflicts.jsonl")) else list()
d3<-if(length(p3))map_dec(p3)else character(); f3<-if(length(p3))map_fail(p3)else logical()

final <- vector("list",length(ids))
for(i in seq_along(ids)){
  id <- ids[[i]]
  votes <- c(d1[[id]],d2[[id]])
  failures <- c(f1[[id]],f2[[id]])
  if(id %in% need3){votes<-c(votes,d3[[id]]);failures<-c(failures,f3[[id]])}
  substantive <- votes[!failures & votes %in% c("include","exclude")]
  ni<-sum(substantive=="include"); ne<-sum(substantive=="exclude")
  decision <- if(ni>=2L)"include" else if(ne>=2L)"exclude" else "uncertain"
  final[[i]] <- list(
    record_id=id,
    decision=decision,
    votes=as.list(votes),
    include_votes=ni,
    exclude_votes=ne,
    agreement=if(length(votes)==2L&&length(unique(votes))==1L&&!any(failures))"2_of_2" else if(decision %in% c("include","exclude"))"2_of_3" else "unresolved",
    requires_human_review=decision %in% c("exclude","uncertain"),
    technical_failure_present=any(failures),
    prompt_version=PROMPT_VERSION,prompt_sha256=PROMPT_SHA256,model=model
  )
}
write_jsonl(final,file.path(output_dir,"final_rescreen.jsonl"))
dec <- vapply(final,function(x)scalar(x$decision),character(1))
summary <- list(
  schema="living-evidence-map-workflow07-zero-topic-targeted-rescreen-v1",
  records=nrow(Q),shard_index=shard_index,shard_count=shard_count,
  third_pass_records=length(need3),
  final_include=sum(dec=="include"),
  final_exclude=sum(dec=="exclude"),
  final_uncertain=sum(dec=="uncertain"),
  human_review_candidates=sum(dec %in% c("exclude","uncertain")),
  prompt_version=PROMPT_VERSION,prompt_sha256=PROMPT_SHA256,model=model,
  created_at_utc=now_utc()
)
write_json(summary,file.path(output_dir,"summary.json"),pretty=TRUE,auto_unbox=TRUE,null="null")
cat(toJSON(summary,pretty=TRUE,auto_unbox=TRUE),"\n")

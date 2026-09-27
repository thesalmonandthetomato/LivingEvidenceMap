#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(jsonlite)
  library(httr2)
  library(digest)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL){
  i <- match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}

input <- arg("--input")
recovery1 <- arg("--recovery1")
recovery2 <- arg("--recovery2")
prompt_path <- arg("--prompt","config/workflow06_geography_semantic_prompt_v2.txt")
out_dir <- arg("--output-dir","outputs/workflow06_unresolved_rescue")
limit_n <- suppressWarnings(as.integer(arg("--limit","0")))
if(is.null(input)||!file.exists(input)) stop("--input is required",call.=FALSE)
if(is.null(recovery1)||!file.exists(recovery1)) stop("--recovery1 is required",call.=FALSE)
if(is.null(recovery2)||!file.exists(recovery2)) stop("--recovery2 is required",call.=FALSE)
if(!file.exists(prompt_path)) stop("Prompt file not found",call.=FALSE)
dir.create(out_dir,recursive=TRUE,showWarnings=FALSE)

norm_ws <- function(z){
  z <- as.character(z); z[is.na(z)] <- ""
  trimws(gsub("[[:space:]]+"," ",z,perl=TRUE))
}
norm_set <- function(z){
  z <- as.character(z)
  z <- z[!is.na(z)&nzchar(trimws(z))]
  if(!length(z)) return("")
  paste(sort(unique(trimws(z))),collapse="; ")
}
normalise_grounding_text <- function(z){
  z <- as.character(z); z[is.na(z)] <- ""
  z <- gsub("\\\\n|\\\\r|\\\\t"," ",z,perl=TRUE)
  z <- gsub("&nbsp;|&#160;|&#xA0;"," ",z,ignore.case=TRUE,perl=TRUE)
  z <- gsub("&amp;","&",z,ignore.case=TRUE)
  z <- gsub("<[^>]+>"," ",z,perl=TRUE)
  z <- gsub("[\u00AD\u200B\uFEFF]","",z,perl=TRUE)
  z <- chartr("\u2018\u2019\u201C\u201D\u2010\u2011\u2012\u2013\u2014","''\"\"-----",z)
  z <- gsub("[[:punct:]]+"," ",z,perl=TRUE)
  tolower(norm_ws(z))
}
evidence_is_grounded <- function(evidence,title,abstract){
  e_raw <- as.character(evidence)
  if(is.na(e_raw)||!nzchar(trimws(e_raw))) return(FALSE)
  txt <- normalise_grounding_text(paste(title,abstract,sep=" "))
  e <- normalise_grounding_text(e_raw)
  if(grepl(e,txt,fixed=TRUE)) return(TRUE)
  ev <- strsplit(e," ",fixed=TRUE)[[1L]]
  src <- strsplit(txt," ",fixed=TRUE)[[1L]]
  ev <- ev[nzchar(ev)]
  if(length(ev)>=4L){
    j<-1L
    for(tok in src){
      if(j<=length(ev)&&identical(tok,ev[[j]])) j<-j+1L
    }
    if(j>length(ev)) return(TRUE)
  }
  raw <- gsub("\u2026","...",e_raw,fixed=TRUE)
  if(!grepl("...",raw,fixed=TRUE)) return(FALSE)
  parts <- strsplit(raw,"...",fixed=TRUE)[[1L]]
  parts <- vapply(parts,normalise_grounding_text,character(1))
  parts <- trimws(gsub("^[. ]+|[. ]+$","",parts,perl=TRUE))
  parts <- parts[nzchar(parts)&nchar(parts)>=4L]
  if(length(parts)<2L) return(FALSE)
  pos<-1L
  for(part in parts){
    rem<-substr(txt,pos,nchar(txt))
    hit<-regexpr(part,rem,fixed=TRUE)[[1L]]
    if(hit<1L) return(FALSE)
    pos<-pos+hit-1L+nchar(part)
  }
  TRUE
}
apply_recovery <- function(base,repl){
  if(!nrow(repl)) return(base)
  idx <- match(repl$record_id,base$record_id)
  if(any(is.na(idx))) stop("Recovery ID absent from source W06",call.=FALSE)
  cols <- intersect(c("geography_status","luna_iso3c","luna_country_names","luna_evidence",
                      "luna_mapping_reason","evidence_all_grounded","geography_reason",
                      "llm_failed","llm_error"),intersect(names(base),names(repl)))
  for(nm in cols) base[[nm]][idx] <- repl[[nm]]
  base
}

x <- read_csv(input,show_col_types=FALSE,progress=FALSE)
r1 <- read_csv(recovery1,show_col_types=FALSE,progress=FALSE)
r2 <- read_csv(recovery2,show_col_types=FALSE,progress=FALSE)
x <- apply_recovery(x,r1)
x <- apply_recovery(x,r2)

u <- x |> filter(geography_status=="UNRESOLVED",!llm_failed) |> arrange(record_sequence)
stopifnot(nrow(u)==471L,!anyDuplicated(u$record_id))
if(is.finite(limit_n)&&limit_n>0L) u <- head(u,limit_n)

prompt_sha <- digest(file=prompt_path,algo="sha256",serialize=FALSE)
expected_prompt_sha <- "2ef4a9f2099878ae825395f3f09b329f219bfd3a185d3704a8662c52bcff70ed"
if(!identical(prompt_sha,expected_prompt_sha)) stop("Locked geography prompt SHA mismatch",call.=FALSE)
base_prompt <- paste(readLines(prompt_path,warn=FALSE,encoding="UTF-8"),collapse="\n")
rescue_instruction <- paste(
  "",
  "RESCUE PASS FOR A PREVIOUSLY UNRESOLVED RECORD",
  "The previous automated pass returned UNRESOLVED. Reassess the record independently under exactly the rules above.",
  "Do not preserve UNRESOLVED merely because the previous pass used it.",
  "Use RESOLVED if the supplied title/abstract supports a defensible country assignment.",
  "Use NONE if no substantive country-level geography is actually stated.",
  "Use UNRESOLVED only if substantive geography is genuinely present but still cannot be mapped or reconciled defensibly from the supplied text.",
  "Do not use deterministic geography or outside knowledge as evidence.",
  sep="\n"
)
prompt <- paste0(base_prompt,rescue_instruction)

schema <- list(
  type="object",
  properties=list(
    geography_status=list(type="string",enum=c("RESOLVED","NONE","UNRESOLVED")),
    locations=list(type="array",items=list(
      type="object",
      properties=list(
        iso3c=list(type="string",pattern="^[A-Z]{3}$"),
        country_name=list(type="string",minLength=2),
        evidence=list(type="string",minLength=2),
        mapping_reason=list(type="string",minLength=2)
      ),
      required=c("iso3c","country_name","evidence","mapping_reason"),
      additionalProperties=FALSE
    )),
    geography_reason=list(type="string",minLength=2)
  ),
  required=c("geography_status","locations","geography_reason"),
  additionalProperties=FALSE
)

extract_text <- function(z){
  for(o in z$output) if(!is.null(o$content)) for(cc in o$content)
    if(identical(cc$type,"output_text")) return(cc$text)
  stop("No output_text returned",call.=FALSE)
}

call_one <- function(row,pass){
  user <- paste(
    "RECORD ID:",row$record_id,
    "RESCUE PASS:",pass,
    "PREVIOUS UNRESOLVED REASON:",ifelse(is.na(row$geography_reason),"",row$geography_reason),
    "",
    "TITLE:",ifelse(is.na(row$title),"",row$title),
    "",
    "ABSTRACT:",ifelse(is.na(row$abstract),"",row$abstract),
    sep="\n"
  )
  body <- list(
    model="gpt-5.6-luna",
    store=FALSE,
    reasoning=list(effort="low"),
    input=list(
      list(role="system",content=list(list(type="input_text",text=prompt))),
      list(role="user",content=list(list(type="input_text",text=user)))
    ),
    text=list(
      verbosity="low",
      format=list(type="json_schema",name="workflow06_unresolved_rescue",strict=TRUE,schema=schema)
    )
  )
  z <- request("https://api.openai.com/v1/responses") |>
    req_auth_bearer_token(Sys.getenv("OPENAI_API_KEY")) |>
    req_body_json(body,auto_unbox=TRUE) |>
    req_timeout(120) |>
    req_retry(max_tries=5) |>
    req_perform() |>
    resp_body_json(simplifyVector=FALSE)

  a <- fromJSON(extract_text(z),simplifyVector=FALSE)
  locs <- a$locations
  if(is.null(locs)) locs <- list()
  if(a$geography_status=="NONE" && length(locs)>0L) stop("NONE returned with locations")
  if(a$geography_status=="RESOLVED" && length(locs)==0L) stop("RESOLVED returned without locations")
  iso <- if(length(locs)) vapply(locs,function(q)as.character(q$iso3c),character(1)) else character()
  cn <- if(length(locs)) vapply(locs,function(q)as.character(q$country_name),character(1)) else character()
  ev <- if(length(locs)) vapply(locs,function(q)as.character(q$evidence),character(1)) else character()
  mp <- if(length(locs)) vapply(locs,function(q)as.character(q$mapping_reason),character(1)) else character()
  pseudo <- toupper(iso) %in% c("ZZZ","XXX") | grepl("global|multiple countries|worldwide",cn,ignore.case=TRUE)
  if(any(pseudo)) stop("Pseudo-country not allowed")
  grounded <- if(length(ev)) vapply(ev,evidence_is_grounded,logical(1),title=row$title,abstract=row$abstract) else logical()
  if(a$geography_status=="RESOLVED" && !all(grounded)) stop("RESOLVED evidence failed grounding")
  list(
    pass=pass,
    status=as.character(a$geography_status),
    iso3c=norm_set(iso),
    country_names=norm_set(cn),
    evidence=paste(ev,collapse=" || "),
    mapping_reason=paste(mp,collapse=" || "),
    geography_reason=as.character(a$geography_reason),
    evidence_all_grounded=if(length(grounded))all(grounded) else TRUE,
    failed=FALSE,
    error="",
    response_id=if(is.null(z$id))"" else as.character(z$id)
  )
}

safe_call <- function(row,pass){
  tryCatch(call_one(row,pass),error=function(e)list(
    pass=pass,status="UNRESOLVED",iso3c="",country_names="",evidence="",mapping_reason="",
    geography_reason="",evidence_all_grounded=FALSE,failed=TRUE,error=conditionMessage(e),response_id=""
  ))
}
decision_key <- function(z) paste(z$status,z$iso3c,sep="|")

rows <- vector("list",nrow(u))
raw_path <- file.path(out_dir,"workflow06_unresolved_rescue_passes.jsonl")
if(file.exists(raw_path)) file.remove(raw_path)

for(i in seq_len(nrow(u))){
  row <- u[i,,drop=FALSE]
  a <- safe_call(row,"A")
  b <- safe_call(row,"B")
  need_c <- a$failed || b$failed || a$status=="UNRESOLVED" || b$status=="UNRESOLVED" || !identical(decision_key(a),decision_key(b))
  c <- if(need_c) safe_call(row,"C") else NULL
  passes <- Filter(Negate(is.null),list(a,b,c))
  keys <- vapply(passes,decision_key,character(1))
  tab <- sort(table(keys),decreasing=TRUE)
  winner <- if(length(tab)&&tab[[1]]>=2L) names(tab)[[1]] else ""
  chosen <- NULL
  if(nzchar(winner)){
    cand <- passes[keys==winner]
    # Prefer the first non-failed pass supporting the majority decision.
    good <- Filter(function(z)!isTRUE(z$failed),cand)
    if(length(good)) chosen <- good[[1]]
  }
  if(is.null(chosen)){
    final_status <- "UNRESOLVED"; final_iso <- ""; final_cn <- ""; final_ev <- ""; final_mp <- ""
    final_reason <- "No two rescue passes produced the same valid geography decision."
    consensus <- FALSE
  } else {
    final_status <- chosen$status; final_iso <- chosen$iso3c; final_cn <- chosen$country_names
    final_ev <- chosen$evidence; final_mp <- chosen$mapping_reason; final_reason <- chosen$geography_reason
    consensus <- TRUE
  }

  out <- list(
    record_id=as.character(row$record_id),
    record_sequence=as.integer(row$record_sequence),
    original_geography_status="UNRESOLVED",
    original_geography_reason=ifelse(is.na(row$geography_reason),"",as.character(row$geography_reason)),
    pass_a=a,pass_b=b,pass_c=c,
    third_pass_used=need_c,
    consensus=consensus,
    final_geography_status=final_status,
    final_iso3c=final_iso,
    final_country_names=final_cn,
    final_evidence=final_ev,
    final_mapping_reason=final_mp,
    final_geography_reason=final_reason,
    route_to_workflow08=identical(final_status,"UNRESOLVED")
  )
  cat(toJSON(out,auto_unbox=TRUE,null="null"),"\n",file=raw_path,append=TRUE,sep="")
  rows[[i]] <- tibble(
    record_id=out$record_id,
    record_sequence=out$record_sequence,
    original_geography_reason=out$original_geography_reason,
    pass_a_status=a$status,pass_a_iso3c=a$iso3c,pass_a_failed=a$failed,
    pass_b_status=b$status,pass_b_iso3c=b$iso3c,pass_b_failed=b$failed,
    pass_c_status=if(is.null(c))"" else c$status,
    pass_c_iso3c=if(is.null(c))"" else c$iso3c,
    pass_c_failed=if(is.null(c))FALSE else c$failed,
    third_pass_used=need_c,
    consensus=consensus,
    final_geography_status=final_status,
    final_iso3c=final_iso,
    final_country_names=final_cn,
    final_evidence=final_ev,
    final_mapping_reason=final_mp,
    final_geography_reason=final_reason,
    route_to_workflow08=identical(final_status,"UNRESOLVED")
  )
  if(i==1L || i%%25L==0L || i==nrow(u)){
    message(sprintf("Rescue %d/%d; W08 residual so far=%d.",i,nrow(u),
                    sum(vapply(rows[seq_len(i)],function(z)isTRUE(z$route_to_workflow08[[1]]),logical(1)))))
  }
}

res <- bind_rows(rows)
write_csv(res,file.path(out_dir,"workflow06_unresolved_rescue.csv"),na="")
write_csv(res |> filter(route_to_workflow08),file.path(out_dir,"workflow06_unresolved_residual_w08.csv"),na="")

summary <- list(
  schema="living-evidence-map-workflow06-unresolved-rescue-v1",
  source_workflow06_run="36265092530",
  source_records=19407L,
  unresolved_input=nrow(u),
  two_passes_per_record=TRUE,
  third_pass_rule="run if A/B disagree, either pass is UNRESOLVED, or either pass fails",
  model="gpt-5.6-luna",
  reasoning="low",
  prompt_sha256=prompt_sha,
  resolved_n=sum(res$final_geography_status=="RESOLVED"),
  none_n=sum(res$final_geography_status=="NONE"),
  unresolved_residual_n=sum(res$final_geography_status=="UNRESOLVED"),
  third_pass_used_n=sum(res$third_pass_used),
  records_with_any_failed_pass=sum(res$pass_a_failed|res$pass_b_failed|res$pass_c_failed),
  created_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
write_json(summary,file.path(out_dir,"summary.json"),pretty=TRUE,auto_unbox=TRUE,null="null")
writeLines("PASS",file.path(out_dir,"WORKFLOW06_UNRESOLVED_RESCUE_PASS.ok"))
cat(toJSON(summary,pretty=TRUE,auto_unbox=TRUE),"
")

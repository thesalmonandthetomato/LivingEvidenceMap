#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(jsonlite)
  library(httr2)
  library(digest)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default=NULL){
  i <- match(flag,args)
  if(is.na(i)) return(default)
  if(i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}

records_path <- arg("--records")
det_path <- arg("--deterministic")
prompt_path <- arg("--prompt","config/workflow06_geography_semantic_prompt_v2.txt")
out_dir <- arg("--output-dir")
shard_id <- as.integer(arg("--shard-id"))
shard_count <- as.integer(arg("--shard-count","20"))

if(is.null(records_path)||!file.exists(records_path)) stop("--records is required")
if(is.null(det_path)||!file.exists(det_path)) stop("--deterministic is required")
if(is.null(out_dir)) stop("--output-dir is required")
if(is.na(shard_id)||shard_id<1L||shard_id>shard_count) stop("Invalid --shard-id")
if(!file.exists(prompt_path)) stop("Prompt file not found")
dir.create(out_dir,recursive=TRUE,showWarnings=FALSE)

records <- read_csv(records_path,show_col_types=FALSE)
det <- read_csv(det_path,show_col_types=FALSE)

records_base <- records |>
  select(-any_of(c("deterministic_primary_countries","deterministic_primary_iso3c",
                   "geography_review_required","geography_review_reason")))
x <- records_base |>
  inner_join(
    det |>
      select(record_id, deterministic_primary_countries, deterministic_primary_iso3c,
             geography_review_required, geography_review_reason),
    by="record_id"
  ) |>
  arrange(record_sequence)

if(!nrow(x)) stop("Workflow 06 screening queue is empty; semantic coder should not be invoked",call.=FALSE)
stopifnot(!anyDuplicated(x$record_id),!anyDuplicated(x$record_sequence))
if(!"geography_input_sha256"%in%names(x)){
  x$geography_input_sha256 <- mapply(function(t,a)digest(toJSON(list(title=ifelse(is.na(t),"",t),abstract=ifelse(is.na(a),"",a)),auto_unbox=TRUE,null="null",na="null"),algo="sha256",serialize=FALSE),x$title,x$abstract,USE.NAMES=FALSE)
}
samp <- x |> filter(((record_sequence - 1L) %% shard_count) == (shard_id - 1L))

prompt <- paste(readLines(prompt_path,warn=FALSE,encoding="UTF-8"),collapse="\n")
prompt_sha <- digest(file=prompt_path,algo="sha256",serialize=FALSE)
expected_prompt_sha <- "2ef4a9f2099878ae825395f3f09b329f219bfd3a185d3704a8662c52bcff70ed"
if(!identical(prompt_sha,expected_prompt_sha)) stop("Locked geography prompt SHA mismatch")

schema <- list(
  type="object",
  properties=list(
    geography_status=list(type="string",enum=c("RESOLVED","NONE","UNRESOLVED")),
    locations=list(
      type="array",
      items=list(
        type="object",
        properties=list(
          iso3c=list(type="string",pattern="^[A-Z]{3}$"),
          country_name=list(type="string",minLength=2),
          evidence=list(type="string",minLength=2),
          mapping_reason=list(type="string",minLength=2)
        ),
        required=c("iso3c","country_name","evidence","mapping_reason"),
        additionalProperties=FALSE
      )
    ),
    geography_reason=list(type="string",minLength=2)
  ),
  required=c("geography_status","locations","geography_reason"),
  additionalProperties=FALSE
)

extract_text <- function(z){
  for(o in z$output){
    if(!is.null(o$content)){
      for(c in o$content){
        if(identical(c$type,"output_text")) return(c$text)
      }
    }
  }
  stop("No output_text returned")
}
norm_ws <- function(z){
  z <- as.character(z); z[is.na(z)] <- ""
  trimws(gsub("[[:space:]]+"," ",z,perl=TRUE))
}
norm_set <- function(z){
  z <- as.character(z)
  z <- z[!is.na(z) & nzchar(trimws(z))]
  if(!length(z)) return("")
  paste(sort(unique(trimws(z))),collapse="; ")
}
norm_semicolon <- function(x){
  x <- as.character(x); x[is.na(x)] <- ""
  vapply(strsplit(x,";",fixed=TRUE),norm_set,character(1))
}
normalise_grounding_text <- function(z){
  z <- as.character(z); z[is.na(z)] <- ""
  z <- gsub("\\\\n|\\\\r|\\\\t", " ", z, perl=TRUE)
  z <- gsub("&nbsp;|&#160;|&#xA0;", " ", z, ignore.case=TRUE, perl=TRUE)
  z <- gsub("&amp;", "&", z, ignore.case=TRUE, fixed=FALSE)
  z <- gsub("<[^>]+>", " ", z, perl=TRUE)
  z <- gsub("[\u00AD\u200B\uFEFF]", "", z, perl=TRUE)
  z <- gsub("[\u2018\u2019]", "'", z, perl=TRUE)
  z <- gsub("[\u201C\u201D]", "\\\"", z, perl=TRUE)
  z <- gsub("[\u2010\u2011\u2012\u2013\u2014]", "-", z, perl=TRUE)
  z <- gsub("[[:punct:]]+", " ", z, perl=TRUE)
  tolower(norm_ws(z))
}

evidence_is_grounded <- function(evidence,title,abstract){
  e_raw <- as.character(evidence)
  if(is.na(e_raw) || !nzchar(trimws(e_raw))) return(FALSE)
  txt <- normalise_grounding_text(paste(title,abstract,sep=" "))
  e <- normalise_grounding_text(e_raw)

  # Preferred rule: the evidence is a contiguous source substring after
  # harmless Unicode/whitespace/markup normalisation.
  if(grepl(e,txt,fixed=TRUE)) return(TRUE)

  # Also tolerate compressed quotations where the evidence words occur
  # in the source in the same order but intervening source words were omitted.
  evidence_tokens <- strsplit(e, " ", fixed=TRUE)[[1L]]
  source_tokens <- strsplit(txt, " ", fixed=TRUE)[[1L]]
  evidence_tokens <- evidence_tokens[nzchar(evidence_tokens)]
  if(length(evidence_tokens) >= 4L){
    j <- 1L
    for(tok in source_tokens){
      if(j <= length(evidence_tokens) && identical(tok, evidence_tokens[[j]])) j <- j + 1L
    }
    if(j > length(evidence_tokens)) return(TRUE)
  }

  # Tolerate model-inserted ellipses only when every non-trivial quoted
  # fragment is found in the source in the same order. This preserves
  # source grounding while relaxing the formatting requirement.
  raw <- gsub("\u2026", "...", e_raw, fixed=TRUE)
  if(!grepl("...", raw, fixed=TRUE)) return(FALSE)
  parts <- strsplit(raw, "...", fixed=TRUE)[[1L]]
  parts <- vapply(parts, normalise_grounding_text, character(1))
  parts <- trimws(gsub("^[. ]+|[. ]+$", "", parts, perl=TRUE))
  parts <- parts[nzchar(parts) & nchar(parts) >= 4L]
  if(length(parts) < 2L) return(FALSE)

  pos <- 1L
  for(part in parts){
    remainder <- substr(txt,pos,nchar(txt))
    hit <- regexpr(part,remainder,fixed=TRUE)[[1L]]
    if(hit < 1L) return(FALSE)
    pos <- pos + hit - 1L + nchar(part)
  }
  TRUE
}

call_one <- function(row){
  user <- paste(
    "RECORD ID:",row$record_id,"",
    "TITLE:",ifelse(is.na(row$title),"",row$title),"",
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
      format=list(type="json_schema",name="substantive_geography",strict=TRUE,schema=schema)
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
  iso <- if(length(locs)) vapply(locs,function(q) as.character(q$iso3c),character(1)) else character()
  names <- if(length(locs)) vapply(locs,function(q) as.character(q$country_name),character(1)) else character()
  evidence <- if(length(locs)) vapply(locs,function(q) as.character(q$evidence),character(1)) else character()
  mapping <- if(length(locs)) vapply(locs,function(q) as.character(q$mapping_reason),character(1)) else character()
  grounded <- if(length(locs)) vapply(evidence,evidence_is_grounded,logical(1),title=row$title,abstract=row$abstract) else logical()

  if(a$geography_status=="NONE" && length(locs)>0L) stop("NONE returned with non-empty locations")
  if(a$geography_status=="RESOLVED" && length(locs)==0L) stop("RESOLVED returned with no locations")

  list(
    record_id=as.character(row$record_id),
    record_sequence=as.integer(row$record_sequence),
    geography_input_sha256=as.character(row$geography_input_sha256),
    geography_status=as.character(a$geography_status),
    locations=locs,
    geography_reason=as.character(a$geography_reason),
    evidence_all_grounded=if(length(grounded)) all(grounded) else TRUE,
    llm_failed=FALSE,
    llm_error=NA_character_,
    luna_iso3c=norm_set(iso),
    luna_country_names=norm_set(names),
    luna_evidence=paste(evidence,collapse=" || "),
    luna_mapping_reason=paste(mapping,collapse=" || ")
  )
}

jsonl_path <- file.path(out_dir,"geography_results.jsonl")
if(file.exists(jsonl_path)) file.remove(jsonl_path)
rows <- vector("list",nrow(samp))
message(sprintf("Production geography shard %d/%d: %d records.",shard_id,shard_count,nrow(samp)))

if(!nrow(samp)){
  empty <- x[0,] |>
    transmute(
      record_id=as.character(record_id),record_sequence=as.integer(record_sequence),
      title=as.character(title),abstract=as.character(abstract),geography_input_sha256=as.character(geography_input_sha256),
      deterministic_primary_countries=as.character(deterministic_primary_countries),
      deterministic_primary_iso3c=as.character(deterministic_primary_iso3c),
      geography_review_required=as.logical(geography_review_required),
      geography_review_reason=as.character(geography_review_reason),
      geography_status=character(),luna_iso3c=character(),luna_country_names=character(),
      luna_evidence=character(),luna_mapping_reason=character(),evidence_all_grounded=logical(),
      geography_reason=character(),llm_failed=logical(),llm_error=character(),
      det_iso3c=character(),exact_agreement=logical(),deterministic_none=logical(),luna_none=logical(),discrepancy_type=character()
    )
  write_csv(empty,file.path(out_dir,"geography_results.csv"),na="")
  write_csv(empty,file.path(out_dir,"geography_qc_flags.csv"),na="")
  file.create(jsonl_path)
  summary<-list(shard_id=shard_id,shard_count=shard_count,n=0L,model="gpt-5.6-luna",reasoning="low",prompt_sha256=prompt_sha,
                resolved_n=0L,none_n=0L,unresolved_n=0L,evidence_ungrounded_n=0L,llm_failures_n=0L,deterministic_exact_agreement_n=0L)
  writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),file.path(out_dir,"summary.json"))
  cat(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),"\n")
  quit(save="no",status=0L)
}

for(i in seq_len(nrow(samp))){
  row <- samp[i,,drop=FALSE]
  ans <- tryCatch(
    call_one(row),
    error=function(e) list(
      record_id=as.character(row$record_id),
      record_sequence=as.integer(row$record_sequence),
      geography_input_sha256=as.character(row$geography_input_sha256),
      geography_status="UNRESOLVED",
      locations=list(),
      geography_reason="",
      evidence_all_grounded=FALSE,
      llm_failed=TRUE,
      llm_error=conditionMessage(e),
      luna_iso3c="",
      luna_country_names="",
      luna_evidence="",
      luna_mapping_reason=""
    )
  )
  cat(toJSON(ans,auto_unbox=TRUE,null="null"),"\n",file=jsonl_path,append=TRUE,sep="")
  rows[[i]] <- tibble(
    record_id=ans$record_id,
    record_sequence=ans$record_sequence,
    geography_input_sha256=ans$geography_input_sha256,
    geography_status=ans$geography_status,
    luna_iso3c=ans$luna_iso3c,
    luna_country_names=ans$luna_country_names,
    luna_evidence=ans$luna_evidence,
    luna_mapping_reason=ans$luna_mapping_reason,
    evidence_all_grounded=ans$evidence_all_grounded,
    geography_reason=ans$geography_reason,
    llm_failed=ans$llm_failed,
    llm_error=ifelse(is.na(ans$llm_error),"",ans$llm_error)
  )
  if(i==1L || i%%25L==0L || i==nrow(samp)){
    message(sprintf("Shard %d: %d/%d; failures=%d.",shard_id,i,nrow(samp),
      sum(vapply(rows[seq_len(i)],function(z) isTRUE(z$llm_failed[[1]]),logical(1)))))
  }
}

llm <- bind_rows(rows)
cmp <- samp |>
  select(record_id,record_sequence,title,abstract,geography_input_sha256,deterministic_primary_countries,
         deterministic_primary_iso3c,geography_review_required,geography_review_reason) |>
  left_join(llm,by=c("record_id","record_sequence")) |>
  mutate(
    det_iso3c=norm_semicolon(deterministic_primary_iso3c),
    luna_iso3c=norm_semicolon(luna_iso3c),
    exact_agreement=det_iso3c==luna_iso3c,
    deterministic_none=!nzchar(det_iso3c),
    luna_none=geography_status=="NONE",
    discrepancy_type=case_when(
      llm_failed ~ "llm_failure",
      !evidence_all_grounded ~ "ungrounded_evidence",
      exact_agreement ~ "exact_agreement",
      deterministic_none & geography_status=="RESOLVED" ~ "luna_only_geography",
      !deterministic_none & luna_none ~ "deterministic_only_geography",
      TRUE ~ "different_country_set"
    )
  )

write_csv(cmp,file.path(out_dir,"geography_results.csv"),na="")
write_csv(cmp |> filter(discrepancy_type!="exact_agreement"),file.path(out_dir,"geography_qc_flags.csv"),na="")

summary <- list(
  shard_id=shard_id,
  shard_count=shard_count,
  n=nrow(cmp),
  first_record_sequence=min(cmp$record_sequence),
  last_record_sequence=max(cmp$record_sequence),
  model="gpt-5.6-luna",
  reasoning="low",
  prompt_sha256=prompt_sha,
  resolved_n=sum(cmp$geography_status=="RESOLVED"),
  none_n=sum(cmp$geography_status=="NONE"),
  unresolved_n=sum(cmp$geography_status=="UNRESOLVED"),
  evidence_ungrounded_n=sum(!cmp$evidence_all_grounded),
  llm_failures_n=sum(cmp$llm_failed),
  deterministic_exact_agreement_n=sum(cmp$exact_agreement)
)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),file.path(out_dir,"summary.json"))
cat(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),"\n")

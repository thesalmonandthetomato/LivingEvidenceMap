#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
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

input <- arg("--input")
prompt_path <- arg("--prompt","config/workflow05_geography_semantic_prompt.txt")
out_dir <- arg("--output-dir","outputs/workflow06_failure_recovery")
if(is.null(input)||!file.exists(input)) stop("--input is required",call.=FALSE)
if(!file.exists(prompt_path)) stop("Prompt file not found",call.=FALSE)
dir.create(out_dir,recursive=TRUE,showWarnings=FALSE)

x <- read_csv(input,show_col_types=FALSE) |>
  filter(llm_failed) |>
  arrange(record_sequence)

expected_ids <- c(
  "work-60e645a39d981a54",
  "work-a933887a625b37d8",
  "work-e8046bb0876a1942",
  "work-f026296875ea14e0"
)
stopifnot(
  nrow(x)==4L,
  !anyDuplicated(x$record_id),
  setequal(x$record_id,expected_ids)
)

prompt_sha <- digest(file=prompt_path,algo="sha256",serialize=FALSE)
expected_prompt_sha <- "ce20acddf42e494a799d08b130d3e1bace95746035a7ad8e625fc8046a1bd07a"
if(!identical(prompt_sha,expected_prompt_sha)) stop("Locked geography prompt SHA mismatch",call.=FALSE)
prompt <- paste(readLines(prompt_path,warn=FALSE,encoding="UTF-8"),collapse="\n")

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
  stop("No output_text returned",call.=FALSE)
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
evidence_is_grounded <- function(evidence,title,abstract){
  e <- tolower(norm_ws(evidence))
  if(!nzchar(e)) return(FALSE)
  txt <- tolower(norm_ws(paste(title,abstract,sep=" ")))
  grepl(e,txt,fixed=TRUE)
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
  if(a$geography_status=="NONE" && length(locs)>0L) stop("NONE returned with non-empty locations",call.=FALSE)
  if(a$geography_status=="RESOLVED" && length(locs)==0L) stop("RESOLVED returned with no locations",call.=FALSE)

  iso <- if(length(locs)) vapply(locs,function(q) as.character(q$iso3c),character(1)) else character()
  names <- if(length(locs)) vapply(locs,function(q) as.character(q$country_name),character(1)) else character()
  evidence <- if(length(locs)) vapply(locs,function(q) as.character(q$evidence),character(1)) else character()
  mapping <- if(length(locs)) vapply(locs,function(q) as.character(q$mapping_reason),character(1)) else character()
  grounded <- if(length(locs)) vapply(evidence,evidence_is_grounded,logical(1),title=row$title,abstract=row$abstract) else logical()

  list(
    record_id=as.character(row$record_id),
    record_sequence=as.integer(row$record_sequence),
    geography_status=as.character(a$geography_status),
    luna_iso3c=norm_set(iso),
    luna_country_names=norm_set(names),
    luna_evidence=paste(evidence,collapse=" || "),
    luna_mapping_reason=paste(mapping,collapse=" || "),
    evidence_all_grounded=if(length(grounded)) all(grounded) else TRUE,
    geography_reason=as.character(a$geography_reason),
    llm_failed=FALSE,
    llm_error="",
    response_id=if(is.null(z$id)) "" else as.character(z$id),
    model_returned=if(is.null(z$model)) "" else as.character(z$model)
  )
}

rows <- vector("list",nrow(x))
raw_path <- file.path(out_dir,"workflow06_failure_recovery.jsonl")
if(file.exists(raw_path)) file.remove(raw_path)

for(i in seq_len(nrow(x))){
  row <- x[i,,drop=FALSE]
  ans <- tryCatch(
    call_one(row),
    error=function(e) list(
      record_id=as.character(row$record_id),
      record_sequence=as.integer(row$record_sequence),
      geography_status="UNRESOLVED",
      luna_iso3c="",
      luna_country_names="",
      luna_evidence="",
      luna_mapping_reason="",
      evidence_all_grounded=FALSE,
      geography_reason="",
      llm_failed=TRUE,
      llm_error=conditionMessage(e),
      response_id="",
      model_returned=""
    )
  )
  cat(toJSON(ans,auto_unbox=TRUE,null="null"),"\n",file=raw_path,append=TRUE,sep="")
  rows[[i]] <- as.data.frame(ans,stringsAsFactors=FALSE)
}

out <- bind_rows(rows)
write_csv(out,file.path(out_dir,"workflow06_failure_recovery.csv"),na="")
summary <- list(
  source_workflow06_run="36265092530",
  records=nrow(out),
  recovered_n=sum(!out$llm_failed),
  still_failed_n=sum(out$llm_failed),
  resolved_n=sum(out$geography_status=="RESOLVED"),
  none_n=sum(out$geography_status=="NONE"),
  unresolved_n=sum(out$geography_status=="UNRESOLVED"),
  evidence_not_grounded_n=sum(!out$evidence_all_grounded),
  model="gpt-5.6-luna",
  reasoning="low",
  prompt_sha256=prompt_sha
)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),file.path(out_dir,"summary.json"))
cat(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),"\n")

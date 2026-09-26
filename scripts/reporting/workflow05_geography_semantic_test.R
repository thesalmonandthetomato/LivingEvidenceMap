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
prompt_path <- arg("--prompt","config/workflow05_geography_semantic_prompt.txt")
out_dir <- arg("--output-dir","outputs/workflow05_geography_semantic_test")
sample_size <- as.integer(arg("--sample-size","200"))
sample_seed <- as.integer(arg("--sample-seed","20260926"))

dir.create(out_dir,recursive=TRUE,showWarnings=FALSE)
if(is.null(records_path)||!file.exists(records_path)) stop("--records is required")
if(is.null(det_path)||!file.exists(det_path)) stop("--deterministic is required")
if(!file.exists(prompt_path)) stop("Prompt file not found")

records <- read_csv(records_path,show_col_types=FALSE)
det <- read_csv(det_path,show_col_types=FALSE)
x <- records |>
  inner_join(
    det |>
      select(
        record_id,
        deterministic_primary_countries,
        deterministic_primary_iso3c,
        geography_review_required,
        geography_review_reason
      ),
    by="record_id"
  )

stopifnot(nrow(x)==19407L,!anyDuplicated(x$record_id))
set.seed(sample_seed)
samp <- x |> slice_sample(n=sample_size)
stopifnot(nrow(samp)==sample_size,!anyDuplicated(samp$record_id))
write_csv(samp,file.path(out_dir,paste0("sample_",sample_size,".csv")),na="")

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
  stop("No output_text returned")
}

norm_ws <- function(z){
  z <- as.character(z)
  z[is.na(z)] <- ""
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
evidence_is_grounded <- function(evidence,title,abstract){
  e <- tolower(norm_ws(evidence))
  if(!nzchar(e)) return(FALSE)
  txt <- tolower(norm_ws(paste(title,abstract,sep=" ")))
  grepl(e,txt,fixed=TRUE)
}

call_one <- function(row){
  user <- paste(
    "RECORD ID:",row$record_id,
    "",
    "TITLE:",
    ifelse(is.na(row$title),"",row$title),
    "",
    "ABSTRACT:",
    ifelse(is.na(row$abstract),"",row$abstract),
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
      format=list(
        type="json_schema",
        name="substantive_geography",
        strict=TRUE,
        schema=schema
      )
    )
  )

  z <- request("https://api.openai.com/v1/responses") |>
    req_auth_bearer_token(Sys.getenv("OPENAI_API_KEY")) |>
    req_body_json(body,auto_unbox=TRUE) |>
    req_timeout(120) |>
    req_retry(max_tries=4) |>
    req_perform() |>
    resp_body_json(simplifyVector=FALSE)

  a <- fromJSON(extract_text(z),simplifyVector=FALSE)
  locs <- a$locations
  if(is.null(locs)) locs <- list()

  iso <- if(length(locs)) vapply(locs,function(z) as.character(z$iso3c),character(1)) else character()
  names <- if(length(locs)) vapply(locs,function(z) as.character(z$country_name),character(1)) else character()
  evidence <- if(length(locs)) vapply(locs,function(z) as.character(z$evidence),character(1)) else character()
  mapping <- if(length(locs)) vapply(locs,function(z) as.character(z$mapping_reason),character(1)) else character()
  grounded <- if(length(locs)) vapply(evidence,evidence_is_grounded,logical(1),title=row$title,abstract=row$abstract) else logical()

  if(a$geography_status=="NONE" && length(locs)>0L) stop("NONE returned with non-empty locations")
  if(a$geography_status=="RESOLVED" && length(locs)==0L) stop("RESOLVED returned with no locations")

  tibble(
    record_id=row$record_id,
    luna_status=a$geography_status,
    luna_iso3c=norm_set(iso),
    luna_country_names=norm_set(names),
    luna_evidence=paste(evidence,collapse=" || "),
    luna_mapping_reason=paste(mapping,collapse=" || "),
    evidence_all_grounded=if(length(grounded)) all(grounded) else TRUE,
    geography_reason=a$geography_reason,
    llm_failed=FALSE,
    llm_error=NA_character_
  )
}

results <- vector("list",nrow(samp))
message(sprintf("Semantic geography test: %d records.",nrow(samp)))
for(i in seq_len(nrow(samp))){
  row <- samp[i,,drop=FALSE]
  results[[i]] <- tryCatch(
    call_one(row),
    error=function(e) tibble(
      record_id=row$record_id,
      luna_status="UNRESOLVED",
      luna_iso3c="",
      luna_country_names="",
      luna_evidence="",
      luna_mapping_reason="",
      evidence_all_grounded=FALSE,
      geography_reason="",
      llm_failed=TRUE,
      llm_error=conditionMessage(e)
    )
  )
  if(i==1L || i%%10L==0L || i==nrow(samp)){
    message(sprintf("Semantic geography test: %d/%d; failures=%d.",i,nrow(samp),sum(vapply(results[seq_len(i)],function(z) isTRUE(z$llm_failed[[1]]),logical(1)))))
  }
}

llm <- bind_rows(results)
write_csv(llm,file.path(out_dir,"luna_geography.csv"),na="")

cmp <- samp |>
  left_join(llm,by="record_id") |>
  mutate(
    det_iso3c=norm_semicolon(deterministic_primary_iso3c),
    luna_iso3c=norm_semicolon(luna_iso3c),
    exact_agreement=det_iso3c==luna_iso3c,
    deterministic_none=!nzchar(det_iso3c),
    luna_none=luna_status=="NONE",
    deterministic_extra=vapply(seq_len(n()),function(i){
      d <- unlist(strsplit(det_iso3c[[i]],"; ",fixed=TRUE)); d<-d[nzchar(d)]
      l <- unlist(strsplit(luna_iso3c[[i]],"; ",fixed=TRUE)); l<-l[nzchar(l)]
      norm_set(setdiff(d,l))
    },character(1)),
    luna_extra=vapply(seq_len(n()),function(i){
      d <- unlist(strsplit(det_iso3c[[i]],"; ",fixed=TRUE)); d<-d[nzchar(d)]
      l <- unlist(strsplit(luna_iso3c[[i]],"; ",fixed=TRUE)); l<-l[nzchar(l)]
      norm_set(setdiff(l,d))
    },character(1)),
    discrepancy_type=case_when(
      llm_failed ~ "llm_failure",
      !evidence_all_grounded ~ "ungrounded_evidence",
      exact_agreement ~ "exact_agreement",
      deterministic_none & luna_status=="RESOLVED" ~ "luna_only_geography",
      !deterministic_none & luna_none ~ "deterministic_only_geography",
      TRUE ~ "different_country_set"
    )
  )

write_csv(cmp,file.path(out_dir,"comparison_200.csv"),na="")
write_csv(cmp |> filter(discrepancy_type!="exact_agreement"),file.path(out_dir,"discrepancies.csv"),na="")

patterns <- cmp |> count(discrepancy_type,name="n") |> mutate(pct=100*n/nrow(cmp)) |> arrange(desc(n))
write_csv(patterns,file.path(out_dir,"discrepancy_patterns.csv"),na="")

status_counts <- cmp |> count(luna_status,name="n") |> mutate(pct=100*n/nrow(cmp))
write_csv(status_counts,file.path(out_dir,"luna_status_counts.csv"),na="")

summary <- list(
  n=nrow(cmp),
  sample_strategy="simple_random",
  sample_seed=sample_seed,
  model="gpt-5.6-luna",
  reasoning="low",
  prompt_sha256=digest(file=prompt_path,algo="sha256",serialize=FALSE),
  exact_agreement_n=sum(cmp$exact_agreement),
  exact_agreement_pct=100*mean(cmp$exact_agreement),
  discrepancies_n=sum(!cmp$exact_agreement),
  discrepancies_pct=100*mean(!cmp$exact_agreement),
  luna_resolved_n=sum(cmp$luna_status=="RESOLVED"),
  luna_none_n=sum(cmp$luna_status=="NONE"),
  luna_unresolved_n=sum(cmp$luna_status=="UNRESOLVED"),
  deterministic_review_n=sum(cmp$geography_review_required %in% TRUE),
  evidence_ungrounded_n=sum(!cmp$evidence_all_grounded),
  llm_failures_n=sum(cmp$llm_failed)
)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),file.path(out_dir,"summary.json"))

cat(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),"\n")
print(patterns)
print(status_counts)

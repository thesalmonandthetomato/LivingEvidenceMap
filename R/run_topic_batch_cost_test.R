#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(curl)
  library(digest)
  library(httr2)
  library(jsonlite)
  library(readr)
})

api_root <- "https://api.openai.com/v1"
out_dir <- Sys.getenv("COST_TEST_OUTPUT_DIR", "outputs/workflow06_topic_cost_test_100")
queue_path <- file.path(out_dir, "validation_queue_100.csv")
master_path <- "data/master/current/living_evidence_map_master.csv"
benchmark_path <- "/tmp/ranked/topic_consistency_queue.csv"
ontology_path <- Sys.getenv("TOPIC_ONTOLOGY_PATH", "data/reference/topic_ontology_v3_4.csv")
system_prompt_path <- Sys.getenv("TOPIC_SYSTEM_PROMPT_PATH", "/tmp/prior_batch/luna_a/topic_v4_system_prompt.txt")
selection_salt <- Sys.getenv("COST_TEST_SELECTION_SALT", "topic-v3.4-cost-test-100-2026-09|")
sample_size <- as.integer(Sys.getenv("COST_TEST_SAMPLE_SIZE", "100"))
poll_seconds <- as.integer(Sys.getenv("BATCH_POLL_SECONDS", "20"))
max_wait_seconds <- as.integer(Sys.getenv("BATCH_MAX_WAIT_SECONDS", "18000"))
luna_model <- "gpt-5.6-luna"
terra_model <- "gpt-5.6-terra"
prices <- list(
  `gpt-5.6-luna` = list(input = 0.10, cached = 0.01, cache_write = 0.125, output = 0.60),
  `gpt-5.6-terra` = list(input = 1.00, cached = 0.10, cache_write = 1.25, output = 6.00)
)

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x
read_csv_quiet <- function(path) readr::read_csv(path, show_col_types = FALSE, progress = FALSE)
write_csv_safe <- function(x, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  readr::write_csv(x, path, na = "")
}
write_json_file <- function(x, path) jsonlite::write_json(x, path, pretty = TRUE, auto_unbox = TRUE, null = "null")
sha256_file <- function(path) digest::digest(file = path, algo = "sha256", serialize = FALSE)

api_request <- function(method, route, body = NULL, raw = FALSE) {
  key <- Sys.getenv("OPENAI_API_KEY")
  if (!nzchar(key)) stop("OPENAI_API_KEY is required")
  req <- request(paste0(api_root, route)) |>
    req_method(method) |>
    req_auth_bearer_token(key) |>
    req_retry(max_tries = 5, retry_on_failure = TRUE) |>
    req_timeout(300)
  if (!is.null(body)) req <- req |> req_body_json(body, auto_unbox = TRUE, null = "null")
  resp <- req_perform(req)
  if (raw) return(resp_body_raw(resp))
  resp_body_json(resp, simplifyVector = FALSE)
}

upload_batch_file <- function(path) {
  key <- Sys.getenv("OPENAI_API_KEY")
  request(paste0(api_root, "/files")) |>
    req_auth_bearer_token(key) |>
    req_body_multipart(purpose = "batch", file = curl::form_file(path, type = "application/jsonl")) |>
    req_retry(max_tries = 5, retry_on_failure = TRUE) |>
    req_timeout(300) |>
    req_perform() |>
    resp_body_json(simplifyVector = FALSE)
}

submit_and_wait <- function(jsonl_path, label) {
  uploaded <- upload_batch_file(jsonl_path)
  batch <- api_request("POST", "/batches", list(
    input_file_id = uploaded$id, endpoint = "/v1/responses", completion_window = "24h",
    metadata = list(description = label)
  ))
  started <- Sys.time()
  terminal <- c("completed", "failed", "expired", "cancelled")
  while (!(batch$status %in% terminal)) {
    if (as.numeric(difftime(Sys.time(), started, units = "secs")) > max_wait_seconds) {
      stop(sprintf("Batch %s did not finish within %s seconds", batch$id, max_wait_seconds))
    }
    Sys.sleep(poll_seconds)
    batch <- api_request("GET", paste0("/batches/", batch$id))
    message(label, ": ", batch$status)
  }
  if (batch$status != "completed") stop("Batch ", batch$id, " ended with status ", batch$status)
  bytes <- api_request("GET", paste0("/files/", batch$output_file_id, "/content"), raw = TRUE)
  output_path <- file.path(out_dir, paste0(label, "_output.jsonl"))
  writeBin(bytes, output_path)
  write_json_file(batch, file.path(out_dir, paste0(label, "_batch.json")))
  lines <- readLines(output_path, warn = FALSE, encoding = "UTF-8")
  lapply(lines[nzchar(lines)], jsonlite::fromJSON, simplifyVector = FALSE)
}

ontology_prompt <- function(x) {
  fields <- c(definition = "Definition", include_when = "Include when", exclude_when = "Exclude when",
              required_subject_terms = "Subject concept cues", required_focus_terms = "Focus concept cues",
              alternative_standalone_cues = "Alternative specific cues",
              supporting_terms_from_old_ontology = "Supporting lexical cues", prompt_logic_note = "Interpretation note")
  vapply(seq_len(nrow(x)), function(i) {
    lines <- paste(x$path_id[i], x$hierarchy_path[i], sep = " | ")
    for (field in names(fields)) {
      value <- trimws(as.character(x[[field]][i] %||% ""))
      if (!is.na(value) && nzchar(value)) lines <- c(lines, paste0(fields[[field]], ": ", value))
    }
    paste(lines, collapse = "\n")
  }, character(1)) |> paste(collapse = "\n\n")
}

topic_schema <- function(path_ids) list(
  type = "object", properties = list(
    assignments = list(type = "array", items = list(type = "object", properties = list(
      path_id = list(type = "string", enum = as.list(path_ids)), role = list(type = "string", enum = list("PRIMARY", "SECONDARY")),
      reason = list(type = "string")), required = list("path_id", "role", "reason"), additionalProperties = FALSE)),
    review_required = list(type = "boolean"), review_reason = list(type = list("string", "null"))),
  required = list("assignments", "review_required", "review_reason"), additionalProperties = FALSE)

extract_output_text <- function(response) {
  for (item in response$output) if (identical(item$type, "message")) {
    for (content in item$content) if (identical(content$type, "output_text")) return(content$text)
  }
  stop("No output_text returned")
}

usage_row <- function(stage, custom_id, model, response) {
  u <- response$usage %||% list(); d <- u$input_tokens_details %||% list(); od <- u$output_tokens_details %||% list()
  input <- as.integer(u$input_tokens %||% 0); cached <- as.integer(d$cached_tokens %||% 0)
  cache_write <- as.integer(d$cache_write_tokens %||% 0); output <- as.integer(u$output_tokens %||% 0)
  ordinary <- input - cached - cache_write; p <- prices[[model]]
  cost <- (ordinary*p$input + cached*p$cached + cache_write*p$cache_write + output*p$output)/1e6
  data.frame(stage, custom_id, model, input_tokens=input, ordinary_input_tokens=ordinary,
             cached_input_tokens=cached, cache_write_tokens=cache_write, output_tokens=output,
             reasoning_tokens=as.integer(od$reasoning_tokens %||% 0), total_tokens=as.integer(u$total_tokens %||% input+output),
             estimated_batch_cost_usd=cost)
}

build_queue <- function() {
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  source <- read_csv_quiet(master_path); benchmark <- read_csv_quiet(benchmark_path)
  benchmark_ids <- unique(as.character(benchmark$record_id))
  if (length(benchmark_ids) != 50) stop("Expected 50 benchmark exclusions, found ", length(benchmark_ids))
  extra_paths <- strsplit(Sys.getenv("COST_TEST_ADDITIONAL_EXCLUSIONS", ""), .Platform$path.sep, fixed=TRUE)[[1]]
  extra_paths <- extra_paths[nzchar(extra_paths)]; extra_ids <- character(); exclusion_sources <- list()
  for (path in extra_paths) {
    ids <- unique(as.character(read_csv_quiet(path)$record_id))
    if (length(intersect(ids, c(benchmark_ids, extra_ids)))) stop("Overlapping exclusion source: ", path)
    extra_ids <- c(extra_ids, ids); exclusion_sources[[length(exclusion_sources)+1]] <- list(path=path, records=length(ids))
  }
  excluded <- unique(c(benchmark_ids, extra_ids))
  candidates <- source[nzchar(source$record_id) & !(source$record_id %in% excluded) & nzchar(source$title) & nzchar(source$abstract), ]
  keys <- vapply(as.character(candidates$record_id), function(id) digest(paste0(selection_salt,id), algo="sha256", serialize=FALSE), character(1))
  candidates <- candidates[order(keys, candidates$record_id), ]
  selected <- candidates[seq_len(min(sample_size, nrow(candidates))), ]
  if (nrow(selected) != sample_size) stop("Expected ", sample_size, " selected records, found ", nrow(selected))
  queue <- selected[, c("record_id", "title", "abstract")]
  write_csv_safe(queue, queue_path)
  write_csv_safe(data.frame(record_id=selected$record_id, historical_pathways_not_gold=selected$topic_path_ids), file.path(out_dir,"historical_context_not_gold.csv"))
  manifest <- list(source=master_path, source_sha256=sha256_file(master_path), source_records=nrow(source),
    excluded_original_benchmark_records=length(benchmark_ids), additional_exclusion_sources=exclusion_sources,
    excluded_additional_records=length(extra_ids), excluded_total_unique_records=length(excluded), eligible_records=nrow(candidates),
    selected_records=nrow(selected), selection_salt=selection_salt,
    selection=paste("First",sample_size,"after ascending SHA-256 of selection_salt plus record_id"),
    selected_record_ids=as.list(as.character(selected$record_id)), queue_sha256=sha256_file(queue_path), ontology=ontology_path,
    models=list(passes=luna_model, adjudicator=terra_model), reasoning_effort="medium", processing="Batch API", manual_gold_available=FALSE)
  write_json_file(manifest, file.path(out_dir,"selection_manifest.json")); print(manifest)
}

write_jsonl <- function(items, path) {
  con <- file(path, open="wt", encoding="UTF-8"); on.exit(close(con))
  for (x in items) writeLines(toJSON(x, auto_unbox=TRUE, null="null", digits=NA), con)
}

run_luna <- function() {
  records <- read_csv_quiet(queue_path); ontology <- read_csv_quiet(ontology_path)
  prefix <- paste0(paste(readLines(system_prompt_path, warn=FALSE),collapse="\n"),"\n\nONTOLOGY\n\n",ontology_prompt(ontology))
  schema <- topic_schema(as.character(ontology$path_id)); requests <- list()
  for (pass in c("a","b")) for (i in seq_len(nrow(records))) {
    r <- records[i,]; body <- list(model=luna_model, store=FALSE, reasoning=list(effort="medium"),
      prompt_cache_key="topic-v3.4-cost-test-luna", prompt_cache_options=list(mode="explicit",ttl="30m"),
      input=list(list(role="system",content=list(list(type="input_text",text=prefix,prompt_cache_breakpoint=list(mode="explicit")))),
                 list(role="user",content=list(list(type="input_text",text=paste0("RECORD\n\nTitle: ",r$title,"\n\nAbstract: ",r$abstract,"\n\nReturn the substantive ontology assignments."))))),
      text=list(verbosity="low",format=list(type="json_schema",name="topic_v4",strict=TRUE,schema=schema)))
    requests[[length(requests)+1]] <- list(custom_id=paste0("luna-",pass,"-",r$record_id),method="POST",url="/v1/responses",body=body)
  }
  input_path <- file.path(out_dir,"luna_batch_input.jsonl"); write_jsonl(requests,input_path)
  results <- submit_and_wait(input_path,"luna"); pass_rows <- list(a=list(),b=list()); usage <- list()
  for (item in results) {
    bits <- strsplit(item$custom_id,"-",fixed=TRUE)[[1]]; pass <- bits[2]; rid <- paste(bits[-c(1,2)],collapse="-")
    response <- item$response$body %||% NULL; if (is.null(response) || !is.null(item$error)) stop("Luna batch failure: ",item$custom_id)
    usage[[length(usage)+1]] <- usage_row("luna",item$custom_id,luna_model,response)
    parsed <- fromJSON(extract_output_text(response),simplifyVector=FALSE)
    seen <- character(); assignments <- list()
    for (a in parsed$assignments) if (a$path_id %in% ontology$path_id && !(a$path_id %in% seen)) { seen<-c(seen,a$path_id); assignments[[length(assignments)+1]]<-a }
    pass_rows[[pass]][[length(pass_rows[[pass]])+1]] <- list(record_id=rid,parsed=parsed,assignments=assignments)
  }
  for (pass in c("a","b")) {
    long <- list(); recs <- list()
    for (x in pass_rows[[pass]]) {
      src <- records[records$record_id==x$record_id,]
      for (a in x$assignments) long[[length(long)+1]] <- data.frame(record_id=x$record_id,title=src$title,abstract=src$abstract,path_id=a$path_id,role=a$role,reason=a$reason,hierarchy_path=ontology$hierarchy_path[match(a$path_id,ontology$path_id)])
      recs[[length(recs)+1]] <- data.frame(record_id=x$record_id,title=src$title,abstract=src$abstract,
        assigned_path_ids=paste(vapply(x$assignments,`[[`,"", "path_id"),collapse="; "),
        assigned_path_roles=paste(vapply(x$assignments,function(a) paste0(a$path_id,"=",a$role),""),collapse="; "),assignment_count=length(x$assignments),
        review_required=x$parsed$review_required,review_reason=x$parsed$review_reason %||% "",status="completed",classification_error="")
    }
    od <- file.path(out_dir,paste0("luna_",pass)); dir.create(od,recursive=TRUE,showWarnings=FALSE)
    write_csv_safe(do.call(rbind,long),file.path(od,"topic_assignments.csv")); write_csv_safe(do.call(rbind,recs),file.path(od,"topic_classification_records.csv"))
    write_csv_safe(data.frame(record_id=character(),classification_error=character()),file.path(od,"topic_classification_failures.csv"))
  }
  write_csv_safe(do.call(rbind,usage),file.path(out_dir,"luna_usage.csv")); message("Completed two Luna passes for ",nrow(records)," records")
}

split_paths <- function(x) {
  if (length(x) == 0L || all(is.na(x))) return(character())
  x <- as.character(x[[1]])
  if (is.na(x) || !nzchar(x)) return(character())
  y <- trimws(strsplit(x, ";", fixed = TRUE)[[1]])
  y[nzchar(y)]
}
evaluate_luna <- function() {
  records<-read_csv_quiet(queue_path); hist<-read_csv_quiet(file.path(out_dir,"historical_context_not_gold.csv")); maps<-list(); reasons<-list()
  for(pass in c("a","b")){
    x<-read_csv_quiet(file.path(out_dir,paste0("luna_",pass),"topic_assignments.csv"))
    by_record<-split(x, as.character(x$record_id))
    maps[[pass]]<-lapply(by_record, function(df) setNames(as.character(df$role), as.character(df$path_id)))
    reasons[[pass]]<-lapply(by_record, function(df) setNames(as.character(df$reason), as.character(df$path_id)))
  }
  canonical_roles <- function(x) {
    if (length(x) == 0L) return(character())
    n <- names(x)
    if (is.null(n) || length(n) == 0L) return(as.character(x))
    x[order(n)]
  }
  rows<-list(); exact<-full<-tp<-fp<-fn<-0; jac<-numeric()
  for(i in seq_len(nrow(records))){ rid<-as.character(records$record_id[i]); a<-maps$a[[rid]] %||% character(); b<-maps$b[[rid]] %||% character(); as<-names(a) %||% character(); bs<-names(b) %||% character()
    exact<-exact+setequal(as,bs); full<-full+identical(canonical_roles(a),canonical_roles(b)); tp<-tp+length(intersect(as,bs)); fp<-fp+length(setdiff(bs,as)); fn<-fn+length(setdiff(as,bs)); jac<-c(jac,if(length(union(as,bs)))length(intersect(as,bs))/length(union(as,bs)) else 1)
    role_dis<-intersect(as,bs); role_dis<-role_dis[a[role_dis]!=b[role_dis]]
    rows[[i]]<-data.frame(record_id=rid,title=records$title[i],abstract=records$abstract[i],historical_pathways_not_gold=paste(sort(split_paths(hist$historical_pathways_not_gold[hist$record_id==rid])),collapse="; "),
      luna_a_coding=paste(paste0(sort(as),"=",a[sort(as)]),collapse="; "),luna_b_coding=paste(paste0(sort(bs),"=",b[sort(bs)]),collapse="; "),a_b_pathway_exact=as.integer(setequal(as,bs)),
      a_only=paste(sort(setdiff(as,bs)),collapse="; "),b_only=paste(sort(setdiff(bs,as)),collapse="; "),role_disagreements=paste(paste0(role_dis,":",a[role_dis],"->",b[role_dis]),collapse="; "),
      luna_a_reasons=paste(paste0(sort(as),": ",reasons$a[[rid]][sort(as)]),collapse=" | "),luna_b_reasons=paste(paste0(sort(bs),": ",reasons$b[[rid]][sort(bs)]),collapse=" | "))
  }
  precision<-if(tp+fp)tp/(tp+fp) else 1; recall<-if(tp+fn)tp/(tp+fn) else 1
  summary<-list(records=nrow(records),exact_pathway_matches=exact,exact_pathway_agreement=exact/nrow(records),mean_jaccard=mean(jac),pathway_precision=precision,pathway_recall=recall,pathway_f1=2*precision*recall/(precision+recall),exact_full_ranked_matches=full,exact_full_ranked_agreement=full/nrow(records),pathway_disagreements=nrow(records)-exact)
  write_csv_safe(do.call(rbind,rows),file.path(out_dir,"validation_review_queue.csv")); write_json_file(summary,file.path(out_dir,"validation_summary.json")); print(summary)
}

run_terra <- function() {
  review<-read_csv_quiet(file.path(out_dir,"validation_review_queue.csv")); review<-review[review$a_b_pathway_exact==0,]; ontology<-read_csv_quiet(ontology_path)
  empty_usage<-data.frame(stage=character(),custom_id=character(),model=character(),input_tokens=integer(),ordinary_input_tokens=integer(),cached_input_tokens=integer(),cache_write_tokens=integer(),output_tokens=integer(),reasoning_tokens=integer(),total_tokens=integer(),estimated_batch_cost_usd=double())
  if(!nrow(review)){write_csv_safe(data.frame(record_id=character(),terra_final_pathways=character(),terra_rationale=character(),terra_review_required=logical(),terra_review_reason=character()),file.path(out_dir,"terra_conflict_adjudication.csv"));write_csv_safe(empty_usage,file.path(out_dir,"terra_usage.csv"));return()}
  prefix<-paste("You are adjudicating conflicts between two independent Luna topic-classification passes for a salmon-aquaculture evidence map.","Assess the title and abstract against the supplied ontology.","Neither Luna pass is presumed correct. Do not select a pass wholesale and do not automatically take the union.","Evaluate every proposed pathway independently and add a pathway missed by both passes if the record and ontology require it.","Assign only pathways that represent substantive research questions, interventions, outcomes or conclusions.","Exclude background concepts, incidental measurements and routine endpoints.","A pathway labelled General is an exclusive fallback: do not assign it when a more specific sibling pathway applies.","Historical coding and human final decisions are deliberately withheld.","Return the final pathway IDs, one concise evidence-based rationale, and a review flag.",paste0("\nFULL ONTOLOGY\n\n",ontology_prompt(ontology)),sep="\n")
  schema<-list(type="object",properties=list(final_path_ids=list(type="array",items=list(type="string",enum=as.list(ontology$path_id))),rationale=list(type="string"),review_required=list(type="boolean"),review_reason=list(type=list("string","null"))),required=list("final_path_ids","rationale","review_required","review_reason"),additionalProperties=FALSE)
  requests<-list(); for(i in seq_len(nrow(review))){r<-review[i,]; disputed<-paste(c(r$a_only,r$b_only)[nzchar(c(r$a_only,r$b_only))],collapse="; "); dynamic<-paste0("RECORD\n\nRecord ID: ",r$record_id,"\nTitle: ",r$title,"\nAbstract: ",r$abstract,"\n\nLUNA PASS A\nAssignments: ",r$luna_a_coding,"\nReasons: ",r$luna_a_reasons,"\n\nLUNA PASS B\nAssignments: ",r$luna_b_coding,"\nReasons: ",r$luna_b_reasons,"\n\nDisputed pathway IDs: ",disputed,"\n\nAdjudicate the final pathway set.");body<-list(model=terra_model,store=FALSE,reasoning=list(effort="medium"),prompt_cache_key="topic-v3.4-cost-test-terra",prompt_cache_options=list(mode="explicit",ttl="30m"),input=list(list(role="system",content=list(list(type="input_text",text=prefix,prompt_cache_breakpoint=list(mode="explicit")))),list(role="user",content=list(list(type="input_text",text=dynamic)))),text=list(verbosity="low",format=list(type="json_schema",name="topic_conflict_adjudication",strict=TRUE,schema=schema)));requests[[i]]<-list(custom_id=paste0("terra-",r$record_id),method="POST",url="/v1/responses",body=body)}
  input_path<-file.path(out_dir,"terra_batch_input.jsonl");write_jsonl(requests,input_path);results<-submit_and_wait(input_path,"terra");rows<-usage<-list()
  for(item in results){rid<-sub("^terra-","",item$custom_id);response<-item$response$body %||% NULL;if(is.null(response)||!is.null(item$error))stop("Terra batch failure for ",rid);parsed<-fromJSON(extract_output_text(response),simplifyVector=FALSE);src<-review[review$record_id==rid,];usage[[length(usage)+1]]<-usage_row("terra",item$custom_id,terra_model,response);rows[[length(rows)+1]]<-data.frame(record_id=rid,title=src$title,disputed_path_ids=paste(c(src$a_only,src$b_only)[nzchar(c(src$a_only,src$b_only))],collapse="; "),luna_a_coding=src$luna_a_coding,luna_b_coding=src$luna_b_coding,terra_final_pathways=paste(unlist(parsed$final_path_ids),collapse="; "),terra_rationale=parsed$rationale,terra_review_required=parsed$review_required,terra_review_reason=parsed$review_reason %||% "")}
  write_csv_safe(do.call(rbind,rows),file.path(out_dir,"terra_conflict_adjudication.csv"));write_csv_safe(do.call(rbind,usage),file.path(out_dir,"terra_usage.csv"));message("Completed Terra adjudication for ",length(rows)," disagreements")
}

summarise_cost <- function(){usage<-rbind(read_csv_quiet(file.path(out_dir,"luna_usage.csv")),read_csv_quiet(file.path(out_dir,"terra_usage.csv")));by<-lapply(split(usage,usage$stage),function(x)list(requests=nrow(x),input_tokens=sum(x$input_tokens),ordinary_input_tokens=sum(x$ordinary_input_tokens),cached_input_tokens=sum(x$cached_input_tokens),cache_write_tokens=sum(x$cache_write_tokens),output_tokens=sum(x$output_tokens),cost_usd=sum(x$estimated_batch_cost_usd)));total<-sum(usage$estimated_batch_cost_usd);summary<-list(pricing_basis="OpenAI Batch API prices per 1M tokens verified 2026-09-18",prices_usd_per_million=prices,by_stage=by,total_cost_usd=total,cost_per_source_record_usd=total/sample_size,projected_14738_record_cost_usd=total/sample_size*14738,projection_assumption="The 100-record test is representative of abstract length, output length, cache performance and pathway-disagreement rate.");write_json_file(summary,file.path(out_dir,"cost_summary.json"));print(summary)}

args<-commandArgs(trailingOnly=TRUE);if(length(args)!=1||!(args[[1]]%in%c("build","luna","evaluate","terra","summary")))stop("Usage: run_topic_batch_cost_test.R build|luna|evaluate|terra|summary")
switch(args[[1]],build=build_queue(),luna=run_luna(),evaluate=evaluate_luna(),terra=run_terra(),summary=summarise_cost())

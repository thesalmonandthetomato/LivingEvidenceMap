#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(curl)
  library(digest)
  library(httr2)
  library(jsonlite)
  library(readr)
})

api_root <- "https://api.openai.com/v1"
model <- "gpt-5.6-luna"
out_dir <- Sys.getenv("TOPIC_PROD_OUTPUT_DIR", "outputs/workflow06_topic_v3_6_pilot")
queue_path <- file.path(out_dir, "input_queue.csv")
ontology_path <- Sys.getenv("TOPIC_ONTOLOGY_PATH", "data/reference/topic_ontology_v3_6.csv")
system_prompt_path <- Sys.getenv("TOPIC_SYSTEM_PROMPT_PATH", "data/reference/topic_system_prompt_v3_6.txt")
master_path <- Sys.getenv("TOPIC_MASTER_PATH", "data/master/current/living_evidence_map_master.csv")
chunk_size <- as.integer(Sys.getenv("TOPIC_CHUNK_SIZE", "50"))
poll_seconds <- as.integer(Sys.getenv("BATCH_POLL_SECONDS", "20"))
max_wait_seconds <- as.integer(Sys.getenv("BATCH_MAX_WAIT_SECONDS", "18000"))
passes <- c("a","b","c")
prices <- list(input=0.10,cached=0.01,cache_write=0.125,output=0.60)

read_csv_q <- function(p) readr::read_csv(p, show_col_types=FALSE, progress=FALSE)
write_csv_s <- function(x,p) {dir.create(dirname(p),recursive=TRUE,showWarnings=FALSE); readr::write_csv(x,p,na="")}
write_json_s <- function(x,p) {dir.create(dirname(p),recursive=TRUE,showWarnings=FALSE); jsonlite::write_json(x,p,pretty=TRUE,auto_unbox=TRUE,null="null")}
sha256_file <- function(p) digest::digest(file=p,algo="sha256",serialize=FALSE)
`%||%` <- function(x,y) if(is.null(x)||length(x)==0) y else x

api_request <- function(method, route, body=NULL, raw=FALSE) {
  key <- Sys.getenv("OPENAI_API_KEY")
  if(!nzchar(key)) stop("OPENAI_API_KEY is required")
  req <- request(paste0(api_root,route)) |>
    req_method(method) |> req_auth_bearer_token(key) |>
    req_retry(max_tries=5,retry_on_failure=TRUE) |> req_timeout(300)
  if(!is.null(body)) req <- req |> req_body_json(body,auto_unbox=TRUE,null="null")
  resp <- req_perform(req)
  if(raw) return(resp_body_raw(resp))
  resp_body_json(resp,simplifyVector=FALSE)
}

upload_batch_file <- function(path) {
  key <- Sys.getenv("OPENAI_API_KEY")
  request(paste0(api_root,"/files")) |>
    req_auth_bearer_token(key) |>
    req_body_multipart(purpose="batch",file=curl::form_file(path,type="application/jsonl")) |>
    req_retry(max_tries=5,retry_on_failure=TRUE) |> req_timeout(300) |>
    req_perform() |> resp_body_json(simplifyVector=FALSE)
}

write_jsonl <- function(items,path){
  con <- file(path,open="wt",encoding="UTF-8"); on.exit(close(con))
  for(x in items) writeLines(toJSON(x,auto_unbox=TRUE,null="null",digits=NA),con)
}

ontology_prompt <- function(x) {
  fields <- c(definition="Definition",include_when="Include when",exclude_when="Exclude when",
              required_subject_terms="Subject concept cues",required_focus_terms="Focus concept cues",
              alternative_standalone_cues="Alternative specific cues",
              supporting_terms_from_old_ontology="Supporting lexical cues",
              prompt_logic_note="Interpretation note")
  paste(vapply(seq_len(nrow(x)),function(i){
    z <- paste(x$path_id[i],x$hierarchy_path[i],sep=" | ")
    for(f in names(fields)){
      v <- trimws(as.character(x[[f]][i] %||% ""))
      if(!is.na(v)&&nzchar(v)) z <- c(z,paste0(fields[[f]],": ",v))
    }
    paste(z,collapse="\n")
  },character(1)),collapse="\n\n")
}

topic_schema <- function(ids) list(
  type="object",properties=list(
    assignments=list(type="array",items=list(type="object",properties=list(
      path_id=list(type="string",enum=as.list(ids)),
      role=list(type="string",enum=list("PRIMARY","SECONDARY")),
      reason=list(type="string")
    ),required=list("path_id","role","reason"),additionalProperties=FALSE)),
    review_required=list(type="boolean"),
    review_reason=list(type=list("string","null"))
  ),
  required=list("assignments","review_required","review_reason"),
  additionalProperties=FALSE
)

extract_output_text <- function(response){
  for(item in response$output) if(identical(item$type,"message"))
    for(content in item$content) if(identical(content$type,"output_text")) return(content$text)
  stop("No output_text returned")
}

usage_row <- function(pass,chunk,custom_id,response){
  u<-response$usage %||% list(); d<-u$input_tokens_details %||% list(); od<-u$output_tokens_details %||% list()
  input<-as.integer(u$input_tokens %||% 0); cached<-as.integer(d$cached_tokens %||% 0)
  cw<-as.integer(d$cache_write_tokens %||% 0); output<-as.integer(u$output_tokens %||% 0)
  ordinary<-input-cached-cw
  cost<-(ordinary*prices$input+cached*prices$cached+cw*prices$cache_write+output*prices$output)/1e6
  data.frame(pass,chunk,custom_id,model,input_tokens=input,ordinary_input_tokens=ordinary,
             cached_input_tokens=cached,cache_write_tokens=cw,output_tokens=output,
             reasoning_tokens=as.integer(od$reasoning_tokens %||% 0),
             total_tokens=as.integer(u$total_tokens %||% input+output),
             estimated_batch_cost_usd=cost)
}

validate_queue <- function(){
  q<-read_csv_q(queue_path)
  req<-c("record_id","title","abstract")
  miss<-setdiff(req,names(q)); if(length(miss)) stop("Queue missing columns: ",paste(miss,collapse=", "))
  q$record_id<-as.character(q$record_id)
  q$title<-as.character(q$title); q$abstract<-as.character(q$abstract)
  q$title[is.na(q$title)]<-""; q$abstract[is.na(q$abstract)]<-""
  if(any(!nzchar(q$record_id)|is.na(q$record_id))) stop("Blank record_id in queue")
  if(anyDuplicated(q$record_id)) stop("Duplicate record_id in queue")
  if(any(!nzchar(q$title) & !nzchar(q$abstract))) stop("Queue contains records with neither title nor abstract")
  q
}

build_full_queue <- function(){
  dir.create(out_dir,recursive=TRUE,showWarnings=FALSE)
  x<-read_csv_q(master_path)
  req<-c("record_id","title","abstract")
  miss<-setdiff(req,names(x)); if(length(miss)) stop("Master missing columns: ",paste(miss,collapse=", "))
  q<-x[,req,drop=FALSE]
  q$record_id<-as.character(q$record_id)
  q$title<-as.character(q$title); q$abstract<-as.character(q$abstract)
  q$title[is.na(q$title)]<-""; q$abstract[is.na(q$abstract)]<-""
  if(any(!nzchar(q$record_id)|is.na(q$record_id))) stop("Blank record_id in master")
  if(anyDuplicated(q$record_id)) {
    dup<-unique(q$record_id[duplicated(q$record_id)])
    write_csv_s(q[q$record_id %in% dup,,drop=FALSE],file.path(out_dir,"duplicate_record_ids.csv"))
    stop("Duplicate record_id values in master: ",length(dup))
  }
  bad<-q[!nzchar(q$title) & !nzchar(q$abstract),,drop=FALSE]
  if(nrow(bad)){
    write_csv_s(bad,file.path(out_dir,"records_without_title_or_abstract.csv"))
    stop("Master contains ",nrow(bad)," records with neither title nor abstract")
  }
  write_csv_s(q,queue_path)
  summary<-list(
    source_master=master_path,
    records=nrow(q),
    title_only=sum(nzchar(q$title)&!nzchar(q$abstract)),
    abstract_only=sum(!nzchar(q$title)&nzchar(q$abstract)),
    title_and_abstract=sum(nzchar(q$title)&nzchar(q$abstract)),
    queue_sha256=sha256_file(queue_path)
  )
  write_json_s(summary,file.path(out_dir,"queue_summary.json"))
  print(summary)
}


write_global_manifest <- function(){
  q<-validate_queue(); o<-read_csv_q(ontology_path)
  if(anyDuplicated(o$path_id)) stop("Duplicate ontology path_id")
  if(!all(c("path_id","hierarchy_path") %in% names(o))) stop("Ontology missing required columns")
  n_chunks<-ceiling(nrow(q)/chunk_size)
  m<-list(
    workflow="three independent Luna passes; retain union; score 1/3, 2/3, 3/3",
    model=model,passes=as.list(passes),reasoning_effort="medium",processing="Batch API",
    records=nrow(q),chunk_size=chunk_size,chunks_per_pass=n_chunks,
    expected_model_classifications=nrow(q)*length(passes),
    queue_sha256=sha256_file(queue_path),
    ontology_path=ontology_path,ontology_sha256=sha256_file(ontology_path),
    system_prompt_path=system_prompt_path,system_prompt_sha256=sha256_file(system_prompt_path),
    created_utc=format(Sys.time(),tz="UTC",usetz=TRUE)
  )
  write_json_s(m,file.path(out_dir,"production_manifest.json"))
  print(m)
}

chunk_dir <- function(pass,chunk) file.path(out_dir,paste0("pass_",pass),sprintf("chunk_%03d",chunk))

prepare_chunk <- function(pass,chunk){
  if(!(pass %in% passes)) stop("Unknown pass")
  q<-validate_queue(); o<-read_csv_q(ontology_path)
  n_chunks<-ceiling(nrow(q)/chunk_size)
  if(chunk<1||chunk>n_chunks) stop("Chunk out of range")
  d<-chunk_dir(pass,chunk); dir.create(d,recursive=TRUE,showWarnings=FALSE)
  if(file.exists(file.path(d,"complete.ok"))) return(invisible(NULL))
  input_path<-file.path(d,"batch_input.jsonl")
  if(file.exists(input_path)) return(invisible(NULL))
  i1<-(chunk-1)*chunk_size+1; i2<-min(chunk*chunk_size,nrow(q)); x<-q[i1:i2,,drop=FALSE]
  prefix<-paste0(paste(readLines(system_prompt_path,warn=FALSE),collapse="\n"),
                 "\n\nONTOLOGY\n\n",ontology_prompt(o))
  schema<-topic_schema(as.character(o$path_id))
  reqs<-vector("list",nrow(x))
  for(i in seq_len(nrow(x))){
    rec<-x[i,]
    body<-list(model=model,store=FALSE,reasoning=list(effort="medium"),
      prompt_cache_key="topic-v3.6-production-luna",
      prompt_cache_options=list(mode="explicit",ttl="30m"),
      input=list(
        list(role="system",content=list(list(type="input_text",text=prefix,prompt_cache_breakpoint=list(mode="explicit")))),
        list(role="user",content=list(list(type="input_text",text=paste0(
          "RECORD\n\nTitle: ",rec$title,"\n\nAbstract: ",rec$abstract,
          "\n\nReturn all substantive ontology assignments. Retain meaningful secondary pathways."
        ))))
      ),
      text=list(verbosity="low",format=list(type="json_schema",name="topic_v36",strict=TRUE,schema=schema)))
    reqs[[i]]<-list(custom_id=paste0("luna-",pass,"-",rec$record_id),method="POST",url="/v1/responses",body=body)
  }
  write_jsonl(reqs,input_path)
  write_json_s(list(
    pass=pass,chunk=chunk,records=nrow(x),record_ids=as.list(as.character(x$record_id)),
    input_sha256=sha256_file(input_path),queue_sha256=sha256_file(queue_path),
    ontology_sha256=sha256_file(ontology_path),prompt_sha256=sha256_file(system_prompt_path)
  ),file.path(d,"chunk_input_manifest.json"))
}

submit_chunk <- function(pass,chunk){
  prepare_chunk(pass,chunk)
  d<-chunk_dir(pass,chunk)
  if(file.exists(file.path(d,"complete.ok"))){
    message("Already complete: pass ",pass," chunk ",chunk); return(invisible(NULL))
  }
  submitted_path<-file.path(d,"batch_submitted.json")
  if(file.exists(submitted_path)){
    prior<-jsonlite::read_json(submitted_path,simplifyVector=FALSE)
    message("Recovering existing submitted batch ",prior$id," for pass ",pass," chunk ",chunk)
    return(invisible(NULL))
  }
  input_path<-file.path(d,"batch_input.jsonl")
  uploaded<-upload_batch_file(input_path)
  batch<-api_request("POST","/batches",list(
    input_file_id=uploaded$id,endpoint="/v1/responses",completion_window="24h",
    metadata=list(description=paste0("topic-v3.6-",pass,"-chunk-",chunk))))
  write_json_s(batch,submitted_path)
  writeLines("submitted",file.path(d,"submission.ok"))
  message("Submitted pass ",pass," chunk ",chunk," as ",batch$id)
}

finish_chunk <- function(pass,chunk){
  prepare_chunk(pass,chunk)
  q<-validate_queue(); o<-read_csv_q(ontology_path)
  d<-chunk_dir(pass,chunk)
  done<-file.path(d,"complete.ok")
  if(file.exists(done)){
    message("Already complete: pass ",pass," chunk ",chunk); return(invisible(NULL))
  }
  submitted_path<-file.path(d,"batch_submitted.json")
  if(!file.exists(submitted_path)) stop("No persisted batch submission for pass ",pass," chunk ",chunk)
  submitted<-jsonlite::read_json(submitted_path,simplifyVector=FALSE)
  batch_id<-as.character(submitted$id)
  batch<-api_request("GET",paste0("/batches/",batch_id))
  terminal<-c("completed","failed","expired","cancelled")
  started<-Sys.time()
  while(!(batch$status %in% terminal)){
    if(as.numeric(difftime(Sys.time(),started,units="secs"))>max_wait_seconds){
      write_json_s(batch,file.path(d,"batch_timeout_state.json"))
      stop("Batch ",batch_id," did not reach a terminal state within ",max_wait_seconds," seconds")
    }
    Sys.sleep(poll_seconds)
    batch<-api_request("GET",paste0("/batches/",batch_id))
    write_json_s(batch,file.path(d,"batch_latest.json"))
    message("pass ",pass," chunk ",chunk,": ",batch$status)
  }
  write_json_s(batch,file.path(d,"batch_final.json"))
  if(batch$status!="completed") stop("Persisted batch ",batch_id," ended ",batch$status,"; refusing automatic resubmission")
  bytes<-api_request("GET",paste0("/files/",batch$output_file_id,"/content"),raw=TRUE)
  raw_path<-file.path(d,"batch_output.jsonl"); writeBin(bytes,raw_path)
  input_path<-file.path(d,"batch_input.jsonl")
  input_lines<-readLines(input_path,warn=FALSE,encoding="UTF-8"); input_lines<-input_lines[nzchar(input_lines)]
  reqs<-lapply(input_lines,jsonlite::fromJSON,simplifyVector=FALSE)
  expected<-vapply(reqs,`[[`,"","custom_id")
  lines<-readLines(raw_path,warn=FALSE,encoding="UTF-8"); lines<-lines[nzchar(lines)]
  items<-lapply(lines,jsonlite::fromJSON,simplifyVector=FALSE)
  got<-vapply(items,`[[`,"","custom_id")
  if(anyDuplicated(got)) stop("Duplicate custom_id in batch output")
  if(length(got)!=length(expected)||!setequal(got,expected)){
    write_json_s(list(expected=as.list(expected),got=as.list(got)),file.path(d,"id_mismatch.json"))
    stop("Batch output custom_id set does not match input")
  }
  assignments<-list(); records<-list(); usages<-list()
  for(item in items){
    cid<-item$custom_id
    rid<-sub(paste0("^luna-",pass,"-"),"",cid)
    response<-item$response$body %||% NULL
    if(is.null(response)||!is.null(item$error)) stop("API item failure: ",cid)
    parsed<-fromJSON(extract_output_text(response),simplifyVector=FALSE)
    aa<-parsed$assignments %||% list()
    ids<-vapply(aa,function(a) as.character(a$path_id),"")
    bad<-setdiff(ids,as.character(o$path_id)); if(length(bad)) stop("Unknown path_id for ",rid,": ",paste(bad,collapse=","))
    duplicate_path_ids_collapsed<-sum(duplicated(ids))
    if(duplicate_path_ids_collapsed){
      unique_ids<-unique(ids)
      aa<-lapply(unique_ids,function(pid){
        z<-aa[ids==pid]
        roles<-vapply(z,function(a) as.character(a$role),"")
        reasons<-unique(vapply(z,function(a) as.character(a$reason),""))
        list(
          path_id=pid,
          role=if("PRIMARY" %in% roles) "PRIMARY" else "SECONDARY",
          reason=paste(reasons,collapse=" | ")
        )
      })
      ids<-unique_ids
      message("Collapsed ",duplicate_path_ids_collapsed," duplicate path assignment(s) for ",rid)
    }
    for(a in aa) assignments[[length(assignments)+1]]<-data.frame(
      record_id=rid,path_id=a$path_id,role=a$role,reason=a$reason,
      hierarchy_path=o$hierarchy_path[match(a$path_id,o$path_id)],stringsAsFactors=FALSE)
    records[[length(records)+1]]<-data.frame(
      record_id=rid,assignment_count=length(aa),
      duplicate_path_ids_collapsed=duplicate_path_ids_collapsed,
      review_required=isTRUE(parsed$review_required),
      review_reason=as.character(parsed$review_reason %||% ""),
      stringsAsFactors=FALSE)
    usages[[length(usages)+1]]<-usage_row(pass,chunk,cid,response)
  }
  long<-if(length(assignments)) do.call(rbind,assignments) else data.frame(
    record_id=character(),path_id=character(),role=character(),reason=character(),hierarchy_path=character())
  rec<-do.call(rbind,records); use<-do.call(rbind,usages)
  write_csv_s(long,file.path(d,"topic_assignments.csv"))
  write_csv_s(rec,file.path(d,"record_results.csv"))
  write_csv_s(use,file.path(d,"usage.csv"))
  manifest<-list(
    pass=pass,chunk=chunk,records=nrow(rec),record_ids=as.list(as.character(rec$record_id)),
    input_sha256=sha256_file(input_path),output_sha256=sha256_file(raw_path),
    batch_id=batch$id,input_file_id=batch$input_file_id,output_file_id=batch$output_file_id,
    assignments=nrow(long),cost_usd=sum(use$estimated_batch_cost_usd),
    queue_sha256=sha256_file(queue_path),ontology_sha256=sha256_file(ontology_path),
    prompt_sha256=sha256_file(system_prompt_path)
  )
  write_json_s(manifest,file.path(d,"chunk_manifest.json"))
  writeLines("validated",done)
  message("Validated pass ",pass," chunk ",chunk," (",nrow(rec)," records)")
}

run_chunk <- function(pass,chunk){
  submit_chunk(pass,chunk)
  finish_chunk(pass,chunk)
}


combine <- function(){
  q<-validate_queue(); o<-read_csv_q(ontology_path); n_chunks<-ceiling(nrow(q)/chunk_size)
  all<-list(); recs<-list(); usage<-list()
  for(p in passes) for(ch in seq_len(n_chunks)){
    d<-chunk_dir(p,ch)
    if(!file.exists(file.path(d,"complete.ok"))) stop("Missing validated chunk: ",p,"/",ch)
    a<-read_csv_q(file.path(d,"topic_assignments.csv"))
    if(nrow(a)){a$pass<-p; all[[length(all)+1]]<-a}
    r<-read_csv_q(file.path(d,"record_results.csv")); r$pass<-p; recs[[length(recs)+1]]<-r
    u<-read_csv_q(file.path(d,"usage.csv")); usage[[length(usage)+1]]<-u
  }
  A<-if(length(all)) do.call(rbind,all) else data.frame()
  R<-do.call(rbind,recs); U<-do.call(rbind,usage)
  write_csv_s(A,file.path(out_dir,"all_pass_assignments.csv"))
  write_csv_s(R,file.path(out_dir,"all_pass_record_results.csv"))
  write_csv_s(U,file.path(out_dir,"all_pass_usage.csv"))
  if(!nrow(A)) stop("No assignments returned")
  keys<-unique(A[,c("record_id","path_id")])
  score_rows<-lapply(seq_len(nrow(keys)),function(i){
    rid<-keys$record_id[i]; pid<-keys$path_id[i]; z<-A[A$record_id==rid & A$path_id==pid,,drop=FALSE]
    get1<-function(p,col){v<-z[z$pass==p,col,drop=TRUE]; if(length(v)) as.character(v[1]) else ""}
    n<-length(unique(z$pass))
    data.frame(record_id=rid,path_id=pid,
      hierarchy_path=o$hierarchy_path[match(pid,o$path_id)],
      confidence_n=n,confidence_label=paste0(n,"/3"),
      stars=paste(rep("★",n),collapse=""),
      role_a=get1("a","role"),role_b=get1("b","role"),role_c=get1("c","role"),
      reason_a=get1("a","reason"),reason_b=get1("b","reason"),reason_c=get1("c","reason"),
      stringsAsFactors=FALSE)
  })
  scores<-do.call(rbind,score_rows)
  scores<-scores[order(scores$record_id,scores$path_id),]
  write_csv_s(scores,file.path(out_dir,"three_luna_pathway_scores.csv"))
  total_cost<-sum(U$estimated_batch_cost_usd)
  counts<-as.list(table(factor(scores$confidence_n,levels=1:3)))
  names(counts)<-c("one_of_three","two_of_three","three_of_three")
  write_json_s(list(records=nrow(q),assignments=nrow(scores),confidence_counts=counts,
    measured_batch_cost_usd=total_cost),file.path(out_dir,"combine_summary.json"))
}

audit <- function(){
  q<-validate_queue(); o<-read_csv_q(ontology_path)
  R<-read_csv_q(file.path(out_dir,"all_pass_record_results.csv"))
  S<-read_csv_q(file.path(out_dir,"three_luna_pathway_scores.csv"))
  U<-read_csv_q(file.path(out_dir,"all_pass_usage.csv"))
  failures<-character()
  for(p in passes){
    ids<-as.character(R$record_id[R$pass==p])
    if(anyDuplicated(ids)) failures<-c(failures,paste("duplicate record results in pass",p))
    miss<-setdiff(as.character(q$record_id),ids); extra<-setdiff(ids,as.character(q$record_id))
    if(length(miss)) failures<-c(failures,paste("missing records in pass",p,length(miss)))
    if(length(extra)) failures<-c(failures,paste("unknown records in pass",p,length(extra)))
  }
  if(any(!(S$path_id %in% o$path_id))) failures<-c(failures,"unknown pathway IDs in combined scores")
  if(any(!(S$confidence_n %in% 1:3))) failures<-c(failures,"invalid confidence score")
  per_record<-aggregate(path_id~record_id,S,length); names(per_record)[2]<-"retained_pathways"
  allr<-merge(data.frame(record_id=as.character(q$record_id)),per_record,by="record_id",all.x=TRUE)
  allr$retained_pathways[is.na(allr$retained_pathways)]<-0
  flags<-allr[allr$retained_pathways==0 | allr$retained_pathways>10,,drop=FALSE]
  write_csv_s(flags,file.path(out_dir,"audit_review_flags.csv"))
  summary<-list(
    audit_pass=length(failures)==0,
    hard_failures=as.list(failures),
    records=nrow(q),
    expected_pass_record_results=nrow(q)*3,
    actual_pass_record_results=nrow(R),
    retained_record_pathways=nrow(S),
    one_star=sum(S$confidence_n==1),two_star=sum(S$confidence_n==2),three_star=sum(S$confidence_n==3),
    zero_code_records=sum(allr$retained_pathways==0),
    records_with_gt10_codes=sum(allr$retained_pathways>10),
    measured_batch_cost_usd=sum(U$estimated_batch_cost_usd),
    queue_sha256=sha256_file(queue_path),ontology_sha256=sha256_file(ontology_path),
    prompt_sha256=sha256_file(system_prompt_path)
  )
  write_json_s(summary,file.path(out_dir,"audit_summary.json"))
  if(length(failures)) stop(paste(failures,collapse="; "))
  writeLines("PASS",file.path(out_dir,"AUDIT_PASS.ok"))
  print(summary)
}

args<-commandArgs(trailingOnly=TRUE)
mode<-args[1] %||% ""
if (mode == "build_queue") {
  build_full_queue()
} else if (mode == "manifest") {
  write_global_manifest()
} else if (mode == "submit_chunk") {
  submit_chunk(args[2], as.integer(args[3]))
} else if (mode == "finish_chunk") {
  finish_chunk(args[2], as.integer(args[3]))
} else if (mode == "run_chunk") {
  run_chunk(args[2], as.integer(args[3]))
} else if (mode == "combine") {
  combine()
} else if (mode == "audit") {
  audit()
} else {
  stop("Usage: build_queue | manifest | submit_chunk <a|b|c> <chunk> | finish_chunk <a|b|c> <chunk> | run_chunk <a|b|c> <chunk> | combine | audit")
}

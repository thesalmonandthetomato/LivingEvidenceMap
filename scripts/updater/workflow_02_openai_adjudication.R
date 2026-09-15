#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
  library(stringi)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag, default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i == length(args)) stop(sprintf('Missing value after %s',flag))
  args[[i+1L]]
}

input_path <- arg('--input')
queue_path <- arg('--queue')
output_path <- arg('--output','outputs/fresh_workflow02/llm_adjudication_results.jsonl')
prior_path <- arg('--prior-decisions',NULL)
model <- arg('--model',Sys.getenv('OPENAI_DUPLICATE_MODEL','gpt-5.6-luna'))
checkpoint_every <- as.integer(arg('--checkpoint-every','1'))
if (is.null(input_path) || is.null(queue_path)) stop('--input and --queue are required')
if (!nzchar(Sys.getenv('OPENAI_API_KEY'))) stop('OPENAI_API_KEY is required for residual duplicate adjudication')
if (is.na(checkpoint_every) || checkpoint_every < 1L) stop('--checkpoint-every must be positive')

`%||%` <- function(x,y) if (is.null(x)) y else x
now_utc <- function() format(Sys.time(),tz='UTC',format='%Y-%m-%dT%H:%M:%SZ')
norm <- function(x) {
  if (is.null(x) || !length(x)) return('')
  s <- tolower(stringi::stri_trans_general(as.character(x)[1],'NFKD; [:Nonspacing Mark:] Remove; NFC'))
  trimws(gsub('\\s+',' ',gsub('[^a-z0-9]+',' ',s,perl=TRUE),perl=TRUE))
}
read_jsonl <- function(path) {
  if (!file.exists(path)) return(list())
  x <- readLines(path,warn=FALSE,encoding='UTF-8')
  x <- x[nzchar(trimws(x))]
  lapply(seq_along(x), function(i) tryCatch(fromJSON(x[[i]],simplifyVector=FALSE),error=function(e)stop(sprintf('Invalid JSONL %s line %d: %s',path,i,conditionMessage(e)))))
}
append_jsonl <- function(x,path) {
  dir.create(dirname(path),recursive=TRUE,showWarnings=FALSE)
  con <- file(path,'at',encoding='UTF-8'); on.exit(close(con))
  writeLines(toJSON(x,auto_unbox=TRUE,null='null',na='null',digits=NA),con)
}
pair_key <- function(a,b) paste(sort(c(as.character(a),as.character(b))),collapse='||')
payload <- function(r) { p <- r$lens$raw_payload %||% list(); if(!is.list(p)) list() else p }
canonical <- function(r) {
  if (is.list(r$canonical)) return(r$canonical)
  p<-payload(r); src<-p$source
  list(lens_id=r$identity$lens_id%||%p$lens_id,title=p$title,authors=p$authors,year=p$year_published%||%p$date_published,source=if(is.list(src))src$title else src,doi=NULL,abstract=p$abstract)
}
extract_dois <- function(r) {
  vals<-character(); c<-canonical(r)
  if(!is.null(c$doi) && nzchar(norm(c$doi))) vals<-c(vals,as.character(c$doi))
  ids<-payload(r)$external_ids%||%list()
  if(is.list(ids)) for(it in ids) if(is.list(it)&&norm(it$type)=='doi'&&nzchar(norm(it$value))) vals<-c(vals,as.character(it$value))
  unique(vals)
}
author_text <- function(r) {
  a<-canonical(r)$authors%||%list()
  if(is.character(a)) return(paste(a,collapse='; '))
  if(!is.list(a)) return('')
  vals<-vapply(a,function(x){
    if(is.list(x)) {
      z<-trimws(paste(x$first_name%||%'',x$last_name%||%''))
      if(nzchar(z)) z else as.character(x$name%||%'')
    } else as.character(x)
  },character(1))
  paste(Filter(nzchar,vals),collapse='; ')
}
record_view <- function(r) {
  c<-canonical(r); p<-payload(r); src<-p$source
  list(
    lens_id=as.character(c$lens_id%||%r$identity$lens_id%||%''),
    title=as.character(c$title%||%''),
    year=as.character(c$year%||%''),
    authors=author_text(r),
    source=as.character(c$source%||%if(is.list(src))src$title else src%||%''),
    doi=extract_dois(r),
    publication_type=as.character(p$publication_type%||%''),
    volume=as.character(p$volume%||%''),
    issue=as.character(p$issue%||%''),
    start_page=as.character(p$start_page%||%''),
    end_page=as.character(p$end_page%||%''),
    abstract=as.character(c$abstract%||%p$abstract%||%'')
  )
}
extract_output_text <- function(resp) {
  items <- resp$output %||% list()
  for (it in items) {
    if (is.list(it) && identical(it$type,'message')) {
      for (ct in it$content%||%list()) {
        if (is.list(ct) && identical(ct$type,'output_text') && !is.null(ct$text)) return(as.character(ct$text))
      }
    }
  }
  stop('No output_text returned by Responses API')
}

records<-read_jsonl(input_path); queue<-read_jsonl(queue_path)
n<-length(records)
if (!length(queue)) {
  dir.create(dirname(output_path),recursive=TRUE,showWarnings=FALSE)
  file.create(output_path)
  writeLines(
    toJSON(
      list(
        queued_pairs=0,
        adjudicated_pairs=0,
        duplicate=0,
        not_duplicate=0,
        uncertain=0,
        technical_failures=0,
        reused_prior_decisions=0,
        new_api_calls=0,
        model=model,
        completed_at=now_utc()
      ),
      auto_unbox=TRUE,pretty=TRUE,null='null',na='null'
    ),
    sub('\\.jsonl$','_summary.json',output_path)
  )
  message('PASS: no residual duplicate candidates require OpenAI adjudication')
  quit(save='no',status=0)
}

# Resume safely within the same run if a checkpoint file already exists.
existing<-read_jsonl(output_path)
done_keys<-if(length(existing)) unique(vapply(existing,function(x)as.character(x$pair_key%||%''),character(1))) else character()

# Reuse only previously resolved substantive model decisions. Uncertain or
# technically failed decisions are deliberately not cached.
prior<-if(!is.null(prior_path) && file.exists(prior_path)) read_jsonl(prior_path) else list()
prior_map<-list()
if(length(prior)) for(x in prior) {
  k<-as.character(x$pair_key%||%'')
  d<-as.character(x$decision%||%'')
  if(nzchar(k) && d%in%c('duplicate','not_duplicate') && !isTRUE(x$technical_failure)) prior_map[[k]]<-x
}
message(sprintf(
  'OpenAI duplicate adjudication: %d queued pairs; %d already checkpointed; %d reusable prior decisions; model=%s',
  length(queue),length(done_keys),length(prior_map),model
))

schema<-list(
  type='object',
  additionalProperties=FALSE,
  properties=list(
    decision=list(type='string',enum=list('duplicate','not_duplicate','uncertain')),
    confidence=list(type='number',minimum=0,maximum=1),
    rationale=list(type='string')
  ),
  required=list('decision','confidence','rationale')
)

for (i in seq_along(queue)) {
  ca<-queue[[i]]
  ai<-as.integer(ca$record_index)+1L; bi<-as.integer(ca$matched_index)+1L
  if(is.na(ai)||is.na(bi)||ai<1||bi<1||ai>n||bi>n) stop(sprintf('Invalid candidate indices at queue row %d',i))
  a<-records[[ai]]; b<-records[[bi]]
  ida<-as.character(a$identity$lens_id%||%canonical(a)$lens_id%||%'')
  idb<-as.character(b$identity$lens_id%||%canonical(b)$lens_id%||%'')
  key<-pair_key(ida,idb)
  if(key %in% done_keys) next

  if(!is.null(prior_map[[key]])) {
    reused<-prior_map[[key]]
    reused$reused_prior_decision<-TRUE
    reused$reused_at<-now_utc()
    append_jsonl(reused,output_path)
    done_keys<-c(done_keys,key)
    if(i%%checkpoint_every==0L||i==length(queue)) message(sprintf('OpenAI duplicate adjudication: %d/%d processed; reused prior decision=%s',i,length(queue),as.character(reused$decision)))
    next
  }

  evidence<-list(
    deterministic_candidate=list(
      basis=ca$basis%||%'',
      title_similarity=ca$title_similarity%||%NULL,
      abstract_similarity=ca$abstract_similarity%||%NULL,
      manifestation_pattern=ca$manifestation_pattern%||%NULL
    ),
    record_a=record_view(a),
    record_b=record_view(b)
  )
  prompt<-paste0(
    'Determine whether these two bibliographic records represent the same underlying publication/work or distinct works. ',
    'Return duplicate for duplicate database manifestations, preprint/final versions, repository/journal versions, or versioned records of the same work. ',
    'Return not_duplicate for genuinely distinct publications, even if titles are generic or identical. ',
    'Return uncertain when the supplied bibliographic evidence is insufficient. ',
    'Do not use topical similarity alone. Treat DOI disagreement as evidence, not absolute proof; explicit versioned DOI forms may still represent the same work.\n\n',
    toJSON(evidence,auto_unbox=TRUE,null='null',na='null',digits=NA)
  )

  result<-tryCatch({
    body<-list(
      model=model,
      store=FALSE,
      reasoning=list(effort='low'),
      input=list(list(role='user',content=list(list(type='input_text',text=prompt)))),
      text=list(
        verbosity='low',
        format=list(type='json_schema',name='duplicate_adjudication',strict=TRUE,schema=schema)
      )
    )
    resp<-request('https://api.openai.com/v1/responses') |>
      req_auth_bearer_token(Sys.getenv('OPENAI_API_KEY')) |>
      req_body_json(body,auto_unbox=TRUE) |>
      req_timeout(120) |>
      req_retry(max_tries=5,backoff=~min(30,2^.x)) |>
      req_perform() |>
      resp_body_json(simplifyVector=FALSE)
    parsed<-fromJSON(extract_output_text(resp),simplifyVector=FALSE)
    dec<-as.character(parsed$decision%||%'')
    conf<-suppressWarnings(as.numeric(parsed$confidence%||%NA_real_))
    rat<-as.character(parsed$rationale%||%'')
    if(!dec%in%c('duplicate','not_duplicate','uncertain')) stop('Invalid model decision')
    if(length(conf)!=1L||is.na(conf)||conf<0||conf>1) stop('Invalid model confidence')
    if(length(rat)!=1L||!nzchar(rat)) stop('Empty model rationale')
    usage<-resp$usage%||%list()
    list(
      pair_key=key,lens_id_a=ida,lens_id_b=idb,
      decision=dec,confidence=conf,rationale=rat,
      model_requested=model,model_returned=as.character(resp$model%||%model),
      response_id=as.character(resp$id%||%''),
      input_tokens=usage$input_tokens%||%NULL,
      output_tokens=usage$output_tokens%||%NULL,
      total_tokens=usage$total_tokens%||%NULL,
      technical_failure=FALSE,error=NULL,reused_prior_decision=FALSE,
      adjudicated_at=now_utc(),queue_row=i,
      deterministic_basis=ca$basis%||%'',
      title_similarity=ca$title_similarity%||%NULL,
      abstract_similarity=ca$abstract_similarity%||%NULL
    )
  },error=function(e){
    list(
      pair_key=key,lens_id_a=ida,lens_id_b=idb,
      decision='uncertain',confidence=NULL,rationale='Technical model/API failure; human review required.',
      model_requested=model,model_returned=NULL,response_id=NULL,
      input_tokens=NULL,output_tokens=NULL,total_tokens=NULL,
      technical_failure=TRUE,error=conditionMessage(e),reused_prior_decision=FALSE,
      adjudicated_at=now_utc(),queue_row=i,
      deterministic_basis=ca$basis%||%'',
      title_similarity=ca$title_similarity%||%NULL,
      abstract_similarity=ca$abstract_similarity%||%NULL
    )
  })

  append_jsonl(result,output_path)
  done_keys<-c(done_keys,key)
  if(i%%checkpoint_every==0L||i==length(queue)) {
    message(sprintf('OpenAI duplicate adjudication: %d/%d processed; decision=%s; confidence=%s',i,length(queue),result$decision,as.character(result$confidence%||%'NA')))
  }
}

all_results<-read_jsonl(output_path)
if(length(all_results)!=length(queue)) stop(sprintf('Adjudication cardinality mismatch: queue=%d results=%d',length(queue),length(all_results)))
keys<-vapply(all_results,function(x)as.character(x$pair_key%||%''),character(1))
if(any(!nzchar(keys))||anyDuplicated(keys)) stop('Adjudication pair-key invariant failed')
decisions<-vapply(all_results,function(x)as.character(x$decision%||%''),character(1))
failures<-sum(vapply(all_results,function(x)isTRUE(x$technical_failure),logical(1)))
reused<-sum(vapply(all_results,function(x)isTRUE(x$reused_prior_decision),logical(1)))
summary<-list(
  queued_pairs=length(queue),
  adjudicated_pairs=length(all_results),
  duplicate=sum(decisions=='duplicate'),
  not_duplicate=sum(decisions=='not_duplicate'),
  uncertain=sum(decisions=='uncertain'),
  technical_failures=failures,
  reused_prior_decisions=reused,
  new_api_calls=length(all_results)-reused,
  model=model,
  completed_at=now_utc()
)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null='null',na='null'),sub('\\.jsonl$','_summary.json',output_path))
message(toJSON(summary,auto_unbox=TRUE,pretty=TRUE))
message('PASS: OpenAI residual duplicate adjudication complete with checkpointed provenance')

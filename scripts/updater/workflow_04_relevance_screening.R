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
  if (i == length(args)) stop(sprintf("Missing value after %s",flag))
  args[[i+1L]]
}

input_path <- arg("--input")
queue_path <- arg("--queue")
output_path <- arg("--output","outputs/workflow04/screening_results.jsonl")
checkpoint_path <- arg("--checkpoint","outputs/workflow04/checkpoint.json")
summary_path <- arg("--summary","outputs/workflow04/screening_summary.json")
model <- arg("--model",Sys.getenv("OPENAI_RELEVANCE_MODEL","gpt-5.6-luna"))
max_records <- as.integer(arg("--max-records","0"))
checkpoint_every <- as.integer(arg("--checkpoint-every","25"))
mode <- arg("--mode","openai")

if (is.null(input_path) || is.null(queue_path)) stop("--input and --queue are required")
if (!mode %in% c("mock","openai")) stop("--mode must be mock or openai")
if (mode=="openai" && !nzchar(Sys.getenv("OPENAI_API_KEY"))) stop("OPENAI_API_KEY is required")
if (is.na(checkpoint_every) || checkpoint_every < 1L) stop("--checkpoint-every must be positive")
if (is.na(max_records) || max_records < 0L) stop("--max-records must be >= 0")

`%||%` <- function(x,y) if (is.null(x)) y else x
now_utc <- function() format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")

SYSTEM_PROMPT <- paste(
"You are screening bibliographic records for inclusion in a living evidence map of commercial aquaculture of Atlantic salmon, Pacific salmon, and rainbow trout.",
"",
"This is a HIGH-SENSITIVITY title/abstract screening stage.",
"",
"Your task is to classify each record as exactly one of: RETAIN, EXCLUDE, UNCERTAIN.",
"",
"RETAIN whenever the available bibliographic evidence reasonably establishes eligibility.",
"Do not exclude merely because the study's main outcome, organism, discipline, or document type is unusual.",
"",
"Use ALL supplied metadata: title, abstract, keywords, journal/source title, and any explicitly supplied affiliation or funding information. Do not infer facts that are not present in those fields.",
"",
"1. ELIGIBLE SPECIES",
"Eligible species/groups are:",
"- Atlantic salmon (Salmo salar)",
"- Chinook salmon (Oncorhynchus tshawytscha)",
"- coho salmon (Oncorhynchus kisutch)",
"- sockeye salmon (Oncorhynchus nerka)",
"- chum salmon (Oncorhynchus keta)",
"- pink salmon (Oncorhynchus gorbuscha)",
"- masu salmon (Oncorhynchus masou)",
"- rainbow trout (Oncorhynchus mykiss; including historical synonyms)",
"- unspecified \"salmon\" where the aquaculture/farming context is established",
"",
"Generic terms such as salmonid, salmonids, trout, or fish DO NOT by themselves satisfy the species criterion. Do not infer an eligible species merely from a salmonid-specific pathogen.",
"",
"However, explicit SALMON FARMING can itself establish the relevant salmon context for studies examining impacts arising from salmon aquaculture, even where the organism actually measured is not an eligible species. Examples: sea trout affected by salmon farming -> RETAIN; lumpfish deployed in salmon farms -> RETAIN; prawns exposed to salmon-farm treatments -> RETAIN; environmental effects of salmon net pens -> RETAIN.",
"",
"2. AQUACULTURE CONTEXT",
"The record must concern commercial/farmed aquaculture, its products, processes, infrastructure, inputs, consequences, impacts, or closely connected research. Evidence can come from any supplied metadata field.",
"",
"Explicit indicators include aquaculture, mariculture, farmed, salmon farm, fish farm, commercial production, aquaculture production, recirculating aquaculture system/RAS, commercial sea cages/net pens, aquaculture feed, farm management, on-farm monitoring, or commercial processing of farmed fish.",
"",
"An explicitly aquaculture-focused journal may establish aquaculture context where the eligible species and study subject are otherwise clear.",
"",
"An explicitly aquaculture-focused author affiliation or funding source may establish context where eligible species/relevance are clear but the title/abstract does not state the production setting. A generic university, fisheries, marine, agriculture, or government affiliation is insufficient.",
"",
"\"Commercial conditions\" may establish aquaculture context when clearly referring to production of an eligible species. For Atlantic salmon, an explicit \"seawater phase\" may establish aquaculture production context.",
"",
"Broodstock, experimental diets, commercial diets, selective breeding, production stressors, processing, slaughter, welfare, disease control and other production-related research can establish aquaculture context when the metadata clearly connects them to production.",
"",
"3. IMPORTANT HIGH-SENSITIVITY RULE",
"Do NOT require the eligible salmon/rainbow trout to be the organism directly measured.",
"",
"RETAIN studies of environmental, ecological, occupational, social, economic, health, disease, treatment or other consequences of eligible salmon aquaculture. Examples include effects of salmon farms on wild fish or wildlife, environmental enrichment beneath salmon farms, disease transmission from/between salmon farms, occupational safety in salmon aquaculture, effects of salmon-farm therapeutants on non-target species, cleaner fish used within salmon farms, and hydrodynamics relevant to salmon-farm disease transmission.",
"",
"An explicit reference to an eligible salmon/rainbow-trout farm or aquaculture operation is sufficient at this screening stage even if it is not the principal analytical subject. Do not introduce a \"substantive focus\" requirement that is not part of the eligibility criteria.",
"",
"4. FISHMEAL RULE",
"If a record refers to (a) an eligible salmon species or rainbow trout AND (b) fishmeal, RETAIN it regardless of whether additional aquaculture terminology is present.",
"",
"5. HATCHERY / STOCK ENHANCEMENT",
"Do NOT treat hatchery use automatically as aquaculture.",
"EXCLUDE studies where eligible salmon are hatchery-reared solely for release into rivers/ocean, restocking, stock enhancement, population supplementation, sport fisheries, conservation release, or sea/ocean ranching. These are not commercial aquaculture for this evidence map.",
"A facility being called a \"fish farm\" or hatchery does not override clear evidence that the purpose is population supplementation or release.",
"",
"6. EXPERIMENTAL CAGES AND PENS",
"Do NOT infer commercial aquaculture solely because fish are held experimentally in cages, pens, net pens, or tanks. Experimental containment used only for an exposure/ecology experiment is insufficient. There must be additional evidence connecting the study to commercial aquaculture or production.",
"",
"7. WILD POPULATIONS",
"A study of wild eligible salmonids is not automatically relevant.",
"EXCLUDE purely wild-population ecology, genetics, migration, conservation, restocking, or disease surveillance where aquaculture appears only as generic background and the study does not evaluate or meaningfully connect to salmon aquaculture.",
"RETAIN where the wild-population study explicitly evaluates an exposure, impact, interaction, disease risk, genetic interaction or other consequence connected to eligible salmon aquaculture. At this high-sensitivity stage, an explicit and plausible salmon-farming connection should normally favour RETAIN.",
"",
"8. GENERIC SALMONIDS",
"Strong aquaculture context does NOT rescue a direct study that identifies the relevant fish only as \"salmonid\" or \"salmonids\".",
"Example: \"Sea lice infestation of salmonids in Chile\" in the journal Aquaculture, with no eligible species or explicit \"salmon\" -> EXCLUDE.",
"Likewise, \"triploid salmonids for aquaculture\" -> EXCLUDE if no eligible species is identified.",
"But this rule does NOT apply where the study is explicitly about the IMPACT OF SALMON FARMING itself, e.g. \"salmon net pens\", \"salmon farms\", or \"salmon mariculture\". In those cases the aquaculture activity supplies the relevant salmon context.",
"",
"9. PRODUCTS AND PROCESSING",
"Studies of salmon/rainbow-trout food products, processing, storage, fillets, slaughter or post-harvest quality are eligible where commercial aquaculture origin is explicit or reasonably established from the supplied metadata. Do not assume all salmon products are farmed. However, production geography and industrial context can establish origin where the context makes farmed origin unambiguous.",
"",
"10. SPECIAL CASES",
"Genetically engineered salmon intended for food production -> RETAIN.",
"Corrections/corrigenda to otherwise eligible studies -> RETAIN at relevance screening. Document-type cleanup occurs downstream.",
"Administrative, programme, report, chapter or other non-journal records are NOT excluded merely because they are not primary research if they explicitly concern eligible salmon aquaculture. Do not impose an unstated study-design criterion.",
"Contents pages, tables of contents, collections of book reviews, or composite records must NOT be retained by combining species evidence from one listed item with aquaculture evidence from another listed item. Assess the record itself as one coherent work.",
"",
"11. DECISION LOGIC",
"RETAIN when eligible species/relevant salmon farming is established AND commercial aquaculture relevance is established, OR a specific inclusion rule above applies.",
"EXCLUDE when an eligibility gate clearly fails, the record clearly concerns only wild/restocking/non-commercial contexts, or only generic salmonid terminology is available for a direct-species study.",
"UNCERTAIN only when available metadata are genuinely insufficient or contradictory AND neither RETAIN nor EXCLUDE can be justified from the supplied evidence. Do NOT use UNCERTAIN merely because a record is unusual.",
"This is a high-sensitivity screening stage. Where evidence genuinely supports both interpretations and exclusion is not clearly justified, favour RETAIN.",
"",
"12. OUTPUT",
"Return structured output with decision and reason. The decision value must be exactly one of: retain, exclude, uncertain. The reason must be one concise sentence identifying the specific bibliographic evidence that determines the decision. Identify the relevant species evidence and aquaculture-context evidence, or state explicitly which gate failed.",
"Do not invent missing metadata. Do not infer species from subject matter alone. Do not use topical similarity alone as evidence of eligibility.",
sep="\n"
)
PROMPT_VERSION <- "workflow04-v1-legacy-python-prompt"
PROMPT_SHA256 <- digest::digest(SYSTEM_PROMPT,algo="sha256",serialize=FALSE)

read_jsonl <- function(path) {
  if (!file.exists(path)) return(list())
  x <- readLines(path,warn=FALSE,encoding="UTF-8")
  x <- x[nzchar(trimws(x))]
  lapply(seq_along(x),function(i)tryCatch(
    fromJSON(x[[i]],simplifyVector=FALSE),
    error=function(e)stop(sprintf("Invalid JSONL %s line %d: %s",path,i,conditionMessage(e)))
  ))
}
append_jsonl <- function(x,path) {
  dir.create(dirname(path),recursive=TRUE,showWarnings=FALSE)
  con <- file(path,"at",encoding="UTF-8"); on.exit(close(con))
  writeLines(toJSON(x,auto_unbox=TRUE,null="null",na="null",digits=NA),con)
}
write_checkpoint <- function(done,total,ret,exc,unc,fail) {
  dir.create(dirname(checkpoint_path),recursive=TRUE,showWarnings=FALSE)
  payload <- list(
    workflow="04_relevance_screening",
    implementation_language="R",
    completed_records=done,total_records=total,
    retain=ret,exclude=exc,uncertain=unc,technical_failures=fail,
    model=model,prompt_version=PROMPT_VERSION,prompt_sha256=PROMPT_SHA256,updated_at=now_utc()
  )
  tmp <- paste0(checkpoint_path,".tmp")
  writeLines(toJSON(payload,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),tmp)
  file.rename(tmp,checkpoint_path)
}
payload <- function(r) {
  p <- r$lens$raw_payload %||% list()
  if (is.list(p)) p else list()
}
canonical <- function(r) {
  c <- r$canonical %||% list()
  if (is.list(c)) c else list()
}
textify <- function(x) {
  if (is.null(x)) return("")
  if (is.character(x)) return(paste(x[nzchar(x)],collapse="; "))
  if (is.atomic(x)) return(paste(as.character(x),collapse="; "))
  if (is.list(x)) return(paste(Filter(nzchar,vapply(x,textify,character(1))),collapse="; "))
  as.character(x)
}
first_nonempty <- function(...) {
  xs <- list(...)
  for(x in xs) {
    z <- textify(x)
    if(nzchar(trimws(z))) return(trimws(z))
  }
  ""
}
lens_id <- function(r) as.character((r$identity %||% list())$lens_id %||% canonical(r)$lens_id %||% payload(r)$lens_id %||% "")
source_title <- function(x) {
  if (is.list(x)) return(first_nonempty(x$title,x$name))
  first_nonempty(x)
}
affiliations <- function(r) {
  vals <- character()
  for(src in list(canonical(r),payload(r))) {
    if(!is.list(src)) next
    vals <- c(vals,textify(src$affiliations))
    a <- src$authors %||% list()
    if(is.list(a)) for(author in a) if(is.list(author)) vals <- c(vals,textify(author$affiliations))
  }
  paste(unique(vals[nzchar(vals)]),collapse="; ")
}
funding <- function(r) {
  vals <- character()
  for(src in list(canonical(r),payload(r))) {
    if(!is.list(src)) next
    for(k in c("funding","funders","funder","funding_sources","funding_source","grants","grant","funding_text","acknowledgements")) {
      if(!is.null(src[[k]])) vals <- c(vals,textify(src[[k]]))
    }
  }
  paste(unique(vals[nzchar(vals)]),collapse="; ")
}
record_view <- function(r) {
  c <- canonical(r); p <- payload(r)
  list(
    lens_id=lens_id(r),
    title=first_nonempty(c$title,p$title),
    abstract=first_nonempty(c$abstract,p$abstract),
    keywords=first_nonempty(c$keywords,p$keywords,p$keyword,p$author_keywords),
    journal_source_title=first_nonempty(c$source_title,c$journal,p$source_title,p$journal,source_title(p$source),source_title(p$publication)),
    affiliations=affiliations(r),
    funding=funding(r)
  )
}
extract_output_text <- function(resp) {
  for(it in resp$output %||% list()) {
    if(is.list(it) && identical(it$type,"message")) {
      for(ct in it$content %||% list()) {
        if(is.list(ct) && identical(ct$type,"output_text") && !is.null(ct$text)) return(as.character(ct$text))
      }
    }
  }
  stop("No output_text returned by Responses API")
}

records <- read_jsonl(input_path)
queue <- read_jsonl(queue_path)
if (!length(records)) stop("Canonical input is empty")
if (!length(queue)) stop("Workflow 04 queue is empty")

ids <- vapply(records,lens_id,character(1))
qids <- vapply(queue,lens_id,character(1))
if(any(!nzchar(ids)) || anyDuplicated(ids)) stop("Canonical Lens-ID invariant failed")
if(any(!nzchar(qids)) || anyDuplicated(qids)) stop("Queue Lens-ID invariant failed")
if(any(!qids %in% ids)) stop("Workflow 04 queue contains Lens IDs absent from canonical records")

# Workflow 04 may only screen the explicitly reconciled new-screening queue.
for(r in queue) {
  s <- r$screening %||% list()
  d <- r$deduplication %||% list()
  if(!identical(as.character(s$status %||% ""),"not_previously_screened")) stop(sprintf("Queue record %s is not marked not_previously_screened",lens_id(r)))
  if(!isTRUE(s$requires_screening)) stop(sprintf("Queue record %s does not require screening",lens_id(r)))
  if(!isTRUE(s$publication_status_eligible %||% TRUE)) stop(sprintf("Publication-blocked record %s must not enter Workflow 04 queue",lens_id(r)))
  if(!as.character(d$status %||% "") %in% c("unique","canonical")) stop(sprintf("Non-representative record %s entered Workflow 04 queue",lens_id(r)))
}

if(max_records>0L) queue <- queue[seq_len(min(max_records,length(queue)))]
total <- length(queue)

schema <- list(
  type="object",
  additionalProperties=FALSE,
  properties=list(
    decision=list(type="string",enum=list("retain","exclude","uncertain")),
    reason=list(type="string")
  ),
  required=list("decision","reason")
)

existing <- read_jsonl(output_path)
done_ids <- if(length(existing)) vapply(existing,function(x)as.character(x$lens_id %||% ""),character(1)) else character()
if(anyDuplicated(done_ids)) stop("Existing Workflow 04 result IDs are duplicated")
if(any(!done_ids %in% vapply(queue,lens_id,character(1)))) stop("Existing Workflow 04 results do not match current queue/sample")

counts <- c(retain=0L,exclude=0L,uncertain=0L)
failures <- 0L
if(length(existing)) {
  dec <- vapply(existing,function(x)as.character(x$decision %||% ""),character(1))
  counts["retain"] <- sum(dec=="retain")
  counts["exclude"] <- sum(dec=="exclude")
  counts["uncertain"] <- sum(dec=="uncertain")
  failures <- sum(vapply(existing,function(x)isTRUE(x$technical_failure),logical(1)))
}
write_checkpoint(length(existing),total,counts["retain"],counts["exclude"],counts["uncertain"],failures)

message(sprintf("Workflow 04 relevance screening: %d queue records; %d already checkpointed; model=%s",total,length(existing),model))

for(i in seq_along(queue)) {
  r <- queue[[i]]
  id <- lens_id(r)
  if(id %in% done_ids) next
  view <- record_view(r)

  result <- if(mode=="mock") {
    txt <- tolower(paste(unlist(view,use.names=FALSE),collapse=" "))
    if(!nzchar(trimws(paste(view$title,view$abstract,view$keywords)))) {
      list(decision="uncertain",reason="Available bibliographic metadata are insufficient to establish either eligibility or clear ineligibility.",technical_failure=FALSE,error=NULL,response_id=NULL,model_returned=NULL,usage=NULL)
    } else if(grepl("wild",txt) && !grepl("farm|aquaculture|mariculture",txt)) {
      list(decision="exclude",reason="The supplied metadata describe a wild-population context without evidence of commercial aquaculture.",technical_failure=FALSE,error=NULL,response_id=NULL,model_returned=NULL,usage=NULL)
    } else if(grepl("atlantic salmon|salmo salar|rainbow trout|oncorhynchus mykiss",txt) && grepl("farm|aquaculture|mariculture",txt)) {
      list(decision="retain",reason="The supplied metadata explicitly identify an eligible species and commercial aquaculture context.",technical_failure=FALSE,error=NULL,response_id=NULL,model_returned=NULL,usage=NULL)
    } else {
      list(decision="uncertain",reason="Mock mode cannot make a defensible eligibility decision from the supplied metadata.",technical_failure=FALSE,error=NULL,response_id=NULL,model_returned=NULL,usage=NULL)
    }
  } else {
    tryCatch({
      user_text <- paste0(
        "SCREEN THIS RECORD USING ONLY THE SUPPLIED METADATA.\n\n",
        toJSON(view,auto_unbox=TRUE,pretty=TRUE,null="null",na="null")
      )
      body <- list(
        model=model,
        store=FALSE,
        reasoning=list(effort="low"),
        input=list(
          list(role="system",content=list(list(type="input_text",text=SYSTEM_PROMPT))),
          list(role="user",content=list(list(type="input_text",text=user_text)))
        ),
        text=list(
          verbosity="low",
          format=list(type="json_schema",name="salmon_aquaculture_relevance_screen",strict=TRUE,schema=schema)
        )
      )
      resp <- request("https://api.openai.com/v1/responses") |>
        req_auth_bearer_token(Sys.getenv("OPENAI_API_KEY")) |>
        req_body_json(body,auto_unbox=TRUE) |>
        req_timeout(120) |>
        req_retry(max_tries=5,backoff=~min(30,2^.x)) |>
        req_perform() |>
        resp_body_json(simplifyVector=FALSE)
      parsed <- fromJSON(extract_output_text(resp),simplifyVector=FALSE)
      d <- as.character(parsed$decision %||% "")
      rr <- as.character(parsed$reason %||% "")
      if(!d %in% c("retain","exclude","uncertain")) stop("Invalid model screening decision")
      if(length(rr)!=1L || !nzchar(trimws(rr))) stop("Empty model screening reason")
      list(
        decision=d,reason=rr,technical_failure=FALSE,error=NULL,
        response_id=as.character(resp$id %||% ""),
        model_returned=as.character(resp$model %||% model),
        usage=resp$usage %||% NULL
      )
    },error=function(e) {
      list(
        decision="uncertain",
        reason="Technical screening failure; human review required.",
        technical_failure=TRUE,error=conditionMessage(e),
        response_id=NULL,model_returned=NULL,usage=NULL
      )
    })
  }

  row <- list(
    workflow="04_relevance_screening",
    implementation_language="R",
    lens_id=id,
    decision=result$decision,
    reason=result$reason,
    provisional=TRUE,
    requires_human_review=identical(result$decision,"uncertain") || isTRUE(result$technical_failure),
    technical_failure=isTRUE(result$technical_failure),
    error=result$error,
    model_requested=if(mode=="openai") model else NULL,
    prompt_version=PROMPT_VERSION,
    prompt_sha256=PROMPT_SHA256,
    model_returned=result$model_returned,
    response_id=result$response_id,
    usage=result$usage,
    evidence=view,
    screened_at=now_utc()
  )
  append_jsonl(row,output_path)
  done_ids <- c(done_ids,id)
  counts[result$decision] <- counts[result$decision] + 1L
  if(isTRUE(result$technical_failure)) failures <- failures + 1L
  done <- length(done_ids)
  if(done %% checkpoint_every==0L || done==total) {
    write_checkpoint(done,total,counts["retain"],counts["exclude"],counts["uncertain"],failures)
    message(sprintf("Workflow 04: %d/%d screened; retain=%d exclude=%d uncertain=%d failures=%d",
      done,total,counts["retain"],counts["exclude"],counts["uncertain"],failures))
  }
}

all_results <- read_jsonl(output_path)
if(length(all_results)!=total) stop(sprintf("Workflow 04 result cardinality mismatch: expected %d got %d",total,length(all_results)))
rid <- vapply(all_results,function(x)as.character(x$lens_id %||% ""),character(1))
if(anyDuplicated(rid) || setequal(rid,vapply(queue,lens_id,character(1)))==FALSE) stop("Workflow 04 result identity invariant failed")
if(any(vapply(all_results,function(x)isTRUE(x$technical_failure),logical(1)))) {
  message("Workflow 04 completed with technical failures; results remain provisional and apply must be blocked.")
}

dec <- vapply(all_results,function(x)as.character(x$decision %||% ""),character(1))
summary <- list(
  workflow="04_relevance_screening",
  implementation_language="R",
  queue_records=total,
  retain=sum(dec=="retain"),
  exclude=sum(dec=="exclude"),
  uncertain=sum(dec=="uncertain"),
  technical_failures=sum(vapply(all_results,function(x)isTRUE(x$technical_failure),logical(1))),
  model=model,
  prompt_version=PROMPT_VERSION,
  prompt_sha256=PROMPT_SHA256,
  completed_at=now_utc()
)
dir.create(dirname(summary_path),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),summary_path)
message(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"))
message("PASS: Workflow 04 R relevance-screening run complete with checkpointed per-record provenance.")

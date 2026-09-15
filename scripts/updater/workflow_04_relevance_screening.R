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
"You are screening bibliographic records for inclusion in a living evidence map of commercial aquaculture involving Atlantic salmon, Pacific salmon, and rainbow trout.",
"",
"This is a HIGH-SENSITIVITY title/abstract screening stage. Classify each record as exactly RETAIN, EXCLUDE, or UNCERTAIN.",
"",
"GENERAL EVIDENCE RULE",
"Use the supplied title, abstract, keywords and source metadata. Affiliation and funding information may corroborate an interpretation but MUST NOT establish aquaculture relevance by themselves. An aquaculture-focused journal or source title may support aquaculture context but MUST NOT override a title/abstract that is clearly wild, conservation-only, restocking-only, or otherwise outside commercial aquaculture. Do not infer facts from geography, institutions, common practice, or subject-matter familiarity when those facts are not stated in the supplied metadata.",
"",
"1. ELIGIBLE SPECIES / SALMON-FARMING CONTEXT",
"Eligible directly studied species are:",
"- Atlantic salmon (Salmo salar)",
"- Chinook salmon (Oncorhynchus tshawytscha)",
"- coho salmon (Oncorhynchus kisutch)",
"- sockeye salmon (Oncorhynchus nerka)",
"- chum salmon (Oncorhynchus keta)",
"- pink salmon (Oncorhynchus gorbuscha)",
"- masu salmon (Oncorhynchus masou)",
"- rainbow trout (Oncorhynchus mykiss, including historical scientific synonyms)",
"- unspecified salmon when commercial salmon farming/aquaculture context is explicitly established.",
"",
"Generic salmonid, salmonids, trout, or fish terminology does NOT by itself establish an eligible species. Do not infer an eligible species merely from a salmonid-specific pathogen, location, production system, journal, affiliation, or funding source.",
"",
"An explicit reference to salmon farming, salmon farms, farmed salmon, salmon aquaculture, salmon net pens/cages, or equivalent commercial salmon production can establish the relevant salmon context for studies of consequences or associated organisms even when the organism measured is not itself an eligible species.",
"",
"2. COMMERCIAL AQUACULTURE CONTEXT",
"The record must concern commercial/farmed aquaculture, its products, processes, infrastructure, inputs, consequences, impacts, or closely connected research.",
"Strong indicators include explicit aquaculture/mariculture/farmed/commercial-production wording; salmon or rainbow-trout farms; production sea cages/net pens; RAS used for production; aquaculture feed; farm management; on-farm monitoring; production breeding; production health/welfare; slaughter; or processing of explicitly farmed fish.",
"",
"Experimental rearing, tanks, cages, pens, hatcheries, seawater exposure, broodstock, diets, disease challenges, or a source journal named Aquaculture do NOT on their own prove commercial aquaculture context. They may contribute to a RETAIN decision when the record supplies additional production/farming evidence.",
"",
"3. CONSEQUENCES OF SALMON AQUACULTURE",
"Do NOT require the eligible salmon/rainbow trout to be the organism directly measured. RETAIN studies of environmental, ecological, occupational, social, economic, health, disease, treatment, infrastructure, hydrodynamic, or other consequences of eligible salmon aquaculture when the farming connection is explicit.",
"Examples include effects of salmon farms on wild fish or wildlife; benthic/environmental effects beneath salmon farms; disease transmission from or between salmon farms; occupational safety in salmon aquaculture; salmon-farm therapeutants affecting non-target species; cleaner fish used in salmon farms; or hydrodynamics explicitly studied for salmon-farm disease/parasite transmission.",
"",
"4. FISHMEAL RULE",
"If a record explicitly refers to an eligible salmon species or rainbow trout AND fishmeal, RETAIN it, even if no additional aquaculture term is present.",
"",
"5. HATCHERY / STOCK ENHANCEMENT",
"Do NOT treat hatchery use automatically as commercial aquaculture. EXCLUDE studies where eligible salmon are reared solely for release, restocking, stock enhancement, population supplementation, conservation release, sport fisheries, or sea/ocean ranching, unless the record separately evaluates commercial aquaculture.",
"",
"6. WILD POPULATIONS",
"EXCLUDE purely wild-population ecology, genetics, migration, conservation, restocking, or disease surveillance where commercial aquaculture is absent or only generic background. RETAIN when the record explicitly evaluates an exposure, impact, interaction, disease risk, genetic interaction, or other consequence of eligible salmon/rainbow-trout aquaculture.",
"",
"7. GENERIC SALMONIDS",
"Strong aquaculture context does NOT rescue a direct study that identifies the relevant fish only as salmonid/salmonids or generic trout. EXCLUDE if no eligible species or explicit salmon-farming context is supplied. This does not apply to studies explicitly about impacts or operation of salmon farming itself.",
"",
"8. PRODUCTS AND PROCESSING",
"Studies of salmon/rainbow-trout food products, processing, storage, fillets, slaughter, or post-harvest quality are eligible only when farmed/commercial-aquaculture origin is explicit in the supplied metadata. Do not infer farmed origin from country, market context, product type, or common industry practice.",
"",
"9. SPECIAL CASES",
"Genetically engineered eligible salmon intended for food production -> RETAIN.",
"Corrections/corrigenda/errata should be screened for relevance to the underlying work; publication-status handling occurs separately.",
"Reports, chapters, conference records, theses, administrative records, and other non-journal material are not excluded merely because of document type if they concern eligible commercial aquaculture.",
"Contents pages, tables of contents, composite records, and collections must be assessed as one coherent record. Do not combine species evidence from one listed item with aquaculture evidence from another.",
"",
"10. DECISION LOGIC",
"RETAIN when the supplied metadata reasonably establish BOTH an eligible species/relevant salmon-farming context AND commercial aquaculture relevance, or when a specific inclusion rule above applies.",
"EXCLUDE only when the supplied metadata clearly establish that an eligibility gate fails, or clearly establish an exclusively wild/restocking/non-commercial context.",
"UNCERTAIN when the metadata are too sparse, incomplete, or contradictory to establish either RETAIN or EXCLUDE. Missing evidence is not negative evidence. In particular, absence of an abstract should not itself cause EXCLUDE.",
"This is a high-sensitivity stage: where the supplied evidence genuinely supports an aquaculture interpretation and exclusion is not clearly justified, favour RETAIN over EXCLUDE. Do not use UNCERTAIN merely because a record is unusual.",
"",
"11. OUTPUT",
"Return decision as exactly retain, exclude, or uncertain, plus one concise reason. The reason must identify the specific species/salmon-farming evidence and aquaculture-context evidence, or state explicitly which eligibility gate clearly failed or why the metadata are insufficient. Do not invent missing metadata.",
sep="\n"
)

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
    model=model,updated_at=now_utc()
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
  prompt_version="2026-09-15-v2",
  completed_at=now_utc()
)
dir.create(dirname(summary_path),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),summary_path)
message(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"))
message("PASS: Workflow 04 R relevance-screening run complete with checkpointed per-record provenance.")

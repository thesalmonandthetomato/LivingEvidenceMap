#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
  library(stringi)
  library(digest)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
canonical_path <- arg("--canonical")
w03_path <- arg("--workflow03-status")
output_dir <- arg("--output-dir","outputs/workflow04_consensus")
model <- arg("--model",Sys.getenv("OPENAI_RELEVANCE_MODEL","gpt-5.6-luna"))
checkpoint_every <- as.integer(arg("--checkpoint-every","25"))
max_records <- as.integer(arg("--max-records","0"))
if(is.null(canonical_path)||is.null(w03_path)) stop("Required: --canonical --workflow03-status",call.=FALSE)
if(!nzchar(Sys.getenv("OPENAI_API_KEY"))) stop("OPENAI_API_KEY is required",call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

`%||%` <- function(x,y) if(is.null(x)) y else x
now_utc <- function() format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
scalar <- function(x){if(is.null(x)||!length(x))return("");z<-as.character(x[[1L]]);if(is.na(z))"" else trimws(z)}
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
"An eligible species mentioned only as an illustrative example, for example in wording such as \"species such as salmon…\", should not by itself establish relevance.",
"",
"However, explicit SALMON FARMING can itself establish the relevant salmon context for studies examining impacts arising from salmon aquaculture, even where the organism actually measured is not an eligible species. Examples: sea trout affected by salmon farming -> RETAIN; lumpfish deployed in salmon farms -> RETAIN; prawns exposed to salmon-farm treatments -> RETAIN; environmental effects of salmon net pens -> RETAIN.",
"",
"2. AQUACULTURE CONTEXT",
"The record must concern commercial/farmed aquaculture, its products, processes, infrastructure, inputs, consequences, impacts, or closely connected research. Evidence can come from any supplied metadata field.",
"",
"Explicit indicators include aquaculture, mariculture, farmed, salmon farm, fish farm, commercial production, aquaculture production, recirculating aquaculture system/RAS, commercial sea cages/net pens, aquaculture feed, farm management, on-farm monitoring, or commercial processing of farmed fish.",
"Where the record explicitly states that the eligible study species is farmed, this is sufficient evidence of farming context.",
"Do not infer that fish are farmed solely from terms such as commercial, commercially, processing, or market. These terms alone do not establish aquaculture origin.",
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
"Studies explicitly concerning salmon lice in an aquaculture context are directly relevant to salmon aquaculture and should be RETAINED, even where the organism studied is the salmon louse or a non-salmon species used in lice control.",
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
"Temporary capture, trapping or holding of fish in rivers or streams for research does not constitute farming or aquaculture.",
"",
"7. WILD POPULATIONS",
"A study of wild eligible salmonids is not automatically relevant.",
"EXCLUDE purely wild-population ecology, genetics, migration, conservation, restocking, or disease surveillance where aquaculture appears only as generic background and the study does not evaluate or meaningfully connect to salmon aquaculture.",
"RETAIN where the wild-population study explicitly evaluates an exposure, impact, interaction, disease risk, genetic interaction or other consequence connected to eligible salmon aquaculture. At this high-sensitivity stage, an explicit and plausible salmon-farming connection should normally favour RETAIN.",
"Studies of wild eligible salmonids may be relevant where salmon farming is itself a substantive exposure, pressure or explanatory factor being investigated.",
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
PROMPT_VERSION <- "workflow04-v3-salmon-lice-clarification"
PROMPT_SHA256 <- digest::digest(SYSTEM_PROMPT,algo="sha256",serialize=FALSE)

EXPECTED_PROMPT_SHA256 <- "ab71cad800996f2aea4cf1313c3ab749017f01094946830671f2f579a4710f69"
if(!identical(PROMPT_SHA256,EXPECTED_PROMPT_SHA256)){
  stop(sprintf("IMMUTABLE PROMPT CHECK FAILED: expected %s got %s",EXPECTED_PROMPT_SHA256,PROMPT_SHA256),call.=FALSE)
}

read_jsonl <- function(path){
  x<-readLines(path,warn=FALSE,encoding="UTF-8");x<-x[nzchar(trimws(x))]
  lapply(seq_along(x),function(i)tryCatch(fromJSON(x[[i]],simplifyVector=FALSE),error=function(e)stop(sprintf("Invalid JSONL %s line %d: %s",path,i,conditionMessage(e)),call.=FALSE)))
}
append_jsonl <- function(x,path){con<-file(path,"at",encoding="UTF-8");on.exit(close(con));writeLines(toJSON(x,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)}
write_jsonl <- function(rows,path){con<-file(path,"wt",encoding="UTF-8");on.exit(close(con));for(x in rows)writeLines(toJSON(x,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)}
textify <- function(x){
  if(is.null(x))return("")
  if(is.character(x))return(paste(x[nzchar(x)],collapse="; "))
  if(is.atomic(x))return(paste(as.character(x),collapse="; "))
  if(is.list(x))return(paste(Filter(nzchar,vapply(x,textify,character(1))),collapse="; "))
  as.character(x)
}
first_nonempty <- function(...){for(x in list(...)){z<-textify(x);if(nzchar(trimws(z)))return(trimws(z))};""}
record_id <- function(r) scalar((r$identity %||% list())$record_id)
canonical <- function(r){x<-r$canonical %||% list();if(is.list(x))x else list()}
record_view <- function(r){
  c<-canonical(r)
  list(
    record_id=record_id(r),
    title=first_nonempty(c$title,r$title),
    abstract=first_nonempty(c$abstract,r$abstract),
    keywords=first_nonempty(c$keywords,r$keywords),
    journal_source_title=first_nonempty(c$source_title,c$journal,r$source_title,r$journal),
    affiliations=first_nonempty(c$affiliations,r$affiliations),
    funding=first_nonempty(c$funding,c$funders,r$funding,r$funders)
  )
}
extract_output_text <- function(resp){
  for(it in resp$output %||% list()) if(is.list(it)&&identical(it$type,"message"))
    for(ct in it$content %||% list()) if(is.list(ct)&&identical(ct$type,"output_text")&&!is.null(ct$text)) return(as.character(ct$text))
  stop("No output_text returned by Responses API")
}
w03_excluded <- function(x){
  isTRUE((x$publication_status %||% list())$exclude_from_workflow04 %||% x$exclude_from_workflow04 %||% FALSE)
}
schema <- list(
  type="object",additionalProperties=FALSE,
  properties=list(decision=list(type="string",enum=list("retain","exclude","uncertain")),reason=list(type="string")),
  required=list("decision","reason")
)
screen_one <- function(r,pass){
  view<-record_view(r)
  tryCatch({
    user_text<-paste0("SCREEN THIS RECORD USING ONLY THE SUPPLIED METADATA.\n\n",toJSON(view,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"))
    body<-list(
      model=model,store=FALSE,reasoning=list(effort="low"),
      input=list(
        list(role="system",content=list(list(type="input_text",text=SYSTEM_PROMPT))),
        list(role="user",content=list(list(type="input_text",text=user_text)))
      ),
      text=list(verbosity="low",format=list(type="json_schema",name="salmon_aquaculture_relevance_screen",strict=TRUE,schema=schema))
    )
    resp<-request("https://api.openai.com/v1/responses") |>
      req_auth_bearer_token(Sys.getenv("OPENAI_API_KEY")) |>
      req_body_json(body,auto_unbox=TRUE) |> req_timeout(120) |>
      req_retry(max_tries=5,backoff=~min(30,2^.x)) |> req_perform() |>
      resp_body_json(simplifyVector=FALSE)
    parsed<-fromJSON(extract_output_text(resp),simplifyVector=FALSE)
    d<-scalar(parsed$decision); rr<-scalar(parsed$reason)
    if(!d %in% c("retain","exclude","uncertain")) stop("Invalid model decision")
    if(!nzchar(rr)) stop("Empty model reason")
    list(
      record_id=record_id(r),pass=pass,decision=d,reason=rr,
      technical_failure=FALSE,error=NULL,model_requested=model,
      model_returned=scalar(resp$model %||% model),response_id=scalar(resp$id),
      usage=resp$usage %||% NULL,prompt_version=PROMPT_VERSION,
      prompt_sha256=PROMPT_SHA256,screened_at=now_utc()
    )
  },error=function(e) list(
    record_id=record_id(r),pass=pass,decision="uncertain",
    reason="Technical screening failure; retry required.",technical_failure=TRUE,
    error=conditionMessage(e),model_requested=model,model_returned=NULL,response_id=NULL,
    usage=NULL,prompt_version=PROMPT_VERSION,prompt_sha256=PROMPT_SHA256,screened_at=now_utc()
  ))
}
run_pass <- function(records,pass,path){
  existing<-if(file.exists(path))read_jsonl(path) else list()
  done<-if(length(existing))vapply(existing,function(x)scalar(x$record_id),character(1)) else character()
  if(anyDuplicated(done))stop(sprintf("Duplicate record IDs in pass %d checkpoint",pass),call.=FALSE)
  ids<-vapply(records,record_id,character(1))
  if(any(!done %in% ids))stop(sprintf("Pass %d checkpoint contains IDs absent from queue",pass),call.=FALSE)
  total<-length(records)
  for(i in seq_along(records)){
    rid<-ids[[i]]
    if(rid %in% done)next
    row<-screen_one(records[[i]],pass)
    append_jsonl(row,path)
    done<-c(done,rid)
    if(length(done)%%checkpoint_every==0L || length(done)==total){
      cat(sprintf("PASS %d checkpoint: %d/%d\n",pass,length(done),total))
    }
  }
  read_jsonl(path)
}

canonical_records<-read_jsonl(canonical_path)
if(length(canonical_records)!=32292L)stop(sprintf("Expected 32,292 canonical records, found %d",length(canonical_records)),call.=FALSE)
cids<-vapply(canonical_records,record_id,character(1))
if(any(!nzchar(cids))||anyDuplicated(cids))stop("Canonical record_id invariant failed",call.=FALSE)

w03<-read_jsonl(w03_path)
wids<-vapply(w03,function(x)scalar(x$record_id),character(1))
if(length(w03)!=32292L||any(!nzchar(wids))||anyDuplicated(wids)||!setequal(cids,wids))stop("Workflow 03 identity invariant failed",call.=FALSE)
wm<-setNames(w03,wids)
eligible_idx<-which(!vapply(cids,function(id)w03_excluded(wm[[id]]),logical(1)))
if(length(eligible_idx)!=32283L)stop(sprintf("Expected 32,283 W03-eligible records, found %d",length(eligible_idx)),call.=FALSE)
eligible<-canonical_records[eligible_idx]
if(max_records>0L) eligible<-eligible[seq_len(min(max_records,length(eligible)))]

p1_path<-file.path(output_dir,"pass1.jsonl")
p2_path<-file.path(output_dir,"pass2.jsonl")
p3_path<-file.path(output_dir,"pass3_conflicts.jsonl")

p1<-run_pass(eligible,1L,p1_path)
p2<-run_pass(eligible,2L,p2_path)

map_dec<-function(rows)setNames(vapply(rows,function(x)scalar(x$decision),character(1)),vapply(rows,function(x)scalar(x$record_id),character(1)))
map_fail<-function(rows)setNames(vapply(rows,function(x)isTRUE(x$technical_failure),logical(1)),vapply(rows,function(x)scalar(x$record_id),character(1)))
d1<-map_dec(p1);d2<-map_dec(p2);f1<-map_fail(p1);f2<-map_fail(p2)
ids<-vapply(eligible,record_id,character(1))
if(!setequal(names(d1),ids)||!setequal(names(d2),ids))stop("Pass 1/2 coverage invariant failed",call.=FALSE)

# Any disagreement, UNCERTAIN, or technical failure gets a third vote.
need3<-ids[(d1[ids]!=d2[ids]) | d1[ids]=="uncertain" | d2[ids]=="uncertain" | f1[ids] | f2[ids]]
queue3<-eligible[match(need3,ids)]
p3<-if(length(queue3))run_pass(queue3,3L,p3_path) else list()
d3<-if(length(p3))map_dec(p3) else character()
f3<-if(length(p3))map_fail(p3) else logical()

final<-vector("list",length(ids))
for(i in seq_along(ids)){
  id<-ids[[i]]
  votes<-c(d1[[id]],d2[[id]])
  failures<-c(f1[[id]],f2[[id]])
  if(id %in% need3){votes<-c(votes,d3[[id]]);failures<-c(failures,f3[[id]])}
  substantive<-votes[!failures & votes %in% c("retain","exclude")]
  nr<-sum(substantive=="retain"); ne<-sum(substantive=="exclude")
  decision<-if(nr>=2L)"retain" else if(ne>=2L)"exclude" else "uncertain"
  final[[i]]<-list(
    record_id=id,
    screening=list(
      decision=decision,
      decision_origin="luna_consensus",
      votes=as.list(votes),
      vote_count=length(votes),
      retain_votes=nr,
      exclude_votes=ne,
      agreement=if(length(votes)==2L && length(unique(votes))==1L && !any(failures))"2_of_2" else if(decision %in% c("retain","exclude"))"2_of_3" else "unresolved",
      requires_human_review=identical(decision,"uncertain"),
      technical_failure_present=any(failures),
      model=model,prompt_version=PROMPT_VERSION,prompt_sha256=PROMPT_SHA256
    )
  )
}
write_jsonl(final,file.path(output_dir,"workflow04_consensus_layer.jsonl"))
final_dec<-vapply(final,function(x)scalar(x$screening$decision),character(1))
summary<-list(
  schema="living-evidence-map-workflow04-luna-consensus-v1",
  status=if(any(final_dec=="uncertain"))"HUMAN_REVIEW_REQUIRED" else "PASS",
  canonical_records=length(canonical_records),
  workflow03_excluded=length(canonical_records)-length(eligible_idx),
  workflow03_eligible=length(eligible_idx),
  records_screened=length(eligible),
  pass1_records=length(p1),pass2_records=length(p2),
  third_pass_records=length(need3),
  two_of_two_agreement=length(ids)-length(need3),
  final_retain=sum(final_dec=="retain"),
  final_exclude=sum(final_dec=="exclude"),
  final_unresolved=sum(final_dec=="uncertain"),
  model=model,prompt_version=PROMPT_VERSION,prompt_sha256=PROMPT_SHA256,
  prompt_immutable_check=TRUE,
  created_at_utc=now_utc()
)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),file.path(output_dir,"summary.json"),useBytes=TRUE)
cat(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),"\n")

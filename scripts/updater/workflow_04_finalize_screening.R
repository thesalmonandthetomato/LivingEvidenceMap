#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(jsonlite))

args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
canonical_path<-arg("--canonical")
consensus_path<-arg("--consensus")
historical_path<-arg("--historical")
terra_path<-arg("--terra")
output_dir<-arg("--output-dir","outputs/workflow04_final")
if(any(vapply(list(canonical_path,consensus_path,historical_path,terra_path),is.null,logical(1))))stop("Required: --canonical --consensus --historical --terra",call.=FALSE)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

`%||%`<-function(x,y)if(is.null(x))y else x
scalar<-function(x){if(is.null(x)||!length(x))return("");z<-as.character(x[[1L]]);if(is.na(z))"" else trimws(z)}
now_utc<-function()format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
read_jsonl<-function(path){x<-readLines(path,warn=FALSE,encoding="UTF-8");x<-x[nzchar(trimws(x))];lapply(seq_along(x),function(i)fromJSON(x[[i]],simplifyVector=FALSE))}
write_jsonl<-function(rows,path){con<-file(path,"wt",encoding="UTF-8");on.exit(close(con));for(x in rows)writeLines(toJSON(x,auto_unbox=TRUE,null="null",na="null",digits=NA),con,useBytes=TRUE)}
rid_canonical<-function(r)scalar((r$identity %||% list())$record_id)
rid_layer<-function(r)scalar(r$record_id)

canonical<-read_jsonl(canonical_path)
consensus<-read_jsonl(consensus_path)
historical<-read_jsonl(historical_path)
terra<-read_jsonl(terra_path)

if(length(canonical)!=32292L)stop(sprintf("Expected 32,292 canonical records, found %d",length(canonical)),call.=FALSE)
if(length(consensus)!=32283L)stop(sprintf("Expected 32,283 W04 consensus records, found %d",length(consensus)),call.=FALSE)
if(length(historical)!=22198L)stop(sprintf("Expected 22,198 safe historical decisions, found %d",length(historical)),call.=FALSE)
if(length(terra)!=443L)stop(sprintf("Expected 443 one-off Terra adjudications, found %d",length(terra)),call.=FALSE)

can_ids<-vapply(canonical,rid_canonical,character(1))
con_ids<-vapply(consensus,rid_layer,character(1))
hist_ids<-vapply(historical,rid_layer,character(1))
terra_ids<-vapply(terra,rid_layer,character(1))
for(z in list(can_ids,con_ids,hist_ids,terra_ids))if(any(!nzchar(z))||anyDuplicated(z))stop("record_id uniqueness invariant failed",call.=FALSE)
if(any(!con_ids%in%can_ids))stop("Consensus contains IDs absent from canonical",call.=FALSE)

hist_map<-setNames(historical,hist_ids)
terra_map<-setNames(terra,terra_ids)
can_map<-setNames(canonical,can_ids)
hist_dec<-vapply(historical,function(x)scalar((x$screening %||% list())$decision),character(1))
if(any(!hist_dec%in%c("retain","exclude")))stop("Safe historical layer contains non-substantive decisions",call.=FALSE)
safe_hist_exclude_ids<-hist_ids[hist_dec=="exclude"]

cons_dec<-vapply(consensus,function(x)scalar((x$screening %||% list())$decision),character(1))
unresolved_ids<-con_ids[cons_dec=="uncertain"]
if(length(unresolved_ids)!=691L)stop(sprintf("Expected 691 Luna unresolved records, found %d",length(unresolved_ids)),call.=FALSE)

hist_unresolved<-intersect(unresolved_ids,hist_ids)
terra_expected<-setdiff(unresolved_ids,hist_unresolved)
if(length(hist_unresolved)!=248L)stop(sprintf("Expected 248 safe historical fallbacks, found %d",length(hist_unresolved)),call.=FALSE)
if(length(terra_expected)!=443L||!setequal(terra_expected,terra_ids))stop("Terra queue does not exactly match unresolved records lacking safe historical decisions",call.=FALSE)

terra_dec<-vapply(terra,function(x)scalar(x$decision),character(1))
if(sum(terra_dec=="retain")!=41L||sum(terra_dec=="exclude")!=148L||sum(terra_dec=="uncertain")!=254L)stop("Unexpected Terra decision totals",call.=FALSE)
if(any(vapply(terra,function(x)isTRUE(x$technical_failure),logical(1))))stop("Terra technical failures present; refusing finalisation",call.=FALSE)

final<-vector("list",length(consensus))
route<-character(length(consensus))
for(i in seq_along(consensus)){
  row<-consensus[[i]]
  id<-rid_layer(row)
  luna<-row$screening %||% list()
  d<-scalar(luna$decision)
  if(id%in%safe_hist_exclude_ids){
    h<-hist_map[[id]]
    row$screening<-list(
      decision="exclude",
      decision_origin="historical_exclude_authoritative",
      requires_human_review=FALSE,
      luna_consensus=luna,
      historical_screening=h$screening %||% NULL,
      historical_override_applied=identical(d,"retain")
    )
    route[[i]]<-"historical_exclude_authoritative"
  } else if(d%in%c("retain","exclude")){
    row$screening$decision_origin="luna_consensus"
    row$screening$requires_human_review=FALSE
    route[[i]]<-"luna_consensus"
  } else if(id%in%hist_unresolved){
    h<-hist_map[[id]]
    hd<-scalar((h$screening %||% list())$decision)
    if(!hd%in%c("retain","exclude"))stop(sprintf("Historical fallback is not substantive for %s",id),call.=FALSE)
    row$screening<-list(
      decision=hd,
      decision_origin="historical_fallback_after_luna_unresolved",
      requires_human_review=FALSE,
      luna_consensus=luna,
      historical_screening=h$screening %||% NULL
    )
    route[[i]]<-"historical_fallback"
  } else {
    t<-terra_map[[id]]
    td<-scalar(t$decision)
    if(td%in%c("retain","exclude")){
      row$screening<-list(
        decision=td,
        decision_origin="terra_oneoff_adjudication_after_luna_unresolved",
        requires_human_review=FALSE,
        luna_consensus=luna,
        terra_adjudication=t
      )
      route[[i]]<-"terra_oneoff"
    } else if(td=="uncertain"){
      row$screening<-list(
        decision="exclude",
        decision_origin="human_rule_adjudication_after_luna_terra_uncertain",
        requires_human_review=FALSE,
        luna_consensus=luna,
        terra_adjudication=t,
        human_rule_adjudication=list(
          decision="exclude",
          basis="Bulk exclusion approved after audit of all 254 residual records: supplied bibliographic metadata did not establish both an eligible species/relevant salmon-farming context and commercial aquaculture relevance under the immutable Workflow 04 eligibility rules.",
          adjudicated_record_set_size=254L,
          adjudicated_at_utc=now_utc()
        )
      )
      route[[i]]<-"human_rule_bulk_exclude"
    } else stop(sprintf("Invalid Terra decision for %s",id),call.=FALSE)
  }
  final[[i]]<-row
}

final_dec<-vapply(final,function(x)scalar((x$screening %||% list())$decision),character(1))
if(any(!final_dec%in%c("retain","exclude")))stop("Final layer contains non-substantive decisions",call.=FALSE)
historical_exclude_overrides<-sum(con_ids%in%safe_hist_exclude_ids & cons_dec=="retain")
if(historical_exclude_overrides!=344L)stop(sprintf("Expected 344 historical EXCLUDE overrides of Luna RETAIN, found %d",historical_exclude_overrides),call.=FALSE)
if(sum(final_dec=="retain")!=19407L)stop(sprintf("Expected 19,407 final retains, found %d",sum(final_dec=="retain")),call.=FALSE)
if(sum(final_dec=="exclude")!=12876L)stop(sprintf("Expected 12,876 final excludes, found %d",sum(final_dec=="exclude")),call.=FALSE)
if(length(final)!=32283L||anyDuplicated(vapply(final,rid_layer,character(1))))stop("Final layer coverage invariant failed",call.=FALSE)

write_jsonl(final,file.path(output_dir,"workflow04_final_screening_layer.jsonl"))
included_ids<-vapply(final[final_dec=="retain"],rid_layer,character(1))
excluded_ids<-vapply(final[final_dec=="exclude"],rid_layer,character(1))
writeLines(included_ids,file.path(output_dir,"workflow04_included_record_ids.txt"),useBytes=TRUE)
writeLines(excluded_ids,file.path(output_dir,"workflow04_excluded_record_ids.txt"),useBytes=TRUE)
included_canonical<-unname(can_map[included_ids])
write_jsonl(included_canonical,file.path(output_dir,"workflow04_included_canonical.jsonl"))

summary<-list(
  schema="living-evidence-map-workflow04-final-screening-v2",
  status="PASS",
  source_luna_consensus_run=36221408684,
  source_terra_oneoff_run=36225691899,
  workflow03_eligible=32283L,
  final_retain=19407L,
  final_exclude=12876L,
  inclusion_rate=19407/32283,
  historical_exclude_overrides_of_luna_retain=historical_exclude_overrides,
  unresolved=0L,
  decision_routes=list(
    luna_consensus=sum(route=="luna_consensus"),
    historical_exclude_authoritative=sum(route=="historical_exclude_authoritative"),
    historical_fallback=sum(route=="historical_fallback"),
    terra_oneoff=sum(route=="terra_oneoff"),
    human_rule_bulk_exclude=sum(route=="human_rule_bulk_exclude")
  ),
  historical_exclude_authoritative=list(
    total=sum(route=="historical_exclude_authoritative"),
    overrode_luna_retain=sum(route=="historical_exclude_authoritative"&cons_dec=="retain"),
    agreed_with_luna_exclude=sum(route=="historical_exclude_authoritative"&cons_dec=="exclude"),
    resolved_luna_uncertain=sum(route=="historical_exclude_authoritative"&cons_dec=="uncertain")
  ),
  historical_fallback=list(
    total=sum(route=="historical_fallback"),
    retain=sum(route=="historical_fallback"&final_dec=="retain"),
    exclude=sum(route=="historical_fallback"&final_dec=="exclude")
  ),
  terra_oneoff=list(
    total=sum(route=="terra_oneoff"),
    retain=sum(route=="terra_oneoff"&final_dec=="retain"),
    exclude=sum(route=="terra_oneoff"&final_dec=="exclude")
  ),
  human_rule_bulk_exclude=list(total=sum(route=="human_rule_bulk_exclude"),exclude=sum(route=="human_rule_bulk_exclude"&final_dec=="exclude")),
  created_at_utc=now_utc()
)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null",na="null",digits=NA),file.path(output_dir,"summary.json"),useBytes=TRUE)
cat(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null",na="null",digits=NA),"\n")

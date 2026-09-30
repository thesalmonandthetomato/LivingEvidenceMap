#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(jsonlite);library(readr);library(digest)})
args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
canonical_path<-arg("--canonical");w03_path<-arg("--w03");w04_path<-arg("--w04");w05_path<-arg("--w05");w05_matches_path<-arg("--w05-matches");w06_path<-arg("--w06");w07_scores_path<-arg("--w07-scores");w07_qc_path<-arg("--w07-qc");w07_late_path<-arg("--w07-late-exclusions");decisions_path<-arg("--decisions");ontology_path<-arg("--ontology");out_path<-arg("--output");ledger_path<-arg("--ledger");manifest_path<-arg("--manifest")
req<-c(canonical_path,w03_path,w04_path,w05_path,w05_matches_path,w06_path,w07_scores_path,w07_qc_path,w07_late_path,decisions_path,ontology_path,out_path,ledger_path,manifest_path)
if(any(is.na(req)|!nzchar(req)))stop("Missing required Workflow 08 finalisation argument",call.=FALSE)
`%||%`<-function(x,y)if(is.null(x)||length(x)==0L)y else x
clean<-function(x){z<-as.character(x%||%"");if(length(z)==0L||is.na(z[[1L]]))"" else z[[1L]]}
splitsemi<-function(x){z<-trimws(strsplit(clean(x),";",fixed=TRUE)[[1]]);z[nzchar(z)]}
read_jsonl<-function(path){x<-readLines(path,warn=FALSE,encoding="UTF-8");x<-x[nzchar(trimws(x))];lapply(x,fromJSON,simplifyVector=FALSE)}
index_jsonl<-function(x,keyfun){k<-vapply(x,keyfun,character(1));if(any(!nzchar(k))||anyDuplicated(k))stop("Invalid/duplicate JSONL keys",call.=FALSE);setNames(x,k)}

w03<-index_jsonl(read_jsonl(w03_path),function(z)clean(z$record_id));w04<-index_jsonl(read_jsonl(w04_path),function(z)clean(z$record_id))
w05<-read_csv(w05_path,show_col_types=FALSE,progress=FALSE);w05_matches<-read_csv(w05_matches_path,show_col_types=FALSE,progress=FALSE);w06<-read_csv(w06_path,show_col_types=FALSE,progress=FALSE);scores<-read_csv(w07_scores_path,show_col_types=FALSE,progress=FALSE);w07_qc<-read_csv(w07_qc_path,show_col_types=FALSE,progress=FALSE);late<-read_csv(w07_late_path,show_col_types=FALSE,progress=FALSE);onto<-read_csv(ontology_path,show_col_types=FALSE,progress=FALSE);decisions<-read_jsonl(decisions_path)
if(anyDuplicated(w05$record_id)||anyDuplicated(w06$record_id)||anyDuplicated(w07_qc$record_id)||anyDuplicated(late$record_id))stop("Duplicate record ID in W05-W07 record-level inputs",call.=FALSE)

dkeys<-vapply(decisions,function(z)clean(z$review_key),character(1));if(anyDuplicated(dkeys))stop("Duplicate W08 review key",call.=FALSE);dmap<-setNames(decisions,dkeys)
by_type<-function(t)Filter(function(z)identical(clean(z$issue_type),t),decisions)
species_dec<-by_type("species_none");geo_dec<-c(by_type("geography_unresolved"),by_type("geography_evidence_unvalidated"));topic_dec<-by_type("topic_extreme_disagreement");zero_dec<-by_type("zero_topic_eligibility_uncertain")
species_map<-setNames(species_dec,vapply(species_dec,function(z)clean(z$record_id),character(1)));geo_map<-setNames(geo_dec,vapply(geo_dec,function(z)clean(z$record_id),character(1)));topic_map<-setNames(topic_dec,vapply(topic_dec,function(z)clean(z$record_id),character(1)));zero_map<-setNames(zero_dec,vapply(zero_dec,function(z)clean(z$record_id),character(1)))
w05i<-setNames(seq_len(nrow(w05)),as.character(w05$record_id));w06i<-setNames(seq_len(nrow(w06)),as.character(w06$record_id));w07qci<-setNames(seq_len(nrow(w07_qc)),as.character(w07_qc$record_id));late_ids<-unique(as.character(late$record_id))

canonical_ids<-vapply(read_jsonl(canonical_path),function(z)clean((z$identity%||%list())$record_id),character(1))
if(any(!nzchar(canonical_ids))||anyDuplicated(canonical_ids))stop("Canonical identity invariant failed",call.=FALSE)
if(!setequal(names(w03),canonical_ids))stop("W03 population does not match canonical population",call.=FALSE)
w03_eligible_ids<-canonical_ids[!vapply(canonical_ids,function(id)isTRUE((w03[[id]]$publication_status%||%list())$exclude_from_workflow04),logical(1))]
if(!setequal(names(w04),w03_eligible_ids))stop("W04 population does not match W03-eligible population",call.=FALSE)
w04_retained_ids<-names(w04)[vapply(w04,function(z)identical(clean((z$screening%||%list())$decision),"retain"),logical(1))]
if(!setequal(as.character(w05$record_id),w04_retained_ids)||!setequal(as.character(w06$record_id),w04_retained_ids)||!setequal(as.character(w07_qc$record_id),w04_retained_ids))stop("W05/W06/W07 populations do not match W04-retained population",call.=FALSE)
if(length(setdiff(late_ids,w04_retained_ids)))stop("W07 late exclusions contain IDs outside W04-retained population",call.=FALSE)
if(length(setdiff(vapply(decisions,function(z)clean(z$record_id),character(1)),w04_retained_ids)))stop("W08 decisions contain IDs outside W04-retained population",call.=FALSE)

w05_match_split<-split(seq_len(nrow(w05_matches)),as.character(w05_matches$record_id))
ret<-scores[scores$retained_for_analysis%in%TRUE,,drop=FALSE];ret_split<-split(seq_len(nrow(ret)),as.character(ret$record_id));onto_i<-setNames(seq_len(nrow(onto)),as.character(onto$path_id))
score_key<-paste(as.character(ret$record_id),as.character(ret$path_id),sep="\r");if(anyDuplicated(score_key))stop("Duplicate retained W07 record/path score",call.=FALSE);score_i<-setNames(seq_len(nrow(ret)),score_key)
code_for_label<-c("Atlantic salmon"="SAL_SALAR","Rainbow trout"="ONC_MYKISS","Chinook salmon"="ONC_TSHAWYTSCHA","Coho salmon"="ONC_KISUTCH","Sockeye salmon"="ONC_NERKA","Chum salmon"="ONC_KETA","Pink salmon"="ONC_GORBUSCHA","Masu salmon"="ONC_MASOU","Unspecified species"="UNSPEC_SALMON")
country_names<-c(CAN="Canada",BIH="Bosnia and Herzegovina",DNK="Denmark",FIN="Finland",ISL="Iceland",NOR="Norway",SWE="Sweden",FRA="France",CHL="Chile",IRL="Ireland",FRO="Faroe Islands")
row_payload<-function(df,i,drop=character()){if(is.null(i)||!length(i))return(NULL);z<-as.list(df[i[[1L]],setdiff(names(df),drop),drop=FALSE]);lapply(z,function(v){if(length(v)==0L||is.na(v[[1L]]))NULL else v[[1L]]})}
rows_payload<-function(df,idx,drop=character()){if(is.null(idx)||!length(idx))return(list());lapply(idx,function(i)row_payload(df,i,drop))}
score_payload<-function(rid,pid){i<-score_i[[paste(rid,pid,sep="\r")]];if(is.null(i))return(NULL);row_payload(ret,i,drop=c("record_id","path_id","hierarchy_path"))}
topic_items<-function(ids,source,rid){ids<-unique(as.character(ids));ids<-ids[nzchar(ids)];lapply(ids,function(pid){oi<-onto_i[[pid]];if(is.null(oi))stop("Unknown topic path: ",pid,call.=FALSE);list(path_id=pid,hierarchy_path=clean(onto$hierarchy_path[[oi]]),level_1=clean(onto$level_1[[oi]]),level_2=clean(onto$level_2[[oi]]),source=source,workflow07_score=score_payload(rid,pid))})}

# Write a clean machine-readable copy of the complete W08 decisions as the adjudication ledger.
dir.create(dirname(ledger_path),recursive=TRUE,showWarnings=FALSE);file.copy(decisions_path,ledger_path,overwrite=TRUE)

out<-file(out_path,"wt",encoding="UTF-8");on.exit(close(out),add=TRUE);can<-file(canonical_path,"rt",encoding="UTF-8");on.exit(close(can),add=TRUE)
n<-0L;included<-0L;excluded<-0L;exc_counts<-c(workflow03=0L,workflow04=0L,workflow07_late=0L,workflow08=0L);included_uncoded<-0L;topic_assignments<-0L;species_overrides<-0L;geo_overrides<-0L;topic_overrides<-0L;seen<-character()
repeat{
 ln<-readLines(can,n=1L,warn=FALSE);if(!length(ln))break;if(!nzchar(trimws(ln)))next
 rec<-fromJSON(ln,simplifyVector=FALSE);incoming_rec<-rec;rid<-clean((rec$identity%||%list())$record_id);if(!nzchar(rid)||rid%in%seen)stop("Invalid/duplicate canonical record_id",call.=FALSE);seen<-c(seen,rid);n<-n+1L
 ps<-(w03[[rid]]$publication_status)%||%list();ps_excl<-isTRUE(ps$exclude_from_workflow04)
 screening<-list(status="included",final_included=TRUE,exclusion_stage=NULL,exclusion_reason=NULL,workflow03_publication_status=clean(ps$code),workflow04=NULL,workflow07_late_automatic_exclusion=FALSE,workflow08_exclusion=FALSE)
 if(ps_excl){screening$status<-"excluded";screening$final_included<-FALSE;screening$exclusion_stage<-"workflow03";screening$exclusion_reason<-paste0("publication_status:",clean(ps$code));exc_counts[["workflow03"]]<-exc_counts[["workflow03"]]+1L}
 else {w4<-w04[[rid]];if(is.null(w4))stop("W03-eligible record absent from W04: ",rid,call.=FALSE);screening$workflow04<-w4$screening;if(identical(clean(w4$screening$decision),"exclude")){screening$status<-"excluded";screening$final_included<-FALSE;screening$exclusion_stage<-"workflow04";screening$exclusion_reason<-"workflow04_relevance_screening";exc_counts[["workflow04"]]<-exc_counts[["workflow04"]]+1L}}
 species<-list(status="not_coded",codes=character(),labels=character(),source=NULL,workflow05=NULL,matches=list(),workflow08_adjudication=NULL);geography<-list(status="not_coded",iso3c=character(),country_names=character(),evidence=NULL,reason=NULL,source=NULL,workflow06=NULL,workflow06_pre_recovery=NULL,workflow06_recovery=list(),workflow08_prebaseline_adjudication=NULL,workflow08_adjudication=NULL);topics<-list(status="not_coded",assignments=list(),path_ids=character(),source=NULL,workflow07_assignments=list(),workflow07_record_qc=NULL,workflow08_adjudication=NULL,zero_topic_adjudication=NULL)
 if(!ps_excl&&!is.null(w04[[rid]])&&identical(clean(w04[[rid]]$screening$decision),"retain")){
  i5<-w05i[[rid]];i6<-w06i[[rid]];if(is.null(i5)||is.null(i6))stop("W04-retained record absent from W05/W06: ",rid,call.=FALSE)
  scodes<-splitsemi(w05$farmed_species_codes[[i5]]);slabs<-splitsemi(w05$farmed_species[[i5]]);species<-list(status=if(length(scodes)&&!identical(scodes,"NONE"))"coded" else "unresolved",codes=scodes,labels=slabs,source="workflow05",workflow05=row_payload(w05,i5,drop=c("record_id","title","abstract")),matches=rows_payload(w05_matches,w05_match_split[[rid]],drop=c("record_id")),workflow08_adjudication=NULL)
  sd<-species_map[[rid]];if(!is.null(sd)){fv<-sd$final_value;if(identical(sd$decision,"exclude_record")){screening$status<-"excluded";screening$final_included<-FALSE;screening$exclusion_stage<-"workflow08";screening$exclusion_reason<-"species_none_human_exclusion";screening$workflow08_exclusion<-TRUE}else{labs<-as.character(fv$farmed_species%||%fv$species_labels%||%character());labs<-labs[nzchar(labs)];codes<-unname(code_for_label[labs]);if(any(is.na(codes)))stop("Unknown W08 species label: ",rid,call.=FALSE);species$status<-"coded";species$codes<-codes;species$labels<-labs;species$source<-"workflow08_human";species$workflow08_adjudication<-sd;species_overrides<-species_overrides+1L}}
  z6<-w06[i6,,drop=FALSE];gst<-clean(z6$geography_status);geography<-list(status=gst,iso3c=if(gst=="RESOLVED")splitsemi(z6$luna_iso3c)else character(),country_names=if(gst=="RESOLVED")splitsemi(z6$luna_country_names)else character(),evidence=clean(z6$luna_evidence),reason=clean(z6$geography_reason),source="workflow06",workflow06=row_payload(w06,i6,drop=c("record_id","title","abstract")),workflow08_adjudication=NULL)
  gd<-geo_map[[rid]];if(!is.null(gd)){fv<-gd$final_value;gst<-clean(fv$geography_status);geography$status<-gst;geography$iso3c<-as.character(fv$iso3c%||%character());geography$country_names<-as.character(fv$country_names%||%character());geography$evidence<-NULL;geography$reason<-clean(gd$rationale);geography$source<-"workflow08_human";geography$workflow08_adjudication<-gd;geo_overrides<-geo_overrides+1L}
  ids<-character();idx<-ret_split[[rid]];if(!is.null(idx))ids<-as.character(ret$path_id[idx]);qci<-w07qci[[rid]];topics<-list(status=if(length(ids))"coded" else "uncoded",assignments=topic_items(ids,"workflow07",rid),path_ids=ids,source="workflow07",workflow07_assignments=rows_payload(ret,idx,drop=character()),workflow07_record_qc=row_payload(w07_qc,qci,drop=c("record_id")),workflow08_adjudication=NULL,zero_topic_adjudication=NULL)
  td<-topic_map[[rid]];if(!is.null(td)){fv<-td$final_value;if(isFALSE(fv$included)){screening$status<-"excluded";screening$final_included<-FALSE;screening$exclusion_stage<-"workflow08";screening$exclusion_reason<-"topic_human_exclusion";screening$workflow08_exclusion<-TRUE}else{ids<-as.character(fv$path_ids%||%character());topics$status<-if(length(ids))"coded" else "uncoded";topics$assignments<-topic_items(ids,"workflow08_human",rid);topics$path_ids<-ids;topics$source<-"workflow08_human";topics$workflow08_adjudication<-td;if(identical(td$decision,"no_code"))topics$status<-"included_uncoded";topic_overrides<-topic_overrides+1L}}
  zd<-zero_map[[rid]];if(!is.null(zd)){fv<-zd$final_value;if(isFALSE(fv$included)){screening$status<-"excluded";screening$final_included<-FALSE;screening$exclusion_stage<-"workflow08";screening$exclusion_reason<-"zero_topic_human_exclusion";screening$workflow08_exclusion<-TRUE}else{topics$status<-"included_uncoded";topics$assignments<-list();topics$path_ids<-character();topics$source<-"workflow08_human";topics$zero_topic_adjudication<-zd}}
  if(rid%in%late_ids&&isTRUE(screening$final_included)){screening$status<-"excluded";screening$final_included<-FALSE;screening$exclusion_stage<-"workflow07_late";screening$exclusion_reason<-"zero_topic_targeted_rescreen_exclude";screening$workflow07_late_automatic_exclusion<-TRUE;exc_counts[["workflow07_late"]]<-exc_counts[["workflow07_late"]]+1L}
  if(!isTRUE(screening$final_included)&&identical(screening$exclusion_stage,"workflow08"))exc_counts[["workflow08"]]<-exc_counts[["workflow08"]]+1L
 }
 if(isTRUE(screening$final_included)){included<-included+1L;if(topics$status%in%c("uncoded","included_uncoded"))included_uncoded<-included_uncoded+1L;topic_assignments<-topic_assignments+length(topics$path_ids)}else excluded<-excluded+1L
 rec$publication_status<-ps;rec$screening<-screening;rec$species<-species;rec$geography<-geography;rec$topics<-topics;rec$provenance$workflow08<-list(status="final",decision_ledger_sha256=digest(file=decisions_path,algo="sha256",serialize=FALSE),finalised_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ"))
 protected_keys<-setdiff(names(incoming_rec),c("publication_status","screening","species","geography","topics","provenance"))
 for(k in protected_keys){
   a<-toJSON(incoming_rec[[k]],auto_unbox=TRUE,null="null",na="null",digits=NA)
   b<-toJSON(rec[[k]],auto_unbox=TRUE,null="null",na="null",digits=NA)
   if(!identical(a,b))stop(sprintf("W08 schema preservation failed for %s field %s",rid,k),call.=FALSE)
 }
 if(!is.null(incoming_rec$provenance)){
   p0<-incoming_rec$provenance;p1<-rec$provenance;p1$workflow08<-NULL
   if(!identical(toJSON(p0,auto_unbox=TRUE,null="null",na="null",digits=NA),toJSON(p1,auto_unbox=TRUE,null="null",na="null",digits=NA)))stop(sprintf("W08 provenance preservation failed for %s",rid),call.=FALSE)
 }
 writeLines(toJSON(rec,auto_unbox=TRUE,null="null",na="null",digits=NA),out,useBytes=TRUE)
}
close(can);on.exit(NULL,add=FALSE);close(out);on.exit(NULL,add=FALSE)
if(n!=length(canonical_ids)||included+excluded!=n)stop("Final canonical population invariant failed",call.=FALSE)
if(sum(exc_counts)!=excluded)stop(sprintf("Exclusion accounting mismatch: stages=%d excluded=%d",sum(exc_counts),excluded),call.=FALSE)
manifest<-list(schema="living-evidence-map-workflow08-final-v3",status="PASS",canonical_schema_version="living-evidence-map-canonical-v1",annotation_preservation="lossless-upstream-handoff-v2",canonical_records=n,final_included_records=included,final_excluded_records=excluded,exclusions_by_stage=as.list(exc_counts),included_uncoded_topic_records=included_uncoded,final_topic_assignments=topic_assignments,w08_decision_issues=length(decisions),w08_unique_review_records=length(unique(vapply(decisions,function(z)clean(z$record_id),character(1)))),species_overrides=species_overrides,geography_human_overrides=geo_overrides,topic_human_overrides=topic_overrides,source_counts=list(workflow03=length(w03),workflow04=length(w04),workflow05=nrow(w05),workflow06=nrow(w06),workflow07_late_exclusions=nrow(late)),source_sha256=list(canonical_input=digest(file=canonical_path,algo="sha256",serialize=FALSE),workflow03=digest(file=w03_path,algo="sha256",serialize=FALSE),workflow04=digest(file=w04_path,algo="sha256",serialize=FALSE),workflow05=digest(file=w05_path,algo="sha256",serialize=FALSE),workflow06=digest(file=w06_path,algo="sha256",serialize=FALSE),workflow07_scores=digest(file=w07_scores_path,algo="sha256",serialize=FALSE),workflow08_decisions=digest(file=decisions_path,algo="sha256",serialize=FALSE),ontology=digest(file=ontology_path,algo="sha256",serialize=FALSE)),final_canonical_jsonl_sha256=digest(file=out_path,algo="sha256",serialize=FALSE),final_canonical_jsonl_bytes=unname(file.info(out_path)$size),adjudication_ledger_sha256=digest(file=ledger_path,algo="sha256",serialize=FALSE),generated_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ"))
writeLines(toJSON(manifest,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),manifest_path,useBytes=TRUE)
cat(sprintf("PASS: final W08 canonical: %d included / %d excluded / %d total; SHA256=%s\n",included,excluded,n,manifest$final_canonical_jsonl_sha256))

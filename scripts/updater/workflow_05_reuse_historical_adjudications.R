#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(dplyr);library(readr);library(jsonlite);library(fs)})

args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){i<-match(flag,args);if(is.na(i))return(default);if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE);args[[i+1L]]}
canonical_path<-arg("--canonical")
queue_path<-arg("--queue")
state_path<-arg("--deterministic-state")
historical_path<-arg("--historical")
output_dir<-arg("--output-dir","outputs/workflow05/inheritance")
if(any(vapply(list(canonical_path,queue_path,state_path,historical_path),is.null,logical(1))))stop("Required: --canonical --queue --deterministic-state --historical",call.=FALSE)
for(p in c(canonical_path,queue_path,state_path,historical_path))if(!file.exists(p))stop(sprintf("Input not found: %s",p),call.=FALSE)
dir_create(output_dir,recurse=TRUE)

`%||%`<-function(x,y)if(is.null(x))y else x
clean<-function(x){x<-as.character(x);x[is.na(x)]<-"";trimws(x)}
bool<-function(x)tolower(clean(x))%in%c("true","t","1","yes")
norm_set<-function(x){
 z<-clean(x);if(!nzchar(z))return("")
 vals<-trimws(unlist(strsplit(z,";",fixed=TRUE)));vals<-vals[nzchar(vals)]
 paste(sort(unique(vals)),collapse="; ")
}
norm_text<-function(x)gsub("\\s+"," ",clean(x))

read_jsonl<-function(path){
 lines<-readLines(path,warn=FALSE,encoding="UTF-8");lines<-lines[nzchar(trimws(lines))]
 lapply(lines,function(z)fromJSON(z,simplifyVector=FALSE))
}
canonical<-read_jsonl(canonical_path)
lens_rows<-list();k<-0L
for(r in canonical){
 rid<-clean((r$identity%||%list())$record_id)
 refs<-unlist(r$manifestation_refs%||%list(),use.names=FALSE)
 lens<-sub("^lens:","",refs[grepl("^lens:",refs,ignore.case=TRUE)])
 if(length(lens))for(x in lens){k<-k+1L;lens_rows[[k]]<-data.frame(historical_record_id=x,record_id=rid,stringsAsFactors=FALSE)}
}
lens_map<-if(length(lens_rows))bind_rows(lens_rows) else tibble(historical_record_id=character(),record_id=character())
if(anyDuplicated(lens_map$historical_record_id))stop("A Lens manifestation maps to more than one current canonical work",call.=FALSE)

queue<-read_csv(queue_path,show_col_types=FALSE,progress=FALSE)
state<-read_csv(state_path,show_col_types=FALSE,progress=FALSE)
hist<-read_csv(historical_path,show_col_types=FALSE,progress=FALSE)
required_hist<-c("record_id","deterministic_species","deterministic_species_ids","species_review_required","species_assignment_reason","non_target_species",
                 "deterministic_primary_countries","deterministic_primary_iso3c","geography_review_required","geography_review_reason",
                 "species_decision","llm_species","species_reason","geography_decision","llm_primary_country_iso3c","geography_reason")
missing<-setdiff(required_hist,names(hist))
if(length(missing))stop("Historical adjudication CSV missing required columns: ",paste(missing,collapse=", "),call.=FALSE)

hist<-hist|>mutate(historical_record_id=as.character(record_id))|>
  select(-record_id)|>left_join(lens_map,by="historical_record_id")|>
  filter(!is.na(record_id),nzchar(record_id))

current<-state|>mutate(record_id=as.character(record_id))
queue_ids<-unique(as.character(queue$record_id))
hist<-hist|>filter(record_id%in%queue_ids)

same_species_state<-function(h,c){
 identical(norm_set(h$deterministic_species),norm_set(c$deterministic_species)) &&
 identical(norm_set(h$deterministic_species_ids),norm_set(c$deterministic_species_ids)) &&
 identical(norm_text(h$species_assignment_reason),norm_text(c$species_assignment_reason)) &&
 identical(norm_set(h$non_target_species),norm_set(c$non_target_species))
}
same_geo_state<-function(h,c){
 identical(norm_set(h$deterministic_primary_countries),norm_set(c$deterministic_primary_countries)) &&
 identical(norm_set(h$deterministic_primary_iso3c),norm_set(c$deterministic_primary_iso3c)) &&
 identical(norm_text(h$geography_review_reason),norm_text(c$geography_review_reason))
}

inherit_rows<-list();audit_rows<-list();ii<-0L;aa<-0L
for(rid in queue_ids){
 c<-current[current$record_id==rid,,drop=FALSE]
 h<-hist[hist$record_id==rid,,drop=FALSE]
 if(nrow(c)!=1L)stop(sprintf("Current deterministic state not unique for %s",rid),call.=FALSE)

 sp_candidates<-h[bool(h$species_review_required)&h$species_decision%in%c("ACCEPT","CHANGE"),,drop=FALSE]
 sp_candidates<-sp_candidates[vapply(seq_len(nrow(sp_candidates)),function(i)same_species_state(sp_candidates[i,,drop=FALSE],c),logical(1)),,drop=FALSE]
 geo_candidates<-h[bool(h$geography_review_required)&h$geography_decision%in%c("ACCEPT","CHANGE"),,drop=FALSE]
 geo_candidates<-geo_candidates[vapply(seq_len(nrow(geo_candidates)),function(i)same_geo_state(geo_candidates[i,,drop=FALSE],c),logical(1)),,drop=FALSE]

 sp_reuse<-FALSE;geo_reuse<-FALSE;sp_conflict<-FALSE;geo_conflict<-FALSE
 sp_dec<-sp_val<-sp_reason<-""
 if(nrow(sp_candidates)){
   keys<-unique(paste(sp_candidates$species_decision,norm_set(sp_candidates$llm_species),norm_text(sp_candidates$species_reason),sep="\t"))
   if(length(keys)==1L){sp_reuse<-TRUE;sp_dec<-sp_candidates$species_decision[[1]];sp_val<-sp_candidates$llm_species[[1]];sp_reason<-sp_candidates$species_reason[[1]]} else sp_conflict<-TRUE
 }
 geo_dec<-geo_val<-geo_reason<-""
 if(nrow(geo_candidates)){
   keys<-unique(paste(geo_candidates$geography_decision,norm_set(geo_candidates$llm_primary_country_iso3c),norm_text(geo_candidates$geography_reason),sep="\t"))
   if(length(keys)==1L){geo_reuse<-TRUE;geo_dec<-geo_candidates$geography_decision[[1]];geo_val<-geo_candidates$llm_primary_country_iso3c[[1]];geo_reason<-geo_candidates$geography_reason[[1]]} else geo_conflict<-TRUE
 }

 if(sp_reuse||geo_reuse){
   ii<-ii+1L
   inherit_rows[[ii]]<-tibble(
     record_id=rid,
     species_decision=if(sp_reuse)sp_dec else "NOT_REVIEWED",
     llm_species=if(sp_reuse)sp_val else "",
     species_reason=if(sp_reuse)sp_reason else "",
     geography_decision=if(geo_reuse)geo_dec else "NOT_REVIEWED",
     llm_primary_country_iso3c=if(geo_reuse)geo_val else "",
     geography_reason=if(geo_reuse)geo_reason else "",
     inherited_species=sp_reuse,inherited_geography=geo_reuse,
     inheritance_source="historical_workflow05_adjudication",
     historical_manifestations=paste(sort(unique(c(sp_candidates$historical_record_id,geo_candidates$historical_record_id))),collapse="; ")
   )
 }
 aa<-aa+1L
 audit_rows[[aa]]<-tibble(record_id=rid,historical_rows=nrow(h),species_reused=sp_reuse,geography_reused=geo_reuse,
                          species_conflict=sp_conflict,geography_conflict=geo_conflict)
}
inherited<-if(length(inherit_rows))bind_rows(inherit_rows) else tibble(
 record_id=character(),species_decision=character(),llm_species=character(),species_reason=character(),
 geography_decision=character(),llm_primary_country_iso3c=character(),geography_reason=character(),
 inherited_species=logical(),inherited_geography=logical(),inheritance_source=character(),historical_manifestations=character())
audit<-bind_rows(audit_rows)

remaining<-queue|>left_join(inherited|>select(record_id,inherited_species,inherited_geography),by="record_id")|>
 mutate(inherited_species=coalesce(inherited_species,FALSE),inherited_geography=coalesce(inherited_geography,FALSE),
        species_review_required=species_review_required & !inherited_species,
        geography_review_required=geography_review_required & !inherited_geography)|>
 filter(species_review_required|geography_review_required)

write_csv(inherited,path(output_dir,"inherited_annotation_adjudication.csv"),na="")
write_csv(remaining,path(output_dir,"remaining_annotation_adjudication_queue.csv"),na="")
write_csv(audit,path(output_dir,"historical_inheritance_audit.csv"),na="")

summary<-list(
 schema="living-evidence-map-workflow05-historical-adjudication-reuse-audit-v1",
 current_queue_records=nrow(queue),
 current_queue_species_dimensions=sum(queue$species_review_required%in%TRUE),
 current_queue_geography_dimensions=sum(queue$geography_review_required%in%TRUE),
 historical_rows_total=nrow(read_csv(historical_path,show_col_types=FALSE,progress=FALSE)),
 historical_rows_mapped_to_current_queue=nrow(hist),
 records_with_any_inherited_adjudication=nrow(inherited),
 inherited_species_dimensions=sum(inherited$inherited_species%in%TRUE),
 inherited_geography_dimensions=sum(inherited$inherited_geography%in%TRUE),
 historical_species_conflicts=sum(audit$species_conflict%in%TRUE),
 historical_geography_conflicts=sum(audit$geography_conflict%in%TRUE),
 remaining_llm_queue_records=nrow(remaining),
 reuse_rule="unique Lens manifestation mapping to current stable record_id plus unchanged relevant deterministic state; multiple historical manifestations must agree",
 status="PASS"
)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null"),path(output_dir,"historical_inheritance_summary.json"))
cat(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null"),"\n")

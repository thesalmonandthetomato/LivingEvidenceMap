#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(jsonlite)
  library(digest)
})
source("R/geography_grounding.R")

args<-commandArgs(trailingOnly=TRUE)
arg<-function(flag,default=NULL){
  i<-match(flag,args)
  if(is.na(i))return(default)
  if(i==length(args))stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}
w06_path<-arg("--w06")
records_path<-arg("--records")
gazetteer_path<-arg("--gazetteer","config/global_country_gazetteer_v3.csv")
output_dir<-arg("--output-dir","outputs/workflow06_no_model_validation")

for(p in c(w06_path,records_path,gazetteer_path)){
  if(is.null(p)||!file.exists(p))stop("Required validation input missing: ",p,call.=FALSE)
}
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

w06<-read_csv(w06_path,show_col_types=FALSE,progress=FALSE)
rec<-read_csv(records_path,show_col_types=FALSE,progress=FALSE)
gaz<-read_csv(gazetteer_path,show_col_types=FALSE,progress=FALSE)

req6<-c("record_id","geography_status","luna_iso3c","luna_country_names",
        "luna_evidence","evidence_all_grounded","llm_failed",
        "deterministic_primary_iso3c")
reqr<-c("record_id","title","abstract")
if(length(setdiff(req6,names(w06))))stop("W06 layer missing fields: ",paste(setdiff(req6,names(w06)),collapse=", "),call.=FALSE)
if(length(setdiff(reqr,names(rec))))stop("Record context missing fields",call.=FALSE)
if(anyDuplicated(w06$record_id)||anyDuplicated(rec$record_id))stop("Duplicate record_id",call.=FALSE)
if(!setequal(w06$record_id,rec$record_id))stop("W06/context population mismatch",call.=FALSE)
if(nrow(w06)!=21819L)stop(sprintf("Expected current W06 population 21819, found %d",nrow(w06)),call.=FALSE)

# Current authoritative W06 state invariants. These validate that replaying the
# deterministic layer is being performed over the published semantic state,
# not a changed/re-screened population.
if(sum(w06$geography_status=="RESOLVED")!=9072L)stop("Unexpected RESOLVED count",call.=FALSE)
if(sum(w06$geography_status=="NONE")!=12185L)stop("Unexpected NONE count",call.=FALSE)
if(sum(w06$geography_status=="UNRESOLVED")!=562L)stop("Unexpected UNRESOLVED count",call.=FALSE)
if(sum(w06$llm_failed %in% TRUE)!=6L)stop("Unexpected terminal model-failure count",call.=FALSE)

x<-w06 |> left_join(rec |> select(record_id,title,abstract),by="record_id")
if(any(is.na(x$title)) && any(is.na(x$abstract))) {
  # NA text is allowed per-record, but the join itself must cover all IDs.
  if(any(is.na(match(w06$record_id,rec$record_id))))stop("Context join failed",call.=FALSE)
}

before_hash<-digest(toJSON(w06, dataframe="rows", na="null", digits=NA),
                    algo="sha256",serialize=FALSE)

val<-lapply(seq_len(nrow(x)),function(i)geography_auto_validation(
  status=x$geography_status[[i]],
  llm_failed=x$llm_failed[[i]] %in% TRUE,
  luna_iso3c=x$luna_iso3c[[i]],
  deterministic_iso3c=x$deterministic_primary_iso3c[[i]],
  evidence_all_grounded=x$evidence_all_grounded[[i]] %in% TRUE,
  title=x$title[[i]],abstract=x$abstract[[i]],gazetteer=gaz
))
x$geography_autovalidated<-vapply(val,function(z)isTRUE(z$valid),logical(1))
x$geography_auto_validation_basis<-vapply(val,function(z)as.character(z$basis),character(1))

# Adding deterministic validation metadata must not modify any published W06
# semantic or raw-QC field.
after_hash<-digest(toJSON(x[,names(w06),drop=FALSE],dataframe="rows",na="null",digits=NA),
                   algo="sha256",serialize=FALSE)
if(!identical(before_hash,after_hash))stop("Published W06 fields changed during replay",call.=FALSE)

# Logical invariants of the new validation layer.
if(any(x$llm_failed %in% TRUE & x$geography_autovalidated))stop("Model failures were auto-validated",call.=FALSE)
if(any(x$geography_status=="UNRESOLVED" & x$geography_autovalidated))stop("UNRESOLVED records were auto-validated",call.=FALSE)
if(any(x$geography_status=="RESOLVED" & x$evidence_all_grounded %in% TRUE & !x$geography_autovalidated))stop("Grounded RESOLVED record left residual",call.=FALSE)
exact_basis_idx<-which(x$geography_auto_validation_basis=="deterministic_exact_agreement")
if(length(exact_basis_idx)){
  exact_basis_ok<-vapply(exact_basis_idx,function(i)
    identical(normalise_iso3_set(x$luna_iso3c[[i]]),
              normalise_iso3_set(x$deterministic_primary_iso3c[[i]])),
    logical(1))
  if(!all(exact_basis_ok))stop("Exact-agreement basis assigned without exact agreement",call.=FALSE)
}

cue_ids<-which(x$geography_auto_validation_basis=="explicit_country_cues")
if(length(cue_ids)){
  ok<-vapply(cue_ids,function(i)strict_country_cues_support_set(
    x$luna_iso3c[[i]],x$title[[i]],x$abstract[[i]],gaz),logical(1))
  if(!all(ok))stop("Explicit-country basis failed independent replay",call.=FALSE)
}

# Safety fixtures: direct country cues should validate; subnational-only cues
# must not satisfy the strict explicit-country exception.
stopifnot(
  strict_country_cues_support_set("GBR","UK retail market","",gaz),
  strict_country_cues_support_set("GBR","U.K. retail market","",gaz),
  strict_country_cues_support_set("NOR","Norwegian salmon sector","",gaz),
  strict_country_cues_support_set("USA","U.S. salmon market","",gaz),
  !strict_country_cues_support_set("NOR","Study undertaken in Vosso","",gaz)
)

residual<-x |> filter(!(geography_autovalidated %in% TRUE))
if(any(residual$geography_status=="NONE"))stop("NONE record incorrectly left in review residual",call.=FALSE)
resolved_residual<-residual |> filter(geography_status=="RESOLVED",!(llm_failed %in% TRUE))
if(nrow(resolved_residual)){
  if(any(resolved_residual$evidence_all_grounded %in% TRUE))stop("Grounded resolved record in residual",call.=FALSE)
  exact<-vapply(seq_len(nrow(resolved_residual)),function(i)
    identical(normalise_iso3_set(resolved_residual$luna_iso3c[[i]]),
              normalise_iso3_set(resolved_residual$deterministic_primary_iso3c[[i]])),logical(1))
  if(any(exact))stop("Exact-agreement resolved record in residual",call.=FALSE)
  cue<-vapply(seq_len(nrow(resolved_residual)),function(i)
    strict_country_cues_support_set(resolved_residual$luna_iso3c[[i]],
                                    resolved_residual$title[[i]],
                                    resolved_residual$abstract[[i]],gaz),logical(1))
  if(any(cue))stop("Explicit-country-corroborated resolved record in residual",call.=FALSE)
}

basis<-x |> count(geography_auto_validation_basis,name="n") |> arrange(desc(n))
write_csv(basis,file.path(output_dir,"auto_validation_basis_counts.csv"),na="")
write_csv(residual,file.path(output_dir,"geography_review_residual_validation.csv"),na="")

summary<-list(
  schema="living-evidence-map-workflow06-no-model-autovalidation-validation-v1",
  status="PASS",
  records=nrow(x),
  published_resolved=sum(x$geography_status=="RESOLVED"),
  published_none=sum(x$geography_status=="NONE"),
  published_unresolved=sum(x$geography_status=="UNRESOLVED"),
  terminal_model_failures=sum(x$llm_failed%in%TRUE),
  raw_evidence_not_grounded=sum(!(x$evidence_all_grounded%in%TRUE)),
  geography_autovalidated=sum(x$geography_autovalidated%in%TRUE),
  geography_review_residual=nrow(residual),
  autoaccepted_exact_agreement=sum(x$geography_auto_validation_basis=="deterministic_exact_agreement"),
  autoaccepted_explicit_country_cues=sum(x$geography_auto_validation_basis=="explicit_country_cues"),
  resolved_still_uncorroborated=nrow(resolved_residual),
  original_fields_sha256_before=before_hash,
  original_fields_sha256_after=after_hash,
  model_calls=0L,
  validated_at_utc=format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%SZ")
)
write_json(summary,file.path(output_dir,"summary.json"),auto_unbox=TRUE,pretty=TRUE)
cat(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),"\n")
cat(sprintf("PASS: no-model W06 auto-validation replay records=%d residual=%d exact=%d explicit_cues=%d unresolved=%d failures=%d\n",
            nrow(x),nrow(residual),summary$autoaccepted_exact_agreement,
            summary$autoaccepted_explicit_country_cues,
            summary$published_unresolved,summary$terminal_model_failures))

#!/usr/bin/env Rscript
suppressPackageStartupMessages({library(dplyr);library(readr);library(jsonlite);library(httr2);library(digest)})

args<-commandArgs(trailingOnly=TRUE)
arg<-function(f,d=NULL){i<-match(f,args);if(is.na(i))d else args[[i+1L]]}
det_path<-arg("--deterministic"); rec_path<-arg("--records"); out<-arg("--output-dir","outputs/workflow05_luna_test")
prompt_path<-arg("--prompt","config/workflow05_luna_independent_audit_prompt.txt")
dir.create(out,recursive=TRUE,showWarnings=FALSE)
det<-read_csv(det_path,show_col_types=FALSE); rec<-read_csv(rec_path,show_col_types=FALSE)
x<-inner_join(rec,det,by="record_id")
set.seed(20260926)
both<-x|>filter(species_review_required,geography_review_required)
sp<-x|>filter(species_review_required,!geography_review_required)
geo<-x|>filter(!species_review_required,geography_review_required)
easy<-x|>filter(!species_review_required,!geography_review_required)
sample_n_safe<-function(z,n) if(nrow(z)<=n) z else slice_sample(z,n=n)
samp<-bind_rows(sample_n_safe(easy,40),sample_n_safe(sp,25),sample_n_safe(geo,31),both)|>distinct(record_id,.keep_all=TRUE)
stopifnot(nrow(samp)==100L)
prompt<-paste(readLines(prompt_path,warn=FALSE),collapse="\n")
allowed<-c("SAL_SALAR","ONC_MYKISS","ONC_TSHAWYTSCHA","ONC_KISUTCH","ONC_NERKA","ONC_KETA","ONC_GORBUSCHA","ONC_MASOU","UNSPEC_SALMON")
schema<-list(type="object",properties=list(
 species_status=list(type="string",enum=c("ASSIGNED","NONE","UNRESOLVED")),
 species_ids=list(type="array",items=list(type="string",enum=allowed)),
 species_reason=list(type="string"),
 geography_status=list(type="string",enum=c("ASSIGNED","NONE","UNRESOLVED")),
 primary_country_iso3c=list(type="array",items=list(type="string")),
 geography_reason=list(type="string")),
 required=c("species_status","species_ids","species_reason","geography_status","primary_country_iso3c","geography_reason"),
 additionalProperties=FALSE)
extract_text<-function(z){for(o in z$output){if(!is.null(o$content))for(c in o$content)if(identical(c$type,"output_text"))return(c$text)};stop("No output_text")}
call_one<-function(r){
 user<-paste("RECORD ID",r$record_id,"","TITLE",r$title,"","ABSTRACT",r$abstract,"","Classify species and primary study geography independently.",sep="\n")
 body<-list(model="gpt-5.6-luna",store=FALSE,reasoning=list(effort="low"),
  input=list(list(role="system",content=list(list(type="input_text",text=prompt))),list(role="user",content=list(list(type="input_text",text=user)))),
  text=list(verbosity="low",format=list(type="json_schema",name="species_geography_audit",strict=TRUE,schema=schema)))
 z<-request("https://api.openai.com/v1/responses")|>req_auth_bearer_token(Sys.getenv("OPENAI_API_KEY"))|>req_body_json(body,auto_unbox=TRUE)|>req_timeout(120)|>req_retry(max_tries=4)|>req_perform()|>resp_body_json(simplifyVector=FALSE)
 fromJSON(extract_text(z),simplifyVector=TRUE)
}
norm<-function(z){z<-as.character(z);z<-z[!is.na(z)&nzchar(trimws(z))];if(!length(z))return("");paste(sort(unique(trimws(z))),collapse=";")}
res<-lapply(seq_len(nrow(samp)),function(i){a<-call_one(samp[i,]); data.frame(record_id=samp$record_id[i],species_status=a$species_status,luna_species_ids=norm(a$species_ids),species_reason=a$species_reason,geography_status=a$geography_status,luna_iso3c=norm(a$primary_country_iso3c),geography_reason=a$geography_reason)})
res<-bind_rows(res)
cmp<-samp|>left_join(res,by="record_id")|>mutate(det_species_ids=vapply(strsplit(coalesce(deterministic_species_ids,""),";",fixed=TRUE),norm,character(1)),det_iso3c=vapply(strsplit(coalesce(deterministic_primary_iso3c,""),";",fixed=TRUE),norm,character(1)),species_agree=det_species_ids==luna_species_ids,geography_agree=det_iso3c==luna_iso3c)
write_csv(cmp,file.path(out,"comparison_100.csv"));write_csv(filter(cmp,!species_agree|!geography_agree|species_status=="UNRESOLVED"|geography_status=="UNRESOLVED"),file.path(out,"disagreements.csv"))
summary<-list(n=nrow(cmp),species_exact_agreement=sum(cmp$species_agree),species_exact_agreement_pct=mean(cmp$species_agree)*100,geography_exact_agreement=sum(cmp$geography_agree),geography_exact_agreement_pct=mean(cmp$geography_agree)*100,species_unresolved=sum(cmp$species_status=="UNRESOLVED"),geography_unresolved=sum(cmp$geography_status=="UNRESOLVED"),prompt_sha256=digest(file=prompt_path,algo="sha256",serialize=FALSE),model="gpt-5.6-luna",reasoning="low")
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),file.path(out,"summary.json"));print(summary)

#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(jsonlite); library(httr2); library(digest); library(tidyr)
})

args <- commandArgs(trailingOnly = TRUE)
arg <- function(f,d=NULL){i<-match(f,args); if(is.na(i)) d else args[[i+1L]]}
det_path <- arg("--deterministic")
rec_path <- arg("--records")
out <- arg("--output-dir","outputs/workflow05_luna_two_pass_test")
prompt_path <- arg("--prompt","config/workflow05_luna_independent_audit_prompt.txt")
sample_file <- arg("--sample-file", NULL)
sample_strategy <- arg("--sample-strategy", "stratified")
sample_size <- as.integer(arg("--sample-size", "100"))
sample_seed <- as.integer(arg("--sample-seed", "20260926"))
dir.create(out, recursive=TRUE, showWarnings=FALSE)

det <- read_csv(det_path, show_col_types=FALSE)
rec <- read_csv(rec_path, show_col_types=FALSE)
x <- inner_join(rec, det, by="record_id")
stopifnot(nrow(x)==19407L, !anyDuplicated(x$record_id))

if (!is.null(sample_file)) {
  prior_sample <- read_csv(sample_file, show_col_types=FALSE)
  stopifnot("record_id" %in% names(prior_sample), nrow(prior_sample)==sample_size, !anyDuplicated(prior_sample$record_id))
  samp <- x |> semi_join(prior_sample |> select(record_id), by="record_id")
  stopifnot(nrow(samp)==sample_size)
} else if (identical(sample_strategy, "simple_random")) {
  set.seed(sample_seed)
  samp <- x |> slice_sample(n=sample_size)
} else {
  if (sample_size != 100L) stop("Stratified pilot is defined only for sample_size=100")
  set.seed(sample_seed)
  sample_n_safe <- function(z,n) if(nrow(z)<=n) z else slice_sample(z,n=n)
  both <- x |> filter(species_review_required, geography_review_required)
  sp <- x |> filter(species_review_required, !geography_review_required)
  geo <- x |> filter(!species_review_required, geography_review_required)
  easy <- x |> filter(!species_review_required, !geography_review_required)

  samp <- bind_rows(
    sample_n_safe(easy, 40),
    sample_n_safe(sp, 25),
    sample_n_safe(geo, 31),
    both
  ) |> distinct(record_id, .keep_all=TRUE)

  if(nrow(samp) > sample_size) samp <- samp |> slice_head(n=sample_size)
  if(nrow(samp) < sample_size) {
    remaining <- anti_join(x, samp, by="record_id")
    samp <- bind_rows(samp, sample_n_safe(remaining, sample_size-nrow(samp)))
  }
}
stopifnot(nrow(samp)==sample_size, !anyDuplicated(samp$record_id))

samp <- samp |> mutate(
  stratum = case_when(
    species_review_required & geography_review_required ~ "both_review",
    species_review_required ~ "species_review",
    geography_review_required ~ "geography_review",
    TRUE ~ "non_review"
  )
)
write_csv(samp, file.path(out,paste0("sample_",sample_size,".csv")))

prompt <- paste(readLines(prompt_path,warn=FALSE),collapse="\n")
allowed <- c("SAL_SALAR","ONC_MYKISS","ONC_TSHAWYTSCHA","ONC_KISUTCH","ONC_NERKA","ONC_KETA","ONC_GORBUSCHA","ONC_MASOU","UNSPEC_SALMON")
schema <- list(
  type="object",
  properties=list(
    species_status=list(type="string",enum=c("ASSIGNED","NONE","UNRESOLVED")),
    species_ids=list(type="array",items=list(type="string",enum=allowed)),
    species_reason=list(type="string"),
    geography_status=list(type="string",enum=c("ASSIGNED","NONE","UNRESOLVED")),
    primary_country_iso3c=list(type="array",items=list(type="string")),
    geography_reason=list(type="string")
  ),
  required=c("species_status","species_ids","species_reason","geography_status","primary_country_iso3c","geography_reason"),
  additionalProperties=FALSE
)

extract_text <- function(z){
  for(o in z$output){
    if(!is.null(o$content)){
      for(c in o$content) if(identical(c$type,"output_text")) return(c$text)
    }
  }
  stop("No output_text")
}

call_one <- function(r, pass){
  user <- paste(
    "RECORD ID", r$record_id, "",
    "TITLE", r$title, "",
    "ABSTRACT", r$abstract, "",
    "Classify species and primary study geography independently.",
    sep="\n"
  )
  body <- list(
    model="gpt-5.6-luna",
    store=FALSE,
    reasoning=list(effort="low"),
    input=list(
      list(role="system",content=list(list(type="input_text",text=prompt))),
      list(role="user",content=list(list(type="input_text",text=user)))
    ),
    text=list(
      verbosity="low",
      format=list(type="json_schema",name="species_geography_audit",strict=TRUE,schema=schema)
    )
  )
  z <- request("https://api.openai.com/v1/responses") |>
    req_auth_bearer_token(Sys.getenv("OPENAI_API_KEY")) |>
    req_body_json(body,auto_unbox=TRUE) |>
    req_timeout(120) |>
    req_retry(max_tries=4) |>
    req_perform() |>
    resp_body_json(simplifyVector=FALSE)
  a <- fromJSON(extract_text(z), simplifyVector=TRUE)
  tibble(
    record_id=r$record_id,
    pass=pass,
    species_status=a$species_status,
    species_ids=list(a$species_ids),
    species_reason=a$species_reason,
    geography_status=a$geography_status,
    primary_country_iso3c=list(a$primary_country_iso3c),
    geography_reason=a$geography_reason
  )
}

norm_vec <- function(z){
  z <- as.character(z); z <- z[!is.na(z) & nzchar(trimws(z))]
  if(!length(z)) return("")
  paste(sort(unique(trimws(z))),collapse="; ")
}
norm_string <- function(x){
  x <- as.character(x); x[is.na(x)] <- ""
  vapply(strsplit(x,";",fixed=TRUE), norm_vec, character(1))
}

run_pass <- function(pass){
  message(sprintf("Starting Luna pass %d for %d records",pass,nrow(samp)))
  out_list <- vector("list",nrow(samp))
  for(i in seq_len(nrow(samp))){
    out_list[[i]] <- call_one(samp[i,],pass)
    if(i==1L || i%%10L==0L || i==nrow(samp)) message(sprintf("Pass %d: %d/%d",pass,i,nrow(samp)))
  }
  bind_rows(out_list)
}

p1 <- run_pass(1L)
p2 <- run_pass(2L)
write_csv(p1 |> mutate(species_ids=vapply(species_ids,norm_vec,character(1)), primary_country_iso3c=vapply(primary_country_iso3c,norm_vec,character(1))), file.path(out,"luna_pass1.csv"))
write_csv(p2 |> mutate(species_ids=vapply(species_ids,norm_vec,character(1)), primary_country_iso3c=vapply(primary_country_iso3c,norm_vec,character(1))), file.path(out,"luna_pass2.csv"))

wide <- p1 |>
  select(-pass) |>
  rename_with(~paste0("l1_",.x),-record_id) |>
  left_join(
    p2 |> select(-pass) |> rename_with(~paste0("l2_",.x),-record_id),
    by="record_id"
  )

cmp <- samp |>
  left_join(wide,by="record_id") |>
  mutate(
    det_species_ids=norm_string(deterministic_species_ids),
    det_iso3c=norm_string(deterministic_primary_iso3c),
    l1_species_ids=vapply(l1_species_ids,norm_vec,character(1)),
    l2_species_ids=vapply(l2_species_ids,norm_vec,character(1)),
    l1_iso3c=vapply(l1_primary_country_iso3c,norm_vec,character(1)),
    l2_iso3c=vapply(l2_primary_country_iso3c,norm_vec,character(1)),
    species_det_l1=det_species_ids==l1_species_ids,
    species_det_l2=det_species_ids==l2_species_ids,
    species_l1_l2=l1_species_ids==l2_species_ids,
    species_all3=species_det_l1 & species_det_l2,
    geography_det_l1=det_iso3c==l1_iso3c,
    geography_det_l2=det_iso3c==l2_iso3c,
    geography_l1_l2=l1_iso3c==l2_iso3c,
    geography_all3=geography_det_l1 & geography_det_l2,
    species_pattern=case_when(
      species_all3 ~ "all_three_agree",
      species_l1_l2 & !species_det_l1 ~ "luna1_luna2_agree_not_deterministic",
      species_det_l1 & !species_det_l2 ~ "deterministic_luna1_agree",
      species_det_l2 & !species_det_l1 ~ "deterministic_luna2_agree",
      TRUE ~ "all_different"
    ),
    geography_pattern=case_when(
      geography_all3 ~ "all_three_agree",
      geography_l1_l2 & !geography_det_l1 ~ "luna1_luna2_agree_not_deterministic",
      geography_det_l1 & !geography_det_l2 ~ "deterministic_luna1_agree",
      geography_det_l2 & !geography_det_l1 ~ "deterministic_luna2_agree",
      TRUE ~ "all_different"
    )
  )

write_csv(cmp,file.path(out,"comparison_100_three_way.csv"))
write_csv(
  cmp |> filter(!species_all3 | !geography_all3 | l1_species_status=="UNRESOLVED" | l2_species_status=="UNRESOLVED" | l1_geography_status=="UNRESOLVED" | l2_geography_status=="UNRESOLVED"),
  file.path(out,"three_way_disagreements.csv")
)

pairwise <- tibble(
  dimension=c("species","species","species","geography","geography","geography"),
  comparison=c("deterministic_vs_luna1","deterministic_vs_luna2","luna1_vs_luna2","deterministic_vs_luna1","deterministic_vs_luna2","luna1_vs_luna2"),
  agreement_n=c(sum(cmp$species_det_l1),sum(cmp$species_det_l2),sum(cmp$species_l1_l2),sum(cmp$geography_det_l1),sum(cmp$geography_det_l2),sum(cmp$geography_l1_l2)),
  agreement_pct=100*c(sum(cmp$species_det_l1),sum(cmp$species_det_l2),sum(cmp$species_l1_l2),sum(cmp$geography_det_l1),sum(cmp$geography_det_l2),sum(cmp$geography_l1_l2))/nrow(cmp)
)
write_csv(pairwise,file.path(out,"pairwise_agreement.csv"))

strat <- cmp |>
  group_by(stratum) |>
  summarise(
    n=n(),
    species_all3_n=sum(species_all3),
    species_all3_pct=100*mean(species_all3),
    geography_all3_n=sum(geography_all3),
    geography_all3_pct=100*mean(geography_all3),
    .groups="drop"
  )
write_csv(strat,file.path(out,"stratified_three_way_agreement.csv"))

species_patterns <- cmp |> count(species_pattern,name="n") |> mutate(pct=100*n/nrow(cmp))
geography_patterns <- cmp |> count(geography_pattern,name="n") |> mutate(pct=100*n/nrow(cmp))
write_csv(species_patterns,file.path(out,"species_agreement_patterns.csv"))
write_csv(geography_patterns,file.path(out,"geography_agreement_patterns.csv"))

summary <- list(
  n=nrow(cmp),
  sample_strategy=sample_strategy,
  sample_seed=sample_seed,
  model="gpt-5.6-luna",
  reasoning="low",
  prompt_sha256=digest(file=prompt_path,algo="sha256",serialize=FALSE),
  species_three_way_agreement_n=sum(cmp$species_all3),
  species_three_way_agreement_pct=100*mean(cmp$species_all3),
  geography_three_way_agreement_n=sum(cmp$geography_all3),
  geography_three_way_agreement_pct=100*mean(cmp$geography_all3),
  luna1_species_unresolved=sum(cmp$l1_species_status=="UNRESOLVED"),
  luna2_species_unresolved=sum(cmp$l2_species_status=="UNRESOLVED"),
  luna1_geography_unresolved=sum(cmp$l1_geography_status=="UNRESOLVED"),
  luna2_geography_unresolved=sum(cmp$l2_geography_status=="UNRESOLVED"),
  any_three_way_disagreement_n=sum(!cmp$species_all3 | !cmp$geography_all3),
  any_three_way_disagreement_pct=100*mean(!cmp$species_all3 | !cmp$geography_all3),
  luna_pair_agree_against_deterministic_any_n=sum((cmp$species_l1_l2 & !cmp$species_det_l1) | (cmp$geography_l1_l2 & !cmp$geography_det_l1)),
  luna_pair_agree_against_deterministic_any_pct=100*mean((cmp$species_l1_l2 & !cmp$species_det_l1) | (cmp$geography_l1_l2 & !cmp$geography_det_l1)),
  any_luna_unresolved_n=sum(cmp$l1_species_status=="UNRESOLVED" | cmp$l2_species_status=="UNRESOLVED" | cmp$l1_geography_status=="UNRESOLVED" | cmp$l2_geography_status=="UNRESOLVED"),
  any_luna_unresolved_pct=100*mean(cmp$l1_species_status=="UNRESOLVED" | cmp$l2_species_status=="UNRESOLVED" | cmp$l1_geography_status=="UNRESOLVED" | cmp$l2_geography_status=="UNRESOLVED")
)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE),file.path(out,"summary.json"))
print(summary); print(pairwise); print(strat); print(species_patterns); print(geography_patterns)

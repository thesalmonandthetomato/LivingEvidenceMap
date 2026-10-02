#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(data.table))

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}
validation_path <- arg("--validation")
pairs_path <- arg("--pairs")
registry_path <- arg("--registry")
output_dir <- arg("--output-dir")
if (is.null(validation_path)||is.null(pairs_path)||is.null(registry_path)||is.null(output_dir)) {
  stop("--validation --pairs --registry --output-dir required",call.=FALSE)
}
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

val <- fread(validation_path,na.strings=c("","NA"))
risky_classes <- c(
  "possible_identifier_or_container_misassignment",
  "still_ambiguous_or_conflicting",
  "external_lookup_unresolved"
)
risk <- val[external_validation_class %in% risky_classes]
if (nrow(risk)!=363L) stop(sprintf("Expected 363 risky/unresolved rows, got %d",nrow(risk)),call.=FALSE)

pairs <- fread(pairs_path,na.strings=c("","NA"))
reg <- fread(registry_path,na.strings=c("","NA"))

# Count all manifestations and source diversity attached to each identifier.
id_stats <- reg[,.(identifier_manifestations=uniqueN(manifestation_key),
                   identifier_sources=uniqueN(source)),
                by=.(identifier_type,identifier_value)]

risk <- merge(
  risk,
  id_stats,
  by.x=c("identifier_type","identifier_value"),
  by.y=c("identifier_type","identifier_value"),
  all.x=TRUE,
  sort=FALSE
)

# Count how many disagreement pairs the same identifier generates.
risk_counts <- risk[,.(risky_pair_count=.N,
                      unique_risky_manifestations=uniqueN(c(record_i,record_j))),
                    by=.(identifier_type,identifier_value)]
risk <- merge(risk,risk_counts,by=c("identifier_type","identifier_value"),all.x=TRUE,sort=FALSE)

# Detect likely container/reused identifiers conservatively.
risk[, likely_reused_or_container := (
  risky_pair_count >= 3L |
  unique_risky_manifestations >= 4L |
  identifier_manifestations >= 5L
)]

# Group-level classifications.
groups <- unique(risk[,.(identifier_type,identifier_value,
                        identifier_manifestations,identifier_sources,
                        risky_pair_count,unique_risky_manifestations,
                        likely_reused_or_container)])

groups[, risk_class:=fcase(
  likely_reused_or_container, "reused_or_container_identifier",
  risky_pair_count==1L & identifier_manifestations<=2L, "isolated_pair_anomaly",
  default="small_multi_record_identifier_group"
)]

# Pull representative titles from risky rows for inspection.
repr <- risk[,.(example_title_i=title_i[1L],
               example_title_j=title_j[1L],
               example_external_title=external_title[1L]),
             by=.(identifier_type,identifier_value)]
groups <- merge(groups,repr,by=c("identifier_type","identifier_value"),all.x=TRUE)

fwrite(groups[order(identifier_type,-risky_pair_count)],
       file.path(output_dir,"risky_identifier_groups.csv"))
fwrite(risk[order(identifier_type,identifier_value)],
       file.path(output_dir,"risky_pairs_with_group_stats.csv"))

summary <- groups[,.(identifier_groups=.N,
                     risky_pairs=sum(risky_pair_count),
                     manifestations=sum(unique_risky_manifestations),
                     max_pairs=max(risky_pair_count)),
                  by=.(identifier_type,risk_class)][order(identifier_type,risk_class)]
fwrite(summary,file.path(output_dir,"risky_group_summary.csv"))

# Explicit guard candidates for any future production integration.
guards <- groups[risk_class=="reused_or_container_identifier",
                 .(identifier_type,identifier_value,
                   identifier_manifestations,identifier_sources,
                   risky_pair_count,unique_risky_manifestations)]
fwrite(guards,file.path(output_dir,"future_never_auto_resolve_guard_candidates.csv"))

cat("PASS: risky identifier group audit\n")
print(summary)
cat(sprintf("RISKY_PAIRS=%d; IDENTIFIER_GROUPS=%d; GUARD_CANDIDATES=%d; zero W01 modifications\n",
            nrow(risk),nrow(groups),nrow(guards)))

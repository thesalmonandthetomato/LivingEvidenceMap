#!/usr/bin/env Rscript
# Offline fixture test for the W08b identity-coverage extractor.
# No network access, API keys, production inputs or repository state changes.
tmp <- tempfile("w08b-test-");dir.create(tmp)
on.exit(unlink(tmp,recursive=TRUE),add=TRUE)
record <- function(id,mans,doi=NULL) list(identity=list(record_id=id),canonical=list(doi=doi),manifestations=mans)
manifestation <- function(source,source_record_id,source_identity=list(),identifiers=list(),doi=NULL)
  list(source=source,source_record_id=source_record_id,doi=doi,
       manifestation_metadata=list(source_identity=source_identity,identifiers=identifiers))
x<-list(
  record("a",list(manifestation("lens","123-456-789-000-111",list(lens_id="123-456-789-000-111")),
                   manifestation("openalex","https://openalex.org/W123",list(openalex_id="W123"))),"10.1234/a"),
  record("b",list(manifestation("openalex","W456",list(openalex_id="W456")))),
  record("c",list(manifestation("scopus","s-1")),"https://doi.org/10.1234/C"),
  record("d",list(manifestation("wos","w-1"))),
  record("e",list(manifestation("lens","l-1",list(lens_id="l-1")),
                   manifestation("lens","l-2",list(lens_id="l-2")))),
  record("f",list(), "10.1234/f")
)
input<-file.path(tmp,"input.jsonl");out<-file.path(tmp,"output")
writeLines(vapply(x,function(v)jsonlite::toJSON(v,auto_unbox=TRUE,null="null"),character(1)),input)
status<-system2(file.path(R.home("bin"),"Rscript"),
  c("scripts/workflow08b/audit_identifiers.R",shQuote(input),shQuote(out)))
stopifnot(status==0L)
d<-read.csv(file.path(out,"seed_identifier_audit.csv"),stringsAsFactors=FALSE)
stopifnot(nrow(d)==6L,!anyDuplicated(d$record_id))
r<-setNames(d$preferred_route,d$record_id)
stopifnot(r[["a"]]=="lens",r[["b"]]=="openalex",r[["c"]]=="lens_doi_lookup",
          r[["d"]]=="unresolved",r[["e"]]=="identity_conflict",
          r[["f"]]=="manifestations_missing")
stopifnot(d$openalex_id[d$record_id=="a"]=="W123")
cat("PASS: W08b identifier routes and ambiguity quarantine\n")

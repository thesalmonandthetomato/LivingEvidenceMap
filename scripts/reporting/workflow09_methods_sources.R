# Database inventory for Methods reporting; use release W00 selection and W01 sources.
methods_source_inventory <- function() {
  selection <- jsonlite::fromJSON("data/workflow00/source_selection.json")
  summary <- jsonlite::fromJSON("docs/reporting/workflow_09_inputs/current/w00_summary.json")
  w01 <- read.csv("docs/reporting/workflow_09_inputs/current/w01_source_summary.csv", stringsAsFactors=FALSE)
  ebsco <- jsonlite::fromJSON("config/workflow00_ebsco_sources.json",simplifyVector=FALSE)$sources
  if (as.character(selection$baseline_run_id) != as.character(summary$source_run_id))
    stop("W00 run mismatch: source selection and W09 summary")
  ids <- as.character(selection$selected_sources)
  if (length(ids) != selection$selected_source_count || anyDuplicated(ids) || !all(ids %in% names(ebsco)))
    stop("Invalid EBSCO selection")
  absent <- setdiff(ids, w01$source_code)
  for (id in absent) {
    d <- file.path("docs/search_record",paste0("workflow00-search-record-",id,"-",selection$baseline_run_id),"full_search")
    f <- if(dir.exists(d)) list.files(d,"\\.json$",full.names=TRUE) else character()
    if(length(f)!=1L) stop("Cannot verify search with no manifestations: ",id)
    record <- jsonlite::fromJSON(f)
    if(record$source!=id || record$reported_search_results!=0 || !isTRUE(record$complete_download))
      stop("Unverified source in W00: ",id)
  }
  base <- data.frame(code=c("lens","openalex","scopus","wos","agricola"),
    name=c("The Lens","OpenAlex","Scopus",
    "Web of Science (Web of Science Core Collection: Science Citation Index Expanded (SCI-EXPANDED) 1981-present, Social Sciences Citation Index (SSCI) 1981-present, Arts & Humanities Citation Index (AHCI) 2017-present, Emerging Sources Citation Index (ESCI) 2005-present; Current Contents Connect; MEDLINE; Preprint Citation Index; Research Commons)",
    "AGRICOLA"),via=c("The Lens","OpenAlex","Scopus","Web of Science","Europe PMC"))
  if (!all(base$code %in% w01$source_code)) stop("Missing baseline source in W01")
  extras <- data.frame(code=ids,name=vapply(ebsco[ids],function(z)z$display_name,character(1)),via="EBSCOhost")
  api <- rbind(base,extras)
  manual <- data.frame(code=c("cab","proquest"),name=c("CAB Abstracts","ProQuest Dissertations & Theses Global (PQD&T)"),via=c("CABI Digital Library","ProQuest"))
  if(!all(manual$code %in% w01$source_code))stop("Missing manual source in W01")
  allowed <- c(api$code,manual$code)
  if(length(setdiff(w01$source_code,allowed)))stop("Unmapped W01 sources")
  list(api=api,manual=manual,api_count=nrow(api),total=nrow(api)+nrow(manual))
}

#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(jsonlite)
  library(digest)
})

args <- commandArgs(trailingOnly=TRUE)
arg <- function(flag,default=NULL) {
  i <- match(flag,args)
  if (is.na(i)) return(default)
  if (i==length(args)) stop(sprintf("Missing value after %s",flag),call.=FALSE)
  args[[i+1L]]
}

input_path <- arg("--input")
pricing_path <- arg("--pricing")
output_path <- arg("--output")
if (any(vapply(list(input_path,pricing_path,output_path),is.null,logical(1)))) {
  stop("Required: --input --pricing --output",call.=FALSE)
}

lines <- readLines(input_path,warn=FALSE,encoding="UTF-8")
lines <- lines[nzchar(trimws(lines))]
rows <- lapply(lines,fromJSON,simplifyVector=FALSE)
pricing <- fromJSON(pricing_path,simplifyVector=FALSE)

num <- function(x,default=0) {
  z <- suppressWarnings(as.numeric(x))
  if (!length(z) || is.na(z) || !is.finite(z)) default else z
}
get_usage <- function(r,name) {
  if (is.null(r$api_usage) || is.null(r$api_usage[[name]])) return(0)
  num(r$api_usage[[name]])
}
get_detail <- function(r,group,name) {
  if (is.null(r$api_usage) || is.null(r$api_usage[[group]]) || is.null(r$api_usage[[group]][[name]])) return(0)
  num(r$api_usage[[group]][[name]])
}

models <- unique(vapply(rows,function(r) {
  if (!is.null(r$resolved_model) && nzchar(as.character(r$resolved_model))) as.character(r$resolved_model)
  else as.character(r$requested_model)
},character(1)))

by_model <- list()
grand_cost <- 0
grand <- list(input_tokens=0,cached_input_tokens=0,uncached_input_tokens=0,
              output_tokens=0,reasoning_output_tokens=0,total_tokens=0)

for (model in models) {
  mrows <- Filter(function(r) {
    rm <- if (!is.null(r$resolved_model) && nzchar(as.character(r$resolved_model))) as.character(r$resolved_model) else as.character(r$requested_model)
    identical(rm,model)
  },rows)

  input <- sum(vapply(mrows,get_usage,numeric(1),name="input_tokens"))
  output <- sum(vapply(mrows,get_usage,numeric(1),name="output_tokens"))
  total <- sum(vapply(mrows,get_usage,numeric(1),name="total_tokens"))
  cached <- sum(vapply(mrows,get_detail,numeric(1),group="input_tokens_details",name="cached_tokens"))
  reasoning <- sum(vapply(mrows,get_detail,numeric(1),group="output_tokens_details",name="reasoning_tokens"))
  uncached <- max(0,input-cached)

  price <- pricing$models[[model]]
  if (is.null(price)) stop(sprintf("No pricing entry for resolved model: %s",model),call.=FALSE)

  input_cost <- uncached / 1e6 * num(price$input_per_million_tokens)
  cached_cost <- cached / 1e6 * num(price$cached_input_per_million_tokens)
  output_cost <- output / 1e6 * num(price$output_per_million_tokens)
  cost <- input_cost + cached_cost + output_cost

  by_model[[model]] <- list(
    cases=length(mrows),
    input_tokens=input,
    cached_input_tokens=cached,
    uncached_input_tokens=uncached,
    output_tokens=output,
    reasoning_output_tokens=reasoning,
    total_tokens=total,
    cost_usd=list(
      uncached_input=input_cost,
      cached_input=cached_cost,
      output=output_cost,
      total=cost
    ),
    rates_per_million_tokens=price
  )

  grand$input_tokens <- grand$input_tokens + input
  grand$cached_input_tokens <- grand$cached_input_tokens + cached
  grand$uncached_input_tokens <- grand$uncached_input_tokens + uncached
  grand$output_tokens <- grand$output_tokens + output
  grand$reasoning_output_tokens <- grand$reasoning_output_tokens + reasoning
  grand$total_tokens <- grand$total_tokens + total
  grand_cost <- grand_cost + cost
}

summary <- list(
  schema="living-evidence-map-workflow01-llm-cost-summary-v1",
  cases=length(rows),
  pricing_schema=pricing$schema,
  pricing_as_of=pricing$as_of,
  pricing_currency=pricing$currency,
  pricing_source=pricing$source,
  input_adjudications_sha256=digest(file=input_path,algo="sha256",serialize=FALSE),
  aggregate_usage=grand,
  estimated_cost_usd=grand_cost,
  by_model=by_model
)
dir.create(dirname(output_path),recursive=TRUE,showWarnings=FALSE)
writeLines(toJSON(summary,auto_unbox=TRUE,pretty=TRUE,null="null",na="null"),output_path)
cat(sprintf("PASS: aggregated LLM usage for %d cases; estimated cost USD %.6f\n",length(rows),grand_cost))

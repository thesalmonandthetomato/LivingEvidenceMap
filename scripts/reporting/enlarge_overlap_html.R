#!/usr/bin/env Rscript
# W10 publishing compatibility: enlarge existing W09 HTML Figure 3 without re-rendering W09.
a <- commandArgs(trailingOnly=TRUE)
if(length(a)!=1L || !file.exists(a[[1L]])) stop("Usage: enlarge_overlap_html.R results.html")
path<-a[[1L]]
x<-paste(readLines(path,warn=FALSE,encoding="UTF-8"),collapse="\n")
marker<-"w09-figure3-publisher-enhancement-v2"
if(grepl(marker,x,fixed=TRUE))quit(status=0L)
# W09 source now wraps Figure 3 directly; already rendered older documents need
# this idempotent, caption-based enhancement when W10 publishes them.
injection<-paste0(
'<style id="',marker,'">',
'.w09-overlap-scroll{max-height:680px;max-height:min(70vh,680px);overflow:auto;overscroll-behavior:contain;border:1px solid #dedede;padding:8px;margin-bottom:1em}',
'.w09-overlap-scroll img{width:200%!important;max-width:none!important;height:auto!important}',
'</style>\n',
'<script id="w09-overlap-scroll-compatibility">',
'document.addEventListener("DOMContentLoaded",function(){',
'var selectors=document.querySelectorAll("img");',
'for(var i=0;i<selectors.length;i++){',
'var img=selectors[i];var alt=(img.getAttribute("alt")||"").trim();',
'if(!/^Figure\\s*3\\s*[.:]/i.test(alt))continue;',
'if(img.closest(".w09-overlap-scroll"))continue;',
'var frame=document.createElement("div");frame.className="w09-overlap-scroll";',
'frame.setAttribute("role","region");frame.setAttribute("tabindex","0");',
'frame.setAttribute("aria-label","Figure 3 database overlap, scroll horizontally and vertically");',
'img.parentNode.insertBefore(frame,img);frame.appendChild(img);',
'}});',
'</script>')
if (grepl("</head>", x, fixed=TRUE)) {
  x <- sub("</head>", paste0(injection, "\n</head>"), x, fixed=TRUE)
} else {
  stop("Expected HTML head closing tag")
}
writeLines(x,path,useBytes=TRUE)
cat("PASS: W10 Figure 3 scrollable enhancement inserted\n")

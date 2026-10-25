#!/usr/bin/env Rscript
# W10 compatibility for previously rendered W09 HTML. Match Figure 3 by alt text,
# and first undo legacy wrappers that could accidentally encompass Figure 2.
a <- commandArgs(trailingOnly=TRUE)
if(length(a)!=1L || !file.exists(a[[1L]])) stop("Usage: enlarge_overlap_html.R results.html")
path <- a[[1L]]
x <- paste(readLines(path,warn=FALSE,encoding="UTF-8"),collapse="\n")
marker <- "w09-figure3-publisher-enhancement-v4"
if(grepl(marker,x,fixed=TRUE)) quit(status=0L)
injection <- paste0(
'<style id="',marker,'">',
'.w09-figure3-frame-v4{max-height:1360px;max-height:min(140vh,1360px);overflow:auto;overscroll-behavior:contain;padding:8px;margin-bottom:1em;border:none!important}',
'.w09-figure3-frame-v4 img{width:200%!important;max-width:none!important;height:auto!important}',
'.w09-overlap-scroll{max-height:none!important;height:auto!important;overflow:visible!important;border:none!important;padding:0!important}',
'.w09-overlap-scroll img{width:auto!important;max-width:100%!important;height:auto!important}',
'</style>\n',
'<script id="w09-figure3-publisher-script-v4">',
'document.addEventListener("DOMContentLoaded",function(){',
'var imgs=document.querySelectorAll("img");',
'for(var i=0;i<imgs.length;i++){',
'var img=imgs[i],alt=(img.getAttribute("alt")||"").trim();',
'if(!/^Figure\\s*3\\s*[.:]/i.test(alt))continue;',
'if(img.closest(".w09-figure3-frame-v4"))continue;',
'var frame=document.createElement("div");frame.className="w09-figure3-frame-v4";',
'frame.setAttribute("role","region");frame.setAttribute("tabindex","0");',
'frame.setAttribute("aria-label","Figure 3 enlarged and scrollable");',
'img.parentNode.insertBefore(frame,img);frame.appendChild(img);',
'}',
'});',
'</script>')
if (!grepl("</head>",x,fixed=TRUE)) stop("Expected HTML head closing tag")
x <- sub("</head>",paste0(injection,"\n</head>"),x,fixed=TRUE)
# Remove the obsolete no-milestones sentence from an already-rendered W09 report.
x <- gsub("No saved human–human consistency milestones were available for this reporting run\\.", "", x)
writeLines(x,path,useBytes=TRUE)
cat("PASS: Figure 3-only W10 enhancement installed; legacy Figure 2 wrapper neutralised\n")

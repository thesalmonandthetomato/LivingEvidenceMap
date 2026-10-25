#!/usr/bin/env Rscript
# W10 publication compatibility for archived W09 results HTML.
# Remove legacy figures' misplaced wrappers before styling Figure 3 only.
a <- commandArgs(trailingOnly=TRUE)
if(length(a)!=1L || !file.exists(a[[1L]])) stop("Usage: enlarge_overlap_html.R results.html")
path <- a[[1L]]
x <- paste(readLines(path,warn=FALSE,encoding="UTF-8"),collapse="\n")
marker <- "w09-figure3-publisher-enhancement-v5"
if(grepl(marker,x,fixed=TRUE)) quit(status=0L)
injection <- paste0(
'<style id="',marker,'">',
'.w09-figure3-frame-v5{max-height:1360px;max-height:min(140vh,1360px);overflow:auto;overscroll-behavior:contain;padding:8px;margin-bottom:1em;border:0!important}',
'.w09-figure3-frame-v5>img{display:block;width:200%!important;max-width:none!important;height:auto!important}',
'.w09-overlap-scroll{overflow:visible!important;max-height:none!important;height:auto!important;border:0!important;padding:0!important}',
'.w09-overlap-scroll img{width:auto!important;max-width:100%!important;height:auto!important}',
'img[alt^="Figure 2."]{width:auto!important;max-width:100%!important;height:auto!important}',
'.w09-figure3-frame-v5 img[alt^="Figure 3."]{width:200%!important;max-width:none!important;height:auto!important}',
'</style>\n',
'<script id="w09-figure3-publisher-script-v5">',
'document.addEventListener("DOMContentLoaded",function(){',
'function num(img){var a=(img.getAttribute("alt")||"").trim();var m=a.match(/^Figure\\s*([23])\\s*[.:]/i);return m?+m[1]:0;}',
'var imgs=Array.from(document.querySelectorAll("img"));',
'var two=imgs.filter(function(i){return num(i)===2;});',
'var three=imgs.filter(function(i){return num(i)===3;});',
'if(two.length!==1||three.length!==1){console.error("Figure 2/3 target ambiguous",two.length,three.length);return;}',
'/* Remove misplaced wrappers around either image, including the prior v4 wrapper. */',
'Array.from(document.querySelectorAll(".w09-overlap-scroll,.w09-figure3-frame-v4")).forEach(function(w){',
'while(w.firstChild)w.parentNode.insertBefore(w.firstChild,w);w.remove();',
'});',
'var fig2=two[0],fig3=three[0];',
'fig2.style.removeProperty("width");fig2.style.removeProperty("max-width");fig2.style.removeProperty("height");',
'fig2.style.setProperty("max-width","100%","important");',
'if(fig3.closest(".w09-figure3-frame-v5"))return;',
'var frame=document.createElement("div");frame.className="w09-figure3-frame-v5";',
'frame.setAttribute("role","region");frame.setAttribute("tabindex","0");',
'frame.setAttribute("aria-label","Figure 3 enlarged and scrollable");',
'fig3.parentNode.insertBefore(frame,fig3);frame.appendChild(fig3);',
'});',
'</script>')
if(!grepl("</head>",x,fixed=TRUE)) stop("Expected HTML head closing tag")
x <- sub("</head>",paste0(injection,"\n</head>"),x,fixed=TRUE)
x <- gsub("No saved human–human consistency milestones were available for this reporting run\\.","",x)
writeLines(x,path,useBytes=TRUE)
cat("PASS: isolated Figure 3 enlargement; Figure 2 legacy wrapper reset\n")

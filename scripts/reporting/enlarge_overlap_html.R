#!/usr/bin/env Rscript
# Apply Figure 3 enlargement to the already-rendered W09 HTML at W10 publication.
args <- commandArgs(trailingOnly=TRUE)
if (length(args) != 1L || !file.exists(args[[1L]])) stop("Usage: enlarge_overlap_html.R results.html")
path <- args[[1L]]
x <- paste(readLines(path,warn=FALSE,encoding="UTF-8"),collapse="\n")
# Remove previous publisher-injected styles/scripts; otherwise old rules keep affecting Figure 2.
x <- gsub('<style id="w09-figure3-publisher-enhancement[^"]*"[^>]*>[\\s\\S]*?</style>', '', x, perl=TRUE)
x <- gsub('<script id="w09-overlap-scroll-compatibility"[^>]*>[\\s\\S]*?</script>', '', x, perl=TRUE)
css <- paste0('<style id="w09-figure3-caption-target-v8">',
 '.w09-figure3-caption-target-v8{height:1360px;max-height:none;overflow:auto;overscroll-behavior:contain;margin:0 0 1em;padding:0;border:0!important;}',
 '.w09-figure3-caption-target-v8 img{display:block;width:200%!important;max-width:none!important;height:auto!important;}',
 '</style>')
js <- paste0('<script id="w09-figure3-caption-script-v8">',
 'document.addEventListener("DOMContentLoaded",function(){',
 'var captions=Array.from(document.querySelectorAll("figcaption,p.caption,.figure .caption"));',
 'var figures=captions.filter(function(p){return /^Figure\\s*3\\s*[.:]/i.test((p.textContent||"").trim());});',
 'if(figures.length!==1){console.error("Figure 3 caption not uniquely identified",figures.length);return;}',
 'var caption=figures[0],fig=caption.closest("figure,.figure");',
 'if(!fig){console.error("Figure 3 image container missing");return;}',
 'var img=fig.querySelector("img");if(!img){console.error("Figure 3 image missing");return;}',
 'var wrappers=Array.from(document.querySelectorAll(".w09-overlap-scroll,.w09-figure3-frame-v4,.w09-figure3-frame-v5,.w09-figure3-only-v7"));',
 'wrappers.forEach(function(el){while(el.firstChild)el.parentNode.insertBefore(el.firstChild,el);el.remove();});',
 'var frame=document.createElement("div");frame.className="w09-figure3-caption-target-v8";',
 'frame.setAttribute("role","region");frame.setAttribute("tabindex","0");',
 'frame.setAttribute("aria-label","Figure 3 database overlap scrollable chart");',
 'img.parentNode.insertBefore(frame,img);frame.appendChild(img);',
 'console.info("Figure 3 enlargement applied; Figure 2 unchanged");',
 '});</script>')
if(!grepl("</head>",x,fixed=TRUE))stop("Cannot find closing HTML head")
x<-sub("</head>",paste0(css,"\n",js,"\n</head>"),x,fixed=TRUE)
writeLines(x,path,useBytes=TRUE)
cat("PASS: Figure 3 caption-based layout injected; no Figure 2 selector\n")

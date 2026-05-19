#!/usr/bin/env bash
# Fetch offline preview dependencies into Resources/preview/vendor/.
# Run once after `git clone`. Network is required only for this script.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/Resources/preview/vendor"
mkdir -p "$VENDOR"/{katex/contrib,katex/fonts,mathjax,mermaid,highlight}

KATEX_VERSION="0.16.11"
MATHJAX_VERSION="3.2.2"
MERMAID_VERSION="11.4.1"
HLJS_VERSION="11.10.0"

fetch() {
  local url="$1" out="$2"
  echo "  $url -> ${out#"$ROOT/"}"
  curl --fail --silent --show-error -L "$url" -o "$out"
}

echo "Fetching KaTeX $KATEX_VERSION..."
fetch "https://cdn.jsdelivr.net/npm/katex@$KATEX_VERSION/dist/katex.min.js" \
      "$VENDOR/katex/katex.min.js"
fetch "https://cdn.jsdelivr.net/npm/katex@$KATEX_VERSION/dist/katex.min.css" \
      "$VENDOR/katex/katex.min.css"
fetch "https://cdn.jsdelivr.net/npm/katex@$KATEX_VERSION/dist/contrib/auto-render.min.js" \
      "$VENDOR/katex/contrib/auto-render.min.js"
# KaTeX fonts referenced from katex.min.css.
for font in KaTeX_AMS-Regular KaTeX_Caligraphic-Bold KaTeX_Caligraphic-Regular \
            KaTeX_Fraktur-Bold KaTeX_Fraktur-Regular KaTeX_Main-Bold \
            KaTeX_Main-BoldItalic KaTeX_Main-Italic KaTeX_Main-Regular \
            KaTeX_Math-BoldItalic KaTeX_Math-Italic KaTeX_SansSerif-Bold \
            KaTeX_SansSerif-Italic KaTeX_SansSerif-Regular KaTeX_Script-Regular \
            KaTeX_Size1-Regular KaTeX_Size2-Regular KaTeX_Size3-Regular \
            KaTeX_Size4-Regular KaTeX_Typewriter-Regular; do
  for ext in woff2 woff ttf; do
    fetch "https://cdn.jsdelivr.net/npm/katex@$KATEX_VERSION/dist/fonts/${font}.${ext}" \
          "$VENDOR/katex/fonts/${font}.${ext}" || true
  done
done

echo "Fetching MathJax $MATHJAX_VERSION (tex-svg standalone)..."
fetch "https://cdn.jsdelivr.net/npm/mathjax@$MATHJAX_VERSION/es5/tex-svg.js" \
      "$VENDOR/mathjax/tex-svg.js"

echo "Fetching Mermaid $MERMAID_VERSION..."
fetch "https://cdn.jsdelivr.net/npm/mermaid@$MERMAID_VERSION/dist/mermaid.min.js" \
      "$VENDOR/mermaid/mermaid.min.js"

echo "Fetching highlight.js $HLJS_VERSION..."
fetch "https://cdn.jsdelivr.net/npm/@highlightjs/cdn-assets@$HLJS_VERSION/highlight.min.js" \
      "$VENDOR/highlight/highlight.min.js"
fetch "https://cdn.jsdelivr.net/npm/@highlightjs/cdn-assets@$HLJS_VERSION/styles/github.min.css" \
      "$VENDOR/highlight/github.min.css"
fetch "https://cdn.jsdelivr.net/npm/@highlightjs/cdn-assets@$HLJS_VERSION/styles/github-dark.min.css" \
      "$VENDOR/highlight/github-dark.min.css"

echo "Done. Vendor assets in $VENDOR"
ls -la "$VENDOR"

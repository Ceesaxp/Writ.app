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

# Every vendored library carries its own licence, and the text has to travel
# with the app in all three distribution channels (DMG, Homebrew, App Store).
# Fetch it from the same pinned version as the code rather than transcribing it
# by hand, and verify what came back: a CDN that answers a bad path with a
# styled 200 error page sails straight past `curl --fail` and past any size
# check, so match on an identifier that only the real licence contains.
#
# MIT      "Permission is hereby granted"
# Apache-2.0 "Apache License"
# BSD-3    "Redistribution and use in source and binary forms"
fetch_license() {
  local url="$1" out="$2" marker="$3" problem=""
  fetch "$url" "$out"
  if grep -q -i -e '<!doctype' -e '<html' "$out"; then
    problem="it is an HTML document — the CDN probably served an error page"
  elif ! grep -q -F -- "$marker" "$out"; then
    problem="it does not contain the expected marker \"$marker\""
  fi
  if [ -n "$problem" ]; then
    echo "ERROR: ${out#"$ROOT/"} is not a licence text: $problem" >&2
    echo "       source:     $url" >&2
    echo "       first line: $(head -1 "$out")" >&2
    exit 1
  fi
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
fetch_license "https://cdn.jsdelivr.net/npm/katex@$KATEX_VERSION/LICENSE" \
              "$VENDOR/katex/LICENSE" "Permission is hereby granted"

echo "Fetching MathJax $MATHJAX_VERSION (tex-svg standalone)..."
fetch "https://cdn.jsdelivr.net/npm/mathjax@$MATHJAX_VERSION/es5/tex-svg.js" \
      "$VENDOR/mathjax/tex-svg.js"
# Apache-2.0 also obliges us to pass on upstream's NOTICE file, but only if
# upstream ships one. mathjax@3.2.2 does not: the published package root holds
# exactly `es5`, `LICENSE`, `package.json` and `README.md`, and the NOTICE path
# 404s. Re-check if MATHJAX_VERSION moves.
fetch_license "https://cdn.jsdelivr.net/npm/mathjax@$MATHJAX_VERSION/LICENSE" \
              "$VENDOR/mathjax/LICENSE" "Apache License"

echo "Fetching Mermaid $MERMAID_VERSION..."
fetch "https://cdn.jsdelivr.net/npm/mermaid@$MERMAID_VERSION/dist/mermaid.min.js" \
      "$VENDOR/mermaid/mermaid.min.js"
fetch_license "https://cdn.jsdelivr.net/npm/mermaid@$MERMAID_VERSION/LICENSE" \
              "$VENDOR/mermaid/LICENSE" "Permission is hereby granted"

echo "Fetching highlight.js $HLJS_VERSION..."
fetch "https://cdn.jsdelivr.net/npm/@highlightjs/cdn-assets@$HLJS_VERSION/highlight.min.js" \
      "$VENDOR/highlight/highlight.min.js"
fetch "https://cdn.jsdelivr.net/npm/@highlightjs/cdn-assets@$HLJS_VERSION/styles/github.min.css" \
      "$VENDOR/highlight/github.min.css"
fetch "https://cdn.jsdelivr.net/npm/@highlightjs/cdn-assets@$HLJS_VERSION/styles/github-dark.min.css" \
      "$VENDOR/highlight/github-dark.min.css"
fetch_license "https://cdn.jsdelivr.net/npm/@highlightjs/cdn-assets@$HLJS_VERSION/LICENSE" \
              "$VENDOR/highlight/LICENSE" \
              "Redistribution and use in source and binary forms"

echo "Done. Vendor assets in $VENDOR"
ls -la "$VENDOR"

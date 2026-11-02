#!/bin/sh
# Builds the web app into docs/ (served by GitHub Pages) from web/kehai.html.
# web/kehai.html is also the claude.ai Artifact page, so it has no <html>/<head> of its own; this wraps it.
set -e
cd "$(dirname "$0")/.."
VERSION=$(date +%Y%m%d%H%M%S)
{
  printf '<!doctype html><html lang="ja"><head><meta charset="utf-8">'
  printf '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">'
  printf '<meta name="theme-color" content="#0F1218">'
  printf '<link rel="manifest" href="manifest.webmanifest">'
  printf '<link rel="apple-touch-icon" href="icons/apple-touch-icon.png">'
  printf '<meta name="apple-mobile-web-app-capable" content="yes"><meta name="mobile-web-app-capable" content="yes">'
  printf '<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent"><meta name="apple-mobile-web-app-title" content="けはい">'
  printf '<style>:root{color-scheme:light;padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)}body{margin:0}img{max-width:100%%}[hidden]{display:none!important}</style>'
  printf '<script>if("serviceWorker" in navigator&&location.protocol==="https:")addEventListener("load",function(){navigator.serviceWorker.register("sw.js").catch(function(){})});</script>'
  printf '</head><body>\n'
  sed 's#<span class="badge" id="buildBadge">試作 0.1</span>#<span class="badge" id="buildBadge">試作 0.1 · Web</span>#' web/kehai.html
  printf '\n</body></html>\n'
} > docs/index.html
sed "s/__VERSION__/$VERSION/" web/sw.js > docs/sw.js
touch docs/.nojekyll
echo "built docs/index.html ($(wc -c < docs/index.html) bytes), sw version $VERSION"

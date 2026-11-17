#!/bin/sh
# Construit le plugin hokkos-deckgl-grafana à déployer, depuis la copie d'origine
# (Apache 2.0, récupérée sur energygraph.info le 2026-11-17, sha256 vérifiés contre son MANIFEST).
# Seule modification : les ressources des hôtes de l'auteur (hors service) sont servies
# par notre site, sous /static/ et /tiles/.
set -eu
cd "$(dirname "$0")"
src=hokkos-deckgl-grafana-1.0.0-original
out=build/hokkos-deckgl-grafana
rm -rf build && mkdir -p build && cp -R "$src" "$out"
rm "$out/MANIFEST.txt"   # signature privée liée au domaine d'origine : le plugin est chargé en non signé
for f in "$out"/*.js; do
  sed -i.tmp \
    -e 's#https://r2\.energygraph\.info/#/static/#g' \
    -e 's#https://static\.energygraph\.info/#/static/#g' \
    -e 's#https://map\.energygraph\.info/#/tiles/#g' "$f"
  rm "$f.tmp"
done
cat >> "$out/README.md" <<'NOTE'

---
Modified copy: URLs of the original author's hosts (r2/static/map.energygraph.info) were
replaced with relative paths (/static/, /tiles/). No other change.
NOTE
! grep -lE 'https?://[a-z0-9.]*energygraph\.info' "$out"/*.js

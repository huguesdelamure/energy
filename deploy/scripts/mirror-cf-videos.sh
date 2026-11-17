#!/bin/sh
# Copie des rasters de facteur de charge (vidéos H.264 par jour, vent et solaire) publiés par
# energygraph.info sur r2.energygraph.info, vers /srv/energy/static/cf/. Reprenable : saute
# les fichiers déjà présents. Plage observée le 2026-11-17 : 2021-01-01 .. 2023-08-31.
set -u
dest=/srv/energy/static/cf
d=2020-12-01
end=2023-09-15
ok=0; miss=0
while [ "$(date -d "$d" +%s)" -le "$(date -d "$end" +%s)" ]; do
  p=$(date -d "$d" +%Y/%m/%d)
  for k in w s; do
    f="$dest/$p/${k}_crf22.mp4"
    [ -s "$f" ] && { ok=$((ok+1)); continue; }
    mkdir -p "$dest/$p"
    code=$(curl -s -m 120 --retry 3 -o "$f.part" -w '%{http_code}' "https://r2.energygraph.info/cf/$p/${k}_crf22.mp4")
    if [ "$code" = 200 ]; then mv "$f.part" "$f"; ok=$((ok+1)); else rm -f "$f.part"; miss=$((miss+1)); fi
  done
  d=$(date -d "$d + 1 day" +%Y-%m-%d)
done
find "$dest" -type d -empty -delete
echo "termine: $ok fichiers presents, $miss absents"

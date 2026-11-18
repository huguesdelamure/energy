#!/usr/bin/env python3
"""Éoliennes OpenStreetMap pour la carte « Wind turbines charge factors » (couche WindPowerCapacityScatterPlot).

    osm_wind.py OUT.pbf

Requête Overpass mondiale (power=generator + generator:source=wind), sortie Arrow IPC (format fichier)
attendue par le plugin deck.gl : lat, lon en Int32 microdegrés, power en W (0 si inconnue).
Écriture atomique : fichier temporaire puis rename.
"""

import csv
import io
import logging
import os
import re
import sys
import time

import pyarrow as pa
import requests

OVERPASS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
    "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
]
QUERY = """[out:csv(::lat,::lon,"generator:output:electricity";false;"\\t")][timeout:900][maxsize:536870912];
nwr["power"="generator"]["generator:source"="wind"];
out center;"""
UNITS = {"w": 1, "kw": 1e3, "mw": 1e6, "gw": 1e9}
POWER_RE = re.compile(r"^\s*([0-9]+(?:[.,][0-9]+)?)\s*([kmg]?w)?\s*$", re.I)
MAX_W = 30e6  # au-delà : valeur de parc saisie sur une éolienne, ignorée

log = logging.getLogger("osm_wind")


def power_w(raw: str) -> float:
    m = POWER_RE.match(raw or "")
    if not m:
        return 0.0
    value = float(m.group(1).replace(",", "."))
    unit = (m.group(2) or "").lower()
    if not unit:  # nombre nu : kW si plausible, sinon W
        unit = "kw" if value < 30000 else "w"
    w = value * UNITS[unit]
    return w if 0 < w <= MAX_W else 0.0


def fetch() -> requests.Response:
    for attempt in range(3):
        for url in OVERPASS:
            try:
                r = requests.post(url, data={"data": QUERY}, timeout=1000,
                                  headers={"User-Agent": "energy-collector/1.0"})
                r.raise_for_status()
                return r
            except requests.RequestException as e:
                log.warning("%s : %s", url, e)
        time.sleep(300)
    raise SystemExit("Overpass injoignable")


def main(out: str) -> None:
    r = fetch()
    lat, lon, power = [], [], []
    for row in csv.reader(io.StringIO(r.text), delimiter="\t"):
        if len(row) < 2 or not row[0] or not row[1]:
            continue
        lat.append(round(float(row[0]) * 1e6))
        lon.append(round(float(row[1]) * 1e6))
        power.append(power_w(row[2] if len(row) > 2 else ""))
    if len(lat) < 100_000:  # garde-fou : réponse tronquée ou erreur Overpass rendue en 200
        raise SystemExit(f"seulement {len(lat)} éoliennes, fichier non remplacé")
    table = pa.table({
        "lat": pa.array(lat, pa.int32()),
        "lon": pa.array(lon, pa.int32()),
        "power": pa.array(power, pa.float32()),
    })
    tmp = out + ".tmp"
    with pa.OSFile(tmp, "wb") as f, pa.ipc.new_file(f, table.schema) as w:
        w.write_table(table)
    os.chmod(tmp, 0o644)
    os.replace(tmp, out)
    known = sum(1 for p in power if p)
    log.info("%d éoliennes, %d avec puissance, %.1f GW", len(lat), known, sum(power) / 1e9)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    main(sys.argv[1])

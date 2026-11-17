"""Génère raw.border depuis la carte des voisinages de entsoe-py (zones de prix).
Pays et zones de réglage : frontières déduites en ramenant chaque zone de prix à son pays.
Limite connue : pas de frontières internes entre les 4 zones de réglage allemandes."""

import psycopg
from entsoe.mappings import NEIGHBOURS, Area

with psycopg.connect("dbname=energy") as conn, conn.cursor() as cur:
    cur.execute("SELECT d.eic, a.area_type, a.domain_id, a.code, a.country FROM raw.area a JOIN raw.domain d ON d.id = a.domain_id")
    rows = cur.fetchall()
    bzn = {eic: (dom, country) for eic, t, dom, code, country in rows if t == "bzn"}
    by_country = {(t, code): dom for eic, t, dom, code, country in rows if t in ("cty", "cta")}

    pairs = set()
    for a, neighbours in NEIGHBOURS.items():
        for b in neighbours:
            ea, eb = Area[a].code, Area[b].code
            if ea in bzn and eb in bzn:
                pairs.add(("bzn", bzn[ea][0], bzn[eb][0]))
                ca, cb = bzn[ea][1], bzn[eb][1]
                if ca != cb:
                    for t in ("cty", "cta"):
                        if (t, ca) in by_country and (t, cb) in by_country:
                            pairs.add((t, by_country[(t, ca)], by_country[(t, cb)]))
    for t, x, y in list(pairs):
        pairs.add((t, y, x))
    cur.execute("SET ROLE energy")
    cur.executemany("INSERT INTO raw.border VALUES (%s, %s, %s) ON CONFLICT DO NOTHING", sorted(pairs))
    cur.execute("SELECT area_type, count(*) FROM raw.border GROUP BY 1 ORDER BY 1")
    print(cur.fetchall())

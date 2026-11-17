#!/usr/bin/env python3
"""Collecte des sources ouvertes sans clé : Ember (annuel + mensuel) et ODRÉ (registre des installations).

    sources_collect.py ember
    sources_collect.py odre [--snapshot 311224 ...]   (défaut : registre courant + instantanés absents)

Ember : fichiers complets rechargés dans une transaction (quelques Mo).
ODRÉ : un instantané par fin d'année (registre au 31/12) + le registre courant, réécrits en entier.
"""

import argparse
import csv
import io
import logging
import sys

import psycopg
import requests

DSN = "dbname=energy"
EMBER = {
    "year": "https://files.ember-energy.org/public-downloads/generation/outputs/release_generation_yearly_global.csv",
    "month": "https://files.ember-energy.org/public-downloads/generation/outputs/release_generation_monthly_global.csv",
}
ODRE = "https://odre.opendatasoft.com/api/explore/v2.1/catalog/datasets"
ODRE_DATASET = "registre-national-installation-production-stockage-electricite-agrege"

log = logging.getLogger("sources")


def num(v):
    return float(v) if v not in (None, "") else None


def flag(v):
    return {"True": True, "False": False}.get(v)


def ember(conn):
    rows = []
    for period, url in EMBER.items():
        r = requests.get(url, timeout=300)
        r.raise_for_status()
        for x in csv.DictReader(io.StringIO(r.content.decode("utf-8-sig"))):
            date = f"{x['Year']}-01-01" if period == "year" else x["Date"]
            rows.append((period, date, x["Area"], x["ISO 3 code"] or None, x["Area type"], x["Electricity source"],
                         x["Is aggregated source"] == "True", num(x["Generation (TWh)"]), num(x.get("Capacity (GW)")),
                         num(x["Emissions (MtCO2e)"]), num(x["Emissions intensity (gCO2e/kWh)"]),
                         x["Continent"] or None, x["Ember region"] or None, flag(x["EU member"]),
                         flag(x["OECD member"]), flag(x["G20 member"]), flag(x["G7 member"])))
        log.info("ember %s : %d lignes", period, len(rows))
    with conn.cursor() as cur:
        cur.execute("DELETE FROM raw.ember")
        with cur.copy("COPY raw.ember FROM STDIN") as cp:
            for row in rows:
                cp.write_row(row)
    conn.commit()
    log.info("ember : %d lignes chargées", len(rows))


ODRE_FIELDS = [
    "nominstallation", "codeeicresourceobject", "codeinseecommune", "commune", "codedepartement", "departement",
    "coderegion", "region", "datemiseenservice", "codefiliere", "filiere", "codecombustible",
    "codescombustiblessecondaires", "codetechnologie", "technologie", "puismaxinstallee", "puismaxrac",
    "nbgroupes", "nbinstallations", "regime", "energieannuelleglissanteinjectee", "energieannuelleinjectee",
]


def odre_snapshot(conn, snapshot):
    """snapshot : '' pour le registre courant, sinon 'JJMMAA' (ex. 311224)."""
    ds = ODRE_DATASET + (f"-{snapshot}" if snapshot else "")
    r = requests.get(f"{ODRE}/{ds}/exports/csv", params={"delimiter": ";"}, timeout=600)
    r.raise_for_status()
    reader = csv.DictReader(io.StringIO(r.content.decode("utf-8-sig")), delimiter=";")
    year = 2000 + int(snapshot[-2:]) if snapshot else None
    rows = []
    for x in reader:
        # Les instantanés annuels nomment l'énergie "energieannuelleinjectee", le courant "...glissante...".
        energy = x.get("energieannuelleglissanteinjectee") or x.get("energieannuelleinjectee")
        mes = x.get("datemiseenservice") or None
        if mes and "/" in mes:
            d, m, y = mes.split("/")
            mes = f"{y}-{m}-{d}"
        rows.append((snapshot or "current", year, x.get("nominstallation"), x.get("codeeicresourceobject") or None,
                     x.get("codeinseecommune") or None, x.get("commune"), x.get("codedepartement"),
                     x.get("departement"), x.get("coderegion"), x.get("region"), mes, x.get("codefiliere"),
                     x.get("filiere"), x.get("codecombustible") or None, x.get("codescombustiblessecondaires") or None,
                     x.get("codetechnologie") or None, x.get("technologie"), num(x.get("puismaxinstallee")),
                     num(x.get("puismaxrac")), num(x.get("nbgroupes")), num(x.get("nbinstallations")),
                     x.get("regime"), num(energy)))
    with conn.cursor() as cur:
        cur.execute("DELETE FROM raw.odre_installation WHERE snapshot = %s", (snapshot or "current",))
        with cur.copy("COPY raw.odre_installation (snapshot, year, name, eic, insee, commune, dep_code, departement, "
                      "region_code, region, commissioning, filiere_code, filiere, combustible_code, "
                      "combustible_secondary_code, technology_code, technology, kw_installed, kw_rac, groups, "
                      "installations, regime, kwh_year) FROM STDIN") as cp:
            for row in rows:
                cp.write_row(row)
    conn.commit()
    log.info("odre %s : %d installations", ds, len(rows))


def odre(conn, snapshots):
    if not snapshots:
        r = requests.get(ODRE, params={"where": f'startswith(dataset_id, "{ODRE_DATASET}-")', "limit": 100}, timeout=60)
        r.raise_for_status()
        available = sorted(d["dataset_id"].rsplit("-", 1)[1] for d in r.json()["results"])
        with conn.cursor() as cur:
            cur.execute("SELECT DISTINCT snapshot FROM raw.odre_installation")
            loaded = {s for (s,) in cur.fetchall()}
        snapshots = [s for s in available if s not in loaded] + [""]
    for s in snapshots:
        odre_snapshot(conn, s)


def communes(conn):
    """Centre géographique des communes et arrondissements municipaux (geo.api.gouv.fr)."""
    rows = {}
    for kind in ("commune-actuelle", "arrondissement-municipal"):
        r = requests.get("https://geo.api.gouv.fr/communes",
                         params={"fields": "code,nom,centre", "type": kind, "format": "json"}, timeout=300)
        r.raise_for_status()
        for c in r.json():
            if c.get("centre"):
                lon, lat = c["centre"]["coordinates"]
                rows[c["code"]] = (c["code"], c["nom"], lon, lat)
    with conn.cursor() as cur:
        cur.execute("DELETE FROM raw.commune")
        with cur.copy("COPY raw.commune FROM STDIN") as cp:
            for row in rows.values():
                cp.write_row(row)
    conn.commit()
    log.info("communes : %d", len(rows))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("ember")
    sub.add_parser("communes")
    o = sub.add_parser("odre")
    o.add_argument("--snapshot", action="append", default=[])
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s", stream=sys.stdout)
    with psycopg.connect(DSN) as conn:
        if args.cmd == "ember":
            ember(conn)
        elif args.cmd == "communes":
            communes(conn)
        else:
            odre(conn, args.snapshot)


if __name__ == "__main__":
    main()

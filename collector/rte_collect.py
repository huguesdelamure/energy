#!/usr/bin/env python3
"""Collecte API Data RTE -> PostgreSQL (schéma raw).

    rte_collect.py backfill {generation,unavailability} [--since 2015-01-01]
    rte_collect.py update [--days 3]

generation     : Actual Generation v1, actual_generations_per_unit, fenêtres de 7 jours calées sur minuit
                 heure de Paris (l'API refuse les fenêtres < 1 jour local et > ~1 mois).
unavailability : Unavailability Additional Information v7, filtre sur la date de PUBLICATION, toutes les
                 versions renvoyées : la collecte par fenêtres de publication reconstitue l'historique complet.
                 Fenêtres de 7 jours (réponse plafonnée à 1000 messages, 206 au-delà : on redécoupe).
Identifiants : /etc/energy/rte.b64 (client_id:client_secret en base64). Journal : raw.fetch_log.
"""

import argparse
import json
import logging
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import UTC, datetime, timedelta
from zoneinfo import ZoneInfo

import psycopg

DSN = "dbname=energy"
CRED = "/etc/energy/rte.b64"
API = "https://digital.iservices.rte-france.com"
GEN = API + "/open_api/actual_generation/v1/actual_generations_per_unit"
UNAV = API + "/open_api/unavailability_additional_information/v7/generation_unavailabilities"
PARIS = ZoneInfo("Europe/Paris")
SETTLED = timedelta(days=7)

log = logging.getLogger("rte")


class Api:
    def __init__(self):
        self.b64 = open(CRED).read().strip()
        self.token, self.expires = None, 0.0

    def _token(self):
        if time.monotonic() < self.expires - 60:
            return self.token
        req = urllib.request.Request(API + "/token/oauth/", method="POST",
                                     headers={"Authorization": f"Basic {self.b64}"})
        with urllib.request.urlopen(req, timeout=60) as r:
            d = json.load(r)
        self.token, self.expires = d["access_token"], time.monotonic() + d["expires_in"]
        return self.token

    def get(self, url, params):
        """Renvoie (statut HTTP, corps JSON). 206 = réponse tronquée à 1000 éléments."""
        q = urllib.parse.urlencode(params, safe=":")
        for attempt in range(5):
            req = urllib.request.Request(f"{url}?{q}", headers={"Authorization": f"Bearer {self._token()}"})
            try:
                with urllib.request.urlopen(req, timeout=180) as r:
                    return r.status, json.load(r)
            except urllib.error.HTTPError as e:
                body = e.read().decode(errors="replace")[:300]
                if e.code in (429, 500, 502, 503, 504):
                    log.warning("HTTP %s, nouvel essai", e.code)
                    time.sleep(20 * (attempt + 1))
                    continue
                raise RuntimeError(f"HTTP {e.code}: {body}") from None
            except OSError as e:
                log.warning("réseau: %s", e)
                time.sleep(20 * (attempt + 1))
        raise RuntimeError("API RTE indisponible après 5 essais")


def iso_utc(t):
    return t.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def iso_paris(t):
    return t.astimezone(PARIS).isoformat(timespec="seconds")


class Store:
    def __init__(self, conn):
        self.conn = conn
        with conn.cursor() as cur:
            cur.execute("SELECT eic, id FROM raw.rte_unit")
            self.units = dict(cur.fetchall())

    def unit_id(self, cur, eic, name, ptype=None, capacity=None):
        if eic not in self.units:
            cur.execute("INSERT INTO raw.rte_unit (eic, name, production_type, installed_capacity) "
                        "VALUES (%s, %s, %s, %s) ON CONFLICT (eic) DO UPDATE SET name = EXCLUDED.name RETURNING id",
                        (eic, name, ptype, capacity))
            self.units[eic] = cur.fetchone()[0]
        elif ptype or capacity:
            cur.execute("UPDATE raw.rte_unit SET production_type = coalesce(%s, production_type), "
                        "installed_capacity = coalesce(%s, installed_capacity) WHERE eic = %s", (ptype, capacity, eic))
        return self.units[eic]

    def write_generation(self, data):
        rows = 0
        with self.conn.cursor() as cur:
            for u in data.get("actual_generations_per_unit", []):
                uid = self.unit_id(cur, u["unit"]["eic_code"], u["unit"]["name"], u["unit"].get("production_type"))
                vals = [(v["start_date"], uid, v.get("value"), v.get("updated_date")) for v in u.get("values", [])]
                cur.executemany(
                    "INSERT INTO raw.rte_generation (time, unit_id, value, updated) VALUES (%s, %s, %s, %s) "
                    "ON CONFLICT (unit_id, time) DO UPDATE SET value = EXCLUDED.value, updated = EXCLUDED.updated", vals)
                rows += len(vals)
        return rows

    def write_unavailability(self, data):
        rows = 0
        with self.conn.cursor() as cur:
            for m in data.get("generation_unavailabilities", []):
                if m.get("fuel_type") == "NUCLEAR" or m.get("affected_asset_or_unit_type") == "GENERATION_UNIT":
                    self.unit_id(cur, m["affected_asset_or_unit_eic_code"], m.get("affected_asset_or_unit_name") or "",
                                 None, m.get("affected_asset_or_unit_installed_capacity"))
                cur.execute(
                    "INSERT INTO raw.rte_unavailability (message_id, identifier, version, unit_eic, unit_name, asset_type, "
                    "fuel_type, installed_capacity, status, type, reason, remarks, participant, creation, publication, "
                    "start_date, end_date) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) "
                    "ON CONFLICT (message_id) DO NOTHING",
                    (m["message_id"], m["identifier"], m["version"], m["affected_asset_or_unit_eic_code"],
                     m.get("affected_asset_or_unit_name"), m.get("affected_asset_or_unit_type"), m.get("fuel_type"),
                     m.get("affected_asset_or_unit_installed_capacity"), m.get("event_status"),
                     m.get("unavailability_type"), m.get("reason"), m.get("remarks"), m.get("market_participant"),
                     m.get("creation_date"), m["publication_date"], m.get("start_date"), m.get("end_date")))
                if cur.rowcount:
                    cur.executemany(
                        "INSERT INTO raw.rte_unavailability_value VALUES (%s, %s, %s, %s, %s) ON CONFLICT DO NOTHING",
                        [(m["message_id"], v["start_date"], v["end_date"], v.get("available_capacity"),
                          v.get("unavailable_capacity")) for v in m.get("values", [])])
                rows += 1
        return rows

    def log(self, dataset, start, end, rows, status, detail=None):
        with self.conn.cursor() as cur:
            cur.execute(
                "INSERT INTO raw.fetch_log (dataset, key, period, rows, status, detail) "
                "VALUES (%s, 'FR', tstzrange(%s, %s), %s, %s, %s) "
                "ON CONFLICT (dataset, key, period) DO UPDATE SET fetched_at = now(), rows = EXCLUDED.rows, "
                "status = EXCLUDED.status, detail = EXCLUDED.detail", (dataset, start, end, rows, status, detail))

    def settled(self, dataset, start, end):
        with self.conn.cursor() as cur:
            cur.execute("SELECT 1 FROM raw.fetch_log WHERE dataset = %s AND key = 'FR' AND period = tstzrange(%s, %s) "
                        "AND status IN ('ok', 'empty') AND fetched_at > upper(period) + %s",
                        (dataset, start, end, SETTLED))
            return cur.fetchone() is not None


def fetch(api, store, kind, start, end):
    """Collecte une fenêtre ; pour les indisponibilités, redécoupe si la réponse est tronquée (206)."""
    if kind == "generation":
        _, data = api.get(GEN, {"start_date": iso_paris(start), "end_date": iso_paris(end)})
        return store.write_generation(data)
    status, data = api.get(UNAV, {"start_date": iso_utc(start), "end_date": iso_utc(end)})
    if status == 206 and end - start > timedelta(hours=6):
        mid = start + (end - start) / 2
        return fetch(api, store, kind, start, mid) + fetch(api, store, kind, mid, end)
    if status == 206:
        log.warning("fenêtre de 6 h encore tronquée : %s", start)
    return store.write_unavailability(data)


def windows(since, until):
    """Fenêtres de 7 jours calées sur minuit à Paris, de la plus récente à la plus ancienne."""
    out, t = [], since
    while t < until:
        nxt = min(t + timedelta(days=7), until)
        out.append((t, nxt))
        t = nxt
    return out[::-1]


def run(api, store, kind, since, until, force=False):
    ds = "RTE_" + kind.upper()[:4]
    for start, end in windows(since, until):
        if not force and store.settled(ds, start, end):
            continue
        try:
            n = fetch(api, store, kind, start, end)
            store.log(ds, start, end, n, "ok" if n else "empty")
            store.conn.commit()
            log.info("%s %s..%s %d", kind, start.date(), end.date(), n)
        except Exception as e:
            store.conn.rollback()
            store.log(ds, start, end, None, "error", str(e)[:1000])
            store.conn.commit()
            log.error("%s %s..%s : %s", kind, start.date(), end.date(), e)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("backfill")
    b.add_argument("kind", choices=["generation", "unavailability"])
    b.add_argument("--since", default="2015-01-01")
    u = sub.add_parser("update")
    u.add_argument("--days", type=int, default=3)
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s", stream=sys.stdout)

    today = datetime.now(PARIS).replace(hour=0, minute=0, second=0, microsecond=0)
    with psycopg.connect(DSN) as conn:
        store, api = Store(conn), Api()
        if args.cmd == "backfill":
            since = datetime.fromisoformat(args.since).replace(tzinfo=PARIS)
            run(api, store, args.kind, since, today + timedelta(days=1))
        else:
            since = today - timedelta(days=args.days)
            for kind in ("generation", "unavailability"):
                # fenêtre glissante : jusqu'à maintenant pour les indisponibilités (publication), J+1 pour la production
                end = datetime.now(UTC) if kind == "unavailability" else today + timedelta(days=1)
                run(api, store, kind, since, end, force=True)


if __name__ == "__main__":
    main()

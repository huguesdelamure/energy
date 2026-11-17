#!/usr/bin/env python3
"""Collecte ENTSO-E Transparency -> PostgreSQL (schéma raw).

    entsoe_collect.py backfill A75 [--since 2015-01-01] [--key EIC]
    entsoe_collect.py update [--days 3]

Chaque requête (jeu, domaine ou frontière, période) est tracée dans raw.fetch_log.
Le backfill saute les périodes déjà collectées et consolidées ; update re-collecte
les derniers jours de tous les jeux (les données ENTSO-E sont corrigées a posteriori).
"""

import argparse
import io
import logging
import re
import sys
import time
import zipfile
from datetime import UTC, datetime, timedelta
from xml.etree import ElementTree as ET

import psycopg
import requests

API = "https://web-api.tp.entsoe.eu/api"
TOKEN_FILE = "/etc/energy/entsoe.token"
DSN = "dbname=energy"
MIN_INTERVAL = 0.25          # s entre deux requêtes : 240/min, sous la limite de 400/min
SETTLED = timedelta(days=7)  # au-delà, une période collectée n'est plus re-demandée en backfill

log = logging.getLogger("entsoe")

# jeu -> (paramètres fixes, taille de fenêtre max acceptée par l'API, types de zones interrogés)
DATASETS = {
    "A75":   ({"documentType": "A75", "processType": "A16"}, "year", ("cty", "bzn", "cta")),
    "A73":   ({"documentType": "A73", "processType": "A16"}, "day",  ("cta",)),
    "A44":   ({"documentType": "A44", "contract_MarketAgreement.type": "A01"}, "year", ("bzn",)),
    "A65":   ({"documentType": "A65", "processType": "A16"}, "year", ("cty", "bzn", "cta")),
    "A68":   ({"documentType": "A68", "processType": "A33"}, "year", ("cty", "bzn")),
    "A69":   ({"documentType": "A69", "processType": "A01"}, "year", ("bzn",)),
    "A11":   ({"documentType": "A11"}, "year", None),
    "A09":   ({"documentType": "A09", "contract_MarketAgreement.Type": "A05"}, "year", None),
    "A09DA": ({"documentType": "A09", "contract_MarketAgreement.Type": "A01"}, "year", None),
}
FLOW_KIND = {"A11": "physical", "A09": "commercial", "A09DA": "commercial_day_ahead"}


# --- API ---------------------------------------------------------------------

class Api:
    def __init__(self, token):
        self.token = token
        self.session = requests.Session()
        self.last = 0.0

    def get(self, params):
        """Renvoie la liste des documents XML (un .zip peut en contenir plusieurs), [] si pas de données."""
        params = {**params, "securityToken": self.token}
        for attempt in range(6):
            wait = MIN_INTERVAL - (time.monotonic() - self.last)
            if wait > 0:
                time.sleep(wait)
            self.last = time.monotonic()
            try:
                r = self.session.get(API, params=params, timeout=120)
            except requests.RequestException as e:
                log.warning("réseau: %s, nouvel essai", e)
                time.sleep(10 * (attempt + 1))
                continue
            if r.status_code == 429 or r.status_code >= 500:
                log.warning("HTTP %s, nouvel essai", r.status_code)
                time.sleep(30 * (attempt + 1))
                continue
            docs = unzip(r.content)
            if any(is_no_data(d) for d in docs):
                return []
            if r.status_code != 200:
                raise RuntimeError(f"HTTP {r.status_code}: {ack_text(docs[0])[:300]}")
            return docs
        raise RuntimeError("API indisponible après 6 essais")


def unzip(content):
    if content[:2] != b"PK":
        return [content]
    with zipfile.ZipFile(io.BytesIO(content)) as z:
        return [z.read(n) for n in z.namelist()]


def strip_ns(root):
    for el in root.iter():
        el.tag = el.tag.rsplit("}", 1)[-1]
    return root


def is_no_data(doc):
    # Acknowledgement_MarketDocument, Reason/code 999 = "No matching data found"
    return b"Acknowledgement_MarketDocument" in doc[:500] and b"<code>999</code>" in doc


def ack_text(doc):
    try:
        return " ".join(t.text or "" for t in strip_ns(ET.fromstring(doc)).iter("text"))
    except ET.ParseError:
        return doc[:300].decode(errors="replace")


# --- XML -> points -------------------------------------------------------------

def minutes(resolution):
    m = re.fullmatch(r"P(?:(\d+)Y)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?)?", resolution)
    y, d, h, mi = (int(x or 0) for x in m.groups())
    return y * 525600 + d * 1440 + h * 60 + mi


def text(el, path):
    found = el.find(path)
    return found.text if found is not None else None


def parse_ts(doc):
    """Itère (série, time, dur_min, valeur) ; série = dict des attributs utiles du TimeSeries."""
    root = strip_ns(ET.fromstring(doc))
    for ts in root.iter("TimeSeries"):
        meta = {
            "psr": text(ts, "MktPSRType/psrType"),
            "unit_eic": text(ts, "MktPSRType/PowerSystemResources/mRID"),
            "unit_name": text(ts, "MktPSRType/PowerSystemResources/name"),
            "in": text(ts, "inBiddingZone_Domain.mRID") or text(ts, "in_Domain.mRID"),
            "out": text(ts, "outBiddingZone_Domain.mRID") or text(ts, "out_Domain.mRID"),
            "curve": text(ts, "curveType") or "A01",
        }
        for period in ts.iter("Period"):
            start = datetime.fromisoformat(text(period, "timeInterval/start").replace("Z", "+00:00"))
            end = datetime.fromisoformat(text(period, "timeInterval/end").replace("Z", "+00:00"))
            dur = minutes(text(period, "resolution"))
            points = {}
            for p in period.iter("Point"):
                v = text(p, "quantity") or text(p, "price.amount")
                points[int(text(p, "position"))] = float(v)
            if not points:
                continue
            step = timedelta(minutes=dur)
            if meta["curve"] == "A03" and dur < 525600:
                # Courbe compressée : une position absente reprend la valeur précédente.
                n = int((end - start) / step)
                last = None
                for pos in range(1, n + 1):
                    last = points.get(pos, last)
                    if last is not None:
                        yield meta, start + (pos - 1) * step, dur, last
            else:
                for pos, v in sorted(points.items()):
                    yield meta, start + (pos - 1) * step, dur, v


# --- Base ----------------------------------------------------------------------

def upsert(cur, table, cols, key, rows):
    """COPY dans une table temporaire puis INSERT ... ON CONFLICT DO UPDATE."""
    if not rows:
        return 0
    cur.execute(f"CREATE TEMP TABLE IF NOT EXISTS _in (LIKE {table} INCLUDING DEFAULTS) ON COMMIT DROP")
    cur.execute("TRUNCATE _in")
    with cur.copy(f"COPY _in ({', '.join(cols)}) FROM STDIN") as cp:
        for r in rows:
            cp.write_row(r)
    upd = ", ".join(f"{c} = EXCLUDED.{c}" for c in cols if c not in key)
    cur.execute(
        f"INSERT INTO {table} ({', '.join(cols)}) "
        f"SELECT DISTINCT ON ({', '.join(key)}) {', '.join(cols)} FROM _in "
        f"ON CONFLICT ({', '.join(key)}) DO UPDATE SET {upd}"
    )
    cur.execute("DROP TABLE _in")
    return len(rows)


class Store:
    def __init__(self, conn):
        self.conn = conn
        with conn.cursor() as cur:
            cur.execute("SELECT eic, id FROM raw.domain")
            self.domain = dict(cur.fetchall())
            cur.execute("SELECT psr, ptype FROM raw.psr_type")
            self.ptype = dict(cur.fetchall())
            cur.execute("SELECT eic, id FROM raw.unit")
            self.unit = dict(cur.fetchall())
            cur.execute("SELECT d.eic, min(a.country) FROM raw.area a JOIN raw.domain d ON d.id = a.domain_id GROUP BY 1")
            self.country = dict(cur.fetchall())

    def unit_id(self, cur, eic, name, domain_eic, psr):
        if eic not in self.unit:
            cur.execute(
                "INSERT INTO raw.unit (eic, name, domain_id, country, ptype) VALUES (%s, %s, %s, %s, %s) "
                "ON CONFLICT (eic) DO UPDATE SET name = EXCLUDED.name RETURNING id",
                (eic, name or eic, self.domain.get(domain_eic), self.country.get(domain_eic), self.ptype.get(psr)),
            )
            self.unit[eic] = cur.fetchone()[0]
        return self.unit[eic]

    def write(self, dataset, key, docs):
        """Convertit les documents en lignes et les écrit. Renvoie le nombre de lignes."""
        rows = []
        with self.conn.cursor() as cur:
            for doc in docs:
                for m, t, dur, v in parse_ts(doc):
                    if dataset == "A75":
                        if m["psr"] not in self.ptype:
                            continue
                        consumption = m["out"] is not None and m["in"] is None
                        rows.append((t, self.domain[key], self.ptype[m["psr"]], dur,
                                     None if consumption else v, v if consumption else None))
                    elif dataset == "A73":
                        uid = self.unit_id(cur, m["unit_eic"], m["unit_name"], key, m["psr"])
                        rows.append((t, uid, dur, v))
                    elif dataset == "A44":
                        rows.append((t, self.domain[key], dur, v))
                    elif dataset == "A65":
                        rows.append((t, self.domain[key], dur, v))
                    elif dataset == "A68":
                        if m["psr"] in self.ptype:
                            rows.append((t.year, self.domain[key], self.ptype[m["psr"]], v))
                    elif dataset == "A69":
                        if m["psr"] in self.ptype:
                            rows.append((t, self.domain[key], self.ptype[m["psr"]], dur, v))
                    else:  # flux
                        src, dst = key.split(">")
                        rows.append((t, FLOW_KIND[dataset], self.domain[src], self.domain[dst], dur, v))

            if dataset == "A75":
                rows = merge_gen_cons(rows)
                n = upsert(cur, "raw.generation", ["time", "domain_id", "ptype", "dur", "gen", "cons"],
                           ["domain_id", "ptype", "time"], rows)
            elif dataset == "A73":
                n = upsert(cur, "raw.generation_unit", ["time", "unit_id", "dur", "gen"], ["unit_id", "time"], rows)
            elif dataset == "A44":
                n = upsert(cur, "raw.day_ahead_price", ["time", "domain_id", "dur", "price"],
                           ["domain_id", "dur", "time"], rows)
            elif dataset == "A65":
                n = upsert(cur, "raw.load", ["time", "domain_id", "dur", "value"], ["domain_id", "time"], rows)
            elif dataset == "A68":
                n = upsert(cur, "raw.installed_capacity", ["year", "domain_id", "ptype", "value"],
                           ["domain_id", "ptype", "year"], rows)
            elif dataset == "A69":
                n = upsert(cur, "raw.generation_forecast", ["time", "domain_id", "ptype", "dur", "value"],
                           ["domain_id", "ptype", "time"], rows)
            else:
                n = upsert(cur, "raw.flow", ["time", "kind", "from_id", "to_id", "dur", "value"],
                           ["kind", "from_id", "to_id", "time"], rows)
        return n

    def log(self, dataset, key, start, end, rows, status, detail=None):
        with self.conn.cursor() as cur:
            cur.execute(
                "INSERT INTO raw.fetch_log (dataset, key, period, rows, status, detail) "
                "VALUES (%s, %s, tstzrange(%s, %s), %s, %s, %s) "
                "ON CONFLICT (dataset, key, period) DO UPDATE SET fetched_at = now(), "
                "rows = EXCLUDED.rows, status = EXCLUDED.status, detail = EXCLUDED.detail",
                (dataset, key, start, end, rows, status, detail),
            )

    def settled(self, dataset, key, start, end):
        """Vrai si la période a déjà été collectée après sa consolidation."""
        with self.conn.cursor() as cur:
            cur.execute(
                "SELECT 1 FROM raw.fetch_log WHERE dataset = %s AND key = %s AND period = tstzrange(%s, %s) "
                "AND status IN ('ok', 'empty') AND fetched_at > upper(period) + %s",
                (dataset, key, start, end, SETTLED),
            )
            return cur.fetchone() is not None

    def keys(self, dataset):
        """Domaines (EIC) ou frontières (EIC>EIC) à interroger pour un jeu."""
        with self.conn.cursor() as cur:
            types = DATASETS[dataset][2]
            if types:
                cur.execute(
                    "SELECT DISTINCT d.eic FROM raw.area a JOIN raw.domain d ON d.id = a.domain_id "
                    "WHERE a.area_type = ANY(%s) ORDER BY 1", (list(types),))
            else:
                cur.execute(
                    "SELECT DISTINCT f.eic || '>' || t.eic FROM raw.border b "
                    "JOIN raw.domain f ON f.id = b.from_id JOIN raw.domain t ON t.id = b.to_id ORDER BY 1")
            return [r[0] for r in cur.fetchall()]


def merge_gen_cons(rows):
    """A75 livre production et consommation dans deux TimeSeries : une ligne par (domaine, filière, instant)."""
    merged = {}
    for t, d, p, dur, gen, cons in rows:
        cur = merged.get((d, p, t))
        if cur is None:
            merged[(d, p, t)] = [t, d, p, dur, gen, cons]
        else:
            cur[4] = gen if gen is not None else cur[4]
            cur[5] = cons if cons is not None else cur[5]
    return [tuple(r) for r in merged.values()]


# --- Planification -------------------------------------------------------------

def windows(since, until, size):
    """Fenêtres UTC alignées sur l'année ou le jour, de la plus récente à la plus ancienne."""
    out = []
    t = since
    while t < until:
        nxt = datetime(t.year + 1, 1, 1, tzinfo=UTC) if size == "year" else t + timedelta(days=1)
        out.append((t, min(nxt, until)))
        t = nxt
    return out[::-1]


def params_for(dataset, key, start, end):
    p = dict(DATASETS[dataset][0])
    p["periodStart"] = start.strftime("%Y%m%d%H%M")
    p["periodEnd"] = end.strftime("%Y%m%d%H%M")
    if dataset in ("A75", "A73", "A68", "A69"):
        p["in_Domain"] = key
    elif dataset == "A44":
        p["in_Domain"] = p["out_Domain"] = key
    elif dataset == "A65":
        p["outBiddingZone_Domain"] = key
    else:
        src, dst = key.split(">")
        p["out_Domain"], p["in_Domain"] = src, dst
    return p


def run(api, store, dataset, keys, since, until, force):
    size = DATASETS[dataset][1]
    for start, end in windows(since, until, size):
        for key in keys:
            if not force and store.settled(dataset, key, start, end):
                continue
            try:
                docs = api.get(params_for(dataset, key, start, end))
                n = store.write(dataset, key, docs)
                store.log(dataset, key, start, end, n, "ok" if n else "empty")
                store.conn.commit()
                log.info("%s %s %s..%s %d lignes", dataset, key, start.date(), end.date(), n)
            except Exception as e:  # une période en erreur ne bloque pas les autres
                store.conn.rollback()
                store.log(dataset, key, start, end, None, "error", str(e)[:1000])
                store.conn.commit()
                log.error("%s %s %s..%s : %s", dataset, key, start.date(), end.date(), e)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("backfill")
    b.add_argument("dataset", choices=DATASETS)
    b.add_argument("--since", default="2015-01-01")
    b.add_argument("--until")
    b.add_argument("--key", help="un seul EIC (ou EIC>EIC)")
    b.add_argument("--force", action="store_true")
    u = sub.add_parser("update")
    u.add_argument("--days", type=int, default=3)
    u.add_argument("--dataset", action="append", choices=DATASETS)
    args = ap.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s", stream=sys.stdout)
    with open(TOKEN_FILE) as f:
        api = Api(f.read().strip())
    now = datetime.now(UTC)
    tomorrow = datetime(now.year, now.month, now.day, tzinfo=UTC) + timedelta(days=2)  # inclut le day-ahead J+1

    with psycopg.connect(DSN) as conn:
        store = Store(conn)
        if args.cmd == "backfill":
            since = datetime.fromisoformat(args.since).replace(tzinfo=UTC)
            until = datetime.fromisoformat(args.until).replace(tzinfo=UTC) if args.until else tomorrow
            keys = [args.key] if args.key else store.keys(args.dataset)
            run(api, store, args.dataset, keys, since, until, args.force)
        else:
            since = datetime(now.year, now.month, now.day, tzinfo=UTC) - timedelta(days=args.days)
            for ds in args.dataset or [d for d in DATASETS if d != "A68"]:
                # Fenêtre courte en update : on interroge [since, demain[ d'un bloc, même pour A73 (jour par jour).
                if DATASETS[ds][1] == "day":
                    run(api, store, ds, store.keys(ds), since, tomorrow, True)
                else:
                    for key in store.keys(ds):
                        try:
                            docs = api.get(params_for(ds, key, since, tomorrow))
                            n = store.write(ds, key, docs)
                            store.log(ds, key, since, tomorrow, n, "ok" if n else "empty")
                            conn.commit()
                        except Exception as e:
                            conn.rollback()
                            store.log(ds, key, since, tomorrow, None, "error", str(e)[:1000])
                            conn.commit()
                            log.error("%s %s update : %s", ds, key, e)


if __name__ == "__main__":
    main()

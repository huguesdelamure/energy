#!/usr/bin/env python3
"""Importe les dashboards d'origine dans Grafana, en adaptant à la volée (les JSON restent intacts) :
- datasources PostgreSQL d'origine (I3yziRGVz, 000000001) -> energy-pg ;
- dossiers recréés avec leurs UID d'origine, liens de la Home (folderId numériques) -> folderUID ;
- ressources de r2.energygraph.info -> /static/ (copiées localement).
Idempotent (overwrite). À lancer sur le serveur : sudo python3 -I import.py <dossier des JSON>.
"""

import base64
import json
import re
import sys
import urllib.request
from pathlib import Path

GRAFANA = "http://127.0.0.1:3000"
PASSWORD = Path("/root/grafana-admin-password").read_text().strip()
AUTH = "Basic " + base64.b64encode(f"admin:{PASSWORD}".encode()).decode()

FOLDERS = {  # folderId d'origine -> (uid, titre)
    9: ("4NfVpV74k", "Europe electricity"),
    6: ("Wh3vV5G4z", "France Nuclear"),
    17: ("fHcnsVIVz", "France electricity"),
    29: ("cee5ebab-b003-4de7-9eee-399f7f216027", "World Electricity"),
}
INFINITY_UID = "d7489df0-0285-4aad-947c-27b089483f47"
HOME_UID = "e72-tIG4z"
AGGREGATED_AVAILABILITY_UID = "uMjgqrW4z"


def api(method, path, body=None):
    req = urllib.request.Request(GRAFANA + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": AUTH, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def adapt(text):
    text = text.replace('"I3yziRGVz"', '"energy-pg"').replace('"000000001"', '"energy-pg"')
    text = text.replace('"type":"postgres"', '"type":"grafana-postgresql-datasource"')
    text = text.replace('"type": "postgres"', '"type": "grafana-postgresql-datasource"')
    # Puissance du parc nucléaire codée en dur dans l'original (avant Flamanville 3) : 61370 -> 62990 MW.
    text = text.replace("61370", "62990")
    text = text.replace("https://r2.energygraph.info/", "/static/")
    # Variables insérées sans guillemets dans l'original : une valeur unique arrive brute en SQL
    # (1 hour, nuclear) et casse la requête.
    text = text.replace("$production_types, $__timeFrom(), $__timeTo())", "'$production_types', $__timeFrom(), $__timeTo())")
    text = text.replace("::production_type[], $bucket_width,", "::production_type[], '$bucket_width',")
    # Business Text >= 5 : handlebars n'est plus global dans les helpers, il est fourni par context.
    text = re.sub(r"(?<!context\.)handlebars\.registerHelper", "context.handlebars.registerHelper", text)
    # Liens absolus vers le site d'origine (liens de panels, entre dashboards) -> relatifs.
    return text.replace("https://energygraph.info/", "/")


def drop_rte_curves(dash):
    """Courbes « rte-AAAA-MM-JJ » ressaisies à la main dans l'original depuis des PDF : aucune source
    publique, la requête renvoie toujours vide. On retire la requête, son override et la variable."""
    for p in dash["panels"]:
        p["targets"] = [t for t in p.get("targets", []) if "multi_origin" not in t.get("rawSql", "")]
        overrides = p.get("fieldConfig", {}).get("overrides")
        if overrides:
            p["fieldConfig"]["overrides"] = [o for o in overrides if "rte" not in str(o["matcher"].get("options"))]
    dash["templating"]["list"] = [v for v in dash["templating"]["list"] if v["name"] != "rte_updates"]


HOME_HEADER = (
    '<h1 id="energy">energy.mgmt0.net</h1>\r\n'
    '<p>Electricity in the World, Europe and France, and its greenhouse gas emissions, '
    'with time series and large scale map visualisations.</p>\r\n'
    '<p>Fork of <a href="https://energygraph.info">energygraph.info</a>, no longer maintained by its author: '
    'dashboards and map plugin from the original site, data collection rebuilt from public sources '
    '(<a href="https://github.com/huguesdelamure/energy">source</a>).</p>'
)
TITLE_SUFFIX = re.compile(r"\s*(?:-\s*energygraph\.info|\(energygraph\.info\))$")


def rebrand(dash):
    """Fork : pas de marque « Energygraph ». Accueil réécrit avec le crédit, suffixe des titres de panels retiré."""
    def walk(panels):
        for p in panels:
            yield p
            yield from walk(p.get("panels", []))
    for p in walk(dash["panels"]):
        if p.get("title"):
            p["title"] = TITLE_SUFFIX.sub("", p["title"])
        if dash["uid"] == HOME_UID and p["type"] == "marcusolsson-dynamictext-panel":
            content = p["options"]["defaultContent"]
            head, sep, rest = content.partition("<div")
            assert sep, "accueil : structure inattendue"
            p["options"]["defaultContent"] = HOME_HEADER + "\r\n" + sep + rest
            grow = 2  # deux lignes de grille pour le paragraphe de crédit
            p["gridPos"]["h"] += grow
            for other in dash["panels"]:
                if other is not p:
                    other["gridPos"]["y"] += grow


def main(src):
    status, _ = api("GET", f"/api/datasources/uid/{INFINITY_UID}")
    if status == 404:
        print("infinity", api("POST", "/api/datasources", {
            "name": "Infinity", "uid": INFINITY_UID, "type": "yesoreyeram-infinity-datasource", "access": "proxy"})[0])

    for uid, title in FOLDERS.values():
        if api("GET", f"/api/folders/{uid}")[0] == 404:
            print("folder", title, api("POST", "/api/folders", {"uid": uid, "title": title})[0])

    for f in sorted(Path(src).glob("*.json")):
        exported = json.loads(adapt(f.read_text()))
        dash, meta = exported["dashboard"], exported["meta"]
        dash["id"] = None
        dash.pop("version", None)
        rebrand(dash)
        if dash["uid"] == AGGREGATED_AVAILABILITY_UID:
            drop_rte_curves(dash)
        if dash["uid"] == HOME_UID:
            for p in dash["panels"]:
                if p["type"] == "dashlist" and p["options"].get("folderId") in FOLDERS:
                    p["options"]["folderUID"] = FOLDERS[p["options"].pop("folderId")][0]
        status, res = api("POST", "/api/dashboards/db", {
            "dashboard": dash, "folderUid": meta.get("folderUid") or "", "overwrite": True,
            "message": "import energygraph.info"})
        print(status, dash["uid"], dash["title"], "" if status == 200 else res)

    print("home", api("PATCH", "/api/org/preferences", {"homeDashboardUID": HOME_UID})[0])


if __name__ == "__main__":
    main(sys.argv[1])

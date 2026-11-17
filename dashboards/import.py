#!/usr/bin/env python3
"""Importe les dashboards d'origine dans Grafana, en adaptant à la volée (les JSON restent intacts) :
- datasources PostgreSQL d'origine (I3yziRGVz, 000000001) -> energy-pg ;
- dossiers recréés avec leurs UID d'origine, liens de la Home (folderId numériques) -> folderUID ;
- ressources de r2.energygraph.info -> /static/ (copiées localement).
Idempotent (overwrite). À lancer sur le serveur : sudo python3 -I import.py <dossier des JSON>.
"""

import base64
import json
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
    return text.replace("https://r2.energygraph.info/", "/static/")


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

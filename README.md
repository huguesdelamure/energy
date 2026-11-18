# energy.mgmt0.net

Republication de [energygraph.info](https://energygraph.info), dont l'auteur a cessé la maintenance :
électricité en Europe, en France et dans le monde, à partir de données publiques, affichée dans Grafana.

Site : https://energy.mgmt0.net

## Crédits

- Dashboards, plugin cartographique et choix de modélisation : auteur d'energygraph.info.
  Les dashboards d'origine sont conservés tels quels dans `dashboards/original/` et adaptés à l'import.
- Plugin `hokkos-deckgl-grafana` 1.0.0 : Apache 2.0, copie d'origine dans `vendor/`,
  seule modification les URL des ressources (voir `vendor/build-deckgl.sh`).

## Sources de données

| Source | Données | Licence / conditions |
|---|---|---|
| [ENTSO-E Transparency](https://transparency.entsoe.eu) | production par filière et par unité, prix day-ahead, flux, consommation, capacités | réutilisation avec attribution, token API |
| [RTE Data](https://data.rte-france.com) | production par réacteur, indisponibilités REMIT (toutes versions) | compte et application Data RTE |
| [ODRÉ](https://odre.opendatasoft.com) | registre national des installations de production (instantanés annuels) | Licence Ouverte |
| [Ember](https://ember-energy.org) | production et émissions mondiales, annuelles et mensuelles | CC-BY 4.0 |
| [Copernicus ERA5](https://cds.climate.copernicus.eu) via [atlite](https://github.com/PyPSA/atlite) | rasters horaires de facteur de charge éolien et solaire | licence Copernicus |
| [OpenStreetMap](https://www.openstreetmap.org) via Overpass | position et puissance des éoliennes (carte World) | ODbL, © contributeurs OpenStreetMap |
| [geo.api.gouv.fr](https://geo.api.gouv.fr) | centres des communes | Licence Ouverte |
| [Natural Earth](https://www.naturalearthdata.com) | contours des pays | domaine public |

## Architecture

- PostgreSQL 18 + TimescaleDB (édition Apache) : tables brutes dans `raw` (jamais exposées),
  fonctions `SECURITY DEFINER` dans `entsoe`, `rte`, `odre`, `ember`, `map`, seules appelables par Grafana.
- Grafana 12 en lecture anonyme. Le rôle `grafana_ro` : exécution des fonctions publiées uniquement,
  transactions en lecture seule, `statement_timeout` 10 s, 5 connexions.
- Collecteurs Python sous `collector/`, lancés par des timers systemd (`deploy/systemd/`).
- Apache en frontal (`deploy/apache/`), ressources statiques des cartes sous `/static/`.
- Sauvegarde : `pg_dump` quotidien dans `/var/backups/energy` sur le serveur, 7 jours gardés
  (`deploy/scripts/energy-backup.sh`, procédure de restauration TimescaleDB en tête du script).
  Copie hors serveur : non faite.
- Rattrapage ENTSO-E complet : `systemd-run --unit=entsoe-backfill-all /usr/local/sbin/entsoe-backfill-all.sh`
  (3 files parallèles, sous la limite de 400 requêtes/min ; reprenable).

## Limites connues

- Disponibilité nucléaire : chaque unité ne compte qu'entre ses bornes d'activité, déduites des publications RTE
  (`raw.rte_refresh_unit_bounds`). Les groupes publiés tardivement par RTE (CNR, 2021-2022) comptent pour 0 avant.
- Dashboards RTE sur plus de 5 ans environ : délai de 10 s dépassé (production horaire non agrégée).
- Courbes « rte-AAAA-MM-JJ » d'Aggregated availability retirées à l'import : ressaisies à la main dans
  l'original, sans source publique.

## Arborescence

| Chemin | Contenu |
|---|---|
| `sql/` | schémas (`0xx`) et fonctions (`1xx`), idempotents, à jouer dans l'ordre en `postgres` |
| `collector/` | `entsoe_collect.py`, `rte_collect.py`, `sources_collect.py` (Ember, ODRÉ, communes), `era5_cf.py`, `osm_wind.py`, `make_borders.py` |
| `dashboards/` | JSON d'origine, `import.py`, contrats des fonctions déduits des dashboards (`spec-*.md`) |
| `deploy/` | unités systemd, vhosts Apache, drop-in Grafana, scripts |
| `tests/` | tests SQL (données synthétiques ou réelles, exécutés en `grafana_ro`) |
| `vendor/` | plugin deck.gl d'origine et son script de build |

## Secrets (hors dépôt, sur le serveur)

| Fichier | Contenu |
|---|---|
| `/etc/energy/entsoe.token` | token API ENTSO-E |
| `/etc/energy/rte.b64` | `client_id:client_secret` Data RTE en base64 |
| `/etc/energy/cdsapirc` | clé Copernicus CDS |
| `/root/grafana-admin-password`, `/root/energy-grafana-ro-password` | comptes Grafana et PostgreSQL |

# energygraph.info : contrat des fonctions SQL (France Nuclear, France electricity, World Electricity, Home)

Source : 13 dashboards de `dash/*.json` (lecture seule). Grafana OSS 10.1.4 (panels), datasource PostgreSQL uid `I3yziRGVz`, Infinity 2.7.1.
Aucune requête n'a été jouée : tout est déduit du JSON. "?" = hypothèse.

## Conventions transverses
- `$__timeFrom()/$__timeTo()` = timestamptz littéraux. Les plages vont dans le FUTUR (nucléaire : `now-1y` -> `now+6M`, `now-2M`->`now+2M`, `now-6M`->`now+6M`) : les fonctions de disponibilité doivent renvoyer des valeurs futures, la production NULL/absente.
- Format `time_series` : colonne `time` (timestamptz) + colonne texte `metric` (= nom de série, `SELECT *, 'production' as metric` l'ajoute à l'appelant) + colonnes numériques. Les autres colonnes texte deviennent des labels (`${__field.labels.eic_code}`).
- Variables multi : `ARRAY[$x]` reçoit `'a','b'` (donc text[]). Variable mono-valeur non quotée : `$update`, `$unav`, `$year` (map) arrivent bruts (entier). `ARRAY[$update]::int[]` : cast explicite côté appelant.
- Variable de requête à 2 colonnes : `__text`, `__value` (convention retenue ; texte=label, valeur=clé).
- Unités : puissance en MW (`megwatt`), énergie en TWh/Wh selon le cas.
- Enum PG `production_type` (cast `::production_type[]` ailleurs) : biomass, fossil_brown_coal_lignite, fossil_coal_derived_gas, fossil_gas, fossil_hard_coal, fossil_oil, fossil_oil_shale, fossil_peat, geothermal, hydro_pumped_storage, hydro_run_of_river_and_poundage, hydro_water_reservoir, marine, nuclear, other, other_renewable, solar, waste, wind_offshore, wind_onshore (valeurs ENTSO-E PsrType en snake_case).
- Pays : AL AT BA BE BG CH CZ DE DK EE ES FI FR GB GE GR HU IE IT LT LV MD ME MK NL NO PL PT RO RS SE SI SK UA XK (34, ISO-2).

## rte.* (source : API Data RTE https://data.rte-france.com/)
Sources probables : "Actual Generation" (`actual_generations_per_unit`, par unité, pas horaire : cf `insertNulls: 3600000` sur gr_6) pour la production ; "Unavailability Additional Information" (`generation_unavailabilities`, REMIT) pour les indisponibilités. Non vérifié (pas d'accès API/doc ici).
Capacité installée nucléaire agrégée = 61370 MW (max codé en dur dans q7IpAJHVz, overrides).
`cre` / `update_id` : le param `'cre'` est une "origine" de snapshot ; les autres origines sont `rte-YYYY-MM-DD` (courbes RTE saisies à la main, cf `rte_updates`). `update_id` = entier identifiant un état de la base REMIT à une date (valeurs vues : 165 = 2022-09-11, 179). Aide de q7 : données "à minuit UTC", donc probablement un snapshot/jour (?). Interprétation libre : `update_id` = rang dense des dates de mise à jour (`updated_date` des versions REMIT) ; "état connu à la date D" = dernières versions dont `updated_date <= D`. Ce que veut dire `cre` (CRE, régulateur ?) n'est pas déductible.

### rte.production_types_with_units()
- Sortie : 1 col texte (ou `__text`,`__value`) ; valeur utilisée par `generation_per_units_of_production_type` : 'nuclear', 'hydro_pumped_storage' (14D8KtxWz var `production_types`).
- Sémantique : types de production ayant au moins une unité dans actual_generation_per_unit.
- Piège : variable `multi:true` mais appel sans `ARRAY[]` -> en pratique mono-valeur (une multi donnerait 2 args).

### rte.generation_per_units_delta(from timestamptz, to timestamptz, production_type text)
- 14D8KtxWz #11 (echarts). Sortie : 1 frame large : `time` + 1 col numérique par unité (nom d'unité = nom de série) ; l'option echarts prend `fields.find(type==='time')` et TOUTES les colonnes number en barres empilées.
- Sémantique : variation (MW) de production de chaque unité entre pas consécutifs (ΔP(t)=P(t)-P(t-1)) ; le tooltip masque |Δ|<=5 MW. Format `time_series`. ? (delta entre pas vs entre bornes de plage non tranché ; pas horaire probable).
- 'nuclear' = littéral du type.

### rte.generation_per_units_of_production_type(production_type text, from, to)
- 14D8KtxWz #2, timeseries, MW, légende table (mean/max/min/range). Sortie : `time`, `metric`(nom unité), `value`(MW). Production réelle par unité du type.

### rte.unavailability_update_id_date(origin text, production_type text)
- Var `update`/`unav` (cM9g, gr_6, uMjg multi, vJYZ). Sortie : `__text` = date 'YYYY-MM-DD' (les séries sont nommées par cette date, regexp `\d{4}-\d{2}-\d{2}` dans uMjg), `__value` = update_id int. Ordre : tri desc par date (cM9g sort=2 alphabétique desc). `'cre','nuclear'`. Commentaire `--nocache` dans cM9g/uMjg : sans doute un marqueur pour un cache de requêtes devant PG (?).

### rte.unavailability_tag(update_id int)
- Annotation cM9gMNZ4k "Update" (ligne verticale verte). Sortie : `time` (timestamptz de l'update), `text`, `tags` (comme la requête "Now").

### rte.availability_per_unit_capacity_factor_raw(update_id int, from, to)
- cM9g state-timeline, unité `percentunit`, seuils % (0,10,50,80,90), `mergeValues`. Sortie : `time`, `metric`(nom unité), `value` 0..1 = capacité disponible / installée. "raw" = valeurs en escalier aux seuls instants de changement (non rééchantillonnées). Toutes les unités nucléaires (une ligne par unité). Disponible = installée moins indisponibilités actives à `update_id`.

### rte.unavailabilities_per_production_type(production_type text, from, to)  /  rte.unavailabilities_per_unit(eic_code text, from, to)
- Tables (format `table`, filtrables ; tri par `update` desc). Colonnes d'après les overrides byName (union des deux tables) : `unit name` (seulement per_production_type, absente de gr_6), `id`, `identifier`, `version`, `type`, `status`, `creation`, `update`, `start`, `end`, `cap`, `installed_capacity`, `reason` (inspect). Types : id/version int, creation/update/start/end timestamptz, cap/installed_capacity MW. Les overrides `time,value,start_date,end_date` sont des restes. Filtrage : indisponibilités recouvrant [from,to].
- Source : une ligne par version/indisponibilité REMIT RTE (`status` ACTIVE/INACTIVE/DISMISSED ?, `type` planifiée/forcée ?, `reason` texte libre).

### rte.nuclear_name_eic_code()
- Var `unit` gr_6 : `__text` = nom d'unité (ex. tranche), `__value` = EIC 'W' (ex. `17W100P100P0135M`). Passé en `'${unit:value}'`. Unités nucléaires RTE.

### rte.generation_per_unit(eic_code text, from, to)  (+ `'production' as metric`)
- gr_6 série "production" (MW, fillOpacity 50, insertNulls 1h). Sortie : `time`, `value`. Production réelle horaire d'une unité.

### rte.availability_per_unit_raw(eic_code text, update_id int, from, to)  (+ `'capacity' as metric`)
- gr_6 série "capacity" (MW). Sortie : `time`, `value` = capacité disponible (MW) en escalier, état à `update_id`, passé et futur.

### rte.availability_nuclear(from, to)  /  rte.production_charge_factor_nuclear(from, to)
- q7IpAJHVz stat, `joinByField Time outer`, puis organize ; noms de champs exacts : `availability capacity` (MW, max 61370), `availability share` (0..1), `charge factor` (0..1), `production` (MW, max 61370). Répartition probable : availability_nuclear -> `time`, `availability capacity`, `availability share` ; production_charge_factor_nuclear -> `time`, `production`, `charge factor` (?). Format `time_series`, réduction `lastNotNull` + sparkline. Capacité = somme du parc avec le dernier update (minuit UTC) ; `charge factor` = production / capacité installée (ou disponible ? non tranché). Lien : /d/uMjgqrW4z.

### rte.on_off_share_nuclear(from, to)
- q7 "Units on/off", format `table`. Colonnes : `on` (int), `off` (int), `share_on` (0..1). Sémantique (aide) : nombre d'unités > 20 MW de production (on) vs sinon (off). Colonne `time` éventuelle (sparkline) ? non déductible.

### rte.generation_per_units_nuclear(from, to)
- q7 "Nuclear units production stats", MW, stat+sparkline, seuil rouge < 20 MW, lien `var-unit=${__field.labels.eic_code}`. Sortie : `time`, `value`, + labels texte `eic_code` et nom d'unité, une série par unité, PLUS une série dont le nom contient "All" (regex `.*All.*` -> displayName "Sum", max 61370) = somme du parc. Fenêtre = plage du dashboard (24 h).

### rte.availability_sum_raw_multi(update_ids int[], from, to)
- uMjg ligne "availability". Sortie `time_series` : une série par update_id, nommée par la date de l'update (`YYYY-MM-DD`), MW, `stepAfter`, somme des unités nucléaires (aucun filtre de type en argument : nucléaire implicite).

### rte.availability_sum_raw_multi_origin(origins text[], production_type text, from, to)
- uMjg ligne "rte". Origines `rte-2022-11-15`, `rte-2022-10-17`, `rte-2023-06-28`. Sortie : séries nommées par origine (`rte-...`, regexp override `/rte\-.*/` = lissage) ; noms hérités `rte`, `rte-hi`, `rte-lo` dans organize (bornes haute/basse ?). Ces courbes ne viennent PAS de l'API : numérisées des PDF RTE (Analyse passage hiver 2022-2023 fig. 7 ; actualisations 18 oct. et nov. ; Perspectives sécurité d'approvisionnement été/automne/hiver 2023), donc à ressaisir.

### rte.generation_aggregated_of_production_type(production_type text, from, to)  (+ 'production' as metric)
- uMjg série "production" (fill 50). `time`, `value` MW = somme des unités du type.

### rte.availability_sum_raw_yearly_repeat(update_id int, from, to)
- vJYZk6MVk "Yearly availability", plage `now/y`. Sortie : `time` + 1 série par année (nom = année ?), disponibilité agrégée de l'update répétée/superposée par année sur un axe de temps commun (?). Non déductible : décalage temporel des années.

## odre.* (source : ODRE, jeu "registre-national-installation-production-stockage-electricite-agrege" https://odre.opendatasoft.com/explore/dataset/registre-national-installation-production-stockage-electricite-agrege ; lien Agence ORE dans l'aide)
Paramètres communs (KhwOJrB4k) : `(code_filiere text[], code_combustible text[], code_technologie text[], prod_years text[]/int[], min_cf text, max_cf text, min_count text)`. Constantes : filiere `EOLIE`, combustible `''`, technologie `TERRE`. `''` = pas de filtre (ARRAY[''] pour combustible). Textbox : `min_count`=10 (nb mini d'installations par année d'installation), `min_cf`/`max_cf` (courants 0.01 / 0.5) ; vide = pas de filtre -> parser avec NULLIF(...,'')::numeric. `year` multi : "last 12 months"=2023 (valeur 2023) puis 2022..2017 ; 2023 = énergie annuelle glissante du registre courant, années passées = instantanés annuels du registre (versions `...-agrege-3101YY`?) ; non tranché.
Colonnes ODRE manifestes (plotly) : nom_installation, nb_groupes, nb_installations, energie_annuelle_glissante_injectee (kWh), puis_max_installee (kW), puis_max_rac (kW), commune, departement, region, regime, date_mise_en_service, + codes filiere/combustible/technologie. Facteur de charge = energie_annuelle_glissante / (puis_max_installee x 8760).

### odre.capacity_factor_per_installation_year(...)
- Série temps `time_series` (KhwOJrB4k #2, Mixed avec Infinity) : `time` (1er janv. de l'année d'installation, timestamptz) + une colonne nommée exactement `ODRE average` (0..1, percentunit, épaisseur 3). Moyenne du CF pondérée par la puissance (cf aide), plusieurs années de prod -> moyenne pondérée unique ; années d'installation filtrées par `min_count`.

### odre.data_per_installation_year(...)
- Plotly violon, format `table`, noms EXACTS lus par `fields.find(f.name===...)` : `year_start` (x, date ou année), `cf_inst` (y, 0..1), `nom_installation`, `nb_groupes`, `nb_installations`, `energie_annuelle_glissante_injectee`, `puis_max_installee`, `puis_max_rac`, `commune`, `departement`, `region`, `regime`, `date_mise_en_service`, `year_prod`. Une ligne par installation x année de production, filtrée par min_cf/max_cf et min_count.

### odre.total_per_year(...)
- Table (KhwOJrB4k #5) jointe en inner sur `year` à l'Infinity B. Colonnes : `year` (année de prod), `cf_odre` (en % : unité `percent`, donc 0..100), `prod_odre` (TWh), `cap_odre` (GW). Division faite côté panel : prod_odre/prod_rte.

### odre.cap_inst_per_year(...)
- Table (#6) jointe en inner sur `inst_year`. Colonnes : `inst_year`, `prod_year`, `cap_inst_odre` (GW). Capacité installée par année d'installation, par année de prod.

## map.*
### map.generation_capacities(year int)
- WC9L4zIVk, plugin `hokkos-deckgl-grafana`, couche `OdreCapacities`, format `table`, vue lat 47.01/lon 2.76 z5.56. `$year` mono-valeur brut (int). Colonnes non lisibles dans le JSON (logique dans le plugin). D'après l'aide : position (lat/lon ? ou geom), type (10 classes : Marine, Other, Stockage, Hydro, Nuclear, Bioenergy, Thermal, Geothermal, Wind, Solar = regroupement de `filiere`), group count (nb_groupes), installation count (nb_installations), capacity (W), production (Wh, glissante annuelle), names (noms agrégés). Source géo : registre ODRE (champ géographique par commune/IRIS ?) ; localisation exacte non déductible. A lire dans le code du plugin.

## ember.* (source : Ember https://ember-climate.org/data/data-catalogue/ : Yearly + Monthly electricity data ; méthodologie Ember 2023)
### ember.get_date_from_period_region(period text, region text)
- Var `time` Q9d2hcb4k. `period` ∈ year|month ; `region` ∈ worlds_countries, Africa, Asia, Europe, Latin America and Caribbean, Middle East, North America, Oceania, EU, OECD, G20, G7, worlds_regions. Sortie `__text` = '2022' (année ; mois : format ? 'YYYY-MM'), `__value` = date '2022-01-01'. Dates où des données existent pour la région.

### ember.production_intensity_per_time_area_config(period, region, time date, emission_factors text)
- Plotly mosaïque, `format table`, lecture PAR POSITION : col0 production (TWh), col1 intensité (gCO2eq/kWh), col2 pays (text, tooltip), col3 région (text ; doit valoir un de Africa, Asia, Latin America and Caribbean, Europe, North America, Oceania, Middle East). Émissions MT = prod x intensité / 1000. Ordre des lignes = ordre de la mosaïque (probablement intensité croissante ?). 1 ligne par pays (ou par groupe pour `worlds_regions`, doublons). Intensité = Σ(prod par type x facteur d'émission) / prod totale.
- `emission_factors` (valeurs exactes) : `Oberschelp2019_Jordaans2022_UNECE2022_IPCC2014_Ember` (charbon par pays Oberschelp 2019, gaz par pays Jordaan 2022, reste UNECE 2022 / IPCC 2014 / Ember, moyenne mondiale si pas d'estimation), `UNECE2022_IPCC2014_Ember` (charbon/gaz UNECE 2022 relevés, solaire/éolien/nucléaire UNECE), `IPCC2014_Ember` (valeurs Ember d'origine, IPCC 2014 ACV).

### ember.emission_factors(emission_factors text)
- Table sans override ni transformation. Colonnes non déductibles ; probable : type de production, pays (pour charbon/gaz individualisés), facteur gCO2eq/kWh, source (Oberschelp/Jordaan/UNECE/IPCC/Ember).

### ember.get_area_name()
- Var `area` (d6be5f33) : 1 colonne texte, défaut 'Europe' ; pays, continents, groupes (EU, OECD, G20, G7, World...) d'Ember.
### ember.get_from_date(area text, period text [, from1 date])
- Vars `from1`/`from2`. `__text` 'YYYY-MM' (mois ; année ? '2022'), `__value` date 'YYYY-MM-01'. Surcharge à 2 puis 3 arguments : from2 = dates disponibles autres que from1 (probablement postérieures ; ?).
### ember.get_duration(area, period, from1, from2)
- Var `duration`. `__text` humain ('1 year'), `__value` chaîne interval PG ('11 mons'). Durée commune maximale (et sous-durées) comparable entre les deux périodes ; la valeur sauvée ('11 mons' / '1 year') est incohérente : à surveiller.
### ember.get_waterfall(category text, area, period, from1, from2, duration interval-text)
- Plotly waterfall `measure: relative`, `format table`, lecture par position : col0 `y` (TWh, delta), col1 `x` (libellé catégoriel). `category` gen = par type de production, gen_agg = Clean / Fossil. Libellés spéciaux obligatoires : `Exchange` (y>0 = plus d'import, <=0 = plus d'export ; delta net import) et `Demand` (y = -Δdemande, car le script inverse le signe ; fermeture de la cascade : ΣΔprod + Δimport - Δdemande = 0). Hover calcule initial -> final avec cumul Plotly. ~10 catégories en mode `gen`. Source : Ember yearly/monthly (generation par fuel, imports nets, demande).

## entsoe.* (appelées depuis World Electricity : b550d6bc, f487b4fd) ; source : ENTSO-E Transparency Platform
### entsoe.units_of_contries_with_production_types(countries text[], production_types text[])
- Var `units` (b550). `__text` = "Parc du Banc de Guérande 1 - FR - wind offshore" (nom - pays - type avec espaces), `__value` = EIC unité (`17W0000014455651`). Unités de production (puissance>=100 MW ; document "actual generation per generation unit" A73 ?).
### entsoe.generation_per_units(eic text[], from, to)
- timeseries, légende table min/max/mean. `time`, `metric` (nom d'unité), `value` MW.
### entsoe.generation_per_countries(countries text[], production_types text[], from, to)
- f487 "Production per type". `time`, `metric` (probablement "pays - type" ?), `value` MW. Source probable : A75 actual generation per type.

## Infinity (yesoreyeram-infinity-datasource 2.7.1, uid d7489df0-0285-4aad-947c-27b089483f47), tous dans KhwOJrB4k
- Aucune requête HTTP : 3 requêtes `type: csv`, `source: inline`, l'URL (`github.com/yesoreyeram/.../users.json`) n'est qu'un reste inutilisé. Parsing : colonnes déclarées par selecteur.
 - B (#2) format `timeseries` : `year`(timestamp) -> temps, `cf`(number) -> nom `IRENA` (tirets 10/10) ; CSV 1991..2021 (0,2235 ... 0,3588) : facteur de charge éolien terrestre IRENA par année d'installation.
 - B (#5) format `table` : `year,cf_rte,prod_rte,cap_rte` 2014..2022 (ex. 2014 : 22.5, 16.97, 9.30 ; 2022 : 22, 38.02, 21.16) ; jointure sur `year`, champs `cf_rte B`, `prod_rte B`, `cap_rte B` (colonnes suffixées par la jointure).
 - A (#6) format `table` : `inst_year,cap_inst_rte` 2014..2022 (1.096 ... 1.941 GW) ; champ `cap_inst_rte A`.
 - Les CSV complets sont dans `dash/KhwOJrB4k.json` (`.targets[].data`).

## Plugins non natifs (id : version)
- `volkovlabs-echarts-panel` 6.0.0 (14D8 variations) ; `marcusolsson-dynamictext-panel` 4.5.0 (versions panel 9.3.6/9.5.1/10.1.4 dans le JSON) ; `nline-plotlyjs-panel` 1.6.7 (Q9d2, d6be, KhwOJ) ; `hokkos-deckgl-grafana` 1.0.0 (maj 2023-10-12, auteur "hokkos", plugin custom non publié : WC9L, b550, f487) ; datasource `yesoreyeram-infinity-datasource` 2.7.1. Panels natifs : timeseries, state-timeline, stat, table, text, dashlist, row.
- b550 et f487 : couches du plugin `WindPowerCapacityScatterPlot`, `windCapacityFactorRaster`, `Countries`, `Time`, datasource "-- Grafana --" sans requête SQL : le plugin charge ses données lui-même (éoliennes, raster ERA5 0.25°). Base de localisation des éoliennes : non déductible du JSON.

## Home (e72-tIG4z) et liens
- Panel dynamictext (HTML) : titre "Energygraph", "A site on energy, mainly electricity, and its greenhouse gas emissions, in the World, Europe and France, with time series and large scale map visualisations." ; "New :" liens vers /d/f487b4fd-.../wind-and-solar-charge-factor-map?autofitpanels et /d/b550d6bc-.../wind-turbines-charge-factors-map?autofitpanels&orgId=1 ; vidéo `https://r2.energygraph.info/energygraph.info.mp4` (+ poster `...mp4_snapshot_00.00.035_min.jpg`, Cloudflare R2). Aucun crédit, nom d'auteur ni mention de source sur la Home.
- 4 `dashlist` (Europe electricity folderId 9, World Electricity 29, France nuclear 6, France electricity 17), `showSearch`.
- Dashboards qui ne sont que des liens : aucun ; Home = liste de dashboards. b550/f487 ont 2 liens de dashboard (Default / Fit `?autofitpanels`, keepTime, includeVars).
- Sources citées dans les "Help" : RTE Data, RTE Analyse passage hiver 2022-2023 (+ actualisations), RTE Perspectives 2023, ODRE registre, IRENA Power Generation Costs 2020/2021 (p.59), Agence ORE (dataviz), Ember (data catalogue + methodology 2023), IPCC 2014 AR5 WGIII Annex III, UNECE 2022 (LCA), Oberschelp 2019 (Nat Sustain 2:113), Jordaan 2022 (Nat Clim Change 12:1059), Global Energy Monitor (charbon), iban.com country codes, ERA5/ECMWF, atlite (PyPSA), Reindl 1990, Huld 2010. Modèle éolien : Vestas V112 3 MW, moyeu 80 m ; vent U/V 100 m + rugosité.

## Points incertains
1. Signification de `'cre'` et de `update_id` (snapshot quotidien vs rang de versions REMIT) ; ids 165/179 ne permettent pas de conclure.
2. Colonnes exactes des tables d'indisponibilité, de `ember.emission_factors`, de `map.generation_capacities` (lues par le plugin hokkos, source absente).
3. Répartition des 4 champs de q7 entre `availability_nuclear` et `production_charge_factor_nuclear`, définition du `charge factor`, présence de `time` dans `on_off_share_nuclear`.
4. Semantics de `availability_sum_raw_yearly_repeat` et des séries `rte-hi/rte-lo`.
5. Types SQL des paramètres : tableaux reçus quotés (text[]), `$year` de la carte reçu brut (int).
6. Années ODRE : instantanés annuels du registre vs un seul registre ; "last 12 months" = 2023.
7. Données `rte-*` numérisées à la main depuis les PDF RTE, non reproductibles par API.
8. Doc RTE/ENTSO-E/ODRE/Ember non consultée (nom des jeux d'après ta liste + mémoire) ; échelle de temps (15 min/1 h) à valider.
9. Hors périmètre non examiné : dossier "Europe electricity" (sauf 3 fonctions entsoe).

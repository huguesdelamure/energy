# Spec SQL entsoe.* : dossier Grafana "Europe electricity" (11 dashboards)

Source : dashboards/original/*.json (folderTitle = "Europe electricity"). Datasource Postgres uid I3yziRGVz. Les panels à targets vides utilisent "-- Dashboard --" (ils réutilisent la requête d'un autre panel, notés "via panel N").

## Conventions transverses (déduites)
- Interpolation Grafana Postgres : variable multi => `'a','b'` (texte quoté) ; `$years` custom => entiers non quotés ; `${x:sqlstring}` idem quoté. Donc `ARRAY[$countries]` = text[], `ARRAY[$years]` = int[], `ARRAY[$units]` = text[] (codes EIC).
- Tableaux de types sans cast (`ARRAY[$production_types]`) = text[] : les fonctions concernées prennent `text[]`. Seules `correlatogram` et `capture_price` castent `::production_type[]` : elles prennent `production_type[]` (enum). Un `text[]` ne se convertit pas implicitement en enum[], donc ne pas harmoniser.
- Variables multi vides (capture_price : `others` et `production_types_day_ahead` valent `[]` par défaut) : tolérer tableau vide ou `{''}`.
- `$__timeFrom()/$__timeTo()` = timestamptz. Valeurs en kW (unit Grafana `kwatt`), énergie en kWh (`kwatth`) : ENTSO-E donne des MW/MWh, ×1000 à l'ingestion ou en sortie.
- Format "long" : colonne texte `metric` + colonnes numériques ; Grafana `time_series` pivote par `metric` ; avec 2 colonnes valeur les champs s'appellent `<colonne> <metric>` (cf. regex `kwh (.*)`, `flh (.*)`, filtres `price.*`/`rate.*`).
- LOESS : calculé côté navigateur (JS embarqué dans le panel echarts, bandwidth 0.1). La variable LOESS n'est jamais envoyée en SQL.
- Valeur "None" (`null`) des variables countries1..3 : arrive en SQL comme la chaîne `'null'` (et pas NULL) ; la fonction doit renvoyer 0 ligne pour ce pays.

## Enum production_type (implicite)
Valeurs custom des variables, mappées sur les codes PSR ENTSO-E : biomass (B01), fossil_brown_coal_lignite (B02), fossil_coal_derived_gas (B03), fossil_gas (B04), fossil_hard_coal (B05), fossil_oil (B06), fossil_oil_shale (B07), fossil_peat (B08), geothermal (B09), hydro_pumped_storage (B10), hydro_run_of_river_and_poundage (B11), hydro_water_reservoir (B12), marine (B13), nuclear (B14), other_renewable (B15), solar (B16), waste (B17), wind_offshore (B18), wind_onshore (B19), other (B20) = 20 valeurs.
- `total` (libellé "demand") est proposé dans la variable de a7e92719 (correlatogram) : l'enum doit contenir `total` (= charge A65), sinon le cast `::production_type[]` échoue. Absent des autres dashboards.
- `other` absent des listes de e2802e7d, THFJM_F4k et a9b7502a (19 valeurs) ; présent ailleurs (20).
- a9b7502a `production_types_day_ahead` : solar, wind_offshore, wind_onshore. `others` : base, demand (text, pas enum).

## Codes zones / pays
- Pays (35, variables `countries`) : AL AT BA BE BG CH CZ DE DK EE ES FI FR GB GE GR HU IE IT LT LV MD ME MK NL NO PL PT RO RS SE SI SK UA XK. (THFJM_F4k : 36 entrées = ces 35 sans changement + `null`.) HR absent côté pays.
- Zones de prix day-ahead (44, a9b7502a et c9e51a42, variable `zones`) : AT BE BG CH CZ DE_LU DK1 DK2 EE ES FI FR GR HR HU IE_SEM IT-CNORTH IT-CSOUTH IT-Calabria IT-NORTH IT-SOUTH IT-Sardinia IT-Sicily LT LV ME MK NL NO1..NO5 PL PT RO RS SE1..SE4 SI SK (liste coupée par mon extraction à 43 valeurs + 1 entrée vide finale due à la virgule terminale).
- Colonnes attendues de day_ahead_prices (listes des transformations de KIDsWG0nz, 42 noms + Time) : AT BE BG CH CZ DE_LU DK1 DK2 EE ES FI FR GR HR HU IT-CNORTH IT-CSOUTH IT-Calabria IT-NORTH IT-SACOAC IT-SOUTH IT-Sardinia IT-Sicily LT LV NL NO1 NO2 NO2NSL NO3 NO4 NO5 PL PT RO RS SE1 SE2 SE3 SE4 SI SK. (IT-SACOAC, NO2NSL présents ici, absents de la variable `zones`.)
- Types de zone (`area_type`) : cty (Country), bzn (Bidding Zone), cta (Control Area).
- Flow : `bucket_width` 15m,1h,6h,12h,24h,1 week,1 month,1 year ; `flow_type` physical|commercial|commercial_day_ahead ; `net_flow` constante 'false'. Correlatogram bucket_width : 1 hour,1 day,1 week,1 month,1 year (panel répété par valeur). Capture price : 1 day,1 week,1 month,1 year. Années (years) : 2015..2024.

## Plugins de panel non natifs
- volkovlabs-echarts-panel pluginVersion 6.0.0 (FpgRGmY4k, THFJM_F4k, a7e92719) ; loess.js intégré dans le code du panel.
- marcusolsson-dynamictext-panel : version non déterminable (le champ pluginVersion contient 10.1.4/9.5.1, version Grafana). Sert à l'aide (Handlebars).
- hokkos-deckgl-grafana : version non déterminable (7dWs1mVVk : vide ; KIDsWG0nz : 8.3.2 = très probablement version Grafana). Layers utilisés : `Flow`+`Time` (7dWs) ; `DayAheadPrices`+`Time` (KIDs). Natifs : timeseries, table, text, stat, heatmap, histogram. `__requires` vide partout.

---
## entsoe.area_map_code_eic(area_type text)
- Variable/targets : refId `nodes` du panel deck.gl Flow (7dWs1mVVk panel 2), format table.
- Sortie : une ligne par zone du type demandé : code EIC (text), code court mappé (text, ex. FR, DE_LU), nom, coordonnées (lat/lon float ou géométrie) pour placer les nœuds sur la carte. Noms exacts : INCONNUS (dépend du plugin, voir incertains).
- Sémantique : référentiel des nœuds (zones) du graphe de flux, par type d'aire.
- Données : référentiel ENTSO-E (EIC des aires, area_type) + géocodage maison.

## entsoe.flow_graph_edges_eic(area_type text, from timestamptz, to timestamptz, bucket interval, flow_type text, net_flow boolean|text)
- Panel deck.gl Flow, refId `edges`, format table.
- Sortie : une ligne par (bucket temporel, zone source EIC, zone cible EIC) : `time` timestamptz, from/to (EIC text, jointure avec nodes), valeur kW (float). Noms exacts INCONNUS. La couche "Time" du plugin exige une colonne temps (play control).
- Sémantique : arêtes orientées des flux entre zones, agrégées par bucket. `net_flow` ('false' constante, reçu en littéral texte) : false = deux arcs opposés par frontière ; true = solde net (un seul arc, sens du solde positif).
- `bucket` : `INTERVAL '$bucket_width'` donc valeurs Postgres valides ('15m','1h','1 week'...).
- Données : physical = A11 (flux physiques agrégés, 60 min) ; commercial = A09 (finalised schedule, échanges commerciaux programmés, total) ; commercial_day_ahead = A09 day-ahead (contract type A01). Par frontière in_Domain/out_Domain, pour cty/bzn/cta. Granularité source 15/60 min.

## entsoe.flow_net_interpolated(area_type text, from, to, bucket interval, flow_type text)
- Panel timeseries 4 (7dWs1mVVk), format time_series ; son résultat est aussi réutilisé par le panel table "Stats" (via panel 4, transfo reduce mean/min/max/range => colonnes = zones).
- Sortie : `time` + UNE COLONNE PAR ZONE (nom = code court, ex. FR, DE_LU), valeur float en kW. Wide, pas de `metric`. L'override du panel cite une colonne `AAAA` (artefact, à ignorer).
- Sémantique : solde net import/export par zone, positif = export net, négatif = import net (texte d'aide du panel), interpolé aux instants des buckets ("interpolated" : comble les trous/ré-échantillonne).
- Données : mêmes que flow_graph_edges_eic, soldes calculés (somme sorties - somme entrées par zone).

## entsoe.units_of_contries_with_production_types(countries text[], production_types text[])   [sic : "contries"]
- Variable query `units` (FpgRGmY4k, VHZHpV74k ; hors périmètre aussi b550d6bc), multi.
- Sortie : 2 colonnes `__text` (nom lisible de l'unité, SANS '+' ni ',' : le JS fait split('+') sur `${units:text}`) et `__value` (code EIC de l'unité, ex. 18W000000000AI2L, 17W0000014455651).
- Sémantique : liste des unités de production (centrales/groupes) des pays et types sélectionnés. Ordre texte/valeur cohérent (le JS les aligne par index).
- Données : A73 (génération réelle par unité, métadonnées nom/EIC/PSR) et/ou A71 (capacité installée par unité). Granularité : métadonnées.

## entsoe.generation_per_units(units text[])... (units, from, to)  -> (text[], timestamptz, timestamptz)
- VHZHpV74k panel 2, format time_series, unit kwatt, legend min/max/mean, `insertNulls` 3600000 (1 h) : pas de série plus lâche que 1 h.
- Sortie : `time` timestamptz, `metric` text (nom de l'unité), valeur float kW (nom de colonne libre, non référencé).
- Sémantique : production réelle de chaque unité sur la période.
- Données : A73, 15/30/60 min selon unité.

## entsoe.cum_histo_per_unit(units text[], from, to, 800 int, 50 int, true boolean, 1.2 float)
- FpgRGmY4k panels 2 (courbes), 4 (histogrammes), 8 (table Stats), format table, une seule requête partagée.
- Sortie, format long, colonnes : `metric` text, `eic_code` text, `order` float, `share` float, plus colonnes de stats. Valeurs de `metric` : `cum` (courbe), `histo` (histogramme), puis lignes de stats (order NULL) : min_share, max_share, sum_share, sum_share_limit_cons, sum_prod, sum_cons, avg_prod, min_prod, max_prod, cnt (les 4 derniers libellés de la table : Average/Min/Max/Samples count).
  - `cum` : order = fraction du temps (0..1, ×100 dans le JS = "Percent of the time"), share = facteur de charge (0..1+, ×100). Triée par share décroissant ; 800 points.
  - `histo` : order = centre du bin du facteur de charge (0..~1.2, pas régulier : le JS calcule delta = order[1]-order[0]), share = fréquence normalisée (axe "Samples, adjusted by samples range for constant area", donc densité ≈ count/(N·largeur bin)).
- Sémantique : monotone de charge (distribution cumulative complémentaire) + histogramme du facteur de charge de chaque unité.
- Littéraux : 800 = nombre de points de la courbe cumulée (ré-échantillonnage) ; 50 = nombre de bins de l'histogramme (THFJM utilise 100 pour les pays) ; `true` et `1.2` : NON DÉDUCTIBLES (hypothèses : true = normaliser par la capacité de l'unité ; 1.2 = plafond du facteur de charge/bornes du dernier bin).
- Données : A73 (génération par unité) ; dénominateur = capacité de l'unité (A71 capacité installée par unité, processType A33) ou max observé : à trancher.

## entsoe.cum_histo_per_countries_prod_types(countries text[], production_types text[], from, to, 800 int, 100 int, scale_prod_to_cons boolean)
- THFJM_F4k, 3 requêtes (refId 1,2,3, une par jeu de pays/types), panels courbes (2), histogrammes (4), 3 stats (8,9,10 filtrés par refId).
- Sortie : même schéma long que cum_histo_per_unit SANS `eic_code` : `metric`, `order`, `share` ; metric = cum | histo | min_share | max_share | sum_share | sum_share_limit_cons | sum_cons | sum_prod. Stats lues par `rowsToFields` (metric -> nom de champ, share -> valeur, order ignoré) : une ligne par stat, share = valeur.
  - `cum` : order = fraction du temps, share = couverture = Σprod/Σload (0..1+).
  - `histo` : order = centre de bin de la couverture, share = fréquence normalisée.
  - sum_share = Σprod/Σload (couverture moyenne) ; sum_share_limit_cons = idem avec production bornée à la charge (Σmin(prod,load)/Σload, "Avg with export limit") ; sum_prod, sum_cons = énergies totales (masquées).
- Sémantique : taux de couverture de la demande par les types de production sélectionnés (somme sur les pays), en monotone de charge + histogramme + stats. `scale_prod_to_cons = true` : production mise à l'échelle de la charge (aide : "scaled to the load") ; sans doute facteur Σload/Σprod_total (à préciser). 800 points, 100 bins.
- Données : A75 (génération par type) et A65 (charge réelle, "total"), pays, 15/60 min alignées à l'heure.
- Cas `countries = {'null'}` : 0 ligne.

## entsoe.generation_cumsum_per_day_for_year(countries text[], production_types text[], years int[], from, to)
- J4UfBbVVk panel 4 (table -> prepareTimeSeries multi) et panel 2 (via panel 4, mêmes données, FLH).
- Sortie : `time` timestamptz (un point par jour), `metric` text (probablement l'année, c'est la légende), `kwh` float (kWh, cumul depuis le 1er janvier), `flh` float (heures équivalent pleine charge). Regex : `kwh (.*)`, `flh (.*)`.
- Sémantique : cumul journalier depuis le début d'année, pays/types sommés, une série par année sélectionnée (superposées : `time` vraisemblablement ramené à une année commune, celle de $__timeFrom) ; flh = kwh cumulé / capacité installée A68 agrégée de l'année.
- Données : A75 (génération agrégée par type, jour) + A68 (capacités installées annuelles, publiées une fois par an : l'aide signale la dérive).

## entsoe.capacities_per_countries_prod_types_years(countries text[], production_types text[], years int[])
- J4UfBbVVk panel 6 (table). Sortie : colonnes dont `capacity` (kW, override unit kwatt) ; autres colonnes (pays, type, année) : noms INCONNUS.
- Sémantique : capacités installées par pays x type x année (sans somme visible).
- Données : A68 (Installed capacity per production type, annuel, au 1er janvier).

## entsoe.day_ahead_prices(currency text 'EUR', from, to)
- KIDsWG0nz panel 2 (time_series, stepAfter, spanNulls) ; panels 4 (deckgl DayAheadPrices), 6 (histogram bucketSize 10), 9 (heatmap) la réutilisent (via panel 2).
- Sortie : `time` + une colonne par zone (noms = liste des 42 zones ci-dessus, dont NO2NSL, IT-SACOAC), float prix en EUR/MWh (unit currencyEUR). Wide. Les panels filtrent par nom de champ : les colonnes doivent s'appeler exactement ainsi (y compris `Time` en majuscule côté Grafana, correspondant à `time`).
- Sémantique : prix spot day-ahead par zone de prix. `'EUR'` = devise (filtre ou conversion ; ENTSO-E publie par zone dans sa devise).
- Données : A44 (Day-ahead prices), in_Domain = out_Domain = zone, PT60M (PT15M depuis le passage SDAC au pas 15 min d'octobre 2025 : à ré-échantillonner ou non).

## entsoe.generation_per_countries(countries text[], production_types text[], from, to)
- iLGJqA7Vz panel 2, format time_series, unit kwatt, legend min/max/mean, lineInterpolation smooth.
- Sortie : `time`, `metric` text (une série par couple pays x type, ex. "FR nuclear"), valeur float kW. Format exact du nom : non déterminable.
- Sémantique : production temporelle par pays et par type.
- Données : A75 (actual generation per type), pays (area type CTY), 15/60 min ; pas de somme entre pays (l'aide parle de "combination").

## entsoe.generation_heatmap(countries text[], production_types text[], from, to, 1.2 float)
- e2802e7d panel 2, format time_series, heatmap natif : `calculate:false`, `rowsFrame.layout:"ge"`, axe Y unit "h" inversé, cellValues kwatth.
- Sortie : `time` (un point par jour) + colonnes dont le NOM est la borne de ligne (heure 0..23) : une cellule = énergie produite (kWh) pendant cette heure du jour, somme des pays et types sélectionnés. Layout "ge" => noms de colonnes numériques croissants.
- Sémantique : carte thermique jour x heure de la production sommée.
- Littéral 1.2 : NON DÉDUCTIBLE du JSON (hypothèse : coefficient d'écrêtage/normalisation d'échelle ; color.exponent du panel est 0.5, sans lien).
- Données : A75, pas horaire.

## entsoe.map_code_per_type(area_type text)
- Variable query `zones` de a7e92719 (multi). Sortie : codes de zones du type (cty : DE, ES, FR, BE ; bzn : DE_LU...). Une ou deux colonnes (`__text`,`__value`), non déterminable. Valeur retenue par défaut [DE,ES,FR,BE] avec cty.
- Données : référentiel des aires ENTSO-E.

## entsoe.correlatogram(area_type text, zones text[], production_types production_type[], bucket text|interval, from, to)
- a7e92719 panel 5, répété par valeur de `bucket_width` (repeat vertical : une valeur par appel), format table, echarts heatmap.
- Sortie : `metric1` text, `metric2` text, `value` float (-1..1, visualMap min -1 max 1). Une seule ligne par paire non ordonnée : le JS recrée la symétrie et la diagonale. Libellés : un par (zone, type), clés de tri `m1+m2` (ex. "FR solar").
- Sémantique : matrice de corrélation de Pearson (corr() SQL) entre les séries zone x type (dont `total` = charge) agrégées par pas bucket_width sur [from,to].
- Données : A75 par type (zone/BZN/CTA/pays selon area_type) + A65 charge réelle.

## entsoe.capture_price(zones text[], production_types production_type[], others text[], production_types_day_ahead production_type[], from, to, bucket_width text)
- a9b7502a panels 2 (prix) et 5 (taux, via panel 2), format time_series.
- Sortie : `time`, `metric` text (série), `price` float EUR/MWh, `rate` float (ratio, percentunit). Panel 2 garde les champs `Time|price.*`, panel 5 `Time|rate.*` ; donc champs `price <metric>` et `rate <metric>`.
- Sémantique : prix de capture = moyenne des prix DA horaires pondérée par la production horaire du profil ; rate = prix de capture / prix de base (baseload) de la même période. Profils : production_types (production réelle), others (`base` : poids constant = prix DA moyen ; `demand` : pondéré par la charge), production_types_day_ahead (solar/wind pondérés par la production prévue day-ahead). Agrégé par bucket_width.
- Données : A44, A75, A65, A69 (prévision DA éolien/solaire).

## entsoe.cumulative_negative_day_ahead_prices(zones text[], years int[], cnt_type text, from, to)
- c9e51a42 panel 1, format time_series, unit hours, legend lastNotNull.
- Sortie : `time`, `metric` text (zone x année), valeur float en heures. cnt_type : `inf_0` (prix < 0) ou `inf_eq_0` (prix <= 0).
- Sémantique : nombre d'heures cumulées depuis le 1er janvier où le prix DA est négatif (ou nul), une série par zone x année (années superposées sur un même axe, par alignement de `time`).
- Données : A44 ; au pas 15 min, compter 0,25 h par quart d'heure.

---
## Points incertains
1. Noms exacts des colonnes de area_map_code_eic / flow_graph_edges_eic / capacities_per_countries_prod_types_years / map_code_per_type / generation_heatmap : non présents dans le JSON. Pour deck.gl il faut lire les sources du plugin hokkos-deckgl-grafana (contrat des layers Flow, DayAheadPrices, Time).
2. Littéraux non déterminables : `true` et `1.2` (cum_histo_per_unit), `1.2` (generation_heatmap).
3. Formule de `scale_prod_to_cons` et de la normalisation de `share` pour `histo`.
4. Alignement temporel multi-années (J4Uf, c9e51a42) : time ramené à une année commune supposé, non prouvé. Étiquette `metric` = année supposée.
5. Format des libellés `metric` (generation_per_countries, capture_price, correlatogram) non observable ; seul le préfixe `price`/`rate`/`kwh`/`flh` est contraint.
6. Dénominateur du facteur de charge par unité (A71/A33 vs max observé).
7. Type des paramètres littéraux entre quotes (`'$net_flow'`, `'$bucket_width'`, `'$cnt_type'`) : boolean/interval/text, au choix (les quotes autorisent le cast implicite d'un littéral).
8. Granularité DA 15 min depuis oct. 2025 : comportement attendu (ré-échantillonnage ?) non défini par le JSON.
9. Liste des 44 zones : la variable contient une virgule finale (entrée vide possible).
10. Versions des plugins dynamictext et deckgl non récupérables ; le dossier `__requires` est vide.
11. Aucune vérification contre la base ou les sources ENTSO-E ; mappings documentType (A11, A09, A44, A65, A68, A69, A71, A73, A75) issus de ma connaissance de l'API Transparency, non testés.

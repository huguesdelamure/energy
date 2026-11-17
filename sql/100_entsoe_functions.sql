-- Fonctions entsoe.* appelées par les dashboards "Europe electricity".
-- Contrat (noms, paramètres, colonnes) : dashboards/spec-europe.md. Puissances en kW, énergies en kWh
-- (unités Grafana kwatt/kwatth des dashboards d'origine), prix en EUR/MWh.
-- SECURITY DEFINER : grafana_ro n'a que EXECUTE sur ces fonctions, jamais accès à raw.*.
-- Idempotent. À exécuter en postgres.

SET ROLE energy;

-- --- Aides internes (schéma raw, non exposées) -------------------------------------------

-- Domaines des pays demandés (le dashboard envoie 'null' pour "None").
CREATE OR REPLACE FUNCTION raw.country_domains(countries text[])
RETURNS TABLE (code text, domain_id smallint) LANGUAGE sql STABLE AS $$
  SELECT a.code, a.domain_id FROM raw.area a
  WHERE a.area_type = 'cty' AND a.code = ANY(countries)
$$;

-- Production horaire moyenne (MW) par domaine et filière.
CREATE OR REPLACE FUNCTION raw.gen_hourly(domains smallint[], ptypes production_type[], t_from timestamptz, t_to timestamptz)
RETURNS TABLE (t timestamptz, domain_id smallint, ptype production_type, mw double precision)
LANGUAGE sql STABLE AS $$
  SELECT time_bucket('1 hour', g.time), g.domain_id, g.ptype, avg(g.gen)
  FROM raw.generation g
  WHERE g.domain_id = ANY(domains) AND g.ptype = ANY(ptypes)
    AND g.time >= t_from AND g.time < t_to AND g.gen IS NOT NULL
  GROUP BY 1, 2, 3
$$;

-- Consommation horaire moyenne (MW) par domaine.
CREATE OR REPLACE FUNCTION raw.load_hourly(domains smallint[], t_from timestamptz, t_to timestamptz)
RETURNS TABLE (t timestamptz, domain_id smallint, mw double precision)
LANGUAGE sql STABLE AS $$
  SELECT time_bucket('1 hour', l.time), l.domain_id, avg(l.value)
  FROM raw.load l
  WHERE l.domain_id = ANY(domains) AND l.time >= t_from AND l.time < t_to
  GROUP BY 1, 2
$$;

-- Prix day-ahead horaires (EUR/MWh) : moyenne des quarts d'heure si pas 15 min.
CREATE OR REPLACE FUNCTION raw.price_hourly(domains smallint[], t_from timestamptz, t_to timestamptz)
RETURNS TABLE (t timestamptz, domain_id smallint, price double precision)
LANGUAGE sql STABLE AS $$
  SELECT time_bucket('1 hour', p.time), p.domain_id, avg(p.price)
  FROM (
    SELECT DISTINCT ON (domain_id, time) time, domain_id, price
    FROM raw.day_ahead_price
    WHERE domain_id = ANY(domains) AND time >= t_from AND time < t_to
    ORDER BY domain_id, time, dur
  ) p
  GROUP BY 1, 2
$$;

-- Monotone (n points) + histogramme (bins) d'une série de valeurs, au format long des dashboards.
-- cum : order = fraction du temps (0..1), share = valeur dépassée pendant cette fraction.
-- histo : order = centre du bin, share = densité (aire constante quel que soit le nombre d'échantillons).
CREATE OR REPLACE FUNCTION raw.cum_histo(vals double precision[], n int, bins int, vmax double precision)
RETURNS TABLE (metric text, "order" double precision, share double precision)
LANGUAGE sql IMMUTABLE AS $$
  WITH v AS (SELECT x FROM unnest(vals) x WHERE x IS NOT NULL),
  stats AS (SELECT count(*) AS cnt, coalesce(vmax, max(x)) AS hi FROM v),
  fr AS (SELECT i::double precision / (n - 1) AS f FROM generate_series(0, n - 1) i),
  cum AS (
    SELECT 'cum'::text, u.f, u.q
    FROM (SELECT percentile_disc((SELECT array_agg(1 - f ORDER BY f) FROM fr)) WITHIN GROUP (ORDER BY x) AS qs FROM v) p,
         unnest((SELECT array_agg(f ORDER BY f) FROM fr), p.qs) AS u(f, q),
         stats
    WHERE stats.cnt > 0
  ),
  h AS (
    SELECT least(width_bucket(x, 0, nullif(stats.hi, 0), bins), bins) AS b
    FROM v, stats WHERE x >= 0
  ),
  histo AS (
    SELECT 'histo'::text, (b - 0.5) * stats.hi / bins,
      count(*)::double precision / (stats.cnt * stats.hi / bins)
    FROM h, stats WHERE b >= 1 GROUP BY b, stats.hi, stats.cnt
  )
  SELECT * FROM cum UNION ALL SELECT * FROM histo
$$;

-- --- Unités de production ---------------------------------------------------------------

-- [sic] "contries" : nom d'origine, appelé tel quel par les dashboards.
CREATE OR REPLACE FUNCTION entsoe.units_of_contries_with_production_types(countries text[], production_types text[])
RETURNS TABLE (__text text, __value text) LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  -- Le JS des panels découpe ${units:text} sur '+' et ',' : on les retire des noms.
  SELECT translate(u.name, '+,', '  ') || ' (' || u.country || ', ' || u.ptype || ')', u.eic
  FROM raw.unit u
  WHERE u.country = ANY(countries) AND u.ptype::text = ANY(production_types)
  ORDER BY u.country, u.ptype, u.name
$$;

CREATE OR REPLACE FUNCTION entsoe.generation_per_units(units text[], t_from timestamptz, t_to timestamptz)
RETURNS TABLE ("time" timestamptz, metric text, value double precision) LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT g.time, u.name, g.gen * 1000
  FROM raw.generation_unit g JOIN raw.unit u ON u.id = g.unit_id
  WHERE u.eic = ANY(units) AND g.time >= t_from AND g.time < t_to
  ORDER BY 1
$$;

-- Facteur de charge par unité : monotone, histogramme et stats.
-- norm : facteur de charge rapporté à la capacité de l'unité (A71 si connue, sinon max observé
-- sur toute la période collectée). cf_max : borne haute des bins (valeurs au-delà dans le dernier bin).
CREATE OR REPLACE FUNCTION entsoe.cum_histo_per_unit(units text[], t_from timestamptz, t_to timestamptz,
  n int, bins int, norm boolean, cf_max double precision)
RETURNS TABLE (metric text, eic_code text, "order" double precision, share double precision)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  WITH u AS (
    SELECT u.id, u.eic,
      CASE WHEN norm THEN coalesce(u.capacity,
        (SELECT max(gen) FROM raw.generation_unit WHERE unit_id = u.id)) ELSE 1 END AS cap
    FROM raw.unit u WHERE u.eic = ANY(units)
  ),
  s AS (
    SELECT u.eic, array_agg(g.gen / nullif(u.cap, 0)) AS cf, array_agg(g.gen) AS mw,
      sum(g.gen * g.dur / 60.0) AS mwh, count(*) AS cnt
    FROM u JOIN raw.generation_unit g ON g.unit_id = u.id
    WHERE g.time >= t_from AND g.time < t_to AND g.gen IS NOT NULL
    GROUP BY u.eic
  )
  SELECT c.metric, s.eic, c."order", c.share
  FROM s, raw.cum_histo(s.cf, n, bins, cf_max) c
  UNION ALL
  SELECT m, s.eic, NULL, v FROM s, LATERAL (VALUES
    ('min_share', (SELECT min(x) FROM unnest(s.cf) x)),
    ('max_share', (SELECT max(x) FROM unnest(s.cf) x)),
    ('sum_share', (SELECT avg(x) FROM unnest(s.cf) x)),
    ('sum_prod',  s.mwh * 1000),
    ('avg_prod',  (SELECT avg(x) * 1000 FROM unnest(s.mw) x)),
    ('min_prod',  (SELECT min(x) * 1000 FROM unnest(s.mw) x)),
    ('max_prod',  (SELECT max(x) * 1000 FROM unnest(s.mw) x)),
    ('cnt',       s.cnt::double precision)
  ) AS st(m, v)
$$;

-- --- Production par pays ----------------------------------------------------------------

CREATE OR REPLACE FUNCTION entsoe.generation_per_countries(countries text[], production_types text[],
  t_from timestamptz, t_to timestamptz)
RETURNS TABLE ("time" timestamptz, metric text, value double precision) LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT g.time, c.code || ' ' || g.ptype, g.gen * 1000
  FROM raw.country_domains(countries) c
  JOIN raw.generation g ON g.domain_id = c.domain_id
  WHERE g.ptype::text = ANY(production_types) AND g.time >= t_from AND g.time < t_to AND g.gen IS NOT NULL
  ORDER BY 1
$$;

-- Carte thermique jour x heure (heure locale Europe/Brussels) de la production sommée, en kWh.
-- Le 5e paramètre (1.2) de l'original n'est pas déductible des dashboards : accepté et ignoré.
CREATE OR REPLACE FUNCTION entsoe.generation_heatmap(countries text[], production_types text[],
  t_from timestamptz, t_to timestamptz, unused double precision)
RETURNS TABLE ("time" timestamptz, metric text, value double precision) LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  WITH h AS (
    SELECT g.t, sum(g.mw) AS mw
    FROM raw.gen_hourly((SELECT array_agg(domain_id) FROM raw.country_domains(countries)),
                        production_types::production_type[], t_from, t_to) g
    GROUP BY g.t
  )
  SELECT x.day, x.hour::text, x.kwh FROM (
    SELECT date_trunc('day', h.t AT TIME ZONE 'Europe/Brussels') AT TIME ZONE 'Europe/Brussels' AS day,
           extract(hour FROM h.t AT TIME ZONE 'Europe/Brussels')::int AS hour,
           sum(h.mw) * 1000 AS kwh
    FROM h GROUP BY 1, 2
  ) x ORDER BY x.day, x.hour
$$;

-- Cumul journalier depuis le 1er janvier, une série par année, superposées sur l'année de t_from.
-- flh = heures équivalent pleine charge = kWh cumulés / capacité installée A68 de l'année.
CREATE OR REPLACE FUNCTION entsoe.generation_cumsum_per_day_for_year(countries text[], production_types text[],
  years int[], t_from timestamptz, t_to timestamptz)
RETURNS TABLE ("time" timestamptz, metric text, kwh double precision, flh double precision)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  WITH c AS (SELECT array_agg(domain_id) AS d FROM raw.country_domains(countries)),
  y AS (SELECT unnest(years) AS year),
  daily AS (
    SELECT y.year, date_trunc('day', g.t AT TIME ZONE 'Europe/Brussels')::date AS day, sum(g.mw) AS mwh
    FROM y, c, raw.gen_hourly(c.d, production_types::production_type[],
           make_timestamptz(y.year, 1, 1, 0, 0, 0, 'Europe/Brussels'),
           make_timestamptz(y.year + 1, 1, 1, 0, 0, 0, 'Europe/Brussels')) g
    GROUP BY 1, 2
  ),
  cap AS (
    SELECT ic.year, sum(ic.value) AS mw FROM raw.installed_capacity ic, c
    WHERE ic.domain_id = ANY(c.d) AND ic.ptype::text = ANY(production_types) AND ic.year = ANY(years)
    GROUP BY 1
  ),
  base AS (SELECT extract(year FROM t_from AT TIME ZONE 'Europe/Brussels')::int AS y0)
  SELECT (make_date(base.y0, 1, 1) + (d.day - make_date(d.year, 1, 1)))::timestamp AT TIME ZONE 'Europe/Brussels',
         d.year::text,
         sum(d.mwh) OVER w * 1000,
         sum(d.mwh) OVER w / nullif(cap.mw, 0)
  FROM daily d CROSS JOIN base LEFT JOIN cap USING (year)
  WINDOW w AS (PARTITION BY d.year ORDER BY d.day)
  ORDER BY 1
$$;

CREATE OR REPLACE FUNCTION entsoe.capacities_per_countries_prod_types_years(countries text[], production_types text[], years int[])
RETURNS TABLE (country text, production_type text, year int, capacity double precision)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT c.code, ic.ptype::text, ic.year::int, ic.value * 1000
  FROM raw.country_domains(countries) c JOIN raw.installed_capacity ic ON ic.domain_id = c.domain_id
  WHERE ic.ptype::text = ANY(production_types) AND ic.year = ANY(years)
  ORDER BY 1, 2, 3
$$;

-- Taux de couverture de la demande par les filières choisies (somme des pays).
-- scale : production remise à l'échelle de la charge (Σcharge / Σproduction toutes filières sur la
-- période), pour neutraliser le solde des échanges. Hypothèse : la formule d'origine n'est pas publiée.
CREATE OR REPLACE FUNCTION entsoe.cum_histo_per_countries_prod_types(countries text[], production_types text[],
  t_from timestamptz, t_to timestamptz, n int, bins int, scale boolean)
RETURNS TABLE (metric text, "order" double precision, share double precision)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  WITH c AS (SELECT array_agg(domain_id) AS d FROM raw.country_domains(countries)),
  sel AS (SELECT g.t, sum(g.mw) AS mw FROM c, raw.gen_hourly(c.d, production_types::production_type[], t_from, t_to) g GROUP BY 1),
  tot AS (SELECT sum(g.mw) AS mw FROM c, raw.gen_hourly(c.d, enum_range(NULL::production_type), t_from, t_to) g),
  ld AS (SELECT l.t, sum(l.mw) AS mw FROM c, raw.load_hourly(c.d, t_from, t_to) l GROUP BY 1),
  j AS (SELECT sel.mw AS prod, ld.mw AS cons FROM sel JOIN ld USING (t) WHERE ld.mw > 0),
  k AS (SELECT CASE WHEN scale THEN (SELECT sum(cons) FROM j) / nullif((SELECT mw FROM tot), 0) ELSE 1 END AS f),
  r AS (SELECT j.prod * k.f AS prod, j.cons, j.prod * k.f / j.cons AS share FROM j, k)
  SELECT ch.* FROM (SELECT array_agg(share) a FROM r) x, raw.cum_histo(x.a, n, bins, NULL) ch
  WHERE EXISTS (SELECT 1 FROM r)
  UNION ALL
  SELECT m, NULL, v FROM (SELECT
      min(share) mn, max(share) mx, sum(prod) / nullif(sum(cons), 0) ss,
      sum(least(prod, cons)) / nullif(sum(cons), 0) sl, sum(prod) * 1000 sp, sum(cons) * 1000 sc
    FROM r HAVING count(*) > 0) s,
  LATERAL (VALUES ('min_share', mn), ('max_share', mx), ('sum_share', ss),
                  ('sum_share_limit_cons', sl), ('sum_prod', sp), ('sum_cons', sc)) AS st(m, v)
$$;

-- --- Prix --------------------------------------------------------------------------------

-- Une série par zone de prix (Grafana pivote sur metric). Pas natif jusqu'à 62 jours,
-- moyenne horaire jusqu'à 2 ans, journalière au-delà. ENTSO-E publie A44 en EUR : currency ignoré.
CREATE OR REPLACE FUNCTION entsoe.day_ahead_prices(currency text, t_from timestamptz, t_to timestamptz)
RETURNS TABLE ("time" timestamptz, metric text, value double precision) LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  WITH z AS (
    SELECT a.domain_id, a.code FROM raw.area a WHERE a.area_type = 'bzn'
  ),
  p AS (
    SELECT DISTINCT ON (d.domain_id, d.time) d.time, d.domain_id, d.price
    FROM raw.day_ahead_price d
    WHERE d.domain_id IN (SELECT domain_id FROM z) AND d.time >= t_from AND d.time < t_to
    ORDER BY d.domain_id, d.time, d.dur
  ),
  b AS (
    SELECT CASE WHEN t_to - t_from <= interval '62 days' THEN NULL
                WHEN t_to - t_from <= interval '2 years' THEN interval '1 hour'
                ELSE interval '1 day' END AS w
  )
  SELECT CASE WHEN b.w IS NULL THEN p.time ELSE time_bucket(b.w, p.time, 'Europe/Brussels') END,
         z.code, avg(p.price)
  FROM p JOIN z USING (domain_id), b
  GROUP BY 1, 2 ORDER BY 1
$$;

-- Heures cumulées depuis le 1er janvier à prix négatif (inf_0) ou négatif ou nul (inf_eq_0),
-- une série par zone x année, superposées sur l'année de t_from. Un point par jour.
CREATE OR REPLACE FUNCTION entsoe.cumulative_negative_day_ahead_prices(zones text[], years int[], cnt_type text,
  t_from timestamptz, t_to timestamptz)
RETURNS TABLE ("time" timestamptz, metric text, value double precision) LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  WITH z AS (SELECT a.domain_id, a.code FROM raw.area a WHERE a.area_type = 'bzn' AND a.code = ANY(zones)),
  y AS (SELECT unnest(years) AS year),
  p AS (
    SELECT DISTINCT ON (d.domain_id, d.time) d.domain_id, d.time, d.dur, d.price, y.year
    FROM y, raw.day_ahead_price d
    WHERE d.domain_id IN (SELECT domain_id FROM z)
      AND d.time >= make_timestamptz(y.year, 1, 1, 0, 0, 0, 'Europe/Brussels')
      AND d.time <  make_timestamptz(y.year + 1, 1, 1, 0, 0, 0, 'Europe/Brussels')
    ORDER BY d.domain_id, d.time, d.dur
  ),
  daily AS (
    SELECT p.domain_id, p.year, date_trunc('day', p.time AT TIME ZONE 'Europe/Brussels')::date AS day,
      sum(CASE WHEN p.price < 0 OR (cnt_type = 'inf_eq_0' AND p.price = 0) THEN p.dur / 60.0 ELSE 0 END) AS h
    FROM p GROUP BY 1, 2, 3
  ),
  base AS (SELECT extract(year FROM t_from AT TIME ZONE 'Europe/Brussels')::int AS y0)
  SELECT (make_date(base.y0, 1, 1) + (d.day - make_date(d.year, 1, 1)))::timestamp AT TIME ZONE 'Europe/Brussels',
         z.code || ' ' || d.year,
         sum(d.h) OVER (PARTITION BY d.domain_id, d.year ORDER BY d.day)
  FROM daily d JOIN z USING (domain_id) CROSS JOIN base
  ORDER BY 1
$$;

-- Prix de capture : prix DA moyen pondéré par un profil, et rapport au prix de base, par bucket.
-- Profils : production réalisée (A75), base (poids 1), demand (A65), prévision DA éolien/solaire (A69).
CREATE OR REPLACE FUNCTION entsoe.capture_price(zones text[], production_types production_type[], others text[],
  production_types_day_ahead production_type[], t_from timestamptz, t_to timestamptz, bucket_width text)
RETURNS TABLE ("time" timestamptz, metric text, price double precision, rate double precision)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  WITH z AS (SELECT a.domain_id, a.code FROM raw.area a WHERE a.area_type = 'bzn' AND a.code = ANY(zones)),
  d AS (SELECT array_agg(domain_id) AS ids FROM z),
  pr AS (SELECT p.* FROM d, raw.price_hourly(d.ids, t_from, t_to) p),
  w AS (
    SELECT g.t, g.domain_id, g.ptype::text AS profile, g.mw AS w
      FROM d, raw.gen_hourly(d.ids, production_types, t_from, t_to) g
    UNION ALL
    SELECT pr.t, pr.domain_id, 'base', 1 FROM pr WHERE 'base' = ANY(others)
    UNION ALL
    SELECT l.t, l.domain_id, 'demand', l.mw FROM d, raw.load_hourly(d.ids, t_from, t_to) l WHERE 'demand' = ANY(others)
    UNION ALL
    SELECT time_bucket('1 hour', f.time), f.domain_id, f.ptype || ' day ahead', avg(f.value)
      FROM raw.generation_forecast f, d
      WHERE f.domain_id = ANY(d.ids) AND f.ptype = ANY(production_types_day_ahead)
        AND f.time >= t_from AND f.time < t_to
      GROUP BY 1, 2, 3
  ),
  b AS (
    SELECT time_bucket(bucket_width::interval, pr.t, 'Europe/Brussels') AS bt, pr.domain_id, w.profile,
      sum(w.w * pr.price) / nullif(sum(w.w), 0) AS capture
    FROM pr JOIN w USING (t, domain_id) GROUP BY 1, 2, 3
  ),
  base AS (
    SELECT time_bucket(bucket_width::interval, pr.t, 'Europe/Brussels') AS bt, pr.domain_id, avg(pr.price) AS base
    FROM pr GROUP BY 1, 2
  )
  SELECT b.bt, z.code || ' ' || b.profile, b.capture, b.capture / nullif(base.base, 0)
  FROM b JOIN base USING (bt, domain_id) JOIN z USING (domain_id)
  ORDER BY 1
$$;

-- --- Corrélations ------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION entsoe.map_code_per_type(area_type text)
RETURNS TABLE (code text) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT a.code FROM raw.area a WHERE a.area_type = map_code_per_type.area_type ORDER BY 1
$$;

-- Corrélation de Pearson entre séries zone x filière (total = charge A65), moyennées par bucket.
-- Une ligne par paire non ordonnée ; le panel reconstruit la symétrie et la diagonale.
CREATE OR REPLACE FUNCTION entsoe.correlatogram(area_type text, zones text[], production_types production_type[],
  bucket text, t_from timestamptz, t_to timestamptz)
RETURNS TABLE (metric1 text, metric2 text, value double precision)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  WITH z AS (SELECT a.domain_id, a.code FROM raw.area a
             WHERE a.area_type = correlatogram.area_type AND a.code = ANY(zones)),
  d AS (SELECT array_agg(domain_id) AS ids FROM z),
  s AS (
    SELECT time_bucket(bucket::interval, g.t, 'Europe/Brussels') AS bt, z.code || ' ' || g.ptype AS m, avg(g.mw) AS v
      FROM d, raw.gen_hourly(d.ids, production_types, t_from, t_to) g JOIN z USING (domain_id)
      GROUP BY 1, 2
    UNION ALL
    SELECT time_bucket(bucket::interval, l.t, 'Europe/Brussels'), z.code || ' total', avg(l.mw)
      FROM d, raw.load_hourly(d.ids, t_from, t_to) l JOIN z USING (domain_id)
      WHERE 'total' = ANY(production_types)
      GROUP BY 1, 2
  )
  SELECT s1.m, s2.m, corr(s1.v, s2.v)
  FROM s s1 JOIN s s2 ON s1.bt = s2.bt AND s1.m < s2.m
  GROUP BY 1, 2
  HAVING count(*) > 2
  ORDER BY 1, 2
$$;

RESET ROLE;

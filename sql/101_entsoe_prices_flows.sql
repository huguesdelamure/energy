-- Prix day-ahead et flux : fonctions consommées par le plugin deck.gl (contrat : scratchpad deckgl/contract.md,
-- résumé dans dashboards/README.md). Idempotent. À exécuter en postgres.

SET ROLE energy;

-- Format wide imposé par le layer DayAheadPrices : il ne lit que la première trame du refId
-- day_ahead_prices, une colonne par zone nommée par son code court. Colonnes = les 42 de l'original.
-- Pas natif jusqu'à 62 jours, moyenne horaire jusqu'à 2 ans, journalière au-delà.
-- ENTSO-E publie A44 en EUR : currency est accepté et ignoré.
DROP FUNCTION IF EXISTS entsoe.day_ahead_prices(text, timestamptz, timestamptz);
CREATE FUNCTION entsoe.day_ahead_prices(currency text, t_from timestamptz, t_to timestamptz)
RETURNS TABLE (
  "time" timestamptz,
  "AT" double precision,
  "BE" double precision,
  "BG" double precision,
  "CH" double precision,
  "CZ" double precision,
  "DE_LU" double precision,
  "DK1" double precision,
  "DK2" double precision,
  "EE" double precision,
  "ES" double precision,
  "FI" double precision,
  "FR" double precision,
  "GR" double precision,
  "HR" double precision,
  "HU" double precision,
  "IT-CNORTH" double precision,
  "IT-CSOUTH" double precision,
  "IT-Calabria" double precision,
  "IT-NORTH" double precision,
  "IT-SACOAC" double precision,
  "IT-SOUTH" double precision,
  "IT-Sardinia" double precision,
  "IT-Sicily" double precision,
  "LT" double precision,
  "LV" double precision,
  "NL" double precision,
  "NO1" double precision,
  "NO2" double precision,
  "NO2NSL" double precision,
  "NO3" double precision,
  "NO4" double precision,
  "NO5" double precision,
  "PL" double precision,
  "PT" double precision,
  "RO" double precision,
  "RS" double precision,
  "SE1" double precision,
  "SE2" double precision,
  "SE3" double precision,
  "SE4" double precision,
  "SI" double precision,
  "SK" double precision
) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  WITH z AS (SELECT a.domain_id, a.code FROM raw.area a WHERE a.area_type = 'bzn'),
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
  SELECT CASE WHEN b.w IS NULL THEN p.time ELSE time_bucket(b.w, p.time, 'Europe/Brussels') END AS t,
         round(avg(p.price) FILTER (WHERE z.code = 'AT')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'BE')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'BG')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'CH')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'CZ')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'DE_LU')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'DK1')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'DK2')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'EE')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'ES')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'FI')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'FR')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'GR')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'HR')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'HU')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'IT-CNORTH')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'IT-CSOUTH')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'IT-Calabria')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'IT-NORTH')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'IT-SACOAC')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'IT-SOUTH')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'IT-Sardinia')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'IT-Sicily')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'LT')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'LV')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'NL')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'NO1')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'NO2')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'NO2NSL')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'NO3')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'NO4')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'NO5')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'PL')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'PT')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'RO')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'RS')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'SE1')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'SE2')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'SE3')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'SE4')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'SI')::numeric, 2)::double precision,
         round(avg(p.price) FILTER (WHERE z.code = 'SK')::numeric, 2)::double precision
  FROM p JOIN z USING (domain_id), b
  GROUP BY 1 ORDER BY 1
$$;

-- Nœuds du graphe de flux : id libre, code = EIC (clé des polygones et points du plugin).
CREATE OR REPLACE FUNCTION entsoe.area_map_code_eic(area_type text)
RETURNS TABLE (id text, code text) LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT a.code, d.eic FROM raw.area a JOIN raw.domain d ON d.id = a.domain_id
  WHERE a.area_type = area_map_code_eic.area_type ORDER BY 1
$$;

-- Flux d'un type de zone, moyennés par bucket (MW). kind : physical, commercial, commercial_day_ahead.
CREATE OR REPLACE FUNCTION raw.flow_bucketed(p_area_type text, t_from timestamptz, t_to timestamptz,
  bucket interval, p_kind text)
RETURNS TABLE (bt timestamptz, from_id smallint, to_id smallint, mw double precision)
LANGUAGE sql STABLE AS $$
  SELECT time_bucket(bucket, f.time, 'Europe/Brussels'), f.from_id, f.to_id, avg(f.value)
  FROM raw.flow f
  JOIN raw.border b ON b.area_type = p_area_type AND b.from_id = f.from_id AND b.to_id = f.to_id
  WHERE f.kind = p_kind::raw.flow_kind AND f.time >= t_from AND f.time < t_to
  GROUP BY 1, 2, 3
$$;

-- Arêtes du graphe : time croissant, source/target en EIC, value en kW.
-- net_flow = true : un seul arc par frontière, dans le sens du solde.
-- Le layer Flow perd la dernière arête de chaque pas de temps (slice(i, r) exclusif) : on ajoute
-- en fin de pas une arête nulle sacrifiée, pour que toutes les vraies arêtes s'affichent.
CREATE OR REPLACE FUNCTION entsoe.flow_graph_edges_eic(area_type text, t_from timestamptz, t_to timestamptz,
  bucket interval, flow_type text, net_flow text)
RETURNS TABLE ("time" timestamptz, source text, target text, value double precision)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  WITH f AS (SELECT * FROM raw.flow_bucketed(area_type, t_from, t_to, bucket, flow_type)),
  e AS (
    SELECT f.bt, f.from_id, f.to_id, f.mw FROM f WHERE NOT net_flow::boolean
    UNION ALL
    SELECT a.bt,
           CASE WHEN a.mw - coalesce(b.mw, 0) >= 0 THEN a.from_id ELSE a.to_id END,
           CASE WHEN a.mw - coalesce(b.mw, 0) >= 0 THEN a.to_id ELSE a.from_id END,
           abs(a.mw - coalesce(b.mw, 0))
    FROM f a LEFT JOIN f b ON b.bt = a.bt AND b.from_id = a.to_id AND b.to_id = a.from_id
    WHERE net_flow::boolean AND a.from_id < a.to_id
  ),
  rows AS (
    SELECT e.bt, df.eic AS source, dt.eic AS target, e.mw * 1000 AS value, 0 AS pad
    FROM e JOIN raw.domain df ON df.id = e.from_id JOIN raw.domain dt ON dt.id = e.to_id
    WHERE e.mw > 0
    UNION ALL
    SELECT DISTINCT ON (e.bt) e.bt, df.eic, dt.eic, 0, 1
    FROM e JOIN raw.domain df ON df.id = e.from_id JOIN raw.domain dt ON dt.id = e.to_id
  )
  SELECT bt, source, target, value FROM rows ORDER BY bt, pad, source, target
$$;

-- Solde net par zone (kW) : positif = export net, négatif = import net. Une série par zone.
CREATE OR REPLACE FUNCTION entsoe.flow_net_interpolated(area_type text, t_from timestamptz, t_to timestamptz,
  bucket interval, flow_type text)
RETURNS TABLE ("time" timestamptz, metric text, value double precision)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  WITH f AS (SELECT * FROM raw.flow_bucketed(area_type, t_from, t_to, bucket, flow_type)),
  n AS (
    SELECT bt, from_id AS id, mw FROM f
    UNION ALL
    SELECT bt, to_id, -mw FROM f
  )
  SELECT n.bt, a.code, sum(n.mw) * 1000
  FROM n JOIN raw.area a ON a.domain_id = n.id AND a.area_type = flow_net_interpolated.area_type
  GROUP BY 1, 2 ORDER BY 1
$$;

RESET ROLE;

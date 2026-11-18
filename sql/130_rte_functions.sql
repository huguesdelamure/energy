-- Fonctions rte.* (France Nuclear). Contrat : dashboards/spec-fr-world.md. Puissances en MW.
-- "update_id" = jour J (entier = J - 2015-01-01) ; état des indisponibilités tel que connu à la fin de J
-- (minuit UTC suivant), reconstitué depuis l'historique complet des versions REMIT.
-- Idempotent. À exécuter en postgres.
SET ROLE energy;

-- --- Aides internes -----------------------------------------------------------------------

CREATE OR REPLACE FUNCTION raw.rte_update_instant(update_id int) RETURNS timestamptz LANGUAGE sql IMMUTABLE AS $$
  SELECT ((date '2015-01-01' + update_id + 1)::timestamp AT TIME ZONE 'UTC')
$$;

-- Parc nucléaire = unités déclarées NUCLEAR par Actual Generation depuis 2015 (59, dont Fessenheim 1 et 2).
-- Chaque unité ne compte qu'entre in_service_from et in_service_until : sans cela un réacteur fermé
-- (Fessenheim, 2020) ou pas encore en service (Flamanville 3, 2024) serait compté disponible à pleine puissance,
-- faute de message d'indisponibilité.

-- Bornes d'activité : premier et dernier pas publiés par Actual Generation ; le début est avancé au premier
-- message d'indisponibilité de l'unité s'il est antérieur (unités publiées tardivement par Actual Generation).
-- Le début des données (2015-01-01) et une publication de moins de 7 jours laissent la borne ouverte.
-- Appelée par rte_collect.py après chaque collecte.
CREATE OR REPLACE FUNCTION raw.rte_refresh_unit_bounds() RETURNS void LANGUAGE sql AS $$
  WITH remit AS (
    SELECT unit_eic, min(least(publication, start_date)) AS first FROM raw.rte_unavailability GROUP BY unit_eic
  ),
  b AS (
    SELECT u.id,
      least((SELECT min(g.time) FROM raw.rte_generation g WHERE g.unit_id = u.id), r.first) AS first,
      (SELECT max(g.time) FROM raw.rte_generation g WHERE g.unit_id = u.id) AS last
    FROM raw.rte_unit u LEFT JOIN remit r ON r.unit_eic = u.eic
  )
  UPDATE raw.rte_unit u SET
    in_service_from  = CASE WHEN b.first > timestamptz '2015-01-02 00:00+00' THEN b.first END,
    in_service_until = CASE WHEN b.last < now() - interval '7 days' THEN b.last + interval '1 hour' END
  FROM b WHERE b.id = u.id
$$;
CREATE OR REPLACE FUNCTION raw.rte_nuclear_units() RETURNS TABLE (eic text, name text, capacity real)
LANGUAGE sql STABLE AS $$
  SELECT u.eic, u.name, u.installed_capacity FROM raw.rte_unit u WHERE u.production_type = 'NUCLEAR'
$$;

-- Tranches d'indisponibilité en vigueur, telles que connues à as_of (dernière version par événement,
-- messages retirés exclus), qui recouvrent [t_from, t_to[.
CREATE OR REPLACE FUNCTION raw.rte_segments(as_of timestamptz, eics text[], t_from timestamptz, t_to timestamptz)
RETURNS TABLE (eic text, s timestamptz, e timestamptz, available real) LANGUAGE sql STABLE AS $$
  WITH latest AS (
    SELECT DISTINCT ON (identifier) message_id, unit_eic, status
    FROM raw.rte_unavailability
    WHERE publication <= as_of AND unit_eic = ANY(eics)
    ORDER BY identifier, publication DESC, version DESC
  )
  SELECT l.unit_eic, v.start_date, v.end_date, v.available
  FROM latest l JOIN raw.rte_unavailability_value v USING (message_id)
  WHERE l.status IS DISTINCT FROM 'DISMISSED' AND v.end_date > t_from AND v.start_date < t_to
$$;

-- Disponibilité en escalier par unité (MW) : un point à t_from puis à chaque changement.
CREATE OR REPLACE FUNCTION raw.rte_availability(as_of timestamptz, eics text[], t_from timestamptz, t_to timestamptz)
RETURNS TABLE (eic text, t timestamptz, available double precision) LANGUAGE sql STABLE AS $$
  WITH seg AS MATERIALIZED (SELECT * FROM raw.rte_segments(as_of, eics, t_from, t_to)),
  u AS (SELECT r.eic, r.installed_capacity AS cap, r.in_service_from AS f, r.in_service_until AS l
        FROM raw.rte_unit r WHERE r.eic = ANY(eics)),
  pts AS (
    SELECT u.eic, t_from AS t FROM u
    UNION SELECT u.eic, u.f FROM u WHERE u.f > t_from AND u.f < t_to
    UNION SELECT u.eic, u.l FROM u WHERE u.l > t_from AND u.l < t_to
    UNION SELECT seg.eic, seg.s FROM seg WHERE seg.s > t_from AND seg.s < t_to
    UNION SELECT seg.eic, seg.e FROM seg WHERE seg.e > t_from AND seg.e < t_to
  ),
  v AS (
    SELECT p.eic, p.t, CASE WHEN p.t < u.f OR p.t >= u.l THEN 0 ELSE coalesce(
      (SELECT min(seg.available) FROM seg WHERE seg.eic = p.eic AND seg.s <= p.t AND seg.e > p.t), u.cap) END AS available
    FROM pts p JOIN u USING (eic)
  )
  -- on ne garde que les vrais changements de valeur
  SELECT eic, t, available FROM (
    SELECT v.*, lag(available) OVER (PARTITION BY eic ORDER BY t) AS prev FROM v
  ) x WHERE prev IS DISTINCT FROM available
$$;

-- Somme en escalier d'un ensemble d'unités : cumul des variations de chaque unité.
CREATE OR REPLACE FUNCTION raw.rte_availability_sum(as_of timestamptz, eics text[], t_from timestamptz, t_to timestamptz)
RETURNS TABLE (t timestamptz, available double precision) LANGUAGE sql STABLE AS $$
  WITH a AS (SELECT * FROM raw.rte_availability(as_of, eics, t_from, t_to)),
  d AS (SELECT a.t, a.available - coalesce(lag(a.available) OVER (PARTITION BY a.eic ORDER BY a.t), 0) AS delta FROM a),
  g AS (SELECT d.t, sum(d.delta) AS delta FROM d GROUP BY d.t)
  SELECT g.t, sum(g.delta) OVER (ORDER BY g.t) FROM g ORDER BY g.t
$$;

CREATE OR REPLACE FUNCTION raw.rte_nuclear_eics() RETURNS text[] LANGUAGE sql STABLE AS $$
  SELECT array_agg(eic) FROM raw.rte_nuclear_units()
$$;

-- --- Variables -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION rte.production_types_with_units()
RETURNS TABLE (__text text, __value text) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT DISTINCT lower(production_type), lower(production_type) FROM raw.rte_unit
  WHERE production_type IS NOT NULL ORDER BY 1
$$;

-- Jours où au moins un message du type a été publié, du plus récent au plus ancien.
-- origin ('cre' dans l'original) est accepté et ignoré : une seule source, l'API RTE.
CREATE OR REPLACE FUNCTION rte.unavailability_update_id_date(origin text, production_type text)
RETURNS TABLE (__text text, __value int) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT to_char(d, 'YYYY-MM-DD'), (d - date '2015-01-01')::int
  FROM (SELECT DISTINCT (publication AT TIME ZONE 'UTC')::date AS d FROM raw.rte_unavailability
        WHERE fuel_type = upper(production_type)) x
  ORDER BY d DESC
$$;

CREATE OR REPLACE FUNCTION rte.unavailability_tag(update_id int)
RETURNS TABLE ("time" timestamptz, text text, tags text) LANGUAGE sql IMMUTABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT raw.rte_update_instant(update_id), 'Update ' || to_char(date '2015-01-01' + update_id, 'YYYY-MM-DD'), 'update'
$$;

CREATE OR REPLACE FUNCTION rte.nuclear_name_eic_code()
RETURNS TABLE (__text text, __value text) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT name, eic FROM raw.rte_nuclear_units() ORDER BY name
$$;

-- --- Production ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION rte.generation_per_unit(eic_code text, t_from timestamptz, t_to timestamptz)
RETURNS TABLE ("time" timestamptz, value real) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT g.time, g.value FROM raw.rte_generation g JOIN raw.rte_unit u ON u.id = g.unit_id
  WHERE u.eic = eic_code AND g.time >= t_from AND g.time < t_to ORDER BY 1
$$;

CREATE OR REPLACE FUNCTION rte.generation_per_units_of_production_type(production_type text, t_from timestamptz, t_to timestamptz)
RETURNS TABLE ("time" timestamptz, metric text, value real) LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT g.time, u.name, g.value FROM raw.rte_generation g JOIN raw.rte_unit u ON u.id = g.unit_id
  WHERE u.production_type = upper(production_type) AND g.time >= t_from AND g.time < t_to ORDER BY 1
$$;

-- Variation horaire de production par unité (MW), une série par unité.
CREATE OR REPLACE FUNCTION rte.generation_per_units_delta(t_from timestamptz, t_to timestamptz, production_type text)
RETURNS TABLE ("time" timestamptz, metric text, value real) LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT x.time, x.name, x.delta FROM (
    SELECT g.time, u.name, g.value - lag(g.value) OVER (PARTITION BY g.unit_id ORDER BY g.time) AS delta
    FROM raw.rte_generation g JOIN raw.rte_unit u ON u.id = g.unit_id
    WHERE u.production_type = upper(production_type) AND g.time >= t_from - interval '1 hour' AND g.time < t_to
  ) x WHERE x.time >= t_from AND x.delta IS NOT NULL ORDER BY 1
$$;

CREATE OR REPLACE FUNCTION rte.generation_aggregated_of_production_type(production_type text, t_from timestamptz, t_to timestamptz)
RETURNS TABLE ("time" timestamptz, value double precision) LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT g.time, sum(g.value) FROM raw.rte_generation g JOIN raw.rte_unit u ON u.id = g.unit_id
  WHERE u.production_type = upper(production_type) AND g.time >= t_from AND g.time < t_to
  GROUP BY 1 ORDER BY 1
$$;

-- Production par réacteur + série "All" (somme du parc). eic_code devient un label Grafana.
-- Colonnes : le panel affiche ${__field.labels.name} et lie sur ${__field.labels.eic_code} ; la série
-- de somme doit contenir "All" (override byRegexp .*All.*).
DROP FUNCTION IF EXISTS rte.generation_per_units_nuclear(timestamptz, timestamptz);
CREATE FUNCTION rte.generation_per_units_nuclear(t_from timestamptz, t_to timestamptz)
RETURNS TABLE ("time" timestamptz, value double precision, name text, eic_code text) LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  WITH g AS (
    SELECT g.time, u.name, u.eic, g.value FROM raw.rte_generation g JOIN raw.rte_unit u ON u.id = g.unit_id
    WHERE u.eic = ANY(raw.rte_nuclear_eics()) AND g.time >= t_from AND g.time < t_to
  )
  SELECT time, value, name, eic FROM g
  UNION ALL
  SELECT time, sum(value), 'All', 'All' FROM g GROUP BY time
  ORDER BY 1
$$;

-- Production du parc et facteur de charge (production / puissance installée du parc).
CREATE OR REPLACE FUNCTION rte.production_charge_factor_nuclear(t_from timestamptz, t_to timestamptz)
RETURNS TABLE ("time" timestamptz, production double precision, "charge factor" double precision)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  WITH cap AS (SELECT sum(capacity) AS mw FROM raw.rte_nuclear_units())
  SELECT g.time, sum(g.value), sum(g.value) / nullif((SELECT mw FROM cap), 0)
  FROM raw.rte_generation g JOIN raw.rte_unit u ON u.id = g.unit_id
  WHERE u.eic = ANY(raw.rte_nuclear_eics()) AND g.time >= t_from AND g.time < t_to
  GROUP BY 1 ORDER BY 1
$$;

-- Réacteurs en marche (> 20 MW) à la dernière heure disponible de la plage.
CREATE OR REPLACE FUNCTION rte.on_off_share_nuclear(t_from timestamptz, t_to timestamptz)
RETURNS TABLE ("on" bigint, "off" bigint, share_on double precision) LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  WITH n AS (SELECT eic FROM raw.rte_nuclear_units()),
  last AS (
    SELECT max(g.time) AS t FROM raw.rte_generation g JOIN raw.rte_unit u ON u.id = g.unit_id
    WHERE u.eic IN (SELECT eic FROM n) AND g.time >= t_from AND g.time < t_to
  ),
  s AS (
    SELECT n.eic, coalesce(g.value, 0) > 20 AS running
    FROM n JOIN raw.rte_unit u ON u.eic = n.eic
    LEFT JOIN raw.rte_generation g ON g.unit_id = u.id AND g.time = (SELECT t FROM last)
  )
  SELECT count(*) FILTER (WHERE running), count(*) FILTER (WHERE NOT running),
         count(*) FILTER (WHERE running)::double precision / nullif(count(*), 0)
  FROM s
$$;

-- --- Disponibilité ---------------------------------------------------------------------------

-- Disponibilité du parc selon l'état le plus récent des indisponibilités (passé et futur).
CREATE OR REPLACE FUNCTION rte.availability_nuclear(t_from timestamptz, t_to timestamptz)
RETURNS TABLE ("time" timestamptz, "availability capacity" double precision, "availability share" double precision)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT a.t, a.available, a.available / nullif((SELECT sum(capacity) FROM raw.rte_nuclear_units()), 0)
  FROM raw.rte_availability_sum(now(), raw.rte_nuclear_eics(), t_from, t_to) a
$$;

CREATE OR REPLACE FUNCTION rte.availability_per_unit_raw(eic_code text, update_id int, t_from timestamptz, t_to timestamptz)
RETURNS TABLE ("time" timestamptz, value double precision) LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT a.t, a.available FROM raw.rte_availability(raw.rte_update_instant(update_id), ARRAY[eic_code], t_from, t_to) a
  ORDER BY 1
$$;

-- Disponibilité / puissance installée de chaque réacteur (0..1), pour la frise.
CREATE OR REPLACE FUNCTION rte.availability_per_unit_capacity_factor_raw(update_id int, t_from timestamptz, t_to timestamptz)
RETURNS TABLE ("time" timestamptz, metric text, value double precision) LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT a.t, u.name, a.available / nullif(u.capacity, 0)
  FROM raw.rte_availability(raw.rte_update_instant(update_id), raw.rte_nuclear_eics(), t_from, t_to) a
  JOIN raw.rte_nuclear_units() u USING (eic)
  ORDER BY 1
$$;

-- Disponibilité du parc pour plusieurs états connus (une série par date d'état).
CREATE OR REPLACE FUNCTION rte.availability_sum_raw_multi(update_ids int[], t_from timestamptz, t_to timestamptz)
RETURNS TABLE ("time" timestamptz, metric text, value double precision) LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT a.t, to_char(date '2015-01-01' + i, 'YYYY-MM-DD'), a.available
  FROM unnest(update_ids) i,
       raw.rte_availability_sum(raw.rte_update_instant(i), raw.rte_nuclear_eics(), t_from, t_to) a
  ORDER BY 1
$$;

-- Courbes RTE ressaisies à la main depuis des PDF (2022-2023) dans l'original : non reproductibles.
CREATE OR REPLACE FUNCTION rte.availability_sum_raw_multi_origin(origins text[], production_type text,
  t_from timestamptz, t_to timestamptz)
RETURNS TABLE ("time" timestamptz, metric text, value double precision) LANGUAGE sql IMMUTABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT NULL::timestamptz, NULL::text, NULL::double precision WHERE false
$$;

-- Disponibilité du parc de chaque année (état connu à update_id), superposée sur l'année de t_from.
CREATE OR REPLACE FUNCTION rte.availability_sum_raw_yearly_repeat(update_id int, t_from timestamptz, t_to timestamptz)
RETURNS TABLE ("time" timestamptz, metric text, value double precision) LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  WITH y0 AS (SELECT extract(year FROM t_from AT TIME ZONE 'Europe/Paris')::int AS y),
  years AS (
    SELECT generate_series(2015, extract(year FROM raw.rte_update_instant(update_id) AT TIME ZONE 'Europe/Paris')::int + 1) AS y
  )
  SELECT (a.t + make_interval(years => y0.y - years.y)), years.y::text, a.available
  FROM years, y0,
       raw.rte_availability_sum(raw.rte_update_instant(update_id), raw.rte_nuclear_eics(),
         make_timestamptz(years.y, 1, 1, 0, 0, 0, 'Europe/Paris'),
         make_timestamptz(years.y + 1, 1, 1, 0, 0, 0, 'Europe/Paris')) a
  ORDER BY 1
$$;

-- Tables d'indisponibilités (toutes versions) recouvrant la plage.
CREATE OR REPLACE FUNCTION raw.rte_unav_rows(eics text[], t_from timestamptz, t_to timestamptz)
RETURNS TABLE ("unit name" text, id text, identifier text, version int, type text, status text,
  creation timestamptz, "update" timestamptz, start timestamptz, "end" timestamptz, cap real,
  installed_capacity real, reason text, remarks text)
LANGUAGE sql STABLE AS $$
  SELECT m.unit_name, m.message_id, m.identifier, m.version, m.type, m.status, m.creation, m.publication,
         m.start_date, m.end_date,
         (SELECT min(v.available) FROM raw.rte_unavailability_value v WHERE v.message_id = m.message_id),
         m.installed_capacity, m.reason, m.remarks
  FROM raw.rte_unavailability m
  WHERE m.unit_eic = ANY(eics) AND m.end_date > t_from AND m.start_date < t_to
  ORDER BY m.publication DESC
$$;

CREATE OR REPLACE FUNCTION rte.unavailabilities_per_production_type(production_type text, t_from timestamptz, t_to timestamptz)
RETURNS TABLE ("unit name" text, id text, identifier text, version int, type text, status text,
  creation timestamptz, "update" timestamptz, start timestamptz, "end" timestamptz, cap real,
  installed_capacity real, reason text, remarks text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT * FROM raw.rte_unav_rows(
    (SELECT array_agg(DISTINCT unit_eic) FROM raw.rte_unavailability WHERE fuel_type = upper(production_type)),
    t_from, t_to)
$$;

CREATE OR REPLACE FUNCTION rte.unavailabilities_per_unit(eic_code text, t_from timestamptz, t_to timestamptz)
RETURNS TABLE (id text, identifier text, version int, type text, status text, creation timestamptz,
  "update" timestamptz, start timestamptz, "end" timestamptz, cap real, installed_capacity real, reason text, remarks text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT id, identifier, version, type, status, creation, "update", start, "end", cap, installed_capacity, reason, remarks
  FROM raw.rte_unav_rows(ARRAY[eic_code], t_from, t_to)
$$;

RESET ROLE;

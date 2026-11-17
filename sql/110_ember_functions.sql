-- Fonctions ember.* (dossier World Electricity). Contrat : dashboards/spec-fr-world.md. Idempotent.
SET ROLE energy;

-- Filières de base (non agrégées) qui composent la production.
CREATE OR REPLACE FUNCTION raw.ember_gen_sources() RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
  SELECT ARRAY['Coal', 'Gas', 'Other fossil', 'Nuclear', 'Hydro', 'Wind', 'Solar', 'Bioenergy', 'Other renewables']
$$;

-- Aires d'une "région" du dashboard : continent Ember, groupe (EU, OECD, G20, G7), tous les pays,
-- ou les 7 régions Ember elles-mêmes (worlds_regions).
CREATE OR REPLACE FUNCTION raw.ember_areas(p_period text, p_region text, p_date date)
RETURNS TABLE (area text, iso3 text, region text) LANGUAGE sql STABLE AS $$
  SELECT DISTINCT e.area, e.iso3, coalesce(e.ember_region, e.area)
  FROM raw.ember e
  WHERE e.period = p_period AND e.date = p_date AND e.source = 'Total generation'
    AND CASE p_region
      WHEN 'worlds_regions' THEN e.area_type = 'Region' AND e.area IN
        ('Africa', 'Asia', 'Europe', 'Latin America and Caribbean', 'Middle East', 'North America', 'Oceania')
      WHEN 'worlds_countries' THEN e.area_type = 'Country or economy'
      WHEN 'EU' THEN e.area_type = 'Country or economy' AND e.eu
      WHEN 'OECD' THEN e.area_type = 'Country or economy' AND e.oecd
      WHEN 'G20' THEN e.area_type = 'Country or economy' AND e.g20
      WHEN 'G7' THEN e.area_type = 'Country or economy' AND e.g7
      ELSE e.area_type = 'Country or economy' AND e.ember_region = p_region
    END
$$;

CREATE OR REPLACE FUNCTION ember.get_date_from_period_region(period text, region text)
RETURNS TABLE (__text text, __value date) LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT CASE WHEN period = 'year' THEN to_char(e.date, 'YYYY') ELSE to_char(e.date, 'YYYY-MM') END, e.date
  FROM (SELECT DISTINCT date FROM raw.ember WHERE raw.ember.period = get_date_from_period_region.period
        AND source = 'Total generation' AND gen_twh > 0) e
  WHERE EXISTS (SELECT 1 FROM raw.ember_areas(period, region, e.date))
  ORDER BY e.date DESC
$$;

-- Lecture par position dans le panel : production (TWh), intensité (gCO2e/kWh), aire, région.
-- Intensité = Σ(production filière x facteur du jeu) / Σ production ; facteur absent du jeu = intensité Ember.
CREATE OR REPLACE FUNCTION ember.production_intensity_per_time_area_config(period text, region text, "time" text, config text)
RETURNS TABLE (production double precision, intensity double precision, area_name text, region_name text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  WITH a AS (SELECT * FROM raw.ember_areas(period, region, "time"::date)),
  s AS (
    SELECT a.area, a.region, e.gen_twh,
      coalesce(
        (SELECT f.factor FROM raw.emission_factor f WHERE f.config = production_intensity_per_time_area_config.config
           AND f.source = e.source AND f.country = a.iso3),
        (SELECT f.factor FROM raw.emission_factor f WHERE f.config = production_intensity_per_time_area_config.config
           AND f.source = e.source AND f.country IS NULL),
        e.intensity, 0) AS factor
    FROM a JOIN raw.ember e ON e.area = a.area
    WHERE e.period = production_intensity_per_time_area_config.period AND e.date = "time"::date
      AND e.source = ANY(raw.ember_gen_sources()) AND e.gen_twh > 0
  )
  SELECT sum(gen_twh), sum(gen_twh * factor) / nullif(sum(gen_twh), 0), s.area, s.region
  FROM s GROUP BY s.area, s.region
  HAVING sum(gen_twh) > 0
  ORDER BY 2
$$;

CREATE OR REPLACE FUNCTION ember.emission_factors(config text)
RETURNS TABLE (source text, country text, factor double precision, reference text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT f.source, coalesce(f.country, 'all'), f.factor, f.reference
  FROM raw.emission_factor f WHERE f.config = emission_factors.config
  UNION ALL
  SELECT s, 'all', NULL, 'Ember (published intensity, per country)'
  FROM unnest(raw.ember_gen_sources()) s
  WHERE NOT EXISTS (SELECT 1 FROM raw.emission_factor f WHERE f.config = emission_factors.config AND f.source = s)
  ORDER BY 1, 2
$$;

CREATE OR REPLACE FUNCTION ember.get_area_name()
RETURNS TABLE (area text) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT DISTINCT e.area FROM raw.ember e ORDER BY 1
$$;

CREATE OR REPLACE FUNCTION ember.get_from_date(area text, period text)
RETURNS TABLE (__text text, __value date) LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT CASE WHEN period = 'year' THEN to_char(e.date, 'YYYY') ELSE to_char(e.date, 'YYYY-MM') END, e.date
  FROM raw.ember e
  WHERE e.area = get_from_date.area AND e.period = get_from_date.period AND e.source = 'Total generation' AND e.gen_twh > 0
  ORDER BY e.date DESC
$$;

-- Seconde période : dates postérieures à la première.
CREATE OR REPLACE FUNCTION ember.get_from_date(area text, period text, from1 text)
RETURNS TABLE (__text text, __value date) LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT * FROM ember.get_from_date(area, period) d WHERE d.__value > from1::date
$$;

-- Durées comparables : k pas (années ou mois) tant que les deux périodes restent dans les données
-- et ne se chevauchent pas. __value = intervalle PostgreSQL ('1 year', '11 mons').
CREATE OR REPLACE FUNCTION ember.get_duration(area text, period text, from1 text, from2 text)
RETURNS TABLE (__text text, __value text) LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  WITH last AS (
    SELECT max(e.date) AS d FROM raw.ember e
    WHERE e.area = get_duration.area AND e.period = get_duration.period AND e.source = 'Total generation'
  ),
  step AS (SELECT CASE WHEN period = 'year' THEN interval '1 year' ELSE interval '1 month' END AS s)
  SELECT CASE WHEN k = 1 THEN '1 ' || period ELSE k || ' ' || period || 's' END, (k * step.s)::text
  FROM step, last, generate_series(1, 600) k
  WHERE from2::date + (k - 1) * step.s <= last.d
    AND from1::date + k * step.s <= from2::date
  ORDER BY k
$$;

-- Cascade : variation (TWh) entre [from1, from1 + duration[ et [from2, from2 + duration[.
-- Colonnes lues par position : y, x. "Exchange" = Δ imports nets, "Demand" = -Δ demande (le panel
-- inverse le signe), de sorte que Σ Δproduction + Δimports - Δdemande = 0.
CREATE OR REPLACE FUNCTION ember.get_waterfall(category text, area text, period text, from1 text, from2 text, duration text)
RETURNS TABLE (y double precision, x text) LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  WITH e AS (
    SELECT e.source,
      sum(e.gen_twh) FILTER (WHERE e.date >= from1::date AND e.date < from1::date + duration::interval) AS v1,
      sum(e.gen_twh) FILTER (WHERE e.date >= from2::date AND e.date < from2::date + duration::interval) AS v2
    FROM raw.ember e
    WHERE e.area = get_waterfall.area AND e.period = get_waterfall.period
    GROUP BY e.source
  ),
  cats AS (
    SELECT c, ord FROM unnest(
      CASE WHEN category = 'gen_agg' THEN ARRAY['Fossil', 'Clean'] ELSE raw.ember_gen_sources() END
    ) WITH ORDINALITY AS u(c, ord)
  )
  SELECT r.y, r.x FROM (
    SELECT coalesce(e.v2, 0) - coalesce(e.v1, 0) AS y, cats.c AS x, cats.ord FROM cats LEFT JOIN e ON e.source = cats.c
    UNION ALL
    SELECT coalesce(v2, 0) - coalesce(v1, 0), 'Exchange', 100 FROM e WHERE source = 'Net imports'
    UNION ALL
    SELECT -(coalesce(v2, 0) - coalesce(v1, 0)), 'Demand', 101 FROM e WHERE source = 'Demand'
  ) r ORDER BY r.ord
$$;

RESET ROLE;

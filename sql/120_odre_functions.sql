-- Fonctions odre.* (France electricity) et map.generation_capacities (carte deck.gl OdreCapacities).
-- Contrats : dashboards/spec-fr-world.md et contrat du plugin. Idempotent.
SET ROLE energy;

CREATE INDEX IF NOT EXISTS odre_installation_year ON raw.odre_installation (year);

-- Filtre "tableau vide ou {''} = pas de filtre" des variables constantes du dashboard.
CREATE OR REPLACE FUNCTION raw.any_or_all(arr text[], val text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT arr IS NULL OR cardinality(array_remove(arr, '')) = 0 OR val = ANY(arr)
$$;

-- Instantané utilisé pour une année de production : registre au 31/12 de l'année s'il existe,
-- sinon registre courant (énergie sur 12 mois glissants).
CREATE OR REPLACE FUNCTION raw.odre_snapshot_for(y int) RETURNS text LANGUAGE sql STABLE AS $$
  SELECT coalesce((SELECT snapshot FROM raw.odre_installation WHERE year = y LIMIT 1), 'current')
$$;

-- Installations filtrées avec leur facteur de charge, pour les années de production demandées.
-- Exclut les installations mises en service pendant ou après l'année (année de production incomplète).
CREATE OR REPLACE FUNCTION raw.odre_cf(filieres text[], combustibles text[], technologies text[], years int[],
  min_cf text, max_cf text, min_count text)
RETURNS TABLE (year_prod int, year_start int, cf double precision, i raw.odre_installation)
LANGUAGE sql STABLE AS $$
  WITH y AS MATERIALIZED (SELECT u AS year_prod, raw.odre_snapshot_for(u) AS snap FROM unnest(years) u),
  base AS (
    SELECT y.year_prod, extract(year FROM o.commissioning)::int AS year_start,
           o.kwh_year / nullif(o.kw_installed * 8760, 0) AS cf, o AS i
    FROM y JOIN raw.odre_installation o ON o.snapshot = y.snap
    WHERE raw.any_or_all(filieres, o.filiere_code) AND raw.any_or_all(combustibles, o.combustible_code)
      AND raw.any_or_all(technologies, o.technology_code)
      AND o.commissioning IS NOT NULL AND o.kw_installed > 0 AND o.kwh_year IS NOT NULL
      AND extract(year FROM o.commissioning) < y.year_prod
  ),
  f AS (
    SELECT base.*, count(*) OVER (PARTITION BY base.year_prod, base.year_start) AS n FROM base
    WHERE (nullif(min_cf, '') IS NULL OR cf >= min_cf::double precision)
      AND (nullif(max_cf, '') IS NULL OR cf <= max_cf::double precision)
  )
  SELECT f.year_prod, f.year_start, f.cf, f.i FROM f
  WHERE nullif(min_count, '') IS NULL OR f.n >= min_count::int
$$;

CREATE OR REPLACE FUNCTION odre.data_per_installation_year(filieres text[], combustibles text[], technologies text[],
  years int[], min_cf text, max_cf text, min_count text)
RETURNS TABLE (year_start int, cf_inst double precision, nom_installation text, nb_groupes double precision,
  nb_installations double precision, energie_annuelle_glissante_injectee double precision,
  puis_max_installee double precision, puis_max_rac double precision, commune text, departement text,
  region text, regime text, date_mise_en_service date, year_prod int)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT c.year_start, c.cf, (c.i).name, (c.i).groups, (c.i).installations, (c.i).kwh_year, (c.i).kw_installed,
         (c.i).kw_rac, (c.i).commune, (c.i).departement, (c.i).region, (c.i).regime, (c.i).commissioning, c.year_prod
  FROM raw.odre_cf(filieres, combustibles, technologies, years, min_cf, max_cf, min_count) c
  ORDER BY c.year_start, c.year_prod
$$;

-- Facteur de charge moyen pondéré par la puissance, par année d'installation (toutes années de prod).
CREATE OR REPLACE FUNCTION odre.capacity_factor_per_installation_year(filieres text[], combustibles text[],
  technologies text[], years int[], min_cf text, max_cf text, min_count text)
RETURNS TABLE ("time" timestamptz, "ODRE average" double precision)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT make_timestamptz(c.year_start, 1, 1, 0, 0, 0, 'UTC'),
         sum((c.i).kwh_year) / nullif(sum((c.i).kw_installed * 8760), 0)
  FROM raw.odre_cf(filieres, combustibles, technologies, years, min_cf, max_cf, min_count) c
  GROUP BY c.year_start ORDER BY 1
$$;

-- Totaux par année de production : facteur de charge (%), production (TWh), puissance (GW).
CREATE OR REPLACE FUNCTION odre.total_per_year(filieres text[], combustibles text[], technologies text[],
  years int[], min_cf text, max_cf text, min_count text)
RETURNS TABLE (year int, cf_odre double precision, prod_odre double precision, cap_odre double precision)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT c.year_prod, 100 * sum((c.i).kwh_year) / nullif(sum((c.i).kw_installed * 8760), 0),
         sum((c.i).kwh_year) / 1e9, sum((c.i).kw_installed) / 1e6
  FROM raw.odre_cf(filieres, combustibles, technologies, years, min_cf, max_cf, min_count) c
  GROUP BY c.year_prod ORDER BY 1
$$;

-- Puissance (GW) par année d'installation, pour chaque année de production.
CREATE OR REPLACE FUNCTION odre.cap_inst_per_year(filieres text[], combustibles text[], technologies text[],
  years int[], min_cf text, max_cf text, min_count text)
RETURNS TABLE (inst_year int, prod_year int, cap_inst_odre double precision)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT c.year_start, c.year_prod, sum((c.i).kw_installed) / 1e6
  FROM raw.odre_cf(filieres, combustibles, technologies, years, min_cf, max_cf, min_count) c
  GROUP BY 1, 2 ORDER BY 1, 2
$$;

-- Carte des capacités : un point par commune et filière, noms agrégés. Colonnes lues par le layer
-- OdreCapacities (refId capacities) : kW, kWh, lon/lat en degrés.
CREATE OR REPLACE FUNCTION map.generation_capacities(year int)
RETURNS TABLE (name text, type text, combustible_code text, combustible_secondary_code text, technology_code text,
  group_count double precision, installation_count double precision, kwh_year_sliding double precision,
  kw_capacity double precision, lon double precision, lat double precision)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT left(string_agg(DISTINCT o.name, ', ') FILTER (WHERE o.name <> 'Confidentiel'), 500),
         o.filiere_code, min(o.combustible_code), min(o.combustible_secondary_code), min(o.technology_code),
         sum(o.groups), sum(o.installations), sum(o.kwh_year), sum(o.kw_installed), c.lon, c.lat
  FROM (SELECT raw.odre_snapshot_for(generation_capacities.year) AS snap) s
  JOIN raw.odre_installation o ON o.snapshot = s.snap
  JOIN raw.commune c ON c.insee = o.insee
  WHERE o.kw_installed > 0
    AND o.filiere_code IN ('MARIN', 'AUTRE', 'STOCK', 'HYDLQ', 'NUCLE', 'BIOEN', 'THERM', 'GEOTH', 'EOLIE', 'SOLAI')
  GROUP BY o.insee, o.filiere_code, c.lon, c.lat
$$;

RESET ROLE;

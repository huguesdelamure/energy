-- Compatibilité avec l'interpolation Grafana, constatée en navigateur le 2026-11-17 :
-- une variable à choix multiple arrive TOUJOURS en texte quoté ('2024','2023'), donc ARRAY[$years]
-- est un text[]. Variantes text[] des fonctions qui prennent des années ; elles appellent la version int[].
-- Idempotent. À exécuter en postgres.
SET ROLE energy;

CREATE OR REPLACE FUNCTION raw.int_array(a text[]) RETURNS int[] LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(array_agg(x::int), '{}') FROM unnest(a) x WHERE x ~ '^\s*-?\d+\s*$'
$$;

CREATE OR REPLACE FUNCTION entsoe.generation_cumsum_per_day_for_year(countries text[], production_types text[],
  years text[], t_from timestamptz, t_to timestamptz)
RETURNS TABLE ("time" timestamptz, metric text, kwh double precision, flh double precision)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT * FROM entsoe.generation_cumsum_per_day_for_year(countries, production_types, raw.int_array(years), t_from, t_to)
$$;

CREATE OR REPLACE FUNCTION entsoe.capacities_per_countries_prod_types_years(countries text[], production_types text[], years text[])
RETURNS TABLE (country text, production_type text, year int, capacity double precision)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT * FROM entsoe.capacities_per_countries_prod_types_years(countries, production_types, raw.int_array(years))
$$;

CREATE OR REPLACE FUNCTION entsoe.cumulative_negative_day_ahead_prices(zones text[], years text[], cnt_type text,
  t_from timestamptz, t_to timestamptz)
RETURNS TABLE ("time" timestamptz, metric text, value double precision) LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
  SELECT * FROM entsoe.cumulative_negative_day_ahead_prices(zones, raw.int_array(years), cnt_type, t_from, t_to)
$$;

CREATE OR REPLACE FUNCTION odre.data_per_installation_year(filieres text[], combustibles text[], technologies text[],
  years text[], min_cf text, max_cf text, min_count text)
RETURNS TABLE (year_start int, cf_inst double precision, nom_installation text, nb_groupes double precision, nb_installations double precision, energie_annuelle_glissante_injectee double precision, puis_max_installee double precision, puis_max_rac double precision, commune text, departement text, region text, regime text, date_mise_en_service date, year_prod int)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT * FROM odre.data_per_installation_year(filieres, combustibles, technologies, raw.int_array(years), min_cf, max_cf, min_count)
$$;

CREATE OR REPLACE FUNCTION odre.capacity_factor_per_installation_year(filieres text[], combustibles text[], technologies text[],
  years text[], min_cf text, max_cf text, min_count text)
RETURNS TABLE ("time" timestamptz, "ODRE average" double precision)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT * FROM odre.capacity_factor_per_installation_year(filieres, combustibles, technologies, raw.int_array(years), min_cf, max_cf, min_count)
$$;

CREATE OR REPLACE FUNCTION odre.total_per_year(filieres text[], combustibles text[], technologies text[],
  years text[], min_cf text, max_cf text, min_count text)
RETURNS TABLE (year int, cf_odre double precision, prod_odre double precision, cap_odre double precision)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT * FROM odre.total_per_year(filieres, combustibles, technologies, raw.int_array(years), min_cf, max_cf, min_count)
$$;

CREATE OR REPLACE FUNCTION odre.cap_inst_per_year(filieres text[], combustibles text[], technologies text[],
  years text[], min_cf text, max_cf text, min_count text)
RETURNS TABLE (inst_year int, prod_year int, cap_inst_odre double precision)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT * FROM odre.cap_inst_per_year(filieres, combustibles, technologies, raw.int_array(years), min_cf, max_cf, min_count)
$$;

RESET ROLE;

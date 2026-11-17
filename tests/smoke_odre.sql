\set ON_ERROR_STOP 1
\pset pager off
\timing on
SET statement_timeout = '30s';
SET ROLE grafana_ro;
\echo == total_per_year (onshore wind)
SELECT year, round(cf_odre::numeric,1) cf_pct, round(prod_odre::numeric,1) twh, round(cap_odre::numeric,1) gw FROM odre.total_per_year(ARRAY['EOLIE'], ARRAY[''], ARRAY['TERRE'], ARRAY[2025,2024,2023,2022,2021,2020,2019,2018,2017], '', '', '10');
\echo == cf per installation year (2017-2023)
SELECT extract(year FROM time)::int y, round("ODRE average"::numeric,3) FROM odre.capacity_factor_per_installation_year(ARRAY['EOLIE'], ARRAY[''], ARRAY['TERRE'], ARRAY[2023,2022,2021,2020,2019,2018,2017], '0.01', '0.5', '10') WHERE extract(year FROM time) >= 2015;
\echo == data rows / cap_inst
SELECT count(*) FROM odre.data_per_installation_year(ARRAY['EOLIE'], ARRAY[''], ARRAY['TERRE'], ARRAY[2023], '0.01', '0.5', '10');
SELECT * FROM odre.cap_inst_per_year(ARRAY['EOLIE'], ARRAY[''], ARRAY['TERRE'], ARRAY[2023], '', '', '10') WHERE inst_year >= 2020;
\echo == map
SELECT type, count(*), round(sum(kw_capacity)/1e6) gw FROM map.generation_capacities(2024) GROUP BY 1 ORDER BY 3 DESC;

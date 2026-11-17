\set ON_ERROR_STOP 0
\pset pager off
SET statement_timeout = '10s';
SET ROLE grafana_ro;
select count(*) odre_total from odre.total_per_year(ARRAY['EOLIE'],ARRAY[''], ARRAY['TERRE'], ARRAY['2022'], '0.01', '0.5', '10');
select count(*) odre_data from odre.data_per_installation_year(ARRAY['EOLIE'],ARRAY[''], ARRAY['TERRE'], ARRAY['2022'], '0.01', '0.5', '10');
select count(*) odre_cf from odre.capacity_factor_per_installation_year(ARRAY['EOLIE'],ARRAY[''], ARRAY['TERRE'], ARRAY['2022'], '0.01', '0.5', '10');
select count(*) odre_cap from odre.cap_inst_per_year(ARRAY['EOLIE'],ARRAY[''], ARRAY['TERRE'], ARRAY['2022'], '0.01', '0.5', '10');
select count(*) mosaic from ember.production_intensity_per_time_area_config('year', 'worlds_countries', '2022', 'Oberschelp2019_Jordaans2022_UNECE2022_IPCC2014_Ember');
select count(*) waterfall from ember.get_waterfall('gen', 'Europe', 'month', '2022-01', '2023-01-01', '11 mons');
select count(*) dur from ember.get_duration('Europe', 'month', '2022-01', '2023-01-01');
select count(*) cumsum from entsoe.generation_cumsum_per_day_for_year(ARRAY['DE','FR','ES'], ARRAY['solar'], ARRAY['2024','2023'], now(), now());
select count(*) caps from entsoe.capacities_per_countries_prod_types_years(ARRAY['DE','FR','ES'], ARRAY['solar'], ARRAY['2024','2023']);
select count(*) neg from entsoe.cumulative_negative_day_ahead_prices(ARRAY['FR'], ARRAY['2024'], 'inf_0', now(), now());
select count(*) corr from entsoe.correlatogram('cty', ARRAY['DE','FR'], ARRAY['solar','total']::production_type[], '1 hour', now() - interval '1 day', now());
select count(*) units_type from rte.generation_per_units_of_production_type('nuclear', now() - interval '1 day', now());
select count(DISTINCT name) reacteurs, count(*) FILTER (WHERE name = 'All') somme from rte.generation_per_units_nuclear(now() - interval '1 day', now());
select * from rte.on_off_share_nuclear(now() - interval '1 day', now());
select round(max("availability capacity")) parc_dispo_mw from rte.availability_nuclear(now() - interval '1 day', now());

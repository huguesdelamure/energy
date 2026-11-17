\set ON_ERROR_STOP 1
\pset pager off
SET ROLE grafana_ro;
\echo == dates Europe yearly
SELECT * FROM ember.get_date_from_period_region('year', 'Europe') LIMIT 3;
\echo == mosaic Europe 2024 IPCC vs fallback
SELECT round(production::numeric,1) twh, round(intensity::numeric) g, area_name, region_name FROM ember.production_intensity_per_time_area_config('year', 'Europe', '2024-01-01', 'IPCC2014_Ember') WHERE area_name IN ('France','Germany','Poland');
SELECT round(production::numeric,1) twh, round(intensity::numeric) g, area_name FROM ember.production_intensity_per_time_area_config('year', 'Europe', '2024-01-01', 'UNECE2022_IPCC2014_Ember') WHERE area_name IN ('France','Germany','Poland');
SELECT count(*) FROM ember.production_intensity_per_time_area_config('month', 'worlds_regions', '2026-06-01', 'IPCC2014_Ember');
\echo == factors
SELECT * FROM ember.emission_factors('IPCC2014_Ember');
\echo == waterfall France 2023 vs 2024
SELECT * FROM ember.get_from_date('France', 'year') LIMIT 2;
SELECT * FROM ember.get_duration('France', 'year', '2023-01-01', '2024-01-01');
SELECT round(y::numeric,2) y, x FROM ember.get_waterfall('gen', 'France', 'year', '2023-01-01', '2024-01-01', '1 year');
SELECT round(sum(y)::numeric,3) AS closure FROM ember.get_waterfall('gen', 'France', 'year', '2023-01-01', '2024-01-01', '1 year');
SELECT * FROM ember.get_duration('France', 'month', '2025-01-01', '2026-01-01') LIMIT 3;

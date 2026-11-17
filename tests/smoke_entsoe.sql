\set ON_ERROR_STOP 1
\pset pager off
BEGIN;
-- 10 jours synthétiques FR/DE, 15 min pour la production, 60 min pour le reste
INSERT INTO raw.generation (time, domain_id, ptype, dur, gen)
SELECT t, a.domain_id, p, 15, 1000 + 500*sin(extract(epoch FROM t)/43200) + random()*100
FROM generate_series('2024-06-01'::timestamptz, '2024-06-11'::timestamptz - interval '15 min', '15 min') t,
     raw.area a, unnest(ARRAY['nuclear','solar','wind_onshore']::production_type[]) p
WHERE a.area_type = 'cty' AND a.code IN ('FR','DE');
INSERT INTO raw.load (time, domain_id, dur, value)
SELECT t, a.domain_id, 60, 4000 + 800*sin(extract(epoch FROM t)/43200)
FROM generate_series('2024-06-01'::timestamptz, '2024-06-11'::timestamptz - interval '1 hour', '1 hour') t, raw.area a
WHERE a.area_type = 'cty' AND a.code IN ('FR','DE');
INSERT INTO raw.day_ahead_price (time, domain_id, dur, price)
SELECT t, a.domain_id, 60, 50 + 60*sin(extract(epoch FROM t)/43200)
FROM generate_series('2024-06-01'::timestamptz, '2024-06-11'::timestamptz - interval '1 hour', '1 hour') t, raw.area a
WHERE a.area_type = 'bzn' AND a.code IN ('FR','DE_LU');
INSERT INTO raw.installed_capacity VALUES (2024, (SELECT domain_id FROM raw.area WHERE code='FR' AND area_type='cty'), 'nuclear', 61000);
INSERT INTO raw.unit (eic, name, domain_id, country, ptype) VALUES ('TESTUNIT1', 'Unit, A+B', (SELECT domain_id FROM raw.area WHERE code='FR' AND area_type='cta'), 'FR', 'nuclear');
INSERT INTO raw.generation_unit SELECT t, (SELECT id FROM raw.unit WHERE eic='TESTUNIT1'), 60, 900 + random()*400
FROM generate_series('2024-06-01'::timestamptz, '2024-06-10'::timestamptz, '1 hour') t;

SET ROLE grafana_ro;
\echo == units
SELECT * FROM entsoe.units_of_contries_with_production_types(ARRAY['FR'], ARRAY['nuclear']);
\echo == generation_per_units
SELECT count(*), min(value)::int, max(value)::int FROM entsoe.generation_per_units(ARRAY['TESTUNIT1'], '2024-06-01', '2024-06-11');
\echo == cum_histo_per_unit
SELECT metric, count(*), round(min(share)::numeric,3), round(max(share)::numeric,3) FROM entsoe.cum_histo_per_unit(ARRAY['TESTUNIT1'], '2024-06-01', '2024-06-11', 800, 50, true, 1.2) GROUP BY 1 ORDER BY 1;
\echo == generation_per_countries
SELECT metric, count(*) FROM entsoe.generation_per_countries(ARRAY['FR','DE'], ARRAY['nuclear','solar'], '2024-06-01', '2024-06-11') GROUP BY 1 ORDER BY 1;
\echo == heatmap
SELECT count(*), count(DISTINCT metric), min(time), max(time) FROM entsoe.generation_heatmap(ARRAY['FR'], ARRAY['nuclear'], '2024-06-01', '2024-06-11', 1.2);
\echo == cumsum
SELECT metric, count(*), round(max(kwh)::numeric), round(max(flh)::numeric,1), min(time) FROM entsoe.generation_cumsum_per_day_for_year(ARRAY['FR'], ARRAY['nuclear'], ARRAY[2024], '2026-01-01', '2026-12-31') GROUP BY 1;
\echo == capacities
SELECT * FROM entsoe.capacities_per_countries_prod_types_years(ARRAY['FR'], ARRAY['nuclear'], ARRAY[2024]);
\echo == cum_histo_per_countries
SELECT metric, count(*), round(min(share)::numeric,3), round(max(share)::numeric,3) FROM entsoe.cum_histo_per_countries_prod_types(ARRAY['FR','DE'], ARRAY['nuclear','solar'], '2024-06-01', '2024-06-11', 800, 100, true) GROUP BY 1 ORDER BY 1;
SELECT count(*) AS null_country FROM entsoe.cum_histo_per_countries_prod_types(ARRAY['null'], ARRAY['nuclear'], '2024-06-01', '2024-06-11', 800, 100, true);
\echo == day_ahead_prices
SELECT metric, count(*) FROM entsoe.day_ahead_prices('EUR', '2024-06-01', '2024-06-11') GROUP BY 1;
SELECT metric, count(*) FROM entsoe.day_ahead_prices('EUR', '2024-01-01', '2024-12-31') GROUP BY 1;
\echo == negative hours
SELECT metric, max(value), count(*) FROM entsoe.cumulative_negative_day_ahead_prices(ARRAY['FR','DE_LU'], ARRAY[2024], 'inf_0', '2026-01-01', '2026-12-31') GROUP BY 1;
\echo == capture
SELECT metric, count(*), round(avg(price)::numeric,1), round(avg(rate)::numeric,3) FROM entsoe.capture_price(ARRAY['FR'], ARRAY['solar']::production_type[], ARRAY['base','demand'], ARRAY[]::production_type[], '2024-06-01', '2024-06-11', '1 day') GROUP BY 1;
\echo == correlatogram
SELECT * FROM entsoe.correlatogram('cty', ARRAY['FR','DE'], ARRAY['nuclear','solar','total']::production_type[], '1 hour', '2024-06-01', '2024-06-11') LIMIT 5;
SELECT count(*) FROM entsoe.map_code_per_type('bzn');
\echo == isolation
SELECT count(*) FROM raw.area;
ROLLBACK;

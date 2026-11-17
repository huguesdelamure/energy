\set ON_ERROR_STOP 1
\pset pager off
\timing on
SET statement_timeout = '10s';
SET ROLE grafana_ro;
\echo == variables
SELECT * FROM rte.production_types_with_units();
SELECT * FROM rte.unavailability_update_id_date('cre', 'nuclear') LIMIT 3;
SELECT count(*) FROM rte.nuclear_name_eic_code();
\echo == overview (dernières 24 h)
SELECT round("availability capacity") mw, round("availability share"::numeric,3) share FROM rte.availability_nuclear(now() - interval '1 day', now()) ORDER BY 1 DESC LIMIT 1;
SELECT count(*) pts, round(max(production)) max_mw, round(max("charge factor")::numeric,3) cf FROM rte.production_charge_factor_nuclear(now() - interval '2 days', now());
SELECT * FROM rte.on_off_share_nuclear(now() - interval '2 days', now());
SELECT count(DISTINCT metric) series, count(*) FILTER (WHERE metric = 'All') all_pts FROM rte.generation_per_units_nuclear(now() - interval '2 days', now());
\echo == disponibilité future (6 mois), état connu aujourd hui vs il y a 3 mois
SELECT count(*) steps, round(min(value)) min_mw, round(max(value)) max_mw FROM rte.availability_sum_raw_multi(ARRAY[(current_date - date '2015-01-01')::int], now() - interval '1 month', now() + interval '6 months');
SELECT metric, count(*) FROM rte.availability_sum_raw_multi(ARRAY[(current_date - date '2015-01-01')::int, (current_date - 90 - date '2015-01-01')::int], now(), now() + interval '6 months') GROUP BY 1;
\echo == frise par réacteur
SELECT count(DISTINCT metric) reacteurs, count(*) pts, round(min(value)::numeric,2), round(max(value)::numeric,2) FROM rte.availability_per_unit_capacity_factor_raw((current_date - date '2015-01-01')::int, now() - interval '1 month', now() + interval '6 months');
\echo == unité
SELECT __text, __value FROM rte.nuclear_name_eic_code() LIMIT 1 \gset u_
SELECT count(*) FROM rte.generation_per_unit(:'u___value', now() - interval '7 days', now());
SELECT * FROM rte.availability_per_unit_raw(:'u___value', (current_date - date '2015-01-01')::int, now() - interval '3 months', now() + interval '6 months') LIMIT 4;
SELECT count(*) FROM rte.unavailabilities_per_unit(:'u___value', now() - interval '3 months', now() + interval '6 months');
SELECT count(*) FROM rte.unavailabilities_per_production_type('nuclear', now() - interval '1 month', now());
\echo == variations, annuel, origines
SELECT count(*) FROM rte.generation_per_units_delta(now() - interval '1 day', now(), 'nuclear');
SELECT metric, count(*) FROM rte.availability_sum_raw_yearly_repeat((current_date - date '2015-01-01')::int, date_trunc('year', now()), date_trunc('year', now()) + interval '1 year') GROUP BY 1 ORDER BY 1;
SELECT count(*) FROM rte.availability_sum_raw_multi_origin(ARRAY['rte-2022-11-15'], 'nuclear', now(), now());

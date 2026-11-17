\set ON_ERROR_STOP 1
\pset pager off
BEGIN;
INSERT INTO raw.flow (time, kind, from_id, to_id, dur, value)
SELECT t, 'physical'::raw.flow_kind, f.id, d.id, 60, CASE WHEN f.eic < d.eic THEN 1000 ELSE 300 END
FROM generate_series('2024-06-01'::timestamptz, '2024-06-01 05:00'::timestamptz, '1 hour') t,
     raw.domain f, raw.domain d
WHERE f.eic = '10YFR-RTE------C' AND d.eic IN ('10YBE----------2', '10YES-REE------0')
UNION ALL
SELECT t, 'physical'::raw.flow_kind, d.id, f.id, 60, CASE WHEN d.eic < f.eic THEN 1000 ELSE 300 END
FROM generate_series('2024-06-01'::timestamptz, '2024-06-01 05:00'::timestamptz, '1 hour') t,
     raw.domain f, raw.domain d
WHERE f.eic = '10YFR-RTE------C' AND d.eic IN ('10YBE----------2', '10YES-REE------0');
INSERT INTO raw.day_ahead_price (time, domain_id, dur, price)
SELECT t, a.domain_id, 60, 42.123 FROM generate_series('2024-06-01'::timestamptz, '2024-06-01 03:00'::timestamptz, '1 hour') t, raw.area a
WHERE a.area_type = 'bzn' AND a.code IN ('FR', 'NO2NSL');
SET ROLE grafana_ro;
\echo == nodes
SELECT count(*), min(code) FROM entsoe.area_map_code_eic('bzn');
\echo == edges (non net)
SELECT * FROM entsoe.flow_graph_edges_eic('bzn', '2024-06-01', '2024-06-01 02:00', INTERVAL '1h', 'physical', 'false');
\echo == edges (net)
SELECT * FROM entsoe.flow_graph_edges_eic('cty', '2024-06-01', '2024-06-01 01:00', INTERVAL '1h', 'physical', 'true');
\echo == net
SELECT * FROM entsoe.flow_net_interpolated('bzn', '2024-06-01', '2024-06-01 01:00', INTERVAL '1h', 'physical');
\echo == prices wide
SELECT "time", "FR", "NO2NSL", "DE_LU" FROM entsoe.day_ahead_prices('EUR', '2024-06-01', '2024-06-02');
ROLLBACK;

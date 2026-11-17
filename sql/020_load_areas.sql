-- Charge sql/areas.csv (passé sur stdin via \copy ... from pstdin). Idempotent.
SET ROLE energy;
CREATE TEMP TABLE a (code text, area_type text, eic text, country text, name text);
\copy a from pstdin with (format csv, header true)
INSERT INTO raw.domain (eic, name)
  SELECT DISTINCT ON (eic) eic, name FROM a ORDER BY eic, area_type DESC
ON CONFLICT (eic) DO NOTHING;
INSERT INTO raw.area (code, area_type, domain_id, country)
  SELECT a.code, a.area_type, d.id, a.country FROM a JOIN raw.domain d USING (eic)
ON CONFLICT (code, area_type) DO UPDATE SET domain_id = EXCLUDED.domain_id, country = EXCLUDED.country;
SELECT area_type, count(*) FROM raw.area GROUP BY 1 ORDER BY 1;
SELECT count(*) AS domains FROM raw.domain;

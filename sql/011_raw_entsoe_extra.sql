-- Compléments ENTSO-E : prévisions éolien/solaire (A69) et frontières pour les flux. Idempotent.
SET ROLE energy;

-- A69 : prévision day-ahead éolien et solaire (MW).
CREATE TABLE IF NOT EXISTS raw.generation_forecast (
  time      timestamptz NOT NULL,
  domain_id smallint NOT NULL REFERENCES raw.domain,
  ptype     production_type NOT NULL,
  dur       smallint NOT NULL,
  value     real NOT NULL,
  PRIMARY KEY (domain_id, ptype, time)
);
SELECT create_hypertable('raw.generation_forecast', by_range('time', INTERVAL '1 year'), if_not_exists => true);

-- Frontières interrogées pour A11/A09, dans les deux sens, par type de zone.
CREATE TABLE IF NOT EXISTS raw.border (
  area_type text NOT NULL CHECK (area_type IN ('cty','bzn','cta')),
  from_id   smallint NOT NULL REFERENCES raw.domain,
  to_id     smallint NOT NULL REFERENCES raw.domain,
  PRIMARY KEY (area_type, from_id, to_id)
);

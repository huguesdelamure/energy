-- Tables brutes ENTSO-E. Propriétaire : energy. Jamais lisibles par grafana_ro :
-- Grafana passe uniquement par les fonctions SECURITY DEFINER des schémas publiés.
-- Idempotent : rejouable. À exécuter en postgres.

GRANT USAGE, CREATE ON SCHEMA public TO energy;
SET ROLE energy;

-- Le cast ::production_type[] est écrit en dur dans les dashboards d'origine,
-- le type doit donc être résolu via le search_path par défaut (public).
DO $$ BEGIN
  CREATE TYPE public.production_type AS ENUM (
    'biomass', 'fossil_brown_coal_lignite', 'fossil_coal_derived_gas', 'fossil_gas',
    'fossil_hard_coal', 'fossil_oil', 'fossil_oil_shale', 'fossil_peat', 'geothermal',
    'hydro_pumped_storage', 'hydro_run_of_river_and_poundage', 'hydro_water_reservoir',
    'marine', 'nuclear', 'other', 'other_renewable', 'solar', 'waste',
    'wind_offshore', 'wind_onshore', 'energy_storage', 'total');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Code PSR ENTSO-E (B01..B25) -> production_type
CREATE TABLE IF NOT EXISTS raw.psr_type (
  psr   text PRIMARY KEY,
  ptype production_type NOT NULL UNIQUE
);
INSERT INTO raw.psr_type VALUES
  ('B01','biomass'), ('B02','fossil_brown_coal_lignite'), ('B03','fossil_coal_derived_gas'),
  ('B04','fossil_gas'), ('B05','fossil_hard_coal'), ('B06','fossil_oil'), ('B07','fossil_oil_shale'),
  ('B08','fossil_peat'), ('B09','geothermal'), ('B10','hydro_pumped_storage'),
  ('B11','hydro_run_of_river_and_poundage'), ('B12','hydro_water_reservoir'), ('B13','marine'),
  ('B14','nuclear'), ('B15','other_renewable'), ('B16','solar'), ('B17','waste'),
  ('B18','wind_offshore'), ('B19','wind_onshore'), ('B20','other'), ('B25','energy_storage')
ON CONFLICT DO NOTHING;

-- Domaine ENTSO-E = un code EIC. Toutes les séries sont rattachées au domaine,
-- pour ne pas dupliquer un EIC qui est à la fois pays, zone de prix et zone de réglage (FR, BE...).
CREATE TABLE IF NOT EXISTS raw.domain (
  id   smallserial PRIMARY KEY,
  eic  text NOT NULL UNIQUE,
  name text NOT NULL
);

-- Zone telle qu'affichée dans les dashboards : (code, type) -> domaine.
CREATE TABLE IF NOT EXISTS raw.area (
  code      text NOT NULL,             -- FR, DE_LU, IT-NORTH, SE3...
  area_type text NOT NULL CHECK (area_type IN ('cty','bzn','cta')),
  domain_id smallint NOT NULL REFERENCES raw.domain,
  country   text NOT NULL,             -- code pays (cty) de rattachement
  PRIMARY KEY (code, area_type)
);

-- A75 : production réalisée par filière. dur = résolution en minutes (15, 30, 60).
CREATE TABLE IF NOT EXISTS raw.generation (
  time      timestamptz NOT NULL,
  domain_id smallint NOT NULL REFERENCES raw.domain,
  ptype     production_type NOT NULL,
  dur       smallint NOT NULL,
  gen       real,                      -- MW produits
  cons      real,                      -- MW consommés (pompage, stockage)
  PRIMARY KEY (domain_id, ptype, time)
);
SELECT create_hypertable('raw.generation', by_range('time', INTERVAL '3 months'), if_not_exists => true);

-- Unités de production, découvertes au fil de la collecte A73.
CREATE TABLE IF NOT EXISTS raw.unit (
  id        serial PRIMARY KEY,
  eic       text NOT NULL UNIQUE,
  name      text NOT NULL,
  domain_id smallint REFERENCES raw.domain,  -- domaine interrogé (zone de réglage)
  country   text,                            -- code pays, pour les filtres des dashboards
  ptype     production_type,
  capacity  real                             -- MW installés si connus
);

-- A73 : production réalisée par unité.
CREATE TABLE IF NOT EXISTS raw.generation_unit (
  time    timestamptz NOT NULL,
  unit_id int NOT NULL REFERENCES raw.unit,
  dur     smallint NOT NULL,
  gen     real,
  PRIMARY KEY (unit_id, time)
);
SELECT create_hypertable('raw.generation_unit', by_range('time', INTERVAL '3 months'), if_not_exists => true);

-- A44 : prix day-ahead (EUR/MWh). 60 min puis 15 min depuis le 01/10/2025 (SDAC) ;
-- les deux résolutions peuvent coexister sur la période de bascule.
CREATE TABLE IF NOT EXISTS raw.day_ahead_price (
  time      timestamptz NOT NULL,
  domain_id smallint NOT NULL REFERENCES raw.domain,
  dur       smallint NOT NULL,
  price     real NOT NULL,
  PRIMARY KEY (domain_id, dur, time)
);
SELECT create_hypertable('raw.day_ahead_price', by_range('time', INTERVAL '1 year'), if_not_exists => true);

-- A65 : consommation réalisée (MW).
CREATE TABLE IF NOT EXISTS raw.load (
  time      timestamptz NOT NULL,
  domain_id smallint NOT NULL REFERENCES raw.domain,
  dur       smallint NOT NULL,
  value     real NOT NULL,
  PRIMARY KEY (domain_id, time)
);
SELECT create_hypertable('raw.load', by_range('time', INTERVAL '1 year'), if_not_exists => true);

-- A11 flux physiques, A09 échanges commerciaux totaux, A09 day-ahead.
DO $$ BEGIN
  CREATE TYPE raw.flow_kind AS ENUM ('physical', 'commercial', 'commercial_day_ahead');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS raw.flow (
  time    timestamptz NOT NULL,
  kind    raw.flow_kind NOT NULL,
  from_id smallint NOT NULL REFERENCES raw.domain,
  to_id   smallint NOT NULL REFERENCES raw.domain,
  dur     smallint NOT NULL,
  value   real NOT NULL,               -- MW de from vers to
  PRIMARY KEY (kind, from_id, to_id, time)
);
SELECT create_hypertable('raw.flow', by_range('time', INTERVAL '1 year'), if_not_exists => true);

-- A68 : capacité installée par filière, publiée pour l'année.
CREATE TABLE IF NOT EXISTS raw.installed_capacity (
  year      smallint NOT NULL,
  domain_id smallint NOT NULL REFERENCES raw.domain,
  ptype     production_type NOT NULL,
  value     real NOT NULL,             -- MW
  PRIMARY KEY (domain_id, ptype, year)
);

-- Journal de collecte : backfill reprenable, collecte auditable.
CREATE TABLE IF NOT EXISTS raw.fetch_log (
  dataset    text NOT NULL,            -- A75, A73, A44, A65, A11, A09, A09DA, A68
  key        text NOT NULL,            -- EIC, ou "EIC_FROM>EIC_TO" pour les flux
  period     tstzrange NOT NULL,
  fetched_at timestamptz NOT NULL DEFAULT now(),
  rows       int,
  status     text NOT NULL,            -- ok, empty, error
  detail     text,
  PRIMARY KEY (dataset, key, period)
);

RESET ROLE;
GRANT USAGE ON SCHEMA public TO grafana_ro;

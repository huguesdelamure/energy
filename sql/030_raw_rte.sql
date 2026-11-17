-- Données RTE (API Data RTE) : production par unité et indisponibilités REMIT avec toutes leurs versions.
-- Idempotent. À exécuter en postgres.
SET ROLE energy;

CREATE TABLE IF NOT EXISTS raw.rte_unit (
  id              serial PRIMARY KEY,
  eic             text NOT NULL UNIQUE,
  name            text NOT NULL,
  production_type text,            -- NUCLEAR, FOSSIL_GAS, HYDRO_PUMPED_STORAGE... (Actual Generation)
  installed_capacity real          -- MW, dernière valeur vue dans les messages REMIT
);

-- Actual Generation per unit : production horaire (MW).
CREATE TABLE IF NOT EXISTS raw.rte_generation (
  time    timestamptz NOT NULL,      -- début du pas
  unit_id int NOT NULL REFERENCES raw.rte_unit,
  value   real,
  updated timestamptz,
  PRIMARY KEY (unit_id, time)
);
SELECT create_hypertable('raw.rte_generation', by_range('time', INTERVAL '6 months'), if_not_exists => true);

-- Messages REMIT d'indisponibilité : une ligne par version (message_id = identifiant + version).
CREATE TABLE IF NOT EXISTS raw.rte_unavailability (
  message_id   text PRIMARY KEY,
  identifier   text NOT NULL,
  version      int NOT NULL,
  unit_eic     text NOT NULL,
  unit_name    text,
  asset_type   text,                 -- GENERATION_UNIT, PRODUCTION_UNIT
  fuel_type    text,                 -- NUCLEAR, ...
  installed_capacity real,
  status       text,                 -- ACTIVE, INACTIVE, DISMISSED
  type         text,                 -- PLANNED, FORCED
  reason       text,
  remarks      text,
  participant  text,
  creation     timestamptz,
  publication  timestamptz NOT NULL,
  start_date   timestamptz,
  end_date     timestamptz
);
CREATE INDEX IF NOT EXISTS rte_unav_ident ON raw.rte_unavailability (identifier, publication DESC);
CREATE INDEX IF NOT EXISTS rte_unav_unit ON raw.rte_unavailability (unit_eic, publication);
CREATE INDEX IF NOT EXISTS rte_unav_fuel ON raw.rte_unavailability (fuel_type, publication);

-- Tranches de puissance d'une version (une version peut annoncer plusieurs paliers).
CREATE TABLE IF NOT EXISTS raw.rte_unavailability_value (
  message_id  text NOT NULL REFERENCES raw.rte_unavailability ON DELETE CASCADE,
  start_date  timestamptz NOT NULL,
  end_date    timestamptz NOT NULL,
  available   real,
  unavailable real,
  PRIMARY KEY (message_id, start_date)
);

-- Données Ember (yearly + monthly electricity data), rechargées en entier à chaque collecte.
-- Idempotent. À exécuter en postgres.
SET ROLE energy;

CREATE TABLE IF NOT EXISTS raw.ember (
  period       text NOT NULL CHECK (period IN ('year', 'month')),
  date         date NOT NULL,              -- 1er janvier (year) ou 1er du mois (month)
  area         text NOT NULL,
  iso3         text,
  area_type    text NOT NULL,              -- 'Country or economy' | 'Region'
  source       text NOT NULL,              -- Coal, Gas, ..., Net imports, Demand, Total generation
  aggregated   boolean NOT NULL,
  gen_twh      double precision,
  capacity_gw  double precision,
  emissions_mt double precision,
  intensity    double precision,           -- gCO2e/kWh publié par Ember
  continent    text,
  ember_region text,                       -- Africa, Asia, Europe, Latin America and Caribbean, Middle East, North America, Oceania
  eu boolean, oecd boolean, g20 boolean, g7 boolean,
  PRIMARY KEY (period, date, area, source)
);

-- Facteurs d'émission par jeu de configuration (gCO2e/kWh, cycle de vie).
-- country NULL = valeur par défaut de la filière pour ce jeu. Filière absente du jeu : intensité Ember.
CREATE TABLE IF NOT EXISTS raw.emission_factor (
  config    text NOT NULL,
  source    text NOT NULL,                 -- libellé de filière Ember
  country   text,                          -- code ISO3, NULL = tous pays
  factor    double precision NOT NULL,
  reference text NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS emission_factor_key ON raw.emission_factor (config, source, coalesce(country, ''));

-- IPCC 2014 (AR5 WGIII Annex III, médianes cycle de vie). Other fossil : pas de valeur IPCC, intensité Ember.
INSERT INTO raw.emission_factor (config, source, country, factor, reference) VALUES
  ('IPCC2014_Ember', 'Coal', NULL, 820, 'IPCC 2014'),
  ('IPCC2014_Ember', 'Gas', NULL, 490, 'IPCC 2014'),
  ('IPCC2014_Ember', 'Bioenergy', NULL, 230, 'IPCC 2014'),
  ('IPCC2014_Ember', 'Solar', NULL, 48, 'IPCC 2014'),
  ('IPCC2014_Ember', 'Wind', NULL, 11, 'IPCC 2014'),
  ('IPCC2014_Ember', 'Hydro', NULL, 24, 'IPCC 2014'),
  ('IPCC2014_Ember', 'Nuclear', NULL, 12, 'IPCC 2014'),
  ('IPCC2014_Ember', 'Other renewables', NULL, 38, 'IPCC 2014')
ON CONFLICT DO NOTHING;

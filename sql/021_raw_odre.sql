-- Registre national des installations de production et de stockage (ODRÉ), par instantané. Idempotent.
SET ROLE energy;

CREATE TABLE IF NOT EXISTS raw.odre_installation (
  snapshot   text NOT NULL,          -- 'JJMMAA' (registre au 31/12) ou 'current'
  year       smallint,               -- année de production couverte par l'instantané (NULL = 12 mois glissants)
  name       text,
  eic        text,
  insee      text,                   -- commune
  commune    text,
  dep_code   text,
  departement text,
  region_code text,
  region     text,
  commissioning date,
  filiere_code text,                 -- EOLIE, SOLAI, NUCLE, HYDLQ, THERM, BIOEN, GEOTH, MARIN, STOCK, AUTRE
  filiere    text,
  combustible_code text,
  combustible_secondary_code text,
  technology_code text,              -- TERRE, MER, ...
  technology text,
  kw_installed double precision,
  kw_rac     double precision,
  groups     double precision,
  installations double precision,
  regime     text,
  kwh_year   double precision        -- énergie injectée sur l'année (ou 12 mois glissants)
);
CREATE INDEX IF NOT EXISTS odre_installation_snapshot ON raw.odre_installation (snapshot, filiere_code);

-- Centre des communes (geo.api.gouv.fr), pour placer les installations sur la carte.
CREATE TABLE IF NOT EXISTS raw.commune (
  insee text PRIMARY KEY,
  name  text,
  lon   double precision NOT NULL,
  lat   double precision NOT NULL
);

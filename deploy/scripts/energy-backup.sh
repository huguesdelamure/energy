#!/bin/sh
# Sauvegarde quotidienne de la base energy (pg_dump format custom), 7 jours gardés.
# Restauration TimescaleDB : createdb energy; psql -c 'CREATE EXTENSION timescaledb';
#   psql -c 'SELECT timescaledb_pre_restore()'; pg_restore -d energy FICHIER; psql -c 'SELECT timescaledb_post_restore()'
set -eu
DIR=/var/backups/energy
OUT="$DIR/energy-$(date +%F).dump"
pg_dump -d energy -Fc -f "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
find "$DIR" -name 'energy-*.dump' -mtime +6 -delete

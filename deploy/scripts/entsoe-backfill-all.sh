#!/bin/sh
# Rattrapage ENTSO-E complet en 3 files parallèles (3 x 120 req/min max < 400/min autorisées).
# A73 se demande jour par jour : il occupe une file à lui seul.
set -u
lane() { for d in "$@"; do systemctl start "entsoe-backfill@$d"; done; }
lane A73 &
lane A65 A75 A44 A69 &
lane A68 A11 A09 A09DA &
wait

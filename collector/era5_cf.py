#!/usr/bin/env python3
"""Rasters horaires de facteur de charge éolien et solaire (monde, 0,25°) depuis ERA5, encodés en vidéo
au format lu par le layer windCapacityFactorRaster du plugin deck.gl :
/srv/energy/static/cf/AAAA/MM/JJ/{w,s}_crf22.mp4, H.264 1440x720, 24 images (heure UTC), CRF 22,
longitude -180 -> 180 de gauche à droite, latitude 90 -> -90 de haut en bas, valeur dans la luminance.

    era5_cf.py day 2023-09-01
    era5_cf.py backfill --since 2023-09-01      (saute les jours déjà encodés)
    era5_cf.py latest                            (dernier jour publié par ERA5, J-6)
    era5_cf.py calibrate 2023-06-21              (compare au fichier de l'auteur, sans écrire)

Modèles (aide du dashboard d'origine) : éolienne Vestas V112 3 MW, moyeu 80 m, vent 100 m extrapolé
avec la rugosité ; PV panneau CSi (Huld 2010), ciel clair Reindl 1990, orientation optimale en latitude.
Clé Copernicus CDS : /etc/energy/cdsapirc (url + key), passée via CDSAPI_RC.
"""

import argparse
import logging
import os
import subprocess
import sys
from datetime import UTC, date, datetime, timedelta
from pathlib import Path

import atlite
import imageio_ffmpeg
import numpy as np

OUT = Path("/srv/energy/static/cf")
WORK = Path("/var/lib/energy/era5")
os.environ.setdefault("CDSAPI_RC", "/etc/energy/cdsapirc")

# Encodage de la valeur : Y = OFFSET + SCALE * cf, 0 quand cf <= 0 (nuit, calme).
# Valeurs par défaut à confirmer par "calibrate" sur un jour publié par l'auteur.
OFFSET, SCALE = 16.0, 219.0

log = logging.getLogger("era5")


def capacity_factors(day):
    """Renvoie (vent, solaire) : tableaux (24, 721, 1440) float32, latitude décroissante, longitude -180..180."""
    WORK.mkdir(parents=True, exist_ok=True)
    nc = WORK / f"{day}.nc"
    cutout = atlite.Cutout(path=nc, module="era5", x=slice(-180, 180), y=slice(-90, 90),
                           time=str(day), dx=0.25, dy=0.25)
    try:
        cutout.prepare(features=["wind", "influx", "temperature"], monthly_requests=False)
        wind = cutout.wind(turbine="Vestas_V112_3MW", capacity_factor_timeseries=True)
        pv = cutout.pv(panel="CSi", orientation="latitude_optimal", capacity_factor_timeseries=True)
        out = []
        for da in (wind, pv):
            da = da.transpose("time", "y", "x").sortby("y", ascending=False).sortby("x")
            out.append(np.nan_to_num(da.values.astype(np.float32), nan=0.0))
        return out
    finally:
        nc.unlink(missing_ok=True)


def to_frames(cf):
    """(24, 721, 1440) -> (24, 720, 1440) uint8 : on retire la ligne du pôle Sud pour 720 lignes."""
    cf = np.clip(cf[:, :720, :1440], 0, 1)
    y = np.where(cf > 0, OFFSET + SCALE * cf, 0)
    return np.round(y).astype(np.uint8)


def encode(frames, dest):
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(".tmp.mp4")
    cmd = [imageio_ffmpeg.get_ffmpeg_exe(), "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "gray",
           "-s", "1440x720", "-r", "24", "-i", "-", "-c:v", "libx264", "-preset", "slow", "-crf", "22",
           "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(tmp)]
    subprocess.run(cmd, input=frames.tobytes(), check=True)
    tmp.rename(dest)


def decode(path):
    cmd = [imageio_ffmpeg.get_ffmpeg_exe(), "-v", "error", "-i", str(path), "-f", "rawvideo", "-pix_fmt", "gray", "-"]
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.uint8).reshape(-1, 720, 1440)


def do_day(day, force=False):
    d = OUT / f"{day:%Y/%m/%d}"
    w, s = d / "w_crf22.mp4", d / "s_crf22.mp4"
    if not force and w.exists() and s.exists():
        return False
    wind, pv = capacity_factors(day)
    encode(to_frames(wind), w)
    encode(to_frames(pv), s)
    log.info("%s encodé", day)
    return True


def calibrate(day):
    """Ajuste Y_auteur = a + b * cf_calculé sur les pixels > 0 des deux rasters, sans rien écrire."""
    wind, pv = capacity_factors(day)
    for name, cf, f in (("vent", wind, "w_crf22.mp4"), ("solaire", pv, "s_crf22.mp4")):
        theirs = decode(OUT / f"{day:%Y/%m/%d}" / f).astype(np.float32)
        ours = np.clip(cf[:, :720, :1440], 0, 1)
        m = (theirs > 20) & (ours > 0.02)
        b, a = np.polyfit(ours[m], theirs[m], 1)
        r = np.corrcoef(ours[m], theirs[m])[0, 1]
        print(f"{name}: Y_auteur = {a:.1f} + {b:.1f} * cf  (r = {r:.3f}, {m.sum()} pixels)")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("day")
    d.add_argument("date", type=date.fromisoformat)
    d.add_argument("--force", action="store_true")
    b = sub.add_parser("backfill")
    b.add_argument("--since", type=date.fromisoformat, default=date(2023, 9, 1))
    sub.add_parser("latest")
    c = sub.add_parser("calibrate")
    c.add_argument("date", type=date.fromisoformat)
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s", stream=sys.stdout)

    last = datetime.now(UTC).date() - timedelta(days=6)   # ERA5T publié avec ~5 jours de retard
    if args.cmd == "day":
        do_day(args.date, args.force)
    elif args.cmd == "latest":
        do_day(last)
    elif args.cmd == "calibrate":
        calibrate(args.date)
    else:
        day = last
        while day >= args.since:   # du plus récent au plus ancien : le site se remplit par le présent
            try:
                do_day(day)
            except Exception as e:
                log.error("%s : %s", day, e)
            day -= timedelta(days=1)


if __name__ == "__main__":
    main()

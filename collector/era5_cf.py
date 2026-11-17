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

# Encodage de la valeur : Y = 255 * cf. Étalonné le 2026-11-17 sur le 2023-06-21 publié par l'auteur :
# vent Y = -0.1 + 254.4 cf (r = 0.999).
SCALE = 255.0

# Modèle PV. Défaut avant étalonnage solaire : écart de pente de 7 % avec l'auteur (r = 0.996).
PV = {"panel": "CSi", "orientation": "latitude_optimal"}
PV_CANDIDATES = {
    "CSi latitude_optimal": {"panel": "CSi", "orientation": "latitude_optimal"},
    "CSi pente 30 sud": {"panel": "CSi", "orientation": {"slope": 30.0, "azimuth": 180.0}},
    "CSi pente 35 sud": {"panel": "CSi", "orientation": {"slope": 35.0, "azimuth": 180.0}},
    "CdTe latitude_optimal": {"panel": "CdTe", "orientation": "latitude_optimal"},
    "CSi latitude_optimal clearsky enhanced": {"panel": "CSi", "orientation": "latitude_optimal", "clearsky_model": "enhanced"},
    "CSi tracking horizontal": {"panel": "CSi", "orientation": "latitude_optimal", "tracking": "horizontal"},
}

log = logging.getLogger("era5")


def grid(da):
    da = da.transpose("time", "y", "x").sortby("y", ascending=False).sortby("x")
    return np.nan_to_num(da.values.astype(np.float32), nan=0.0)


def cutout_for(day):
    WORK.mkdir(parents=True, exist_ok=True)
    cutout = atlite.Cutout(path=WORK / f"{day}.nc", module="era5", x=slice(-180, 180), y=slice(-90, 90),
                           time=str(day), dx=0.25, dy=0.25)
    cutout.prepare(features=["wind", "influx", "temperature"], monthly_requests=False)
    return cutout


def capacity_factors(day):
    """Renvoie (vent, solaire) : tableaux (24, 721, 1440) float32, latitude décroissante, longitude -180..180."""
    try:
        cutout = cutout_for(day)
        wind = grid(cutout.wind(turbine="Vestas_V112_3MW", aggregate_time=None))
        pv = grid(cutout.pv(**PV, aggregate_time=None))
        return wind, pv
    finally:
        (WORK / f"{day}.nc").unlink(missing_ok=True)


def to_frames(cf):
    """(24, 721, 1440) -> (24, 720, 1440) uint8 : on retire la ligne du pôle Sud pour 720 lignes."""
    cf = np.clip(cf[:, :720, :1440], 0, 1)
    return np.round(SCALE * cf).astype(np.uint8)


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


def fit(cf, theirs):
    ours = np.clip(cf[:, :720, :1440], 0, 1)
    m = (theirs > 20) & (ours > 0.02)
    b, a = np.polyfit(ours[m], theirs[m], 1)
    r = np.corrcoef(ours[m], theirs[m])[0, 1]
    return f"Y_auteur = {a:.1f} + {b:.1f} * cf  (r = {r:.4f}, {m.sum()} pixels)"


def calibrate(day):
    """Compare au fichier de l'auteur (pente idéale 255, ordonnée 0), sans rien écrire.
    Le cutout ERA5 est gardé dans WORK pour rejouer les candidats PV sans retélécharger."""
    cutout = cutout_for(day)
    d = OUT / f"{day:%Y/%m/%d}"
    print("vent:", fit(grid(cutout.wind(turbine="Vestas_V112_3MW", aggregate_time=None)),
                       decode(d / "w_crf22.mp4").astype(np.float32)))
    theirs = decode(d / "s_crf22.mp4").astype(np.float32)
    for name, params in PV_CANDIDATES.items():
        try:
            print(f"solaire {name}:", fit(grid(cutout.pv(**params, aggregate_time=None)), theirs), flush=True)
        except Exception as e:
            print(f"solaire {name}: erreur {e}", flush=True)


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

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SONDE l'échantillon des catalogues réels : élévation + vent sur la croix de 5 points à 2 km,
exactement la croix que `MarineWeatherService.neighbourhood` envoie à Open-Meteo.

Deux mesures, à ne pas confondre (cf. audit précédent) :
  • ÉLÉVATION → où l'épingle tombe dans le MONDE RÉEL (MNT 90 m). `elevation == 0` = eau.
  • VENT      → ce que le MODÈLE en exprime. L'étendue ne peut être non nulle que si les
                5 points tombent dans des mailles DISTINCTES.

Reprise : le cache disque permet de relancer après un 429 / épuisement de quota sans
reperdre ce qui est déjà acquis.

    python3 audit/sonde_catalogues.py elevation
    python3 audit/sonde_catalogues.py vent
"""
import json, math, os, subprocess, sys, time, urllib.parse

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ECH = os.path.join(BASE, "audit/echantillon_catalogues.json")
CACHE_ELEV = os.path.join(BASE, "audit/cache_elevation_catalogues.json")
CACHE_VENT = os.path.join(BASE, "audit/cache_vent_catalogues.json")

NEIGHBOURHOOD_KM = 2.0                 # = MarineWeatherService.neighbourhoodKm
MODEL = "meteofrance_seamless"         # = premier de WindEnsemble.modelPriority (répond partout)
LABELS = ["centre", "nord", "sud", "est", "ouest"]
PAST_DAYS, FORECAST_DAYS = 5, 2


def neighbourhood(lat, lon):
    """Copie exacte de MarineWeatherService.neighbourhood."""
    d_lat = NEIGHBOURHOOD_KM / 111.0
    d_lon = NEIGHBOURHOOD_KM / (111.0 * max(0.1, math.cos(math.radians(lat))))
    return [(lat, lon), (lat + d_lat, lon), (lat - d_lat, lon),
            (lat, lon + d_lon), (lat, lon - d_lon)]


def get(url, tries=12):
    """curl et non urllib : le magasin de certificats de ce Python ne valide pas
    api.open-meteo.com (CERTIFICATE_VERIFY_FAILED), curl si."""
    for k in range(tries):
        try:
            p = subprocess.run(["curl", "-s", "--max-time", "120", url],
                               capture_output=True, text=True)
            d = json.loads(p.stdout)
            if isinstance(d, dict) and d.get("error"):
                raise RuntimeError(d.get("reason", "erreur API"))
            return d
        except Exception as e:
            msg = str(e)
            low = msg.lower()
            # Trois plafonds distincts chez Open-Meteo. Le plafond PAR MINUTE (600) se
            # franchit sans rien consommer d'irréversible : on attend et on repart.
            # Ceux à l'heure et au jour, eux, arrêtent la sonde — le cache disque garde
            # l'acquis et la relance reprendra là où elle en est.
            if "minutely" in low:
                print("    (plafond par minute — attente 65 s)")
                time.sleep(65)
                continue
            if "limit" in low or "quota" in low:
                raise RuntimeError("QUOTA:" + msg)
            if k == tries - 1:
                raise
            time.sleep(3 * (k + 1))


def key(lat, lon):
    return f"{lat:.4f},{lon:.4f}"


def load(path):
    return json.load(open(path)) if os.path.exists(path) else {}


def save(path, d):
    json.dump(d, open(path, "w"))


def points_of(entries):
    pts, seen = [], set()
    for e in entries:
        for (la, lo) in neighbourhood(e["lat"], e["lon"]):
            k = key(la, lo)
            if k not in seen:
                seen.add(k); pts.append((round(la, 4), round(lo, 4)))
    return pts


def run_elevation(entries):
    cache = load(CACHE_ELEV)
    pts = [p for p in points_of(entries) if key(*p) not in cache]
    print(f"élévation : {len(pts)} points à obtenir")
    B = 100
    for i in range(0, len(pts), B):
        chunk = pts[i:i + B]
        q = urllib.parse.urlencode({
            "latitude": ",".join(f"{a:.4f}" for a, _ in chunk),
            "longitude": ",".join(f"{b:.4f}" for _, b in chunk)})
        try:
            d = get("https://api.open-meteo.com/v1/elevation?" + q)
        except RuntimeError as e:
            print("STOP:", e); break
        for (a, b), v in zip(chunk, d["elevation"]):
            cache[key(a, b)] = v
        save(CACHE_ELEV, cache)
        print(f"  {i + len(chunk)}/{len(pts)}")
        time.sleep(13)
    print("élévations en cache :", len(cache))


def fetch_vent(chunk):
    """Renvoie la liste des réponses, ou None si la taille ne correspond pas."""
    q = urllib.parse.urlencode({
        "latitude": ",".join(f"{a:.4f}" for a, _ in chunk),
        "longitude": ",".join(f"{b:.4f}" for _, b in chunk),
        "hourly": "wind_speed_10m",
        "models": MODEL,
        "wind_speed_unit": "kn",
        "past_days": PAST_DAYS,
        "forecast_days": FORECAST_DAYS,
        "timeformat": "unixtime"})
    d = get("https://api.open-meteo.com/v1/forecast?" + q)
    arr = d if isinstance(d, list) else [d]
    return arr if len(arr) == len(chunk) else None


def run_vent(entries):
    cache = load(CACHE_VENT)
    pts = [p for p in points_of(entries) if key(*p) not in cache]
    print(f"vent : {len(pts)} points à obtenir")
    B = 40                                   # coordonnées par requête
    i = 0
    while i < len(pts):
        chunk = pts[i:i + B]
        try:
            arr = fetch_vent(chunk)
        except RuntimeError as e:
            print("STOP:", e); break
        if arr is None:                      # l'API n'a pas rendu autant de séries : on rétrécit
            if B > 5:
                B = max(5, B // 4)
                print(f"  lot ramené à {B} coordonnées")
                continue
            print("  ATTENTION lot rejeté même à 5 coordonnées"); break
        for (a, b), resp in zip(chunk, arr):
            cache[key(a, b)] = {"elev": resp.get("elevation"),
                                "ws": resp.get("hourly", {}).get("wind_speed_10m", [])}
        save(CACHE_VENT, cache)
        i += len(chunk)
        print(f"  {i}/{len(pts)}")
        time.sleep(6)
    print("séries vent en cache :", len(cache))


def toutes_les_entrees():
    """Les 4 catalogues EN ENTIER — l'endpoint élévation est assez bon marché pour ça
    (100 coordonnées par requête, ~220 requêtes pour 4 326 entrées), donc le compte des
    épingles sur terre n'a pas à être une estimation : il peut être exhaustif."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from echantillon_catalogues import load_all
    out = []
    for cat, items in load_all().items():
        for it in items:
            it = dict(it); it["catalogue"] = cat; it["_poids"] = 1.0
            out.append(it)
    return out


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else "elevation"
    if what == "elevation-tout":
        CACHE_ELEV = os.path.join(BASE, "audit/cache_elevation_tout.json")
        run_elevation(toutes_les_entrees())
    else:
        entries = json.load(open(ECH))["entrees"]
        (run_elevation if what == "elevation" else run_vent)(entries)

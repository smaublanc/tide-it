#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SONDE — paires « front de mer » / « plan d'eau abrité ».

Le test qui touche le propriétaire : en vent synoptique établi, un plan d'eau abrité ne
doit PAS souffler plus fort que le front de mer qui lui fait face. C'est l'anomalie
signalée cinq fois (Andernos > Lacanau Océan).

On mesure, pour chaque méthode d'échantillonnage candidate (A..F) et chaque paire, la
part des heures DIURNES où l'abrité dépasse le front de mer — d'abord toutes heures
confondues (la thermique a le droit d'inverser l'ordre), puis en ne gardant que les
heures VENTÉES, où le synoptique domine et où l'inversion n'a plus d'excuse physique.

DEUX FENÊTRES de 30 jours :
  · « ete »   = past_days=30 (18 juil. → 16 août 2026) — la fenêtre demandée.
  · « hiver » = 1er → 31 janv. 2026 — parce que TOUS les audits de ce dépôt portent sur
    l'été et n'ont jamais dépassé 20 nds observés. Le régime qui décide (> 25 nds) n'y
    était pas. Ici il y est (34,5 nds à Lacanau au premier sondage).

SOURCE : historical-forecast-api.open-meteo.com — même modèle `meteofrance_seamless`,
même grille native, même MNT pour `elevation` ; quota distinct de api.open-meteo.com,
épuisé par les volets précédents.

Sortie : audit/resultats_paires_abritees.json (cache : la sonde reprend où elle s'arrête)
"""
import json, math, os, subprocess, sys, time, urllib.parse

NEIGHBOURHOOD_KM = 2.0        # = MarineWeatherService.neighbourhoodKm
MODEL            = "meteofrance_seamless"
HOST             = "https://historical-forecast-api.open-meteo.com/v1/forecast"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "resultats_paires_abritees.json")

FENETRES = {
    "ete":   {"past_days": "30", "forecast_days": "0"},
    "hiver": {"start_date": "2026-01-01", "end_date": "2026-01-31"},
}

# 8 paires imposées. `front` = front de mer exposé, `abrite` = plan d'eau abrité.
PAIRES = [
    ("Lacanau Ocean / Andernos (Bassin)",      (45.0060,  -1.2020), (44.7450,  -1.1030)),
    ("Lacanau Ocean / Cap Ferret",             (45.0060,  -1.2020), (44.6333,  -1.2500)),
    ("Tarifa / baie de Cadix",                 (36.0100,  -5.6100), (36.5000,  -6.2500)),
    ("Wijk aan Zee / IJsselmeer",              (52.4900,   4.5800), (52.7200,   5.3000)),
    ("Hookipa Maui / baie de Kahului",         (20.9300,-156.3600), (20.8900,-156.4700)),
    ("Sotavento Fuerteventura / sa lagune",    (28.0500, -14.3200), (28.0900, -14.2900)),
    ("Jericoacoara / sa lagune interieure",    (-2.8000, -40.5100), (-2.8700, -40.4700)),
    ("Bloubergstrand / Langebaan lagune",     (-33.8100,  18.4600), (-33.0900,  18.0300)),
]


def neighbourhood(lat, lon):
    """Copie exacte de MarineWeatherService.neighbourhood (centre, N, S, E, O)."""
    d_lat = NEIGHBOURHOOD_KM / 111.0
    d_lon = NEIGHBOURHOOD_KM / (111.0 * max(0.1, math.cos(math.radians(lat))))
    return [(lat, lon), (lat + d_lat, lon), (lat - d_lat, lon),
            (lat, lon + d_lon), (lat, lon - d_lon)]


def fetch(coords, fenetre):
    params = {
        "latitude":  ",".join(f"{c[0]:.4f}" for c in coords),
        "longitude": ",".join(f"{c[1]:.4f}" for c in coords),
        "hourly": "wind_speed_10m",
        "models": MODEL,
        "wind_speed_unit": "kn",
    }
    params.update(FENETRES[fenetre])
    url = HOST + "?" + urllib.parse.urlencode(params)
    for attempt in range(6):
        try:
            out = subprocess.run(["curl", "-s", "--max-time", "180", url],
                                 capture_output=True, text=True)
            data = json.loads(out.stdout)
        except Exception as e:
            print(f"    ! {e}", file=sys.stderr); time.sleep(20 * (attempt + 1)); continue
        if isinstance(data, dict) and data.get("error"):
            raison = str(data.get("reason", "")).lower()
            print(f"    ! {data.get('reason')}", file=sys.stderr)
            if "daily" in raison:
                return None
            if "minutely" in raison or "hourly" in raison:
                time.sleep(70); continue
            time.sleep(20 * (attempt + 1)); continue
        if isinstance(data, dict):
            data = [data]
        if len(data) != len(coords):
            print(f"    ! {len(data)} séries pour {len(coords)} coordonnées", file=sys.stderr)
            return None
        return data
    return None


def sonde_spot(lat, lon, fenetre):
    coords = neighbourhood(lat, lon)
    data = fetch(coords, fenetre)
    if data is None:
        return None
    series, elevs = [], []
    for d in data:
        h = d.get("hourly") or {}
        series.append(h.get("wind_speed_10m") or [])
        elevs.append(d.get("elevation"))
    times = (data[0].get("hourly") or {}).get("time") or []
    return {"lat": lat, "lon": lon, "coords": coords,
            "times": times, "elevations": elevs, "vent": series}


def main():
    res = json.load(open(OUT)) if os.path.exists(OUT) else {}
    for fenetre in FENETRES:
        res.setdefault(fenetre, {})
        for nom, front, abrite in PAIRES:
            entree = res[fenetre].get(nom)
            if entree and entree.get("front") and entree.get("abrite"):
                print(f"= [{fenetre}] {nom} (déjà)"); continue
            print(f"→ [{fenetre}] {nom}…", flush=True)
            a = sonde_spot(*front, fenetre)
            if a is None:
                print("  ABANDON", file=sys.stderr); json.dump(res, open(OUT, "w"), ensure_ascii=False); return
            time.sleep(1.5)
            b = sonde_spot(*abrite, fenetre)
            if b is None:
                print("  ABANDON", file=sys.stderr); json.dump(res, open(OUT, "w"), ensure_ascii=False); return
            res[fenetre][nom] = {"front": a, "abrite": b}
            json.dump(res, open(OUT, "w"), ensure_ascii=False)
            print(f"  ok — {len(a['times'])} h · élév front {a['elevations']} / abrité {b['elevations']}",
                  flush=True)
            time.sleep(1.5)
    print(f"\nÉcrit dans {OUT}")


if __name__ == "__main__":
    main()

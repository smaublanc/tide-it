#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AUDIT RUGOSITÉ — le vent 10 m dépend-il de la maille TERRE/EAU échantillonnée,
et si oui, partout sur la planète ou seulement dans le Bassin d'Arcachon ?

Pour chaque spot : la croix de 5 points à 2 km (identique à
MarineWeatherService.neighbourhood), sondée sur past_days=14 avec elevation.
UNE requête réseau par spot par modèle.

Sortie : audit/resultats_rugosite.json
"""
import json, math, subprocess, sys, time, urllib.parse
from statistics import median

import os
NEIGHBOURHOOD_KM = float(os.environ.get("RAYON_KM", "2.0"))
PAST_DAYS = 14

# ---------------------------------------------------------------- spots
# (nom, lat, lon, continent/zone)  — spots de glisse côtiers reconnus.
SPOTS = [
    # Europe atlantique
    ("Lacanau Océan (FR)",        45.0000,   -1.2033, "Europe-Atlantique"),
    ("Andernos, Bassin (FR)",     44.7433,   -1.1042, "Europe-Atlantique"),
    ("Guincho (PT)",              38.7320,   -9.4720, "Europe-Atlantique"),
    ("Brandon Bay (IE)",          52.2600,  -10.0300, "Europe-Atlantique"),
    ("Westkapelle (NL)",          51.5250,    3.4350, "Europe-Atlantique"),
    ("Sylt / Westerland (DE)",    54.9060,    8.3000, "Europe-Atlantique"),
    ("Tarifa (ES)",               36.0128,   -5.6033, "Europe-Atlantique"),
    # Méditerranée
    ("La Franqui, Leucate (FR)",  42.9160,    3.0300, "Mediterranee"),
    ("Vassiliki (GR)",            38.6250,   20.6000, "Mediterranee"),
    ("Alaçatı (TR)",              38.2500,   26.3600, "Mediterranee"),
    # Afrique
    ("Dakhla lagune (MA)",        23.8500,  -15.8000, "Afrique"),
    ("Essaouira (MA)",            31.5000,   -9.7700, "Afrique"),
    ("Langebaan (ZA)",           -33.0900,   18.0300, "Afrique"),
    ("Blouberg, Le Cap (ZA)",    -33.8100,   18.4600, "Afrique"),
    ("Paje, Zanzibar (TZ)",       -6.2700,   39.5300, "Afrique"),
    # Caraïbes
    ("Cabarete (DO)",             19.7580,  -70.4110, "Caraibes"),
    ("Sorobon, Bonaire (BQ)",     12.0900,  -68.2200, "Caraibes"),
    ("Silver Rock (BB)",          13.0700,  -59.5300, "Caraibes"),
    # Amérique du Nord
    ("Cape Hatteras (US)",        35.2200,  -75.6900, "Amerique-Nord"),
    ("Hood River (US)",           45.7100, -121.5100, "Amerique-Nord"),
    ("La Ventana (MX)",           24.0500, -109.9900, "Amerique-Nord"),
    ("Sherman Island (US)",       38.0400, -121.7700, "Amerique-Nord"),
    # Amérique du Sud / centrale
    ("Cumbuco (BR)",              -3.6250,  -38.7300, "Amerique-Sud"),
    ("Jericoacoara (BR)",         -2.7950,  -40.5100, "Amerique-Sud"),
    ("Paracas (PE)",             -13.8300,  -76.2500, "Amerique-Sud"),
    ("Punta Chame (PA)",           8.6400,  -79.7000, "Amerique-Sud"),
    # Asie
    ("Mui Ne (VN)",               10.9500,  108.2600, "Asie"),
    ("Bulabog, Boracay (PH)",     11.9700,  121.9300, "Asie"),
    ("Kalpitiya (LK)",             8.2300,   79.7500, "Asie"),
    ("Ishigaki (JP)",             24.4000,  124.1500, "Asie"),
    # Océanie
    ("Leighton, Perth (AU)",     -32.0400,  115.7500, "Oceanie"),
    ("Currumbin (AU)",           -28.1300,  153.4900, "Oceanie"),
    ("New Plymouth (NZ)",        -39.0500,  174.0300, "Oceanie"),
    # Îles
    ("Le Morne (MU)",            -20.4900,   57.3100, "Iles"),
    ("Pozo Izquierdo (ES)",       27.8100,  -15.4200, "Iles"),
    ("Kite Beach, Maui (US)",     20.9000, -156.4400, "Iles"),
    ("Punta Preta, Sal (CV)",     16.5900,  -22.9400, "Iles"),
]

LABELS = ["centre", "nord", "sud", "est", "ouest"]


def neighbourhood(lat, lon):
    """Copie exacte de MarineWeatherService.neighbourhood."""
    d_lat = NEIGHBOURHOOD_KM / 111.0
    d_lon = NEIGHBOURHOOD_KM / (111.0 * max(0.1, math.cos(math.radians(lat))))
    return [(lat, lon), (lat + d_lat, lon), (lat - d_lat, lon),
            (lat, lon + d_lon), (lat, lon - d_lon)]


def fetch(lat, lon, model):
    pts = neighbourhood(lat, lon)
    q = urllib.parse.urlencode({
        "latitude":  ",".join(f"{p[0]:.4f}" for p in pts),
        "longitude": ",".join(f"{p[1]:.4f}" for p in pts),
        "hourly": "wind_speed_10m",
        "models": model,
        "wind_speed_unit": "kn",
        "past_days": str(PAST_DAYS),
        "forecast_days": "1",
    })
    url = "https://api.open-meteo.com/v1/forecast?" + q
    # urllib n'a pas de magasin de certificats utilisable ici -> curl (trust store systeme).
    for attempt in range(6):
        try:
            out = subprocess.run(["curl", "-s", "--max-time", "120", url],
                                 capture_output=True, timeout=140)
            data = json.loads(out.stdout.decode())
            if isinstance(data, dict) and "error" in data:
                raise RuntimeError(data.get("reason", "erreur API"))
            return data if isinstance(data, list) else [data]
        except Exception as e:
            if attempt == 5:
                print(f"    ECHEC {model}: {e}", file=sys.stderr, flush=True)
                return None
            time.sleep(15 * (attempt + 1))
    return None


def pct(xs, p):
    if not xs:
        return None
    s = sorted(xs)
    k = (len(s) - 1) * p
    lo, hi = math.floor(k), math.ceil(k)
    return s[lo] if lo == hi else s[lo] + (s[hi] - s[lo]) * (k - lo)


def analyse(name, zone, resp):
    """resp = liste de 5 objets (un par coordonnée)."""
    if not resp or len(resp) < 5:
        return None
    elevs, series, cells = [], [], []
    for loc in resp:
        elevs.append(loc.get("elevation"))
        series.append(loc["hourly"]["wind_speed_10m"])
        cells.append((round(loc.get("latitude", 0), 4), round(loc.get("longitude", 0), 4)))
    mailles = len(set(cells))
    n = min(len(s) for s in series)
    if n < 24 or any(e is None for e in elevs):
        return None

    # eau = maille dont l'élévation modèle vaut 0 (proxy vérifié par le propriétaire)
    is_water = [e <= 0.0 for e in elevs]
    n_water, n_land = sum(is_water), 5 - sum(is_water)
    mixed = n_water > 0 and n_land > 0

    ranges, ranges_windy = [], []
    diffs, ratios = [], []            # eau - terre, eau / terre (par heure)
    w_all, l_all = [], []
    centre_vals = []
    for h in range(n):
        vals = [series[i][h] for i in range(5)]
        if any(v is None for v in vals):
            continue
        centre_vals.append(vals[0])
        rg = max(vals) - min(vals)
        ranges.append(rg)
        if vals[0] >= 8.0:            # heures navigables : le régime qui compte
            ranges_windy.append(rg)
        if mixed:
            w = median([vals[i] for i in range(5) if is_water[i]])
            l = median([vals[i] for i in range(5) if not is_water[i]])
            w_all.append(w); l_all.append(l)
            diffs.append(w - l)
            if l >= 3.0:              # ratio indéfini quand la terre est calme
                ratios.append(w / l)

    if not ranges:
        return None
    out = {
        "spot": name, "zone": zone, "heures": len(ranges),
        "elevations": elevs, "eau": n_water, "terre": n_land, "mixte": mixed,
        "mailles_distinctes": mailles,
        "elev_etendue_m": round(max(elevs) - min(elevs), 1),
        "vent_moyen_centre_kn": round(sum(centre_vals) / len(centre_vals), 2),
        "etendue_mediane_kn": round(median(ranges), 3),
        "etendue_p90_kn": round(pct(ranges, 0.90), 3),
        "etendue_max_kn": round(max(ranges), 3),
        "etendue_mediane_ventee_kn": round(median(ranges_windy), 3) if ranges_windy else None,
        "heures_ventees": len(ranges_windy),
    }
    if mixed and diffs:
        out.update({
            "eau_moy_kn": round(sum(w_all) / len(w_all), 2),
            "terre_moy_kn": round(sum(l_all) / len(l_all), 2),
            "ecart_eau_terre_kn": round(sum(diffs) / len(diffs), 3),
            "ratio_eau_terre": round((sum(w_all) / len(w_all)) / (sum(l_all) / len(l_all)), 3)
                                if sum(l_all) > 0 else None,
            "ratio_horaire_median": round(median(ratios), 3) if ratios else None,
        })
    return out


def main():
    models = sys.argv[1:] or ["icon_seamless"]
    result = {}
    for model in models:
        rows = []
        print(f"\n=== modele {model} ===", flush=True)
        for (name, lat, lon, zone) in SPOTS:
            resp = fetch(lat, lon, model)
            row = analyse(name, zone, resp)
            if row:
                rows.append(row)
                print(f"  {name:28s} elev={row['elevations']} "
                      f"étendue méd {row['etendue_mediane_kn']:5.2f} p90 {row['etendue_p90_kn']:5.2f} "
                      f"mailles={row['mailles_distinctes']} "
                      f"{'MIXTE ecart ' + str(row.get('ecart_eau_terre_kn')) if row['mixte'] else 'homogene'}", flush=True)
            else:
                print(f"  {name:28s} - pas de donnee", flush=True)
            time.sleep(2.5)
        result[model] = rows
    with open(f"audit/resultats_rugosite_{'_'.join(models)}_{int(NEIGHBOURHOOD_KM)}km.json", "w") as f:
        json.dump(result, f, indent=1, ensure_ascii=False)
    print("\n-> ecrit", flush=True)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AUDIT RUGOSITÉ, volet 2 — le contraste MER/TERRE à l'échelle de la MAILLE.

Le volet 1 (croix à 2 km) a montré que 23 spots sur 37 lisent la MÊME maille aux
cinq points : la croix ne peut alors RIEN exprimer, quelle que soit l'élévation.
Ici on écarte la croix jusqu'à dépasser la maille du modèle, pour mesurer de
combien le vent change réellement entre une maille MER et une maille TERRE.

Usage : RAYON_KM=12 python3 audit/audit_rugosite_maille.py icon_seamless
"""
import json, math, os, subprocess, sys, time, urllib.parse
from statistics import median

RAYON_KM = float(os.environ.get("RAYON_KM", "12.0"))
PAST_DAYS = int(os.environ.get("PAST_DAYS", "7"))

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from audit_rugosite import SPOTS, pct  # même liste de spots, même percentile


def cross(lat, lon, km):
    d_lat = km / 111.0
    d_lon = km / (111.0 * max(0.1, math.cos(math.radians(lat))))
    return [(lat, lon), (lat + d_lat, lon), (lat - d_lat, lon),
            (lat, lon + d_lon), (lat, lon - d_lon)]


def fetch(lat, lon, model, km):
    pts = cross(lat, lon, km)
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
    for attempt in range(8):
        try:
            out = subprocess.run(["curl", "-s", "--max-time", "120", url],
                                 capture_output=True, timeout=140)
            data = json.loads(out.stdout.decode())
            if isinstance(data, dict) and "error" in data:
                raise RuntimeError(data.get("reason", "erreur API"))
            return data if isinstance(data, list) else [data]
        except Exception as e:
            if attempt == 7:
                print(f"    ECHEC: {e}", file=sys.stderr, flush=True)
                return None
            time.sleep(45)
    return None


def analyse(name, zone, resp):
    if not resp or len(resp) < 5:
        return None
    elevs, series, cells = [], [], []
    for loc in resp:
        elevs.append(loc.get("elevation"))
        series.append(loc["hourly"]["wind_speed_10m"])
        cells.append((round(loc.get("latitude", 0), 4), round(loc.get("longitude", 0), 4)))
    if any(e is None for e in elevs):
        return None
    n = min(len(s) for s in series)

    # `== 0` EXACTEMENT, jamais `<= 0` ni `< 0.5`. Mesuré sur 2 617 points (17 août 2026) :
    # les élévations renvoyées sont TOUJOURS des entiers, et la terre littorale basse ne lit pas
    # 0 — elle lit un petit entier NÉGATIF. Polders néerlandais −5, Camargue −1, delta du Pô −2,
    # Fens −1, Lammefjord −4. `<= 0` classait donc toute cette terre ferme comme de l'eau.
    # Constaté ici même : Sherman Island (delta du Sacramento) lit [−4, −6, 0, −4, 0] — des îles
    # agricoles asséchées derrière digues, à forte rugosité — et `<= 0` y comptait 5 mailles
    # d'eau sur 5 au lieu de 2.
    # `== 0` : rappel 100 % sur l'océan (1 658/1 658), 0,65 % de faux positifs à terre.
    is_water = [e == 0.0 for e in elevs]
    # on n'oppose EAU et TERRE que si les deux camps occupent des mailles DISTINCTES :
    # sinon on comparerait une série avec elle-même.
    cw = {cells[i] for i in range(5) if is_water[i]}
    cl = {cells[i] for i in range(5) if not is_water[i]}
    opposable = bool(cw) and bool(cl) and not (cw & cl)

    ranges, ranges_windy, w_all, l_all, ratios = [], [], [], [], []
    for h in range(n):
        vals = [series[i][h] for i in range(5)]
        if any(v is None for v in vals):
            continue
        ranges.append(max(vals) - min(vals))
        if vals[0] >= 8.0:
            ranges_windy.append(max(vals) - min(vals))
        if opposable:
            w = median([vals[i] for i in range(5) if is_water[i]])
            l = median([vals[i] for i in range(5) if not is_water[i]])
            w_all.append(w); l_all.append(l)
            if l >= 3.0:
                ratios.append(w / l)
    if not ranges:
        return None
    out = {
        "spot": name, "zone": zone, "heures": len(ranges), "rayon_km": RAYON_KM,
        "elevations": elevs, "mailles_distinctes": len(set(cells)),
        "eau": sum(is_water), "terre": 5 - sum(is_water), "opposable": opposable,
        "etendue_mediane_kn": round(median(ranges), 3),
        "etendue_p90_kn": round(pct(ranges, 0.90), 3),
        "etendue_max_kn": round(max(ranges), 3),
        "etendue_mediane_ventee_kn": round(median(ranges_windy), 3) if ranges_windy else None,
    }
    if opposable and w_all:
        wm, lm = sum(w_all) / len(w_all), sum(l_all) / len(l_all)
        out.update({
            "eau_moy_kn": round(wm, 2), "terre_moy_kn": round(lm, 2),
            "ecart_eau_terre_kn": round(wm - lm, 3),
            "ratio_eau_terre": round(wm / lm, 3) if lm > 0 else None,
            "ratio_horaire_median": round(median(ratios), 3) if ratios else None,
        })
    return out


def main():
    model = (sys.argv[1:] or ["icon_seamless"])[0]
    rows = []
    print(f"=== {model} — croix a {RAYON_KM} km, past_days={PAST_DAYS} ===", flush=True)
    for (name, lat, lon, zone) in SPOTS:
        r = analyse(name, zone, fetch(lat, lon, model, RAYON_KM))
        if r:
            rows.append(r)
            print(f"  {name:26s} mailles={r['mailles_distinctes']} eau/terre={r['eau']}/{r['terre']} "
                  f"etendue med {r['etendue_mediane_kn']:5.2f} p90 {r['etendue_p90_kn']:5.2f} "
                  + (f"ECART {r['ecart_eau_terre_kn']:+.2f} ratio {r['ratio_eau_terre']}"
                     if r.get("opposable") else "non opposable"), flush=True)
        else:
            print(f"  {name:26s} - pas de donnee", flush=True)
        time.sleep(3)
    with open(f"audit/resultats_maille_{model}_{int(RAYON_KM)}km.json", "w") as f:
        json.dump(rows, f, indent=1, ensure_ascii=False)
    print("-> ecrit", flush=True)


if __name__ == "__main__":
    main()

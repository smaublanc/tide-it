#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
RECENSEMENT de l'épingle sur les 4 catalogues (4 326 entrées), + la croix sur l'échantillon.

Trois grandeurs, du plus sûr au plus fragile — et il faut savoir laquelle on cite :
  1. ÉPINGLE SUR TERRE   — recensement (1 point par entrée), pas d'extrapolation.
  2. CROIX MIXTE         — échantillon stratifié (5 points par entrée), taux pondérés.
  3. ÉTENDUE DE VENT     — ce que le MODÈLE exprime, sur l'échantillon sondé en vent.

    python3 audit/analyse_epingles.py
"""
import collections, json, math, os, sys
from statistics import median

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(BASE, "audit"))
from echantillon_catalogues import load_all, continent_of

ELEV = json.load(open(os.path.join(BASE, "audit/cache_elevation_catalogues.json")))
ECH = json.load(open(os.path.join(BASE, "audit/echantillon_catalogues.json")))
TAILLES = ECH["tailles"]
NK = 2.0

# Plans d'eau INTÉRIEURS : leur surface n'est pas à 0 m, `elevation == 0` les dit « terre »
# à tort. Isolés, jamais corrigés — c'est un angle mort assumé de la règle.
LACS = [("Grands Lacs", 41.0, 49.5, -93.0, -76.0), ("Leman/Alpes", 45.5, 48.0, 5.5, 10.5),
        ("Caspienne", 36.0, 47.5, 46.0, 55.0), ("Baikal", 51.0, 56.0, 103.0, 110.0),
        ("Victoria", -3.5, 1.0, 31.0, 35.5), ("Columbia", 45.4, 46.2, -122.5, -119.0)]


def lac(lat, lon):
    for nom, a, b, c, d in LACS:
        if a <= lat <= b and c <= lon <= d:
            return nom
    return None


def k(a, b):
    return f"{a:.4f},{b:.4f}"


def main():
    cat = load_all()
    print("═══ 1. ÉPINGLE SUR TERRE — RECENSEMENT, 1 point par entrée ═══\n")
    print(f"{'catalogue':16} {'mesuré':>7} {'total':>6} {'couv.':>7} | "
          f"{'épingle TERRE':>14} {'dont lac':>9}")
    glob_n = glob_t = 0
    for c in ("surf_spots", "shom_ports", "ticon_stations", "noaa_stations"):
        rows = []
        for e in cat[c]:
            v = ELEV.get(k(e["lat"], e["lon"]))
            if v is None:
                continue
            rows.append((e, v, lac(e["lat"], e["lon"])))
        if not rows:
            continue
        terre = [r for r in rows if r[1] != 0]
        lacs = [r for r in terre if r[2]]
        n, T = len(rows), TAILLES[c]
        print(f"{c:16} {n:>7} {T:>6} {100*n/T:>6.0f}% | {100*len(terre)/n:>13.1f}% "
              f"{len(lacs):>9}")
        glob_n += n
        glob_t += len(terre)
    print(f"{'TOTAL':16} {glob_n:>7} {sum(TAILLES.values()):>6} "
          f"{100*glob_n/sum(TAILLES.values()):>6.0f}% | {100*glob_t/glob_n:>13.1f}%")
    print(f"\n→ {glob_t} épingles sur TERRE parmi les {glob_n} recensées "
          f"(≈ {round(glob_t/glob_n*sum(TAILLES.values()))} sur {sum(TAILLES.values())}).")

    print("\nPAR CONTINENT — le défaut est-il français ?")
    par = collections.defaultdict(lambda: [0, 0])
    for c in cat:
        for e in cat[c]:
            v = ELEV.get(k(e["lat"], e["lon"]))
            if v is None:
                continue
            g = par[continent_of(e["lat"], e["lon"])]
            g[0] += 1
            g[1] += (v != 0)
    print(f"   {'continent':16} {'n':>6} {'épingle TERRE':>15}")
    for cont in sorted(par, key=lambda x: -par[x][0]):
        n, t = par[cont]
        if n < 20:
            continue
        print(f"   {cont:16} {n:>6} {100*t/n:>14.1f}%")

    print("\nRÉPARTITION DES ALTITUDES D'ÉPINGLE — « terre » n'est pas « forêt »")
    vals = [ELEV[k(e['lat'], e['lon'])] for c in cat for e in cat[c]
            if k(e['lat'], e['lon']) in ELEV]
    tot = len(vals)
    for lo, hi, lbl in ((0, 0, "= 0 m (EAU)"), (0.5, 3, "1 - 3 m"), (3.5, 10, "4 - 10 m"),
                        (10.5, 30, "11 - 30 m"), (30.5, 100, "31 - 100 m"),
                        (100.5, 1e9, "> 100 m")):
        s = sum(1 for v in vals if (v == 0 if hi == 0 else lo <= v <= hi))
        print(f"   {lbl:14} {100*s/tot:>6.1f}%   {s:>6}")
    neg = sum(1 for v in vals if v < 0)
    print(f"   {'< 0 m':14} {100*neg/tot:>6.1f}%   {neg:>6}  (polders, dépressions — TERRE)")


if __name__ == "__main__":
    main()

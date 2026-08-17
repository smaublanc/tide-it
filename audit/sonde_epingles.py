#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
RECENSEMENT EXHAUSTIF de l'élévation de L'ÉPINGLE, sur les 4 326 entrées des 4 catalogues.

Pourquoi un script à part : le chiffre de tête (« l'épingle du spot tombe-t-elle sur une
maille TERRE ? ») n'a besoin que d'UN point par entrée, pas des cinq. 4 326 coordonnées
tiennent dans le plafond journalier d'Open-Meteo (10 000), là où la croix complète en
demanderait 21 538. On peut donc RECENSER au lieu d'ESTIMER — plus d'extrapolation, plus
d'intervalle de confiance sur le chiffre le plus cité.

La croix (mixité, étendue de vent) reste, elle, mesurée sur l'échantillon stratifié.

    python3 audit/sonde_epingles.py
"""
import json, os, random, sys, time, urllib.parse

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(BASE, "audit"))
from sonde_catalogues import get, key, load, save, toutes_les_entrees

CACHE = os.path.join(BASE, "audit/cache_elevation_catalogues.json")   # partagé avec la croix


def main():
    cache = load(CACHE)
    pts, seen = [], set()
    for e in toutes_les_entrees():
        k = key(e["lat"], e["lon"])
        if k in cache or k in seen:
            continue
        seen.add(k)
        pts.append((round(e["lat"], 4), round(e["lon"], 4)))
    # ORDRE ALÉATOIRE, et c'est essentiel : si le quota journalier coupe la sonde en
    # cours de route, l'acquis reste un échantillon NON BIAISÉ de l'ensemble. Dans
    # l'ordre naturel des catalogues, une coupure livrerait « tout TICON, pas de NOAA » —
    # c'est-à-dire une tranche géographique, inexploitable comme estimation.
    random.Random(20260817).shuffle(pts)
    print(f"épingles à obtenir : {len(pts)} (déjà en cache : {len(cache)} points)")
    B = 100
    for i in range(0, len(pts), B):
        chunk = pts[i:i + B]
        q = urllib.parse.urlencode({
            "latitude": ",".join(f"{a:.4f}" for a, _ in chunk),
            "longitude": ",".join(f"{b:.4f}" for _, b in chunk)})
        try:
            d = get("https://api.open-meteo.com/v1/elevation?" + q)
        except RuntimeError as e:
            print("STOP:", e)
            break
        for (a, b), v in zip(chunk, d["elevation"]):
            cache[key(a, b)] = v
        save(CACHE, cache)
        print(f"  {i + len(chunk)}/{len(pts)}", flush=True)
        time.sleep(11)
    print("total en cache :", len(cache))


if __name__ == "__main__":
    main()

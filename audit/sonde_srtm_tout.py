#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
COMPTE EXHAUSTIF de la croix terre/eau sur les 4 326 entrées des quatre catalogues,
via un MNT INDÉPENDANT (SRTM 90 m, puis ASTER 30 m au-delà de 60° de latitude).

Pourquoi pas Open-Meteo ? Parce que son endpoint élévation compte un « appel » PAR
COORDONNÉE (mesuré : six requêtes de 100 points suffisent à franchir le plafond des
600/minute). 4 326 entrées × 5 points = 21 538 coordonnées > le plafond JOURNALIER de
10 000 du palier gratuit. L'exhaustif est donc hors de portée sur Open-Meteo, alors
qu'opentopodata.org le rend en ~216 requêtes.

La substitution est légitime, mais elle DOIT être vérifiée : `audit/analyse_catalogues.py`
recroise les deux MNT sur les 1 175 points de l'échantillon et publie leur taux d'accord
sur le verdict binaire eau/terre. Ne pas citer le compte exhaustif sans ce taux.

Sortie : audit/cache_srtm_tout.json
"""
import json, math, os, subprocess, sys, time, urllib.parse

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(BASE, "audit/cache_srtm_tout.json")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sonde_catalogues import points_of, toutes_les_entrees, key


def fetch(chunk, dataset):
    q = "|".join(f"{a:.4f},{b:.4f}" for a, b in chunk)
    url = f"https://api.opentopodata.org/v1/{dataset}?locations=" + urllib.parse.quote(q)
    for k in range(5):
        p = subprocess.run(["curl", "-s", "--max-time", "120", url], capture_output=True, text=True)
        try:
            d = json.loads(p.stdout)
        except Exception:
            time.sleep(5); continue
        if d.get("status") == "OK":
            return [r["elevation"] for r in d["results"]]
        print("   ", dataset, d.get("error", "?")[:90])
        time.sleep(8)
    return None


def run(dataset, pts, cache):
    todo = [p for p in pts if key(*p) not in cache]
    print(f"{dataset} : {len(todo)} points")
    for i in range(0, len(todo), 100):
        ch = todo[i:i + 100]
        vals = fetch(ch, dataset)
        if vals is None:
            print("  STOP"); return False
        for (a, b), v in zip(ch, vals):
            cache[key(a, b)] = v
        json.dump(cache, open(OUT, "w"))
        if i % 2000 == 0:
            print(f"  {i + len(ch)}/{len(todo)}")
        time.sleep(1.1)          # opentopodata : 1 requête/s, 1 000/jour
    return True


if __name__ == "__main__":
    pts = points_of(toutes_les_entrees())
    cache = json.load(open(OUT)) if os.path.exists(OUT) else {}
    print("points uniques :", len(pts))
    run("srtm90m", pts, cache)
    # SRTM s'arrête à 60° : au-delà, ASTER (83 N – 83 S) prend le relais.
    manquants = [p for p in pts if cache.get(key(*p)) is None]
    print("points sans SRTM (hautes latitudes) :", len(manquants))
    if manquants:
        for p in manquants:
            cache.pop(key(*p), None)
        run("aster30m", manquants, cache)
    json.dump(cache, open(OUT, "w"))
    reste = sum(1 for p in pts if cache.get(key(*p)) is None)
    print(f"terminé : {len(cache)} points, {reste} encore sans valeur")

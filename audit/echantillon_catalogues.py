#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Tirage STRATIFIÉ des catalogues réels de l'app, pour mesurer l'ampleur du défaut de
rugosité sur les entrées que l'utilisateur peut réellement ouvrir.

Quatre catalogues, quatre populations très différentes — un tirage uniforme sur leur
union aurait été écrasé par les 2 389 ports TICON et les 1 323 NOAA (dont 262 en Alaska).
On tire donc PAR CATALOGUE et, à l'intérieur, PAR STRATE géographique, puis on rend les
POIDS d'extrapolation (taille de la strate / taille de l'échantillon de la strate) pour
que le pourcentage global soit celui du catalogue, pas celui du tirage.

Sortie : audit/echantillon_catalogues.json
"""
import json, math, os, random, collections

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SEED = 20260817
N_SURF, N_SHOM, N_TICON, N_NOAA = 70, 40, 220, 170
# ⚠️ Tirage EMBOÎTÉ : `stratified` mélange chaque strate avec une graine fixe puis en
# prend un préfixe. Augmenter N ne fait qu'allonger le préfixe — l'échantillon plus
# large CONTIENT le précédent, et le cache réseau reste valide.


def continent_of(lat, lon):
    """Strate géographique grossière — sert à répartir le tirage, pas à décrire la géographie."""
    if lat < -60: return "Antarctique"
    if -20 <= lon <= 45 and 34 <= lat <= 72: return "Europe"
    if -20 <= lon <= 55 and -36 <= lat < 34: return "Afrique"
    if 25 <= lon <= 180 and lat >= 0: return "Asie"
    if 95 <= lon <= 180 and lat < 0: return "Oceanie"
    if -180 <= lon <= -140 and lat < 0: return "Oceanie"
    if lon > 140 and lat < 0: return "Oceanie"
    if lat >= 13 and -170 <= lon <= -50: return "Amerique-Nord"
    if lat < 13 and -95 <= lon <= -30: return "Amerique-Sud"
    if -180 <= lon <= -120: return "Pacifique"
    return "Autre"


def stratified(items, n, keyfn):
    """Tire n éléments en répartissant sur les strates : chaque strate a au moins un
    représentant si elle existe, le reste au prorata de la racine de son effectif
    (racine et non effectif : sans ça l'Europe mangerait tout le tirage TICON)."""
    rnd = random.Random(SEED)
    groups = collections.defaultdict(list)
    for it in items:
        groups[keyfn(it)].append(it)
    keys = sorted(groups)
    weights = {k: math.sqrt(len(groups[k])) for k in keys}
    total = sum(weights.values())
    quota = {}
    for k in keys:
        quota[k] = max(1, min(len(groups[k]), int(round(n * weights[k] / total))))
    # ajuste au total voulu
    while sum(quota.values()) > n:
        k = max(keys, key=lambda k: quota[k] / max(1, len(groups[k])))
        if quota[k] > 1: quota[k] -= 1
        else: break
    while sum(quota.values()) < n:
        k = min((k for k in keys if quota[k] < len(groups[k])),
                key=lambda k: quota[k] / max(1, len(groups[k])), default=None)
        if k is None: break
        quota[k] += 1
    out = []
    for k in keys:
        g = list(groups[k]); rnd.shuffle(g)
        pick = g[:quota[k]]
        w = len(g) / len(pick)          # poids d'extrapolation vers le catalogue entier
        for it in pick:
            it = dict(it); it["_strate"] = k; it["_poids"] = w
            out.append(it)
    return out


def load_all():
    cat = {}

    surf = json.load(open(os.path.join(BASE, "Tide It/surf_spots.json")))
    cat["surf_spots"] = [{"id": s["id"], "name": s["name"], "lat": s["latitude"],
                          "lon": s["longitude"], "pays": s.get("country", "")} for s in surf]

    shom = []
    for line in open(os.path.join(BASE, "Tide It/shom_ports.txt"), encoding="utf-8"):
        line = line.rstrip("\n")
        if not line: continue
        p = line.split(":")
        if len(p) < 4: continue
        try: shom.append({"id": p[0], "name": p[1], "lat": float(p[2]), "lon": float(p[3]), "pays": "France"})
        except ValueError: continue
    cat["shom_ports"] = shom

    tic = json.load(open(os.path.join(BASE, "Tide It/ticon_stations.json")))
    cat["ticon_stations"] = [{"id": s["id"], "name": s["name"], "lat": s["latitude"],
                              "lon": s["longitude"], "pays": s.get("country", "")} for s in tic]

    noaa = json.load(open(os.path.join(BASE, "Tide It/noaa_stations.json")))
    cat["noaa_stations"] = [{"id": s["id"], "name": s["name"], "lat": s["latitude"],
                             "lon": s["longitude"], "pays": s.get("state", s.get("country", ""))} for s in noaa]
    return cat


def main():
    cat = load_all()
    targets = {"surf_spots": N_SURF, "shom_ports": N_SHOM,
               "ticon_stations": N_TICON, "noaa_stations": N_NOAA}
    ech = []
    for name, items in cat.items():
        key = (lambda it: continent_of(it["lat"], it["lon"])) if name != "noaa_stations" \
              else (lambda it: it["pays"] or "?")
        picked = stratified(items, targets[name], key)
        for p in picked:
            p["catalogue"] = name
            p["continent"] = continent_of(p["lat"], p["lon"])
        ech += picked
        print(f"{name}: {len(items)} entrées → {len(picked)} tirées, "
              f"{len(set(p['_strate'] for p in picked))} strates")

    print(f"TOTAL échantillon : {len(ech)}")
    print(collections.Counter(p["continent"] for p in ech))
    out = os.path.join(BASE, "audit/echantillon_catalogues.json")
    json.dump({"tailles": {k: len(v) for k, v in cat.items()}, "entrees": ech},
              open(out, "w"), ensure_ascii=False, indent=1)
    print("→", out)


if __name__ == "__main__":
    main()

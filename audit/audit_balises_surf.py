#!/usr/bin/env python3
"""Chaque spot de surf a-t-il une balise de vent RÉELLE à portée ?

POURQUOI
Le « vent réel » de l'app ne s'affiche que si une balise se trouve à moins de 15 km
(`WindStationAggregator.defaultSearchRadius`). C'est ce rayon qui garantit qu'une mesure décrit
bien le spot — au-delà, elle vient d'un autre régime de vent (piège du Cap Ferret : « réel 9 nds »
contre 17 prévus, la mesure venant d'une station intérieure).

Mais personne n'avait jamais mesuré la COUVERTURE : combien des 284 spots du catalogue voient
réellement une balise ? Sans ce chiffre, on ne sait pas si « pas de vent réel ici » est une
exception ou la règle — ni où chercher pour l'améliorer.

CE QU'IL INTERROGE (aucune source payante, aucune clé, et surtout PAS Open-Meteo — cet audit doit
pouvoir tourner même quand le quota de prévision est épuisé) :
  - Pioupiou      : liste mondiale en un appel, distances calculées en local
  - Bouées NDBC   : liste mondiale en un appel
  - METAR         : par BOÎTE ENGLOBANTE de 5°, une requête par tuile plutôt qu'une par spot
  - winds.mobi    : requête géo par spot, mais SEULEMENT pour les spots encore sans balise
                    (son API ignore `offset`, donc pas d'énumération possible ; et interroger
                    284 fois ce que trois listes ont déjà résolu serait grossier)

USAGE
    cd audit && python3 audit_balises_surf.py
Sortie : audit_balises_surf.json + un tableau lisible.
"""
import json
import math
import subprocess
import sys
import collections

RAYON_KM = 15.0          # = WindStationAggregator.defaultSearchRadius
SPOTS = "../Tide It/surf_spots.json"


def curl(url, timeout=60):
    return subprocess.run(["curl", "-s", "-m", str(timeout), url],
                          capture_output=True, text=True).stdout


def km(lat1, lon1, lat2, lon2):
    r = 6371.0
    dLat, dLon = math.radians(lat2 - lat1), math.radians(lon2 - lon1)
    a = (math.sin(dLat / 2) ** 2
         + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dLon / 2) ** 2)
    return r * 2 * math.asin(math.sqrt(a))


# --- Les spots -----------------------------------------------------------------
raw = json.load(open(SPOTS, encoding="utf-8"))
spots = raw.get("spots", raw) if isinstance(raw, dict) else raw
spots = [s for s in spots if s.get("latitude") is not None]
print(f"{len(spots)} spots de surf\n")

# --- Inventaires mondiaux (2 appels) -------------------------------------------
stations = []   # (source, id, nom, lat, lon)

d = json.loads(curl("https://api.pioupiou.fr/v1/live-with-meta/all"))
arr = d.get("data", d) if isinstance(d, dict) else d
for s in arr:
    loc = s.get("location") or {}
    if loc.get("latitude") is not None and loc.get("longitude") is not None:
        stations.append(("pioupiou", str(s.get("id")), s.get("meta", {}).get("name") or "",
                         loc["latitude"], loc["longitude"]))
print(f"  Pioupiou   : {sum(1 for x in stations if x[0]=='pioupiou'):5}")

n0 = len(stations)
for line in curl("https://www.ndbc.noaa.gov/data/latest_obs/latest_obs.txt").splitlines()[2:]:
    p = line.split()
    if len(p) < 3:
        continue
    try:
        stations.append(("ndbc", p[0], p[0], float(p[1]), float(p[2])))
    except ValueError:
        pass
print(f"  Bouées NDBC: {len(stations)-n0:5}")

# --- METAR par tuiles de 5° (une requête par tuile occupée) --------------------
tuiles = {(int(math.floor(s["latitude"] / 5) * 5), int(math.floor(s["longitude"] / 5) * 5))
          for s in spots}
n0 = len(stations)
vus = set()
for i, (la, lo) in enumerate(sorted(tuiles), 1):
    u = (f"https://aviationweather.gov/api/data/metar?bbox={la-1},{lo-1},{la+6},{lo+6}"
         "&format=json")
    try:
        d = json.loads(curl(u) or "[]")
    except Exception:
        continue
    for s in (d if isinstance(d, list) else d.get("data", [])):
        sid = s.get("icaoId")
        if not sid or sid in vus or s.get("lat") is None:
            continue
        vus.add(sid)
        stations.append(("metar", sid, s.get("name") or sid, s["lat"], s["lon"]))
    sys.stdout.write(f"\r  METAR      : {len(stations)-n0:5} ({i}/{len(tuiles)} tuiles)")
    sys.stdout.flush()
print()

# --- Plus proche par spot, sur les listes locales ------------------------------
def plus_proche(s, pool):
    best = None
    for src, sid, nom, la, lo in pool:
        d = km(s["latitude"], s["longitude"], la, lo)
        if best is None or d < best[0]:
            best = (d, src, sid, nom)
    return best


res = []
for s in spots:
    b = plus_proche(s, stations)
    res.append({"spot": s.get("name"), "pays": s.get("country"),
                "lat": s["latitude"], "lon": s["longitude"],
                "km": None if b is None else round(b[0], 2),
                "source": None if b is None else b[1],
                "station": None if b is None else b[3] or b[2]})

# --- winds.mobi : SEULEMENT pour les spots encore sans balise ------------------
trous = [r for r in res if r["km"] is None or r["km"] > RAYON_KM]
print(f"\n  winds.mobi : interrogé pour les {len(trous)} spots sans balise…")
for i, r in enumerate(trous, 1):
    u = ("https://winds.mobi/api/2.3/stations/"
         f"?near-lat={r['lat']}&near-lon={r['lon']}&near-distance={int(RAYON_KM*1000)}&limit=5")
    try:
        d = json.loads(curl(u, 45) or "[]")
    except Exception:
        d = []
    for st in (d if isinstance(d, list) else []):
        c = (st.get("loc") or {}).get("coordinates") or []
        if len(c) != 2:
            continue
        dd = km(r["lat"], r["lon"], c[1], c[0])
        if r["km"] is None or dd < r["km"]:
            r.update(km=round(dd, 2), source="windsmobi",
                     station=st.get("short") or st.get("name") or st.get("_id"))
    if i % 20 == 0:
        sys.stdout.write(f"\r    {i}/{len(trous)}"); sys.stdout.flush()
print()

# --- Bilan ---------------------------------------------------------------------
couverts = [r for r in res if r["km"] is not None and r["km"] <= RAYON_KM]
print("\n" + "=" * 78)
print(f"COUVERTURE À {RAYON_KM:.0f} km : {len(couverts)}/{len(res)} "
      f"({100*len(couverts)/len(res):.1f} %)")
print("=" * 78)

par_src = collections.Counter(r["source"] for r in couverts)
print("\nQui fournit la balise la plus proche :")
for src, n in par_src.most_common():
    print(f"  {src:12} {n:4}")

print("\nPar pays (spots couverts / total) :")
pays = collections.defaultdict(lambda: [0, 0])
for r in res:
    pays[r["pays"]][1] += 1
    if r["km"] is not None and r["km"] <= RAYON_KM:
        pays[r["pays"]][0] += 1
for p, (c, t) in sorted(pays.items(), key=lambda kv: (kv[1][0] / kv[1][1], -kv[1][1])):
    if c < t:
        print(f"  {p:22} {c:3}/{t:3}")

sans = sorted((r for r in res if r["km"] is None or r["km"] > RAYON_KM),
              key=lambda r: (r["km"] or 9e9))
print(f"\n{len(sans)} spots SANS balise à {RAYON_KM:.0f} km — les 25 les plus proches du seuil :")
for r in sans[:25]:
    d = "aucune" if r["km"] is None else f"{r['km']:6.1f} km"
    print(f"  {r['spot'][:34]:34} {r['pays'][:16]:16} {d}  {(r['station'] or '')[:24]}")

json.dump({"rayon_km": RAYON_KM, "n_spots": len(res),
           "couverts": len(couverts), "resultats": res},
          open("audit_balises_surf.json", "w"), ensure_ascii=False, indent=1)
print("\n→ audit_balises_surf.json")

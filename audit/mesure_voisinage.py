#!/usr/bin/env python3
"""Peut-on retirer l'échantillonnage par voisinage (5 points) sans rien perdre ?

ENJEU : le voisinage envoie 5 coordonnées par requête, et Open-Meteo facture à la localisation.
Le retirer diviserait par ~5 la consommation de quota — ce qui décide de rester ou non sur le
palier gratuit. L'audit du 17/08 a déjà mesuré que la différence de JUSTESSE est de 0,01 kn
(RMSE B 2,71 contre A 2,72 sur 47 stations METAR) et celle de STABILITÉ de 0,009 kn.

CE QUI MANQUAIT : le cas FONDATEUR. Le voisinage a été introduit parce qu'une épingle peut
tomber sur une maille de TERRE et lire le vent de la forêt (Lacanau : 9,3 nds au point contre
18,1 à 1,1 km). La question n'est donc pas la moyenne, c'est : COMBIEN d'entrées du catalogue
verraient leur valeur changer, et de combien ?

Frugal par construction : 1 modèle, 1 variable, 3 jours. ~80 entrées x 5 points.
"""
import json, math, subprocess, statistics, random, collections

random.seed(20260818)
N_ENTREES = 80
KM = 2.0

def curl(u, t=90):
    return subprocess.run(["curl","-s","-m",str(t),u],capture_output=True,text=True).stdout

def cross(lat, lon):
    dLat = KM/111.0; dLon = KM/(111.0*max(0.1, math.cos(math.radians(lat))))
    return [(lat,lon),(lat+dLat,lon),(lat-dLat,lon),(lat,lon+dLon),(lat,lon-dLon)]

# --- Entrées RÉELLES du catalogue livré ---------------------------------------
ent = []
d = json.load(open("../Tide It/surf_spots.json", encoding="utf-8"))
sp = d.get("spots", d) if isinstance(d, dict) else d
ent += [(s["name"], s["latitude"], s["longitude"], "surf") for s in sp if s.get("latitude")]
for l in open("../Tide It/shom_ports.txt", encoding="utf-8"):
    p = l.strip().split(":")
    if len(p) == 4:
        try: ent.append((p[1], float(p[2]), float(p[3]), "port"))
        except ValueError: pass
random.shuffle(ent)
ent = ent[:N_ENTREES]
print(f"{len(ent)} entrées tirées du catalogue livré (spots surf + ports FR)\n")

res = []
for i, (nom, la, lo) in enumerate([(e[0], e[1], e[2]) for e in ent], 1):
    pts = cross(la, lo)
    A = ",".join(f"{p[0]:.4f}" for p in pts); B = ",".join(f"{p[1]:.4f}" for p in pts)
    u = (f"https://api.open-meteo.com/v1/forecast?latitude={A}&longitude={B}"
         "&hourly=wind_speed_10m&models=meteofrance_seamless&wind_speed_unit=kn"
         "&timezone=UTC&forecast_days=3")
    try: j = json.loads(curl(u))
    except Exception: continue
    if isinstance(j, dict):
        if j.get("error"): print("QUOTA:", j.get("reason")); break
        j = [j]
    if len(j) < 5: continue
    els = [x.get("elevation") for x in j]
    n = len(j[0]["hourly"]["time"])
    ecarts, vents = [], []
    for k in range(n):
        v = [x["hourly"]["wind_speed_10m"][k] for x in j]
        if any(z is None for z in v): continue
        ecarts.append(statistics.median(v) - v[0])   # médiane − centre
        vents.append(statistics.median(v))
    if not ecarts: continue
    res.append({"nom": nom, "centre_terre": els[0] != 0,
                "eau_dans_croix": any(e == 0 for e in els),
                "ecart_moy": statistics.mean(ecarts),
                "ecart_abs_moy": statistics.mean(abs(e) for e in ecarts),
                "ecart_max": max(abs(e) for e in ecarts),
                "vent_moy": statistics.mean(vents)})
    if i % 10 == 0: print(f"  {i}/{len(ent)}")

json.dump(res, open("mesure_voisinage.json","w"), ensure_ascii=False, indent=1)
print(f"\n{len(res)} entrées mesurées, 72 h chacune\n")
print("="*74)
print("DE COMBIEN LA VALEUR CHANGERAIT-ELLE SI ON RETIRAIT LE VOISINAGE ?")
print("="*74)
a = sorted(r["ecart_abs_moy"] for r in res)
print(f"  écart |médiane − centre| : médiane {statistics.median(a):.3f} kn · "
      f"p90 {a[int(len(a)*.9)]:.3f} · max {a[-1]:.3f}")
ident = sum(1 for r in res if r["ecart_max"] < 0.05)
print(f"  entrées STRICTEMENT identiques (croix dans une seule maille) : {ident}/{len(res)}"
      f"  ({100*ident/len(res):.0f} %)")
gros = [r for r in res if r["ecart_abs_moy"] >= 1.0]
print(f"  entrées où l'écart moyen dépasse 1 kn : {len(gros)}/{len(res)}"
      f"  ({100*len(gros)/len(res):.0f} %)")

print("\nLE CAS FONDATEUR — épingle sur une maille de TERRE, eau ailleurs dans la croix :")
cas = [r for r in res if r["centre_terre"] and r["eau_dans_croix"]]
print(f"  {len(cas)}/{len(res)} entrées concernées")
if cas:
    b = sorted(r["ecart_abs_moy"] for r in cas)
    print(f"  écart |médiane − centre| : médiane {statistics.median(b):.3f} kn · max {b[-1]:.3f}")
    for r in sorted(cas, key=lambda x: -x["ecart_abs_moy"])[:8]:
        print(f"    {r['nom'][:32]:32} {r['ecart_moy']:+6.2f} kn  (vent moy {r['vent_moy']:.1f})")

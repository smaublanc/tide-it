#!/usr/bin/env python3
"""Chercher la MEILLEURE balise de chaque spot, et vérifier qu'elle publie un historique.

L'audit du 17/08 n'interrogeait winds.mobi que pour les spots DÉJÀ sans couverture : un spot
« couvert » par un aérodrome à 14 km pouvait donc masquer une balise côtière à 3 km. Ici on
interroge winds.mobi pour TOUS les spots, et on retient la plus proche toutes sources confondues.

On vérifie en plus, pour chaque balise retenue, qu'elle publie un HISTORIQUE exploitable —
c'est ce qui permet à la trace du réel d'être continue dès la première ouverture.
"""
import json, math, subprocess, sys, collections

RAYON = 15.0

def curl(u, t=45):
    return subprocess.run(["curl","-s","-m",str(t),u],capture_output=True,text=True).stdout

def km(a,b,c,d):
    R=6371.0; dLa=math.radians(c-a); dLo=math.radians(d-b)
    x=(math.sin(dLa/2)**2+math.cos(math.radians(a))*math.cos(math.radians(c))*math.sin(dLo/2)**2)
    return R*2*math.asin(math.sqrt(x))

raw=json.load(open("../Tide It/surf_spots.json",encoding="utf-8"))
spots=[s for s in (raw.get("spots",raw) if isinstance(raw,dict) else raw) if s.get("latitude")]
print(f"{len(spots)} spots · winds.mobi interrogé pour CHACUN\n")

# base : l'audit précédent (Pioupiou + NDBC + METAR déjà calculés)
base={r["spot"]: r for r in json.load(open("audit_balises_surf.json"))["resultats"]}

res=[]
for i,s in enumerate(spots,1):
    nom=s["name"]; la=s["latitude"]; lo=s["longitude"]
    b=dict(base.get(nom, {"km":None,"source":None,"station":None}))
    b.update(spot=nom, pays=s.get("country"), lat=la, lon=lo, wm_id=None)
    u=(f"https://winds.mobi/api/2.3/stations/?near-lat={la}&near-lon={lo}"
       f"&near-distance={int(RAYON*1000)}&limit=10")
    try: d=json.loads(curl(u) or "[]")
    except Exception: d=[]
    for st in (d if isinstance(d,list) else []):
        c=(st.get("loc") or {}).get("coordinates") or []
        if len(c)!=2 or st.get("status")=="red": continue
        dd=km(la,lo,c[1],c[0])
        if b["km"] is None or dd < b["km"]:
            b.update(km=round(dd,2), source="windsmobi",
                     station=st.get("short") or st.get("name") or st.get("_id"),
                     wm_id=st.get("_id"))
    res.append(b)
    if i%25==0: sys.stdout.write(f"\r  {i}/{len(spots)}"); sys.stdout.flush()
print()

cov=[r for r in res if r["km"] is not None and r["km"]<=RAYON]
avant=len([r for r in base.values() if r["km"] is not None and r["km"]<=RAYON])
print(f"\nCOUVERTURE à {RAYON:.0f} km : {len(cov)}/{len(res)} ({100*len(cov)/len(res):.1f} %)"
      f"   — était {avant}/{len(res)} ({100*avant/len(res):.1f} %)")
print("\nSource de la balise la plus proche :")
for k,v in collections.Counter(r["source"] for r in cov).most_common(): print(f"  {k:12} {v:4}")

# HISTORIQUE : testé sur les balises winds.mobi retenues
wm=[r for r in cov if r["source"]=="windsmobi" and r["wm_id"]]
print(f"\nHistorique vérifié sur les {len(wm)} balises winds.mobi retenues…")
avec=0
for i,r in enumerate(wm,1):
    try:
        h=json.loads(curl(f"https://winds.mobi/api/2.3/stations/{r['wm_id']}/historic/?duration=86400") or "[]")
        n=len(h) if isinstance(h,list) else 0
    except Exception: n=0
    r["histo_24h"]=n
    if n>=20: avec+=1
    if i%20==0: sys.stdout.write(f"\r  {i}/{len(wm)}"); sys.stdout.flush()
print(f"\r  {avec}/{len(wm)} publient un historique 24 h exploitable (>= 20 mesures)")

json.dump(res, open("chasse_balises.json","w"), ensure_ascii=False, indent=1)
gagnes=[r for r in cov if r["source"]=="windsmobi"
        and (base.get(r["spot"],{}).get("km") is None
             or base[r["spot"]]["km"] > r["km"] + 0.5)]
print(f"\n{len(gagnes)} spots ont une balise PLUS PROCHE que ce que l'audit précédent voyait :")
for r in sorted(gagnes,key=lambda x:x["km"])[:20]:
    av=base.get(r["spot"],{}).get("km")
    print(f"  {r['spot'][:30]:30} {r['km']:5.1f} km  (avant {av if av else 'aucune'})"
          f"  {str(r.get('histo_24h','?')):>4} mes.")
print("\n→ chasse_balises.json")

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Agrège audit/resultats_rugosite_monde_2km.json → les quatre chiffres demandés."""
import json, os, sys, math
from statistics import median, pstdev
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
PATH = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "resultats_rugosite_monde_2km.json")
rows = json.load(open(PATH))
EFF = "meteofrance_seamless"


def eff(r):
    return r["modeles"][r["modele_effectif"]]


def mark_opposable(rows):
    """OPPOSABLE = eau et terre tombent dans des mailles DISJOINTES du modèle.

    Quand ce n'est pas le cas, la « médiane eau » et la « médiane terre » sont la MÊME
    série : l'écart vaut exactement 0,000 et le rapport exactement 1,000 sur des centaines
    d'heures. La séparation est nette dans les données (0,000 d'un côté ; |écart| ≥ 0,091
    et rapport ≤ 0,877 ou ≥ 1,013 de l'autre) — aucun cas ambigu.
    """
    for r in rows:
        for st in r["modeles"].values():
            if "opposable" in st:
                continue
            ec, ra = st.get("ecart_eau_terre_kn"), st.get("ratio_eau_terre")
            st["opposable"] = ec is not None and not (ec == 0.0 and ra == 1.0)


mark_opposable(rows)


print("=" * 96)
print(f"AMPLEUR DU DEFAUT DE RUGOSITE — {len(rows)} spots, croix 2 km, past_days=14")
print("=" * 96)

zones = defaultdict(list)
for r in rows:
    zones[r["zone"]].append(r)

print(f"\n{'spot':26s} {'zone':18s} {'elev(m)':22s} {'ma':2s} {'med':>5s} {'p90':>5s} "
      f"{'max':>5s} {'eau':>5s} {'terre':>6s} {'ecart':>6s} {'ratio':>6s}")
print("-" * 96)
for z in ["Europe-Atlantique", "Mediterranee", "Afrique", "Caraibes", "Amerique-Nord",
          "Amerique-Sud", "Asie", "Oceanie", "Iles"]:
    for r in sorted(zones.get(z, []), key=lambda x: -eff(x)["etendue_mediane_kn"]):
        e = eff(r)
        ev = "/".join(str(int(x)) for x in r["elevations"])
        op = e.get("opposable")
        ec = f"{e['ecart_eau_terre_kn']:+6.2f}" if op and "ecart_eau_terre_kn" in e else "     ."
        ra = f"{e['ratio_eau_terre']:6.3f}" if op and e.get("ratio_eau_terre") else "     ."
        ea = f"{e['eau_moy_kn']:5.1f}" if op and "eau_moy_kn" in e else "    ."
        te = f"{e['terre_moy_kn']:6.1f}" if op and "terre_moy_kn" in e else "     ."
        print(f"{r['spot']:26s} {z:18s} {ev:22s} {e['mailles_distinctes']:2d} "
              f"{e['etendue_mediane_kn']:5.2f} {e['etendue_p90_kn']:5.2f} {e['etendue_max_kn']:5.2f} "
              f"{ea} {te} {ec} {ra}")

# ---------------------------------------------------------------- 1) étendue
meds = [eff(r)["etendue_mediane_kn"] for r in rows]
p90s = [eff(r)["etendue_p90_kn"] for r in rows]
maxs = [eff(r)["etendue_max_kn"] for r in rows]
multi = [r for r in rows if eff(r)["mailles_distinctes"] > 1]
mono = [r for r in rows if eff(r)["mailles_distinctes"] == 1]

print("\n" + "=" * 96)
print("1) ETENDUE DU VENT SUR LA CROIX (max - min des 5 points), en noeuds")
print("=" * 96)
print(f"  TOUS les spots ({len(rows)})           mediane des medianes {median(meds):5.2f}   "
      f"mediane des p90 {median(p90s):5.2f}   max observe {max(maxs):5.2f}")
print(f"  croix sur UNE SEULE maille ({len(mono):2d})   etendue identiquement NULLE — "
      f"la croix ne peut rien exprimer")
if multi:
    mm = [eff(r)["etendue_mediane_kn"] for r in multi]
    mp = [eff(r)["etendue_p90_kn"] for r in multi]
    mx = [eff(r)["etendue_max_kn"] for r in multi]
    print(f"  croix sur >1 maille ({len(multi):2d})         mediane {median(mm):5.2f}   "
          f"p90 {median(mp):5.2f}   max {max(mx):5.2f}   (min {min(mm):.2f}, max des med {max(mm):.2f})")
    vent = [eff(r)["etendue_mediane_ventee_kn"] for r in multi
            if eff(r).get("etendue_mediane_ventee_kn") is not None]
    if vent:
        print(f"  ... aux heures NAVIGABLES (centre >= 8 kn)  mediane {median(vent):5.2f}")

# ---------------------------------------------------------------- 2) croix mixte
mixtes = [r for r in rows if r["mixte"]]
opp = [r for r in rows if eff(r).get("opposable")]
print("\n" + "=" * 96)
print("2) CROIX MIXTE (au moins une maille EAU et une maille TERRE)")
print("=" * 96)
print(f"  EXPOSITION — croix mixte au sens du RELIEF REEL (MNT 90 m, elevation) : "
      f"{len(mixtes)}/{len(rows)} = {100*len(mixtes)/len(rows):.0f} %")
print(f"  EXPRESSION — eau et terre dans des mailles DISJOINTES du modele    : "
      f"{len(opp)}/{len(rows)} = {100*len(opp)/len(rows):.0f} %")
print(f"  -> {len(mixtes) - len(opp)} spots straddlent terre et eau dans la realite "
      f"SANS que le modele le voie (une seule maille, ou eau et terre partagent la maille).")
par_zone_mixte = {z: (sum(1 for r in v if r["mixte"]), len(v)) for z, v in zones.items()}
print("  par zone (mixtes/total) : " + "  ".join(f"{z.split('-')[0][:9]} {a}/{b}"
                                                 for z, (a, b) in par_zone_mixte.items()))

# ---------------------------------------------------------------- 3) écart eau/terre
print("\n" + "=" * 96)
print("3) ECART entre la MEDIANE des mailles EAU et la MEDIANE des mailles TERRE (noeuds)")
print("=" * 96)
if opp:
    ecarts = [eff(r)["ecart_eau_terre_kn"] for r in opp]
    print(f"  sur les {len(opp)} spots OPPOSABLES : moyenne {sum(ecarts)/len(ecarts):+5.2f}   "
          f"mediane {median(ecarts):+5.2f}   min {min(ecarts):+5.2f}   max {max(ecarts):+5.2f}")
    pos = sum(1 for e in ecarts if e > 0)
    print(f"  signe : {pos}/{len(ecarts)} spots ont l'eau PLUS ventee que la terre "
          f"({100*pos/len(ecarts):.0f} %)")
ecarts_all = [eff(r).get("ecart_eau_terre_kn") for r in rows if r["mixte"]]
ecarts_all = [e for e in ecarts_all if e is not None]
if ecarts_all:
    print(f"  si l'on inclut les croix mixtes NON opposables (ecart 0 par construction) : "
          f"moyenne {sum(ecarts_all)/len(ecarts_all):+5.2f} sur {len(ecarts_all)} spots "
          f"— chiffre TROMPEUR, il mesure la resolution du modele, pas le contraste.")

# ---------------------------------------------------------------- 4) ratio eau/terre
print("\n" + "=" * 96)
print("4) RAPPORT vent(EAU) / vent(TERRE) — est-il stable ?")
print("=" * 96)
ratios = [(r["spot"], r["zone"], eff(r)["ratio_eau_terre"]) for r in opp
          if eff(r).get("ratio_eau_terre")]
if ratios:
    vals = [v for _, _, v in ratios]
    print(f"  {len(vals)} spots opposables : moyenne {sum(vals)/len(vals):.3f}   "
          f"mediane {median(vals):.3f}   ecart-type {pstdev(vals):.3f}   "
          f"min {min(vals):.3f} ({min(ratios, key=lambda x: x[2])[0]})   "
          f"max {max(vals):.3f} ({max(ratios, key=lambda x: x[2])[0]})")
    print(f"  amplitude : x{max(vals)/min(vals):.2f} entre le spot le plus bas et le plus haut")
    print("\n  par zone :")
    pz = defaultdict(list)
    for _, z, v in ratios:
        pz[z].append(v)
    for z, v in sorted(pz.items()):
        print(f"    {z:20s} n={len(v):2d}  moyenne {sum(v)/len(v):.3f}  "
              f"min {min(v):.3f}  max {max(v):.3f}")
    print("\n  detail, du plus bas au plus haut :")
    for s, z, v in sorted(ratios, key=lambda x: x[2]):
        print(f"    {v:6.3f}  {s:26s} {z}")

# ---------------------------------------------------------------- 5) résolution
print("\n" + "=" * 96)
print("5) LE MODELE EFFECTIF ET SA MAILLE — pourquoi l'etendue est nulle presque partout")
print("=" * 96)
from collections import Counter
print("  modele effectif (premier qui repond, = WindEnsemble.modelPriority) : "
      + str(dict(Counter(r["modele_effectif"] for r in rows))))
for m in ["meteofrance_seamless", "icon_seamless", "gfs_seamless"]:
    ok = [r for r in rows if m in r["modeles"]]
    if not ok:
        continue
    c1 = sum(1 for r in ok if r["modeles"][m]["mailles_distinctes"] == 1)
    print(f"  {m:22s} repond {len(ok):2d}/{len(rows)}  croix sur 1 seule maille : "
          f"{c1:2d} ({100*c1/len(ok):.0f} %)")
print("\n  Hors du domaine AROME/ARPEGE-Europe, meteofrance_seamless = ARPEGE MONDE (0,25 deg,")
print("  ~25 km). Une croix de 2 km y tombe dans UNE maille : la mediane de voisinage est")
print("  un NO-OP, et le vent affiche est celui d'une maille de 25 km qui melange terre et mer.")

# France vs reste du monde
fr = [r for r in rows if "(FR)" in r["spot"]]
hors = [r for r in rows if "(FR)" not in r["spot"]]
print("\n" + "=" * 96)
print("6) FRANCE contre RESTE DU MONDE — la contrainte 'ca doit marcher sur toute la planete'")
print("=" * 96)
for lab, grp in (("France", fr), ("hors France", hors)):
    if not grp:
        continue
    m1 = sum(1 for r in grp if eff(r)["mailles_distinctes"] == 1)
    mm = [eff(r)["etendue_mediane_kn"] for r in grp]
    mu = [r for r in grp if eff(r)["mailles_distinctes"] > 1]
    mmu = [eff(r)["etendue_mediane_kn"] for r in mu]
    print(f"  {lab:12s} n={len(grp):2d}  croix sur 1 maille {m1:2d}/{len(grp):2d}  "
          f"etendue mediane globale {median(mm):5.2f}  "
          + (f"| sur les {len(mu)} croix multi-mailles : mediane {median(mmu):5.2f}, "
             f"max {max(eff(r)['etendue_max_kn'] for r in mu):5.2f}" if mu else ""))

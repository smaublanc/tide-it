#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
VOLET 4 — SYNTHÈSE. Trancher : « mailles eau » est-elle plus juste, moins juste, ou
équivalente — et SELON QUELLE RÉFÉRENCE ?

Trois choses, et rien d'autre :
  1. Le TABLEAU DÉCISIF : pour chaque famille de vérité terrain × chaque modèle, l'écart
     de RMSE à la méthode actuelle, restreint aux stations DISCRIMINANTES (celles où C
     peut différer de B — ailleurs la comparaison est vide et ne fait que diluer).
  2. Le BIAIS DE VALIDATION, chiffré : le même geste (lire les mailles ventées) est-il
     jugé meilleur ou pire selon que le capteur est sur la terre ou sur l'eau ?
  3. Le DÉCALAGE DE NIVEAU de chaque méthode — la grandeur qui a fait retirer le
     « décalage de 2 km vers le large ».
"""
import json, math, os, random, sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from analyse_verite_terrain import (METHODES, SRC, couples, metriques, part_c_differe,
                                    boot, prepare)

MODELES = ["meteofrance_seamless", "icon_seamless", "gfs_seamless"]


def charge():
    d = json.load(open(SRC))
    return {"METAR (terre)": (d["metar"], False),
            "LAISSE (interface)": ([b for b in d["bouees"] if b["genre"] == "laisse"], True),
            "BOUEES (pleine mer)": ([b for b in d["bouees"] if b["genre"] == "ocean"], True)}


def discriminantes(grp, modele, corr):
    """Stations où C rend une valeur différente de B sur ≥5 % des heures."""
    out = []
    for st in grp:
        p = couples(st, modele, corr, 0.0)
        if len(p) >= 150 and part_c_differe(p) >= 0.05:
            out.append(st)
    return out


def bloc(nom, grp, modele, corr):
    par, tout, _, _ = prepare(grp, modele, corr, 0.0)
    if not par:
        return None
    res = {"n": len(par), "obs": sum(v["B"]["obs"] for v in par.values()) / len(par)}
    for m in METHODES:
        r = boot(par, m, "B")
        res[m] = {
            "rmse": sum(v[m]["rmse"] for v in par.values()) / len(par),
            "biais": sum(v[m]["biais"] for v in par.values()) / len(par),
            "mae": sum(v[m]["mae"] for v in par.values()) / len(par),
            "niveau": sum(p[m] for _, p in tout) / len(tout),
            "d": r[0] if r else 0.0, "lo": r[1] if r else 0.0,
            "hi": r[2] if r else 0.0, "P": r[3] if r else 0.5,
        }
    return res


def verdict(v):
    if v["hi"] < 0:
        return "MEILLEURE"
    if v["lo"] > 0:
        return "PIRE     "
    return "="


def main():
    fam = charge()

    print("=" * 104)
    print("1. TABLEAU DECISIF — ecart de RMSE a la methode ACTUELLE (B), en noeuds")
    print("   Restreint aux stations DISCRIMINANTES : celles ou la croix de 2 km melange")
    print("   mailles terre et mailles eau ET ou le modele resout assez fin pour que ca change")
    print("   quelque chose. Partout ailleurs C est LITTERALEMENT egale a B.")
    print("   IC95 par bootstrap sur les stations, 20 000 tirages, 1 station = 1 voix.")
    print("=" * 104)
    for modele in MODELES:
        print(f"\n  ── {modele} ──")
        print(f"  {'famille':22}{'n':>3} {'obs':>6} {'RMSE B':>7} |"
              + "".join(f"{m:>26}" for m in ("C − B", "D − B", "E − B")))
        for nomf, (grp, corr) in fam.items():
            dis = discriminantes(grp, modele, corr)
            if not dis:
                tot = len(prepare(grp, modele, corr, 0.0)[0])
                print(f"  {nomf:22}{0:>3} {'—':>6} {'—':>7} |   "
                      f"aucune station discriminante sur {tot} : C ≡ B partout")
                continue
            r = bloc(nomf, dis, modele, corr)
            ligne = f"  {nomf:22}{r['n']:>3} {r['obs']:6.1f} {r['B']['rmse']:7.2f} |"
            for m in ("C", "D", "E"):
                v = r[m]
                ligne += (f"  {v['d']:+6.3f}[{v['lo']:+5.2f};{v['hi']:+5.2f}]"
                          f"{verdict(v):>10}")
            print(ligne)

    print("\n" + "=" * 104)
    print("2. LE BIAIS DE VALIDATION, CHIFFRE")
    print("   Meme methode, memes heures, memes modeles — seule change la NATURE DU SOL")
    print("   sous l'anemometre. Si le verdict change de signe, c'est la reference qui")
    print("   decide, pas la justesse.")
    print("=" * 104)
    print(f"  {'':22}{'METAR (terre)':>26}{'LAISSE (interface)':>26}{'BOUEES (mer)':>26}")
    for modele in MODELES:
        print(f"\n  ── {modele} — ecart de RMSE a B (toutes stations, 1 = 1 voix) ──")
        lignes = {m: f"  {m} − B{'':16}" for m in ("C", "D", "E")}
        for nomf, (grp, corr) in fam.items():
            r = bloc(nomf, grp, modele, corr)
            for m in ("C", "D", "E"):
                v = r[m]
                lignes[m] += f"{v['d']:+8.3f} {verdict(v):>17}"
        for m in ("C", "D", "E"):
            print(lignes[m])

    print("\n" + "=" * 104)
    print("3. DECALAGE DE NIVEAU — de combien chaque methode remonte la valeur AFFICHEE")
    print("   (moyenne de la valeur rendue, en noeuds, ecart a B). C'est la grandeur qui a")
    print("   fait retirer le « decalage de 2 km vers le large » : il surestimait de 8-9 kn.")
    print("=" * 104)
    for modele in MODELES:
        print(f"\n  ── {modele} ──")
        print(f"  {'famille':22}{'obs':>7}{'niveau B':>10}" +
              "".join(f"{m:>10}" for m in ("A−B", "C−B", "D−B", "E−B", "F−B")))
        for nomf, (grp, corr) in fam.items():
            r = bloc(nomf, grp, modele, corr)
            print(f"  {nomf:22}{r['obs']:7.2f}{r['B']['niveau']:10.2f}" +
                  "".join(f"{r[m]['niveau']-r['B']['niveau']:+10.2f}"
                          for m in ("A", "C", "D", "E", "F")))

    print("\n" + "=" * 104)
    print("4. BIAIS DU MODELE PAR FAMILLE (methode B) — ou le modele se trompe VRAIMENT")
    print("   Ordre de grandeur a comparer aux ecarts entre methodes ci-dessus.")
    print("=" * 104)
    print(f"  {'famille':22}" + "".join(f"{m:>26}" for m in MODELES))
    for nomf, (grp, corr) in fam.items():
        ligne = f"  {nomf:22}"
        for modele in MODELES:
            r = bloc(nomf, grp, modele, corr)
            ligne += f"  biais {r['B']['biais']:+6.2f}  RMSE {r['B']['rmse']:5.2f}   "
        print(ligne)

    # 5. l'effet de la seule correction de hauteur, pour le mettre en regard
    d = json.load(open(SRC))
    ocean = [b for b in d["bouees"] if b["genre"] == "ocean"]
    print("\n" + "=" * 104)
    print("5. CONTROLE D'ECHELLE — de combien la seule CORRECTION DE HAUTEUR deplace-t-elle")
    print("   le resultat, comparee a l'ecart entre deux methodes ?")
    print("=" * 104)
    for modele in MODELES:
        b_brut = bloc("brut", ocean, modele, False)
        b_10m = bloc("10m", ocean, modele, True)
        print(f"  {modele:24} bouees : biais BRUT {b_brut['B']['biais']:+6.2f} kn  →  "
              f"ramene a 10 m {b_10m['B']['biais']:+6.2f} kn   "
              f"(deplacement {b_10m['B']['biais']-b_brut['B']['biais']:+.2f} kn)")
    print("\n  À comparer au plus grand ecart entre C et B jamais mesure ici : ~0,05 kn.")


if __name__ == "__main__":
    main()

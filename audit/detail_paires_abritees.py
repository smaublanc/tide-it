#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
DÉTAIL — niveaux affichés, écarts en nœuds, IC95, et diagnostic de maille.

Complète `analyse_paires_abritees.py` : le pourcentage d'inversion ne suffit pas.
On veut savoir (a) de COMBIEN de nœuds l'ordre est inversé, (b) si une méthode
« répare » l'ordre en gonflant le niveau (= le décalage vers le large déjà refusé),
(c) si l'écart entre méthodes est significatif, (d) combien de mailles de modèle
DISTINCTES la croix voit — car là où il n'y en a qu'une, aucune méthode ne peut rien.
"""
import json, os, statistics as st
from analyse_paires_abritees import (METHODES, LIBELLE, serie_methodes,
                                     elevation_solaire, analyse)

BASE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(BASE, "resultats_paires_abritees.json")
AGG = os.path.join(BASE, "resultats_paires_abritees_agrege.json")


def mailles_distinctes(spot):
    """Nombre de séries horaires DISTINCTES parmi les 5 points = nb de mailles de modèle."""
    sigs = {tuple(s[:200]) for s in spot["vent"]}
    return len(sigs)


def main():
    src = json.load(open(SRC))
    agg = json.load(open(AGG)) if os.path.exists(AGG) else analyse()

    print("=" * 100)
    print("DIAGNOSTIC DE MAILLE — combien de séries DISTINCTES la croix de 5 points voit-elle ?")
    print("=" * 100)
    print(f"{'paire':40s} {'front':>22s} {'abrité':>22s}")
    for nom, p in src["hiver"].items():
        mf, ma = mailles_distinctes(p["front"]), mailles_distinctes(p["abrite"])
        ef = p["front"]["elevations"]; ea = p["abrite"]["elevations"]
        print(f"{nom[:40]:40s} {mf:d} maille(s), {sum(1 for e in ef if e<=0)}/5 eau"
              f"   {ma:d} maille(s), {sum(1 for e in ea if e<=0)}/5 eau")

    for fenetre in ("ete", "hiver"):
        print("\n" + "=" * 100)
        print(f"NIVEAU MOYEN AFFICHÉ (nds) — fenêtre {fenetre.upper()}")
        print("  Contrôle de biais : une méthode qui « répare » l'ordre en GONFLANT tout")
        print("  le monde rejoue le décalage de 2 km vers le large, essayé puis retiré.")
        print("=" * 100)
        print(f"{'paire':40s} {'côté':7s} " + " ".join(f"{m:>6s}" for m in METHODES))
        for nom, r in agg[fenetre].items():
            for cote in ("front", "abrite"):
                cl = "niveau_" + cote
                print(f"{nom[:40]:40s} {cote:7s} " +
                      " ".join(f"{r['methodes'][m][cl]:6.2f}" for m in METHODES))

    print("\n" + "=" * 100)
    print("ÉCART MÉDIAN front − abrité (nds) — positif = ordre PHYSIQUE respecté")
    print("=" * 100)
    for fenetre in ("ete", "hiver"):
        for etiq, titre in (("tous_vents", "toutes heures diurnes"),
                            ("vente_15_commun", "diurnes et ventées (front B > 15 nds)")):
            print(f"\n[{fenetre}] {titre}")
            print(f"{'paire':40s} {'n':>5s} " + " ".join(f"{m:>7s}" for m in METHODES))
            for nom, r in agg[fenetre].items():
                n = r["methodes"]["B"][etiq]["n"]
                if n < 20:
                    continue
                cells = []
                for m in METHODES:
                    v = r["methodes"][m][etiq]["ecart_median_front_moins_abrite"]
                    cells.append(f"{v:7.2f}" if v is not None else "      -")
                print(f"{nom[:40]:40s} {n:5d} " + " ".join(cells))

    print("\n" + "=" * 100)
    print("IC95 DE L'ÉCART À B (points de %, bootstrap 20 000 tirages sur des BLOCS-JOURS)")
    print("  négatif = MOINS d'inversions que B (mieux) · P = probabilité d'être meilleure que B")
    print("=" * 100)
    for fenetre in ("ete", "hiver"):
        for etiq in ("tous_vents", "vente_15_commun", "vente_20_commun"):
            print(f"\n[{fenetre}] {etiq}")
            for nom, r in agg[fenetre].items():
                n = r["methodes"]["B"][etiq]["n"]
                if n < 20:
                    continue
                bits = []
                for m in METHODES:
                    if m == "B":
                        continue
                    ic = r["methodes"][m][etiq].get("ic95_vs_B")
                    d = (r["methodes"][m][etiq]["pct_inversion"]
                         - r["methodes"]["B"][etiq]["pct_inversion"])
                    if ic:
                        sig = "*" if (ic[0] > 0 or ic[1] < 0) else " "
                        bits.append(f"{m}{sig}{d:+6.1f}[{ic[0]:+6.1f};{ic[1]:+6.1f}]P{ic[2]:3.0f}%")
                print(f"  {nom[:36]:36s} n={n:4d}  " + "  ".join(bits))

    # ------------------------------------------------------------------ agrégat
    print("\n" + "=" * 100)
    print("AGRÉGAT — moyenne des paires exploitables (1 paire = 1 voix, n >= 20)")
    print("=" * 100)
    for fenetre in ("ete", "hiver"):
        for etiq in ("tous_vents", "vente_15_commun", "vente_20_commun"):
            vals = {m: [] for m in METHODES}
            npair = 0
            for nom, r in agg[fenetre].items():
                if r["methodes"]["B"][etiq]["n"] < 20:
                    continue
                npair += 1
                for m in METHODES:
                    vals[m].append(r["methodes"][m][etiq]["pct_inversion"])
            if not npair:
                continue
            print(f"[{fenetre:5s}] {etiq:16s} ({npair} paires) : " +
                  "  ".join(f"{m} {sum(vals[m])/npair:5.1f}%" for m in METHODES))


if __name__ == "__main__":
    main()

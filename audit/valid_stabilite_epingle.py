#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
VALIDATION CROISÉE du test de stabilité au pointage.

Le dépôt exige qu'un changement ne soit retenu que si son gain TIENT HORS DE FRANCE et
DÉPASSE LE BRUIT en validation croisée (cf. CLAUDE.md, « Ce que l'audit a REFUSÉ »).
Ce script applique les deux garde-fous au classement produit par analyse_stabilite_epingle.py :

  1. FRANCE / HORS FRANCE — le gain survit-il quand on retire les spots français ?
  2. TEMPOREL — le classement appris sur la 1re semaine tient-il sur la 2de ?
  3. LEAVE-ONE-SPOT-OUT — le classement dépend-il d'un seul spot ?
  4. CONTRÔLE DE DÉGÉNÉRESCENCE — une méthode peut être stable parce qu'elle SATURE.
     On mesure donc aussi la stabilité TEMPORELLE de chaque méthode (l'écart-type de la
     valeur dans le temps) : une méthode qui aplatit le vent est disqualifiée, même
     parfaitement reproductible.
"""
import json, math, os, random, statistics as st

HERE = os.path.dirname(os.path.abspath(__file__))
SRC  = os.path.join(HERE, "resultats_stabilite_epingle.json")
METHODES = ["A", "B", "C", "D", "E", "F"]
SEUIL_NAVIGABLE = 8.0
FRANCE = ("Lacanau", "Andernos", "La Franqui")


def pct(xs, p):
    s = sorted(xs); k = (len(s) - 1) * p
    lo, hi = math.floor(k), math.ceil(k)
    return s[lo] if lo == hi else s[lo] + (s[hi] - s[lo]) * (k - lo)


def weighted_median(vals, poids):
    pairs = sorted(zip(vals, poids)); total = sum(poids); cum = 0.0
    for i, (v, w) in enumerate(pairs):
        cum += w
        if cum >= total / 2:
            if abs(cum - total / 2) < 1e-12 and i + 1 < len(pairs):
                return (v + pairs[i + 1][0]) / 2
            return v
    return pairs[-1][0]


def valeurs(v, e):
    eau = [v[i] for i in range(5) if e[i] is not None and abs(e[i]) < 0.5]
    med5 = st.median(v)
    return {"A": v[0], "B": med5,
            "C": st.median(eau) if eau else med5,
            "D": sum(eau) / len(eau) if eau else med5,
            "E": max(v),
            "F": weighted_median(v, [1.0 / (1.0 + abs(e[i] or 0.0)) for i in range(5)])}


def mesure(data, h0=0, h1=10**9):
    """Rend, par spot : σ (dispersion entre les 9 épingles) et σ_temps (variabilité horaire)."""
    out = []
    for spot in data:
        vent, elev, plan = spot["vent"], spot["elevations"], spot["plan"]
        pins = [{"v": [vent[i] for i in p["indices"]],
                 "e": [elev[i] for i in p["indices"]]} for p in plan]
        sd = {m: [] for m in METHODES}
        serie_moy = {m: [] for m in METHODES}
        for t in range(max(0, h0), min(len(spot["times"]), h1)):
            vt = []
            bad = False
            for p in pins:
                vv = [p["v"][k][t] for k in range(5)]
                if any(x is None for x in vv):
                    bad = True; break
                vt.append(valeurs(vv, p["e"]))
            if bad:
                continue
            if st.mean(x["B"] for x in vt) < SEUIL_NAVIGABLE:
                # on garde quand même la série pour σ_temps (calculé sur TOUTES les heures)
                for m in METHODES:
                    serie_moy[m].append(st.mean(x[m] for x in vt))
                continue
            for m in METHODES:
                xs = [x[m] for x in vt]
                sd[m].append(st.stdev(xs))
                serie_moy[m].append(st.mean(xs))
        if not sd["B"]:
            continue
        out.append({"nom": spot["nom"],
                    "france": spot["nom"].startswith(FRANCE),
                    "sd": {m: st.median(sd[m]) for m in METHODES},
                    "sd_temps": {m: st.stdev(serie_moy[m]) for m in METHODES},
                    "niveau": {m: st.mean(serie_moy[m]) for m in METHODES}})
    return out


def boot_ic(diffs, n=20000, graine=20260817):
    random.seed(graine)
    b = [st.mean([random.choice(diffs) for _ in range(len(diffs))]) for _ in range(n)]
    return st.mean(diffs), pct(b, 0.025), pct(b, 0.975), sum(1 for x in b if x < 0) / n


def classement(spots):
    return sorted((st.mean(s["sd"][m] for s in spots), m) for m in METHODES)


def main():
    data = json.load(open(SRC))
    tous = mesure(data)
    disc = [s for s in tous if s["sd"]["B"] > 1e-9]

    print("=" * 96)
    print("1. FRANCE / HORS FRANCE — le gain tient-il hors de France ?")
    print("=" * 96)
    for etiq, jeu in (("TOUS les spots", tous),
                      ("HORS France", [s for s in tous if not s["france"]]),
                      ("France seule", [s for s in tous if s["france"]]),
                      ("discriminants HORS France", [s for s in disc if not s["france"]])):
        print(f"\n  {etiq} (n={len(jeu)})")
        print("    rang : " + "  >  ".join(m for _, m in classement(jeu)))
        for m in ("C", "D", "E"):
            d = [s["sd"][m] - s["sd"]["B"] for s in jeu]
            moy, lo, hi, p = boot_ic(d)
            verdict = "SIGNIFICATIF" if hi < 0 else "non significatif"
            print(f"    {m} − B = {moy:+.3f} kn  IC95 [{lo:+.3f} ; {hi:+.3f}]  "
                  f"P={100*p:.0f} %  → {verdict}")

    print("\n" + "=" * 96)
    print("2. VALIDATION TEMPORELLE — classement appris sur la semaine 1, vérifié sur la semaine 2")
    print("=" * 96)
    s1, s2 = mesure(data, 0, 168), mesure(data, 168, 336)
    c1, c2 = classement(s1), classement(s2)
    print("  semaine 1 : " + "  >  ".join(m for _, m in c1))
    print("  semaine 2 : " + "  >  ".join(m for _, m in c2))
    print(f"  identique : {[m for _,m in c1] == [m for _,m in c2]}")
    for etiq, jeu in (("semaine 1", s1), ("semaine 2", s2)):
        d = [s["sd"]["C"] - s["sd"]["B"] for s in jeu]
        moy, lo, hi, p = boot_ic(d)
        print(f"  {etiq} : C − B = {moy:+.3f} [{lo:+.3f} ; {hi:+.3f}] P={100*p:.0f} %")

    print("\n" + "=" * 96)
    print("3. LEAVE-ONE-SPOT-OUT — le classement dépend-il d'un seul spot ?")
    print("=" * 96)
    ordres = {}
    for i in range(len(tous)):
        jeu = tous[:i] + tous[i + 1:]
        cle = tuple(m for _, m in classement(jeu))
        ordres.setdefault(cle, []).append(tous[i]["nom"])
    for cle, noms in sorted(ordres.items(), key=lambda x: -len(x[1])):
        print(f"  {'  >  '.join(cle)}   ({len(noms)} retraits sur {len(tous)})")
        if len(noms) <= 3:
            print(f"      en retirant : {', '.join(noms)}")

    print("\n" + "=" * 96)
    print("4. CONTRÔLE DE DÉGÉNÉRESCENCE — une méthode stable parce qu'elle SATURE ?")
    print("   σ_pointage = dispersion entre les 9 épingles (petit = bon)")
    print("   σ_temps    = variabilité du vent DANS LE TEMPS (petit = la méthode aplatit → mauvais)")
    print("=" * 96)
    print(f"  {'méthode':10} {'σ_pointage':>11} {'σ_temps':>9} {'niveau':>8} {'niveau−B':>9} "
          f"{'σ_point/σ_temps':>16}")
    for _, m in classement(disc):
        sp = st.mean(s["sd"][m] for s in disc)
        stp = st.mean(s["sd_temps"][m] for s in disc)
        niv = st.mean(s["niveau"][m] for s in disc)
        dn = st.mean(s["niveau"][m] - s["niveau"]["B"] for s in disc)
        print(f"  {m:10} {sp:11.3f} {stp:9.3f} {niv:8.2f} {dn:+9.3f} {sp/stp:16.4f}")
    print("\n  Pire décalage de niveau par spot (nœuds) :")
    for m in METHODES:
        pires = sorted(((s["niveau"][m] - s["niveau"]["B"], s["nom"]) for s in tous),
                       key=lambda x: -abs(x[0]))[:2]
        print(f"    {m} : " + " · ".join(f"{n} {v:+.2f}" for v, n in pires))


if __name__ == "__main__":
    main()

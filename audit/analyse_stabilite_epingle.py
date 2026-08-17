#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Agrégation du test de STABILITÉ AU POINTAGE (cf. audit_stabilite_epingle.py).

Pour chaque spot, chaque méthode et chaque heure : la valeur rendue par les 9 épingles.
On en tire l'ÉCART-TYPE et l'ÉTENDUE à travers les 9 épingles — c'est-à-dire de combien
la valeur affichée bouge quand l'épingle bouge de 1 km, à conditions météo identiques.

Aucune vérité terrain n'intervient : on ne dit pas quelle méthode est JUSTE, on dit
laquelle est REPRODUCTIBLE. C'est exactement la plainte du propriétaire.
"""
import json, math, os, random, statistics as st, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC  = os.path.join(HERE, "resultats_stabilite_epingle.json")

METHODES = ["A", "B", "C", "D", "E", "F"]
NOMS = {
    "A": "A  centre seul (avant le voisinage)",
    "B": "B  MÉDIANE des 5 points (ACTUEL)",
    "C": "C  médiane des mailles EAU",
    "D": "D  moyenne des mailles EAU",
    "E": "E  maximum des 5 points",
    "F": "F  médiane pondérée 1/(1+|élévation|)",
}
SEUIL_NAVIGABLE = 8.0   # nœuds — en dessous, personne ne navigue et l'écart n'intéresse pas


def median(xs):
    return st.median(xs)


def pct(xs, p):
    if not xs:
        return None
    s = sorted(xs)
    k = (len(s) - 1) * p
    lo, hi = math.floor(k), math.ceil(k)
    return s[lo] if lo == hi else s[lo] + (s[hi] - s[lo]) * (k - lo)


def weighted_median(vals, poids):
    pairs = sorted(zip(vals, poids))
    total = sum(poids)
    cum = 0.0
    for i, (v, w) in enumerate(pairs):
        cum += w
        if cum >= total / 2:
            # symétrie : si l'on tombe pile sur la moitié, on moyenne avec la suivante
            if abs(cum - total / 2) < 1e-12 and i + 1 < len(pairs):
                return (v + pairs[i + 1][0]) / 2
            return v
    return pairs[-1][0]


def valeurs_methodes(v, e):
    """v = 5 vitesses (centre, N, S, E, O), e = 5 élévations. Rend {méthode: valeur}."""
    eau = [v[i] for i in range(5) if e[i] is not None and abs(e[i]) < 0.5]
    med5 = median(v)
    return {
        "A": v[0],
        "B": med5,
        "C": median(eau) if eau else med5,          # repli documenté → B
        "D": sum(eau) / len(eau) if eau else med5,  # repli documenté → B
        "E": max(v),
        "F": weighted_median(v, [1.0 / (1.0 + abs(e[i] if e[i] is not None else 0.0))
                                 for i in range(5)]),
    }


def main():
    data = json.load(open(SRC))
    print(f"{len(data)} spots · {len(data[0]['times'])} heures · 9 épingles × croix de 5 points\n")

    par_spot = []
    sans_eau_pins, total_pins = 0, 0
    spots_sans_eau_qq_part = []

    for spot in data:
        vent, elev, plan = spot["vent"], spot["elevations"], spot["plan"]
        n_h = len(spot["times"])
        # série par épingle : 5 points
        pins = []
        for p in plan:
            idx = p["indices"]
            pins.append({"nom": p["epingle"],
                         "v": [vent[i] for i in idx],
                         "e": [elev[i] for i in idx]})

        n_sans_eau = 0
        for p in pins:
            total_pins += 1
            if not any(x is not None and abs(x) < 0.5 for x in p["e"]):
                n_sans_eau += 1
                sans_eau_pins += 1
        if n_sans_eau:
            spots_sans_eau_qq_part.append((spot["nom"], n_sans_eau))

        # valeurs par méthode, heure par heure, épingle par épingle
        sd  = {m: [] for m in METHODES}
        rng = {m: [] for m in METHODES}
        sd_nav  = {m: [] for m in METHODES}
        rng_nav = {m: [] for m in METHODES}
        rel_nav = {m: [] for m in METHODES}
        niveau  = {m: [] for m in METHODES}
        n_nav = 0

        for t in range(n_h):
            vals_t = []
            ok = True
            for p in pins:
                vv = [p["v"][k][t] if t < len(p["v"][k]) else None for k in range(5)]
                if any(x is None for x in vv):
                    ok = False; break
                vals_t.append(valeurs_methodes(vv, p["e"]))
            if not ok:
                continue
            navigable = st.mean(x["B"] for x in vals_t) >= SEUIL_NAVIGABLE
            if navigable:
                n_nav += 1
            for m in METHODES:
                xs = [x[m] for x in vals_t]
                s, r, mu = st.stdev(xs), max(xs) - min(xs), st.mean(xs)
                sd[m].append(s); rng[m].append(r); niveau[m].append(mu)
                if navigable:
                    sd_nav[m].append(s); rng_nav[m].append(r)
                    rel_nav[m].append(100.0 * s / mu if mu > 0 else 0.0)

        par_spot.append({
            "nom": spot["nom"], "zone": spot["zone"],
            "n_sans_eau": n_sans_eau, "n_nav": n_nav, "n_h": len(sd["B"]),
            "sd":  {m: median(sd[m])  for m in METHODES},
            "rng": {m: median(rng[m]) for m in METHODES},
            "sd_p90": {m: pct(sd[m], 0.90) for m in METHODES},
            "rng_max": {m: max(rng[m]) for m in METHODES},
            "sd_nav":  {m: (median(sd_nav[m])  if sd_nav[m]  else None) for m in METHODES},
            "rng_nav": {m: (median(rng_nav[m]) if rng_nav[m] else None) for m in METHODES},
            "rel_nav": {m: (median(rel_nav[m]) if rel_nav[m] else None) for m in METHODES},
            "niveau":  {m: median(niveau[m]) for m in METHODES},
        })

    # ── CLASSEMENT ────────────────────────────────────────────────────────────
    print("=" * 104)
    print("CLASSEMENT — écart-type de la valeur à travers les 9 épingles (nœuds)")
    print("  « médiane » = médiane sur les 336 heures, puis MOYENNE sur les spots (1 spot = 1 voix)")
    print("=" * 104)
    print(f"{'méthode':38} {'σ méd':>7} {'σ p90':>7} {'étend.':>7} {'σ méd':>8} {'étend.':>8} {'σ rel':>7} {'niveau':>7}")
    print(f"{'':38} {'toutes heures':>23}  {'heures navigables (≥8 kn)':>25}  {'':>7} {'kn':>7}")
    classement = []
    for m in METHODES:
        sdm  = st.mean(s["sd"][m] for s in par_spot)
        p90m = st.mean(s["sd_p90"][m] for s in par_spot)
        rgm  = st.mean(s["rng"][m] for s in par_spot)
        sdn  = st.mean(s["sd_nav"][m] for s in par_spot if s["sd_nav"][m] is not None)
        rgn  = st.mean(s["rng_nav"][m] for s in par_spot if s["rng_nav"][m] is not None)
        reln = st.mean(s["rel_nav"][m] for s in par_spot if s["rel_nav"][m] is not None)
        niv  = st.mean(s["niveau"][m] for s in par_spot)
        classement.append((sdn, m, sdm, p90m, rgm, sdn, rgn, reln, niv))
    for sdn, m, sdm, p90m, rgm, _, rgn, reln, niv in sorted(classement):
        print(f"{NOMS[m]:38} {sdm:7.3f} {p90m:7.3f} {rgm:7.3f} {sdn:8.3f} {rgn:8.3f} "
              f"{reln:6.1f}% {niv:7.2f}")

    print("\nRang (le plus stable d'abord, sur σ médian aux heures navigables) :")
    print("  " + "  >  ".join(m for _, m, *_ in sorted(classement)))

    # ── C VS B : test apparié sur les spots ───────────────────────────────────
    print("\n" + "=" * 104)
    print("C (mailles EAU) EST-ELLE PLUS STABLE QUE B (actuel) ? — test apparié, 1 spot = 1 paire")
    print("=" * 104)
    for etiquette, cle in (("toutes heures", "sd"), ("heures navigables", "sd_nav")):
        diffs = [s[cle]["C"] - s[cle]["B"] for s in par_spot if s[cle]["C"] is not None]
        n = len(diffs)
        moy = st.mean(diffs)
        mieux = sum(1 for d in diffs if d < -1e-9)
        pire  = sum(1 for d in diffs if d >  1e-9)
        egal  = n - mieux - pire
        random.seed(20260817)
        boots = []
        for _ in range(20000):
            ech = [random.choice(diffs) for _ in range(n)]
            boots.append(st.mean(ech))
        lo, hi = pct(boots, 0.025), pct(boots, 0.975)
        p_c_mieux = sum(1 for b in boots if b < 0) / len(boots)
        print(f"\n  {etiquette} (n={n} spots)")
        print(f"    σ(C) − σ(B) moyen : {moy:+.4f} kn   IC95 bootstrap [{lo:+.4f} ; {hi:+.4f}]")
        print(f"    C plus stable sur {mieux} spots · moins stable sur {pire} · identique sur {egal}")
        print(f"    P(C réellement plus stable) = {100*p_c_mieux:.1f} %")

    # même chose pour toutes les méthodes contre B, aux heures navigables
    print("\n  Écart à B (heures navigables), moyenne sur les spots + IC95 bootstrap :")
    for m in METHODES:
        if m == "B":
            continue
        diffs = [s["sd_nav"][m] - s["sd_nav"]["B"] for s in par_spot if s["sd_nav"][m] is not None]
        random.seed(20260817)
        boots = [st.mean([random.choice(diffs) for _ in range(len(diffs))]) for _ in range(20000)]
        lo, hi = pct(boots, 0.025), pct(boots, 0.975)
        signe = "plus stable" if st.mean(diffs) < 0 else "MOINS stable"
        print(f"    {m} : {st.mean(diffs):+.4f} kn  [{lo:+.4f} ; {hi:+.4f}]  → {signe}")

    # ── CAS SANS AUCUNE MAILLE EAU ────────────────────────────────────────────
    print("\n" + "=" * 104)
    print("CROIX SANS AUCUNE MAILLE EAU (C et D indéfinies)")
    print("=" * 104)
    print(f"  {sans_eau_pins}/{total_pins} épingles = {100*sans_eau_pins/total_pins:.1f} %")
    for nom, n in sorted(spots_sans_eau_qq_part, key=lambda x: -x[1]):
        print(f"    {nom:30} {n}/9 épingles sans eau")
    # variante STRICTE : spots où AUCUNE épingle n'a eu besoin du repli
    stricts = [s for s in par_spot if s["n_sans_eau"] == 0]
    if stricts:
        d = [s["sd_nav"]["C"] - s["sd_nav"]["B"] for s in stricts if s["sd_nav"]["C"] is not None]
        print(f"\n  Variante STRICTE — {len(stricts)} spots où le repli n'a JAMAIS servi :")
        print(f"    σ(C) − σ(B) = {st.mean(d):+.4f} kn  ({sum(1 for x in d if x<-1e-9)} mieux / "
              f"{sum(1 for x in d if x>1e-9)} pire / {sum(1 for x in d if abs(x)<=1e-9)} identique)")
    # spots où le repli a servi au moins une fois
    replis = [s for s in par_spot if s["n_sans_eau"] > 0]
    if replis:
        d = [s["sd_nav"]["C"] - s["sd_nav"]["B"] for s in replis if s["sd_nav"]["C"] is not None]
        print(f"  Spots AVEC repli ({len(replis)}) : σ(C) − σ(B) = {st.mean(d):+.4f} kn")

    # ── DÉTAIL PAR SPOT ───────────────────────────────────────────────────────
    print("\n" + "=" * 104)
    print("DÉTAIL PAR SPOT — σ médian aux heures navigables (nœuds), 9 épingles à 1 km")
    print("=" * 104)
    print(f"{'spot':30} {'zone':18} {'nav':>4} {'sans eau':>8} " +
          " ".join(f"{m:>6}" for m in METHODES))
    for s in sorted(par_spot, key=lambda x: -(x["sd_nav"]["B"] or 0)):
        vals = " ".join(f"{(s['sd_nav'][m] if s['sd_nav'][m] is not None else float('nan')):6.2f}"
                        for m in METHODES)
        print(f"{s['nom']:30} {s['zone']:18} {s['n_nav']:4d} {s['n_sans_eau']:8d} {vals}")

    # ── ÉTENDUE MAXIMALE : le pire écart observé entre deux épingles ──────────
    print("\n" + "=" * 104)
    print("PIRE CAS — étendue MAXIMALE entre deux des 9 épingles, sur les 336 heures (nœuds)")
    print("=" * 104)
    print(f"{'spot':30} " + " ".join(f"{m:>6}" for m in METHODES))
    for s in sorted(par_spot, key=lambda x: -x["rng_max"]["B"])[:12]:
        print(f"{s['nom']:30} " + " ".join(f"{s['rng_max'][m]:6.2f}" for m in METHODES))
    print(f"\n{'MOYENNE sur les 26 spots':30} " +
          " ".join(f"{st.mean(s['rng_max'][m] for s in par_spot):6.2f}" for m in METHODES))

    # ── SPOTS OÙ LE MODÈLE EXPRIME QUELQUE CHOSE ──────────────────────────────
    # 16 spots /26 ont σ = 0 pour TOUTES les méthodes : les 9 épingles et leurs croix
    # tombent dans UNE SEULE maille (ARPEGE monde, 25 km, hors domaine AROME). Aucune
    # méthode ne peut y être distinguée d'une autre — les garder dans la moyenne dilue
    # le classement d'un facteur ~2,6 sans rien apprendre.
    disc = [s for s in par_spot if (s["sd_nav"]["B"] or 0) > 1e-9]
    print("\n" + "=" * 104)
    print(f"RESTREINT AUX {len(disc)} SPOTS DISCRIMINANTS (σ_B > 0 : la croix franchit ≥ 2 mailles)")
    print(f"  les {len(par_spot)-len(disc)} autres ont σ = 0 pour les SIX méthodes — une seule maille de modèle")
    print("=" * 104)
    print(f"{'méthode':38} {'σ méd':>7} {'étend.':>7} {'σ rel':>7} {'rang':>5}")
    cl2 = sorted((st.mean(s["sd_nav"][m] for s in disc), m) for m in METHODES)
    for i, (v, m) in enumerate(cl2, 1):
        rg  = st.mean(s["rng_nav"][m] for s in disc)
        rel = st.mean(s["rel_nav"][m] for s in disc)
        print(f"{NOMS[m]:38} {v:7.3f} {rg:7.3f} {rel:6.1f}% {i:5d}")
    print("\n  Rang : " + "  >  ".join(m for _, m in cl2))
    d = [s["sd_nav"]["C"] - s["sd_nav"]["B"] for s in disc]
    random.seed(20260817)
    boots = [st.mean([random.choice(d) for _ in range(len(d))]) for _ in range(20000)]
    print(f"\n  C − B = {st.mean(d):+.3f} kn  IC95 [{pct(boots,0.025):+.3f} ; {pct(boots,0.975):+.3f}]"
          f"  · P(C plus stable) = {100*sum(1 for b in boots if b<0)/len(boots):.1f} %"
          f"  · {sum(1 for x in d if x<-1e-9)} mieux / {sum(1 for x in d if x>1e-9)} pire")

    # ── CE QUE LA STABILITÉ COÛTE : le NIVEAU affiché ─────────────────────────
    # Une méthode PARFAITEMENT stable existe : renvoyer une constante. La stabilité seule
    # ne suffit donc pas — il faut regarder ce que chaque méthode fait dire à l'app.
    print("\n" + "=" * 104)
    print("CE QUE LA STABILITÉ COÛTE — décalage du NIVEAU affiché par rapport à B (nœuds)")
    print("  (une constante aurait σ = 0 : la stabilité seule ne prouve rien)")
    print("=" * 104)
    print(f"{'méthode':38} {'moyen':>8} {'médian':>8} {'max spot':>9}  spot du max")
    for m in METHODES:
        dn = [s["niveau"][m] - s["niveau"]["B"] for s in par_spot]
        i = max(range(len(dn)), key=lambda k: abs(dn[k]))
        print(f"{NOMS[m]:38} {st.mean(dn):+8.3f} {median(dn):+8.3f} {dn[i]:+9.3f}  {par_spot[i]['nom']}")

    # ── L'ANOMALIE D'ORIGINE : Andernos (bassin abrité) vs Lacanau (front de mer) ──
    print("\n" + "=" * 104)
    print("L'ANOMALIE D'ORIGINE — Andernos (bassin abrité) doit-il rester au-dessus de Lacanau ?")
    print("=" * 104)
    a = next((s for s in par_spot if s["nom"].startswith("Andernos")), None)
    l = next((s for s in par_spot if s["nom"].startswith("Lacanau")), None)
    if a and l:
        print(f"{'méthode':38} {'Andernos':>9} {'Lacanau':>9} {'écart':>8}")
        for m in METHODES:
            print(f"{NOMS[m]:38} {a['niveau'][m]:9.2f} {l['niveau'][m]:9.2f} "
                  f"{a['niveau'][m]-l['niveau'][m]:+8.2f}")
        print("  écart > 0 = le bassin abrité affiche PLUS de vent que le front de mer atlantique.")

    json.dump(par_spot, open(os.path.join(HERE, "resultats_stabilite_epingle_agrege.json"), "w"),
              ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()

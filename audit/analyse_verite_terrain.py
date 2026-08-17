#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
VOLET 4 — LA JUSTESSE. Les 6 méthodes d'échantillonnage contre le vent RÉELLEMENT MESURÉ.

Le volet 3 les a classées par STABILITÉ au pointage. Une méthode stable mais FAUSSE serait
pire que la méthode actuelle : ce volet-ci mesure la justesse.

⚠️ LE BIAIS DE VALIDATION EST LE SUJET, PAS UNE NOTE DE BAS DE PAGE.
   Un anémomètre METAR est sur un aérodrome, donc sur la TERRE : il mesure un vent freiné
   par la rugosité terrestre. Toute méthode qui lit les mailles TERRE lui ressemblera
   davantage — non parce qu'elle décrit mieux le spot, mais parce qu'elle décrit mieux
   L'AÉRODROME. Une bouée de pleine mer commet l'erreur symétrique.
   Les trois familles sont donc traitées SÉPARÉMENT et jamais agrégées :
     1. METAR   — capteur sur TERRE          → favorise A / B / F
     2. BOUÉES  — capteur en PLEINE MER      → favorise C / D / E
     3. LAISSE DE MER — jetée, phare, îlot   → la seule famille dont la pose ressemble
        à celle d'un spot de glisse, et la seule qui n'a pas de favori évident.

Usage : python3 audit/analyse_verite_terrain.py [modele]
        modele ∈ meteofrance_seamless (défaut) | icon_seamless | gfs_seamless
"""
import json, math, os, random, sys
from collections import defaultdict

ICI = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(ICI, "resultats_verite_terrain.json")

METHODES = ["A", "B", "C", "D", "E", "F"]
LIBELLE = {
    "A": "A  centre seul",
    "B": "B  MEDIANE des 5 (ACTUEL)",
    "C": "C  mediane des mailles EAU",
    "D": "D  moyenne des mailles EAU",
    "E": "E  maximum des 5",
    "F": "F  mediane ponderee 1/(1+|elev|)",
}
Z0_MER = 0.0002          # longueur de rugosité en mer ouverte (m)
MIN_H = 150              # heures minimales pour retenir une station


# ── réduction : les 6 méthodes ───────────────────────────────────────────────
def mediane(v):
    s = sorted(v); n = len(s)
    return s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2


def mediane_ponderee(v, w):
    tot = sum(w)
    if tot <= 0:
        return mediane(v)
    cum = 0.0
    for val, p in sorted(zip(v, w)):
        cum += p
        if cum >= tot / 2:
            return val
    return max(v)


def reduire(vals, elevs):
    """vals = 5 vitesses (centre, N, S, E, O) ; elevs = 5 élévations du MNT."""
    eau = [v for v, e in zip(vals, elevs) if e == 0.0]
    m_b = mediane(vals)
    return {"A": vals[0], "B": m_b,
            "C": mediane(eau) if eau else m_b,             # repli documenté → B
            "D": sum(eau) / len(eau) if eau else m_b,
            "E": max(vals),
            "F": mediane_ponderee(vals, [1.0 / (1.0 + abs(e)) for e in elevs])}


def facteur_10m(z, z0=Z0_MER):
    """Loi logarithmique : ramène un vent mesuré à z mètres au niveau 10 m."""
    if z is None or z <= 0.5 or abs(z - 10.0) < 0.01:
        return 1.0
    return math.log(10.0 / z0) / math.log(z / z0)


def hauteur_utile(st):
    """Hauteur de l'anémomètre AU-DESSUS DE L'EAU.

    NDBC additionne « site elevation » à la hauteur du mât. Sur un lac, cette élévation
    contient l'ALTITUDE DU LAC (183 m pour le Supérieur) : la retirer est indispensable,
    sans quoi la correction logarithmique amputerait la mesure d'un tiers.
    """
    h = st.get("hauteur_anemo_m")
    if h is None:
        return None
    if st.get("genre") == "lac":
        h -= max(e for e in st["elevations"])
    return h


# ── appariement mesure / modèle ──────────────────────────────────────────────
def couples(st, modele, corrige_hauteur, seuil_kn=0.0):
    series = st["vent_modele"].get(modele)
    if not series or len(series) != 5:
        return []
    elevs, obs = st["elevations"], st["obs_kn"]
    f = facteur_10m(hauteur_utile(st)) if corrige_hauteur else 1.0
    out = []
    for i, t in enumerate(st["times"]):
        o = obs.get(t[:13])
        if o is None:
            continue
        o *= f
        if o < seuil_kn:
            continue
        vals = [series[c][i] for c in range(5)]
        if any(v is None for v in vals):
            continue
        out.append((o, reduire(vals, elevs)))
    return out


def metriques(paires):
    r = {}
    for m in METHODES:
        errs = [p[m] - o for o, p in paires]      # >0 = le modèle SURESTIME
        n = len(errs)
        if not n:
            continue
        r[m] = {"n": n, "biais": sum(errs) / n,
                "rmse": math.sqrt(sum(e * e for e in errs) / n),
                "mae": sum(abs(e) for e in errs) / n,
                "obs": sum(o for o, _ in paires) / n}
    return r


def part_c_differe(paires):
    """Part des heures où C rend une valeur DIFFÉRENTE de B (sinon la station ne dit rien)."""
    if not paires:
        return 0.0
    return sum(1 for _, p in paires if abs(p["C"] - p["B"]) > 1e-9) / len(paires)


def mailles_distinctes(st, modele):
    s = st["vent_modele"].get(modele) or []
    return len({tuple(x if x is not None else -999 for x in serie[:200]) for serie in s})


# ── bootstrap ────────────────────────────────────────────────────────────────
def boot(par_station, m1, m2, cle="rmse", tirages=20000, graine=20260817):
    noms = [k for k, v in par_station.items() if m1 in v and m2 in v]
    if len(noms) < 3:
        return None
    rng = random.Random(graine)
    val = lambda ns, m: sum(par_station[n][m][cle] for n in ns) / len(ns)
    obs = val(noms, m1) - val(noms, m2)
    ech = []
    for _ in range(tirages):
        pick = [noms[rng.randrange(len(noms))] for _ in noms]
        ech.append(val(pick, m1) - val(pick, m2))
    ech.sort()
    return obs, ech[int(.025 * tirages)], ech[int(.975 * tirages)], \
        sum(1 for e in ech if e < 0) / tirages


def boot_blocs(blocs, m1, m2, tirages=4000, graine=7):
    """Bootstrap par BLOCS jour × station sur la RMSE poolée (autocorrélation horaire)."""
    if not blocs:
        return None
    rng = random.Random(graine)

    def rmse(bs, m):
        s = n = 0
        for b in bs:
            for o, p in b:
                e = p[m] - o; s += e * e; n += 1
        return math.sqrt(s / n) if n else float("nan")

    obs = rmse(blocs, m1) - rmse(blocs, m2)
    ech = sorted(rmse([blocs[rng.randrange(len(blocs))] for _ in blocs], m1)
                 - rmse([blocs[rng.randrange(len(blocs))] for _ in blocs], m2)
                 for _ in range(tirages))
    return obs, ech[int(.025 * tirages)], ech[int(.975 * tirages)], \
        sum(1 for e in ech if e < 0) / tirages


# ── rendu ────────────────────────────────────────────────────────────────────
def prepare(stations, modele, corr, seuil):
    par, tout, blocs, diff = {}, [], [], {}
    for st in stations:
        p = couples(st, modele, corr, seuil)
        if len(p) < MIN_H:
            continue
        par[st["nom"]] = metriques(p)
        diff[st["nom"]] = part_c_differe(p)
        tout += p
        for d in range(0, len(p), 24):
            if len(p[d:d + 24]) >= 6:
                blocs.append(p[d:d + 24])
    return par, tout, blocs, diff


def bilan(titre, stations, modele, corr=False, seuil=0.0, note="", ecart=True,
          ref="B", detail=False):
    par, tout, blocs, diff = prepare(stations, modele, corr, seuil)
    print("\n" + "=" * 100)
    print(titre)
    if note:
        print(note)
    if not par:
        print("  aucune station exploitable"); return None
    ndis = sum(1 for v in diff.values() if v >= 0.05)
    print(f"  {len(par)} stations · {len(tout)} couples heure×station · modele {modele}"
          + (f" · mesure ≥ {seuil:g} kn" if seuil else ""))
    print(f"  dont {ndis} stations DISCRIMINANTES (C differe de B sur ≥5 % des heures) ; "
          f"sur les {len(par)-ndis} autres C ≡ B par construction")
    print("=" * 100)
    poole = metriques(tout)
    moy = {m: {c: sum(v[m][c] for v in par.values()) / len(par)
               for c in ("rmse", "biais", "mae")} for m in METHODES}
    gagne = defaultdict(int)
    for v in par.values():
        gagne[min(METHODES, key=lambda m: v[m]["rmse"])] += 1
    print(f"{'':34}{'——— poole (toutes heures) ———':^28}{'— 1 station = 1 voix —':^30}")
    print(f"{'methode':34}{'biais':>8}{'RMSE':>8}{'MAE':>8}  |{'RMSE':>8}{'biais':>9}"
          f"{'MAE':>8}{'gagne':>7}")
    for m in sorted(METHODES, key=lambda m: moy[m]["rmse"]):
        print(f"{LIBELLE[m]:34}{poole[m]['biais']:+8.2f}{poole[m]['rmse']:8.2f}"
              f"{poole[m]['mae']:8.2f}  |{moy[m]['rmse']:8.2f}{moy[m]['biais']:+9.2f}"
              f"{moy[m]['mae']:8.2f}{gagne[m]:7d}")
    print(f"  vent mesure moyen : {poole['B']['obs']:.2f} kn")
    if ecart:
        print(f"\n  ECART A {ref} sur la RMSE (negatif = MEILLEUR) — bootstrap 20 000 "
              f"tirages sur les stations, 1 station = 1 voix")
        for m in METHODES:
            if m == ref:
                continue
            r = boot(par, m, ref)
            if not r:
                continue
            d, lo, hi, p = r
            v = ("MEILLEURE (significatif)" if hi < 0 else
                 "PIRE (significatif)" if lo > 0 else "non significatif")
            print(f"    {m} − {ref} : {d:+6.3f} kn  IC95 [{lo:+6.3f} ; {hi:+6.3f}]  "
                  f"P(meilleure)={p*100:5.1f} %   {v}")
        r = boot_blocs(blocs, "C", ref)
        if r:
            d, lo, hi, p = r
            print(f"    C − {ref} par BLOCS jour×station (RMSE poolee) : {d:+6.3f} kn  "
                  f"IC95 [{lo:+6.3f} ; {hi:+6.3f}]  P={p*100:.1f} %")
    if detail:
        print(f"\n  {'station':28}{'eau/5':>6}{'obs':>7}{'RMSE B':>9}{'RMSE C':>9}"
              f"{'C−B':>8}{'biais B':>9}{'biais C':>9}")
        idx = {st["nom"]: st for st in stations}
        for n in sorted(par, key=lambda n: par[n]["C"]["rmse"] - par[n]["B"]["rmse"]):
            if diff[n] < 0.05:
                continue
            v, st = par[n], idx[n]
            ne = sum(1 for e in st["elevations"] if e == 0.0)
            print(f"  {n[:28]:28}{ne:>6}{v['B']['obs']:7.1f}{v['B']['rmse']:9.2f}"
                  f"{v['C']['rmse']:9.2f}{v['C']['rmse']-v['B']['rmse']:+8.2f}"
                  f"{v['B']['biais']:+9.2f}{v['C']['biais']:+9.2f}")
    return par


def main():
    modele = sys.argv[1] if len(sys.argv) > 1 else "meteofrance_seamless"
    d = json.load(open(SRC))
    metar = d["metar"]
    ocean = [b for b in d["bouees"] if b["genre"] == "ocean"]
    laisse = [b for b in d["bouees"] if b["genre"] == "laisse"]
    lacs = [b for b in d["bouees"] if b["genre"] == "lac"]

    def eau(st):
        return sum(1 for e in st["elevations"] if e == 0.0)

    print("#" * 100)
    print("# VOLET 4 — JUSTESSE DES 6 METHODES CONTRE LE VENT MESURE")
    print("# Trois familles de verite terrain, JAMAIS agregees : chacune est biaisee en")
    print("# faveur des methodes qui ressemblent au sol sur lequel son capteur est pose.")
    print("#" * 100)
    pays = defaultdict(int)
    for s in metar:
        pays[s["pays"]] += 1
    print(f"\nMETAR  : {len(metar)} stations cotieres, {len(pays)} pays — "
          + ", ".join(f"{k}:{v}" for k, v in sorted(pays.items()))
          + f"   (France {pays['FR']}/{len(metar)} = {pays['FR']/len(metar)*100:.0f} %)")
    print(f"BOUEES : {len(ocean)} bouees oceaniques NDBC (8–45 NM du trait de cote)")
    print(f"LAISSE : {len(laisse)} capteurs C-MAN / maregraphes a la laisse de mer "
          f"(jetee, phare, ilot) — dont 1 aux Bahamas")
    print(f"LACS   : {len(lacs)} (controle, angle mort connu de « elevation == 0 »)")
    print(f"Fenetre : 21 jours, 2026-07-27 → 2026-08-16 UTC")

    # ═══ famille 1 : METAR ═══════════════════════════════════════════════════
    bilan("FAMILLE 1 — METAR (anemometre SUR TERRE, aerodrome, 10 m)", metar, modele,
          note="  ⚠️ BIAIS : favorise mecaniquement A/B/F (mailles terre), penalise C/D/E.",
          detail=True)
    bilan("FAMILLE 1 bis — METAR, heures NAVIGABLES (mesure ≥ 8 kn)", metar, modele,
          seuil=8.0, ecart=False)
    bilan("FAMILLE 1 ter — METAR, seules les stations dont la croix TOUCHE l'eau "
          "(≥1 maille a 0)", [s for s in metar if eau(s) >= 1], modele,
          note="  Retire les 19 stations ou C ≡ B par repli : le reste est le vrai test.")

    # ═══ famille 2 : bouées ══════════════════════════════════════════════════
    bilan("FAMILLE 2 — BOUEES NDBC oceaniques, vent RAMENE A 10 m (log-law z0=2e-4)",
          ocean, modele, corr=True,
          note="  ⚠️ BIAIS : favorise mecaniquement C/D/E, penalise A/B/F.\n"
               "  ⚠️ Les 5 mailles y sont TOUTES a elevation 0 : C ≡ B ≡ F par identite.\n"
               "     Cette famille ne peut donc PAS arbitrer C contre B — seulement A, D, E.")
    bilan("FAMILLE 2 bis — BOUEES, vent BRUT non ramene a 10 m", ocean, modele,
          note="  Controle : l'anemometre est a 3,1–4,1 m. Sans correction la mesure est\n"
               "  SOUS le vent 10 m, et toute methode qui rend une valeur basse gagne a tort.",
          ecart=False)
    bilan("FAMILLE 2 ter — BOUEES, heures NAVIGABLES (≥ 8 kn, 10 m)", ocean, modele,
          corr=True, seuil=8.0, ecart=False)

    # ═══ famille 3 : laisse de mer ═══════════════════════════════════════════
    bilan("FAMILLE 3 — LAISSE DE MER (jetee, phare, ilot) — vent ramene a 10 m",
          laisse, modele, corr=True,
          note="  La seule famille dont la pose du capteur ressemble a celle d'un spot :\n"
               "  a l'interface, la ou la croix de 2 km enjambe reellement le trait de cote.",
          detail=True)
    dis = [s for s in laisse if 1 <= eau(s) <= 4]
    bilan("FAMILLE 3 bis — LAISSE DE MER, croix MIXTE seulement (1 a 4 mailles d'eau)",
          dis, modele, corr=True,
          note="  Le coeur du test : ici et seulement ici, C peut differer de B.")
    bas = [s for s in laisse if (s.get("hauteur_anemo_m") or 0) <= 25]
    bilan("FAMILLE 3 ter — LAISSE DE MER, anemometres ≤ 25 m uniquement",
          bas, modele, corr=True,
          note="  Controle de la correction de hauteur : un mat de phare a 39–53 m est mal\n"
               "  decrit par une loi logarithmique marine (distorsion d'ecoulement).",
          ecart=False)
    bilan("FAMILLE 3 quater — LAISSE DE MER, heures NAVIGABLES (≥ 8 kn)", laisse, modele,
          corr=True, seuil=8.0, ecart=False)

    if lacs:
        bilan("CONTROLE — GRANDS LACS (eau douce en altitude : « elevation == 0 » y est "
              "FAUX par construction)", lacs, modele, corr=True, ecart=False)

    # ═══ stratification : la marinité décide-t-elle du classement ? ══════════
    print("\n" + "=" * 100)
    print("LE TEST DU BIAIS DE VALIDATION — l'avantage de C suit-il la MARINITE du capteur ?")
    print("Si C gagne d'autant plus que le capteur est entoure d'eau, alors le classement")
    print("mesure OU L'ON A POSE L'ANEMOMETRE, pas la justesse de la methode.")
    print("=" * 100)
    print(f"  {'famille':16}{'eau/5':>6}{'stat.':>6}{'obs kn':>8}{'RMSE B':>9}{'RMSE C':>9}"
          f"{'C−B':>9}{'biais B':>9}{'biais C':>9}")
    pts = []
    for nomf, grp, corr in (("METAR", metar, False), ("LAISSE", laisse, True),
                            ("BOUEES", ocean, True)):
        seaux = defaultdict(list)
        for st in grp:
            seaux[eau(st)].append(st)
        for ne in sorted(seaux):
            par, tout, _, _ = prepare(seaux[ne], modele, corr, 0.0)
            if not par:
                continue
            g = lambda m, c: sum(v[m][c] for v in par.values()) / len(par)
            print(f"  {nomf:16}{ne:>6}{len(par):>6}{g('B','obs'):8.1f}{g('B','rmse'):9.2f}"
                  f"{g('C','rmse'):9.2f}{g('C','rmse')-g('B','rmse'):+9.3f}"
                  f"{g('B','biais'):+9.2f}{g('C','biais'):+9.2f}")
            if ne < 5:
                pts.append((nomf, ne, g('C', 'rmse') - g('B', 'rmse'), len(par)))

    # corrélation station par station entre marinité et gain de C
    print("\n  CORRELATION station par station : part de mailles EAU  ↔  (RMSE C − RMSE B)")
    for nomf, grp, corr in (("METAR", metar, False), ("LAISSE", laisse, True)):
        par, _, _, diff = prepare(grp, modele, corr, 0.0)
        idx = {st["nom"]: st for st in grp}
        xs, ys = [], []
        for n, v in par.items():
            if diff[n] < 0.05:
                continue
            xs.append(eau(idx[n]) / 5.0)
            ys.append(v["C"]["rmse"] - v["B"]["rmse"])
        if len(xs) < 4:
            continue
        mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
        num = sum((a - mx) * (b - my) for a, b in zip(xs, ys))
        den = math.sqrt(sum((a - mx) ** 2 for a in xs) * sum((b - my) ** 2 for b in ys))
        r = num / den if den else float("nan")
        print(f"    {nomf:8} n={len(xs):3d}  r = {r:+.3f}   "
              f"(C−B moyen {my:+.3f} kn, part d'eau moyenne {mx:.2f})")

    # ═══ résolution effective ════════════════════════════════════════════════
    print("\n" + "=" * 100)
    print("RESOLUTION EFFECTIVE — combien de mailles de MODELE la croix de 2 km traverse-t-elle ?")
    print("Une croix qui ne voit QU'UNE maille rend les 6 methodes strictement identiques :")
    print("aucune arithmetique sur 5 points ne cree l'information que le modele n'a pas produite.")
    print("=" * 100)
    for mdl in ("meteofrance_seamless", "icon_seamless", "gfs_seamless"):
        print(f"  — {mdl}")
        for nomf, grp in (("METAR", metar), ("LAISSE", laisse), ("BOUEES", ocean)):
            c = defaultdict(int)
            for st in grp:
                c[mailles_distinctes(st, mdl)] += 1
            tot = sum(c.values()); une = c.get(1, 0)
            print(f"      {nomf:8} " + " ".join(f"{k}:{v}" for k, v in sorted(c.items()))
                  + f"   → {une}/{tot} ({une/tot*100:.0f} %) indiscernables")

    # ═══ hors de France, leave-one-country-out ══════════════════════════════
    bilan("CONTROLE HORS DE FRANCE — METAR, France retiree",
          [s for s in metar if s["pays"] != "FR"], modele,
          note="  Regle du depot : un gain qui ne tient pas hors de France est une "
               "regression deguisee.")
    print("\n  LEAVE-ONE-COUNTRY-OUT (METAR) — C−B sur la RMSE moyenne")
    for p in sorted({s["pays"] for s in metar}):
        par, _, _, _ = prepare([s for s in metar if s["pays"] != p], modele, False, 0.0)
        if not par:
            continue
        dd = (sum(v["C"]["rmse"] for v in par.values())
              - sum(v["B"]["rmse"] for v in par.values())) / len(par)
        print(f"    sans {p} (n={len(par):2d}) : C−B = {dd:+.3f} kn")
    print("\n  PAR PAYS (METAR) — C−B sur la RMSE moyenne")
    for p in sorted({s["pays"] for s in metar}):
        par, _, _, _ = prepare([s for s in metar if s["pays"] == p], modele, False, 0.0)
        if not par:
            continue
        dd = (sum(v["C"]["rmse"] for v in par.values())
              - sum(v["B"]["rmse"] for v in par.values())) / len(par)
        rb = sum(v["B"]["rmse"] for v in par.values()) / len(par)
        print(f"    {p} (n={len(par):2d}) : RMSE B {rb:5.2f}   C−B = {dd:+.3f} kn")


if __name__ == "__main__":
    main()

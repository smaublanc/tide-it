#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ANALYSE — l'ordre physique est-il rétabli ?

Pour chaque paire et chaque méthode d'échantillonnage (A..F) :
  · part des heures DIURNES où l'ABRITÉ dépasse le FRONT DE MER,
  · idem en ne gardant que les heures VENTÉES (front > 15 nds, puis > 20, puis > 25),
  · écart médian front − abrité (nds), par régime.

Le filtre « venté » est appliqué de DEUX façons :
  (a) « propre »  : le seuil porte sur la valeur que la méthode elle-même affiche.
      C'est le monde de l'utilisateur : il voit 15 nds parce que la méthode le dit.
  (b) « commune » : le seuil porte sur la valeur de la méthode B (l'actuelle), donc le
      MÊME jeu d'heures pour les six méthodes. Sans ça, une méthode qui gonfle le vent
      change l'échantillon et la comparaison ne veut plus rien dire.

DIURNE = élévation solaire > 0 au point du spot (NOAA, calculée ici, aucune dépendance
réseau, valable partout). Les horodatages de l'API sont en UTC (utc_offset_seconds = 0).

Bootstrap par BLOCS DE JOURS (les heures d'une même journée ne sont pas indépendantes :
un régime de vent dure). 20 000 tirages.
"""
import json, math, os, random, statistics as st

BASE = os.path.dirname(os.path.abspath(__file__))
SRC  = os.path.join(BASE, "resultats_paires_abritees.json")
OUT  = os.path.join(BASE, "resultats_paires_abritees_agrege.json")

METHODES = ["A", "B", "C", "D", "E", "F"]
LIBELLE = {
    "A": "A  centre seul (avant le voisinage)",
    "B": "B  MEDIANE des 5 points (ACTUEL)",
    "C": "C  mediane des mailles EAU (elev==0)",
    "D": "D  moyenne des mailles EAU",
    "E": "E  maximum des 5 points",
    "F": "F  mediane ponderee 1/(1+|elev|)",
}


# ---------------------------------------------------------------- soleil (NOAA)
def elevation_solaire(lat, lon, iso):
    """Élévation du soleil en degrés. `iso` = 'YYYY-MM-DDTHH:MM' en UTC."""
    d, h = iso.split("T")
    y, mo, dd = (int(x) for x in d.split("-"))
    hh, mm = (int(x) for x in h.split(":"))
    # jour de l'année
    cum = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
    bis = 1 if (y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)) and mo > 2 else 0
    doy = cum[mo - 1] + dd + bis
    g = 2 * math.pi / 365.0 * (doy - 1 + (hh - 12) / 24.0)
    eq = 229.18 * (0.000075 + 0.001868 * math.cos(g) - 0.032077 * math.sin(g)
                   - 0.014615 * math.cos(2 * g) - 0.040849 * math.sin(2 * g))
    dec = (0.006918 - 0.399912 * math.cos(g) + 0.070257 * math.sin(g)
           - 0.006758 * math.cos(2 * g) + 0.000907 * math.sin(2 * g)
           - 0.002697 * math.cos(3 * g) + 0.00148 * math.sin(3 * g))
    tst = hh * 60 + mm + eq + 4 * lon
    ha = math.radians(tst / 4.0 - 180.0)
    la = math.radians(lat)
    cz = math.sin(la) * math.sin(dec) + math.cos(la) * math.cos(dec) * math.cos(ha)
    return 90.0 - math.degrees(math.acos(max(-1.0, min(1.0, cz))))


# ---------------------------------------------------------------- réductions
def mediane_ponderee(vals, poids):
    pairs = sorted(zip(vals, poids))
    tot = sum(poids)
    if tot <= 0:
        return st.median(vals)
    c = 0.0
    for v, p in pairs:
        c += p
        if c >= tot / 2.0:
            return v
    return pairs[-1][0]


def valeurs_methodes(v5, elevs):
    """v5 = 5 vitesses (centre, N, S, E, O) ; elevs = 5 élévations. → dict méthode -> valeur."""
    eau = [x for x, e in zip(v5, elevs) if e is not None and e <= 0.0]
    med = st.median(v5)
    return {
        "A": v5[0],
        "B": med,
        "C": st.median(eau) if eau else med,          # repli documenté → B
        "D": sum(eau) / len(eau) if eau else med,     # repli documenté → B
        "E": max(v5),
        "F": mediane_ponderee(v5, [1.0 / (1.0 + abs(e if e is not None else 0.0)) for e in elevs]),
    }


def serie_methodes(spot):
    """→ (times, {methode: [valeur par heure ou None]}, n_repli)"""
    vent, elevs, times = spot["vent"], spot["elevations"], spot["times"]
    out = {m: [] for m in METHODES}
    repli = 0
    a_eau = any(e is not None and e <= 0.0 for e in elevs)
    for i in range(len(times)):
        v5 = [s[i] if i < len(s) else None for s in vent]
        if any(x is None for x in v5):
            for m in METHODES:
                out[m].append(None)
            continue
        if not a_eau:
            repli += 1
        d = valeurs_methodes(v5, elevs)
        for m in METHODES:
            out[m].append(d[m])
    return times, out, repli


# ---------------------------------------------------------------- bootstrap
def boot_diff(jours_a, jours_b, n=20000, seed=7):
    """IC95 de (pct_a − pct_b) par rééchantillonnage des JOURS (blocs)."""
    rnd = random.Random(seed)
    idx = list(range(len(jours_a)))
    if not idx:
        return None
    diffs = []
    for _ in range(n):
        pick = [rnd.choice(idx) for _ in idx]
        na = sum(jours_a[i][0] for i in pick); da = sum(jours_a[i][1] for i in pick)
        nb = sum(jours_b[i][0] for i in pick); db = sum(jours_b[i][1] for i in pick)
        if da == 0 or db == 0:
            continue
        diffs.append(100.0 * na / da - 100.0 * nb / db)
    if not diffs:
        return None
    diffs.sort()
    return (diffs[int(0.025 * len(diffs))], diffs[int(0.975 * len(diffs))],
            100.0 * sum(1 for d in diffs if d < 0) / len(diffs))


# ---------------------------------------------------------------- coeur
def analyse():
    src = json.load(open(SRC))
    rapport = {}

    for fenetre, paires in src.items():
        rapport[fenetre] = {}
        for nom, p in paires.items():
            tF, sF, repliF = serie_methodes(p["front"])
            tA, sA, repliA = serie_methodes(p["abrite"])
            assert tF == tA, nom
            latF, lonF = p["front"]["lat"], p["front"]["lon"]

            diurne = [elevation_solaire(latF, lonF, t) > 0 for t in tF]
            jour = [t[:10] for t in tF]

            res = {"n_heures": len(tF),
                   "n_diurnes": sum(diurne),
                   "repli_front_h": repliF, "repli_abrite_h": repliA,
                   "elev_front": p["front"]["elevations"],
                   "elev_abrite": p["abrite"]["elevations"],
                   "methodes": {}}

            # jeu d'heures ventées COMMUN, défini par la méthode B (référence)
            for m in METHODES:
                m_res = {}
                for etiquette, seuil, ref in (
                        ("tous_vents",   None, None),
                        ("vente_15_propre", 15.0, m),   ("vente_15_commun", 15.0, "B"),
                        ("vente_20_commun", 20.0, "B"), ("vente_25_commun", 25.0, "B")):
                    par_jour = {}
                    inversions, total, ecarts = 0, 0, []
                    for i in range(len(tF)):
                        if not diurne[i]:
                            continue
                        f, a = sF[m][i], sA[m][i]
                        if f is None or a is None:
                            continue
                        if seuil is not None:
                            r = sF[ref][i]
                            if r is None or r <= seuil:
                                continue
                        total += 1
                        inv = 1 if a > f else 0
                        inversions += inv
                        ecarts.append(f - a)
                        d = par_jour.setdefault(jour[i], [0, 0])
                        d[0] += inv; d[1] += 1
                    m_res[etiquette] = {
                        "n": total,
                        "pct_inversion": (100.0 * inversions / total) if total else None,
                        "ecart_median_front_moins_abrite": (round(st.median(ecarts), 2)
                                                            if ecarts else None),
                        "ecart_moyen_front_moins_abrite": (round(sum(ecarts) / len(ecarts), 2)
                                                           if ecarts else None),
                        "_jours": list(par_jour.values()),
                    }
                # niveau moyen affiché (contrôle de biais : une méthode peut « réparer »
                # l'ordre en gonflant tout le monde — c'est le décalage vers le large refusé)
                vf = [x for x in sF[m] if x is not None]
                va = [x for x in sA[m] if x is not None]
                m_res["niveau_front"]  = round(sum(vf) / len(vf), 2) if vf else None
                m_res["niveau_abrite"] = round(sum(va) / len(va), 2) if va else None
                res["methodes"][m] = m_res

            # IC95 de l'écart à B, sur le jeu d'heures COMMUN
            for m in METHODES:
                for etiquette in ("tous_vents", "vente_15_commun", "vente_20_commun"):
                    b = boot_diff(res["methodes"][m][etiquette]["_jours"],
                                  res["methodes"]["B"][etiquette]["_jours"])
                    res["methodes"][m][etiquette]["ic95_vs_B"] = (
                        [round(b[0], 2), round(b[1], 2), round(b[2], 1)] if b else None)
            rapport[fenetre][nom] = res

    json.dump(rapport, open(OUT, "w"), ensure_ascii=False, indent=1)
    return rapport


# ---------------------------------------------------------------- affichage
def tableau(rapport):
    for fenetre in ("ete", "hiver"):
        if fenetre not in rapport:
            continue
        print("=" * 104)
        print(f"FENÊTRE : {fenetre.upper()}")
        print("=" * 104)
        for etiquette, titre in (("tous_vents", "TOUTES HEURES DIURNES"),
                                 ("vente_15_commun", "DIURNES ET VENTÉES (front B > 15 nds)"),
                                 ("vente_20_commun", "DIURNES ET VENTÉES (front B > 20 nds)"),
                                 ("vente_25_commun", "DIURNES ET VENTÉES (front B > 25 nds)")):
            print(f"\n--- % d'heures où l'ABRITÉ dépasse le FRONT DE MER — {titre} ---")
            print(f"{'paire':38s} {'n':>5s} " + " ".join(f"{m:>7s}" for m in METHODES))
            moy = {m: [] for m in METHODES}
            for nom, r in rapport[fenetre].items():
                n = r["methodes"]["B"][etiquette]["n"]
                cells = []
                for m in METHODES:
                    v = r["methodes"][m][etiquette]["pct_inversion"]
                    cells.append(f"{v:7.1f}" if v is not None else "      -")
                    if v is not None and n >= 20:
                        moy[m].append(v)
                print(f"{nom[:38]:38s} {n:5d} " + " ".join(cells))
            print(f"{'MOYENNE (paires n>=20)':38s} {'':5s} " +
                  " ".join(f"{(sum(moy[m])/len(moy[m])):7.1f}" if moy[m] else "      -"
                           for m in METHODES))


if __name__ == "__main__":
    tableau(analyse())

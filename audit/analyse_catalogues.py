#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AMPLEUR du défaut de rugosité SUR LES CATALOGUES RÉELS de l'app (4 326 entrées).

Combien d'entrées que l'utilisateur peut réellement ouvrir lisent le vent d'une maille
de TERRE ? Trois grandeurs distinctes, dans cet ordre de gravité :

  1. ÉPINGLE SUR TERRE  — le point du spot a une élévation != 0 : l'app lit là le vent
     d'une forêt, d'une dune ou d'un polder pour un point d'eau.
  2. CROIX MIXTE        — la croix de 2 km contient à la fois de l'eau et de la terre.
     C'est la condition NÉCESSAIRE pour qu'un filtre « ne garder que l'eau » change quoi
     que ce soit ; une croix tout-terre n'est PAS réparable par le voisinage.
  3. ÉTENDUE DE VENT    — ce que le MODÈLE exprime réellement sur la croix. Une croix
     mixte dont les 5 points tombent dans une seule maille de modèle a une étendue
     identiquement nulle : l'exposition existe, l'expression non.

DEUX MNT, ET IL FAUT SAVOIR LEQUEL PARLE :
  • Open-Meteo (`audit/cache_elevation_catalogues.json`) est celui que l'APP interroge —
    c'est la seule mesure qui décrive vraiment ce que voit l'utilisateur. Son endpoint
    compte un appel PAR COORDONNÉE : 21 538 coordonnées dépassent le plafond journalier
    de 10 000. On l'a donc passé EXHAUSTIVEMENT sur les deux catalogues de spots
    (surf_spots 284, shom_ports 330 = 3 070 coordonnées) et sur un ÉCHANTILLON stratifié
    des deux catalogues mondiaux (ticon, noaa), dont les taux sont extrapolés par poids.
  • SRTM 90 m / ASTER 30 m (`audit/cache_srtm_tout.json`, via opentopodata.org) couvre
    les 4 326 entrées, mais ne reproduit le verdict d'Open-Meteo qu'à ~92 % : c'est un
    radar non filtré, ses pixels côtiers lisent 1 à 5 m là où Copernicus GLO-90 met 0.
    Il sert de CORROBORATION de l'ordre de grandeur, jamais de chiffre publié.

    python3 audit/analyse_catalogues.py
"""
import collections, json, math, os, sys
from statistics import median

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(BASE, "audit"))
from sonde_catalogues import toutes_les_entrees
from echantillon_catalogues import continent_of

ECH = json.load(open(os.path.join(BASE, "audit/echantillon_catalogues.json")))
TAILLES = ECH["tailles"]
ELEV = json.load(open(os.path.join(BASE, "audit/cache_elevation_catalogues.json")))
P_SRTM = os.path.join(BASE, "audit/cache_srtm_tout.json")
P_VENT = os.path.join(BASE, "audit/cache_vent_catalogues.json")
SRTM = json.load(open(P_SRTM)) if os.path.exists(P_SRTM) else {}
VENT = json.load(open(P_VENT)) if os.path.exists(P_VENT) else {}
NEIGHBOURHOOD_KM = 2.0
EXHAUSTIFS = ("surf_spots", "shom_ports")     # couverts point par point par Open-Meteo

# Lacs continentaux : l'eau y est à l'altitude de SA surface, pas à 0 — `elevation == 0`
# les classe « terre » à tort. Boîtes larges, uniquement pour ISOLER ces entrées.
LACS = [("Grands Lacs", 41.0, 49.5, -93.0, -76.0), ("Leman/Alpes", 45.5, 48.0, 5.5, 10.5),
        ("Caspienne", 36.0, 47.5, 46.0, 55.0), ("Baikal", 51.0, 56.0, 103.0, 110.0),
        ("Victoria", -3.5, 1.0, 31.0, 35.5), ("Columbia", 45.4, 46.2, -122.5, -119.0)]


def neighbourhood(lat, lon):
    """Copie exacte de MarineWeatherService.neighbourhood."""
    d_lat = NEIGHBOURHOOD_KM / 111.0
    d_lon = NEIGHBOURHOOD_KM / (111.0 * max(0.1, math.cos(math.radians(lat))))
    return [(lat, lon), (lat + d_lat, lon), (lat - d_lat, lon),
            (lat, lon + d_lon), (lat, lon - d_lon)]


def k(a, b): return f"{a:.4f},{b:.4f}"


def pct(xs, p):
    if not xs: return None
    s = sorted(xs); i = (len(s) - 1) * p / 100.0
    lo, hi = int(i), min(int(i) + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (i - lo)


def lac(lat, lon):
    for nom, a, b, c, d in LACS:
        if a <= lat <= b and c <= lon <= d: return nom
    return None


def geo(rows, elev, vent=None):
    """Décore chaque entrée de son verdict terre/eau, et de son vent si disponible."""
    out = []
    for e in rows:
        pts = [(round(a, 4), round(b, 4)) for a, b in neighbourhood(e["lat"], e["lon"])]
        ev = [elev.get(k(a, b)) for a, b in pts]
        if any(v is None for v in ev): continue
        r = dict(e)
        eau = [v == 0 for v in ev]
        r.update(elev=ev, eau=eau, lac=lac(e["lat"], e["lon"]),
                 continent=continent_of(e["lat"], e["lon"]),
                 epingle_terre=ev[0] != 0,
                 mixte=any(eau) and not all(eau),
                 aucune_eau=not any(eau),
                 mediane_sur_terre=sum(eau) < 3)   # la médiane des 5 porte sur une majorité TERRE
        if vent:
            series = [vent.get(k(a, b), {}).get("ws") for a, b in pts]
            if all(series) and len({len(s) for s in series}) == 1 and series[0]:
                ét, centre = [], []
                for h in range(len(series[0])):
                    vals = [s[h] for s in series]
                    if all(v is not None for v in vals):
                        ét.append(max(vals) - min(vals)); centre.append(vals[0])
                if ét:
                    nav = [x for x, c in zip(ét, centre) if c >= 8]
                    r.update(etendue_med=median(ét), etendue_p90=pct(ét, 90),
                             etendue_max=max(ét),
                             etendue_navigable=median(nav) if nav else None,
                             # deux points d'une même maille rendent une série IDENTIQUE
                             mailles=len({tuple(s) for s in series}))
                    # OPPOSABLE : les points EAU et les points TERRE occupent-ils des
                    # mailles de modèle DISJOINTES ? Sinon on comparerait une série avec
                    # elle-même — et un filtre « eau seule » ne peut rien changer.
                    ce = {tuple(s) for s, w in zip(series, eau) if w}
                    ct = {tuple(s) for s, w in zip(series, eau) if not w}
                    r["opposable"] = bool(ce) and bool(ct) and not (ce & ct)
                    if r["mixte"]:
                        d = [median([s[h] for s, w in zip(series, eau) if w])
                             - median([s[h] for s in series])
                             for h in range(len(series[0]))
                             if all(s[h] is not None for s in series)]
                        if d:
                            r["delta_filtre_med"] = median(d)
                            r["delta_filtre_abs_med"] = median([abs(x) for x in d])
                            r["delta_filtre_max"] = max(d, key=abs)
        out.append(r)
    return out


def taux(sel, pop):
    """Taux PONDÉRÉ : les strates n'ont pas été tirées au prorata, `_poids` rétablit
    le taux du CATALOGUE au lieu de celui du tirage."""
    den = sum(r["_poids"] for r in pop)
    return 100.0 * sum(r["_poids"] for r in pop if sel(r)) / den if den else 0.0


# ═════════════════ 1. COMPTE PRINCIPAL — le MNT que l'app interroge ═════════════════
TOUT = geo(toutes_les_entrees(), ELEV)
par_cat = collections.defaultdict(list)
for r in TOUT:
    par_cat[r["catalogue"]].append(r)
# les catalogues mondiaux ne sont couverts que par l'échantillon stratifié : on leur
# rend leurs poids d'extrapolation.
poids = {(e["catalogue"], e["id"]): e["_poids"] for e in ECH["entrees"]}
for cat in ("ticon_stations", "noaa_stations"):
    par_cat[cat] = [dict(r, _poids=poids[(cat, r["id"])]) for r in par_cat[cat]
                    if (cat, r["id"]) in poids]

print("═══ ÉPINGLE SUR TERRE / CROIX MIXTE — MNT d'Open-Meteo, celui que l'app lit ═══\n")
print(f"{'catalogue':16} {'mesuré':>7} {'total':>6} {'couverture':>11} | "
      f"{'épingle TERRE':>14} {'croix MIXTE':>13} {'0 eau (irréparable)':>20} {'médiane sur terre':>18}")
tot = collections.Counter()
lignes = {}
for cat in ("surf_spots", "shom_ports", "ticon_stations", "noaa_stations"):
    pop = par_cat[cat]
    if not pop: continue
    ep, mx = taux(lambda r: r["epingle_terre"], pop), taux(lambda r: r["mixte"], pop)
    z0, md = taux(lambda r: r["aucune_eau"], pop), taux(lambda r: r["mediane_sur_terre"], pop)
    n, T = len(pop), TAILLES[cat]
    lignes[cat] = (ep, mx, z0, md, n, T)
    mode = "exhaustif" if cat in EXHAUSTIFS else "échantillon"
    print(f"{cat:16} {n:>7} {T:>6} {mode:>11} | {ep:>13.1f}% {mx:>12.1f}% "
          f"{z0:>19.1f}% {md:>17.1f}%")
    tot["ep"] += ep / 100 * T; tot["mx"] += mx / 100 * T
    tot["z0"] += z0 / 100 * T; tot["md"] += md / 100 * T; tot["n"] += T
N = tot["n"]
print(f"{'TOTAL (4 catal.)':16} {sum(l[4] for l in lignes.values()):>7} {N:>6} {'':>11} | "
      f"{100*tot['ep']/N:>13.1f}% {100*tot['mx']/N:>12.1f}% "
      f"{100*tot['z0']/N:>19.1f}% {100*tot['md']/N:>17.1f}%")
print(f"\n→ ENTRÉES CONCERNÉES, en effectif : épingle sur TERRE {tot['ep']:.0f} / {N}   |   "
      f"croix MIXTE {tot['mx']:.0f} / {N}   |   aucune eau dans la croix {tot['z0']:.0f} / {N}")

hors = [r for r in TOUT if not r["lac"]]
lacs = [r for r in TOUT if r["lac"] and r["epingle_terre"]]
print(f"\nANGLE MORT « lac » : {len(lacs)} entrées mesurées sont sur un plan d'eau INTÉRIEUR, "
      f"dont l'altitude n'est pas 0 — `elevation == 0` les compte « terre » à tort.")
for nom, c in collections.Counter(r["lac"] for r in lacs).most_common():
    print(f"   {nom:14} {c:>4}")

print("\nPAR CONTINENT (hors lacs, entrées mesurées) — le défaut est-il français ?")
print(f"   {'continent':16} {'n':>5} {'épingle TERRE':>15} {'croix MIXTE':>13}")
for c in sorted({r["continent"] for r in hors}):
    pop = [r for r in hors if r["continent"] == c]
    if len(pop) < 5: continue
    print(f"   {c:16} {len(pop):>5} "
          f"{100*sum(1 for r in pop if r['epingle_terre'])/len(pop):>14.1f}% "
          f"{100*sum(1 for r in pop if r['mixte'])/len(pop):>12.1f}%")

print("\nÉPINGLES ABERRANTES (élévation du point du spot) — à corriger dans le CATALOGUE, "
      "pas dans le code")
for r in sorted(hors, key=lambda r: -r["elev"][0])[:12]:
    print(f"   {r['elev'][0]:>6.0f} m  {r['name'][:38]:40} {r['catalogue']:15} {str(r['pays'])[:20]}")

# ═══════════════════ 2. CORROBORATION par un MNT indépendant ═══════════════════
if SRTM:
    comm = [kk for kk in ELEV if kk in SRTM and SRTM[kk] is not None]
    acc = sum(1 for kk in comm if (ELEV[kk] == 0) == (SRTM[kk] == 0))
    S = geo(toutes_les_entrees(), SRTM)
    print(f"\n\n═══ CORROBORATION — SRTM 90 m / ASTER 30 m sur les 4 326 entrées ═══")
    print(f"accord du verdict eau/terre avec Open-Meteo : {100*acc/len(comm):.1f} % sur "
          f"{len(comm)} points communs (SRTM est un radar non filtré : ses pixels côtiers "
          f"lisent 1 à 5 m là où Copernicus GLO-90 met 0, donc il SUR-compte la terre).")
    print(f"{len(S)} entrées mesurées : épingle terre "
          f"{100*sum(1 for r in S if r['epingle_terre'])/len(S):.1f} %, croix mixte "
          f"{100*sum(1 for r in S if r['mixte'])/len(S):.1f} %, aucune eau "
          f"{100*sum(1 for r in S if r['aucune_eau'])/len(S):.1f} %")

# ═══════════════════════ 3. VENT (échantillon de 235 entrées) ═══════════════════════
ROWS = geo(ECH["entrees"], ELEV, VENT)
wv = [r for r in ROWS if "etendue_med" in r]
if wv:
    print(f"\n\n═══ ÉTENDUE DE VENT SUR LA CROIX — {len(wv)} entrées, 7 jours horaires ═══")
    multi = [r for r in wv if r["mailles"] > 1]
    print(f"croix franchissant ≥2 mailles de MODÈLE : {len(multi)}/{len(wv)} "
          f"({100*len(multi)/len(wv):.1f} %). Ailleurs la médiane de voisinage est un no-op EXACT.")
    for nom, sel in (("toutes", wv), ("multi-mailles", multi)):
        if not sel: continue
        m = [r["etendue_med"] for r in sel]; p = [r["etendue_p90"] for r in sel]
        nv = [r["etendue_navigable"] for r in sel if r.get("etendue_navigable") is not None]
        print(f"  {nom:14} médiane des médianes {median(m):5.2f} kn | médiane des p90 "
              f"{median(p):5.2f} | p90 des p90 {pct(p,90):5.2f} | max "
              f"{max(r['etendue_max'] for r in sel):5.2f}"
              + (f" | heures navigables {median(nv):5.2f}" if nv else ""))

    print(f"\nPIRES CAS (p90 de l'étendue sur la croix)")
    print(f"   {'nom':34} {'catalogue':15} {'pays':15} {'méd':>6} {'p90':>6} {'max':>6} "
          f"{'Δeau':>7}  élévations (m)")
    for r in sorted(wv, key=lambda r: -r["etendue_p90"])[:25]:
        d = r.get("delta_filtre_med")
        print(f"   {r['name'][:33]:34} {r['catalogue']:15} {str(r['pays'])[:14]:15} "
              f"{r['etendue_med']:>6.2f} {r['etendue_p90']:>6.2f} {r['etendue_max']:>6.2f} "
              f"{(f'{d:+.2f}' if d is not None else '   —'):>7}  {[int(v) for v in r['elev']]}")

    # ── Le verdict du MNT ne coïncide PAS avec la maille du modèle ──
    mixtes = [r for r in wv if r["mixte"]]
    opp = [r for r in mixtes if r.get("opposable")]
    print(f"\nLE MNT NE DÉCRIT PAS LA MAILLE — {len(opp)}/{len(mixtes)} "
          f"({100*len(opp)/len(mixtes):.1f} %) des croix MIXTES ont leurs points EAU et leurs "
          f"points TERRE dans des mailles de modèle DISJOINTES. Partout ailleurs, un point "
          f"« eau » et un point « terre » lisent la MÊME série : le MNT résout à 90 m ce que "
          f"le modèle résout à 1,3 km (AROME) ou 25 km (ARPEGE monde).")

    filt = [r for r in wv if r.get("delta_filtre_med") is not None]
    if filt:
        ds = [r["delta_filtre_med"] for r in filt]
        nul = sum(1 for d in ds if abs(d) < 0.1)
        do = [r["delta_filtre_med"] for r in filt if r.get("opposable")]
        print(f"\nCE QUE CHANGERAIT UN FILTRE « médiane sur les mailles EAU seules » :")
        print(f"   sur les {len(filt)} croix mixtes : médiane {median(ds):+.2f} kn | "
              f"p90 {pct(ds,90):+.2f} | max {max(ds, key=abs):+.2f} | "
              f"strictement NUL sur {100*nul/len(ds):.0f} % d'entre elles")
        if do:
            print(f"   sur les {len(do)} croix OPPOSABLES seulement : médiane {median(do):+.2f} kn | "
                  f"p90 {pct(do,90):+.2f} | max {max(do, key=abs):+.2f}")
        print(f"\n   PIRES EFFETS du filtre (|Δ| médian le plus fort)")
        for r in sorted(filt, key=lambda r: -abs(r["delta_filtre_med"]))[:12]:
            print(f"   {r['delta_filtre_med']:+7.2f} kn  {r['name'][:34]:36} {r['catalogue']:15} "
                  f"{str(r['pays'])[:16]:17} {[int(v) for v in r['elev']]}")

json.dump({"principal": [{kk: r[kk] for kk in
                          ("id", "name", "catalogue", "continent", "pays", "lat", "lon",
                           "elev", "epingle_terre", "mixte", "aucune_eau",
                           "mediane_sur_terre", "lac")} for r in TOUT],
           "vent": [{kk: vv for kk, vv in r.items() if kk != "eau"} for r in wv]},
          open(os.path.join(BASE, "audit/resultats_catalogues.json"), "w"),
          ensure_ascii=False, indent=1)
print("\n→ audit/resultats_catalogues.json")

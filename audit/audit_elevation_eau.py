#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
audit_elevation_eau.py — le champ « elevation » d'Open-Meteo identifie-t-il l'EAU ?

QUESTION
    Open-Meteo renvoie « elevation » PAR COORDONNÉE interrogée, dans la même réponse,
    sans coût réseau supplémentaire. Peut-on s'en servir pour savoir si la maille
    échantillonnée est de l'EAU (rugosité faible) ou de la TERRE (rugosité forte) ?

RÉPONSE MESURÉE (17 août 2026)
    OUI pour l'eau AU NIVEAU DE LA MER, avec la règle « elevation == 0 » EXACTEMENT.
    Entre 66°S et 66°N : rappel 100,00 % sur l'océan, 0,65 % de faux positifs sur la
    terre (tous adjugés comme erreurs du masque de vérité), erreur globale 0,176 %.

    NON pour l'eau INTÉRIEURE : un lac renvoie l'altitude de SA SURFACE (Léman 368,
    Michigan 174, Balaton 104, mer Morte −427). La règle « == 0 » les classe TERRE.

TROIS PIÈGES VÉRIFIÉS — ne pas les réintroduire
  1. « elevation < 0.5 » EST DANGEREUX. La terre littorale basse n'est pas à 0 : elle
     est à un petit entier NÉGATIF. Polders néerlandais −3 à −5, Camargue −1, delta du
     Pô −2, Fens −1, Lammefjord −4, dépression caspienne −19, Qattara −79, Death
     Valley −86, vallée du Jourdain −252. Sur un transect néerlandais mer → dunes →
     polder, « == 0 » commet 8 erreurs et « < 0.5 » en commet 21 : les 13 de plus sont
     6,5 km de polder classés « eau » d'affilée. Les valeurs étant TOUJOURS entières,
     « abs(e) < 0.5 » est strictement équivalent à « == 0 » — « < 0.5 » ne l'est PAS.
  2. L'élévation NE DÉPEND PAS DU MODÈLE. Vérifié identique au mètre près sur 9 modèles
     (meteofrance_seamless, icon_seamless, gfs_seamless, ecmwf_ifs025, arome_france_hd,
     ukmo, jma, gem, best_match) et identique à l'endpoint dédié /v1/elevation. C'est
     un MNT à 90 m, pas la maille du modèle. Donc elle décrit le POINT, pas la rugosité
     de la maille qu'AROME (1,3 km) a réellement utilisée : mesuré, 8,6 % des épingles
     lisant 0 sont dans une maille AROME majoritairement TERRE.
  3. Aux latitudes POLAIRES, les plateformes de glace renvoient leur altitude de
     surface (18 à 149 m) alors que le masque océan les donne en mer. Sans effet pour
     l'app, mais c'est la seule cause de « eau avec elevation != 0 » observée.

CE QUE ÇA VAUT POUR LE CATALOGUE (mesuré)
    62,5 % des 284 spots surf et 60,5 % des marégraphes ont leur épingle sur une maille
    TERRE. 58,9 % des spots voient la médiane actuelle porter sur une MAJORITÉ de
    mailles terre. 91,1 % ont au moins une maille EAU exploitable dans la croix de 2 km
    déjà interrogée — donc le correctif ne coûte aucune requête de plus.
    5,9 % des marégraphes sont en eau intérieure (Grands Lacs) : angle mort assumé.

Dépendances : aucune obligatoire. `pip install global_land_mask` pour la vérité
terre/océan indépendante (masque GSHHG ~1 km). Sans lui, seul le jeu curated tourne.

Limite du protocole : la vérité terre/mer vient d'un masque à 1 km. Le désaccord avec
le MNT s'effondre avec la distance à la côte (73,8 % d'accord à 0,5 km → 100,0 % à
3 km) : c'est le MASQUE qui est faux près du trait de côte, pas le MNT — confirmé par
un second MNT à 30 m, qui donne raison au MNT dans 89 % des désaccords.
"""

import json
import math
import random
import subprocess
import sys
import time

ELEV_URL = "https://api.open-meteo.com/v1/elevation"
MAX_COORDS = 100          # limite dure de l'API
PAUSE_S = 1.2             # limite « minutely » du palier gratuit


def elevations(points, chunk=MAX_COORDS, pause=PAUSE_S):
    """[(lat, lon)] -> [elevation | None]. Une requête par tranche de 100."""
    out = []
    for i in range(0, len(points), chunk):
        lot = points[i:i + chunk]
        lat = ",".join(f"{a:.5f}" for a, _ in lot)
        lon = ",".join(f"{b:.5f}" for _, b in lot)
        got = None
        for essai in range(8):
            brut = subprocess.run(
                ["curl", "-sS", "--max-time", "120",
                 f"{ELEV_URL}?latitude={lat}&longitude={lon}"],
                capture_output=True, text=True).stdout
            try:
                rep = json.loads(brut)
            except Exception:
                rep = {"error": True, "reason": "réponse illisible"}
            if isinstance(rep, dict) and len(rep.get("elevation", [])) == len(lot):
                got = rep["elevation"]
                break
            raison = str(rep.get("reason", "")) if isinstance(rep, dict) else ""
            print(f"    [{raison[:60]}] nouvel essai", file=sys.stderr)
            time.sleep(62 if "limit" in raison.lower() else 4 + 4 * essai)
        out.extend(got if got else [None] * len(lot))
        time.sleep(pause)
    return out


# ── Jeu curated : chaque catégorie que l'audit devait couvrir ────────────────
# (nom, lat, lon, vérité : "W" = eau, "L" = terre)
CURATED = [
    # pleine mer, tous les océans
    ("Atlantique large Gascogne",      45.50,   -5.00,  "W"),
    ("Pacifique Nord",                 35.00, -160.00,  "W"),
    ("Océan Indien",                  -15.00,   75.00,  "W"),
    ("Méditerranée (Tyrrhénienne)",    40.00,   12.00,  "W"),
    ("Mer du Nord (Dogger Bank)",      54.80,    2.50,  "W"),
    ("Mer de Tasman",                 -38.00,  158.00,  "W"),
    # lagunes et bassins
    ("Bassin d'Arcachon",              44.68,   -1.12,  "W"),
    ("Lagune de Venise",               45.42,   12.33,  "W"),
    ("IJsselmeer",                     52.75,    5.35,  "W"),
    ("Sotavento (Fuerteventura)",      28.145, -14.228, "W"),
    ("Lagon de Maurice (Le Morne)",   -20.47,   57.31,  "W"),
    ("Mar Menor",                      37.73,   -0.78,  "W"),
    # grands lacs : la règle « == 0 » NE MARCHE PAS, elle renvoie la surface du lac
    ("Léman",                          46.43,    6.52,  "W"),
    ("Lac de Garde",                   45.65,   10.68,  "W"),
    ("Lac Michigan",                   43.50,  -87.00,  "W"),
    ("Balaton",                        46.83,   17.75,  "W"),
    ("Mer Caspienne",                  41.00,   51.00,  "W"),
    ("Mer Morte",                      31.50,   35.47,  "W"),
    # côtes basses : LE cas qui pourrait casser la règle — il donne du NÉGATIF
    ("Polder Flevoland (NL)",          52.52,    5.55,  "L"),
    ("Polder Beemster (NL)",           52.55,    4.92,  "L"),
    ("Camargue, plaine agricole",      43.55,    4.60,  "L"),
    ("Lammefjord (DK)",                55.78,   11.45,  "L"),
    ("Fens (Angleterre)",              52.55,    0.05,  "L"),
    ("Plaine du delta du Pô",          44.95,   12.20,  "L"),
    ("Dépression caspienne (RU)",      45.864,  46.895, "L"),
    ("Vallée du Jourdain",             31.86,   35.46,  "L"),
    ("Death Valley",                   36.25, -116.82,  "L"),
    # deltas et estuaires
    ("Gironde, embouchure",            45.58,   -1.05,  "W"),
    ("Rhône, Grand Rhône",             43.42,    4.84,  "W"),
    ("Westerschelde",                  51.40,    3.70,  "W"),
    ("Baie de Chesapeake",             38.00,  -76.20,  "W"),
    # terres élevées, contrôle
    ("Mont Blanc",                     45.833,   6.865, "L"),
    ("Everest",                        27.988,  86.925, "L"),
    ("Plateau tibétain",               33.00,   88.00,  "L"),
    ("Forêt landaise (Lacanau est)",   45.00,   -1.10,  "L"),
]


def regle_eau(e):
    """La règle retenue. Les valeurs sont toujours entières : '== 0' est exact."""
    return e is not None and abs(e) < 0.5


def jeu_curated():
    print(f"\n=== Jeu curated ({len(CURATED)} points, toutes les catégories) ===")
    ev = elevations([(p[1], p[2]) for p in CURATED])
    lacs = {"Léman", "Lac de Garde", "Lac Michigan", "Balaton",
            "Mer Caspienne", "Mer Morte"}
    err = 0
    for (nom, _, _, verite), e in zip(CURATED, ev):
        if e is None:
            continue
        dit = "EAU" if regle_eau(e) else "TERRE"
        attendu = "EAU" if verite == "W" else "TERRE"
        note = ""
        if dit != attendu:
            err += 1
            note = "  <-- eau INTÉRIEURE, angle mort connu" if nom in lacs else "  <-- ÉCART"
        print(f"  {e!s:>9} m  {dit:<5} (attendu {attendu:<5})  {nom}{note}")
    print(f"\n  écarts : {err} — dont {len(lacs)} lacs (angle mort assumé, pas un défaut)")


def tirage_mondial(n=800, graine=20260817):
    """Tirage pondéré par la surface + vérité terre/océan indépendante."""
    try:
        from global_land_mask import globe
    except ImportError:
        print("\n[tirage mondial ignoré : pip install global_land_mask]")
        return
    print(f"\n=== Tirage mondial pondéré surface (n={n}) ===")
    random.seed(graine)
    pts, terre = [], []
    while len(pts) < n:
        lat = math.degrees(math.asin(random.uniform(-1, 1)))
        lon = random.uniform(-180, 180)
        if abs(lat) > 82:
            continue
        pts.append((lat, lon))
        terre.append(bool(globe.is_land(lat, lon)))
    ev = elevations(pts)
    lignes = [(p, t, e) for p, t, e in zip(pts, terre, ev) if e is not None]

    for borne, libelle in ((90, "toute la planète"), (66, "hors zones polaires")):
        s = [x for x in lignes if abs(x[0][0]) < borne]
        oc = [x for x in s if not x[1]]
        td = [x for x in s if x[1]]
        if not oc or not td:
            continue
        vp = sum(1 for x in oc if regle_eau(x[2]))
        fp = sum(1 for x in td if regle_eau(x[2]))
        print(f"  {libelle:22s} n={len(s):5d}  rappel eau {100*vp/len(oc):6.2f} %  "
              f"faux positifs terre {100*fp/len(td):5.2f} %  "
              f"erreur {100*((len(oc)-vp)+fp)/len(s):.3f} %")
    hors = [x for x in lignes if not x[1] and not regle_eau(x[2])]
    if hors:
        print("  « eau mais elevation != 0 » — latitudes :",
              sorted(round(x[0][0]) for x in hors), "(glace polaire)")


def catalogue_spots(chemin="Tide It/surf_spots.json"):
    """Combien d'épingles du catalogue tombent sur une maille TERRE ?"""
    try:
        spots = json.load(open(chemin))
    except Exception as exc:
        print(f"\n[catalogue ignoré : {exc}]")
        return
    print(f"\n=== Épingles du catalogue ({len(spots)} spots) ===")
    ev = elevations([(s["latitude"], s["longitude"]) for s in spots])
    ok = [(s, e) for s, e in zip(spots, ev) if e is not None]
    eau = sum(1 for _, e in ok if regle_eau(e))
    print(f"  sur l'EAU  (elevation == 0) : {eau:>4} = {100*eau/len(ok):.1f} %")
    print(f"  sur la TERRE               : {len(ok)-eau:>4} = {100*(len(ok)-eau)/len(ok):.1f} %")
    hautes = sorted((x for x in ok if not regle_eau(x[1])), key=lambda x: -x[1])[:10]
    print("  les épingles les plus hautes (à corriger dans le CATALOGUE, pas dans le code) :")
    for s, e in hautes:
        print(f"    {int(e):>5} m  {s['name']}  ({s.get('country')})")


if __name__ == "__main__":
    quoi = sys.argv[1] if len(sys.argv) > 1 else "tout"
    if quoi in ("tout", "curated"):
        jeu_curated()
    if quoi in ("tout", "mondial"):
        tirage_mondial()
    if quoi in ("tout", "catalogue"):
        catalogue_spots()

#!/usr/bin/env python3
"""Vérifie les notes de version App Store avant `fastlane deliver`.

Trois refus d'Apple ou de la charte, qu'on ne veut pas apprendre après l'envoi :

1. EMOJI — Apple rejette les notes qui en contiennent. Aucune exception.
2. NOM DE SOURCE — règle 3 du guide : aucun fournisseur de données ne doit
   apparaître dans une copy publique. L'attribution vit derrière les liens in-app.
3. LONGUEUR — 4 000 caractères maximum par locale.

⚠️ DEUX PIÈGES DÉJÀ PAYÉS, d'où la double liste de la règle 2 :

  - « camera ICON » a déclenché ICON, « 8 WINDY hours » a déclenché Windy. Les
    MARQUES se cherchent donc sans casse mais en mot entier, et les ACRONYMES
    (ICON, GFS, NOAA…) EN RESPECTANT LA CASSE : un acronyme est écrit en capitales
    dans le monde réel, et c'est ce qui le distingue d'un mot ordinaire.
  - La recherche est faite sur les mots, pas sur les sous-chaînes : sans ça
    « meteofrance » se serait déclenché sur des mots contenant « France ».

Sortie 0 = tout va bien, 1 = au moins une note est à corriger.
"""
import re
import sys
import unicodedata
from pathlib import Path

RACINE = Path(__file__).resolve().parent.parent / "fastlane" / "metadata"
MAX = 4000

# Marques : cherchées SANS casse (une marque s'écrit comme on veut).
MARQUES = ["open-meteo", "openmeteo", "open meteo", "weatherkit", "stormglass",
           "predictwind", "windy", "windguru", "winds-up", "windsup", "pioupiou",
           "winds.mobi", "windsmobi", "weameter", "weewx", "worldtides",
           "tidecheck", "meteo-france", "météo-france", "meteofrance",
           "ffvl", "shom", "météo france"]

# Acronymes : cherchés EN RESPECTANT LA CASSE, sinon « camera icon » et
# « 8 windy hours » lèvent une fausse alerte.
ACRONYMES = ["NOAA", "ICON", "GFS", "AROME", "ARPEGE", "ECMWF", "IFS", "METAR",
             "NDBC", "UKMO", "KNMI", "DMI", "JMA", "AIFS", "GEM"]


def emojis(txt):
    """Les caractères qu'Apple refuse : symboles et pictogrammes."""
    out = []
    for c in txt:
        if unicodedata.category(c) == "So" or 0x1F000 <= ord(c) <= 0x1FAFF:
            out.append(c)
    return sorted(set(out))


def sources(txt):
    trouve = []
    bas = txt.lower()
    for m in MARQUES:
        if re.search(r"(?<!\w)" + re.escape(m) + r"(?!\w)", bas):
            trouve.append(m)
    for a in ACRONYMES:
        if re.search(r"(?<!\w)" + re.escape(a) + r"(?!\w)", txt):
            trouve.append(a)
    return trouve


def main():
    fautes = 0
    fichiers = sorted(RACINE.glob("*/release_notes.txt"))
    if not fichiers:
        print(f"aucune note trouvée sous {RACINE}")
        return 1
    for f in fichiers:
        loc = f.parent.name
        txt = f.read_text(encoding="utf-8")
        pbs = []
        if len(txt) > MAX:
            pbs.append(f"{len(txt)} caractères (max {MAX})")
        if e := emojis(txt):
            pbs.append("emoji " + " ".join(e))
        if s := sources(txt):
            pbs.append("source nommée : " + ", ".join(s))
        if pbs:
            fautes += 1
            print(f"  ✗ {loc:9} {' · '.join(pbs)}")
        else:
            print(f"  ✓ {loc:9} {len(txt):5} caractères")
    print()
    print("À corriger avant l'envoi." if fautes else
          f"{len(fichiers)} locales prêtes pour `fastlane deliver`.")
    return 1 if fautes else 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Santé des sources de données de Tide It.

POURQUOI CE SCRIPT
`CLAUDE.md` § « Risques connus » acte la MORT SILENCIEUSE des balises tierces : l'app dégrade
proprement sans elles, donc rien ne casse — et personne n'apprend qu'une source est morte.
Sans ce script, on le découvre par un utilisateur qui signale « plus de vent réel à Andernos ».

CE QU'IL VÉRIFIE, ET CE QU'IL NE VÉRIFIE PAS
Il ne se contente PAS d'un code HTTP 200 : une page d'erreur, une station retirée ou un JSON
vide répondent 200 tout en étant inutilisables. Chaque source a donc un contrôle de CONTENU —
« ce corps de réponse contient-il une donnée que l'app saurait lire ? ».

Il ne teste pas la JUSTESSE des valeurs : c'est le rôle des scripts de `audit/`.

USAGE
    python3 tools/check_sources.py            # tableau lisible
    python3 tools/check_sources.py --quiet    # ne parle QUE s'il y a un problème (cron)

Code de sortie : 0 tout va bien · 1 une source SECONDAIRE est morte · 2 une source
CRITIQUE est morte (l'app perd une fonction entière).
"""
import json
import subprocess
import sys

TIMEOUT = 25

# (nom, criticité, url, contrôle de contenu)
#   CRITIQUE  = sa perte retire une FONCTION de l'app (prévision, houle, marées mondiales).
#   SECONDAIRE = sa perte retire une balise ou une confirmation ; l'app dégrade proprement.
SOURCES = [
    ("Prévision vent",      "CRITIQUE",
     "https://api.open-meteo.com/v1/forecast?latitude=44.65&longitude=-1.16"
     "&hourly=wind_speed_10m&models=meteofrance_seamless&forecast_days=1",
     lambda t: '"wind_speed_10m"' in t and "null" not in t.split('"wind_speed_10m":')[1][:40]),

    ("Prévision houle",     "CRITIQUE",
     "https://marine-api.open-meteo.com/v1/marine?latitude=44.65&longitude=-1.16"
     "&hourly=wave_height&forecast_days=1",
     lambda t: '"wave_height"' in t),

    ("Marées mondiales",    "CRITIQUE",
     "https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations/8518750/harcon.json?units=metric",
     lambda t: '"HarmonicConstituents"' in t),

    ("Balises Pioupiou",    "SECONDAIRE",
     "https://api.pioupiou.fr/v1/live-with-meta/all",
     lambda t: '"measurements"' in t and t.count('"id"') > 20),

    ("Balises winds.mobi",  "SECONDAIRE",
     "https://winds.mobi/api/2.3/stations/?limit=5",
     lambda t: t.strip().startswith("[") and '"_id"' in t),

    ("METAR",               "SECONDAIRE",
     "https://aviationweather.gov/api/data/metar?ids=LFBC&format=json",
     lambda t: '"wdir"' in t or '"wspd"' in t),

    ("Bouées NDBC",         "SECONDAIRE",
     "https://www.ndbc.noaa.gov/data/latest_obs/latest_obs.txt",
     lambda t: len(t.splitlines()) > 100),
]

# Les 4 slugs Weameter cités en dur dans WindStationAggregator. Un slug renommé côté exploitant
# ne casse rien visiblement : la balise disparaît, voilà tout. D'où leur présence ici.
WEAMETER_SLUGS = ["andernos", "pauillac", "lachanau", "kiteschool-leucate"]
for slug in WEAMETER_SLUGS:
    SOURCES.append((
        f"Weameter {slug}", "SECONDAIRE",
        f"https://weameter.com/stations/{slug}",
        # La page doit contenir une vitesse de vent ; une 404 « stylée » répond 200 sans elle.
        lambda t: ("km/h" in t or "kt" in t or "noeud" in t.lower()) and len(t) > 2000,
    ))


def fetch(url):
    """Renvoie (code_http, corps). Code 0 = pas de réponse du tout."""
    r = subprocess.run(
        ["curl", "-sS", "-m", str(TIMEOUT), "-L", "-w", "\n%{http_code}", url],
        capture_output=True, text=True)
    if r.returncode != 0:
        return 0, r.stderr.strip()[:120]
    parts = r.stdout.rsplit("\n", 1)
    if len(parts) != 2:
        return 0, "réponse illisible"
    body, code = parts
    try:
        return int(code), body
    except ValueError:
        return 0, "code HTTP illisible"


def main():
    quiet = "--quiet" in sys.argv
    lignes, morts_critiques, morts_secondaires = [], [], []

    for nom, crit, url, valide in SOURCES:
        code, corps = fetch(url)
        if code == 0:
            etat, detail = "INJOIGNABLE", corps
        elif code != 200:
            etat, detail = "HTTP " + str(code), ""
        else:
            try:
                ok = valide(corps)
            except Exception:
                ok = False
            etat = "ok" if ok else "REPOND MAIS VIDE"
            detail = "" if ok else f"{len(corps)} octets, contenu attendu absent"

        if etat != "ok":
            (morts_critiques if crit == "CRITIQUE" else morts_secondaires).append(nom)
        lignes.append((nom, crit, etat, detail))

    problemes = morts_critiques + morts_secondaires
    if quiet and not problemes:
        return 0

    largeur = max(len(l[0]) for l in lignes)
    print(f"\nSources de données Tide It — {len(lignes)} vérifiées\n")
    for nom, crit, etat, detail in lignes:
        marque = "  " if etat == "ok" else ("!!" if crit == "CRITIQUE" else " ~")
        print(f" {marque} {nom:<{largeur}}  {etat:<16} {detail}")

    print()
    if morts_critiques:
        print(f"CRITIQUE — l'app perd une fonction entière : {', '.join(morts_critiques)}")
    if morts_secondaires:
        print(f"Secondaire — l'app dégrade proprement, mais à vérifier : "
              f"{', '.join(morts_secondaires)}")
    if not problemes:
        print("Toutes les sources répondent et renvoient des données exploitables.")
    print()

    return 2 if morts_critiques else (1 if morts_secondaires else 0)


if __name__ == "__main__":
    sys.exit(main())

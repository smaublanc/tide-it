#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
STABILITÉ AU POINTAGE — le test que réclame le propriétaire, mot pour mot :
« la valeur ne doit pas dépendre de quelques centaines de mètres de pointage ».

Ce test ne demande AUCUNE vérité terrain. Il ne compare pas la prévision au vent réel :
il mesure de combien la valeur AFFICHÉE bouge quand on déplace l'épingle du spot sans
rien changer d'autre. Il est donc réalisable partout sur la planète, sans balise, sans
hypothèse sur ce qui est « juste ».

PROTOCOLE
  Pour chaque spot : 9 épingles = le point d'origine + 1 km dans 8 directions
  (N, NE, E, SE, S, SO, O, NO). Pour CHAQUE épingle on reconstitue la croix de 5 points
  à 2 km de `MarineWeatherService.neighbourhood` (copie exacte, formatage %.4f compris),
  et on calcule la valeur que rendrait chacune des 6 méthodes candidates, heure par heure
  sur 14 jours.
  Puis, POUR CHAQUE MÉTHODE : écart-type et étendue de la valeur à travers les 9 épingles,
  à chaque heure. La méthode la plus stable est celle dont la valeur bouge le moins.

  → 9 épingles × 5 points = 45 coordonnées par spot, UNE requête par spot.

MÉTHODES
  A  centre seul (ce que faisait l'app avant le voisinage)
  B  médiane des 5 points (méthode ACTUELLE)
  C  médiane des mailles EAU seulement (elevation == 0, règle validée au volet 1)
  D  moyenne des mailles EAU seulement
  E  maximum des 5 points
  F  médiane pondérée par l'inverse de l'élévation, poids 1/(1+|elev|)

  C et D n'existent pas si AUCUN des 5 points n'est de l'eau. Le script compte ces cas
  et applique le repli documenté (→ B), tout en mesurant AUSSI la variante « stricte »
  (spots sans repli) pour que le repli ne maquille pas le résultat.

SOURCE : historical-forecast-api.open-meteo.com — MÊME modèle (`meteofrance_seamless`),
même grille native, même MNT pour `elevation` (vérifié : Andernos centre = 6 m, valeur
identique à celle relevée par le propriétaire sur api.open-meteo.com). Cet endpoint sert
les runs passés archivés et possède son PROPRE quota, celui de api.open-meteo.com ayant
été épuisé par les volets précédents. Ce que l'on mesure ici — la sensibilité d'une
méthode d'échantillonnage à la position de l'épingle — ne dépend que de la grille du
modèle, identique dans les deux cas.

Sortie : audit/resultats_stabilite_epingle.json   (cache : rejouer est gratuit)
Analyse : audit/analyse_stabilite_epingle.py
"""
import json, math, os, subprocess, sys, time, urllib.parse

NEIGHBOURHOOD_KM = 2.0        # = MarineWeatherService.neighbourhoodKm
PIN_SHIFT_KM     = 1.0        # déplacement de l'épingle demandé par le protocole
PAST_DAYS        = 14
MODEL            = "meteofrance_seamless"   # le modèle EFFECTIF partout (volet 2 : 47/47 spots)
HOST             = "https://historical-forecast-api.open-meteo.com/v1/forecast"

OUT   = os.path.join(os.path.dirname(os.path.abspath(__file__)), "resultats_stabilite_epingle.json")

BEARINGS = [("O", None)]  # remplacé ci-dessous ; placeholder pour lisibilité
PINS = [("origine", 0.0, 0.0)] + [
    (nom, PIN_SHIFT_KM * math.cos(math.radians(b)), PIN_SHIFT_KM * math.sin(math.radians(b)))
    for nom, b in [("N", 0), ("NE", 45), ("E", 90), ("SE", 135),
                   ("S", 180), ("SO", 225), ("O", 270), ("NO", 315)]
]  # (nom, décalage km vers le nord, décalage km vers l'est)

# 25 spots de glisse CÔTIERS, tous les continents. Sous-ensemble du jeu validé au volet 2
# (audit_rugosite_monde.py), choisi pour l'étalement géographique : aucun continent ne pèse
# plus de 5 spots, et les deux spots qui ont déclenché l'affaire (Lacanau / Andernos) y sont.
SPOTS = [
    # Europe atlantique / mer du Nord
    ("Lacanau Ocean (FR)",        45.0000,   -1.2033, "Europe-Atlantique"),
    ("Andernos, Bassin (FR)",     44.7433,   -1.1042, "Europe-Atlantique"),
    ("Guincho (PT)",              38.7320,   -9.4720, "Europe-Atlantique"),
    ("Westkapelle (NL)",          51.5250,    3.4350, "Europe-Atlantique"),
    ("Hvide Sande (DK)",          56.0000,    8.1300, "Europe-Atlantique"),
    # Méditerranée
    ("La Franqui, Leucate (FR)",  42.9160,    3.0300, "Mediterranee"),
    ("Vassiliki (GR)",            38.6250,   20.6000, "Mediterranee"),
    ("Alacati (TR)",              38.2500,   26.3600, "Mediterranee"),
    # Afrique
    ("Dakhla lagune (MA)",        23.8500,  -15.8000, "Afrique"),
    ("Essaouira (MA)",            31.5000,   -9.7700, "Afrique"),
    ("Langebaan (ZA)",           -33.0900,   18.0300, "Afrique"),
    ("Paje, Zanzibar (TZ)",       -6.2700,   39.5300, "Afrique"),
    # Caraïbes
    ("Cabarete (DO)",             19.7580,  -70.4110, "Caraibes"),
    ("Sorobon, Bonaire (BQ)",     12.0900,  -68.2200, "Caraibes"),
    # Amérique du Nord
    ("Cape Hatteras (US)",        35.2200,  -75.6900, "Amerique-Nord"),
    ("La Ventana (MX)",           24.0500, -109.9900, "Amerique-Nord"),
    ("Long Beach, NY (US)",       40.5800,  -73.6600, "Amerique-Nord"),
    # Amérique du Sud
    ("Cumbuco (BR)",              -3.6250,  -38.7300, "Amerique-Sud"),
    ("Jericoacoara (BR)",         -2.7950,  -40.5100, "Amerique-Sud"),
    ("Paracas (PE)",             -13.8300,  -76.2500, "Amerique-Sud"),
    # Asie
    ("Mui Ne (VN)",               10.9500,  108.2600, "Asie"),
    ("Kalpitiya (LK)",             8.2300,   79.7500, "Asie"),
    # Océanie
    ("Leighton, Perth (AU)",     -32.0400,  115.7500, "Oceanie"),
    ("Currumbin (AU)",           -28.1300,  153.4900, "Oceanie"),
    # Îles
    ("Pozo Izquierdo (ES)",       27.8100,  -15.4200, "Iles"),
    ("Le Morne (MU)",            -20.4900,   57.3100, "Iles"),
]


def neighbourhood(lat, lon):
    """Copie exacte de MarineWeatherService.neighbourhood (centre, N, S, E, O)."""
    d_lat = NEIGHBOURHOOD_KM / 111.0
    d_lon = NEIGHBOURHOOD_KM / (111.0 * max(0.1, math.cos(math.radians(lat))))
    return [(lat, lon), (lat + d_lat, lon), (lat - d_lat, lon),
            (lat, lon + d_lon), (lat, lon - d_lon)]


def shifted(lat, lon, km_n, km_e):
    """Déplace l'épingle de km_n vers le nord et km_e vers l'est."""
    return (lat + km_n / 111.0,
            lon + km_e / (111.0 * max(0.1, math.cos(math.radians(lat)))))


def fetch(coords):
    """coords = [(lat, lon), ...] — une seule requête, comme l'app."""
    q = urllib.parse.urlencode({
        "latitude":  ",".join(f"{c[0]:.4f}" for c in coords),
        "longitude": ",".join(f"{c[1]:.4f}" for c in coords),
        "hourly": "wind_speed_10m",
        "models": MODEL,
        "wind_speed_unit": "kn",
        "past_days": str(PAST_DAYS),
        "forecast_days": "0",
    })
    url = HOST + "?" + q
    for attempt in range(6):
        try:
            out = subprocess.run(["curl", "-s", "--max-time", "180", url],
                                 capture_output=True, text=True)
            data = json.loads(out.stdout)
        except Exception as e:
            print(f"    ! {e}", file=sys.stderr); time.sleep(20 * (attempt + 1)); continue
        if isinstance(data, dict) and data.get("error"):
            raison = str(data.get("reason", "")).lower()
            print(f"    ! {data.get('reason')}", file=sys.stderr)
            if "daily" in raison:
                return None                      # quota du jour : inutile d'insister
            if "minutely" in raison or "hourly" in raison:
                time.sleep(70); continue         # limite de débit : elle se lève seule
            time.sleep(20 * (attempt + 1)); continue
        if isinstance(data, dict):
            data = [data]
        if len(data) != len(coords):
            print(f"    ! {len(data)} séries pour {len(coords)} coordonnées", file=sys.stderr)
            return None
        return data
    return None


def main():
    resultats = []
    if os.path.exists(OUT):
        resultats = json.load(open(OUT))
    deja = {r["nom"] for r in resultats}

    for nom, lat, lon, zone in SPOTS:
        if nom in deja:
            print(f"= {nom} (déjà)"); continue
        # 9 épingles × 5 points = 45 coordonnées, dans un ordre déterministe.
        coords, plan = [], []
        for pnom, kn, ke in PINS:
            plat, plon = shifted(lat, lon, kn, ke)
            idx = []
            for (clat, clon) in neighbourhood(plat, plon):
                idx.append(len(coords))
                coords.append((clat, clon))
            plan.append({"epingle": pnom, "lat": plat, "lon": plon, "indices": idx})

        print(f"→ {nom} ({len(coords)} coordonnées)…", flush=True)
        data = fetch(coords)
        if data is None:
            print("  ABANDON (quota ou erreur) — relancer plus tard", file=sys.stderr)
            break

        series, elevs = [], []
        for d in data:
            h = d.get("hourly") or {}
            series.append(h.get("wind_speed_10m") or [])
            elevs.append(d.get("elevation"))
        times = (data[0].get("hourly") or {}).get("time") or []

        resultats.append({"nom": nom, "lat": lat, "lon": lon, "zone": zone,
                          "times": times, "plan": plan,
                          "elevations": elevs, "vent": series})
        json.dump(resultats, open(OUT, "w"), ensure_ascii=False)
        print(f"  ok — {len(times)} heures", flush=True)
        time.sleep(2)

    print(f"\n{len(resultats)}/{len(SPOTS)} spots dans {OUT}")


if __name__ == "__main__":
    main()

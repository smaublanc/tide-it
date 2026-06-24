#!/usr/bin/env python3
"""Remplit fr (explicite) + en pour les entrées Watch sans aucune localisation."""
import json
PATH = "Tide Watch Watch App/Localizable.xcstrings"

FR_EN = {
    "Marées : SHOM, NOAA.": ("Marées : SHOM, NOAA.", "Tides: SHOM, NOAA."),
    "Ouvre Tide It sur ton iPhone\nune fois pour charger tes spots.": (
        "Ouvre Tide It sur ton iPhone\nune fois pour charger tes spots.",
        "Open Tide It on your iPhone\nonce to load your spots."),
    "Première synchro": ("Première synchro", "First sync"),
    "Prévisions : Open-Meteo.": ("Prévisions : Open-Meteo.", "Forecasts: Open-Meteo."),
    "Sources des données": ("Sources des données", "Data sources"),
    "Vent observé : Pioupiou (CC-BY 4.0), winds.mobi, NDBC, METAR / NOAA.": (
        "Vent observé : Pioupiou (CC-BY 4.0), winds.mobi, NDBC, METAR / NOAA.",
        "Observed wind: Pioupiou (CC-BY 4.0), winds.mobi, NDBC, METAR / NOAA."),
}

m = json.load(open(PATH, encoding="utf-8"))
strings = m["strings"]
fixed = 0
for k, v in strings.items():
    loc = v.get("localizations", {})
    nonempty = [u for u in loc.values() if u.get("stringUnit", {}).get("value", "").strip()]
    if not nonempty and k in FR_EN:
        fr, en = FR_EN[k]
        v["localizations"] = {
            "fr": {"stringUnit": {"state": "translated", "value": fr}},
            "en": {"stringUnit": {"state": "translated", "value": en}},
        }
        fixed += 1
json.dump(m, open(PATH, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print("Watch entries fixed:", fixed)

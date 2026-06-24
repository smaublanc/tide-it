#!/usr/bin/env python3
"""Remplit les traductions EN manquantes dans Localizable.xcstrings (source = fr).
Additif : n'ajoute un bloc 'en' que si absent/vide ; ne touche à rien d'autre."""
import json, sys

PATH = "Tide It/Localizable.xcstrings"

EN = {
    " · %lld s": " · %lld s",
    "%@ — %@": "%@ — %@",
    "%@ · %lld s": "%@ · %lld s",
    "%@ / %@": "%@ / %@",
    "%@ %lld°": "%@ %lld°",
    "%@ → %@ · %@–%@ (estim. modèle)": "%@ → %@ · %@–%@ (model estimate)",
    "%@ à %@, %@%@": "%@ at %@, %@%@",
    "%@ établi à %@ (balise). C'est le moment.": "%@ steady at %@ (station). Now's the time.",
    "%@, puis %@ / %@": "%@, then %@ / %@",
    "%lld s": "%lld s",
    "5/4 mm + chaussons": "5/4 mm + booties",
    "6/5 mm + chaussons, gants, cagoule": "6/5 mm + booties, gloves, hood",
    "Activer les notifications des fenêtres GO ici": "Enable GO window notifications here",
    "Activités : %lld": "Activities: %lld",
    "Ajoute un spot depuis la carte ou la recherche": "Add a spot from the map or search",
    "Au-dessus de la tête": "Overhead",
    "Aucun spot de surf": "No surf spots",
    "Automatique": "Automatic",
    "Avant/après marée": "Before/after tide",
    "Beach break": "Beach break",
    "Boardshort ou 2 mm": "Boardshorts or 2 mm",
    "Ça marche": "Firing",
    "Calé sur bouée proche": "Locked to nearby buoy",
    "Combinaison 3/2 mm": "3/2 mm wetsuit",
    "Combinaison 4/3 mm": "4/3 mm wetsuit",
    "Découvrir les modèles": "Browse presets",
    "Digue / embouchure": "Jetty / rivermouth",
    "Données de houle indisponibles": "Swell data unavailable",
    "Données indisponibles": "Data unavailable",
    "Double overhead": "Double overhead",
    "En baisse": "Dropping",
    "En hausse": "Building",
    "Essai gratuit d'une semaine — sans engagement, annulable à tout moment.": "One-week free trial — no commitment, cancel anytime.",
    "Exigence": "Strictness",
    "Fenêtre de GO — %@": "GO window — %@",
    "Flat": "Flat",
    "Genou": "Knee",
    "HAUTEUR DE LA HOULE": "SWELL HEIGHT",
    "Heures après": "Hours after",
    "Heures avant": "Hours before",
    "houle indisponible": "swell unavailable",
    "Houle modèle (large, offshore)": "Model swell (broad, offshore)",
    "Houle partitionnée (modèle large)": "Partitioned swell (broad model)",
    "HOULES": "SWELLS",
    "indice": "index",
    "L'app calcule le meilleur moment, sans réglage": "The app finds the best time, no setup",
    "Le paiement sera débité sur votre compte Apple à la confirmation de l'achat. Tout essai gratuit non résilié au moins 24h avant son terme se transforme automatiquement en abonnement payant au tarif indiqué. L'abonnement se renouvelle ensuite automatiquement sauf annulation au moins 24h avant la fin de la période en cours. Le renouvellement est facturé au tarif en vigueur. Gérez ou annulez vos abonnements dans Réglages > votre compte Apple > Abonnements.": "Payment will be charged to your Apple Account at confirmation of purchase. Subscriptions automatically renew unless canceled at least 24 hours before the end of the current period; any free trial not canceled at least 24 hours before it ends converts into a paid subscription at the stated rate. Renewals are billed at the current rate. Manage or cancel your subscriptions in Settings > your Apple Account > Subscriptions.",
    "Les alertes et notifications nécessitent Premium — parcours les modèles pour voir": "Alerts and notifications require Premium — browse the presets to preview",
    "Les fenêtres suivent la météo et tes réglages — touche pour ajuster tes sports.": "Windows follow the weather and your settings — tap to adjust your sports.",
    "Marée basse": "Low tide",
    "Marée haute": "High tide",
    "matin": "morning",
    "Mi-marée": "Mid-tide",
    "Mixte": "Mixed",
    "Mode courbe : marée, vent ou surf": "Curve mode: tide, wind, or surf",
    "Normal": "Normal",
    "NOTE PAR HEURE · glisse le doigt": "HOURLY RATING · drag your finger",
    "Notifications de fenêtre GO activées": "GO window notifications on",
    "Notifications des fenêtres GO activées ici": "GO window notifications on here",
    "Période : %lld s": "Period: %lld s",
    "Point break": "Point break",
    "Poitrine": "Chest",
    "Récif": "Reef",
    "Reef break": "Reef break",
    "Règle les sports que tu pratiques SUR CE SPOT et leurs conditions. Le calendrier ne suit que les sports activés ici. (Gratuit : 1 sport.)": "Set the sports you do AT THIS SPOT and their conditions. The calendar only tracks the sports enabled here. (Free: 1 sport.)",
    "Régler mes sports": "Set up my sports",
    "Roche": "Rock",
    "Sable": "Sand",
    "soir": "evening",
    "Souple": "Lenient",
    "Spot de surf %@, %@": "Surf spot %@, %@",
    "Stable": "Holding",
    "Strict": "Strict",
    "Surfable": "Surfable",
    "Taille": "Size",
    "Tendance inconnue": "Trend unknown",
    "Tête": "Head",
    "tideitapp@icloud.com": "tideitapp@icloud.com",
    "Trop gros": "Too big",
    "Vent temps réel — Balises : Pioupiou (CC-BY) · winds.mobi (Holfuy, FFVL, Romma…) · METAR & bouées NDBC (NOAA) · Weameter.  Prévisions de vent : Open-Meteo.": "Real-time wind — Stations: Pioupiou (CC-BY) · winds.mobi (Holfuy, FFVL, Romma…) · METAR & NDBC buoys (NOAA) · Weameter.  Wind forecasts: Open-Meteo.",
}

m = json.load(open(PATH, encoding="utf-8"))
strings = m["strings"]
added = 0
missing_map = []
for k, v in strings.items():
    if not k.strip():
        continue
    if v.get("extractionState", "") == "stale":
        continue
    loc = v.setdefault("localizations", {})
    have_en = "en" in loc and loc["en"].get("stringUnit", {}).get("value", "").strip()
    if have_en:
        continue
    if k in EN:
        loc["en"] = {"stringUnit": {"state": "translated", "value": EN[k]}}
        added += 1
    else:
        missing_map.append(k)

json.dump(m, open(PATH, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print(f"EN added: {added}")
if missing_map:
    print(f"STILL missing EN (no mapping) [{len(missing_map)}]:")
    for k in missing_map:
        print("  ", repr(k))

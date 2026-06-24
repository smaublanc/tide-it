# Tide It 5.0.1 — Notes de mise à jour App Store

Version 5.0.1 (build 3). Sans emoji (règle App Store). À coller dans App Store Connect -> Nouveautés.

## Français (FR)

Tide It 5.0.1 — essai gratuit et finitions.

Essai gratuit d'une semaine : découvrez tout le Premium pendant une semaine, sans engagement — notifications, calendrier GO 7 jours, vent en temps réel, prédictions J+30, mode vent, Live Activity et export.

Balises de vent dans le monde entier : les stations de vent réel s'affichent désormais sur la carte où que vous regardiez, plus seulement en France. Zoomez sur une côte pour les voir apparaître.

Accès rapide à vos derniers spots : vos trois derniers ports consultés sont à portée de main dans le menu central.

Repère de notifications : une cloche indique d'un coup d'œil les spots dont les alertes de fenêtre GO sont activées.

Corrections : le bandeau météo 7 jours se met à jour correctement au changement de port, les notifications ne sont plus envoyées pour un spot que vous avez supprimé, une barre de chargement apparaît pendant la récupération des données sur la carte, et diverses finitions d'affichage et de performance.

## English (US)

Tide It 5.0.1 — free trial and refinements.

One-week free trial: try all of Premium for a week, no commitment — notifications, 7-day GO calendar, real-time wind, 30-day predictions, wind mode, Live Activity and export.

Wind stations worldwide: real-wind stations now show on the map wherever you look, not just in France. Zoom in on a coast to see them appear.

Quick access to your latest spots: your three most recently viewed ports are one tap away in the main menu.

Notification marker: a bell shows at a glance which spots have their GO-window alerts turned on.

Fixes: the 7-day weather strip now updates correctly when switching ports, notifications are no longer sent for a spot you have deleted, a loading bar appears while map data is being fetched, plus assorted display and performance polish.

## TestFlight — What to Test (optionnel)

FR : Essai gratuit (avec un compte sandbox neuf, vérifier la mention « 1 semaine d'essai gratuit » sur les deux abonnements et le bandeau d'essai sur le paywall). Balises à l'étranger (zoomer sur une côte espagnole/anglaise -> les points balise apparaissent). Changement de port (le bandeau météo 7 jours suit le nouveau port). Suppression d'un port (plus aucune notification fantôme ensuite).

US : Free trial (with a fresh sandbox account, check the "1-week free trial" wording on both subscriptions and the trial banner on the paywall). Foreign wind stations (zoom in on a Spanish/UK coast -> station dots appear). Switching ports (the 7-day weather strip follows the new port). Deleting a port (no more stray notifications afterwards).

## Avant le submit (rappel interne, à NE PAS coller dans App Store Connect)

- L'essai gratuit annoncé ci-dessus ne s'affichera en production QUE si les offres introductives (essai gratuit, 1 semaine) sont configurées dans App Store Connect sur les DEUX produits (mensuel + annuel). Le fichier TideIt.storekit ne sert qu'aux tests locaux.
- Conformité chiffrement : ITSAppUsesNonExemptEncryption déjà déclaré (pas de prompt Export Compliance).
- Licence Open-Meteo (tier gratuit non-commercial) inchangée vs prod actuelle — à traiter plus tard avec le proxy NOAA, hors périmètre de cette build.

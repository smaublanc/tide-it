# Audit des modèles de vent

Scripts qui ont produit les tableaux du § « Le vent : qui dit quoi » de `CLAUDE.md`.
Ils confrontent chaque modèle de prévision au vent **réellement mesuré** par le réseau METAR
public, au même point et à la même heure.

## Lancer

Depuis CE dossier (les scripts ouvrent `stations.json` en chemin relatif) :

```bash
cd audit && python3 audit_modeles.py
```

| script | question |
|---|---|
| `audit_modeles.py` | quel modèle est le plus juste ? (RMSE, biais, MAE) |
| `audit_poids.py` | une pondération entre modèles ferait-elle mieux ? |
| `audit_valid.py` | ce gain survit-il en validation croisée, ou est-ce du surajustement ? |
| `audit_robustesse.py` | l'échantillonnage par voisinage coûte-t-il en justesse ? |

Aucune clé d'API : les deux sources sont publiques et sans authentification.
Compter ~2 min par script (une requête réseau par station).

## `stations.json`

17 stations côtières françaises + `LFOB` (Beauvais, 60 km dans les terres) que **les quatre
scripts excluent** — elle sert de témoin « pas la côte ». Format : `[OACI, nom, lat, lon]`.

⚠️ **Ce fichier a été RECONSTITUÉ le 13 août 2026.** Il n'avait jamais été versionné, alors que
`CLAUDE.md` demande explicitement de rejouer ces scripts en hiver : la consigne était donc
inapplicable. Les 17 codes OACI ont été retrouvés dans `resultats-profond.json`, et les
coordonnées reprises du réseau d'observation lui-même (`FR__ASOS`) plutôt que saisies à la main —
c'est la même source que celle qui fournit les mesures, donc aucun décalage possible entre le
point interrogé et le point mesuré. Vérifié de bout en bout : les 17 se chargent et renvoient
des observations.

Si tu ajoutes une station, prends ses coordonnées au même endroit :
`https://mesonet.agron.iastate.edu/geojson/network/FR__ASOS.geojson`

## À relire avant de conclure quoi que ce soit

**La portée de cet audit est le littoral français, en été.** Vent maximal observé **20 nœuds**,
zéro heure au-delà de 25. Le régime qui décide vraiment d'une session kite n'est PAS dans
l'échantillon. Rejouer ces quatre scripts en hiver avant toute conclusion sur le vent fort —
c'est précisément ce pour quoi `stations.json` devait exister.

`resultats-profond.json` conserve les 11 conclusions de l'audit profond du 10 août 2026
(bootstrap par blocs jour × station), y compris celles qui ont **refusé** un changement.

## Réplication du 13 août 2026

`audit_modeles.py` rejoué de bout en bout sur une fenêtre DIFFÉRENTE (7 jours, 1 200 couples,
les mêmes 17 stations) après reconstitution de `stations.json`. Le classement et les ordres de
grandeur tiennent :

| modèle | biais | RMSE (13 août) | RMSE (audit d'origine) |
|---|---|---|---|
| **meteofrance_seamless** | −0,55 | **3,35** | 3,29 |
| meteofrance_arome_france_hd | −0,56 | 4,18 | 4,02 |
| best_match | −1,68 | 4,27 | 4,08 |
| icon_seamless | −3,29 | 5,42 | 5,04 |
| gfs_seamless | −0,88 | 5,62 | 5,23 |
| ecmwf_ifs025 | −3,55 | 6,44 | 5,79 |

Deux semaines indépendantes, même verdict — y compris la sous-estimation d'ICON (−3,3 km/h) et
d'ECMWF (−3,6). Ça valide à la fois les conclusions et le fichier de stations reconstitué.
**Toujours de l'été** : la réserve sur le vent fort reste entière.

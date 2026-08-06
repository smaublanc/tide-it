# Résultats de recherche — balises littoral FR

Deux passes, toutes deux écourtées par la limite d'utilisation (6 agents sur 24 ont rendu).
Données brutes : `recherche-brute.json`, `recherche-v2-brute.json`.
**Les vérifications ci-dessous ont été refaites à la main au `curl`** — les agents vérificateurs
sont tous morts avant de tourner, leurs affirmations n'engagent qu'eux.

---

## La réponse à la question de départ

> « Trouve d'autres Weameter, les balises sont souvent plus près des spots de kite. »

**Le registre mondial WeeWX est épuisé pour le littoral français.** `weewx.com/api/v2/stations`
recense 1 965 stations déclarées → 381 dans la boîte France → et le dépouillement n'en sort
qu'une poignée de côtières qui publient réellement. Ce n'est pas un échec : c'est une réponse.
Le gisement de « Weameter cachés » est mince, il ne faut plus l'espérer gros.

Ce qui reste vaut par la QUALITÉ de l'emplacement, pas par le nombre.

---

## Retenu

### Cap Fréhel — La Chèvrerie du Cap (22)
`http://www.chevrerie-du-cap.com/meteo/json/weewx_data.json` — **vérifié le 6 août 2026, 20 h 45**

WeeWX skin Belchertown : **format identique à Weameter, aucun parseur à écrire**.
48.662 / −2.302, vent 5 km/h, direction 294°, rafale 13 km/h, horodatage frais.
Contact publié : `chevrerie.du.cap@tiscali.fr`.

⚠️ **Piège d'attribution.** L'ajouter au service Weameter le créditerait « Données : Weameter »,
alors que la station appartient à quelqu'un d'autre. Ce serait faux, et surtout contraire à ce
que promettent les courriers (« votre nom affiché sous la mesure »). Il faut d'abord une source
`.weewx` dont l'attribution porte le nom de l'exploitant — c'est le vrai travail avant d'ajouter
la moindre station tierce.

### Diabox — bornes des ports de plaisance bretons
`https://pubs.diabox.com/dataUpdate.php?dbx_id=<id>&dataName=wind_rt` — **6 identifiants vivants
vérifiés** (101, 108, 109, 110, 114, 115), tous frais, direction en degrés + force.

Des anémomètres **de quai**, donc sur l'eau. Deux obstacles avant d'y toucher :
1. La réponse ne porte **aucune coordonnée** — il faut associer chaque `dbx_id` à un port à la
   main. Un seul est identifié (Concarneau).
2. **Aucune licence, aucune CGU.** Contact : `plaisance.concarneau@portsdecornouaille.fr`.
   → Écrire AVANT d'intégrer.

### Mécanisme WeatherLink « embeddablePage »
`https://www.weatherlink.com/embeddablePage/getData/<token32hex>` — toute station Davis dotée
d'une page publique expose son JSON là. Trouvées : Port de Bandol (capitainerie), Club Nautique
de la Marine à Toulon, Quimper. **Non énumérable** (les jetons sont aléatoires) : ça se récolte
une par une. Accord du propriétaire requis dans tous les cas.

---

## Écarté, et pourquoi

| Source | Motif |
|---|---|
| **IEM `FR__ASOS`** | **REDONDANT.** 109 stations FR fraîches, licence explicitement libre — mais ASOS = aéroports, soit exactement les METAR déjà lus. Chambéry, Clermont-Ferrand, Bastia, Deauville. Zéro spot gagné. |
| **Meteoclimatic** | **INTERDIT**, et c'est le flux lui-même qui le dit : `<copyright>` CC BY-**NC**. |
| **aprs.fi (CWOP)** | **INTERDIT** — les CGU de l'API excluent l'usage commercial. |
| **findu.com** | Licence indéterminée, aucune CGU trouvable → non autorisé par défaut. |
| **Weathercloud** | **INTERDIT** par les CGU, malgré 1 857 appareils près du littoral. Le plus dense et le plus inutilisable. |
| **Windguru** | API interne non documentée → non autorisée par défaut. |
| **openSenseMap** | 24 boîtes sur toute la côte atlantique, **1 seule** avec du vent. |
| **Ifremer / Coriolis** | Catalogue hauturier : aucune station côtière anémométrique. |
| **Opendatasoft SYNOP** | Jeu de données mort, plus aucune donnée récente. |
| **Meteostat** | Licence OK mais agrège SYNOP/METAR = redondant, et les dumps sont historiques. |
| **`montamer`** (Weameter) | 404 sur le JSON et sur la page : entrée périmée du sitemap. |

---

## Adresses de contact récoltées

| Destinataire | Adresse | Type | Objet |
|---|---|---|---|
| Kite Zone School (Hourtin/Lachanau) | contact@kitezone-school.com | société | **exploitant d'une balise DÉJÀ dans l'app** (`lachanau`) |
| La Chèvrerie du Cap (Cap Fréhel) | chevrerie.du.cap@tiscali.fr | société | balise WeeWX |
| Ports de Cornouaille (Concarneau) | plaisance.concarneau@portsdecornouaille.fr | collectivité | bornes Diabox |
| Château Brulesécaille (Tauriac 33) | contact@brulesecaille.com | société | balise WeeWX (estuaire, hors spot) |
| IEM (Iowa State) | akrherz@iastate.edu | institution | sans objet (redondant) |

**Le premier de la liste est le plus important** : `lachanau` est déjà affichée dans l'app, et
on connaît enfin l'exploitant. C'est exactement le courrier « votre station est dans Tide It,
voici comment l'en retirer » — le premier à envoyer.

---

## Reste à faire

1. **Source `.weewx` avec attribution par exploitant** — préalable à toute station tierce.
2. **Écrire à Kite Zone School**, puis Cap Fréhel, puis Concarneau.
3. **Webcams : rien.** Les deux agents sont morts avant de tourner, aux deux passes. Sujet
   entièrement ouvert.
4. Relancer les angles non aboutis : `logiciels-pws`, et tous les vérificateurs.

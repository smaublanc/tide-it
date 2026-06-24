# Spots Kite / Wing & Balises Vent (réseaux non-officiels)

> Objectif : retrouver le **vent temps réel** (anémomètres réels, pas prévision modèle) sur des réseaux **retail / communautaires**.
> **Exclus volontairement** : bouées et stations officielles type Candhis (CEREMA), Météo-France, Marine Nationale, NOAA/NWS.
> Pour chaque spot → le(s) réseau(x) qui ont le plus de chances d'avoir une balise dessus. Tu zoomes sur la carte du réseau pour voir la balise exacte.

---

## 1. Les réseaux de balises (la boîte à outils)

C'est ici l'essentiel : ce sont **les sites qui hébergent les balises**. La majorité des spots ci-dessous renvoient à un ou plusieurs de ces réseaux.

| Réseau | URL | Couverture | Type / Notes |
|---|---|---|---|
| **Winds-Up** | https://www.winds-up.com | 400+ spots — France, Espagne, Italie, Europe | **LA référence retail FR.** ~120 anémomètres propres + 40 webcams + stations partenaires. Force/direction minute par minute, records du jour, marées, alertes. Couvre quasi tous les spots FR majeurs. |
| **Windguru STATIONS** | https://stations.windguru.cz | Mondial | Réseau de stations live (onglet distinct des prévisions Windguru). **Meilleur recoupement international gratuit.** Agrège Holfuy, Davis WeatherLink, Tempest/WeatherFlow, etc. |
| **winds.mobi** | https://winds.mobi | Europe (très dense FR) | Agrégateur communautaire : fusionne **Pioupiou + Windbird + Holfuy + FFVL + METAR**. Open source, gratuit. |
| **OpenWindMap / Pioupiou / Windbird** | https://www.openwindmap.org · https://windbird.com | Europe (FR dense) | Anémomètres autonomes Sigfox, données 100% publiques. API gratuite : `http://api.pioupiou.fr/v1/live/all`. Souvent les mêmes balises que winds.mobi. |
| **Holfuy** | https://holfuy.com/en/map | Europe dense + mondial | Carte live, MAJ ~30 s, beaucoup de stations avec **caméra**. Données poussées vers Windguru out-of-the-box. |
| **FFVL Balises** | https://www.balisemeteo.com | France | Réseau d'origine parapente mais massivement utilisé par les kiters/wingers (cols, plages, lacs). |
| **iKitesurf / WeatherFlow / Tempest** | https://wx.ikitesurf.com | **Amérique du Nord ++**, international partiel | 65 000+ stations Tempest propriétaires sur jetées, bouées côtières, plages. Incontournable pour Maui, Hood River, SF Bay, Floride, Caraïbes. App + web (freemium). |
| **Windy.com** | https://www.windy.com | Mondial | Surcouche modèle + **stations reportées + webcams** (calque "Weather stations"). Utile là où il n'y a pas de réseau communautaire (Brésil, Afrique, Asie). |
| **Romma** | https://www.romma.fr | SE France / Alpes / Rhône | Régional, plutôt inland — d'appoint pour les lacs et l'arrière-pays médit. |
| **KWInd** | app mobile | Mondial (communautaire) | App qui construit un réseau de balises orienté kite + spot guide mondial. Complément. |

**Réflexe :** en France → Winds-Up d'abord, puis winds.mobi/Holfuy en complément. À l'international → Windguru Stations + Windy ; en Amérique du Nord → iKitesurf.

---

## 2. Spots internationaux mythiques

| Spot | Pays / zone | Vent dominant | Où trouver une balise |
|---|---|---|---|
| **Tarifa** (Los Lances, Valdevaqueros, Balneario) | Espagne — Andalousie | Levante (E) / Poniente (O) | Winds-Up ✓ · Windguru Stations · Holfuy — stations live très suivies |
| **Roses / Rosas** | Espagne — Costa Brava | Tramontane | Winds-Up · Windguru Stations |
| **Lo Stagnone** (Marsala) | Italie — Sicile | Thermique / Scirocco | Winds-Up ✓ · Windguru Stations · Holfuy |
| **Le Morne / Anse la Raie** | Maurice | Alizés (SE) | Windguru Stations · Windy |
| **Maui** (Kanaha, Kite Beach, Ho'okipa) | USA — Hawaï | Alizés (NE) | **iKitesurf ✓✓** · Windguru Stations |
| **Hood River / Columbia Gorge** | USA — Oregon | Vent thermique de gorge | **iKitesurf ✓✓** · Windguru Stations |
| **San Francisco Bay** (Crissy, Sherman Island, 3rd Ave) | USA — Californie | Thermique d'été | **iKitesurf ✓✓** |
| **Cabarete** | Rép. Dominicaine | Alizés + thermique | iKitesurf · Windguru Stations |
| **Cumbuco / Cauípe / Préa / Jericoacoara** | Brésil — Ceará | Alizés constants (juil.–janv.) | Windguru Stations · Windy |
| **Ilha do Guajiru / Macapá / Barra Grande** | Brésil — NE | Alizés | Windguru Stations · Windy |
| **Bonaire — Lac Bay** | Antilles néerl. | Alizés | Windguru Stations · Windy |
| **Zanzibar — Paje** | Tanzanie | Mousson (Kaskazi / Kusi) | Windguru Stations · Windy |
| **Dakhla** | Maroc | Alizés N/NE | Windguru Stations · Windy |
| **Égypte** (El Gouna, Soma Bay, Safaga, Nabq/Sharm) | Mer Rouge | Vent N constant | Windguru Stations · Windy |
| **Kalpitiya** | Sri Lanka | Mousson SO | Windguru Stations · Windy |
| **Cape Town — Bloubergstrand** | Afrique du Sud | "Cape Doctor" (SE) | Windguru Stations · Windy |

> À l'international, en l'absence de réseau communautaire local, **Windguru Stations** est le point d'entrée le plus fiable ; **iKitesurf** prend le relais dès qu'on est en Amérique du Nord / Caraïbes.

---

## 3. Spots France par façade

Pour tous ces spots, **Winds-Up** couvre l'immense majorité avec ses propres anémomètres. Les réseaux communautaires (**winds.mobi / Pioupiou / Windbird / Holfuy / FFVL**) ajoutent de la densité, et **Windguru Stations** sert de recoupement.

### Manche / Mer du Nord

| Spot | Plan d'eau / détail | Réseau balise |
|---|---|---|
| **Wissant** | entre Cap Gris-Nez et Blanc-Nez | Winds-Up · winds.mobi/FFVL |
| **Le Touquet / Stella-Plage** | grande plage de sable | Winds-Up |
| **Berck-sur-Mer** | sable, marée forte | Winds-Up |
| **Quend-Plage / Fort-Mahon** | sable | Winds-Up · FFVL |
| **Le Crotoy** | baie de Somme | Winds-Up |
| **Boulogne / Le Portel** | — | Winds-Up · Holfuy |

### Atlantique Nord (Bretagne → Vendée → Loire-Atlantique)

| Spot | Plan d'eau / détail | Réseau balise |
|---|---|---|
| **La Torche** (Pointe de la Torche) | vagues + plat, spot référence Bretagne | Winds-Up ✓ · winds.mobi |
| **Quiberon / Penthièvre / Plouharnel** | presqu'île, sable + vagues | Winds-Up · winds.mobi/Holfuy |
| **La Turballe / Pen Bron** | sable, peu fréquenté | Winds-Up |
| **Pont Mahé / Pont-Mahé** | baie | Winds-Up |
| **La Baule / Pornichet / Le Pouliguen** | baie, tous niveaux | Winds-Up · Holfuy |
| **Batz-sur-Mer (Valentin)** | technique, petit | Winds-Up |
| **Saint-Brevin** | embouchure Loire | Winds-Up |
| **Noirmoutier / Fromentine / La Guérinière / Barbâtre** | sable, plusieurs plages | Winds-Up · winds.mobi |
| **Les Sables-d'Olonne** | — | Winds-Up |
| **La Tranche-sur-Mer** | sable, idéal progression | Winds-Up ✓ |

### Atlantique Sud (Île de Ré → Gironde → Landes → Pays Basque)

| Spot | Plan d'eau / détail | Réseau balise |
|---|---|---|
| **Île de Ré** (Rivedoux Plage / Rivedoux Sud) | sable, technique côté sud | Winds-Up · winds.mobi |
| **La Rochelle / Châtelaillon** | — | Winds-Up |
| **Royan / La Palmyre** | estuaire Gironde | Winds-Up |
| **Bassin d'Arcachon** (Cap Ferret / La Vigne / Banc d'Arguin) | plat + thermiques, marée | Winds-Up ✓ · winds.mobi/Pioupiou |
| **Lacanau** (océan + lac) | vagues / plat | Winds-Up · Pioupiou |
| **Hourtin / Carcans** (lac) | lac plat, thermique d'été | Winds-Up · winds.mobi/FFVL |
| **Montalivet** | océan, sable | Winds-Up |
| **Lac de Sanguinet** | lac plat, école/débutant | Winds-Up · winds.mobi |
| **Hossegor / Seignosse (Les Estagnots)** | vagues, zone dédiée été | Winds-Up |
| **Anglet** | vagues, Pays Basque | Winds-Up |

### Méditerranée (Occitanie → PACA → Corse)

| Spot | Plan d'eau / détail | Réseau balise |
|---|---|---|
| **L'Almanarre / Giens** (Hyères) | spot mythique, 5 km, tous vents | Winds-Up ✓ · Holfuy/winds.mobi |
| **Leucate / Port-Leucate / La Franqui** | Tramontane forte, Mondial du Vent | Winds-Up ✓ · FFVL/Holfuy |
| **La Palme** (étang) | plat, Tramontane | Winds-Up ✓ |
| **Gruissan** | plan d'eau, Défi Kite | Winds-Up ✓ · Holfuy |
| **Port-la-Nouvelle** | sable, Tramontane | Winds-Up |
| **Le Grau-du-Roi / L'Espiguette** | Camargue, sable | Winds-Up · winds.mobi |
| **Étang de Thau / Sète** | plat | Winds-Up · Holfuy |
| **Marseille (Prado / Pointe Rouge)** | Mistral | Winds-Up · winds.mobi |
| **Beauduc** | sauvage, Camargue | Winds-Up |
| **Étang de Berre** | plat, Mistral | Winds-Up · winds.mobi/Romma |
| **Piantarella** (Bonifacio) | Corse, plat turquoise | Winds-Up · Windguru Stations |

---

## 4. Méthode rapide

1. **Spot FR** → ouvre Winds-Up, cherche le spot, lis l'anémomètre + webcam. Recoupe avec winds.mobi/Holfuy si doute.
2. **Spot étranger** → Windguru Stations + Windy (calque stations). Amérique du Nord → iKitesurf.
3. **Donnée brute / automatisation** → API Pioupiou (`api.pioupiou.fr/v1/live/all`) ou stations Holfuy → Windguru, toutes deux exploitables sans scraping de bouée officielle.

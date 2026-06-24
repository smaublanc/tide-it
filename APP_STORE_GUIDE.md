# Guide de Soumission App Store — Tide It

## Table des Matieres
1. [Pre-requis](#1-pre-requis)
2. [App Store Connect — Configuration](#2-app-store-connect--configuration)
3. [Fiche App Store — Textes](#3-fiche-app-store--textes)
4. [Captures d'ecran](#4-captures-decran)
5. [Produits In-App (Abonnements)](#5-produits-in-app-abonnements)
6. [Review Notes](#6-review-notes)
7. [Confidentialite & Privacy](#7-confidentialite--privacy)
8. [Checklist Pre-Soumission](#8-checklist-pre-soumission)
9. [Archive & Upload](#9-archive--upload)
10. [Post-Soumission](#10-post-soumission)

---

## 1. Pre-requis

### Comptes necessaires
- [ ] **Apple Developer Account** (99$/an) — https://developer.apple.com
- [ ] **App Store Connect** — https://appstoreconnect.apple.com
- [ ] **WeatherKit activé** dans le Developer Portal (Identifiers > App IDs > Capabilities)

### Certificats & Provisioning
- [ ] Certificat de distribution iOS (Apple Distribution)
- [ ] Provisioning Profile de distribution pour `seb.Tide-It`
- [ ] Provisioning Profile pour le widget `seb.Tide-It.TideItWidget`
- [ ] Provisioning Profile pour la Watch `seb.Tide-It.watchkitapp`
- [ ] Provisioning Profile pour le Watch Widget `seb.Tide-It.watchkitapp.TideWatchWidget`

### Capabilities a activer dans le Developer Portal
Sur l'App ID `seb.Tide-It` :
- [x] App Groups → `group.seb.Tide-It`
- [x] WeatherKit
- [x] In-App Purchase
- [x] Push Notifications (pour les alertes)

---

## 2. App Store Connect — Configuration

### Creer la fiche
1. Aller sur https://appstoreconnect.apple.com
2. **My Apps** → **+** → **New App**
3. Remplir :
   - **Platform** : iOS
   - **Name** : Tide It
   - **Primary Language** : French
   - **Bundle ID** : seb.Tide-It
   - **SKU** : tideit-v1
   - **User Access** : Full Access

### Informations generales
| Champ | Valeur |
|-------|--------|
| **Bundle ID** | seb.Tide-It |
| **Version** | 2.0 |
| **Build** | 1 |
| **Category primaire** | Weather |
| **Category secondaire** | Sports |
| **Content Rights** | Does not contain third-party content |
| **Age Rating** | 4+ |
| **Copyright** | 2026 Tide It |

---

## 3. Fiche App Store — Textes

### Nom de l'app
```
Tide It
```

### Sous-titre (30 caracteres max)
```
Marees mondiales en temps reel
```

### Mots-cles (100 caracteres max, separes par des virgules)
```
marees,tides,meteo,surf,peche,ports,coefficient,mondial,kayak,nautisme
```

### Description (4000 caracteres max)

```
Tide It — L'application de marees la plus complete. Ports francais, americains et mondiaux.

COUVERTURE MONDIALE
Consultez les marees pour plus de 3 500 ports dans le monde : donnees officielles pour la France, NOAA pour les Etats-Unis, et TideCheck pour le reste du monde. Basculement automatique vers la meilleure source disponible.

COURBE DE MAREE INTERACTIVE
Suivez l'evolution de la maree en temps reel grace a une courbe animee et precise. Un indicateur lumineux suit la courbe avec la hauteur d'eau, la tendance montante/descendante et les conditions de vent en direct. Consultez coefficients et horaires d'un coup d'oeil.

MODE VENT
Activez le mode vent pour coloriser la courbe de maree selon la force du vent. Visualisez en un instant ou le vent souffle fort et ou il est calme, directement sur la courbe.

PREVISIONS DETAILLEES SUR 7 JOURS
Anticipez vos sorties avec les previsions completes : courbe de maree heure par heure avec gradient de vent, vitesse, direction, temperature et houle. Les courbes debordent de l'ecran avec un effet de fondu immersif. Vue annuelle des coefficients en un coup d'oeil.

ALERTES INTELLIGENTES
Creez des alertes personnalisees selon vos criteres : coefficient minimum, hauteur d'eau, direction du vent, lever/coucher du soleil. Combinez les conditions avec des operateurs ET/OU. Alertes en temps reel et previsions vent J+3.

SCORES D'ACTIVITES
Des recommandations sur mesure pour le surf, la peche, le kitesurf, la baignade et la mise a l'eau. Un score combine maree + meteo + vent + coefficient vous indique les meilleurs creneaux sur 7 jours.

CARTE INTERACTIVE
Explorez plus de 3 500 ports sur une carte avec clustering intelligent. Visualisez l'etat de la maree en temps reel pour chaque port. Trouvez les ports les plus proches.

UNITES PERSONNALISABLES
Choisissez votre systeme de mesure (metrique ou imperial) et votre unite de vent preferee : km/h, noeuds, m/s ou mph. Toutes les vues, alertes et widgets s'adaptent automatiquement.

COMPARAISON DE PORTS
Comparez jusqu'a 3 ports simultanement. Superposez les courbes de maree et visualisez les decalages horaires entre vos spots favoris.

PORTS PERSONNALISES
Creez vos propres spots avec un decalage horaire par rapport a un port de reference. Ideal pour les mouillages, les plages ou les zones non repertoriees.

DYNAMIC ISLAND & WIDGETS
Suivez la maree en temps reel directement sur votre Dynamic Island. Les widgets HomeScreen et ecran de verrouillage affichent la prochaine maree et le coefficient du jour. Les unites selectionnees sont respectees partout.

APPLE WATCH
Gardez un oeil sur la maree depuis votre poignet. Complications avec courbe de maree coloree, indicateur temps reel et tendance. App native avec courbe et horaires complets.

APPARENCE ADAPTATIVE
Mode clair, sombre ou automatique selon votre systeme. Interface optimisee pour chaque ambiance.

EXPORT & PARTAGE
Exportez vos previsions en PDF professionnel ou en carte image a partager. Ajoutez les horaires a votre calendrier en un tap.

PREMIUM (optionnel)
- Previsions etendues J+30
- Mode vent sur la courbe
- Export PDF et cartes image
- Alertes illimitees
- Dynamic Island
- Apple Watch (complications & app native)

Donnees officielles France, NOAA (USA) et TideCheck (mondial). Meteo par Apple WeatherKit.
```

### Texte promotionnel (170 caracteres max, modifiable sans nouvelle version)
```
Marees mondiales ! 3 500+ ports, courbe animee, mode vent, unites personnalisables, Apple Watch, Dynamic Island et alertes intelligentes.
```

### What's New (pour la v2.0)
```
Tide It 2.0 — Mise a jour majeure !

COUVERTURE MONDIALE
- 3 500+ ports dans le monde (France, USA, mondial)
- Basculement automatique vers la meilleure source

NOUVELLES FONCTIONNALITES
- Mode vent : la courbe de maree se colore selon la force du vent (Premium)
- Unites personnalisables : metrique/imperial, km/h/noeuds/m-s/mph
- Indicateur de tendance (fleche montante/descendante) sur la courbe
- Previsions detaillees avec courbes plein ecran et fondu sur les bords
- Comparaison de ports : superposez jusqu'a 3 courbes
- Ports personnalises avec decalage horaire
- Planificateur d'activites sur 7 jours (surf, peche, kite, baignade, mise a l'eau)
- Vue annuelle des coefficients (heatmap 6 mois)
- Alertes multi-conditions (ET/OU) avec previsions vent J+3

APPARENCE
- Mode systeme, clair et sombre
- Interface epuree et immersive

APPLE WATCH AMELIOREE
- Complication courbe de maree entierement redessinee
- Unites synchronisees avec l'iPhone
- Rafraichissement plus frequent

WIDGETS
- Widget ecran de verrouillage
- Widget configurable par port
- Unites adaptatives
```

---

### Localisation anglaise (EN)

#### App Name
```
Tide It
```

#### Subtitle (30 chars max)
```
Worldwide Tides in Real Time
```

#### Keywords (100 chars max)
```
tides,weather,surf,fishing,ports,coefficient,diving,kayak,sailing,watch
```

#### Description
```
Tide It — The most complete tide app. French, American and worldwide ports.

WORLDWIDE COVERAGE
Check tides for over 3,500 ports worldwide: official data for France, NOAA for the United States, and TideCheck for the rest of the world. Automatic switching to the best available source.

INTERACTIVE TIDE CURVE
Track the tide in real time with an animated, precise curve. A glowing indicator follows the curve showing water height, rising/falling trend and live wind conditions. Check coefficients and schedules at a glance.

WIND MODE
Enable wind mode to colorize the tide curve by wind strength. Instantly see where wind is strong and where it's calm, right on the curve.

DETAILED 7-DAY FORECAST
Plan your outings with hourly tide curves featuring wind gradient, speed, direction, temperature and swell. Curves bleed off-screen with immersive edge-fading. Year-at-a-glance coefficient heatmap.

SMART ALERTS
Create custom alerts based on your criteria: minimum coefficient, water height, wind direction, sunrise/sunset. Combine conditions with AND/OR operators. Real-time alerts plus 3-day wind forecasts.

ACTIVITY SCORES
Tailored recommendations for surfing, fishing, kitesurfing, swimming and boat launching. A combined score of tide + weather + wind + coefficient shows you the best time slots over 7 days.

INTERACTIVE MAP
Explore over 3,500 ports on a map with smart clustering. See real-time tide status for each port. Find the nearest ports.

CUSTOMIZABLE UNITS
Choose your measurement system (metric or imperial) and preferred wind unit: km/h, knots, m/s or mph. All views, alerts and widgets adapt automatically.

PORT COMPARISON
Compare up to 3 ports simultaneously. Overlay tide curves and visualize time offsets between your favorite spots.

CUSTOM PORTS
Create your own spots with a time offset from a reference port. Perfect for anchorages, beaches or unlisted areas.

DYNAMIC ISLAND & WIDGETS
Track the tide in real time right on your Dynamic Island. Home screen and lock screen widgets show the next tide and today's coefficient. Selected units are respected everywhere.

APPLE WATCH
Keep an eye on the tide from your wrist. Complications with colored tide curve, real-time indicator and trend. Native app with full curve and schedule.

ADAPTIVE APPEARANCE
Light, dark or automatic mode matching your system. Interface optimized for each ambiance.

EXPORT & SHARING
Export your forecasts as a professional PDF or shareable image card. Add schedules to your calendar in one tap.

PREMIUM (optional)
- Extended forecast D+30
- Wind mode on the curve
- PDF and image card export
- Unlimited alerts
- Dynamic Island
- Apple Watch (complications & native app)

Official data France, NOAA (USA) and TideCheck (worldwide). Weather by Apple WeatherKit.
```

#### What's New (v2.0)
```
Tide It 2.0 — Major Update!

WORLDWIDE COVERAGE
- 3,500+ ports worldwide (France, USA, international)
- Automatic source selection

NEW FEATURES
- Wind mode: tide curve colored by wind strength (Premium)
- Customizable units: metric/imperial, km-h/knots/m-s/mph
- Rising/falling trend indicator on the curve
- Full-bleed detailed forecasts with edge-fading effect
- Port comparison: overlay up to 3 curves
- Custom ports with time offset
- 7-day activity planner (surfing, fishing, kite, swimming, boat launch)
- Year-at-a-glance coefficient heatmap
- Multi-condition alerts (AND/OR) with 3-day wind forecasts

APPEARANCE
- System, light and dark modes
- Clean, immersive interface

IMPROVED APPLE WATCH
- Fully redesigned tide curve complication
- Units synced with iPhone
- More frequent updates

WIDGETS
- Lock screen widget
- Configurable widget per port
- Adaptive units
```

#### Promotional Text
```
Worldwide tides! 3,500+ ports, animated curve, wind mode, customizable units, Apple Watch, Dynamic Island and smart alerts.
```

---

### Support URL
```
https://tideit.app/support
```
*(Creer une page simple avec un formulaire de contact ou un email)*

### Privacy Policy URL (OBLIGATOIRE)
```
https://tideit.app/privacy
```
*(Creer une page de politique de confidentialite — voir section 7)*

---

## 4. Captures d'ecran

### Tailles requises

| Appareil | Taille (px) | Requis |
|----------|-------------|--------|
| **iPhone 6.9"** (iPhone 16 Pro Max) | 1320 x 2868 | Obligatoire |
| **iPhone 6.3"** (iPhone 16 Pro) | 1206 x 2622 | Optionnel |
| **iPhone 6.7"** (iPhone 16 Plus) | 1290 x 2796 | Optionnel |
| **iPad Pro 13"** | 2048 x 2732 | Si iPad supporté |
| **Apple Watch** | 410 x 502 (Series 10 46mm) | Obligatoire |

### Captures recommandees (6-10 par taille)

#### iPhone — 6 captures minimum
1. **Dashboard principal** — Courbe de maree + prochaine maree + meteo
   - Texte overlay : "Marees en temps reel pour 3 500+ ports"
2. **Carte interactive** — Vue carte avec les ports et etats de maree
   - Texte overlay : "Explorez 3 500+ ports dans le monde"
3. **Alertes** — Liste d'alertes avec conditions personnalisees
   - Texte overlay : "Alertes intelligentes personnalisees"
4. **Scores d'activites** — Cards d'activites avec scores colores
   - Texte overlay : "Le meilleur moment pour votre activite"
5. **Calendrier** — Vue calendrier avec coefficients
   - Texte overlay : "Previsions sur 7 jours"
6. **Dynamic Island** — Screenshot du Dynamic Island actif
   - Texte overlay : "Marees en direct sur votre iPhone"

#### Apple Watch — 3 captures minimum
1. Vue principale avec maree actuelle
2. Liste des prochaines marees
3. Complication sur cadran

### Comment prendre les captures
```bash
# Lancer le simulateur
xcrun simctl boot "iPhone 17 Pro Max"

# Prendre une capture
xcrun simctl io booted screenshot ~/Desktop/screenshot_1.png

# Ou depuis Xcode : Window > Devices and Simulators > screenshot
```

### Conseils design
- Fond sombre (l'app est dark-only, ca rendra bien)
- Ajouter un texte descriptif au-dessus de chaque capture avec Figma/Canva
- Utiliser un mockup iPhone pour encadrer les captures
- Police recommandee : SF Pro Display Bold, couleur cyan (#00D4FF)
- Pas de bezel/status bar si tu utilises un mockup

---

## 5. Produits In-App (Abonnements)

### Configurer les abonnements dans App Store Connect

1. **My Apps** → **Tide It** → **Subscriptions**
2. Creer un **Subscription Group** : `Tide It Premium`
3. Ajouter 2 produits :

#### Produit 1 : Mensuel
| Champ | Valeur |
|-------|--------|
| **Reference Name** | Premium Mensuel |
| **Product ID** | `com.tideit.premium.monthly` |
| **Duration** | 1 Month |
| **Price** | Tier 3 (2,99 EUR) |
| **Display Name (FR)** | Premium Mensuel |
| **Description (FR)** | Previsions J+30, mode vent, export PDF, alertes illimitees, Dynamic Island et Apple Watch. |

#### Produit 2 : Annuel
| Champ | Valeur |
|-------|--------|
| **Reference Name** | Premium Annuel |
| **Product ID** | `com.tideit.premium.yearly` |
| **Duration** | 1 Year |
| **Price** | Tier 20 (19,99 EUR) — ~44% de reduction vs mensuel |
| **Display Name (FR)** | Premium Annuel |
| **Description (FR)** | Previsions J+30, mode vent, export PDF, alertes illimitees, Dynamic Island et Apple Watch. Economisez plus de 40% ! |

### Subscription Group Localisation (FR)
- **Nom du groupe** : Tide It Premium
- **App Name displayed** : Tide It

### Offre d'essai gratuit (recommande)
- **Free Trial** : 7 jours pour l'abonnement annuel
- Configuration : Subscription > Introductory Offers > Free Trial, 1 Week

### Fichier StoreKit Configuration (pour les tests)
Tu devras creer un fichier `TideIt.storekit` dans Xcode :
1. File → New → File → StoreKit Configuration File
2. Ajouter les 2 abonnements avec les memes Product IDs
3. Dans le scheme, ajouter le fichier StoreKit pour le testing

---

## 6. Review Notes

### Notes pour l'equipe de review Apple

```
Tide It est une application de marees couvrant plus de 3 500 ports dans le monde.

COMPTE DE TEST :
Aucun compte necessaire. L'application fonctionne immediatement apres le choix d'un port lors de l'onboarding.

SOURCES DE DONNEES :
Les donnees de marees proviennent de 3 sources selon la region :
- NOAA (National Oceanic and Atmospheric Administration) pour les ports americains
- TideCheck / WorldTides API pour les ports mondiaux
L'app selectionne automatiquement la meilleure source disponible.

FONCTIONNALITES PREMIUM :
Les fonctionnalites premium (Previsions J+30, Mode vent, Export PDF, Dynamic Island, Apple Watch, alertes illimitees) sont accessibles via l'abonnement. Les fonctionnalites gratuites permettent une utilisation complete de l'app : consultation des marees, carte, calendrier 7 jours, 2 alertes, comparaison de ports, choix des unites et export texte.

APPLE WATCH :
L'app inclut une app watchOS native avec complications WidgetKit (accessory families). Les complications affichent une courbe de maree coloree, la prochaine maree, la hauteur d'eau et le coefficient. Les donnees sont partagees via WatchConnectivity et App Group. C'est une fonctionnalite premium.

LOCALISATION :
La localisation est utilisee uniquement pour trouver les ports les plus proches. L'app fonctionne parfaitement sans localisation — l'utilisateur peut choisir manuellement son port.

CALENDRIER :
L'acces au calendrier est demande uniquement lorsque l'utilisateur choisit d'exporter les horaires de marees vers son calendrier.

WEATHERKIT :
L'app utilise WeatherKit pour les donnees meteorologiques et marines. Un droit WeatherKit est requis sur l'App ID.

LIVE ACTIVITY :
L'app propose une Live Activity (Dynamic Island) qui affiche la maree en temps reel. C'est une fonctionnalite premium.

NOTIFICATIONS :
Les notifications sont utilisees pour les alertes de marees configurees par l'utilisateur.

API EXTERNE :
L'app utilise l'API TideCheck (tidecheck.com) pour les ports mondiaux avec une cle API integree. Cette API est gratuite jusqu'a 50 requetes/jour avec fallback vers le calcul harmonique offline.
```

### Demo Video (optionnel mais recommande)
- Montrer l'onboarding (choix de port)
- Scroller le dashboard
- Montrer la carte
- Creer une alerte
- Activer le Dynamic Island
- Montrer le widget

---

## 7. Confidentialite & Privacy

### App Privacy (App Store Connect)

Aller dans **App Privacy** et remplir :

#### Donnees collectees

| Type de donnee | Utilisation | Lie a l'identite | Tracking |
|----------------|-------------|-------------------|----------|
| Precise Location | App Functionality | Non | Non |

#### Donnees NON collectees
- Aucune donnee analytique
- Aucun identifiant publicitaire
- Aucune donnee de sante
- Aucune donnee financiere
- Aucune donnee de contact

### PrivacyInfo.xcprivacy (deja cree)
Le fichier a ete ajoute au projet. Il declare :
- **Tracking** : Non
- **Collected Data** : Precise Location (App Functionality only, not linked, not tracking)
- **API Usage** : UserDefaults (App Group data sharing)

### Politique de confidentialite (a creer sur ton site)
Creer une page `https://tideit.app/privacy` avec :

```
POLITIQUE DE CONFIDENTIALITE — TIDE IT

Derniere mise a jour : Mars 2026

1. DONNEES COLLECTEES
Tide It collecte votre position geographique uniquement pour :
- Identifier les ports a proximite
- Afficher les donnees meteorologiques locales
Votre position n'est jamais stockee sur nos serveurs ni partagee avec des tiers.

2. DONNEES STOCKEES LOCALEMENT
- Port favori et preferences (sur votre appareil)
- Configuration des alertes (sur votre appareil)
- Donnees de marees en cache (sur votre appareil)

3. SERVICES TIERS
- Apple WeatherKit : pour les donnees meteorologiques
- Apple StoreKit : pour la gestion des abonnements
Aucun autre service tiers n'est utilise.

4. TRACKING
Tide It n'utilise aucun outil de tracking, d'analytique ou de publicite.

5. CONTACT
Pour toute question : contact@tideit.app
```

---

## 8. Checklist Pre-Soumission

### Code & Build
- [x] Build iOS reussi (iPhone 17 Pro, iOS 26)
- [x] Build Widget reussi
- [x] Build Watch reussi
- [x] Premium gates en place (J+30, PDF, Live Activity, Mode vent, limite alertes)
- [x] PrivacyInfo.xcprivacy ajoute
- [ ] **Ajouter PrivacyInfo.xcprivacy au target dans Xcode** (Build Phases > Copy Bundle Resources)
- [ ] Tester le parcours complet sur un vrai appareil
- [ ] Tester l'achat in-app en sandbox
- [ ] Verifier que l'app fonctionne sans connexion (mode offline graceful)
- [ ] Tester avec VoiceOver (accessibilite)

### App Store Connect
- [ ] Fiche creee avec textes FR
- [ ] Captures d'ecran uploadees (iPhone + Apple Watch)
- [ ] Abonnements configures et soumis pour review
- [ ] Privacy Policy URL active
- [ ] Support URL active
- [ ] App Privacy rempli
- [ ] Review Notes remplies
- [ ] Age Rating configure (4+)

### Certificats
- [ ] Distribution Certificate valide
- [ ] Provisioning Profiles a jour pour les 3 targets
- [ ] WeatherKit capability active dans le Developer Portal
- [ ] App Group `group.seb.Tide-It` configure pour les 3 targets
- [ ] In-App Purchase capability active

---

## 9. Archive & Upload

### Etape 1 : Preparer l'archive
1. Dans Xcode, selectionner le scheme **Tide It**
2. Selectionner **Any iOS Device (arm64)** comme destination
3. **Product** → **Archive** (Cmd+Shift+B ne suffit pas, il faut Archive)
4. Attendre la fin de l'archivage

### Etape 2 : Valider l'archive
1. L'Organizer s'ouvre automatiquement
2. Selectionner l'archive
3. Cliquer **Validate App**
4. Choisir **Automatically manage signing**
5. Corriger les eventuelles erreurs

### Etape 3 : Uploader
1. Cliquer **Distribute App**
2. Choisir **App Store Connect**
3. Choisir **Upload**
4. Laisser Xcode gerer le signing automatiquement
5. Attendre le traitement (5-15 minutes cote Apple)

### Etape 4 : Selectionner le build
1. Retourner sur App Store Connect
2. Aller dans la version 1.0
3. Sous **Build**, cliquer le **+** et selectionner le build uploade
4. Remplir les derniers champs manquants

### Etape 5 : Soumettre
1. Verifier que tout est vert (pas de warnings)
2. Cliquer **Submit for Review**
3. Choisir : **Automatically release this version** (ou manual si tu preferes)

---

## 10. Post-Soumission

### Delais de review
- **Premiere soumission** : 24-48h en general (parfois jusqu'a 7 jours)
- **Mises a jour** : souvent < 24h

### Rejections courantes a anticiper
1. **Metadata Rejection** : descriptions non conformes, captures trompeuses
2. **WeatherKit** : s'assurer que le droit est bien actif
3. **Subscriptions** : s'assurer que le restore est fonctionnel et visible
4. **Location** : justifier l'usage de la localisation dans les notes de review
5. **Privacy Policy** : URL doit etre accessible et correspondre a l'usage reel

### Apres approbation
- [ ] Verifier l'affichage sur l'App Store
- [ ] Tester un achat reel (abonnement)
- [ ] Configurer les notifications de reviews (App Store Connect > Notifications)
- [ ] Preparer la v1.1 avec les retours utilisateurs

---

## Resume des URLs a creer

| URL | Usage |
|-----|-------|
| `https://tideit.app` | Site web de l'app |
| `https://tideit.app/privacy` | Politique de confidentialite (OBLIGATOIRE) |
| `https://tideit.app/support` | Page de support (OBLIGATOIRE) |
| `https://tideit.app/terms` | Conditions d'utilisation (recommande pour les abonnements) |

---

*Guide mis a jour le 28 mars 2026 pour Tide It v2.0*

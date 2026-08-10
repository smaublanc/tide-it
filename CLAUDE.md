# Tide It — guide de maintenance

App iOS 26 SwiftUI (+ widgets, + Apple Watch) : marées + vent réel + surf pour riders.
Marque : **précision, honnêteté, faible batterie**. 12 langues (fr source). Mode : **maintenance**
(plus de grosses features — correctifs et mises à jour uniquement).

## Compiler (sans booter de simulateur)
```bash
xcodebuild build -scheme "Tide It" -project "Tide It.xcodeproj" -configuration Debug \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```
Vérifier `BUILD SUCCEEDED` + zéro `error:`. Si `database is locked` (Xcode ouvert) : ajouter
`-derivedDataPath /tmp/dd_iso`. **Compiler après chaque lot d'édits Swift, committer seulement vert.**

## Release App Store
Runbook complet : `fastlane/README_DELIVER.md` (procédure générique + pièges vérifiés).
Résumé : bump `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` (pbxproj, 12 configs) → notes de maj
12 langues SANS emoji → `fastlane deliver` (crée la version + pousse les métadonnées) → archive
Xcode → attacher le build via spaceship (`deliver --build_number` NE l'attache PAS) → soumettre.
Une seule version éditable à la fois sur App Store Connect.

## Règles non négociables
1. **i18n** : jamais `Text(variableString)` ni `Text(cond ? "a" : "b")` (init String = verbatim FR).
   → `Text("littéral")`, `(cond ? Text("a") : Text("b"))`, ou `String(localized:)` pour les
   interpolations. Toute nouvelle clé = 12 langues dans `Localizable.xcstrings` **ET** dans les
   catalogues d'extension si la chaîne y apparaît (`TideItWidget/`, `Tide Watch Watch App/`,
   `TideWatchWidget/`, `Tide It/InfoPlist.xcstrings`).
2. **Purge** : tout NOUVEL état par-port doit être purgé dans `TideService.purgePortState`
   (qui distingue suppression vs simple retrait des favoris — voir `portStillExists`).
3. **Honnêteté** : ne jamais afficher une valeur fabriquée/interpolée comme une mesure ;
   nil → l'élément disparaît. Jamais de nom de source de données (SHOM/NOAA/Open-Meteo/…)
   dans une copy publique App Store — l'attribution vit derrière les liens in-app uniquement.
4. **Nouveaux fichiers Swift iOS** : membership EXPLICITE dans le pbxproj (4 entrées, mirror
   d'un fichier existant, `plutil -lint`). Widgets/Watch = FS-synced (auto).
5. **WidgetSharedData** : tout nouveau champ doit aussi être porté par `resolvedSharedData`
   (sinon widget vide).

## Le vent : qui dit quoi (règle d'architecture, non négociable)

**La balise n'entre JAMAIS dans la prévision. Le réel est là pour confirmer.**

| | Source | Rôle |
|---|---|---|
| **Prévision** | UN modèle, le mieux résolu qui réponde : `meteofrance_seamless` (AROME 1,3 km → ARPEGE) → `icon_seamless` → `gfs_seamless` | dire ce qu'il VA faire |
| **Réel** | balise (`WindStationAggregator`), âge toujours affiché | dire ce qu'il FAIT, et confirmer l'instant présent |
| **Confiance** | écart entre les 3 modèles (`windConfidence`) | dire à quel point les modèles s'accordent |

- **Vitesse, rafale ET direction viennent du MÊME modèle.** Moyenner AROME (1,3 km) avec ICON
  (11 km) et GFS (27 km) importait leur incapacité STRUCTURELLE à résoudre le trait de côte :
  au Cap Ferret, AROME donnait 18 nds et la moyenne 12,5 — le Bassin abrité passait pour plus
  venté que le front de mer. Mélanger les directions donnait en plus un cap qu'aucun modèle
  n'avait prévu, alors que le on/off/side-shore décide d'une session.
- **`ForecastBiasService` MESURE, il ne corrige pas.** Les deux fonctions de correction
  (`debiased`, `debiasedSeries`) ont été supprimées : une balise abritée tirait vers le bas la
  prévision d'un spot océan, et une balise en panne depuis la veille continuait de déformer
  sept jours avec ses derniers échantillons (tampon 48 h). Ne pas les réintroduire.
- **Balise affichée : 15 km maximum** (`WindStationAggregator.defaultSearchRadius`, était 60 km).
  Au Cap Ferret, l'app montrait « réel 9 nds » face à une prévision de 17 : la mesure venait
  d'une station à l'intérieur des terres. Les deux valeurs étaient justes chacune chez elle et
  leur juxtaposition ne voulait rien dire — or cette mesure pilote aussi le « Go X% » live.
  Une confirmation doit venir du même endroit ; sinon, ne rien montrer.
- **La seule intervention légitime du réel** est `ActivityScoreService.refinedForecasts` :
  bornée à maintenant → +2 h, mesure de moins de 20 min (bouée : 60 min). C'est la CONFIRMATION
  de l'instant, pas une retouche de prévision.
### Audit de calibration (9 août 2026 — 17 stations côtières, 2 800 heures mesurées)

Vent horaire RÉELLEMENT observé (réseau METAR public) confronté à chaque modèle au même point.

| modèle | biais | **RMSE** | MAE |
|---|---|---|---|
| **meteofrance_seamless** | −0,65 | **3,29** | 2,44 |
| meteofrance_arome_france_hd | −0,65 | 4,02 | 3,05 |
| best_match | −1,65 | 4,08 | 2,98 |
| icon_seamless | **−3,09** | 5,04 | 3,85 |
| gfs_seamless | −0,73 | 5,23 | 3,92 |
| ecmwf_ifs025 | −3,10 | 5,79 | 4,43 |

- **Météo-France gagne sur 16 stations sur 17.** L'ancienne moyenne 0,50/0,30/0,20 donnait 3,44 —
  soit PIRE que Météo-France seul. Moyenner dégradait la prévision.
- **ICON sous-estime le vent côtier de 3,1 km/h en moyenne** (ECMWF aussi). Ce n'est pas du
  bruit : c'est l'incapacité d'une maille de 11 km à résoudre un trait de côte.
- **Des coefficients ne valent PAS le détour.** Optimum mesuré (MF 0,75 / GFS 0,15 / AROME 0,05 /
  ICON 0,05) : RMSE 3,18. Mais en VALIDATION CROISÉE (poids appris sur la moitié du réseau,
  testés sur l'autre, 12 découpages) le gain tombe à **+0,07 km/h** (σ 0,04) — un tiers du gain
  apparent était du surajustement. 0,07 km/h, c'est 0,04 nœud : invisible. Le modèle seul est
  retenu, et il garde l'avantage décisif de donner vitesse, rafale ET direction cohérentes.
- **L'accord entre modèles prédit l'erreur, mais seulement jusqu'à 0,75.** Erreur par tranche de
  confiance : 3,48 (0,2–0,5) → 2,53 → 2,17 (0,7–0,85) → 2,27 → 2,34. Au-delà de ~0,75 elle ne
  baisse plus. D'où `AheadCandidate.confidenceCeiling` : classer 0,96 devant 0,88 était trancher
  sur du bruit. Le seuil de rejet à 0,6 est en revanche VALIDÉ (l'erreur y bondit).

Scripts de l'audit : `audit/audit_modeles.py`, `audit_poids.py`, `audit_valid.py`.

### Audit profond (10 août 2026 — 3 130 couples, bootstrap par blocs jour × station)

- **Météo-France gagne les QUATRE façades**, et le plus largement là où on l'attendait le moins :
  +0,94 km/h d'avance en Méditerranée–Corse contre +0,40 en Bretagne. Sur 2 000 tirages, la
  probabilité qu'un autre modèle le batte est de **0,0 % partout**. Un choix de modèle PAR RÉGION
  serait une régression : ne pas le tenter.
- **⚠️ `best_match` n'est PAS un mélange — c'est un choix par point, et Open-Meteo y choisit ICON**
  sur TOUTE la Manche, plus Nice, Bastia et Ajaccio : exactement les traits de côte qu'une maille
  de 11 km ne sait pas résoudre. Demander explicitement `meteofrance_seamless` en premier n'est
  pas une préférence, c'est ce qui protège l'app de ce piège. Ne jamais retomber sur `best_match`.
- **Dans la zone NAVIGABLE, le réglage est déjà à son meilleur.** Biais de MF conditionné sur la
  valeur affichée : −1,02 / −0,51 / −0,47 km/h (tranches 0-10 / 10-20 / 20-30), et l'erreur
  RELATIVE s'améliore quand ça monte : 45 % → 21 % → **17 %** du vent moyen.
- **Le « biais qui se creuse dans le vent fort » est un artefact.** Conditionner sur l'observation
  (variable bruitée) fabrique un retour à la moyenne : en conditionnant sur le modèle, le signe
  s'INVERSE. Ne pas « corriger » ce faux biais.
- **RÉSERVE MAJEURE** : ces mesures portent sur 8 jours d'août. Vent maximal observé **20 nds**,
  zéro heure au-delà de 25 nds. Le régime qui compte vraiment pour le kite n'est PAS dans
  l'échantillon — rejouer les scripts en hiver avant toute conclusion sur le vent fort.

- **NE PAS décaler le point d'échantillonnage vers le large.** Essayé (2 km dans la direction
  `shoreOrientation`), mesuré, RETIRÉ. La maille TERRE d'AROME décrit assez bien la zone où l'on
  navigue vraiment — les premières centaines de mètres, encore sous influence côtière — alors que
  2 km au large, c'est du vent de pleine mer. Avec le décalage, l'app annonçait 8 à 9 nds de plus
  que tous les autres sites de prévision kite. Un spot mal placé se corrige dans le CATALOGUE,
  jamais par la façon de l'interroger.
- **Confiance plafonnée à 0,5 quand le modèle fin a disparu** (Météo-France s'arrête ~J+5).
  Au-delà, ICON et GFS s'accordent souvent parce qu'ils commettent la MÊME erreur : leur accord
  est un angle mort partagé, pas une preuve.

### Ce que l'audit a changé — et ce qu'il a REFUSÉ de changer

**Appliqué** (défauts STRUCTURELS, valables partout sur la planète) :
- **Seuils de rafales dédoublés.** La rafale d'un modèle est un maximum HORAIRE, celle d'une
  balise une moyenne sur 10 min : deux échelles, un seul jeu de seuils. Médiane du ratio prévu
  1,72 quand ça rafale vraiment, 1,56 sinon — le seuil du badge (1,55) passait SOUS les deux.
  L'app criait « rafaleux » sur **80,6 %** de ses heures ventées, dont **53 % de faux prouvés**,
  pour 11,3 points de note GO en moins. Côté prévision : 1,45 / 1,70, poids 0,16 → **0,10**
  (l'AUC de 0,773 soutient un facteur modéré, pas une pénalité de 11 points). Le badge balise
  garde 1,25 / 1,55, calibrés sur la mesure — NE PAS les réunifier.
- **Marge de 10 km/h avant le gate dur de rafales** (= l'erreur type du modèle sur la rafale).
  Sans elle, les gates hauts se déclenchaient à tort **38 %** (50 km/h) à **51 %** (62 km/h) du
  temps. Un gate de sécurité qui crie faux une fois sur deux finit ignoré, donc dangereux.

**REFUSÉ, et c'est le plus important** — mesuré puis écarté, ne pas retenter :
- **Corriger le biais de Météo-France** : gain hors échantillon +0,026 ± 0,062 km/h, et NÉGATIF
  en multiplicatif. P(gain > 0,3) = 0 % sur 400 découpages.
- **Corriger l'amplitude de la brise thermique** : le modèle est À L'HEURE (décalage mesuré
  +0,10 h ± 0,17 — aucun déphasage), il sous-développe le pic de 2,4 km/h, mais la correction
  ne rend que +0,246 km/h — sous le seuil de bruit.
- **Un modèle par façade maritime** : 0,0 % de probabilité qu'un autre batte Météo-France, sur
  les quatre façades.
- **Les 15 autres modèles testés** (AROME 2,5 km, ARPEGE, AIFS, UKMO ×3, KNMI, DMI, ICON-EU,
  ICON-D2, ARPAE, GEM, JMA) : aucun ne bat `meteofrance_seamless`, écart au deuxième +0,60 km/h
  [IC95 +0,44 ; +0,77]. Les paris régionaux sont réfutés : UKMO 2 km perd 1,54 km/h sur la
  Manche et la Bretagne.
- **Réordonner ICON/GFS dans le repli.** GFS bat ICON de +0,70 km/h à J+5 *en France* — mais
  l'audit est FRANÇAIS, et le repli sert surtout le RESTE DU MONDE, où l'ordre doit rester celui
  de la résolution (ICON 11 km avant GFS 27 km). Et GFS est catastrophique sur la rafale
  (biais −10,3 km/h, corrélation du ratio −0,07 : aucune information). On ne réordonne pas une
  chaîne mondiale sur une mesure locale.

⚠️ **PORTÉE DE L'AUDIT** : littoral français, été. Vent maximal observé 20 nds. Rien de ce qui
précède ne vaut mesure hors de France ni en vent fort — seuls les défauts d'ÉCHELLE (rafales,
gates) ont été appliqués, parce qu'ils tiennent à la nature des données, pas à la géographie.

## Seuils recalibrables (constantes nommées, après retours terrain)
- `WindSteadiness` (ObservedWindCard.swift) : `minAvgKmh=12`, `laminarMaxRatio=1.25`,
  `gustyMinRatio=1.55` — badge Laminaire/Irrégulier/Rafaleux **ET** facteur « Rafales » du
  moteur GO (kiteWingScore, poids 0.16 : laminaire=1, irrégulier 1→0.45, rafaleux 0.45→0 à ×2 ;
  rafales ≥ plafond rider `windCeiling` = gate dur 0 ; pas de donnée rafales = pas de facteur).
- `ForecastBiasService.BiasReadout` : `minSamples=4`, `maxStationKm=8`, `maxAge=3h`,
  `meaningfulBiasKmh=2.5` — jauge de confiance UNIQUEMENT (plus aucune correction). 8 km et non
  25 : au-delà, une balise est dans un autre régime de vent et son écart ne décrit plus ce spot.
- `surfSessionStars` (ActivityScoreService.swift ~l.455) : poids/caps des étoiles surf.
- `refinedForecasts` (ActivityScoreService.swift ~l.405) : horizon +2 h, gates d'âge balise 20 min /
  bouée 60 min.
- `PremiumManager.welcomeTrialDays=30` (mois offert). Droit payant mis en cache avec son
  échéance (`paidEntitlementUntil_v1`) et amorcé SYNCHRONEMENT à l'init : sans ça `paidPremium`
  vaut false à chaque réveil en arrière-plan → l'abonné ne reçoit aucune notif GO.
- `SurfProvider.stickySurfMaxAge=12h` — le widget surf « collant » ne ressert le dernier spot
  visité que dans cette fenêtre ; au-delà il n'affiche rien plutôt qu'une houle périmée.
- `WidgetDataWriter.observedCarryMaxAge=3h` / `forecastCarryMaxAge=6h` — anti-régression du
  widget Vent : une écriture marée-seule (caches vent vides au réveil) REPORTE la dernière
  mesure du même port au lieu de l'effacer ; au-delà des gates elle meurt (l'âge est affiché).

## Pièges vérifiés (ne pas réintroduire)
- **`MKOverlayRenderer.draw`** (TintRenderer, MapView.swift) : remplir `rect(for: mapRect)` — la
  TUILE demandée — et JAMAIS `rect(for: overlay.boundingMapRect)` (= `.world`). MapKit appelle
  `draw()` une fois par tuile : remplir le rect monde à chaque appel rasterise un CGRect de
  ~268 M × 268 M points par tuile → la carte mettait **10 s** à s'afficher (mode sombre seul, la
  teinte n'y étant installée que là). Rendu identique, l'union des tuiles = le monde.
- **`?? 0` sur une mesure** : une valeur ABSENTE ne doit jamais devenir une mesure. `wAvg ?? 0`
  donnait un « 0 km/h » indiscernable d'un calme plat, `wDir ?? 0` un cap plein Nord dessiné à
  la flèche, `waveHeight ?? 0` un « Flat 0,0 m ». Rendre la mesure ABSENTE (reading nil,
  `MarineConditions.hasWaveData`) — jamais la remplacer par un zéro.
- **Ternaire de littéraux** : `Text(cond ? "a" : "b")` EST localisé par SwiftUI (les deux
  branches sont des `LocalizedStringKey`). La règle 1 est plus large que la réalité — le vrai
  piège est `Text(uneVariableString)` et les branches non-littérales.
- **Marées et port** : `selectedPort.didSet` vide `tideData` (ou le repose depuis le cache
  synchrone). Sans ça, les marées du port précédent s'affichent sous le nouveau nom.
- **Lookups par id sur les catalogues** : `SurfSpotCatalog.spot(id:)` est O(1) (`spotsByID`,
  reconstruit dans `rebuild()`). La carte teste l'appartenance surf pour chacun des ~3 500 ports
  à chaque re-render — un `first { $0.id == }` y coûtait ~1 M de comparaisons par passe.
- **`.equatable()` + `Date()` interne = temps GELÉ**. Une vue montée avec `.equatable()` n'est
  re-rendue que si son `==` change. Un `Date()` lu au vol DANS un calcul n'entre dans aucune
  comparaison : curseur « maintenant », en-têtes de jour, âge d'une mesure restent bloqués (au
  passage de minuit, `WeekTrendBands` affichait encore la veille). L'instant doit être une
  PROPRIÉTÉ de la vue, **quantifié** au pas que l'affichage sait montrer — `TodayView.bandsClock`
  (15 min ; 900 s tombe pile sur minuit, tous les fuseaux étant décalés d'un multiple de 15 min)
  et `ObservedWindCard.currentTime`. Ça garde le bénéfice perf sans mentir sur l'heure.
- **Fraîcheur balise** : une mesure vieille ne doit pas être seulement ÉTIQUETÉE, elle doit être
  redemandée. `TodayView.refreshObservedWind()` (tick 60 s + retour au premier plan) redemande
  quand l'affiché dépasse `observedWindStaleMinutes` (10, = le seuil du badge « frais » : une
  seule définition) **ou a disparu** — une station qui se tait sort des 30 min de
  `nearestReading` et, sans ce cas, plus aucune tentative jusqu'au changement de port. Pas de
  polling : le TTL de 3 min de l'agrégateur borne le réseau, une mesure fraîche ne déclenche rien.
- **Jour = fuseau du PORT** partout, jamais `Calendar.current` (cf. `Calendar.inTimeZone`). Vaut
  aussi pour le `DateFormatter` des libellés : sinon un minuit « port » se formate à la veille.

## Risques connus (surveiller, pas de fix code possible)
- **Licence Open-Meteo** : usage commercial = LE point juridique ouvert (self-host = solution).
- **Clés API hardcodées** (`APIKeys.swift`, gitignoré) : quota partagé ; à terme proxy.
  Vieilles clés WorldTides/TideCheck livrées en 4.x : à révoquer côté fournisseurs.
- **Balises tierces** (Pioupiou, winds.mobi, Weameter slugs `andernos/pauillac/lachanau`, METAR,
  NDBC) : mort silencieuse acceptée — l'app dégrade sans balise, mais vérifier après incident.
- Premium debug : `debugForcePremium` est `#if DEBUG` uniquement (jamais en App Store).

## Contact / comptes
Support : tideitapp@icloud.com · App Store id 6743555259 (`seb.Tide-It`) ·
clé API ASC : `~/.appstoreconnect/key.json` (JAMAIS committer, ni les `.p8`).

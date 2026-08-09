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
- **La seule intervention légitime du réel** est `ActivityScoreService.refinedForecasts` :
  bornée à maintenant → +2 h, mesure de moins de 20 min (bouée : 60 min). C'est la CONFIRMATION
  de l'instant, pas une retouche de prévision.
- **La prévision d'un spot est échantillonnée 2 km AU LARGE** (`MarineWeatherService.samplingCoordinate`,
  dans la direction `shoreOrientation` déclarée par le spot). AROME travaille à 1,3 km : sur une
  côte à dune large, la maille contenant la plage est classée TERRE et sa rugosité divise le vent
  par deux. Mesuré à Lacanau : 9,3 nds au point du spot contre 18,1 à 2 km au large. Ce n'est pas
  un artifice pour gonfler le vent — c'est la position où l'on navigue. Sans `shoreOrientation`,
  aucun décalage : on ne devine jamais où est la mer.
- **Confiance plafonnée à 0,5 quand le modèle fin a disparu** (Météo-France s'arrête ~J+5).
  Au-delà, ICON et GFS s'accordent souvent parce qu'ils commettent la MÊME erreur : leur accord
  est un angle mort partagé, pas une preuve.

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

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

## Seuils recalibrables (constantes nommées, après retours terrain)
- `WindSteadiness` (ObservedWindCard.swift) : `minAvgKmh=12`, `laminarMaxRatio=1.25`,
  `gustyMinRatio=1.55` — badge Laminaire/Irrégulier/Rafaleux **ET** facteur « Rafales » du
  moteur GO (kiteWingScore, poids 0.16 : laminaire=1, irrégulier 1→0.45, rafaleux 0.45→0 à ×2 ;
  rafales ≥ plafond rider `windCeiling` = gate dur 0 ; pas de donnée rafales = pas de facteur).
- `ForecastBiasService.BiasReadout` : `minSamples=4`, `maxStationKm=25`, `maxAge=3h`,
  `meaningfulBiasKmh=2.5` — jauge de confiance + correction premium.
- `surfSessionStars` (ActivityScoreService.swift ~l.455) : poids/caps des étoiles surf.
- `refinedForecasts` (ActivityScoreService.swift ~l.405) : horizon +2 h, gates d'âge balise 20 min /
  bouée 60 min.
- `PremiumManager.welcomeTrialDays=30` (mois offert).

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

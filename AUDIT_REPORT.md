# Audit profond — Tide It (iOS / watchOS)

Audit multi-agents (11 sous-systèmes, 39 agents, ~233 findings) suivi de corrections
vérifiées et rebuild des deux cibles. Ce document liste **ce qui a été corrigé** puis
**ce qui reste** (recommandations classées par valeur/effort).

Chaque correction d'algorithme a été **vérifiée manuellement contre le code réel** avant
édition (la passe de vérification adversariale automatique ayant été coupée par une limite
de session). Les corrections du moteur harmonique ont en plus été prouvées
numériquement et verrouillées par des tests unitaires anti-régression.

---

## 1. Corrections appliquées (29 findings critical/high)

### Moteur de marées — précision (le cœur)

| # | Sévérité | Fichier | Correction |
|---|----------|---------|------------|
| Arguments V₀ | high | `HarmonicTideEngine.swift` | **MU2, NU2, L2, LAM2** avaient un argument astronomique faux (jusqu'à ~78° d'erreur de phase). Corrigé vers Schureman/IHO et **prouvé** : le taux de V₀ doit égaler `vitesse − espèce·15°/h` (vérifié au millième près pour les 24 constituants). |
| Facteur nodal f(L2) | high | `HarmonicTideEngine.swift` | Formule de Schureman mal transcrite (`tan(I)/2` au lieu de `tan²(½I)`, `abs()` masquant un signe) → amplitude L2 fausse de ±70 %. Réécrite : `f(L2)=f(M2)·√(1−12·tan²(½I)·cos2P+36·tan⁴(½I))`. |
| Z₀ international | **critical** | `PortCatalog.swift`, `HarmonicTideEngine.swift`, `TideService.swift` | Les 3712 stations NOAA/TICON avaient `meanSeaLevel = 0` → toutes les basses mers clampées à 0,00 m et hauteurs centrées faux. Z₀ désormais **dérivé paresseusement** (zéro hydrographique = plus basse mer astronomique) à la première consultation du port, hors main-thread, mémoïsé. |
| Constituants longue période | high | `PortCatalog.swift` | **SA/SSA/MM/MF/MSF** stockés en MAJUSCULES dans les JSON mais cherchés en `Mf/Mm/Ssa/Sa/MSf` → silencieusement rejetés pour **tous** les ports (y compris français). Lookup rendu insensible à la casse + normalisation de l'id canonique. |
| Coefficient J8-J30 | high | `HarmonicTideEngine.swift` | Les prévisions étendues créaient des marées avec `coefficient: nil` → aucun badge de coef dans ExtendedForecast/Calendar. `estimateCoefficient` rendu `nonisolated static` et appelé dans `computeExtrema`. |
| Étale inversée | high | `TideCalculator.swift` | Juste avant chaque PM (progress > 0.95), « étale basse » était affichée (et vice-versa) car la marée *précédente* servait des deux côtés. Distingué les deux bords (`nxt` près de 1, `prev` près de 0). |

Migration `harmonicsV6Migrated` : purge unique des prédictions cachées et calibrations de
l'ancien modèle au prochain lancement.

### Bugs visibles utilisateur

| # | Sévérité | Fichier | Correction |
|---|----------|---------|------------|
| Vent fantôme watch | **critical** | `WidgetDataWriter.swift` | Les utilisateurs non-premium près d'une balise voyaient « 0 km/h N » sur 3 surfaces watch (le verrou premium envoyait 0/0). Désormais la valeur est `nil` quand verrouillée (station + flag conservés pour l'upsell) → corrige **toutes** les surfaces d'un coup. |
| Hauteur héro en mètres | high | `TodayView.swift` | Le plus gros chiffre du dashboard restait en `m` pour les utilisateurs impériaux. Passe par `UnitFormatter`. |
| Race condition port | high | `TodayView.swift` | `loadPortData()` lançait une `Task` non annulée → un changement rapide de port affichait la météo/soleil du mauvais port. Task stockée, annulée, et gardes `selectedPort.id == port.id` avant chaque écriture. |
| Dégradé vent figé | high | `TodayView.swift` | Le dégradé vent n'était reconstruit que sur `openMeteoForecasts.count` (toujours ~168) → couleurs du port précédent. Observe désormais l'identité réelle des données + `startDate`. |
| ObservedWindCard figé | high | `ObservedWindCard.swift` | `.equatable()` figeait l'âge de la mesure et la pastille « live » (périmé affiché comme frais). Ajout de `currentTime` à l'égalité → rafraîchi chaque minute, perf scroll préservée. |
| Calcul solaire Pacifique | high | `WidgetDataWriter.swift` | L'événement était figé sur le jour UTC d'entrée → coucher 24 h trop tôt pour les ports à lon ≲ -80° (« Sorties Parfaites » cassées sur le Pacifique/Asie, sunset < sunrise). Corrigé : UT normalisé en heure-du-jour puis **décalé de ±24 h vers le midi local du jour demandé** (gère LA/Tahiti/Tokyo sans casser Greenwich). Vérifié par simulation + 4 tests solaires. |
| Côte « Méditerranée » mondiale | high | `PecheAPied.swift` | `CoastType.at` (écrit pour la France) classait New York/Boston en « Méditerranée ». Borné à la France métropolitaine ; cas `.generic` (« Littoral ») sinon. |
| Fuseau Siri | high | `TideAppIntents.swift` | Les horaires Siri sortaient dans le fuseau de l'appareil. Résolus dans le fuseau du port (DOM-TOM, ports étrangers, voyage). |

### Notifications & alertes

| # | Sévérité | Fichier | Correction |
|---|----------|---------|------------|
| Delegate manquant | high | `Tide_ItApp.swift`, `TideAlert.swift` | Aucun `UNUserNotificationCenterDelegate` → notifications supprimées au premier plan, cooldown jamais démarré. Ajout d'un `AppDelegate` (`willPresent` → bannière/son ; `didReceive` → cooldown via le store persistant). |
| Combinaison ET | high | `NotificationScheduler.swift` | `max(conditionDates)` faisait sonner le preset « surf » (coef>80 ET <2 h avant PM) **à** la PM. Séparé l'ancrage **temporel** (timeBefore/after, soleil) du **filtre ambiant** (coef, hauteur). |
| Alertes vent prévisionnelles | high | `TideAlertEvaluator.swift` | La condition vent était évaluée isolément, ignorant `requireAllConditions` → « Alerte vent » trompeuse dès qu'une journée était calme. Restreint aux alertes où le vent décide seul ; titre adapté à l'opérateur. |
| Reschedule background | high | `Tide_ItApp.swift`, `WidgetSharedData.swift`, `WidgetDataWriter.swift` | Le background refresh reprogrammait avec `portId: nil` → notifs sur mauvais port + alertes soleil effacées toutes les 30 min. Ajout de `portId/latitude/longitude` (rétro-compatibles) aux données partagées + passage du port et de la localisation réels. |

### Live Activity & Watch

| # | Sévérité | Fichier | Correction |
|---|----------|---------|------------|
| Live Activity mauvais port | high | `TideService.swift`, `LiveActivityManager.swift` | Le bandeau gardait le nom de l'ancien port avec les marées du nouveau (attribut figé). Détection du changement de port → redémarrage avec les bons attributs. |
| WCSession perdu | high | `WatchSessionManager.swift` | Le 1ᵉʳ envoi avant activation de la session était jeté (le log mentait « différé »). Ajout d'un `pendingData` flushé dans `activationDidCompleteWith`. |
| Vent watch périmé | high | `TideWatchComplication.swift`, `Tide Watch Watch App/ContentView.swift` | `observedWindDate` n'était jamais lu → une mesure de 9 h affichée « en direct » à 18 h. Masquage au-delà de 90 min sur la complication et l'app. |

### Localisation (partiel)

- `TodayView.swift` : ternaires de `String` (« Montante »/« Descendante », « Pleine mer »/
  « Basse mer ») qui contournaient le catalogue 5 langues → convertis en ternaires de `Text`
  littéraux (« Aujourd'hui »/« Demain » via `String(localized:)`).

### Tests anti-régression ajoutés (`Tide_ItTests.swift`)

- `testConstituentV0SpeedConsistency` — verrouille la cohérence V₀↔vitesse des 24 constituants.
- `testCurrentStateSlackJustBeforeHighTide` — verrouille l'étale juste avant la PM.
- `testSolarPacificPortDayLength` — verrouille le report de jour UTC (Tahiti).

**Build iOS + watchOS : SUCCESS. Suite de tests : 46 passées / 0 échec.**

---

## 2. Recommandations (non corrigées — décision produit/effort)

### Architecture / backend (à arbitrer)

1. **Clés API live en dur + quota partagé** (`APIKeys.swift`, `TideRepository.swift`).
   `tc_live_…` (TideCheck, 50 req/jour **pour toute la base utilisateurs**) et WorldTides
   sont compilées dans le binaire (extractibles via `strings`). La source primaire des ports
   mondiaux est donc structurellement en panne dès quelques dizaines d'utilisateurs.
   → **Proxy backend** (Cloudflare Worker/Lambda) détenant les clés, cache serveur par
   station (une prédiction 7 j sert tous les utilisateurs du port), rate-limit par device
   (App Attest). **Révoquer/régénérer ces clés avant la prochaine release publique.**
   Le fallback harmonique offline étant désormais correct (Z₀ dérivé), il couvre la panne.

2. **Complications watch sans push** (`WatchDataManager.swift`). Les complications ne
   reçoivent de nouvelles données qu'à l'ouverture de l'app watch.
   → `transferCurrentComplicationUserInfo` côté iPhone + `scheduleBackgroundRefresh` côté watch.

3. **Live Activity sans mise à jour background** (`LiveActivityManager.swift`). `pushType: nil`,
   `isStale` ignoré. → lire `context.isStale` dans les vues, mettre à jour dans le BGTask,
   programmer une fin ; à terme push updates.

### Code mort à retirer (~3 000+ lignes)

- Sous-système de **calibrage** mort (~600 lignes, `HarmonicTideEngine.swift`) — contient un
  bug V₀ latent.
- Composants jamais montés (~1 300 lignes) : `NextTideCard`, `TidalCurrentView`,
  `WaterWaveBackground`, états loading/empty…
- **Dossier `Views/Weather/` entier** (`WeatherDashboardView`, `WindCompassView`,
  `WeatherTileView`) — dont une boussole à la convention de direction inversée.
- `TideTableView` (427 l), `ActivityPlannerView` (336 l, second moteur de scoring divergent),
  clustering SwiftUI de `MapView` (~350 l), `TideGraphView`, `TideError`/`predictCurve`/
  `CurveCalculationCache`.
- `CloudSyncService` (sync iCloud alertes + port : annoncée, jamais branchée).

> Retirer du code mort est sûr **mais** doit être fait fichier par fichier en confirmant
> l'absence de référence (cibles, previews, App Intents). À faire en lot dédié.

### Précision (raffinements)

- **Coefficient SHOM** : la formule actuelle `(PM−Z0)/(M2+S2)×100` s'écarte de ±5-12 points
  de la convention officielle `C=(H−N0)/U×100`. Calcul par demi-marnage `(PM−BM)/2` rapporté
  à l'unité de Brest serait conforme.
- **Phase de lune** (`TodayView.swift`) : référence ancrée à minuit au lieu de 18:14 UTC du
  6 janvier 2000 → ~18 h de biais systématique.
- **Z₀ dérivé** : scanner le cycle nodal complet (18,6 ans) plutôt qu'1 an le rendrait
  déterministe (actuellement ancré à `Date()`).
- Datums mélangés (MLLW/LAT/MSL) selon la source qui répond pour un même port.
- METAR « VRB » (vent variable) affiché comme un Nord établi (`AviationWeatherService`).

### Perf / batterie

- `TodayView` : `TideMetrics` + path complet de courbe reconstruits à **chaque frame de
  scroll** ; `DateFormatter` recréés par render (alors que `CachedDateFormatter` existe).
- `TideParticleField` : Canvas 30 fps qui tourne hors écran.
- `ticon_stations.json` (3,7 Mo) décodé **deux fois** au lancement.
- Évaluateur d'alertes : appel WeatherKit complet toutes les 5 min sans TTL.
- `TodayView.swift` = god-file de 3 097 lignes / ~15 types → à découper.

### Robustesse

- Triple duplication de `WidgetSharedData` (iOS / Watch App / TideWatchWidget) sans champ de
  version, déjà divergente. → fichier unique partagé entre cibles + champ `schemaVersion`.
- Limite iOS des 64 notifications pendantes non gérée.

---

## 3. Améliorations appliquées — 4 chantiers « Ferrari » (build iOS+watch vert, tests verts)

### Track 1 — Précision ultime du moteur
- **Phase de lune** : référence ré-ancrée à la nouvelle lune RÉELLE du 6 janv. 2000 18:14 UTC
  (au lieu de minuit) → ~18 h de biais systématique supprimé.
- **Z₀ déterministe** : balayage ancré à une date FIXE (au lieu de `Date()`) → le zéro
  hydrographique ne dérive plus d'un lancement/année à l'autre ; fenêtre portée à 425 j
  (cycle périgée-vive-eau).
- **Coefficient demi-marnage** : `(PM − BM)/2` au lieu de `(PM − Z₀)` → invariant au décalage
  saisonnier (Sa/Ssa, désormais réintégrés) et à l'asymétrie. + test `testCoefficient…`.

### Track 2 — Perf & batterie
- `ticon_stations.json` (3,7 Mo) décodé **une seule fois** (cache statique partagé) au lieu de
  deux au lancement.
- `formatTime` de la courbe → `CachedDateFormatter` (plus de `DateFormatter` créé par label
  pendant le scroll).
- Évaluateur d'alertes : **early-exit** si aucune alerte active → plus d'appel WeatherKit
  toutes les 5 min pour rien (la majorité des utilisateurs).

### Track 3 — Solidité release
- **Persistance d'alertes non destructive** : décodage tolérant par élément (`LossyDecode`) +
  suppression du `removeObject` qui effaçait tout au moindre échec.
- **Complications watch poussées** via `transferCurrentComplicationUserInfo` (budget garanti),
  throttlé — plus de complication figée tant que l'app watch n'est pas ouverte.
- **Live Activity** : indicateur `isStale` (données figées >30 min signalées au lieu d'être
  montrées comme « en direct »).
- Template `APIKeys.swift.example` présent (rotation + proxy = action backend, cf. §2.1).

### Track 4 — Nettoyage code mort
- **6 fichiers de vues mortes retirés** (TideTableView, ActivityPlannerView, TidalCurrentView,
  WeatherDashboardView, WindCompassView, WeatherTileView) + entrées pbxproj, et la méthode
  morte `predictCurve` — ~1 400 lignes. Le build a révélé que `NextTideCard.swift` contient
  `AnimatedCountdown` (utilisé par TodayView) → fichier **conservé**.
- **Reste à faire (review dédiée, plus risqué)** : sous-système de calibrage (~600 l, deps
  multi-niveaux dans le moteur), clustering SwiftUI de `MapView` (~350 l intra-fichier),
  `CloudSyncService` (référencé via `.shared` — sync interne morte mais service utilisé),
  découpe du god-file `TodayView` (3 097 l → ajout de fichiers au pbxproj). `TideError` est
  RÉFÉRENCÉ (TideData.swift) — l'audit se trompait, à conserver.

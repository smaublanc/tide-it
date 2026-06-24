# Plan : Redesign Dashboard + Fix Apple Review

## 1. Redesign OceanDashboardCard → épuré + météo 7 jours

**Problème** : La carte actuelle est trop chargée (5 sections empilées) et ne s'intègre pas avec le style épuré de la courbe. La météo ne couvre que le jour courant.

**Solution** : Réécrire `OceanDashboardCard` en gardant UNIQUEMENT les sections essentielles avec un design beaucoup plus aéré, et ajouter une barre météo 7 jours monochrome.

### Nouvelle structure (3 sections au lieu de 5) :

```
┌────────────────────────────────────────────┐
│  2.0 m   ↑ Montante        4h46 → PM      │  ← Tide Hero (inchangé, épuré)
│  ↓1.7m 15:44   (28)   22:43 3.0m ↑       │
│  ━━━━━━━━━━━●━━━━━━━━━━━━━━━━━━━          │
├────────────────────────────────────────────┤
│  ≋ Courant   H2/6 · 2/12 ↑               │  ← Flow (inchangé)
│  [1][2][3][3][2][1]                        │
├────────────────────────────────────────────┤
│  Jeu  Ven  Sam  Dim  Lun  Mar  Mer        │  ← NOUVEAU : 7-day weather strip
│   ☁    ☀    ☁    🌧   ☀    ☁    ☀         │  (icônes monochrome blancs)
│  13°  15°  14°  12°  16°  14°  15°        │
│  20   15   25   30   10   18   22  km/h   │
├────────────────────────────────────────────┤
│  🐟65  🏄75  🪁70  🏊25  ⛵60             │  ← Activities (inchangé)
└────────────────────────────────────────────┘
```

**Changements** :
- **Supprimer** `weatherConditionsSection` (4 stats du jour) — redondant avec la barre 7j
- **Supprimer** `hourlyForecastSection` (12h horizontal scroll avec icônes jaunes)
- **Ajouter** `weeklyWeatherStrip` : 7 colonnes = jour abrégé + icône monochrome (`.white.opacity(0.7)`) + temp + vent
- **Ajouter** `dailyForecast: [DayWeather]` comme paramètre du composant
- **Icônes monochrome** : même SF Symbols mais en `.white.opacity(0.7)` au lieu de `.yellow`

### Fichier modifié : `TodayView.swift`
- OceanDashboardCard : supprimer 2 sections, ajouter weeklyWeatherStrip
- Appel du composant : ajouter `dailyForecast: weatherService.dailyForecast`

---

## 2. Fix Apple 5.2.5 — Apple Weather Attribution

**Problème** : L'app utilise WeatherKit sans afficher l'attribution  Weather + lien légal.

**Solution** : Ajouter dans `SettingsView` > section "À propos" une row Apple Weather avec lien vers `https://weatherkit.apple.com/legal-attribution.html`. Aussi ajouter un petit texte ` Weather` en bas du dashboard.

### Fichiers modifiés :
- `SettingsView.swift` : Nouvelle row " Weather" avec Link vers page légale
- `OceanDashboardCard` : Petit footer ` Weather` discret sous les activités

---

## 3. Fix Apple 3.1.2(c) — Terms of Use / EULA

**Problème** : Pas de lien CGU dans l'app.

**Solution** : Créer une page `docs/terms.html` avec les CGU standard, et ajouter un lien dans SettingsView + dans la description App Store.

### Fichiers :
- `docs/terms.html` : Page CGU (conditions générales d'utilisation)
- `SettingsView.swift` : Nouvelle row "Conditions d'utilisation" avec Link
- `SettingsView.swift` : Nouvelle row "Politique de confidentialité" avec Link

---

## 4. Note Apple 2.1(b) — IAP non soumis

C'est une action **App Store Connect** (pas du code). Le user devra :
- Aller dans App Store Connect > In-App Purchases
- Soumettre les IAP avec screenshot
- Re-soumettre le binaire

→ Je fournirai les instructions au user après les fixes code.

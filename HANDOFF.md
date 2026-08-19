# Reprise — état au 19 août 2026

Version lisible (téléphone) : https://claude.ai/code/artifact/7b2749c0-0a32-480e-815f-70db7e13c526

## État

| | |
|---|---|
| Prête à livrer | **5.4.0 / build 21** |
| En vente aujourd'hui | 5.3.1 / build 19 |
| Dernier commit | `735eb7d`, poussé sur `v5.2.0` **et** `main` |
| Build Release | `** BUILD SUCCEEDED **` |
| Notes 12 langues | 12/12 validées (`python3 tools/check_notes.py`) |
| **App Store Connect** | **rien d'envoyé** |
| **Archive Xcode** | **pas faite** |

## 1. Livrer la 5.4.0 — BLOQUANT

Séquence stricte, runbook complet dans `fastlane/README_DELIVER.md` (étapes 4 à 7).

1. **Métadonnées** — commande à passer par Sébastien (le garde-fou de l'auto mode refuse
   toute publication externe ; ne pas tenter de le contourner) :
   ```
   cd "/Users/maublanc/Desktop/Tide It 5.3"
   export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
   fastlane deliver --api_key_path "$HOME/.appstoreconnect/key.json" \
     --app_version "5.4.0" --skip_binary_upload --skip_screenshots \
     --run_precheck_before_submit false --force
   ```
2. **Archive** Xcode → attendre VALID (~10 min).
3. **Attacher le build** via spaceship — `--build_number` NE l'attache PAS.
4. **Soumettre**, sortie manuelle.

## 2. À regarder avant d'archiver

- **Le bandeau météo n'a jamais été vu tourner.** Ce qui a été montré était un calcul de la
  rampe, pas une capture. L'alpha est passé de 0,16–0,72 à **0,92 constant** et l'encre bascule
  désormais noir/blanc selon la bande. Vérifier en mode **clair ET sombre** — le mode clair est
  celui qui changeait le plus (`TodayView.bandAlpha`, `bandTextColor`).
- **Les étoiles surf** : les fenêtres GO ont été validées, les étoiles non, et trois gates les
  ont durcies.

## 3. Correctifs mesurés, prêts à coder (maintenance)

- **`capOversized` inverse l'échelle avec la période** — `ActivityScoreService.swift:579`.
  Le plafond porte sur la hauteur déferlante, qui monte avec la période : à 1,5 m,
  **13 s note moins bien que 12 s** et affiche « Trop gros » rouge. C'est à l'envers.
- **`capLowEnergy` rend 4★/5★ inatteignables** — `:582`. Écrase à 45 % dès `energyIndex < 18`,
  mesuré sur **77 % des heures**. Les gates 5.4 ont réparé le « oui à tout » ; pas cette moitié.
- **Champs morts d'`ActivityScore`** : ~8 600 allocations de chaînes par recalcul, jamais lues.
- **`enabledSetups(...).filter{...}`** recopié 3 fois.
- **`tools/check_sources.py`** ne surveille pas l'endpoint `extras`.

## 4. Gestes de Sébastien (sans tokens)

- Installer le moniteur hebdomadaire : `launchctl`, mode d'emploi dans
  `tools/com.tideit.sources.plist`.
- Relancer Jean-Louis (Winds-Up) pour la 2e webcam de Hyères — cf. `outreach/REPONSES.md`.
- Guetter les réponses Winds-Up / FFVL (demandes d'API envoyées le 18 août).

## 5. Trous de connaissance — les plus graves

- **Tout l'audit tient sur 8 jours d'août. Vent max observé 20 nds, zéro heure au-delà de 25.**
  Le régime kite n'a jamais été mesuré. Rejouer `audit/*.py` en hiver AVANT toute conclusion
  sur le vent fort. Ne coûte pas de tokens.
- **Licence du fournisseur de prévision** : palier gratuit non-commercial, conditions citant
  les « apps qui ont des abonnements ». À ne pas confondre avec « pas de payant pour l'instant »,
  qui portait sur l'achat d'une MEILLEURE API — ici il s'agit d'être en règle sur celle dont
  l'app dépend déjà. Détail dans `CLAUDE.md` § Risques connus.

## 6. Décidé d'explorer (hors maintenance — arbitrage de Sébastien)

- **Ajouter une balise par son adresse.** L'architecture existe déjà : cas `.weewx`
  (« école de kite, camping, particulier »), structure `{ id, url, source, homepage }`, parseur
  en place, liste de retrait distante pour couper. Trois règles non négociables :
  **reconnaisseur jamais scraper** (les unités : « 18 » peut être km/h, nœuds, m/s ou mph — se
  tromper envoie un rider surtoilé) ; **valider avant d'enregistrer** en montrant la mesure
  obtenue ; au-delà de 15 km **afficher sans alimenter** `refinedForecasts`.
  Prolongement : un `stations.json` distant, lu comme `docs/blocklist.json` l'est déjà,
  diffuserait une balise proposée à tous les téléphones sans mise à jour App Store.
- **Les trois pistes d'intelligence** (vérifiées absentes du code) : aucun retour rider,
  historique d'erreur de prévision stocké mais jamais montré, aucune préférence de marée
  par spot.

## Piège à ne pas confondre avec un problème

`Localizable.xcstrings` **oscille** entre Debug et Release : l'extracteur ne voit pas les
chaînes sous `#if DEBUG`. Un diff sur ce fichier après une vérification d'avant-archive n'est
pas un signal — vérifier seulement qu'aucune clé AYANT des traductions ne disparaît
(`git diff --stat`).

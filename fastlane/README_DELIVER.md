# Pousser les textes App Store (7 langues) en une commande — Fastlane `deliver`

## 🚀 RUNBOOK — publier la prochaine version X.Y.Z (générique, validé jusqu'à 5.2.3)

1. **Bump** : `MARKETING_VERSION` + `CURRENT_PROJECT_VERSION` dans le pbxproj (12 configs,
   remplacement global), `plutil -lint` pour valider.
2. **Notes de maj** : `fastlane/metadata/<locale>/release_notes.txt` pour les 12 locales
   (fr-FR, en-US, de-DE, es-ES, it, nl-NL, pt-PT, zh-Hans, zh-Hant, ja, ko, hi).
3. **Métadonnées** (crée la version + pousse les 12 langues) — la version précédente doit être
   EN LIGNE (une seule version éditable à la fois) :
```
cd "/Users/maublanc/Desktop/Tide It 18"
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
fastlane deliver --api_key_path "$HOME/.appstoreconnect/key.json" \
  --app_version "X.Y.Z" --skip_binary_upload --skip_screenshots \
  --run_precheck_before_submit false --force
```
4. **Archive** dans Xcode (Product ▸ Archive ▸ Distribute ▸ App Store Connect), attendre
   l'état VALID (~10 min).
5. **Attacher le build** — `deliver --build_number` NE l'attache PAS (raté connu) → spaceship :
   `version.select_build(build_id:)` (ruby bundlé fastlane, GEM_HOME=/usr/local/Cellar/fastlane/*/libexec).
6. **Soumettre** :
```
fastlane deliver --api_key_path "$HOME/.appstoreconnect/key.json" \
  --app_version "X.Y.Z" --build_number "N" --skip_metadata --skip_screenshots \
  --submit_for_review --automatic_release false --run_precheck_before_submit false --force
```

**Pièges vérifiés (tous rencontrés en vrai) :**
- ❌ **AUCUN emoji** dans `release_notes.txt` NI `promotional_text.txt` (Apple rejette les deux).
- ❌ Toute **NOUVELLE locale** exige un `supportUrl` (sinon « missing required attribute ») →
  copier celui d'en-US via spaceship `localization.update(attributes:)`.
- ❌ Login Apple ID ne marche plus pour les métadonnées → clé API obligatoire (`key.json`, jamais commitée).
- Le promo d'une offre (« 1 mois offert ») doit rester attaché à la version qui CONTIENT l'offre.
- `name.txt` absent = nom inchangé ; deliver ne touche que les fichiers présents.

---

## ✅ COMMANDE QUI MARCHE (validée juin 2026) — à réutiliser
La clé API est déjà configurée dans `~/.appstoreconnect/key.json`. Pour repousser après avoir édité un .txt :
```
cd "/Users/maublanc/Desktop/Tide It 18"
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
fastlane deliver --api_key_path "$HOME/.appstoreconnect/key.json" \
  --app_version "5.1.0" --skip_binary_upload --skip_screenshots \
  --run_precheck_before_submit false --force
```
**2 pièges rencontrés (déjà réglés ici) :**
- ❌ Login Apple ID + mot de passe ne marche PLUS pour les métadonnées (erreurs 500 / `@token.refresh!`). → Il FAUT la clé API App Store Connect (.p8).
- ❌ Apple refuse les **emoji** dans « Nouveautés » (`release_notes.txt`) **ET** dans le **Texte promotionnel** (`promotional_text.txt`) — vérifié juin 2026 (« Promotional Text can't contain 🎁 »). → Aucun emoji dans ces deux fichiers.
- Le `key.json` contient la clé privée → ne JAMAIS le committer (il est hors du repo, dans `~/.appstoreconnect/`).

---


Tous les textes sont déjà dans `fastlane/metadata/<langue>/` :
`promotional_text.txt` · `description.txt` · `release_notes.txt` (= Nouveautés de la version).
Langues : fr-FR, en-US, de-DE, it, es-ES, nl-NL, pt-PT.

## 1. Installer fastlane (une fois)
```
brew install fastlane
```
(ou `sudo gem install fastlane`)

## 2. S'authentifier — clé API App Store Connect (recommandé, pas de 2FA)
1. App Store Connect → **Users and Access → Integrations → App Store Connect API** → génère une clé (rôle App Manager).
2. Note **Issuer ID** + **Key ID**, télécharge le fichier **AuthKey_XXXX.p8** (téléchargeable une seule fois).
3. Place-le hors du repo (ex. `~/.appstoreconnect/AuthKey_XXXX.p8`) — NE PAS committer.

> Alternative simple : décommente `apple_id("ton@email.com")` dans `fastlane/Appfile` et connecte-toi avec ton Apple ID (un mot de passe spécifique à l'app + 2FA seront demandés).

## 3. Créer la version 5.1.0 dans App Store Connect
Dans App Store Connect, crée la version **5.1.0** (bouton « + Version ou plateforme ») — elle doit être à l'état « Prête à soumettre » pour recevoir les Nouveautés. (fastlane peut aussi la créer avec `--app_version "5.1.0"`.)

## 4. Pousser TOUS les textes (sans binaire, sans captures)
Depuis la racine du projet :
```
fastlane deliver \
  --api_key_path ~/.appstoreconnect/key.json \
  --app_version "5.1.0" \
  --skip_binary_upload --skip_screenshots \
  --force
```
- `--skip_binary_upload --skip_screenshots` : on n'envoie QUE les métadonnées (promo + description + nouveautés), dans les 7 langues.
- `--force` : pas de page de prévisualisation HTML à confirmer.
- Ça **téléverse** les textes ; ça ne **soumet pas**. Tu revois et tu soumets dans App Store Connect (ou ajoute `--submit_for_review`).

### Format de `key.json` (pour `--api_key_path`)
```json
{
  "key_id": "XXXXXXXXXX",
  "issuer_id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "key_filepath": "/Users/<toi>/.appstoreconnect/AuthKey_XXXXXXXXXX.p8",
  "in_house": false
}
```

## Notes
- `promotional_text` se met à jour **quand tu veux** (même app déjà en ligne), sans nouvelle soumission.
- `description` et `release_notes` s'appliquent à la version en préparation (5.1.0).
- Aucune source de données n'est citée dans ces textes (attribution = liens in-app). Ne pas en rajouter.
- Champs non fournis (nom, sous-titre, mots-clés) : laissés tels quels — `deliver` ne touche qu'aux fichiers présents.

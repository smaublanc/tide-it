# Pousser les textes App Store (7 langues) en une commande — Fastlane `deliver`

## 🚀 PROCHAINE MAJ — 5.2.1 (build 7) : mois Premium offert + jauge de confiance

**Séquence (App Store Connect n'autorise qu'UNE version éditable à la fois) :**
1. La **5.2.0 (build 6)** finit sa review et **sort** (mode surf). Tant qu'elle est en review, impossible de créer la 5.2.1.
2. Archive le **build 7** dans Xcode (Product ▸ Archive ▸ Distribute ▸ App Store Connect). Il monte comme build 7 / 5.2.1.
3. Une fois la 5.2.0 **en ligne**, crée la version **5.2.1** dans App Store Connect (ou laisse `--app_version "5.2.1"` la créer), attache le build 7.
4. Pousse les textes (7 langues) — **promo « 1 mois offert » + Nouveautés 5.2.1 + sous-titres/mots-clés optimisés** :
```
cd "/Users/maublanc/Desktop/Tide It 18"
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
fastlane deliver --api_key_path "$HOME/.appstoreconnect/key.json" \
  --app_version "5.2.1" --skip_binary_upload --skip_screenshots \
  --run_precheck_before_submit false --force
```
5. Dans App Store Connect : vérifie, sélectionne le build 7, **soumets** (ou ajoute `--submit_for_review` à la commande).

**Garde-fous (déjà respectés dans les .txt) :**
- ✅ **AUCUN emoji dans `release_notes.txt` NI `promotional_text.txt`** — Apple rejette l'emoji dans LES DEUX (vérifié : « Promotional Text can't contain 🎁 »). Texte brut uniquement.
- ✅ Le **promo « 1 mois offert » ne doit PAS être poussé sur la 5.2.0** (build 6 n'a pas le mois offert → fausse promesse). Il part avec 5.2.1 seulement. (Le promo est éditable en direct, donc OK dès que 5.2.1 est en ligne.)
- ✅ `name.txt` absent = nom inchangé ; sous-titre/mots-clés présents = ré-affirmés (identiques à 5.2.0, no-op).
- ✅ Aucune source de données citée.

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

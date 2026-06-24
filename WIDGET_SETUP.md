# Configuration du widget Tide It

Le widget est préparé. Suivez ces étapes pour l’ajouter au projet Xcode :

## 1. Créer la cible Widget Extension

1. Dans Xcode : **File → New → Target**
2. Choisir **Widget Extension**
3. Cliquer **Next**
4. Renseigner :
   - **Product Name** : `TideItWidget`
   - **Include Configuration App Intent** : décochée
   - **Include Live Activity** : décochée
5. Cliquer **Finish**
6. Si Xcode propose d’activer le schéma, cliquer **Activate**

## 2. Remplacer le code généré

1. Supprimer les fichiers générés par Xcode dans le groupe `TideItWidget`
2. Faire un clic droit sur le groupe `TideItWidget` → **Add Files to "Tide It"...**
3. Sélectionner le dossier `TideItWidget` à la racine du projet
4. Cocher **TideItWidget** comme target
5. Décocher "Copy items if needed"

## 3. Fichiers communs au widget

1. Sélectionner `Tide It/Shared/WidgetSharedData.swift`
2. Dans l’inspecteur (panneau de droite) : **Target Membership**
3. Cocher **TideItWidget** en plus de **Tide It**

## 4. App Groups

1. **App principale** : `Tide It.entitlements` contient déjà `group.seb.Tide-It`
2. **Widget** : 
   - Sélectionner le projet → target **TideItWidget** → **Signing & Capabilities**
   - Cliquer **+ Capability**
   - Ajouter **App Groups**
   - Cocher `group.seb.Tide-It`  
   - Ou utiliser le fichier `TideItWidget/TideItWidget.entitlements` déjà fourni

## 5. Schémas Xcode (Run)

**Important** : Un widget ne se lance jamais seul. Les schémas « Tide It » et « TideItWidgetExtension » exécutent l'app principale au Run (Cmd+R). Pour tester le widget : lance l'app, puis ajoute le widget à l'écran d'accueil (appui long → + → Marées).

## 6. Vérifications

- Le bundle ID du widget doit être `seb.Tide-It.TideItWidget` (ou `seb.Tide-It` + `.TideItWidget`)
- Les App Groups doivent être identiques entre l’app et le widget
- Lancer l’app une fois avec un port sélectionné pour que le widget reçoive des données

## Contenu du widget

- **Petit (small)** : port, prochaine marée (PM/BM), heure, hauteur, coefficient
- **Moyen (medium)** : tendance actuelle, hauteur courante, prochaine marée détaillée
- **Clic** : ouverture de l’app via le schéma `tideit://open`

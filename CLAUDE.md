# Tide It — guide de maintenance

App iOS 26 SwiftUI (+ widgets, + Apple Watch) : marées + vent réel + surf pour riders.
Marque : **précision, honnêteté, faible batterie**. 12 langues (fr source). Mode : **maintenance**
(plus de grosses features — correctifs et mises à jour uniquement).

## Compiler (sans booter de simulateur)
```bash
xcodebuild build-for-testing -scheme "Tide It" -project "Tide It.xcodeproj" -configuration Debug \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```
Vérifier `** TEST BUILD SUCCEEDED **` + zéro `error:`. Si `database is locked` (Xcode ouvert) :
ajouter `-derivedDataPath /tmp/dd_iso`. **Compiler après chaque lot d'édits Swift, committer
seulement vert.**

⚠️ **`build-for-testing` et NON `build`** — un seul mot, et c'est la différence entre un filet de
sécurité vivant et un filet pourri. `build` ne construit que les cibles marquées « build for
running » : les 55 tests unitaires en sont EXCLUS. Constaté le 13 août 2026 — la suite ne
compilait plus depuis `2ef59ff` (5 jours, le commit qui a retiré `WindModelReading.weight`), et
chaque build annonçait « SUCCEEDED » en toute bonne foi. `build-for-testing` couvre les deux,
pour la même durée. Ne pas revenir à `build`.
Aucun simulateur n'est booté : `generic/platform=iOS Simulator` compile seulement.

⚠️ **Mais `build-for-testing` vaut pour DEBUG SEULEMENT.** En `-configuration Release` il échoue
sur `Unable to find module dependency: 'Tide_It'` — et c'est NORMAL : la suite fait
`@testable import Tide_It`, or `ENABLE_TESTABILITY` n'est à YES qu'en Debug. Ce n'est pas un
défaut de l'app, les tests n'ont pas à exister en Release. Pour la vérification Release
d'avant-archive, utiliser `build` tout court (app + widgets + Watch, sans les tests).

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

- **Échantillonnage par VOISINAGE (`MarineWeatherService.neighbourhood`, rayon 2 km, MÉDIANE).**
  Un modèle classe chaque maille TERRE ou MER : la rugosité change le vent d'un facteur deux
  d'une maille à l'autre, et un spot dont la coordonnée tombe du mauvais côté lit le vent de la
  forêt. Mesuré à Lacanau : 9,3 nds au point du spot contre 18,1 à 1,1 km — la bascule tient à
  800 m de pointage. Ampleur mesurée sur 1 624 heures et 10 stations : étendue de **3,15 km/h en
  médiane, 8,0 au p90, 24,7 au maximum**. Déplacer une épingle de 2 km changeait la prévision de
  13 nœuds.
  **Coût en justesse : NUL** — backtest contre le vent mesuré : point 3,46 / moyenne 3,49 /
  MÉDIANE **3,45**. La médiane prend le régime MAJORITAIRE du secteur ; une moyenne se laisse
  tirer par la maille aberrante. Direction prise au CENTRE (une médiane de caps n'a pas de sens
  sur un cercle : 350° et 10° donneraient 180°). UNE seule requête réseau (Open-Meteo accepte
  plusieurs coordonnées) — la batterie ne paie pas la robustesse. Script : `audit/audit_robustesse.py`.
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
- **Filtrer le voisinage par un masque TERRE/MER (`elevation`).** L'audit le plus complet du
  dépôt — 93 stations dans 14 pays (France 6 % de l'échantillon), 26 spots sur tous les
  continents, 8 paires front-de-mer / plan-d'eau, été ET hiver, 17 août 2026. Six méthodes de
  réduction comparées : centre seul, médiane des 5 (ACTUELLE), médiane des mailles eau, moyenne
  des mailles eau, maximum, médiane pondérée par l'élévation.
  - **Le choix de la méthode est du BRUIT devant l'erreur du modèle.** Les six tiennent dans
    **0,13 km/h de RMSE** les unes des autres, quand le modèle se trompe de 2,0 à 4,3. La
    médiane des mailles eau contre l'actuelle : **+0,032 RMSE, non significatif**
    (IC95 [−0,004 ; +0,078], P(meilleure) = 4,3 %). Hors de France : identique.
  - **⚠️ LE CLASSEMENT S'INVERSE AVEC LA RÉFÉRENCE, et c'est la leçon méthodologique.** Le
    maximum des 5 finit DERNIER contre les stations METAR (capteur à terre) et PREMIER contre
    les bouées (capteur en mer). Une référence ne juge pas la justesse : elle juge **la
    ressemblance au sol sur lequel on l'a posée**. Tout classement d'échantillonnage validé sur
    une seule famille de capteurs est donc à jeter.
  - **Le « maximum du voisinage » EST le décalage de 2 km vers le large, par un autre chemin.**
    Il gagne le test de stabilité (3,3× meilleur) mais achète cette stabilité en lisant toujours
    la maille la plus ventée : +0,97 km/h en moyenne, +2,49 sur les spots discriminants, et à
    Lacanau en hiver **9,37 → 15,04 nds (+61 %)**. La maille responsable a été nommée : le point
    Ouest de la croix, 2 km au large. Même geste, même chiffre, même refus.
  - **La médiane des mailles eau AGGRAVE le cas qui l'avait motivée.** Sur Lacanau/Andernos, le
    taux d'inversion passe de **1,9 % à 32,7 %** (hiver, > 15 nds). Parce que les deux mailles
    « eau » d'Andernos sont l'eau LIBRE du Bassin, donc ses mailles les plus ventées : le filtre
    gonfle l'abrité de +36 % contre +9 % le front de mer. L'anomalie n'est pas atténuée, elle est
    **fabriquée**. Le leave-one-pair-out le confirme : toute la pénalité vient de cette seule
    paire — celle que le correctif devait réparer.
  - **RAISON CONCEPTUELLE, définitive : l'élévation décrit le POINT échantillonné, pas le FETCH.**
    L'abri est une propriété AMONT et DIRECTIONNELLE. Or un plan d'eau abrité EST de l'eau : un
    filtre d'élévation y sélectionne son eau libre. Le filtre ne peut pas encoder l'abri, il ne
    peut que l'effacer. **Aucun réglage de seuil ne changera ça — le défaut est dans la grandeur
    choisie.** Ne pas retenter avec un autre seuil, une autre pondération, un autre rayon.
  - **Le problème n'existe pas pour la plupart des spots** : sur 26, **16 ont σ = 0,000 pour les
    six méthodes** — la croix entière tombe dans UNE maille de modèle. Et le modèle de terrain
    résout à 90 m ce que le modèle météo résout à 1,3 km (AROME) ou 25 km (ARPEGE monde) : une
    maille « eau » et une maille « terre » lisent donc très souvent la MÊME série.
  - **ET LA RÉPONSE POSITIVE : l'ordre se rétablit tout seul avec la méthode actuelle.** Taux
    d'inversion abrité > front de mer : 44,7 % toutes heures → **23,9 % au-delà de 15 nds →
    7,4 % au-delà de 20** (hiver) ; 43,3 % → 8,3 % → **0,0 %** (été). Sur Lacanau/Andernos :
    1,9 % à > 15 nds, **0 % à > 20 et > 25 nds**. La thermique inverse l'ordre quand il n'y a
    pas de vent, le synoptique le rétablit dès qu'il s'établit. **En vent navigable, l'app a
    raison** — il n'y avait pas d'artefact d'échantillonnage à réparer.
  - **LA RAISON MÉCANIQUE, à citer avant tout intervalle de confiance : Open-Meteo applique DÉJÀ
    ce critère, en amont et mieux.** Son `cell_selection` par défaut vaut `land` — il choisit la
    maille dont l'altitude ressemble à celle du point demandé, à l'aide d'un MNT 90 m. Filtrer
    nous-mêmes sur `elevation` REAPPLIQUE en aval le travail du fournisseur. D'où le +0,05 km/h :
    il n'y a rien à gagner parce que c'est déjà fait. Vérifiable en une requête, en toute saison.
  - **⚠️ `elevation` n'est PAS un classifieur de maille, et le « 99,8 % de fiabilité » ne répond
    pas à la bonne question.** Ce taux dit « le POINT est-il de l'eau dans un MNT 90 m ». La
    question opérante est « la MAILLE servie par le modèle est-elle de la mer ». Mesuré sur les
    épingles RÉELLES du catalogue surf, contre `cell_selection=sea` : parmi les épingles à
    `elevation == 0` que la règle GARDE, **15 % ne reçoivent pas la maille mer** (Nazaré +4,92 km/h) ;
    parmi celles à `elevation > 0` qu'elle JETTE, **90 % lisent déjà la maille mer**. 15 % de faux
    positifs, 90 % de faux négatifs.
  - **`elevation` décrit le point DEMANDÉ ; la vitesse décrit une maille dont le centre est
    ailleurs.** Distance point demandé → centre de maille servi : 0,48 km en médiane en France
    (AROME 1,3 km) mais **8,44 km hors de France, jusqu'à 18,58 km** (ARPEGE 0,25°). Preuve
    directe : Playa Guiones, MÊME maille pour les 5 points, élévations [0, 0, 0, 14, 0], séries
    identiques à la décimale. Le filtre est donc **structurellement inapplicable hors du domaine
    AROME** — soit l'essentiel de la planète.
  - **Le filtre DÉTRUIT la robustesse au pointage qu'il prétend servir.** Dans **60 % des croix**
    (12,2 % des entrées de catalogue, 18,6 % des spots surf), les points « eau » ne recouvrent
    qu'UNE maille distincte : « médiane des mailles eau » dégénère alors en lecture d'un point
    unique — exactement l'état d'avant le voisinage, celui où « déplacer une épingle de 2 km
    changeait la prévision de 13 nœuds ». Ce n'est pas un cas de repli, c'est son fonctionnement
    normal.
  - **LA BORNE QUI TRANCHE TOUT RETOUR DU SUJET.** La maille « eau » à 2 km capte **73 % du
    gradient côte → pleine mer** (Lacanau 16,41 → 24,28 → 27,12 km/h à 0 / 2 / 40 km ;
    Wijk aan Zee 73 % ; Westkapelle 63 %). Or le déficit RÉELLEMENT mesuré au bord de l'eau, sur
    24 capteurs posés à la laisse de mer, n'est que de **0,46 à 1,53 km/h**. Surcorrection d'un
    facteur 2 à 17. Et le surplus est POSITIF DANS TOUS LES SECTEURS de vent (Lacanau : onshore
    +7,17, side +8,77, offshore +5,96) : c'est un décalage à signe unique, incapable d'encoder un
    abri qui change de signe avec la direction.
  - **Là où navigue le rider, la maille est DÉJÀ la bonne.** À Lacanau, le point à 0,3 km au large
    lit EXACTEMENT la même série que le centre (16,41 km/h en heures ventées). La maille côtière du
    modèle EST celle du rider. L'app n'a pas 8 nœuds de retard au bord de l'eau, elle a 0,5 à 1,5.
  - **`cell_selection=sea` : REFUSÉ, pas « prometteur ».** Le ×8,4 initialement relevé à Tarifa
    était UNE heure. Sur un mois complet (janvier 2026) : 6,77 → 17,48 km/h, soit **+10,71 km/h
    soutenus**, ×2,58 — plus gros que les 8-9 nœuds qui ont fait retirer le décalage vers le large.
    Troisième déguisement du même geste, troisième refus.
  - **NE PAS décoder `elevation` dans `WindEnsembleResponse`.** Tant qu'aucune décision de code
    n'en dépend, une révision de MNT chez Open-Meteo est sans effet. Dès qu'elle pilote un filtre,
    elle devient une entrée **non versionnée et non surveillée** du vent affiché : `check_sources.py`
    ne la regarde pas, et un changement silencieux déplacerait le vent de milliers de spots sans
    mise à jour de l'app. Si ce champ doit servir un jour, qu'il serve HORS LIGNE — verdict calculé
    à l'audit et ÉCRIT dans le catalogue livré, jamais lu en direct.
  - Si le masque est malgré tout utilisé hors ligne : **`elevation == 0` EXACTEMENT**, jamais
    `<= 0` ni `< 0.5`. Les valeurs sont toujours entières et la terre littorale basse lit un petit
    entier NÉGATIF (polders −5, Camargue −1, Pô −2, Fens −1) : `< 0.5` transforme tout polder en
    eau (transect néerlandais : 21 erreurs contre 8). Angle mort assumé : l'eau d'ALTITUDE
    (Léman 368 m, Michigan 174, Garde 65) est classée terre — faux négatif, donc sans danger.
    Piège corrigé dans `audit/audit_rugosite_maille.py`.
  - ⚠️ **Réserve d'honnêteté sur le chiffre le plus spectaculaire** : le « C fait passer
    l'inversion de 1,9 % à 32,7 % » porte sur UNE paire, celle de la découverte. Il illustre le
    mécanisme, il ne doit pas servir de motif principal — les motifs solides sont les quatre points
    ci-dessus, indépendants de tout échantillon.
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
- **Membre isolé lu depuis un contexte qui ne l'est pas → `nonisolated`.** Avertissement
  aujourd'hui, ERREUR en Swift 6. Rencontré QUATRE fois, sous DEUX formes :
  1. *Constante servant de valeur par défaut à un argument* — un argument par défaut est évalué
     HORS de l'acteur : `WindStationAggregator.defaultSearchRadius`,
     `WebcamCatalog.maxDistanceMeters`/`maxSuggestions`, `MarineWeatherService.neighbourhoodKm`.
  2. *`init` d'un `actor` appelant une méthode isolée* — un `init` d'acteur est nonisolated :
     `WatchSourceBlocklist.applyCached()`. Correctif : une fonction `nonisolated static` SANS
     effet de bord qui RENVOIE la valeur, que l'`init` affecte lui-même.

  Réflexe : tout membre lu depuis une fonction `nonisolated` (ou un `init` d'acteur) doit l'être
  aussi — et s'il mute l'état, le transformer en fonction pure qui rend la valeur.
- **Jour = fuseau du PORT** partout, jamais `Calendar.current` (cf. `Calendar.inTimeZone`). Vaut
  aussi pour le `DateFormatter` des libellés : sinon un minuit « port » se formate à la veille.

## Risques connus (surveiller, pas de fix code possible)
- **Licence Open-Meteo — LE point juridique ouvert, et il n'est PAS gris.** Termes relevés le
  13 août 2026, mot pour mot : « You may only use the free API services for **non-commercial**
  purposes », et la liste des usages COMMERCIAUX cite explicitement « Operating websites or
  **apps that have subscriptions** or display advertisements ». Tide It a un abonnement premium :
  l'app est donc en usage commercial sur un palier réservé au non-commercial. Le palier gratuit
  n'offre par ailleurs « no uptime guarantee » — ce qui contredit la promesse de fiabilité.
  Trois issues, une seule décision à prendre :
  1. **Palier payant** (API Standard, 1 M appels/mois ; tarif non publié, passer par le
     checkout ou `info@open-meteo.com`). Conforme immédiatement, apporte une clé, un point
     d'entrée dédié et 99,9 % d'uptime. **C'est l'option cohérente avec le mode maintenance.**
  2. **Self-host** : serveur open source en **AGPLv3**, données en **CC BY 4.0**. Lève la
     restriction commerciale, mais demande d'ingérer AROME + ICON + GFS — du disque, du cron
     et de l'exploitation permanente, soit l'inverse du mode maintenance. L'AGPL n'est PAS un
     obstacle tant que le serveur reste non modifié (il suffit de pointer le dépôt amont).
  3. Changer de fournisseur — mais l'audit a mesuré qu'aucun autre modèle ne vaut celui-là.
- **Aucune clé API n'est embarquée** (vérifié le 13 août 2026) : `APIKeys.resolve` renvoie `""`
  sauf clé fournie par l'utilisateur via UserDefaults/Info.plist, donc `isConfigured` est false
  et WorldTides/TideCheck ne sont JAMAIS appelés dans l'app livrée. Les vieilles clés 4.x ont
  été révoquées côté fournisseurs (13 août 2026) : sans effet sur l'app, comme prévu. Chaque
  chemin de marée retombe sur le moteur harmonique embarqué — les ports français ne touchent
  même pas le réseau.
- **Balises tierces** (Pioupiou, winds.mobi, Weameter slugs `andernos/pauillac/lachanau/
  kiteschool-leucate`, METAR, NDBC) : mort silencieuse acceptée — l'app dégrade sans balise.
  Surveillées par `tools/check_sources.py` (voir ci-dessous) : c'est ce qui évite de l'apprendre
  par un utilisateur.
- Premium debug : `debugForcePremium` est `#if DEBUG` uniquement (jamais en App Store).

## Surveiller les sources (`tools/`)
```bash
python3 tools/check_sources.py          # tableau des 11 sources
```
Contrôle de CONTENU, pas seulement le code HTTP : une page d'erreur ou une station retirée
répondent 200 tout en étant inexploitables. Sortie 0 = tout va bien, 1 = une source secondaire
est morte, 2 = une source CRITIQUE est morte (l'app perd une fonction entière).
Planification hebdomadaire : `tools/com.tideit.sources.plist` (mode d'emploi dans l'en-tête).
Relevé de référence du 13 août 2026 : **11/11 vivantes**.

## Contact / comptes
Support : tideitapp@icloud.com · App Store id 6743555259 (`seb.Tide-It`) ·
clé API ASC : `~/.appstoreconnect/key.json` (JAMAIS committer, ni les `.p8`).

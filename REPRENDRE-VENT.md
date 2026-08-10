# REPRENDRE ICI — chaîne de prévision de vent

État figé le **9 août 2026 à 23 h 10**, avant coupure pour limite d'utilisation.
Reprise programmée le **10 août à 04 h 11**.

---

## La règle, posée par le propriétaire — ne pas la rouvrir

> « Les mesures de l'anémomètre ne doivent pas intervenir dans les prévisions.
> Le réel est pour confirmer. »

| | Source | Rôle |
|---|---|---|
| **Prévision** | UN modèle, le mieux résolu qui réponde (`meteofrance_seamless` → `icon_seamless` → `gfs_seamless`) | ce qu'il VA faire |
| **Réel** | balise ≤ 15 km, âge affiché | ce qu'il FAIT |
| **Confiance** | écart entre les 3 modèles | l'accord des modèles |

Détail complet dans `CLAUDE.md`, § « Le vent : qui dit quoi ».

## Ce qui est FAIT (compilé vert, poussé)

- Correction de prévision par la balise : **supprimée** (`debiased`, `debiasedSeries`, le réglage
  premium, sa clé iCloud). Une balise abritée déformait les spots océan ; une balise en panne
  déformait 7 jours avec ses derniers échantillons.
- Moyenne pondérée des 3 modèles : **supprimée**. Elle importait l'incapacité d'ICON (11 km) et
  GFS (27 km) à résoudre le trait de côte. Mesuré : elle faisait 3,44 de RMSE contre 3,29 pour
  Météo-France seul.
- Rayon de la balise affichée : **60 km → 15 km**. Au Cap Ferret, « réel 9 nds » venait d'une
  station à l'intérieur des terres.
- Rafale impossible (< moyenne) : **écartée** au lieu de produire le verdict « laminaire ».
- Confiance **plafonnée à 0,5** au-delà de J+5 (le modèle fin s'arrête, ICON et GFS s'accordent
  sur leur angle mort commun) et **saturée à 0,75** dans le classement du repérage anticipé.
- **« Go X% » retiré.** Il affichait 88 % sur 9 nds de vent réel. Conservés à la demande :
  la notification « le vent s'établit » et les ÉTOILES des fenêtres (`sessionStars`).
- Décalage 2 km au large : **essayé, mesuré, RETIRÉ** (surestimait de 8-9 nds vs les autres
  sites kite). Ne pas réessayer.

## Ce qui RESTE à faire

1. **Dépouiller l'audit profond.** Lancé le 9 août à 23 h sur 8 axes : skill par échéance,
   par façade maritime, par régime de vent, rafales, direction, brise thermique, recalage de
   biais, modèles non testés. Résultats dans le journal du workflow ; si la session est morte,
   RELANCER le script :
   `~/.claude/projects/-Users-maublanc-Desktop-Tide-It-18/e977adf5-.../workflows/scripts/audit-vent-profond-wf_684975c9-13b.js`
2. **Appliquer les conclusions** de l'audit, en ne retenant qu'un changement dont le gain
   mesuré hors échantillon dépasse **0,3 km/h**. En dessous, c'est du bruit : ne rien changer.
3. **Un point de vérité terrain manque encore** : le propriétaire a confirmé que 17 nds au Cap
   Ferret le 9 août à 19 h 58 était FAUX (réel ~9). Vérifié : ce n'est ni la coordonnée (tout le
   secteur est dans la même maille) ni un décalage horaire (parseur correct). Reste à
   déterminer pourquoi la pastille affichait 17 alors que la valeur de 20 h est 12 — passe de
   modèle en cache, ou lecture de la mauvaise heure. **Une capture avec l'heure trancherait.**

## État de la build

**5.3.0 / build 17.** Debug vert. Métadonnées 12 langues déjà sur App Store Connect.
Non archivée — les notes datent d'avant ces correctifs de prévision.

## Audits déjà faits (versionnés dans `audit/`)

17 stations côtières, 2 800 heures de vent horaire mesuré (réseau METAR public) :

| modèle | biais | RMSE |
|---|---|---|
| meteofrance_seamless | −0,65 | **3,29** |
| arome_france_hd | −0,65 | 4,02 |
| best_match | −1,65 | 4,08 |
| icon_seamless | −3,09 | 5,04 |
| gfs_seamless | −0,73 | 5,23 |
| ecmwf_ifs025 | −3,10 | 5,79 |

Validation croisée : une pondération optimale ne gagne que **+0,07 km/h** hors échantillon
(σ 0,04) — un tiers du gain apparent était du surajustement. Le modèle seul est retenu.

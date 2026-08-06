# REPRENDRE ICI — balises FR, webcams, campagne d'autorisation

État figé au **6 août 2026**. Ce fichier existe parce que la session a été coupée par la limite
d'utilisation. Il contient tout ce qu'il faut pour repartir sans rien redemander au proprio.

---

## 1. Les décisions déjà prises (ne pas les rouvrir)

| Sujet | Décision |
|---|---|
| Politique | **Opt-out.** On affiche, on crédite, on retire immédiatement sur demande. |
| Balises vent | Affichées par défaut. Une mesure est un fait, pas une œuvre. |
| Webcams | L'icône **OUVRE la page de l'exploitant** (un lien n'est pas une contrefaçon). Le flux rejoué *dans* l'app est réservé à ceux qui ont donné un **accord écrit** — guideline App Store 5.2 : la sanction n'est pas le retrait de la fonction mais celui de l'application. |
| Expéditeur | **tideitapp@icloud.com** (pas le Gmail perso : une demande de droits doit venir de l'adresse de l'app). |
| Portée | **Tout le monde**, particuliers compris — mais un particulier ne reçoit un courrier que s'il a **publié lui-même** une adresse de contact sur son site. Sinon c'est du démarchage. |
| Envoi | **L'assistant ne peut PAS envoyer** : le connecteur mail ne sait que créer des brouillons Gmail, et il n'a aucun accès à iCloud. Il livre des `.eml` prêts, le proprio clique. |

---

## 2. Ce qui est FAIT et poussé

- **Liste de retrait distante** — `docs/blocklist.json` en ligne, `SourceBlocklistService.swift`
  branché dans `WindStationAggregator.rebuildDedup()` (point de passage unique → couvre carte,
  widget, alertes, Live Activity, Watch). Amorçage synchrone depuis le cache ; réseau muet =
  la dernière liste connue tient. Commit `e22256d`.
- **Modèles de courrier** — `outreach/demandes-autorisation.md` (5 variantes texte) et les
  versions HTML à deux boutons : `modele-webcam-fr.html`, `modele-balise-fr.html`.
  Encodage des `mailto:` vérifié par décodage. Commit `29b1d8a`.
- **Résultat partiel de recherche** — `outreach/recherche-brute.json` (1 agent sur 13 rendu :
  angle institutionnel, 3 sources vérifiées dont Ogimet et l'archive ouverte Météo-France).

## 3. Ce qui RESTE

1. **Relancer la recherche** (elle est morte avec la session, cf. §4).
2. **Seconde passe : les adresses de contact.** La recherche identifie les *sources*, pas les
   *destinataires*. Manque volontairement demandé nulle part dans le script initial — c'est le
   trou à combler.
3. **Générer `outreach/envois/*.eml`** — un par destinataire, personnalisé (lieu, nom, `[ID]`),
   **trié par valeur** : sociétés et réseaux d'abord, clubs et collectivités ensuite,
   particuliers en dernier. Par vagues : iCloud plafonne les envois quotidiens et repère les
   séries identiques.
4. **Versions anglaises** des HTML (une fois qu'on sait quels destinataires sont étrangers).
5. **Intégrer les nouvelles sources vent** retenues (une classe par source, cf. §5).
6. **Catalogue webcams + icône caméra** dans `ObservedWindCard` : icône si une webcam est
   proche, appui = les 3 plus proches, second appui = ouvre la page (ou le flux si `embed:true`).
   Volontairement PAS commencé : le format du catalogue doit être modelé sur ce que les
   fournisseurs exposent réellement.

---

## 4. Relancer la recherche

Le script est sur le disque et survit à la session :

```
/Users/maublanc/.claude/projects/-Users-maublanc-Desktop-Tide-It-18/e977adf5-a243-499a-a1cc-841078031121/workflows/scripts/balises-fr-et-webcams-wf_3e88fc78-efc.js
```

`resumeFromRunId` ne marche QUE dans la session d'origine → dans une nouvelle session, relancer
avec `{scriptPath: "<ci-dessus>"}`, ce qui repart de zéro. Deux corrections à apporter AVANT :

- **Demander les adresses de contact** dans les schémas (`contactEmail`, `contactPage`) — sinon
  il faudra une seconde passe complète, ce qui est exactement l'erreur commise ici.
- **Élaguer les angles déjà rendus** si `outreach/recherche-brute.json` les couvre
  (l'institutionnel est fait), pour ne pas repayer le même travail.

## 5. Ajouter une source vent (recette)

Une classe `@MainActor ObservableObject` singleton avec `@Published stations: [WindStation]`,
un `refreshIfNeeded(force:)` gardé par un TTL, et le parsing en `nonisolated static`. Puis :
un `case` dans `WindStation.Source` (+ `displayName` + `attributionLabel`), une ligne dans le
`MergeMany` (avec `.eraseToAnyPublisher()`), une dans `refresh()`, une dans `rebuildDedup()`.

Piste la plus prometteuse, à ne pas perdre : **Weameter n'est pas un site, c'est une
convention.** C'est du WeeWX avec le skin Belchertown, qui publie toujours à
`.../json/weewx_data.json`. Les autres logiciels de stations amateur ont les leurs —
CumulusMX `/realtime.txt`, Weather-Display `/clientraw.txt`. Des centaines de stations
françaises tournent là-dessus, souvent posées par des clubs de voile ou des campings, donc
**pile sur les spots** — contrairement aux aéroports METAR.

---

## 6. État de la build (indépendant de tout ça)

- **5.3.0 / build 16**, Debug + Release verts. `goAheadShipped = true` → le repérage anticipé
  est ALLUMÉ pour test sur iPhone (boutons dans Réglages ▸ Débogage).
- **5.2.9 attend sur App Store Connect** avec ses 12 notes déjà téléversées, sans build attaché.
  Quand on publiera la 5.3.0, `deliver --app_version 5.3.0` renommera cette version éditable —
  pas de conflit, mais les notes devront alors mentionner les nouveautés.
- Reste pour la 5.3 : l'état « repérée / confirmée » dans le calendrier, filet indispensable
  quand iOS ne réveille pas l'app la veille.

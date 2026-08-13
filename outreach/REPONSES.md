# Réponses des exploitants — registre

Une réponse reçue ne vaut que si elle est **appliquée** et **retrouvable**. Ce fichier est le
registre ; l'application effective vit dans `Tide It/webcams.json` (champs `embed`,
`embedRefusedByOperator`, `authorizationNote`) et dans `docs/blocklist.json` pour les retraits.

> ⚠️ **Une autorisation n'est pas binaire.** Le courrier envoyé contenait une phrase pré-remplie
> (« j'autorise Tide It à afficher le flux … dans l'application »). Plusieurs exploitants la
> laissent telle quelle **puis la restreignent** dans les conditions particulières. C'est la
> condition MANUSCRITE qui fait foi, jamais la phrase pré-remplie. En cas de contradiction, la
> lecture la plus restrictive s'applique.

## Barème d'application

| Réponse | `embed` | Figure au catalogue | Action |
|---|---|---|---|
| Accord SANS restriction | `true` possible | oui | flux rejouable dans l'app |
| Accord AVEC refus de rediffusion | **`false`** | oui | nom + lien seulement |
| Refus | — | **non** | id dans `docs/blocklist.json` |
| Sans réponse | `false` | oui | lien seulement (modèle opt-out) |

---

## Winds-Up — 13 août 2026 — ACCORD PARTIEL

**Jean-Louis RIBOT**, Director · contact@winds-up.com · www.winds-up.com

> « J'autorise Tide It à afficher le flux de vos 2 webcams de Hyères dans l'application, avec
> mention de notre nom et lien vers notre site. Cette autorisation est révocable à tout moment. »
>
> Conditions particulières : « **Je refuse que la webcam soit rediffusée** directement sur votre
> site mais la mention est OK »

**Lecture retenue** — la condition manuscrite prime sur la phrase pré-remplie : **nom et lien
autorisés, rediffusion du flux refusée**.

**Appliqué** : `embed: false` + `embedRefusedByOperator: true` + `authorizationNote` sur les
**deux** entrées Winds-Up du catalogue (`cam_winds-up-almanarre-salin-des-pesquiers` et
`cam_la-franqui-webcam-le-bleu-winds-up-id-64`). Le second n'est pas couvert par ce courrier
(La Franqui, pas Hyères) mais un refus de rediffusion se respecte pour toutes les caméras d'un
même exploitant — être plus strict que demandé ne coûte rien.

**Vérifié dans l'app** : le menu webcam affiche `Winds-Up — Almanarre / Salin des Pesquiers` et
le lien ouvre `winds-up.com`. Aucun flux n'est rejoué. Les deux conditions étaient donc **déjà**
satisfaites avant leur réponse — celle-ci ne change aucun comportement, elle le sécurise.

**⚠️ Ne jamais passer `embed` à `true`** sur ces entrées sans un nouvel accord écrit explicite.
Guideline App Store 5.2 : rediffuser le flux d'un tiers sans accord fait retirer l'APPLICATION,
pas la fonctionnalité.

### Reste à faire
- **Identifier la 2e webcam de Hyères.** Le courrier en mentionne deux ; le catalogue n'en a
  qu'une à leur nom (Almanarre / Salin des Pesquiers). La liste publique de leurs caméras est
  rendue en JavaScript et n'a pas pu être énumérée. **Demander la seconde URL à Jean-Louis** —
  une ligne de réponse suffit, plutôt que de deviner.
- **Logo proposé** : non intégré. Le nom en toutes lettres satisfait déjà « mention de notre
  nom », et un logo tiers ajoute une contrainte de marque sans rien apporter au rider.
  À reconsidérer seulement s'ils y tiennent.

### Si Winds-Up révoque
Ajouter les deux identifiants ci-dessus au tableau `webcams` de `docs/blocklist.json`. Ils
disparaissent de tous les téléphones au prochain lancement, sans mise à jour App Store — c'est
ce qui rend tenable le « révocable à tout moment » qu'on leur a promis.

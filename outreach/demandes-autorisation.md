# Information et demandes — webcams et balises

Politique retenue : **on affiche, on crédite, on retire immédiatement sur demande.**

Ces courriers ne demandent donc pas une permission qu'on aurait déjà prise — ce serait
malhonnête. Ils informent, ils offrent le retrait en un mot, et ils proposent une contrepartie.

Deux régimes différents, à ne pas confondre :

| | Par défaut | Avec accord écrit |
|---|---|---|
| **Balise vent** | mesure affichée, nom + lien vers le site | rien de plus à obtenir |
| **Webcam** | icône qui **ouvre la page de l'exploitant** (un lien n'est pas une contrefaçon) | flux affiché **dans** l'app |

Le flux vidéo d'un tiers rejoué dans une app commerciale sans accord relève de la guideline
App Store 5.2 : la sanction n'est pas le retrait de la fonctionnalité, c'est le retrait de
l'application. D'où le lien par défaut, et l'intégration réservée à ceux qui ont dit oui.

**Retrait immédiat** : identifiant ajouté à la liste de blocage distante, la source disparaît
au prochain lancement de l'app. Aucune mise à jour App Store, aucune attente.

Remplacer les `[CROCHETS]`. Un destinataire par mail, jamais de copie carbone visible.
Envoi depuis **tideitapp@icloud.com**.

## Versions à boutons (à privilégier)

- [`modele-webcam-fr.html`](modele-webcam-fr.html)
- [`modele-balise-fr.html`](modele-balise-fr.html)

Ouvrir dans Safari → `Cmd+A` `Cmd+C` → coller dans Mail. Les boutons suivent.

**Comment ça marche.** Le site est statique : aucun serveur pour enregistrer un clic. Les
boutons sont donc des `mailto:` qui ouvrent la messagerie du destinataire avec l'objet ET le
corps déjà écrits — il n'a plus qu'à envoyer. Universel, sans infrastructure, et sans traceur
(aucun pixel de suivi dans ces courriers, volontairement).

**La réponse EST l'accord.** Le bouton vert pré-remplit une phrase d'autorisation explicite,
avec la mention « révocable à tout moment » et un champ pour les conditions particulières. Ce
qui revient n'est donc pas un « ok » ambigu mais un accord écrit, daté et utilisable — c'est
exactement ce qu'il faut pour passer une webcam en flux intégré.

**Trier les réponses.** Objets normalisés :

```
ACCORD Tide It — <identifiant>
REFUS  Tide It — <identifiant>
```

Deux règles dans Mail suffisent. L'identifiant est celui de la source dans l'app
(`weameter_andernos`, `webcam_skaping_leucate`…) : il dit exactement quelle ligne basculer.

- **ACCORD** sur une webcam → `embed: true` dans le catalogue.
- **REFUS** → identifiant dans `docs/blocklist.json`. Disparaît au lancement suivant.
- **Silence** → statu quo (affichage crédité, lien sortant).

Le texte du bouton « refus » dit « retirez-moi » et non « je refuse » : on ne demande pas à
quelqu'un de se justifier pour exercer un droit.

## Suivi

| Destinataire | Type | Envoyé le | Réponse | Action |
|---|---|---|---|---|
| | | | | |

Réponse négative → ajouter l'identifiant à `docs/blocklist.json`. C'est tout.

---

## 1 — Webcam · français

**Objet :** Tide It envoie du monde sur votre webcam de [LIEU]

Bonjour,

Je développe Tide It, une application iOS indépendante de marées, de vent réel et de conditions
de surf, utilisée surtout par des kitesurfeurs et des surfeurs du littoral français.

Quand quelqu'un consulte le spot de [LIEU] dans l'application, une icône lui propose les
webcams les plus proches. La vôtre en fait partie : un appui **ouvre votre page**, avec votre
nom. Je ne rediffuse pas votre image, je vous envoie le visiteur.

Deux raisons à ce courrier.

La première : si vous préférez ne pas y figurer, répondez-moi et je vous retire. Le retrait est
immédiat, sans mise à jour de l'application ni délai.

La seconde : si au contraire l'idée vous convient, je peux faire mieux. Avec votre accord
écrit, j'afficherais l'image directement dans l'application, avec votre nom visible et le lien
vers votre site — sans publicité, sans superposition, sans enregistrement, et uniquement quand
l'utilisateur appuie dessus. Jamais de lecture automatique.

Pour être clair d'emblée : Tide It est une application commerciale, certaines fonctions étant
accessibles par abonnement. Je préfère vous le dire plutôt que vous le laisser découvrir.

Merci du temps que vous y consacrerez,

[PRÉNOM NOM]
Tide It — tideitapp@icloud.com
[LIEN APP STORE]

---

## 2 — Webcam · anglais

**Subject:** Tide It is sending visitors to your [LOCATION] webcam

Hello,

I develop Tide It, an independent iOS app for tides, live wind and surf conditions, used mainly
by kitesurfers and surfers along the French coast.

When someone checks the [LOCATION] spot in the app, an icon offers them the nearest webcams.
Yours is one of them: tapping it **opens your page**, under your name. I do not rebroadcast your
image — I send you the visitor.

Two reasons for writing.

First: if you would rather not be listed, just reply and I will remove you. Removal is immediate,
with no app update and no delay.

Second: if you like the idea, I can do better. With your written agreement I would show the
image directly inside the app, with your name visible and a link to your site — no advertising,
no overlay, no recording, and only when the user taps it. Never autoplay.

To be upfront: Tide It is a commercial app, with some features behind a subscription. I would
rather tell you than let you find out.

Thank you for your time,

[FIRST LAST]
Tide It — tideitapp@icloud.com
[APP STORE LINK]

---

## 3 — Balise vent · français (exploitant, club, société)

**Objet :** Votre station de [LIEU] dans Tide It — et comment l'en retirer

Bonjour,

Je développe Tide It, une application iOS indépendante de marées et de vent réel, utilisée
surtout par des kitesurfeurs, windsurfeurs et surfeurs du littoral français.

Votre station de [LIEU] est l'une des rares à mesurer le vent au plus près d'un spot de glisse —
bien plus près que les stations d'aéroport sur lesquelles la plupart des applications se
rabattent. Sa mesure est affichée aux utilisateurs qui consultent ce spot, **avec votre nom et
un lien vers votre site**.

Ce que ça représente concrètement pour vous :

- une requête toutes les trois minutes au maximum, et seulement quand quelqu'un regarde ce
  spot — aucune collecte massive, aucun archivage de votre historique ;
- l'âge de la mesure toujours indiqué, et rien d'affiché si la donnée manque : je ne présente
  jamais une valeur ancienne ou absente comme si elle était actuelle. Votre station ne dira
  jamais autre chose que ce qu'elle mesure ;
- si vous préférez ne pas y figurer, un mot suffit et je vous retire immédiatement, sans
  mise à jour de l'application ni délai.

Pour être clair d'emblée : Tide It est une application commerciale, certaines fonctions étant
accessibles par abonnement.

Si vous souhaitez poser des conditions, dites-les moi, je m'y tiendrai.

Merci,

[PRÉNOM NOM]
Tide It — tideitapp@icloud.com
[LIEN APP STORE]

---

## 4 — Balise vent · anglais

**Subject:** Your [LOCATION] station in Tide It — and how to remove it

Hello,

I develop Tide It, an independent iOS app for tides and live wind, used mainly by kitesurfers,
windsurfers and surfers along the French coast.

Your [LOCATION] station is one of the few measuring wind right at a riding spot — far closer
than the airport stations most apps fall back on. Its readings are shown to users viewing that
spot, **with your name and a link to your site**.

What this means in practice:

- one request every three minutes at most, and only while someone is actually looking at that
  spot — no bulk harvesting, no archiving of your history;
- the age of the reading always displayed, and nothing shown when data is missing: I never
  present a stale or absent value as if it were current. Your station will never be made to say
  anything other than what it measures;
- if you would rather not be listed, one word is enough and I remove you immediately, with no
  app update and no delay.

To be upfront: Tide It is a commercial app, with some features behind a subscription.

If you want to set conditions, tell me and I will honour them.

Thank you,

[FIRST LAST]
Tide It — tideitapp@icloud.com
[APP STORE LINK]

---

## 5 — Station personnelle · français (particulier)

Version courte. Un passionné n'est pas un service client : on ne lui envoie pas un contrat, on
lui parle. À n'envoyer QU'À une adresse qu'il a lui-même publiée sur son propre site.

**Objet :** Votre station météo de [LIEU] — un mot d'un développeur

Bonjour,

Je suis tombé sur votre station météo de [LIEU] en cherchant des mesures de vent fiables sur
[RÉGION]. Elle est nettement mieux placée que tout ce qui existe autour pour les spots de
glisse du coin.

Je développe Tide It, une petite application iOS de marées et de vent pour kitesurfeurs et
surfeurs. Votre mesure y est affichée avec votre nom et un lien vers votre site, pour les gens
qui consultent ce spot.

Une lecture toutes les trois minutes au maximum, uniquement quand quelqu'un regarde. Rien
d'archivé, rien de revendu. Et si ça ne vous va pas, dites-le moi : je vous retire le jour même,
sans attendre une mise à jour de l'application.

L'application est payante pour certaines fonctions, autant que vous le sachiez.

Merci, et bravo pour la station,

[PRÉNOM NOM]
Tide It — tideitapp@icloud.com

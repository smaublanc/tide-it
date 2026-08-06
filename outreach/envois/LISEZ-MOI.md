# Courriers prêts à envoyer

Un `.eml` par destinataire. **Double-clic → le message s'ouvre dans Mail, déjà rempli**
(destinataire, objet, corps HTML avec les deux boutons). Il ne reste qu'à relire et envoyer.

Vérifier que Mail envoie bien depuis **tideitapp@icloud.com** (le champ « De » est déjà
positionné, mais Mail peut le remplacer par le compte par défaut).

Pour tout ouvrir d'un coup :

```
open -a Mail outreach/envois/*.eml
```

L'ordre des fichiers est l'ordre d'envoi conseillé : sociétés, puis collectivités.

## Ce qui part

| # | Destinataire | Objet du courrier | Statut dans l'app |
|---|---|---|---|
| 01 | Kite Zone School — `contact@kitezone-school.com` | station du lac d'Hourtin-Carcans | **DÉJÀ affichée** (`weameter_lachanau`) — le plus urgent |
| 02 | La Chèvrerie du Cap — `chevrerie.du.cap@tiscali.fr` | station du Cap Fréhel | **DÉJÀ affichée** (`weewx_capfrehel`, ajoutée le 6 août 2026) |
| 03 | Ports de Cornouaille — `plaisance.concarneau@portsdecornouaille.fr` | borne du port de plaisance | **PAS intégrée** — aucune licence publiée, on demande AVANT |
| 04 | Château Brulesécaille — `contact@brulesecaille.com` | station de Tauriac | pas intégrée (hors spot de glisse) |

Les deux premiers sont des courriers d'INFORMATION (la mesure est déjà affichée, on offre le
retrait). Le troisième est une vraie DEMANDE : rien n'est affiché tant qu'ils n'ont pas répondu.
La différence est écrite dans le corps de chaque message — ne pas les intervertir.

## Traiter les réponses

Les boutons produisent des objets normalisés :

```
ACCORD Tide It — <identifiant>
REFUS  Tide It — <identifiant>
```

- **REFUS** → ajouter l'identifiant dans `docs/blocklist.json`, committer. La balise disparaît
  de tous les téléphones au lancement suivant.
- **ACCORD** → noter la date dans le tableau de `../demandes-autorisation.md`. Pour Concarneau,
  c'est le feu vert pour intégrer les bornes Diabox.
- **Silence** → statu quo.

## Regénérer

Modifier la liste `DESTINATAIRES` dans `../generer-envois.py`, puis :

```
python3 outreach/generer-envois.py
```

Le dossier est réécrit à chaque exécution (les `.eml` existants sont supprimés).

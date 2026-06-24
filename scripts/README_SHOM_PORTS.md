# Liste des ports SHOM (shom_ports.txt)

L'app utilise la liste `Tide It/shom_ports.txt` (format `ID:Nom:lat:lon`) et récupère les marées via l'API vignette SHOM :

`https://services.data.shom.fr/hdm/vignette/grande/{ID}?locale=fr`

Les **nom et coordonnées GPS** doivent être ceux affichés sur [maree.shom.fr](https://maree.shom.fr/harbor/XXX) (ex. Saint-Gilles-Croix-de-Vie, 046° 41' 48.0" N, 001° 56' 33.0" W).

## Liste officielle via WFS (recommandé)

Le SHOM expose la même liste que maree.shom.fr via un WFS. Pour régénérer la liste complète (439 ports, nom + coordonnées officielles) :

```bash
cd "/chemin/vers/Tide It 17"
python3 scripts/fetch_shom_ports_from_wfs.py
```

Écrit `Tide It/shom_ports.txt`. Option `--dry-run` pour afficher sans écrire.

## Découverte de ports supplémentaires (vignette + géocodage)

Si un port existe sur maree.shom.fr mais n'apparaît pas dans le WFS, on peut l'ajouter avec le script de découverte.

```bash
python3 scripts/discover_shom_ports.py --dry-run   # test
python3 scripts/discover_shom_ports.py             # ajoute au fichier
python3 scripts/discover_shom_ports.py --candidates scripts/shom_port_candidates.txt
```

- **IDs** : comme dans l'URL maree.shom.fr, ex. `https://maree.shom.fr/harbor/ST-GILLES-CROIX-DE-VIE` → ID = `ST-GILLES-CROIX-DE-VIE`.
- Fichiers : `fetch_shom_ports_from_wfs.py` (liste officielle), `discover_shom_ports.py` (candidats), `shom_port_candidates.txt`.

#!/usr/bin/env python3
"""
Récupère la liste des ports SHOM (France uniquement) depuis le WFS officiel.

Filtres : France uniquement (métropole + DOM-TOM). Tous les ports (ref=0 et ref=1)
sont conservés (ex. Arcachon est ref=1 mais doit apparaître).
Coordonnées : priorité à la géométrie WFS (EPSG:3857 -> WGS84) pour limiter les décalages GPS.

Format de sortie : ID:Nom:lat:lon (un port par ligne).
"""

import argparse
import json
import math
import sys
from pathlib import Path
from urllib.request import Request, urlopen

WFS_URL = (
    "https://services.data.shom.fr/x13f1b4faeszdyinv9zqxmx1/wfs"
    "?service=WFS&version=1.0.0&request=GetFeature"
    "&typeName=SPM_PORTS_WFS:liste_ports_spm_h2m&outputFormat=application/json"
)

# Bornes approximatives métropole (pour détecter coords DOM-TOM erronées)
METROPOLE_LAT = (41.0, 51.5)
METROPOLE_LON = (-5.5, 9.5)


def is_france(pays) -> bool:
    if pays is None:
        return False
    s = str(pays).strip()
    return s == "France" or s.startswith("France (")


def mercator_to_wgs84(x: float, y: float) -> tuple:
    """Convertit coordonnées EPSG:3857 (Web Mercator) en WGS84 (lat, lon)."""
    lon = x * 180.0 / 20037508.34
    lat = 360.0 * math.atan(math.exp(y * math.pi / 20037508.34)) / math.pi - 90.0
    return (lat, lon)


def dom_tom_coords_ok(pays: str, lat: float, lon: float) -> bool:
    """False si le port est DOM-TOM mais a des coords métropole ou 0,0 (erreur)."""
    if pays is None or not str(pays).startswith("France ("):
        return True
    if lat == 0.0 and lon == 0.0:
        return False
    # DOM-TOM ne doit pas être en métropole
    if METROPOLE_LAT[0] <= lat <= METROPOLE_LAT[1] and METROPOLE_LON[0] <= lon <= METROPOLE_LON[1]:
        return False
    return True


def fetch_wfs(timeout: int = 60) -> dict:
    req = Request(WFS_URL, headers={
        "User-Agent": "TideIt/1.0 (iOS; discovery)",
        "Referer": "https://maree.shom.fr/",
    })
    with urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def main():
    ap = argparse.ArgumentParser(description="Récupérer la liste des ports SHOM (France, ports principaux)")
    ap.add_argument("--output", type=Path, default=Path("Tide It/shom_ports.txt"), help="Fichier de sortie")
    ap.add_argument("--dry-run", action="store_true", help="Afficher sans écrire")
    ap.add_argument("--all", action="store_true", help="Inclure tous les ports (hors France + secondaires) comme avant")
    args = ap.parse_args()

    root = Path(__file__).resolve().parent.parent
    out_path = root / args.output if not args.output.is_absolute() else args.output

    print("Récupération du WFS SHOM...")
    data = fetch_wfs()
    features = data.get("features", [])
    print(f"  {len(features)} ports reçus.")

    if not args.all:
        features = [f for f in features if is_france((f.get("properties") or {}).get("pays"))]
        print(f"  Après filtre France : {len(features)}")

    lines = []
    skipped_domtom = 0
    for feat in features:
        props = feat.get("properties") or {}
        cst = props.get("cst") or ""
        toponyme = (props.get("toponyme") or "").strip()
        if not cst:
            continue
        # Priorité à la géométrie (position précise du WFS) pour limiter les décalages GPS
        lat_f, lon_f = None, None
        geom = feat.get("geometry") or {}
        if geom.get("type") == "Point" and len(geom.get("coordinates", [])) >= 2:
            try:
                x, y = float(geom["coordinates"][0]), float(geom["coordinates"][1])
                lat_f, lon_f = mercator_to_wgs84(x, y)
            except (TypeError, ValueError):
                pass
        if lat_f is None or lon_f is None:
            lat, lon = props.get("lat"), props.get("lon")
            if lat is None or lon is None:
                continue
            try:
                lat_f = float(lat)
                lon_f = float(lon)
            except (TypeError, ValueError):
                continue
        if not args.all and not dom_tom_coords_ok(props.get("pays"), lat_f, lon_f):
            skipped_domtom += 1
            continue
        # Une seule colonne "nom", pas de ":" dans le nom pour éviter de casser le format
        name = toponyme.replace(":", " - ") if ":" in toponyme else toponyme
        # DOM-TOM : ajouter le territoire entre parenthèses pour éviter les doublons (ex. Saint-Pierre)
        pays = props.get("pays") or ""
        if str(pays).startswith("France (") and str(pays).endswith(")"):
            territoire = str(pays)[8:-1].strip()  # "France (La Réunion)" -> "La Réunion"
            if territoire and territoire not in name:
                name = f"{name} ({territoire})"
        # 6 décimales pour coords (suffisant pour le GPS, évite flottants longs)
        line = f"{cst}:{name}:{round(lat_f, 6)}:{round(lon_f, 6)}"
        lines.append(line)

    if skipped_domtom:
        print(f"  Entrées DOM-TOM incohérentes exclues : {skipped_domtom}")

    # Tri par identifiant pour lisibilité
    lines.sort(key=lambda x: x.split(":", 1)[0].upper())

    if args.dry_run:
        print("\n--- Aperçu (10 premières lignes) ---")
        for ln in lines[:10]:
            print(ln)
        print(f"\n... total {len(lines)} lignes (non écrit)")
        return 0

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Fichier écrit : {out_path} ({len(lines)} ports)")
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)

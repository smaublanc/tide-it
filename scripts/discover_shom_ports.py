#!/usr/bin/env python3
"""
Script pour découvrir les ports SHOM manquants.
Interroge l'API vignette (services.data.shom.fr/hdm/vignette/grande/{id})
et extrait le nom du port. Optionnel : géocodage Nominatim pour lat/lon.
Usage:
  python discover_shom_ports.py [--candidates fichier.txt] [--geocode] [--dry-run]
"""

import argparse
import re
import sys
import time
from pathlib import Path
from typing import Optional, Tuple
from urllib.parse import quote
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

# Encodage des ports existants (ID -> ligne "ID:Nom:lat:lon")
def load_existing_ports(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    out = {}
    for line in path.read_text(encoding="utf-8").strip().splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(":", 1)
        if len(parts) >= 1:
            out[parts[0].strip().upper()] = line
    return out


def fetch_vignette(port_id: str, timeout: int = 15) -> Optional[str]:
    url = f"https://services.data.shom.fr/hdm/vignette/grande/{quote(port_id)}?locale=fr"
    req = Request(url, headers={"User-Agent": "TideIt/1.0 (iOS; discovery)"})
    try:
        with urlopen(req, timeout=timeout) as r:
            return r.read().decode("utf-8", errors="replace")
    except (HTTPError, URLError, OSError):
        return None


def has_valid_tide_data(js_content: str) -> bool:
    """Détecte si la réponse contient des données de marée (BM/PM + heures)."""
    if "BM" not in js_content and "PM" not in js_content:
        return False
    if re.search(r"\d{2}:\d{2}", js_content):
        return True
    return False


def extract_port_name(js_content: str, port_id: str) -> str:
    """Extrait le nom du port depuis le JS de la vignette."""
    # Ex: ifrm.document.write(' Horaire des marées - Arradon'); ou ...Arradon</title>
    m = re.search(r"Horaire des marées\s*[-–]\s*([^'\"<]+)", js_content)
    if m:
        return m.group(1).strip().replace("</title>", "")
    # Ex: ...Arradon</title>
    m = re.search(r"marées\s*[-–]?\s*([A-Za-zÀ-ÿ\-'\s]+?)(?:</title>|')", js_content)
    if m:
        return m.group(1).strip()
    # Ex: ifrm.document.write('# Arradon');
    m = re.search(r"document\.write\s*\(\s*['\"]#\s*([^'\"]+)['\"]", js_content)
    if m:
        return m.group(1).strip()
    # Ex: Horaire des maréesPortsall -> "Portsall"
    m = re.search(r"marées\s*([A-Za-zÀ-ÿ\-'\s]+?)(?:\s*\[|\s*$|')", js_content)
    if m:
        return m.group(1).strip()
    # Fallback: formater l'ID (ARRADON -> Arradon)
    return port_id.replace("_", " ").replace("-", "-").title()


def geocode(name: str) -> Optional[Tuple[float, float]]:
    """Géocodage via Nominatim (1 req/s). Retourne (lat, lon) ou None."""
    from urllib.parse import quote
    q = quote(f"{name}, France")
    url = f"https://nominatim.openstreetmap.org/search?q={q}&format=json&limit=1"
    req = Request(url, headers={"User-Agent": "TideIt/1.0 (discovery)"})
    try:
        with urlopen(req, timeout=10) as r:
            data = __import__("json").loads(r.read().decode())
        if data and len(data) > 0:
            return (float(data[0]["lat"]), float(data[0]["lon"]))
    except Exception:
        pass
    return None


# Candidats connus (ports SHOM existants mais souvent absents des listes)
# Format ID comme sur maree.shom.fr/harbor/ID (majuscules, tirets/underscores)
DEFAULT_CANDIDATES = [
    "ARRADON",
    "LARMOR-PLAGE",
    "ARZAL",
    "SENE",
    "LOCMARIAQUER",
    "ILE-AUX-MOINES",
    "KERMOROCH",
    "PLOUGASTEL",
    "PLOUHINEC",
    "LEZARDRIEUX",
    "LOGUIVY-DE-LA-MER",
    "PLESTIN-LES-GREVES",
    "PLOUESCAT",
    "BRIGNOGAN",
    "LE_FOLGOET",
    "TALARCT",
    "PONT-CROIX",
    "NEVEZ",
    "RIEC-SUR-BELON",
    "ILE-TUDY",
    "CLOHARS-FOUESNANT",
    "BEG-MEIL",
    "PORT-LA-FORET",
    "TREVOU-TREGUIGNEC",
    "PONT-LABBE",
    "TREFFIAGAT",
    "MERIGNAC",
]


def load_candidates_from_file(path: Path) -> list[str]:
    if not path.exists():
        return []
    lines = path.read_text(encoding="utf-8").strip().splitlines()
    return [ln.strip().upper() for ln in lines if ln.strip() and not ln.startswith("#")]


def main():
    ap = argparse.ArgumentParser(description="Découvrir les ports SHOM manquants")
    ap.add_argument("--ports-file", type=Path, default=Path("Tide It/shom_ports.txt"), help="Fichier shom_ports.txt")
    ap.add_argument("--candidates", type=Path, default=None, help="Fichier avec un ID par ligne (candidats à tester)")
    ap.add_argument("--geocode", action="store_true", help="Géocoder les nouveaux ports (Nominatim, lent)")
    ap.add_argument("--dry-run", action="store_true", help="Ne pas écrire le fichier, seulement afficher")
    ap.add_argument("--output", type=Path, default=None, help="Fichier de sortie (défaut: --ports-file)")
    args = ap.parse_args()

    root = Path(__file__).resolve().parent.parent
    ports_path = root / args.ports_file if not args.ports_file.is_absolute() else args.ports_file
    out_path = args.output or ports_path
    if not out_path.is_absolute():
        out_path = root / out_path

    existing = load_existing_ports(ports_path)
    candidates = list(DEFAULT_CANDIDATES)
    if args.candidates:
        candidates.extend(load_candidates_from_file(args.candidates))
    # Dédupliquer et enlever les déjà présents
    to_try = []
    seen = set()
    for c in candidates:
        c = c.strip().upper()
        if not c or c in seen or c in existing:
            continue
        seen.add(c)
        to_try.append(c)

    print(f"Ports déjà dans le fichier: {len(existing)}")
    print(f"Candidats à tester: {len(to_try)}")

    new_lines = []
    for i, port_id in enumerate(to_try):
        js = fetch_vignette(port_id)
        if js is None:
            print(f"  [skip] {port_id} (pas de réponse)")
            continue
        if not has_valid_tide_data(js):
            print(f"  [skip] {port_id} (pas de données marée)")
            continue
        name = extract_port_name(js, port_id)
        lat, lon = 0.0, 0.0
        if args.geocode:
            g = geocode(name)
            if g:
                lat, lon = g
            time.sleep(1.1)
        line = f"{port_id}:{name}:{lat}:{lon}"
        new_lines.append(line)
        print(f"  [OK] {port_id} -> {name} ({lat}, {lon})")

    if not new_lines:
        print("Aucun nouveau port trouvé.")
        return 0

    if args.dry_run:
        print("\n--- Nouveaux ports (dry-run, non écrits) ---")
        for ln in new_lines:
            print(ln)
        return 0

    # Fusionner avec l'existant
    existing_set = set(existing.keys())
    all_lines = list(existing.values())
    for ln in new_lines:
        pid = ln.split(":", 1)[0].upper()
        if pid not in existing_set:
            all_lines.append(ln)
            existing_set.add(pid)

    out_path.write_text("\n".join(sorted(all_lines, key=lambda x: x.split(":", 1)[0])) + "\n", encoding="utf-8")
    print(f"\nFichier mis à jour: {out_path} ({len(all_lines)} lignes, +{len(new_lines)} nouveaux)")
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)

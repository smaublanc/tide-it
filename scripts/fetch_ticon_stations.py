#!/usr/bin/env python3
"""
Fetch TICON-4 tide stations from neaps/tide-database GitHub repo.
Excludes USA stations (already covered by NOAA).
Outputs a JSON file compatible with the Tide It app.
Uses only stdlib — no external dependencies.
"""

import json
import time
import sys
import urllib.request
import urllib.error
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

TREE_URL = "https://api.github.com/repos/neaps/tide-database/git/trees/main?recursive=1"
RAW_BASE = "https://raw.githubusercontent.com/neaps/tide-database/main/"

OUTPUT_PATH = Path(__file__).resolve().parent.parent / "Tide It" / "ticon_stations.json"
MAX_WORKERS = 15

# Constituents the app supports
ALLOWED_CONSTITUENTS = {
    "M2", "S2", "N2", "K2", "K1", "O1", "P1", "Q1", "J1", "OO1",
    "M4", "MS4", "MN4", "M6", "2N2", "MU2", "NU2", "L2", "T2",
    "LAM2", "2MS6", "MF", "MM", "SSA", "SA", "MSF",
}

CONSTITUENT_NAME_MAP = {
    "LAMBDA2": "LAM2", "LDA2": "LAM2",
    "MSF": "MSF",
}

# Country code (ISO 3166-1 alpha-3) to display name
COUNTRY_NAMES = {
    "ago": "Angola", "arg": "Argentina", "asm": "American Samoa", "ata": "Antarctica",
    "aus": "Australia", "bel": "Belgium", "bgd": "Bangladesh", "bgr": "Bulgaria",
    "bhr": "Bahrain", "bhs": "Bahamas", "blz": "Belize", "bra": "Brazil",
    "brb": "Barbados", "can": "Canada", "chl": "Chile", "chn": "China",
    "civ": "Côte d'Ivoire", "cmr": "Cameroon", "cog": "Congo", "cok": "Cook Islands",
    "col": "Colombia", "cpv": "Cape Verde", "cri": "Costa Rica", "cub": "Cuba",
    "cuw": "Curaçao", "deu": "Germany", "dji": "Djibouti", "dma": "Dominica",
    "dnk": "Denmark", "dom": "Dominican Republic", "ecu": "Ecuador", "egy": "Egypt",
    "esp": "Spain", "est": "Estonia", "fin": "Finland", "fji": "Fiji",
    "fra": "France", "fsm": "Micronesia", "gbr": "United Kingdom", "gha": "Ghana",
    "grc": "Greece", "grd": "Grenada", "grl": "Greenland", "gtm": "Guatemala",
    "hkg": "Hong Kong", "hnd": "Honduras", "hrv": "Croatia", "hti": "Haiti",
    "idn": "Indonesia", "ind": "India", "irl": "Ireland", "irn": "Iran",
    "irq": "Iraq", "isl": "Iceland", "isr": "Israel", "ita": "Italy",
    "jam": "Jamaica", "jpn": "Japan", "ken": "Kenya", "khm": "Cambodia",
    "kir": "Kiribati", "kor": "South Korea", "kwt": "Kuwait", "lbn": "Lebanon",
    "lby": "Libya", "lka": "Sri Lanka", "ltu": "Lithuania", "lva": "Latvia",
    "mar": "Morocco", "mdg": "Madagascar", "mex": "Mexico", "mhl": "Marshall Islands",
    "mmr": "Myanmar", "mne": "Montenegro", "moz": "Mozambique", "mrt": "Mauritania",
    "mus": "Mauritius", "mys": "Malaysia", "nam": "Namibia", "ncl": "New Caledonia",
    "nga": "Nigeria", "nic": "Nicaragua", "nld": "Netherlands", "nor": "Norway",
    "nzl": "New Zealand", "omn": "Oman", "pak": "Pakistan", "pan": "Panama",
    "per": "Peru", "phl": "Philippines", "plw": "Palau", "png": "Papua New Guinea",
    "pol": "Poland", "pri": "Puerto Rico", "prt": "Portugal", "pyf": "French Polynesia",
    "qat": "Qatar", "reu": "Réunion", "rou": "Romania", "rus": "Russia",
    "sau": "Saudi Arabia", "sen": "Senegal", "sgp": "Singapore", "slb": "Solomon Islands",
    "sle": "Sierra Leone", "slv": "El Salvador", "som": "Somalia", "stp": "São Tomé and Príncipe",
    "sur": "Suriname", "svn": "Slovenia", "swe": "Sweden", "tgo": "Togo",
    "tha": "Thailand", "ton": "Tonga", "tto": "Trinidad and Tobago", "tun": "Tunisia",
    "tur": "Turkey", "tuv": "Tuvalu", "twn": "Taiwan", "tza": "Tanzania",
    "ukr": "Ukraine", "ury": "Uruguay", "usa": "United States",
    "ven": "Venezuela", "vir": "US Virgin Islands", "vnm": "Vietnam",
    "vut": "Vanuatu", "wsm": "Samoa", "yem": "Yemen", "zaf": "South Africa",
    "myt": "Mayotte", "glp": "Guadeloupe", "mtq": "Martinique", "guf": "French Guiana",
    "spm": "Saint Pierre and Miquelon", "atf": "French Southern Territories",
    "wlf": "Wallis and Futuna", "umi": "US Minor Outlying Islands",
    "gum": "Guam", "mnp": "Northern Mariana Islands",
}


def fetch_json(url):
    """Fetch JSON from URL with retries."""
    for attempt in range(3):
        try:
            req = urllib.request.Request(url)
            req.add_header("Accept", "application/json")
            req.add_header("User-Agent", "TideIt-App/1.0")
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except Exception as e:
            if attempt < 2:
                time.sleep(0.5 * (attempt + 1))
            else:
                return None


def normalize_constituent_name(name):
    """Map TICON constituent name to app-internal name."""
    upper = name.upper().strip()
    mapped = CONSTITUENT_NAME_MAP.get(upper, upper)
    for allowed in ALLOWED_CONSTITUENTS:
        if mapped.upper() == allowed.upper():
            return allowed
    return None


def process_station(file_path):
    """Download and process a single TICON station file."""
    url = RAW_BASE + file_path
    data = fetch_json(url)
    if data is None:
        return None

    harcon_list = data.get("harmonic_constituents", [])
    if not harcon_list or not isinstance(harcon_list, list):
        return None

    constituents = []
    has_m2 = has_s2 = False

    for c in harcon_list:
        raw_name = c.get("name", "")
        if not raw_name:
            continue
        try:
            amplitude = float(c.get("amplitude", 0))
            phase = float(c.get("phase", 0))
        except (TypeError, ValueError):
            continue

        mapped = normalize_constituent_name(raw_name)
        if mapped is None:
            continue

        if mapped == "M2":
            has_m2 = True
        if mapped == "S2":
            has_s2 = True

        constituents.append({
            "id": mapped,
            "amplitude": round(amplitude, 4),
            "phase": round(phase, 2),
        })

    if not has_m2 or not has_s2:
        return None

    lat = float(data.get("latitude", 0))
    lng = float(data.get("longitude", 0))
    name = data.get("name", "").strip().title()
    country = data.get("country", "")
    timezone_str = data.get("timezone", "Etc/UTC")
    source_id = data.get("source", {}).get("id", "")

    # Mean sea level from datums
    datums = data.get("datums", {})
    msl = float(datums.get("MSL", 0))

    # LAT datum for chart datum offset
    lat_datum = float(datums.get("LAT", 0))

    # Build unique ID
    station_id = f"TICON_{source_id}" if source_id else f"TICON_{name.upper().replace(' ', '_')}"

    return {
        "id": station_id,
        "name": name,
        "latitude": round(lat, 6),
        "longitude": round(lng, 6),
        "timezone": timezone_str,
        "country": country,
        "continent": data.get("continent", ""),
        "meanSeaLevel": round(msl, 4),
        "constituents": constituents,
    }


def main():
    print("Fetching repository tree...")
    tree_data = fetch_json(TREE_URL)
    if not tree_data:
        print("ERROR: Failed to fetch repo tree")
        sys.exit(1)

    # Get all TICON JSON files, excluding USA stations (covered by NOAA)
    # Also exclude French stations (covered by SHOM)
    ticon_files = []
    for item in tree_data.get("tree", []):
        path = item.get("path", "")
        if not path.startswith("data/ticon/") or not path.endswith(".json"):
            continue
        filename = path.split("/")[-1]
        # Extract country code from filename pattern: name-id-COUNTRY-source.json
        parts = filename.rsplit(".json", 1)[0].split("-")
        if len(parts) >= 3:
            country_code = parts[-2].lower()
            # Skip USA (covered by NOAA) and France (covered by SHOM)
            if country_code in ("usa",):
                continue
        ticon_files.append(path)

    total = len(ticon_files)
    print(f"Found {total} non-USA TICON stations. Fetching data...\n")

    valid = []
    skipped = 0
    done = 0
    start = time.time()
    seen_ids = set()

    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        futures = {pool.submit(process_station, f): f for f in ticon_files}
        for future in as_completed(futures):
            done += 1
            result = future.result()
            if result and result["id"] not in seen_ids:
                seen_ids.add(result["id"])
                valid.append(result)
            else:
                skipped += 1
            if done % 100 == 0 or done == total:
                pct = done * 100 // total
                print(f"\r  Progress: {done}/{total} ({pct}%)", end="", flush=True)

    elapsed = time.time() - start
    print()

    # Deduplicate by location (keep station with most constituents)
    location_map = {}
    for s in valid:
        key = (round(s["latitude"], 3), round(s["longitude"], 3))
        if key not in location_map or len(s["constituents"]) > len(location_map[key]["constituents"]):
            location_map[key] = s

    deduped = list(location_map.values())
    deduped.sort(key=lambda x: x["id"])

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(OUTPUT_PATH, "w", encoding="utf-8") as f:
        json.dump(deduped, f, ensure_ascii=False)

    print(f"\n{'='*60}")
    print(f"  Total files:               {total}")
    print(f"  Valid (with M2+S2):        {len(valid)}")
    print(f"  After dedup by location:   {len(deduped)}")
    print(f"  Skipped:                   {skipped}")
    print(f"  Time:                      {elapsed:.1f}s")
    print(f"  Output:                    {OUTPUT_PATH}")
    print(f"  File size:                 {OUTPUT_PATH.stat().st_size / 1024:.0f} KB")
    print(f"{'='*60}")


if __name__ == "__main__":
    main()

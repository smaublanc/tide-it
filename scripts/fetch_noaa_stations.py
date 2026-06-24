#!/usr/bin/env python3
"""
Fetch all NOAA tide prediction stations with harmonic constituents.
Outputs a JSON file compatible with the Tide It app.
Uses only stdlib (urllib) — no external dependencies.
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

STATIONS_URL = (
    "https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations.json"
    "?type=harcon"
)
HARCON_URL_TEMPLATE = (
    "https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations"
    "/{station_id}/harcon.json?units=metric"
)

OUTPUT_PATH = Path(__file__).resolve().parent.parent / "Tide It" / "noaa_stations.json"
MAX_WORKERS = 10

# Constituents the app expects
ALLOWED_CONSTITUENTS = {
    "M2", "S2", "N2", "K2", "K1", "O1", "P1", "Q1", "J1", "OO1",
    "M4", "MS4", "MN4", "M6", "2N2", "MU2", "NU2", "L2", "T2",
    "LAM2", "2MS6", "MF", "MM", "SSA", "SA", "MSF",
}

CONSTITUENT_NAME_MAP = {
    "LAMBDA2": "LAM2", "LDA2": "LAM2",
}

# US state abbreviation to full name
STATE_NAMES = {
    "AL": "Alabama", "AK": "Alaska", "AZ": "Arizona", "AR": "Arkansas",
    "CA": "California", "CO": "Colorado", "CT": "Connecticut", "DE": "Delaware",
    "FL": "Florida", "GA": "Georgia", "HI": "Hawaii", "ID": "Idaho",
    "IL": "Illinois", "IN": "Indiana", "IA": "Iowa", "KS": "Kansas",
    "KY": "Kentucky", "LA": "Louisiana", "ME": "Maine", "MD": "Maryland",
    "MA": "Massachusetts", "MI": "Michigan", "MN": "Minnesota", "MS": "Mississippi",
    "MO": "Missouri", "MT": "Montana", "NE": "Nebraska", "NV": "Nevada",
    "NH": "New Hampshire", "NJ": "New Jersey", "NM": "New Mexico", "NY": "New York",
    "NC": "North Carolina", "ND": "North Dakota", "OH": "Ohio", "OK": "Oklahoma",
    "OR": "Oregon", "PA": "Pennsylvania", "RI": "Rhode Island", "SC": "South Carolina",
    "SD": "South Dakota", "TN": "Tennessee", "TX": "Texas", "UT": "Utah",
    "VT": "Vermont", "VA": "Virginia", "WA": "Washington", "WV": "West Virginia",
    "WI": "Wisconsin", "WY": "Wyoming", "DC": "Washington D.C.",
    "PR": "Puerto Rico", "VI": "US Virgin Islands", "GU": "Guam",
    "AS": "American Samoa", "MP": "Northern Mariana Islands",
}

TIMEZONE_BY_LONGITUDE = [
    (-180, -170, "Pacific/Pago_Pago"),
    (-170, -140, "Pacific/Honolulu"),
    (-140, -120, "America/Los_Angeles"),
    (-120, -105, "America/Denver"),
    (-105, -90, "America/Chicago"),
    (-90, -60, "America/New_York"),
    (-60, -30, "America/Puerto_Rico"),
    (140, 180, "Pacific/Guam"),
]


def infer_timezone(lat, lon):
    if lat > 50 and -180 <= lon <= -130:
        return "America/Anchorage"
    for lo, hi, tz in TIMEZONE_BY_LONGITUDE:
        if lo <= lon < hi:
            return tz
    return "Etc/UTC"


def normalize_constituent_name(name):
    upper = name.upper().strip()
    mapped = CONSTITUENT_NAME_MAP.get(upper, upper)
    for allowed in ALLOWED_CONSTITUENTS:
        if mapped.upper() == allowed.upper():
            return allowed
    return None


def fetch_json(url):
    try:
        req = urllib.request.Request(url)
        req.add_header("Accept", "application/json")
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except Exception:
        return None


def process_station(station):
    station_id = station.get("id", "")
    url = HARCON_URL_TEMPLATE.format(station_id=station_id)
    data = fetch_json(url)

    if data is None:
        return None

    harcon_list = data.get("HarmonicConstituents") or data.get("harcon")
    if isinstance(harcon_list, dict):
        harcon_list = harcon_list.get("HarmonicConstituents")
    if not harcon_list or not isinstance(harcon_list, list):
        return None

    z0 = 0.0
    constituents = []
    has_m2 = has_s2 = False

    for c in harcon_list:
        raw_name = c.get("name", c.get("constName", ""))
        if not raw_name:
            continue
        try:
            amplitude = float(c.get("amplitude", 0))
            phase = float(c.get("phase_GMT", c.get("phase", 0)))
        except (TypeError, ValueError):
            continue

        if raw_name.upper().strip() == "Z0":
            z0 = amplitude
            continue

        mapped = normalize_constituent_name(raw_name)
        if mapped is None:
            continue

        if mapped == "M2": has_m2 = True
        if mapped == "S2": has_s2 = True

        constituents.append({
            "id": mapped,
            "amplitude": round(amplitude, 4),
            "phase": round(phase, 2),
        })

    if not has_m2 or not has_s2:
        return None

    lat = float(station.get("lat", 0))
    lng = float(station.get("lng", 0))
    name = station.get("name", station_id).strip().title()
    state = station.get("state", "")
    state_full = STATE_NAMES.get(state.upper(), state) if state else ""

    return {
        "id": f"NOAA_{station_id}",
        "name": name,
        "latitude": round(lat, 6),
        "longitude": round(lng, 6),
        "timezone": infer_timezone(lat, lng),
        "country": "États-Unis",
        "state": state_full,
        "meanSeaLevel": round(z0, 4),
        "constituents": constituents,
    }


def main():
    print("Fetching NOAA station list...")
    stations_data = fetch_json(STATIONS_URL)
    if not stations_data:
        print("ERROR: Failed to fetch station list")
        sys.exit(1)

    stations = stations_data.get("stations", [])
    if not stations:
        print("ERROR: No stations found")
        sys.exit(1)

    total = len(stations)
    print(f"Found {total} stations. Fetching harmonic constituents...\n")

    valid = []
    skipped = 0
    done = 0
    start = time.time()

    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        futures = {pool.submit(process_station, s): s for s in stations}
        for future in as_completed(futures):
            done += 1
            result = future.result()
            if result:
                valid.append(result)
            else:
                skipped += 1
            if done % 50 == 0 or done == total:
                pct = done * 100 // total
                print(f"\r  Progress: {done}/{total} ({pct}%)", end="", flush=True)

    elapsed = time.time() - start
    print()

    valid.sort(key=lambda x: x["id"])
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(OUTPUT_PATH, "w", encoding="utf-8") as f:
        json.dump(valid, f, ensure_ascii=False)  # compact for bundle size

    print(f"\n{'='*60}")
    print(f"  Total stations:            {total}")
    print(f"  Valid (with M2+S2):        {len(valid)}")
    print(f"  Skipped:                   {skipped}")
    print(f"  Time:                      {elapsed:.1f}s")
    print(f"  Output:                    {OUTPUT_PATH}")
    print(f"  File size:                 {OUTPUT_PATH.stat().st_size / 1024:.0f} KB")
    print(f"{'='*60}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
VOLET 4 — LA JUSTESSE, PAS LA STABILITÉ.

Le volet 3 a classé les 6 méthodes d'échantillonnage par leur STABILITÉ au pointage.
Une méthode stable mais FAUSSE serait pire que la méthode actuelle. Ce volet-ci les
confronte donc au vent RÉELLEMENT MESURÉ.

⚠️ BIAIS DE VALIDATION, à lire AVANT les chiffres — il commande tout le protocole.
   Une station METAR est posée sur la TERRE (aérodrome). Son anémomètre est dans une
   rugosité de terre : elle favorise donc MÉCANIQUEMENT les méthodes qui lisent les
   mailles TERRE (A centre, B médiane, F pondérée) et pénalise celles qui lisent l'eau
   (C, D) ou le maximum (E).
   Une bouée NDBC est en pleine mer : elle favorise exactement l'inverse.
   Les deux familles ne sont JAMAIS mélangées, et aucun chiffre global ne les agrège.
   Le seul énoncé qui vaille est celui qui tient dans les DEUX familles à la fois.

FAMILLES DE VÉRITÉ TERRAIN
  1. METAR (IEM/ASOS) — 44 aérodromes CÔTIERS, 12 pays, France plafonnée à 3 stations
     (piège documenté du dépôt : un correctif validé sur la seule France est une
     régression déguisée). Vent moyen en nœuds, `sknt`, report_type=3 (METAR routiniers).
  2. Bouées NDBC — 21 bouées américaines NEARSHORE (8 à 45 NM du trait de côte).
     Vent en m/s à l'altitude de l'anémomètre (3,8 à 4,1 m) : la correction au niveau
     10 m par la loi logarithmique est appliquée ET le résultat brut est conservé, car
     cette correction déplace le NIVEAU et donc le classement des méthodes.
  3. Bouées des GRANDS LACS (2) — gardées À PART : l'eau douce d'altitude est l'angle
     mort connu de la règle « elevation == 0 » (volet 1). Elles servent de contrôle.

MODÈLES : les trois de la chaîne de l'app, en UNE requête (`meteofrance_seamless`,
`icon_seamless`, `gfs_seamless`). MF est le modèle EFFECTIF de l'app partout ; GFS
apporte HRRR 3 km au-dessus des États-Unis, seule façon de donner à la croix de 2 km
une grille assez fine pour que le filtre d'élévation puisse trancher quelque chose.

SOURCE MODÈLE : historical-forecast-api.open-meteo.com (quota propre ; celui de
api.open-meteo.com est épuisé). Même modèle, même grille native, même MNT.

Sortie : audit/resultats_verite_terrain.json   (cache : rejouer est gratuit)
Analyse : audit/analyse_verite_terrain.py
"""
import json, math, os, re, subprocess, sys, time, urllib.parse

ICI = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(ICI, "resultats_verite_terrain.json")

NEIGHBOURHOOD_KM = 2.0          # = MarineWeatherService.neighbourhoodKm
MODELS = "meteofrance_seamless,icon_seamless,gfs_seamless"
HOST = "https://historical-forecast-api.open-meteo.com/v1/forecast"

# Fenêtre de 21 jours, UTC. Bornée à J-1 : le run du jour n'est pas encore archivé.
D1, D2 = "2026-07-27", "2026-08-16"

# ─────────────────────────────────────────────────────────────────────────────
# 1. STATIONS METAR CÔTIÈRES — 12 pays. La France pèse 3 sur 44 (6,8 %).
#    Coordonnées relevées sur les geojson IEM (mesonet.agron.iastate.edu).
# ─────────────────────────────────────────────────────────────────────────────
METAR = [
    # (ICAO, nom, pays, lat, lon)
    ("EHKD", "Den Helder/De Kooy",   "NL", 52.9269,   4.7811),
    ("EHFS", "Vlissingen",           "NL", 51.4413,   3.5959),
    ("EHRD", "Rotterdam",            "NL", 51.9537,   4.4441),
    ("EKCH", "Copenhague",           "DK", 55.6142,  12.6453),
    ("EKYT", "Aalborg",              "DK", 57.0964,   9.8506),
    ("EKEB", "Esbjerg",              "DK", 55.5281,   8.5631),
    ("EKRN", "Ronne/Bornholm",       "DK", 55.0667,  14.7500),
    ("LPFR", "Faro",                 "PT", 37.0167,  -7.9667),
    ("LPPR", "Porto",                "PT", 41.2333,  -8.6833),
    ("LPMA", "Funchal/Madere",       "PT", 32.6979, -16.7744),
    ("LPPD", "Ponta Delgada",        "PT", 37.7412, -25.6979),
    ("LPLA", "Lajes/Terceira",       "PT", 38.7618, -27.0908),
    ("LEBL", "Barcelone",            "ES", 41.2928,   2.0700),
    ("LEVC", "Valence",              "ES", 39.4867,  -0.4733),
    ("LEAL", "Alicante",             "ES", 38.2822,  -0.5582),
    ("LEMG", "Malaga",               "ES", 36.6769,  -4.4906),
    ("LEXJ", "Santander",            "ES", 43.4292,  -3.8314),
    ("LEPA", "Palma de Majorque",    "ES", 39.5608,   2.7367),
    ("GCRR", "Arrecife/Lanzarote",   "ES", 28.9519, -13.6003),
    ("LICJ", "Palerme",              "IT", 38.1819,  13.0994),
    ("LICC", "Catane",               "IT", 37.4667,  15.0639),
    ("LIEE", "Cagliari",             "IT", 39.2434,   9.0603),
    ("LIPZ", "Venise",               "IT", 45.5053,  12.3519),
    ("LICT", "Trapani",              "IT", 37.9142,  12.4914),
    ("LGIR", "Heraklion",            "GR", 35.3397,  25.1803),
    ("LGRP", "Rhodes",               "GR", 36.4054,  28.0862),
    ("LGMK", "Mykonos",              "GR", 37.4333,  25.3500),
    ("LGKO", "Kos",                  "GR", 36.8007,  27.0908),
    ("LGSA", "La Canee/Crete",       "GR", 35.4833,  24.1167),
    ("LFRB", "Brest",                "FR", 48.4442,  -4.4119),
    ("LFMN", "Nice",                 "FR", 43.6489,   7.2089),
    ("LFBZ", "Biarritz",             "FR", 43.4694,  -1.5344),
    ("EIDW", "Dublin",               "IE", 53.4215,  -6.2977),
    ("EICK", "Cork",                 "IE", 51.8481,  -8.4794),
    ("EDXW", "Westerland/Sylt",      "DE", 54.9132,   8.3405),
    ("ENZV", "Stavanger",            "NO", 58.8767,   5.6378),
    ("ENBR", "Bergen",               "NO", 60.2892,   5.2264),
    ("ENBO", "Bodo",                 "NO", 67.2667,  14.3667),
    ("ENTC", "Tromso",               "NO", 69.6767,  18.9131),
    ("LDSP", "Split",                "HR", 43.5394,  16.3011),
    ("LDZD", "Zadar",                "HR", 44.0969,  15.3628),
    ("LDPL", "Pula",                 "HR", 44.8964,  13.9319),
    ("EGPA", "Kirkwall/Orcades",     "GB", 58.9536,  -2.9014),
    ("EGPB", "Sumburgh/Shetland",    "GB", 59.8789,  -1.2956),
    ("EGPC", "Wick",                 "GB", 58.4589,  -3.0931),
    ("EGNH", "Blackpool",            "GB", 53.7744,  -3.0394),
    ("EGJJ", "Jersey",               "GB", 49.2096,  -2.1943),
]

# ─────────────────────────────────────────────────────────────────────────────
# 2. BOUÉES NDBC NEARSHORE (océan) + 2 bouées de GRANDS LACS, gardées à part.
# ─────────────────────────────────────────────────────────────────────────────
BOUEES = [
    ("44018", "Cape Cod, MA",            42.203,  -70.154, "ocean"),
    ("44013", "Boston, MA",              42.346,  -70.651, "ocean"),
    ("44065", "New York Harbor, NY",     40.368,  -73.701, "ocean"),
    ("44017", "Montauk Point, NY",       40.693,  -72.049, "ocean"),
    ("44025", "Long Island, NY",         40.258,  -73.175, "ocean"),
    ("44027", "Jonesport, ME",           44.284,  -67.301, "ocean"),
    ("44009", "Delaware Bay, NJ",        38.460,  -74.692, "ocean"),
    ("41013", "Frying Pan Shoals, NC",   33.436,  -77.764, "ocean"),
    ("41008", "Grays Reef, GA",          31.400,  -80.866, "ocean"),
    ("41009", "Canaveral, FL",           28.508,  -80.185, "ocean"),
    ("42035", "Galveston, TX",           29.235,  -94.410, "ocean"),
    ("42012", "Orange Beach, AL",        30.061,  -87.547, "ocean"),
    ("42013", "WFS C10, FL",             27.173,  -82.924, "ocean"),
    ("46026", "San Francisco, CA",       37.750, -122.838, "ocean"),
    ("46042", "Monterey, CA",            36.787, -122.408, "ocean"),
    ("46053", "E. Santa Barbara, CA",    34.246, -119.842, "ocean"),
    ("46011", "Santa Maria, CA",         34.937, -120.999, "ocean"),
    ("46022", "Eel River, CA",           40.716, -124.540, "ocean"),
    ("46027", "St Georges, CA",          41.840, -124.382, "ocean"),
    ("46029", "Columbia River Bar, OR",  46.148, -124.508, "ocean"),
    ("46015", "Port Orford, OR",         42.754, -124.839, "ocean"),
    ("46050", "Stonewall Bank, OR",      44.679, -124.535, "ocean"),
    ("46041", "Cape Elizabeth, WA",      47.351, -124.741, "ocean"),
    # Grands Lacs : angle mort connu de « elevation == 0 » (eau douce en altitude).
    ("45007", "South Michigan (lac)",    42.674,  -87.026, "lac"),
    ("45012", "East Lake Ontario (lac)", 43.621,  -77.401, "lac"),

    # ── FAMILLE 3 — capteurs À LA LAISSE DE MER (C-MAN / marégraphes NOS) ───────
    # Ni terre franche ni pleine mer : posés sur une jetée, un phare, un îlot ou une
    # île-barrière. C'est le SEUL endroit où la croix de 2 km enjambe vraiment le trait
    # de côte, donc le seul où le filtre « mailles eau » a quelque chose à trancher —
    # et c'est aussi la situation d'un spot de glisse. Le genre exact (laisse de mer,
    # îlot, pleine mer) est RE-DÉTERMINÉ après coup d'après les élévations mesurées.
    ("DUKN7", "Duck Pier, NC",           36.184,  -75.746, "laisse"),
    ("CHLV2", "Chesapeake Light, VA",    36.905,  -75.713, "laisse"),
    ("FWYF1", "Fowey Rock, FL",          25.591,  -80.097, "laisse"),
    ("SANF1", "Sand Key, FL",            24.456,  -81.877, "laisse"),
    ("MLRF1", "Molasses Reef, FL",       25.012,  -80.376, "laisse"),
    ("SMKF1", "Sombrero Key, FL",        24.628,  -81.109, "laisse"),
    ("LONF1", "Long Key, FL",            24.844,  -80.864, "laisse"),
    ("VENF1", "Venice, FL",              27.072,  -82.453, "laisse"),
    ("NPSF1", "Naples, FL",              26.132,  -81.807, "laisse"),
    ("CDRF1", "Cedar Key, FL",           29.136,  -83.029, "laisse"),
    ("KTNF1", "Keaton Beach, FL",        29.819,  -83.593, "laisse"),
    ("APCF1", "Apalachicola, FL",        29.724,  -84.980, "laisse"),
    ("SAUF1", "St Augustine, FL",        29.857,  -81.264, "laisse"),
    ("ANMF1", "Anna Maria, FL",          27.538,  -82.739, "laisse"),
    ("GDIL1", "Grand Isle, LA",          29.267,  -89.957, "laisse"),
    ("BURL1", "Southwest Pass, LA",      28.906,  -89.429, "laisse"),
    ("DPIA1", "Dauphin Island, AL",      30.250,  -88.075, "laisse"),
    ("PTAT2", "Port Aransas, TX",        27.826,  -97.051, "laisse"),
    ("SRST2", "Sabine Pass, TX",         29.683,  -94.033, "laisse"),
    ("LJPC1", "La Jolla, CA",            32.867, -117.257, "laisse"),
    ("PTGC1", "Point Arguello, CA",      34.577, -120.648, "laisse"),
    ("CECC1", "Crescent City, CA",       41.746, -124.184, "laisse"),
    ("PORO3", "Port Orford, OR",         42.739, -124.498, "laisse"),
    ("NWPO3", "Newport, OR",             44.613, -124.067, "laisse"),
    ("TLBO3", "Garibaldi/Tillamook, OR", 45.555, -123.919, "laisse"),
    ("WPTW1", "Westport, WA",            46.904, -124.105, "laisse"),
    ("DESW1", "Destruction Island, WA",  47.675, -124.485, "laisse"),
    ("SISW1", "Smith Island, WA",        48.321, -122.831, "laisse"),
    ("BUZM3", "Buzzards Bay, MA",        41.397,  -71.033, "laisse"),
    ("MDRM1", "Mt. Desert Rock, ME",     43.969,  -68.128, "laisse"),
    ("MISM1", "Matinicus Rock, ME",      43.784,  -68.855, "laisse"),
    ("IOSN3", "Isle of Shoals, NH",      42.967,  -70.623, "laisse"),
    ("TPLM2", "Thomas Point, MD",        38.899,  -76.436, "laisse"),
    ("SPGF1", "Settlement Point (BS)",   26.704,  -78.995, "laisse"),
    # Grands Lacs, laisse de mer : même angle mort que ci-dessus, gardés à part.
    ("SBIO1", "South Bass Island (lac)", 41.629,  -82.841, "lac"),
    ("PILM4", "Passage Island (lac)",    48.223,  -88.366, "lac"),
]

MS_TO_KN = 1.9438445


def curl(url, timeout=180):
    r = subprocess.run(["curl", "-s", "--max-time", str(timeout), url],
                       capture_output=True, text=True)
    return r.stdout


def cle_heure(y, mo, d, h, mi):
    """Arrondit à l'heure la PLUS PROCHE (un METAR de 07:50 décrit 08:00, pas 07:00)."""
    import datetime
    t = datetime.datetime(y, mo, d, h, 0)
    if mi >= 30:
        t += datetime.timedelta(hours=1)
    return t.strftime("%Y-%m-%dT%H")


def obs_metar(icao):
    """Vent moyen mesuré, en NŒUDS, indexé par 'YYYY-MM-DDTHH' (UTC)."""
    y1, m1, d1 = D1.split("-")
    y2, m2, d2 = D2.split("-")
    u = ("https://mesonet.agron.iastate.edu/cgi-bin/request/asos.py?"
         f"station={icao}&data=sknt&year1={int(y1)}&month1={int(m1)}&day1={int(d1)}"
         f"&year2={int(y2)}&month2={int(m2)}&day2={int(d2)+1}"
         "&tz=Etc%2FUTC&format=onlycomma&latlon=no&missing=M&trace=T&direct=no&report_type=3")
    seau = {}
    for line in curl(u).splitlines()[1:]:
        p = line.split(",")
        if len(p) < 3 or p[2] in ("M", "", "T"):
            continue
        m = re.match(r"(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2})", p[1])
        if not m:
            continue
        try:
            v = float(p[2])
        except ValueError:
            continue
        k = cle_heure(*(int(g) for g in m.groups()))
        seau.setdefault(k, []).append(v)
    return {k: sum(v) / len(v) for k, v in seau.items()}


def hauteur_anemo(sid):
    """Hauteur de l'anémomètre AU-DESSUS DE LA MER, lue sur la page NDBC.

    NDBC donne « Anemometer height: X m above site elevation » et, pour les stations
    C-MAN posées sur un phare ou une jetée, « Site elevation: Y m above mean sea
    level ». La hauteur qui compte pour ramener le vent au niveau 10 m est X + Y :
    l'anémomètre d'un phare peut être à 44 m, soit un vent nettement plus fort que
    celui de 10 m, et l'ignorer fabriquerait un faux biais de surestimation.
    """
    page = curl(f"https://www.ndbc.noaa.gov/station_page.php?station={sid}", timeout=60)
    a = re.search(r"Anemometer height:(?:</b>)?\s*([\d.]+)\s*m", page)
    s = re.search(r"Site elevation:(?:</b>)?\s*([\d.]+)\s*m", page)
    if not a:
        return None
    return float(a.group(1)) + (float(s.group(1)) if s else 0.0)


def obs_bouee(sid):
    """Vent moyen mesuré, en NŒUDS À LA HAUTEUR DE L'ANÉMOMÈTRE, par heure UTC.

    realtime2 sert ~45 jours de relevés à 10 min. On moyenne les échantillons de la
    fenêtre [HH:00-30min ; HH:00+30min) — la même agrégation pour toutes les bouées.
    """
    txt = curl(f"https://www.ndbc.noaa.gov/data/realtime2/{sid}.txt", timeout=120)
    seau = {}
    for line in txt.splitlines():
        if line.startswith("#"):
            continue
        p = line.split()
        if len(p) < 7 or p[6] == "MM":
            continue
        try:
            y, mo, d, h, mi = (int(x) for x in p[:5])
            v = float(p[6])
        except ValueError:
            continue
        if v > 90:            # sentinelle NDBC
            continue
        seau.setdefault(cle_heure(y, mo, d, h, mi), []).append(v)
    return {k: sum(v) / len(v) / 1.0 * MS_TO_KN for k, v in seau.items()}


def neighbourhood(lat, lon):
    """Copie exacte de MarineWeatherService.neighbourhood (centre, N, S, E, O)."""
    d_lat = NEIGHBOURHOOD_KM / 111.0
    d_lon = NEIGHBOURHOOD_KM / (111.0 * max(0.1, math.cos(math.radians(lat))))
    return [(lat, lon), (lat + d_lat, lon), (lat - d_lat, lon),
            (lat, lon + d_lon), (lat, lon - d_lon)]


def modele(coords):
    """Les 5 points en UNE requête, 3 modèles. Renvoie la liste des réponses brutes."""
    q = urllib.parse.urlencode({
        "latitude":  ",".join(f"{c[0]:.4f}" for c in coords),
        "longitude": ",".join(f"{c[1]:.4f}" for c in coords),
        "hourly": "wind_speed_10m",
        "models": MODELS,
        "wind_speed_unit": "kn",
        "start_date": D1, "end_date": D2,
        "timezone": "UTC",
    })
    url = HOST + "?" + q
    for essai in range(6):
        out = curl(url)
        try:
            data = json.loads(out)
        except Exception:
            print(f"    ! réponse illisible ({out[:120]})", file=sys.stderr)
            time.sleep(20 * (essai + 1)); continue
        if isinstance(data, dict) and data.get("error"):
            raison = str(data.get("reason", "")).lower()
            print(f"    ! {data.get('reason')}", file=sys.stderr)
            if "daily" in raison:
                return "QUOTA"
            time.sleep(70 if ("minutely" in raison or "hourly" in raison)
                       else 20 * (essai + 1))
            continue
        if isinstance(data, dict):
            data = [data]
        if len(data) != len(coords):
            print(f"    ! {len(data)} séries pour {len(coords)}", file=sys.stderr)
            return None
        return data
    return None


def main():
    res = json.load(open(OUT)) if os.path.exists(OUT) else {"metar": [], "bouees": []}
    faits = {r["id"] for r in res["metar"]} | {r["id"] for r in res["bouees"]}

    PAYS_BOUEE = {"SPGF1": "BS"}   # Settlement Point est aux Bahamas, pas aux États-Unis
    taches = ([("metar", i, n, p, la, lo, "terre") for i, n, p, la, lo in METAR] +
              [("bouees", i, n, PAYS_BOUEE.get(i, "US"), la, lo, k)
               for i, n, la, lo, k in BOUEES])

    for famille, sid, nom, pays, lat, lon, genre in taches:
        if sid in faits:
            print(f"= {sid} (déjà)"); continue
        print(f"→ {sid} {nom}…", end=" ", flush=True)

        if famille == "metar":
            obs, h_anemo = obs_metar(sid), 10.0
        else:
            obs = obs_bouee(sid)
            h_anemo = hauteur_anemo(sid)

        if len(obs) < 200:
            print(f"observations insuffisantes ({len(obs)}) — IGNORÉE", flush=True)
            continue

        data = modele(neighbourhood(lat, lon))
        if data == "QUOTA":
            print("\nQUOTA JOURNALIER ÉPUISÉ — relancer demain, le cache reprend ici",
                  file=sys.stderr)
            break
        if data is None:
            print("échec modèle — passée", flush=True); continue

        series, elevs = {}, []
        times = None
        for d in data:
            h = d.get("hourly") or {}
            times = times or h.get("time")
            elevs.append(d.get("elevation"))
            for k, v in h.items():
                if k.startswith("wind_speed_10m_"):
                    series.setdefault(k[len("wind_speed_10m_"):], []).append(v)

        res[famille].append({
            "id": sid, "nom": nom, "pays": pays, "genre": genre,
            "lat": lat, "lon": lon, "hauteur_anemo_m": h_anemo,
            "times": times, "elevations": elevs,
            "vent_modele": series, "obs_kn": obs,
        })
        json.dump(res, open(OUT, "w"), ensure_ascii=False)
        print(f"ok — {len(obs)} h mesurées, élévations {elevs}, anémo {h_anemo} m",
              flush=True)
        time.sleep(1)

    print(f"\n{len(res['metar'])} METAR + {len(res['bouees'])} bouées → {OUT}")


if __name__ == "__main__":
    main()

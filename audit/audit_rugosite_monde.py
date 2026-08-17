#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AMPLEUR MONDIALE du défaut de RUGOSITÉ — la croix de 2 km, sondée comme l'app la sonde.

QUESTION : le saut de vent entre maille TERRE et maille EAU est-il une curiosité du
Bassin d'Arcachon, ou un défaut universel ?

MÉTHODE — pour chaque spot, UNE requête identique à celle de l'app
(`models=meteofrance_seamless,icon_seamless,gfs_seamless`, croix de 5 points à 2 km,
`MarineWeatherService.neighbourhood`), sur past_days=14, avec `elevation`.

DEUX GRANDEURS À NE PAS CONFONDRE, et c'est tout l'enjeu :
  1. L'EXPOSITION au défaut  = la croix straddle-t-elle terre et eau dans le MONDE RÉEL ?
     → lue sur `elevation`, qui vient du MNT 90 m d'Open-Meteo et NON du modèle.
     Vérifié : la même coordonnée renvoie la même élévation quel que soit le modèle
     demandé (Andernos : 5/15/0 m sous meteofrance, icon ET gfs).
  2. Ce que le MODÈLE en exprime = l'étendue du vent sur les 5 points.
     Elle ne peut être non nulle que si les 5 points tombent dans des mailles DISTINCTES.
     Deux points d'une même maille renvoient une série strictement identique : c'est
     ainsi qu'on compte les mailles, sans supposer la géométrie de la grille.

Le modèle EFFECTIF est le premier qui répond (WindEnsemble.modelPriority) — c'est lui
qui décide de la valeur affichée, donc c'est sur lui que l'amplitude doit être mesurée.

⚠️ RÉSULTAT STRUCTUREL DE CE SONDAGE (17 août 2026, 47 spots) : `meteofrance_seamless`
répond aux 47 spots, sur TOUS les continents — hors domaine AROME/ARPEGE-Europe il
retombe sur ARPEGE MONDE (0,25°, ~25 km). ICON et GFS ne servent donc JAMAIS de
prévision, seulement de second avis pour la confiance. Conséquence directe : sur 28
spots /47 la croix de 2 km tombe dans UNE SEULE maille et la médiane de voisinage est
un no-op exact (étendue identiquement nulle).

⚠️ QUOTA : ~1 500 « appels » Open-Meteo par passage (5 points × 3 modèles × 15 jours).
Le palier gratuit plafonne à 10 000/jour UTC — deux passages dans la même journée UTC
suffisent à l'épuiser si d'autres scripts ont déjà tourné.

Sortie : audit/resultats_rugosite_monde_2km.json
Agrégation : audit/analyse_rugosite_monde.py
"""
import json, math, os, subprocess, sys, time, urllib.parse
from statistics import median

NEIGHBOURHOOD_KM = float(os.environ.get("RAYON_KM", "2.0"))   # = MarineWeatherService.neighbourhoodKm
PAST_DAYS = int(os.environ.get("PAST_DAYS", "14"))
MODELS = ["meteofrance_seamless", "icon_seamless", "gfs_seamless"]  # = WindEnsemble.modelPriority
LABELS = ["centre", "nord", "sud", "est", "ouest"]

# (nom, lat, lon, zone) — spots de glisse côtiers, tous les continents.
SPOTS = [
    # Europe atlantique / mer du Nord
    ("Lacanau Ocean (FR)",        45.0000,   -1.2033, "Europe-Atlantique"),
    ("Andernos, Bassin (FR)",     44.7433,   -1.1042, "Europe-Atlantique"),
    ("Cap Ferret (FR)",           44.6300,   -1.2500, "Europe-Atlantique"),
    ("Guincho (PT)",              38.7320,   -9.4720, "Europe-Atlantique"),
    ("Brandon Bay (IE)",          52.2600,  -10.0300, "Europe-Atlantique"),
    ("Westkapelle (NL)",          51.5250,    3.4350, "Europe-Atlantique"),
    ("Sylt / Westerland (DE)",    54.9060,    8.3000, "Europe-Atlantique"),
    ("Tarifa (ES)",               36.0128,   -5.6033, "Europe-Atlantique"),
    ("Hvide Sande (DK)",          56.0000,    8.1300, "Europe-Atlantique"),
    # Méditerranée
    ("La Franqui, Leucate (FR)",  42.9160,    3.0300, "Mediterranee"),
    ("Hyeres, Almanarre (FR)",    43.0800,    6.1400, "Mediterranee"),
    ("Vassiliki (GR)",            38.6250,   20.6000, "Mediterranee"),
    ("Alacati (TR)",              38.2500,   26.3600, "Mediterranee"),
    ("Tarbena / Rosas (ES)",      42.2500,    3.1800, "Mediterranee"),
    # Afrique
    ("Dakhla lagune (MA)",        23.8500,  -15.8000, "Afrique"),
    ("Essaouira (MA)",            31.5000,   -9.7700, "Afrique"),
    ("Langebaan (ZA)",           -33.0900,   18.0300, "Afrique"),
    ("Blouberg, Le Cap (ZA)",    -33.8100,   18.4600, "Afrique"),
    ("Paje, Zanzibar (TZ)",       -6.2700,   39.5300, "Afrique"),
    ("Safaga (EG)",               26.7300,   33.9400, "Afrique"),
    # Caraïbes
    ("Cabarete (DO)",             19.7580,  -70.4110, "Caraibes"),
    ("Sorobon, Bonaire (BQ)",     12.0900,  -68.2200, "Caraibes"),
    ("Silver Rock (BB)",          13.0700,  -59.5300, "Caraibes"),
    # Amérique du Nord
    ("Cape Hatteras (US)",        35.2200,  -75.6900, "Amerique-Nord"),
    ("Hood River (US)",           45.7100, -121.5100, "Amerique-Nord"),
    ("La Ventana (MX)",           24.0500, -109.9900, "Amerique-Nord"),
    ("Sherman Island (US)",       38.0400, -121.7700, "Amerique-Nord"),
    ("Long Beach, NY (US)",       40.5800,  -73.6600, "Amerique-Nord"),
    # Amérique du Sud / centrale
    ("Cumbuco (BR)",              -3.6250,  -38.7300, "Amerique-Sud"),
    ("Jericoacoara (BR)",         -2.7950,  -40.5100, "Amerique-Sud"),
    ("Paracas (PE)",             -13.8300,  -76.2500, "Amerique-Sud"),
    ("Punta Chame (PA)",           8.6400,  -79.7000, "Amerique-Sud"),
    ("Lago Los Barreales (AR)",  -38.6000,  -68.7500, "Amerique-Sud"),
    # Asie
    ("Mui Ne (VN)",               10.9500,  108.2600, "Asie"),
    ("Bulabog, Boracay (PH)",     11.9700,  121.9300, "Asie"),
    ("Kalpitiya (LK)",             8.2300,   79.7500, "Asie"),
    ("Ishigaki (JP)",             24.4000,  124.1500, "Asie"),
    ("Hayling / Muscat (OM)",     23.5900,   58.5000, "Asie"),
    # Océanie
    ("Leighton, Perth (AU)",     -32.0400,  115.7500, "Oceanie"),
    ("Currumbin (AU)",           -28.1300,  153.4900, "Oceanie"),
    ("New Plymouth (NZ)",        -39.0500,  174.0300, "Oceanie"),
    ("Lake George (AU)",         -35.0800,  149.4200, "Oceanie"),
    # Îles
    ("Le Morne (MU)",            -20.4900,   57.3100, "Iles"),
    ("Pozo Izquierdo (ES)",       27.8100,  -15.4200, "Iles"),
    ("Kite Beach, Maui (US)",     20.9000, -156.4400, "Iles"),
    ("Punta Preta, Sal (CV)",     16.5900,  -22.9400, "Iles"),
    ("Anegada (VG)",              18.7300,  -64.3300, "Iles"),
]


def neighbourhood(lat, lon):
    """Copie exacte de MarineWeatherService.neighbourhood."""
    d_lat = NEIGHBOURHOOD_KM / 111.0
    d_lon = NEIGHBOURHOOD_KM / (111.0 * max(0.1, math.cos(math.radians(lat))))
    return [(lat, lon), (lat + d_lat, lon), (lat - d_lat, lon),
            (lat, lon + d_lon), (lat, lon - d_lon)]


def pct(xs, p):
    if not xs:
        return None
    s = sorted(xs)
    k = (len(s) - 1) * p
    lo, hi = math.floor(k), math.ceil(k)
    return s[lo] if lo == hi else s[lo] + (s[hi] - s[lo]) * (k - lo)


def fetch(lat, lon):
    pts = neighbourhood(lat, lon)
    q = urllib.parse.urlencode({
        "latitude":  ",".join(f"{p[0]:.4f}" for p in pts),
        "longitude": ",".join(f"{p[1]:.4f}" for p in pts),
        "hourly": "wind_speed_10m",
        "models": ",".join(MODELS),
        "wind_speed_unit": "kn",
        "past_days": str(PAST_DAYS),
        "forecast_days": "1",
    })
    url = "https://api.open-meteo.com/v1/forecast?" + q
    for attempt in range(6):
        try:
            out = subprocess.run(["curl", "-s", "--max-time", "120", url],
                                 capture_output=True, timeout=140)
            data = json.loads(out.stdout.decode())
            if isinstance(data, dict) and "error" in data:
                raise RuntimeError(data.get("reason", "erreur API"))
            return data if isinstance(data, list) else [data]
        except Exception as e:
            if attempt == 5:
                print(f"    ECHEC: {e}", file=sys.stderr, flush=True)
                return None
            time.sleep(20 * (attempt + 1))
    return None


def series_of(loc, model):
    h = loc.get("hourly") or {}
    return h.get(f"wind_speed_10m_{model}")


def stats_for_model(series, is_water, n):
    """series = liste de 5 séries pour UN modèle. Renvoie None si le modèle ne répond pas."""
    if any(s is None for s in series):
        return None
    # mailles distinctes : deux points d'une même maille ont une série IDENTIQUE.
    sigs = [tuple(s[:n]) for s in series]
    uniq = list(dict.fromkeys(sigs))
    groupe = [uniq.index(s) for s in sigs]      # index de maille pour chacun des 5 points
    cells = len(uniq)
    couverture = sum(1 for v in series[0][:n] if v is not None)
    if couverture < 24:
        return None

    # OPPOSABLE : eau et terre occupent des mailles DISJOINTES. Sinon comparer la médiane
    # « eau » à la médiane « terre » compare une série avec elle-même — ratio 1,000 par
    # construction, qui n'apprend rien et tire toutes les moyennes vers 1.
    gw = {groupe[i] for i in range(5) if is_water[i]}
    gl = {groupe[i] for i in range(5) if not is_water[i]}
    opposable = bool(gw) and bool(gl) and not (gw & gl)

    ranges, ranges_windy, diffs, ratios, w_all, l_all, centre = [], [], [], [], [], [], []
    mixed = 0 < sum(is_water) < 5
    for h in range(n):
        vals = [s[h] for s in series]
        if any(v is None for v in vals):
            continue
        centre.append(vals[0])
        rg = max(vals) - min(vals)
        ranges.append(rg)
        if vals[0] >= 8.0:                       # heures navigables
            ranges_windy.append(rg)
        if mixed:
            w = median([vals[i] for i in range(5) if is_water[i]])
            l = median([vals[i] for i in range(5) if not is_water[i]])
            w_all.append(w); l_all.append(l)
            diffs.append(w - l)
            if l >= 3.0:                         # ratio indéfini quand la terre est calme
                ratios.append(w / l)
    if not ranges:
        return None
    r = {
        "heures": len(ranges), "mailles_distinctes": cells, "groupe_maille": groupe,
        "opposable": opposable,
        "vent_moyen_centre_kn": round(sum(centre) / len(centre), 2),
        "etendue_mediane_kn": round(median(ranges), 3),
        "etendue_p90_kn": round(pct(ranges, 0.90), 3),
        "etendue_max_kn": round(max(ranges), 3),
        "etendue_mediane_ventee_kn": round(median(ranges_windy), 3) if ranges_windy else None,
        "heures_ventees": len(ranges_windy),
    }
    if mixed and diffs:
        wm, lm = sum(w_all) / len(w_all), sum(l_all) / len(l_all)
        r.update({
            "eau_moy_kn": round(wm, 2), "terre_moy_kn": round(lm, 2),
            "ecart_eau_terre_kn": round(sum(diffs) / len(diffs), 3),
            "ratio_eau_terre": round(wm / lm, 3) if lm > 0 else None,
            "ratio_horaire_median": round(median(ratios), 3) if ratios else None,
        })
    return r


def analyse(name, zone, resp):
    if not resp or len(resp) < 5:
        return None
    elevs = [loc.get("elevation") for loc in resp]
    if any(e is None for e in elevs):
        return None
    # EAU = élévation 0 au MNT 90 m. Proxy vérifié : indépendant du modèle demandé.
    is_water = [e <= 0.0 for e in elevs]
    n = min(len(series_of(resp[0], m) or []) for m in MODELS if series_of(resp[0], m))

    per_model = {}
    for m in MODELS:
        st = stats_for_model([series_of(loc, m) for loc in resp], is_water, n)
        if st:
            per_model[m] = st
    if not per_model:
        return None
    effectif = next(m for m in MODELS if m in per_model)   # = WindEnsemble.modelPriority
    return {
        "spot": name, "zone": zone,
        "elevations": elevs, "eau": sum(is_water), "terre": 5 - sum(is_water),
        "mixte": 0 < sum(is_water) < 5,
        "elev_etendue_m": round(max(elevs) - min(elevs), 1),
        "modele_effectif": effectif,
        "modeles": per_model,
    }


def main():
    rows = []
    print(f"=== croix {NEIGHBOURHOOD_KM} km, past_days={PAST_DAYS}, {len(SPOTS)} spots ===",
          flush=True)
    for (name, lat, lon, zone) in SPOTS:
        r = analyse(name, zone, fetch(lat, lon))
        if not r:
            print(f"  {name:26s} - pas de donnee", flush=True)
            time.sleep(2.5)
            continue
        rows.append(r)
        e = r["modeles"][r["modele_effectif"]]
        tag = "MIXTE" if r["mixte"] else ("tout eau" if r["eau"] == 5 else "tout terre")
        ec = e.get("ecart_eau_terre_kn")
        print(f"  {name:26s} {tag:9s} elev{[int(x) for x in r['elevations']]} "
              f"| {r['modele_effectif'][:12]:12s} mailles={e['mailles_distinctes']} "
              f"etendue med {e['etendue_mediane_kn']:5.2f} p90 {e['etendue_p90_kn']:5.2f} "
              f"max {e['etendue_max_kn']:5.2f}"
              + (f" ecart {ec:+.2f}" if ec is not None else ""), flush=True)
        time.sleep(2.5)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       f"resultats_rugosite_monde_{int(NEIGHBOURHOOD_KM)}km.json")
    with open(out, "w") as f:
        json.dump(rows, f, indent=1, ensure_ascii=False)
    print(f"-> {out} ({len(rows)} spots)", flush=True)


if __name__ == "__main__":
    main()

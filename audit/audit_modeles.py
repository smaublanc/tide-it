# AUDIT : quel modele de vent decrit le mieux le littoral francais ?
#
# Methode : 7 jours d'observations HORAIRES reelles sur 17 stations cotieres, confrontees a ce
# que chaque modele donne au MEME point et a la MEME heure. On en tire, par modele, le biais
# (sur/sous-estimation systematique) et la RMSE (erreur typique). Les poids se deduisent de la
# RMSE : un modele deux fois moins precis pese deux fois moins.
import json, subprocess, math, io, sys

STATIONS = json.load(open("stations.json"))
STATIONS = [s for s in STATIONS if s[0] != "LFOB"]   # Beauvais : 60 km dans les terres

MODELS = ["meteofrance_seamless", "meteofrance_arome_france_hd",
          "icon_seamless", "gfs_seamless", "ecmwf_ifs025", "best_match"]

Y1, M1, D1, Y2, M2, D2 = 2026, 8, 2, 2026, 8, 9


def curl(url, timeout=60):
    r = subprocess.run(["curl", "-s", "-m", str(timeout), url], capture_output=True, text=True)
    return r.stdout


def observations(icao):
    """Vent moyen mesure, en km/h, indexe par 'YYYY-MM-DDTHH'."""
    u = (f"https://mesonet.agron.iastate.edu/cgi-bin/request/asos.py?station={icao}"
         f"&data=sknt&year1={Y1}&month1={M1}&day1={D1}&year2={Y2}&month2={M2}&day2={D2}"
         "&tz=Etc%2FUTC&format=onlycomma&latlon=no&missing=M&trace=T&direct=no&report_type=3")
    out, obs = curl(u), {}
    for line in out.splitlines()[1:]:
        p = line.split(",")
        if len(p) < 3 or p[2] in ("M", ""):
            continue
        try:
            obs[p[1][:13].replace(" ", "T")] = float(p[2]) * 1.852   # noeuds -> km/h
        except ValueError:
            pass
    return obs


def modele(lat, lon, name):
    """Vent prevu par un modele, en km/h, indexe par 'YYYY-MM-DDTHH' (UTC)."""
    u = (f"https://api.open-meteo.com/v1/forecast?latitude={lat:.4f}&longitude={lon:.4f}"
         f"&hourly=wind_speed_10m&models={name}&wind_speed_unit=kmh"
         "&timezone=UTC&past_days=7&forecast_days=1")
    try:
        h = json.loads(curl(u))["hourly"]
    except Exception:
        return {}
    key = "wind_speed_10m"
    if key not in h:
        key = next((k for k in h if k.startswith("wind_speed")), None)
        if key is None:
            return {}
    return {t[:13]: v for t, v in zip(h["time"], h[key]) if v is not None}


stats = {m: {"n": 0, "sum_err": 0.0, "sum_sq": 0.0, "sum_abs": 0.0} for m in MODELS}
par_station = {}

for icao, nom, lat, lon in STATIONS:
    obs = observations(icao)
    if len(obs) < 50:
        print(f"  {nom:14} observations insuffisantes ({len(obs)}) — ignoree", file=sys.stderr)
        continue
    ligne = {}
    for m in MODELS:
        pred = modele(lat, lon, m)
        pairs = [(obs[k], pred[k]) for k in obs if k in pred]
        if len(pairs) < 40:
            continue
        errs = [p - o for o, p in pairs]                       # >0 = le modele SURESTIME
        biais = sum(errs) / len(errs)
        rmse = math.sqrt(sum(e * e for e in errs) / len(errs))
        ligne[m] = (biais, rmse, len(pairs))
        st = stats[m]
        st["n"] += len(pairs)
        st["sum_err"] += sum(errs)
        st["sum_sq"] += sum(e * e for e in errs)
        st["sum_abs"] += sum(abs(e) for e in errs)
    par_station[nom] = ligne
    r = "  ".join(f"{m.split('_')[0][:6]}:{v[1]:4.1f}" for m, v in ligne.items())
    print(f"  {nom:14} {r}", file=sys.stderr)

print("\n" + "=" * 78)
print("BILAN GLOBAL — 17 stations cotieres, 7 jours, vent horaire mesure vs prevu")
print("=" * 78)
print(f"{'modele':30} {'biais':>8} {'RMSE':>8} {'MAE':>8} {'points':>8}")
res = {}
for m in MODELS:
    st = stats[m]
    if st["n"] == 0:
        print(f"{m:30} {'—':>8}")
        continue
    biais = st["sum_err"] / st["n"]
    rmse = math.sqrt(st["sum_sq"] / st["n"])
    mae = st["sum_abs"] / st["n"]
    res[m] = rmse
    print(f"{m:30} {biais:+8.2f} {rmse:8.2f} {mae:8.2f} {st['n']:8d}")

if res:
    print("\nPOIDS deduits (inversement proportionnels au CARRE de la RMSE, normalises) :")
    inv = {m: 1.0 / (v * v) for m, v in res.items()}
    tot = sum(inv.values())
    for m, v in sorted(inv.items(), key=lambda kv: -kv[1]):
        print(f"   {m:30} {v / tot * 100:5.1f} %   (RMSE {res[m]:.2f} km/h)")

json.dump(par_station, io.open("audit_par_station.json", "w", encoding="utf-8"),
          ensure_ascii=False, indent=1)

# AUDIT 2 : quelle COMBINAISON de modeles minimise reellement l'erreur ?
#
# L'audit 1 a donne l'erreur de chaque modele pris seul. Il ne dit PAS si une combinaison ferait
# mieux : des poids deduits des RMSE supposent des erreurs independantes, ce qui est faux (AROME
# HD et meteofrance_seamless sont la meme famille). On mesure donc les combinaisons pour de vrai,
# sur les memes 2800 heures observees.
import json, subprocess, math, itertools, io

STATIONS = [s for s in json.load(open("stations.json")) if s[0] != "LFOB"]
MODELS = ["meteofrance_seamless", "meteofrance_arome_france_hd", "icon_seamless", "gfs_seamless"]
Y1, M1, D1, Y2, M2, D2 = 2026, 8, 2, 2026, 8, 9


def curl(u, t=60):
    return subprocess.run(["curl", "-s", "-m", str(t), u], capture_output=True, text=True).stdout


def observations(icao):
    u = (f"https://mesonet.agron.iastate.edu/cgi-bin/request/asos.py?station={icao}"
         f"&data=sknt&year1={Y1}&month1={M1}&day1={D1}&year2={Y2}&month2={M2}&day2={D2}"
         "&tz=Etc%2FUTC&format=onlycomma&latlon=no&missing=M&trace=T&direct=no&report_type=3")
    obs = {}
    for line in curl(u).splitlines()[1:]:
        p = line.split(",")
        if len(p) >= 3 and p[2] not in ("M", ""):
            try: obs[p[1][:13].replace(" ", "T")] = float(p[2]) * 1.852
            except ValueError: pass
    return obs


def modele(lat, lon, name):
    u = (f"https://api.open-meteo.com/v1/forecast?latitude={lat:.4f}&longitude={lon:.4f}"
         f"&hourly=wind_speed_10m&models={name}&wind_speed_unit=kmh"
         "&timezone=UTC&past_days=7&forecast_days=1")
    try: h = json.loads(curl(u))["hourly"]
    except Exception: return {}
    k = "wind_speed_10m" if "wind_speed_10m" in h else next((x for x in h if x.startswith("wind_speed")), None)
    return {} if k is None else {t[:13]: v for t, v in zip(h["time"], h[k]) if v is not None}


# ── Collecte : une ligne par heure ou TOUS les modeles ET l'observation existent ──
rows = []   # (obs, [m0, m1, m2, m3])
for icao, nom, lat, lon in STATIONS:
    obs = observations(icao)
    preds = {m: modele(lat, lon, m) for m in MODELS}
    for k, o in obs.items():
        vals = [preds[m].get(k) for m in MODELS]
        if all(v is not None for v in vals):
            rows.append((o, vals))
print(f"{len(rows)} heures ou les 4 modeles ET la mesure sont disponibles\n")


def rmse(weights, debias=None):
    """RMSE d'une combinaison ponderee. `debias` = biais a retirer par modele."""
    s = 0.0
    for o, v in rows:
        p = sum(w * (x - (debias[i] if debias else 0)) for i, (w, x) in enumerate(zip(weights, v)))
        s += (p - o) ** 2
    return math.sqrt(s / len(rows))


# biais moyen de chaque modele (pour tester la variante « recalee »)
bias = [sum(v[i] - o for o, v in rows) / len(rows) for i in range(len(MODELS))]
print("Biais moyen par modele (km/h, >0 = surestime) :")
for m, b in zip(MODELS, bias):
    print(f"   {m:30} {b:+6.2f}")

print("\n" + "=" * 74)
print("RMSE DES COMBINAISONS (km/h — plus bas = meilleur)")
print("=" * 74)

cands = {
    "MF seul (implementation actuelle)":        [1, 0, 0, 0],
    "AROME HD seul":                            [0, 1, 0, 0],
    "ICON seul":                                [0, 0, 1, 0],
    "GFS seul":                                 [0, 0, 0, 1],
    "ancienne moyenne 0.50/0.30/0.20":          [0.5, 0, 0.3, 0.2],
    "MF .70 / ICON .20 / GFS .10":              [0.7, 0, 0.2, 0.1],
    "MF .80 / ICON .10 / GFS .10":              [0.8, 0, 0.1, 0.1],
    "MF .85 / ICON .075 / GFS .075":            [0.85, 0, 0.075, 0.075],
    "MF .90 / ICON .05 / GFS .05":              [0.9, 0, 0.05, 0.05],
    "MF .60 / AROME .40":                       [0.6, 0.4, 0, 0],
    "MF .70 / AROME .15 / ICON .075 / GFS .075":[0.7, 0.15, 0.075, 0.075],
    "poids inverse-RMSE2 de l'audit 1":         [0.42, 0.28, 0.18, 0.12],
}
best = None
for nom, w in cands.items():
    tot = sum(w); w = [x / tot for x in w]
    r = rmse(w)
    if best is None or r < best[1]: best = (nom, r, w)
    print(f"  {nom:44} {r:5.2f}")

# ── Recherche du meilleur jeu de poids par balayage (pas de 5 %) ──
print("\nBalayage exhaustif (pas 5 %, 4 modeles) ...")
grid, bw, br = [x / 20 for x in range(21)], None, 1e9
for a in grid:
    for b in grid:
        if a + b > 1: continue
        for c in grid:
            d = 1 - a - b - c
            if d < -1e-9 or d > 1: continue
            r = rmse([a, b, c, max(0.0, d)])
            if r < br: br, bw = r, [a, b, c, max(0.0, d)]
print(f"  OPTIMUM : {br:.2f} km/h")
for m, w in zip(MODELS, bw):
    print(f"     {m:30} {w * 100:5.1f} %")

# ── Meme optimum, mais en retirant d'abord le biais de chaque modele ──
br2, bw2 = 1e9, None
for a in grid:
    for b in grid:
        if a + b > 1: continue
        for c in grid:
            d = 1 - a - b - c
            if d < -1e-9 or d > 1: continue
            r = rmse([a, b, c, max(0.0, d)], debias=bias)
            if r < br2: br2, bw2 = r, [a, b, c, max(0.0, d)]
print(f"\n  OPTIMUM avec biais retire : {br2:.2f} km/h")
for m, w, b in zip(MODELS, bw2, bias):
    print(f"     {m:30} {w * 100:5.1f} %   (biais {b:+.2f})")

json.dump({"rows": len(rows), "bias": dict(zip(MODELS, bias)),
           "best_plain": {"rmse": br, "weights": dict(zip(MODELS, bw))},
           "best_debiased": {"rmse": br2, "weights": dict(zip(MODELS, bw2))}},
          io.open("audit_poids.json", "w"), indent=1)

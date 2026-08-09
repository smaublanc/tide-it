# AUDIT 3 : les poids tiennent-ils hors de l'echantillon qui les a produits ?
#
# Des poids optimises sur 17 stations peuvent n'etre bons QUE sur ces 17 stations. On les
# recalcule donc sur une moitie du reseau et on les evalue sur l'autre — puis l'inverse.
# Si le gain survit a ce test, il est reel ; sinon c'est du surajustement et il faut s'abstenir.
import json, subprocess, math, io, random

STATIONS = [s for s in json.load(open("stations.json")) if s[0] != "LFOB"]
MODELS = ["meteofrance_seamless", "meteofrance_arome_france_hd", "icon_seamless", "gfs_seamless"]
Y1, M1, D1, Y2, M2, D2 = 2026, 8, 2, 2026, 8, 9


def curl(u, t=60):
    return subprocess.run(["curl", "-s", "-m", str(t), u], capture_output=True, text=True).stdout


def observations(icao):
    u = (f"https://mesonet.agron.iastate.edu/cgi-bin/request/asos.py?station={icao}"
         f"&data=sknt&year1={Y1}&month1={M1}&day1={D1}&year2={Y2}&month2={M2}&day2={D2}"
         "&tz=Etc%2FUTC&format=onlycomma&latlon=no&missing=M&trace=T&direct=no&report_type=3")
    o = {}
    for line in curl(u).splitlines()[1:]:
        p = line.split(",")
        if len(p) >= 3 and p[2] not in ("M", ""):
            try: o[p[1][:13].replace(" ", "T")] = float(p[2]) * 1.852
            except ValueError: pass
    return o


def modele(lat, lon, name):
    u = (f"https://api.open-meteo.com/v1/forecast?latitude={lat:.4f}&longitude={lon:.4f}"
         f"&hourly=wind_speed_10m&models={name}&wind_speed_unit=kmh"
         "&timezone=UTC&past_days=7&forecast_days=1")
    try: h = json.loads(curl(u))["hourly"]
    except Exception: return {}
    k = "wind_speed_10m" if "wind_speed_10m" in h else next((x for x in h if x.startswith("wind_speed")), None)
    return {} if k is None else {t[:13]: v for t, v in zip(h["time"], h[k]) if v is not None}


par_station = {}
for icao, nom, lat, lon in STATIONS:
    obs = observations(icao)
    preds = {m: modele(lat, lon, m) for m in MODELS}
    rows = []
    for k, o in obs.items():
        v = [preds[m].get(k) for m in MODELS]
        if all(x is not None for x in v):
            rows.append((o, v))
    if len(rows) >= 40:
        par_station[nom] = rows
print(f"{len(par_station)} stations exploitables\n")


def rmse(rows, w):
    s = sum((sum(a * b for a, b in zip(w, v)) - o) ** 2 for o, v in rows)
    return math.sqrt(s / len(rows))


GRID = [x / 20 for x in range(21)]


def optimise(rows):
    br, bw = 1e9, None
    for a in GRID:
        for b in GRID:
            if a + b > 1: continue
            for c in GRID:
                d = 1 - a - b - c
                if d < -1e-9 or d > 1: continue
                r = rmse(rows, [a, b, c, max(0.0, d)])
                if r < br: br, bw = r, [a, b, c, max(0.0, d)]
    return bw, br


noms = sorted(par_station)
print("=" * 72)
print("VALIDATION CROISEE — poids appris sur une moitie, testes sur l'autre")
print("=" * 72)

MF_ONLY = [1, 0, 0, 0]
gains = []
random.seed(7)
for essai in range(6):
    ordre = noms[:]; random.shuffle(ordre)
    A, B = ordre[:len(ordre) // 2], ordre[len(ordre) // 2:]
    for train, test, lbl in ((A, B, "A→B"), (B, A, "B→A")):
        rt = [r for n in train for r in par_station[n]]
        re_ = [r for n in test for r in par_station[n]]
        w, _ = optimise(rt)
        r_w, r_mf = rmse(re_, w), rmse(re_, MF_ONLY)
        gains.append(r_mf - r_w)
        if essai == 0:
            ws = " ".join(f"{x:.2f}" for x in w)
            print(f"  {lbl}  poids appris [{ws}]   test : melange {r_w:.2f} vs MF seul {r_mf:.2f}"
                  f"   gain {r_mf - r_w:+.2f}")

m = sum(gains) / len(gains)
sd = math.sqrt(sum((g - m) ** 2 for g in gains) / len(gains))
print(f"\n  Sur {len(gains)} decoupages : gain moyen {m:+.3f} km/h (ecart-type {sd:.3f})")
print(f"  Gain minimum observe {min(gains):+.3f}  /  maximum {max(gains):+.3f}")

# poids finaux : optimises sur TOUT, arrondis a un pas lisible
wfull, rfull = optimise([r for n in noms for r in par_station[n]])
print(f"\n  Poids sur l'ensemble : {[round(x,2) for x in wfull]}  → RMSE {rfull:.2f}")
print(f"  MF seul sur l'ensemble : RMSE {rmse([r for n in noms for r in par_station[n]], MF_ONLY):.2f}")

json.dump({"gain_moyen": m, "ecart_type": sd, "min": min(gains), "max": max(gains),
           "poids": dict(zip(MODELS, wfull))}, io.open("audit_valid.json", "w"), indent=1)

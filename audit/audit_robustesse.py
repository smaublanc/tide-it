# BACKTEST : un échantillonnage par VOISINAGE est-il plus juste ET plus robuste
# qu'un point unique ?
#
# LE DÉFAUT À CORRIGER — près d'une côte, la maille du modèle est classée TERRE ou MER, et le
# vent saute d'un facteur 2 entre deux mailles voisines. Un spot dont la coordonnée tombe du
# mauvais côté lit le vent de la forêt. Mesuré à Lacanau : 9,3 nds au point, 18,1 à 1,5 km.
#
# DEUX MÉTRIQUES, et il faut les deux :
#   1. JUSTESSE  — RMSE contre le vent réellement mesuré (17 stations METAR).
#   2. ROBUSTESSE — de combien la valeur bouge quand la coordonnée bouge de ±1 km.
#      C'est ELLE le vrai bug : une app ne peut pas donner deux réponses pour le même spot
#      selon qu'on l'a pointé 500 m plus à l'est.
#
# Open-Meteo accepte plusieurs coordonnées par requête (latitude=a,b,c) → un seul appel par
# station pour les 9 points du voisinage.
import json, subprocess, math, io, statistics

STATIONS = [s for s in json.load(open("stations.json")) if s[0] != "LFOB"]
MODEL = "meteofrance_seamless"
Y1, M1, D1, Y2, M2, D2 = 2026, 8, 2, 2026, 8, 10


def curl(u, t=90):
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


def ring(lat, lon, km):
    """Le point + 8 voisins sur un cercle de rayon `km`."""
    pts = [(lat, lon)]
    for b in range(0, 360, 45):
        r = math.radians(b)
        pts.append((lat + km / 111.0 * math.cos(r),
                    lon + km / (111.0 * max(0.1, math.cos(math.radians(lat)))) * math.sin(r)))
    return pts


def series_multi(pts):
    """Une requête pour N points → liste de dict {heure: vent km/h}."""
    la = ",".join(f"{p[0]:.4f}" for p in pts)
    lo = ",".join(f"{p[1]:.4f}" for p in pts)
    u = (f"https://api.open-meteo.com/v1/forecast?latitude={la}&longitude={lo}"
         f"&hourly=wind_speed_10m&models={MODEL}&wind_speed_unit=kmh"
         "&timezone=UTC&past_days=8&forecast_days=1")
    try:
        d = json.loads(curl(u))
    except Exception:
        return []
    if isinstance(d, dict):
        d = [d]
    out = []
    for item in d:
        h = item.get("hourly") or {}
        k = "wind_speed_10m" if "wind_speed_10m" in h else next(
            (x for x in h if x.startswith("wind_speed")), None)
        out.append({} if k is None else
                   {t[:13]: v for t, v in zip(h["time"], h[k]) if v is not None})
    return out


RAYON_KM = 2.0
rows = []          # (obs, point, moyenne_voisinage, mediane_voisinage, etendue)
par_station = {}

for icao, nom, lat, lon in STATIONS:
    obs = observations(icao)
    if len(obs) < 50:
        continue
    pts = ring(lat, lon, RAYON_KM)
    ser = series_multi(pts)
    if len(ser) < len(pts):
        print(f"  {nom:14} réponse incomplète ({len(ser)}/{len(pts)}) — ignorée")
        continue
    loc = []
    for k, o in obs.items():
        vals = [s.get(k) for s in ser]
        if any(v is None for v in vals):
            continue
        pt = vals[0]
        voisins = vals                      # le point + les 8 voisins
        loc.append((o, pt, sum(voisins) / len(voisins), statistics.median(voisins),
                    max(voisins) - min(voisins)))
    if len(loc) >= 40:
        par_station[nom] = loc
        rows += loc

print(f"\n{len(rows)} heures × {len(par_station)} stations\n")


def rmse(idx):
    return math.sqrt(sum((r[idx] - r[0]) ** 2 for r in rows) / len(rows))


def biais(idx):
    return sum(r[idx] - r[0] for r in rows) / len(rows)


print("=" * 74)
print("1) JUSTESSE — RMSE contre le vent RÉELLEMENT mesuré (km/h)")
print("=" * 74)
for nom, i in (("point unique (implémentation actuelle)", 1),
               (f"moyenne du voisinage {RAYON_KM:.0f} km", 2),
               (f"médiane du voisinage {RAYON_KM:.0f} km", 3)):
    print(f"  {nom:44} RMSE {rmse(i):5.2f}   biais {biais(i):+5.2f}")

print()
print("=" * 74)
print(f"2) ROBUSTESSE — étendue du vent sur le voisinage de {RAYON_KM:.0f} km")
print("   (= de combien la réponse change si la coordonnée bouge)")
print("=" * 74)
et = sorted(r[4] for r in rows)
print(f"  médiane {statistics.median(et):5.2f} km/h   p90 {et[int(len(et)*0.9)]:5.2f}"
      f"   max {et[-1]:5.2f}")
print("\n  Par station (étendue médiane) — les plus instables sont les plus côtières :")
for nom, loc in sorted(par_station.items(), key=lambda kv: -statistics.median(x[4] for x in kv[1])):
    e = statistics.median(x[4] for x in loc)
    p = math.sqrt(sum((x[1] - x[0]) ** 2 for x in loc) / len(loc))
    m = math.sqrt(sum((x[2] - x[0]) ** 2 for x in loc) / len(loc))
    flag = "  ← le voisinage AIDE" if m < p - 0.3 else ("  ← il DÉGRADE" if m > p + 0.3 else "")
    print(f"    {nom:14} étendue {e:5.2f}   RMSE point {p:5.2f} → voisinage {m:5.2f}{flag}")

json.dump({"n": len(rows), "rayon_km": RAYON_KM,
           "rmse_point": rmse(1), "rmse_moyenne": rmse(2), "rmse_mediane": rmse(3),
           "biais_point": biais(1), "biais_moyenne": biais(2),
           "etendue_mediane": statistics.median(et)},
          io.open("audit_robustesse.json", "w"), indent=1)

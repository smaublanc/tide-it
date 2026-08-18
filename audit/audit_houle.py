#!/usr/bin/env python3
"""
audit_houle.py — AUDIT DE LA HOULE (18 aout 2026). Premier audit marine du depot.

VERITE TERRAIN : bouees NDBC/CDIP (gratuites, HORS quota Open-Meteo).
  liste     https://www.ndbc.noaa.gov/data/latest_obs/latest_obs.txt
  historique https://www.ndbc.noaa.gov/data/realtime2/<ID>.txt   (45 j)
  metadonnees https://www.ndbc.noaa.gov/data/stations/station_table.txt
  colonnes : WVHT = Hs (m) | DPD = periode DOMINANTE (= pic) | APD = periode MOYENNE
             MWD = direction au pic (degres, d'ou vient la houle)

MODELE : https://marine-api.open-meteo.com/v1/marine  (ce que fait fetchMarineHourly)

COUT QUOTA : 7 requetes HTTP, ~151 unites ponderees (locations x ceil(jours/7) x ceil(vars/10)).
  Toutes les coordonnees sont GROUPEES dans une seule requete par jeu de variables.
  NE PAS refaire tourner sans besoin : le quota est PARTAGE avec l'app en production.

REPRODUCTION : les 5 etapes ci-dessous, dans l'ordre. urllib echoue sur les certificats
sur ce poste -> les requetes passent par curl (cf. urlA/B/C/D.txt).
"""

import re, json, os, math
from collections import defaultdict

IDS = ["46214","46213","46215","46239","46243","46232","46222","46211",
       "51201","51202","51208","51205",
       "44025","44097","44100","41110","41113","44086",
       "41047","46042","42039","44008",
       "51209","52214","62144","62165"]

meta={}
for line in open('station_table.txt'):
    if line.startswith('#'): continue
    p=line.split('|')
    if len(p)<7: continue
    sid=p[0].strip()
    if sid not in IDS: continue
    m=re.match(r'\s*([\d.]+)\s*([NS])\s+([\d.]+)\s*([EW])', p[6])
    if not m: continue
    lat=float(m.group(1))*(1 if m.group(2)=='N' else -1)
    lon=float(m.group(3))*(1 if m.group(4)=='E' else -1)
    meta[sid]={'name':p[4].strip(),'lat':lat,'lon':lon,'owner':p[1].strip(),'type':p[2].strip()}

obs={}
for sid in IDS:
    f=f'rt2/{sid}.txt'
    if not os.path.exists(f): print("manque",sid); continue
    bins=defaultdict(list)
    for line in open(f):
        if line.startswith('#'): continue
        p=line.split()
        if len(p)<12: continue
        try:
            yy,mm,dd,hh,mi=map(int,p[0:5])
        except ValueError: continue
        def num(s):
            return None if s=='MM' else float(s)
        wvht,dpd,apd,mwd=num(p[8]),num(p[9]),num(p[10]),num(p[11])
        if wvht is None: continue
        # bin sur l'heure la plus proche (UTC)
        import datetime as dt
        t=dt.datetime(yy,mm,dd,hh,mi,tzinfo=dt.timezone.utc)
        t=(t+dt.timedelta(minutes=30)).replace(minute=0,second=0,microsecond=0)
        bins[t.strftime('%Y-%m-%dT%H:00')].append((wvht,dpd,apd,mwd))
    series={}
    for k,v in bins.items():
        def avg(i):
            xs=[x[i] for x in v if x[i] is not None]
            return sum(xs)/len(xs) if xs else None
        def avgdir(i):
            xs=[x[i] for x in v if x[i] is not None]
            if not xs: return None
            sx=sum(math.sin(math.radians(a)) for a in xs); cx=sum(math.cos(math.radians(a)) for a in xs)
            return math.degrees(math.atan2(sx,cx))%360
        series[k]={'wvht':avg(0),'dpd':avg(1),'apd':avg(2),'mwd':avgdir(3)}
    obs[sid]=series
    m=meta.get(sid,{})
    hh=[s['wvht'] for s in series.values()]
    print(f"{sid} {m.get('lat',0):8.3f} {m.get('lon',0):9.3f} h={len(series):5d}  Hs med={sorted(hh)[len(hh)//2]:.2f} max={max(hh):.2f}  DPD={sum(1 for s in series.values() if s['dpd'])} MWD={sum(1 for s in series.values() if s['mwd'])}  {m.get('name','?')[:42]}")
json.dump({'meta':meta,'obs':obs}, open('ndbc.json','w'))
print("total heures:", sum(len(v) for v in obs.values()))
import json, math, statistics as st
import numpy as np

d=json.load(open('ndbc.json')); meta=d['meta']; obs=d['obs']
ids=json.load(open('ids.json'))
A=json.load(open('om_default.json'))

def zone(sid):
    la,lo=meta[sid]['lat'],meta[sid]['lon']
    if lo>0 and la>50: return "Mer du Nord (EU)"
    if 17<la<30 and -180<lo<-150: return "Hawaii"
    if la<0: return "Samoa (hem. Sud)"
    if lo>100: return "Micronesie"
    if -130<lo<-110: return "Pacifique US"
    if -98<lo<-84: return "Golfe du Mexique"
    return "Atlantique US"

rows=[]   # (sid, time, obs..., mod...)
for k,sid in enumerate(ids):
    h=A[k]['hourly']; T=h['time']
    idx={t:i for i,t in enumerate(T)}
    for t,o in obs[sid].items():
        i=idx.get(t)
        if i is None: continue
        def g(name):
            v=h.get(name)
            return v[i] if v and v[i] is not None else None
        rows.append(dict(sid=sid, t=t, zone=zone(sid),
            o_h=o['wvht'], o_dpd=o['dpd'], o_apd=o['apd'], o_mwd=o['mwd'],
            m_h=g('wave_height'), m_tm=g('wave_period'), m_tp=g('wave_peak_period'),
            m_dir=g('wave_direction'),
            m_sw_h=g('swell_wave_height'), m_sw_tm=g('swell_wave_period'),
            m_sw_tp=g('swell_wave_peak_period'), m_sw_dir=g('swell_wave_direction'),
            m_ww_h=g('wind_wave_height')))
print("couples appariés:", len(rows))

def stats(pairs):
    if len(pairs)<3: return None
    e=np.array([m-o for o,m in pairs]); o=np.array([o for o,m in pairs])
    return dict(n=len(pairs), biais=e.mean(), rmse=float(np.sqrt((e**2).mean())),
                mae=float(np.abs(e).mean()), obs_moy=o.mean(),
                rel=float(np.abs(e).mean()/o.mean()*100),
                r=float(np.corrcoef([m for _,m in pairs],[o for o,_ in pairs])[0,1]))

def show(title, pairs, unit=""):
    s=stats(pairs)
    if not s: print(f"{title}: n<3"); return
    print(f"{title:44s} n={s['n']:5d} biais={s['biais']:+6.3f} RMSE={s['rmse']:5.3f} MAE={s['mae']:5.3f} moy_obs={s['obs_moy']:5.2f} err_rel={s['rel']:5.1f}% r={s['r']:.3f} {unit}")
    return s

print("\n=== HAUTEUR SIGNIFICATIVE (m) — modèle par défaut (best_match) ===")
P=[(r['o_h'],r['m_h']) for r in rows if r['o_h'] is not None and r['m_h'] is not None]
glob_h=show("global", P)
print("\npar zone:")
for z in sorted(set(r['zone'] for r in rows)):
    show("  "+z, [(r['o_h'],r['m_h']) for r in rows if r['zone']==z and r['o_h'] and r['m_h'] is not None])
print("\npar bouée:")
for sid in ids:
    s=show(f"  {sid} {meta[sid]['name'][:32]}", [(r['o_h'],r['m_h']) for r in rows if r['sid']==sid and r['o_h'] and r['m_h'] is not None])

print("\n=== PÉRIODE (s) — quelle référence pour quelle variable ===")
for lab,ok,mk in [("wave_period vs DPD (pic obs)","o_dpd","m_tm"),
                  ("wave_period vs APD (moy. obs)","o_apd","m_tm"),
                  ("wave_peak_period vs DPD","o_dpd","m_tp"),
                  ("wave_peak_period vs APD","o_apd","m_tp"),
                  ("swell_wave_period vs DPD","o_dpd","m_sw_tm"),
                  ("swell_peak_period vs DPD","o_dpd","m_sw_tp")]:
    show(lab, [(r[ok],r[mk]) for r in rows if r.get(ok) and r.get(mk)])

def angdiff(a,b):
    return (b-a+180)%360-180
print("\n=== DIRECTION (°) — wave_direction vs MWD ===")
for lab,mk in [("wave_direction","m_dir"),("swell_wave_direction","m_sw_dir")]:
    ds=[angdiff(r['o_mwd'],r[mk]) for r in rows if r['o_mwd'] is not None and r.get(mk) is not None]
    if not ds: continue
    a=np.array(ds)
    print(f"{lab:28s} n={len(a):5d} biais={a.mean():+6.1f}° RMSE={np.sqrt((a**2).mean()):5.1f}° MAE={np.abs(a).mean():5.1f}° médiane|err|={np.median(np.abs(a)):5.1f}°  <=22.5°:{(np.abs(a)<=22.5).mean()*100:4.1f}%  <=45°:{(np.abs(a)<=45).mean()*100:4.1f}%")
    for z in sorted(set(r['zone'] for r in rows)):
        b=np.array([angdiff(r['o_mwd'],r[mk]) for r in rows if r['zone']==z and r['o_mwd'] is not None and r.get(mk) is not None])
        if len(b)>3: print(f"     {z:20s} n={len(b):5d} biais={b.mean():+6.1f}° MAE={np.abs(b).mean():5.1f}° médiane={np.median(np.abs(b)):5.1f}°")

print("\n=== ERREUR DE HAUTEUR PAR TRANCHE (conditionné sur le MODÈLE, cf. piège CLAUDE.md) ===")
for lo,hi in [(0,0.5),(0.5,1),(1,1.5),(1.5,2),(2,3),(3,10)]:
    P=[(r['o_h'],r['m_h']) for r in rows if r['m_h'] is not None and lo<=r['m_h']<hi and r['o_h']]
    show(f"  modèle {lo}-{hi} m", P)
print("  (contrôle) conditionné sur l'OBSERVATION :")
for lo,hi in [(0,0.5),(0.5,1),(1,1.5),(1.5,2),(2,3),(3,10)]:
    P=[(r['o_h'],r['m_h']) for r in rows if r['o_h'] is not None and lo<=r['o_h']<hi and r['m_h'] is not None]
    show(f"  obs {lo}-{hi} m", P)
json.dump(rows, open('rows.json','w'))
import json, math, numpy as np, random
ids=json.load(open('ids.json')); meta=json.load(open('ndbc.json'))['meta']; obs=json.load(open('ndbc.json'))['obs']
A=json.load(open('om_default.json')); B=json.load(open('om_models.json')); C=json.load(open('om_dir.json'))
MODELS=["meteofrance_wave","ewam","gwam","ecmwf_wam025","ncep_gfswave016"]

print("=== 1. QUEL MODÈLE best_match choisit-il ? (identité des séries wave_height) ===")
choice={}
for k,sid in enumerate(ids):
    dh=A[k]['hourly']['wave_height']; T=A[k]['hourly']['time']
    tb={t:i for i,t in enumerate(B[k]['hourly']['time'])}
    best=None
    for m in MODELS:
        s=B[k]['hourly'].get(f'wave_height_{m}')
        if not s: continue
        diffs=[abs(dh[i]-s[tb[t]]) for i,t in enumerate(T) if t in tb and dh[i] is not None and s[tb[t]] is not None]
        if not diffs: continue
        md=sum(diffs)/len(diffs)
        if best is None or md<best[1]: best=(m,md)
    choice[sid]=best
    print(f"  {sid} {meta[sid]['name'][:30]:32s} -> {best[0]:18s} (écart moyen {best[1]:.4f} m)")

rows=json.load(open('rows.json'))
key={(r['sid'],r['t']):r for r in rows}

print("\n=== 2. CLASSEMENT DES MODÈLES — hauteur significative (14 j, mêmes heures) ===")
# échantillon commun : heures où TOUS les modèles globaux répondent
def collect(varmodel, field, tset=None):
    out=[]
    for k,sid in enumerate(ids):
        h=B[k]['hourly']; T=h['time']
        s=h.get(varmodel)
        if not s: continue
        for i,t in enumerate(T):
            o=obs[sid].get(t)
            if not o or o[field] is None or s[i] is None: continue
            out.append((sid,t,o[field],s[i]))
    return out

GLOB=["meteofrance_wave","gwam","ecmwf_wam025","ncep_gfswave016"]
# intersection des heures couvertes par les 4 modèles globaux + le défaut
common=set()
first=True
for m in GLOB:
    keys={(a,b) for a,b,_,_ in collect(f'wave_height_{m}','wvht')}
    common = keys if first else common & keys
    first=False
common &= {(r['sid'],r['t']) for r in rows if r['m_h'] is not None}
print(f"  échantillon commun : {len(common)} couples heure×bouée, {len(set(s for s,_ in common))} bouées")

def eval_series(getter):
    e=[];o=[]
    for (sid,t) in common:
        v=getter(sid,t)
        if v is None: return None
        ov=obs[sid][t]['wvht']; e.append(v-ov); o.append(ov)
    e=np.array(e); o=np.array(o)
    return dict(n=len(e), biais=e.mean(), rmse=float(np.sqrt((e**2).mean())), mae=float(np.abs(e).mean()))

idx={sid:{t:i for i,t in enumerate(B[k]['hourly']['time'])} for k,sid in enumerate(ids)}
Bh={sid:B[k]['hourly'] for k,sid in enumerate(ids)}
res={}
res['best_match (DÉFAUT app)']=eval_series(lambda s,t: key[(s,t)]['m_h'])
for m in GLOB:
    res[m]=eval_series(lambda s,t,m=m: Bh[s][f'wave_height_{m}'][idx[s][t]])
# moyenne des 4 modèles (pour mémoire — la règle du dépôt l'interdit, mais on mesure)
def moy(s,t):
    v=[Bh[s][f'wave_height_{m}'][idx[s][t]] for m in GLOB]
    v=[x for x in v if x is not None]
    return sum(v)/len(v) if v else None
res['(moyenne des 4 — pour mémoire)']=moy and eval_series(moy)
for k,v in sorted(res.items(), key=lambda x:x[1]['rmse']):
    print(f"  {k:34s} n={v['n']:5d} biais={v['biais']:+6.3f} m  RMSE={v['rmse']:.3f} m  MAE={v['mae']:.3f} m")

print("\n=== 3. Bootstrap par BLOCS jour×bouée : P(modèle bat best_match) sur la hauteur ===")
blocks={}
for (sid,t) in common:
    blocks.setdefault((sid,t[:10]),[]).append((sid,t))
bl=list(blocks.values())
random.seed(7)
def rmse_of(getter, sample):
    e=[getter(s,t)-obs[s][t]['wvht'] for blk in sample for (s,t) in blk]
    return math.sqrt(sum(x*x for x in e)/len(e))
getters={'best_match':lambda s,t: key[(s,t)]['m_h']}
for m in GLOB: getters[m]=lambda s,t,m=m: Bh[s][f'wave_height_{m}'][idx[s][t]]
wins={m:0 for m in GLOB}; deltas={m:[] for m in GLOB}
NB=600
for _ in range(NB):
    samp=[bl[random.randrange(len(bl))] for _ in range(len(bl))]
    r0=rmse_of(getters['best_match'],samp)
    for m in GLOB:
        r=rmse_of(getters[m],samp)
        deltas[m].append(r0-r)
        if r<r0: wins[m]+=1
for m in GLOB:
    dd=np.array(deltas[m])
    print(f"  {m:20s} P(bat le défaut)={wins[m]/NB*100:5.1f}%   gain RMSE médian={np.median(dd):+.4f} m  IC95=[{np.percentile(dd,2.5):+.4f} ; {np.percentile(dd,97.5):+.4f}]")
print(f"  (nb de blocs jour×bouée : {len(bl)})")

print("\n=== 4. PÉRIODE : classement des modèles (vs DPD et vs APD) ===")
for field,lab in [('dpd','DPD (pic)'),('apd','APD (moyenne)')]:
    print(f"  -- référence {lab} --")
    line=[]
    for m in GLOB+['DEFAUT']:
        e=[];o=[]
        for (sid,t) in common:
            ov=obs[sid][t][field]
            v = key[(sid,t)]['m_tm'] if m=='DEFAUT' else Bh[sid][f'wave_period_{m}'][idx[sid][t]]
            if ov is None or v is None: continue
            e.append(v-ov); o.append(ov)
        e=np.array(e)
        line.append((float(np.sqrt((e**2).mean())), m, e.mean(), len(e)))
    for rmse,m,b,n in sorted(line):
        print(f"     {m:22s} n={n:5d} biais={b:+6.2f} s  RMSE={rmse:5.2f} s")

print("\n=== 5. DIRECTION : classement des modèles (7 j) ===")
Ch={sid:C[k]['hourly'] for k,sid in enumerate(ids)}
cidx={sid:{t:i for i,t in enumerate(C[k]['hourly']['time'])} for k,sid in enumerate(ids)}
def ang(a,b): return (b-a+180)%360-180
line=[]
for m in GLOB+['DEFAUT']:
    e=[]
    for sid in ids:
        for t,i in cidx[sid].items():
            o=obs[sid].get(t)
            if not o or o['mwd'] is None: continue
            if m=='DEFAUT':
                r=key.get((sid,t)); v=r['m_dir'] if r else None
            else:
                s=Ch[sid].get(f'wave_direction_{m}'); v=s[i] if s else None
            if v is None: continue
            e.append(ang(o['mwd'],v))
    if len(e)<50: continue
    e=np.array(e)
    line.append((float(np.abs(e).mean()), m, e.mean(), len(e), float(np.median(np.abs(e))), float((np.abs(e)<=22.5).mean()*100)))
for mae,m,b,n,med,p in sorted(line):
    print(f"     {m:22s} n={n:5d} biais={b:+6.1f}°  MAE={mae:5.1f}°  médiane|err|={med:5.1f}°  ±22,5°={p:4.1f}%")
json.dump({k:(v[0] if v else None) for k,v in choice.items()}, open('choice.json','w'))
import json, math, random, numpy as np
nd=json.load(open('ndbc.json')); meta=nd['meta']; obs=nd['obs']
rows=json.load(open('rows.json')); depth=json.load(open('depth.json'))
key={(r['sid'],r['t']):r for r in rows}

print("=== A. ANALYSE ≠ PRÉVISION : erreur selon l'échéance (10 bouées, 7 j) ===")
sub=json.load(open('sub.json')); P=json.load(open('om_prev.json'))
for lead in ['', '_previous_day1','_previous_day2','_previous_day3','_previous_day4']:
    e=[]
    for k,sid in enumerate(sub):
        h=P[k]['hourly']; s=h.get('wave_height'+lead)
        if not s: continue
        for i,t in enumerate(h['time']):
            o=obs[sid].get(t)
            if not o or o['wvht'] is None or s[i] is None: continue
            e.append(s[i]-o['wvht'])
    e=np.array(e)
    lab = "analyse (= ce que mesure past_days)" if lead=='' else f"prévision J-{lead[-1]}"
    print(f"  {lab:38s} n={len(e):5d} biais={e.mean():+6.3f} m  RMSE={math.sqrt((e**2).mean()):.3f} m  MAE={np.abs(e).mean():.3f} m")

print("\n=== B. ERREUR DE HAUTEUR vs PROFONDEUR (proxy « près de la côte ») ===")
buckets=[(0,30,"<30 m (petit fond, côtier)"),(30,120,"30-120 m (plateau)"),(120,600,"120-600 m"),(600,99999,">600 m (large)")]
for lo,hi,lab in buckets:
    sids=[s for s in depth if depth[s] and lo<=depth[s]<hi]
    e=[r['m_h']-r['o_h'] for r in rows if r['sid'] in sids and r['o_h'] and r['m_h'] is not None]
    o=[r['o_h'] for r in rows if r['sid'] in sids and r['o_h'] and r['m_h'] is not None]
    if len(e)<50: continue
    e=np.array(e); o=np.array(o)
    print(f"  {lab:28s} {len(sids):2d} bouées n={len(e):5d} Hs_moy={o.mean():4.2f} biais={e.mean():+6.3f} RMSE={math.sqrt((e**2).mean()):.3f} err_rel={np.abs(e).mean()/o.mean()*100:4.1f}%")

print("\n=== C. PÉRIODE : le modèle donne une période MOYENNE, la bouée un pic ===")
d=[(r['o_dpd'],r['o_apd'],r['m_tm'],r['m_sw_tm']) for r in rows if r['o_dpd'] and r['o_apd'] and r['m_tm'] and r['m_sw_tm']]
dpd=np.array([x[0] for x in d]); apd=np.array([x[1] for x in d]); tm=np.array([x[2] for x in d]); sw=np.array([x[3] for x in d])
print(f"  n={len(d)}  DPD(bouée, pic)={dpd.mean():.2f}s  APD(bouée, moyenne)={apd.mean():.2f}s")
print(f"  wave_period (app: repli)  ={tm.mean():.2f}s   ratio DPD/wave_period : médiane={np.median(dpd/tm):.3f}  p10={np.percentile(dpd/tm,10):.3f} p90={np.percentile(dpd/tm,90):.3f}")
print(f"  swell_wave_period (app)   ={sw.mean():.2f}s   ratio DPD/swell_period : médiane={np.median(dpd/sw):.3f}  p10={np.percentile(dpd/sw,10):.3f} p90={np.percentile(dpd/sw,90):.3f}")
for lab,v in [("wave_period",tm),("swell_wave_period",sw)]:
    for ref,rv in [("DPD",dpd),("APD",apd)]:
        e=v-rv
        print(f"    {lab:18s} vs {ref}: biais={e.mean():+5.2f}s RMSE={math.sqrt((e**2).mean()):.2f}s r={np.corrcoef(v,rv)[0,1]:.3f}")
# recalibration multiplicative hors échantillon (bouées apprises / bouées testées)
sids=sorted(set(r['sid'] for r in rows if r['o_dpd'] and r['m_sw_tm']))
random.seed(3); gains=[]
for _ in range(400):
    tr=set(random.sample(sids, len(sids)//2)); te=[s for s in sids if s not in tr]
    A=[(r['o_dpd'],r['m_sw_tm']) for r in rows if r['sid'] in tr and r['o_dpd'] and r['m_sw_tm']]
    k=sum(a for a,_ in A)/sum(b for _,b in A)
    B=[(r['o_dpd'],r['m_sw_tm']) for r in rows if r['sid'] in te and r['o_dpd'] and r['m_sw_tm']]
    e0=np.array([b-a for a,b in B]); e1=np.array([k*b-a for a,b in B])
    gains.append(math.sqrt((e0**2).mean())-math.sqrt((e1**2).mean()))
g=np.array(gains)
print(f"  RECALIBRAGE Tp≈k·Tm, validation croisée par bouées (400 découpages) :")
print(f"    gain RMSE hors échantillon = {g.mean():+.3f} s (σ {g.std():.3f})  P(gain>0)={100*(g>0).mean():.0f}%  IC95=[{np.percentile(g,2.5):+.3f} ; {np.percentile(g,97.5):+.3f}]")

print("\n=== D. IMPACT OPÉRATIONNEL sur le moteur surf (ramp 5→13 s, seuil 'houle organisée' 10 s) ===")
P2=[(r['o_dpd'], r['m_sw_tm'] if r['m_sw_tm'] else r['m_tm']) for r in rows if r['o_dpd'] and (r['m_sw_tm'] or r['m_tm'])]
o=np.array([a for a,_ in P2]); m=np.array([b for _,b in P2])
def ramp(x, lo=5, hi=13): return np.clip((x-lo)/(hi-lo),0,1)
print(f"  n={len(P2)}")
print(f"  heures où la BOUÉE dit >=10 s (houle organisée) : {100*(o>=10).mean():.1f}%")
print(f"  heures où l'APP dit >=10 s                      : {100*(m>=10).mean():.1f}%")
print(f"  heures 'organisées' réelles que l'app RATE      : {100*((o>=10)&(m<10)).sum()/max(1,(o>=10).sum()):.1f}%")
print(f"  heures 'organisées' annoncées à tort            : {100*((m>=10)&(o<10)).sum()/max(1,(m>=10).sum()):.1f}%")
print(f"  score de période moyen : bouée {ramp(o).mean():.3f} vs app {ramp(m).mean():.3f}  → déficit {100*(ramp(o).mean()-ramp(m).mean()):.1f} points sur 100 du facteur période")

print("\n=== E. Bootstrap par blocs jour×bouée sur les chiffres de tête (défaut) ===")
blocks={}
for r in rows:
    if r['o_h'] and r['m_h'] is not None: blocks.setdefault((r['sid'],r['t'][:10]),[]).append(r)
bl=list(blocks.values()); random.seed(11)
rm=[];bi=[]
for _ in range(800):
    s=[bl[random.randrange(len(bl))] for _ in range(len(bl))]
    e=np.array([x['m_h']-x['o_h'] for b in s for x in b])
    rm.append(math.sqrt((e**2).mean())); bi.append(e.mean())
rm=np.array(rm); bi=np.array(bi)
print(f"  hauteur : RMSE {rm.mean():.3f} m IC95=[{np.percentile(rm,2.5):.3f} ; {np.percentile(rm,97.5):.3f}]  biais {bi.mean():+.3f} IC95=[{np.percentile(bi,2.5):+.3f} ; {np.percentile(bi,97.5):+.3f}]  ({len(bl)} blocs)")
import json, math, random, numpy as np
nd=json.load(open('ndbc.json')); obs=nd['obs']; meta=nd['meta']
rows=json.load(open('rows.json')); ids=json.load(open('ids.json'))
B=json.load(open('om_models.json')); C=json.load(open('om_dir.json'))
Bh={sid:B[k]['hourly'] for k,sid in enumerate(ids)}; bidx={sid:{t:i for i,t in enumerate(B[k]['hourly']['time'])} for k,sid in enumerate(ids)}
Ch={sid:C[k]['hourly'] for k,sid in enumerate(ids)}; cidx={sid:{t:i for i,t in enumerate(C[k]['hourly']['time'])} for k,sid in enumerate(ids)}

R=[r for r in rows if r['o_dpd'] and r['m_tm'] and r['m_sw_tm'] and r['m_sw_h'] is not None and r['m_ww_h'] is not None]
print(f"n={len(R)}  (dont houle dominante : {sum(1 for r in R if r['m_sw_h']>r['m_ww_h'])})")
def ev(lab, f, sel=lambda r: True):
    e=np.array([f(r)-r['o_dpd'] for r in R if sel(r)])
    if len(e)<50: return
    print(f"   {lab:44s} n={len(e):5d} biais={e.mean():+5.2f}s RMSE={math.sqrt((e**2).mean()):.2f}s MAE={np.abs(e).mean():.2f}s")
print("\n-- candidat de période, contre DPD (le chiffre que lit un surfeur ailleurs) --")
for sel,lab in [(lambda r: True,"TOUTES heures"),(lambda r: r['m_sw_h']>r['m_ww_h'],"heures HOULE DOMINANTE")]:
    print(f"  [{lab}]")
    ev("swell_wave_period (CE QUE L'APP UTILISE)", lambda r:r['m_sw_tm'], sel)
    ev("wave_period (total, repli actuel)", lambda r:r['m_tm'], sel)
    ev("max(swell, wave)", lambda r:max(r['m_sw_tm'],r['m_tm']), sel)
    ev("ncep_gfswave016 wave_period (= pic vrai)",
       lambda r:(Bh[r['sid']].get('wave_period_ncep_gfswave016') or [None]*400)[bidx[r['sid']][r['t']]] if Bh[r['sid']].get('wave_period_ncep_gfswave016') and (Bh[r['sid']]['wave_period_ncep_gfswave016'][bidx[r['sid']][r['t']]] is not None) else float('nan'),
       lambda r: sel(r) and Bh[r['sid']].get('wave_period_ncep_gfswave016') and Bh[r['sid']]['wave_period_ncep_gfswave016'][bidx[r['sid']][r['t']]] is not None)

print("\n-- IMPACT sur le facteur période du moteur surf (ramp 5→13 s) --")
def ramp(x,lo=5,hi=13): return min(1,max(0,(x-lo)/(hi-lo)))
ref=np.array([ramp(r['o_dpd']) for r in R])
for lab,f in [("app actuelle (swell_wave_period)",lambda r:r['m_sw_tm']),("wave_period (total)",lambda r:r['m_tm'])]:
    v=np.array([ramp(f(r)) for r in R])
    o=np.array([r['o_dpd'] for r in R]); m=np.array([f(r) for r in R])
    print(f"   {lab:36s} score moy {v.mean():.3f} (bouée {ref.mean():.3f}) déficit {100*(ref.mean()-v.mean()):4.1f} pts | >=10s : app {100*(m>=10).mean():4.1f}% vs bouée {100*(o>=10).mean():4.1f}% | rate {100*((o>=10)&(m<10)).sum()/ (o>=10).sum():4.1f}% des houles organisées")
print("\n-- seuils recalibrés pour l'échelle SERVIE (méthode « seuils dédoublés » du vent) --")
for lab,f in [("swell_wave_period",lambda r:r['m_sw_tm']),("wave_period",lambda r:r['m_tm'])]:
    m=np.array([f(r) for r in R]); o=np.array([r['o_dpd'] for r in R])
    # seuils qui reproduisent les MÊMES quantiles que 5 s et 13 s sur l'échelle bouée
    q5=(o<5).mean(); q13=(o<13).mean()
    print(f"   {lab:20s} : 5 s (pic) ↔ {np.quantile(m,q5):.2f} s ; 13 s (pic) ↔ {np.quantile(m,q13):.2f} s ; 10 s (pic) ↔ {np.quantile(m,(o<10).mean()):.2f} s")

print("\n=== DIRECTION : échantillon strictement commun (7 j) ===")
def ang(a,b): return (b-a+180)%360-180
key={(r['sid'],r['t']):r for r in rows}
cands={'défaut wave_direction':lambda s,t:key[(s,t)]['m_dir'],
       'défaut swell_wave_direction':lambda s,t:key[(s,t)]['m_sw_dir'],
       'ncep_gfswave016 wave_direction':lambda s,t:(Ch[s].get('wave_direction_ncep_gfswave016') or [None]*200)[cidx[s][t]],
       'ecmwf_wam025 wave_direction':lambda s,t:(Ch[s].get('wave_direction_ecmwf_wam025') or [None]*200)[cidx[s][t]],
       'gwam wave_direction':lambda s,t:(Ch[s].get('wave_direction_gwam') or [None]*200)[cidx[s][t]]}
common=[(s,t) for s in ids for t in cidx[s] if (s,t) in key and obs[s][t]['mwd'] is not None
        and all((c(s,t) is not None) for c in cands.values())]
print(f"  n commun = {len(common)}")
out=[]
for lab,c in cands.items():
    e=np.array([ang(obs[s][t]['mwd'], c(s,t)) for s,t in common])
    out.append((float(np.abs(e).mean()), lab, e.mean(), float(np.median(np.abs(e))), float((np.abs(e)<=22.5).mean()*100)))
for mae,lab,b,med,p in sorted(out):
    print(f"   {lab:34s} biais={b:+6.1f}° MAE={mae:5.1f}° médiane|err|={med:5.1f}° ±22,5°={p:4.1f}%")

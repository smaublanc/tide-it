#!/usr/bin/env python3
"""
AUDIT DE LA MÉTÉO GÉNÉRALE — 18 août 2026
=========================================
Confronte `MarineWeatherService.fetchWeatherExtras` (température, pression, humidité,
code météo, probabilité de pluie) au réseau METAR public.

VÉRITÉ TERRAIN, GRATUITE ET SANS QUOTA : aviationweather.gov/api/data/metar
  temp/dewp (°C) · altim (QNH hPa) · wxString (temps présent) · clouds (oktas)
  Rétention ~7 jours ; un seul ICAO par requête (le paramètre `ids` multiple plafonne
  la réponse à ~400 enregistrements TOUTES stations confondues — piège vérifié).

COÛT OPEN-METEO : 5 requêtes HTTP, ~160 unités pondérées
  (locations × ceil(jours/7) × ceil(vars×modèles/10)), les 32 coordonnées groupées.

USAGE :  python3 audit_meteo.py <dossier_cache>
  Le dossier doit contenir mt_<ICAO>.json (METAR) et om_*.json (Open-Meteo).
  Les URL exactes sont reproduites dans REQUETES ci-dessous.
"""
REQUETES = {
 "om_main":      "hourly=temperature_2m,pressure_msl,weather_code,cloud_cover,relative_humidity_2m,precipitation",
 "om_models_tp": "hourly=temperature_2m,pressure_msl&models=best_match,meteofrance_seamless,icon_seamless,gfs_seamless,ecmwf_ifs025",
 "om_models_wx": "hourly=weather_code,cloud_cover&models=best_match,meteofrance_seamless,icon_seamless,gfs_seamless",
 "om_pp":        "hourly=precipitation_probability",
 "om_cc":        "hourly=cloud_cover_low,cloud_cover_high",
 "_commun":      "past_days=6&forecast_days=1&timezone=UTC (12→18 août 2026, 168 h)",
}

import json, glob, math, os, sys, random, statistics
from datetime import datetime, timezone, timedelta
from collections import defaultdict

D = os.path.dirname(os.path.abspath(__file__))
SCR = sys.argv[1] if len(sys.argv) > 1 else "."

# Côtier (< ~10 km de mer) = le régime que l'app sert vraiment ; intérieur = témoin.
COTIER = {'LFBZ','LFRB','LFRC','LFMN','LFKJ','LFOH','LEBB','LPFR','LEMG','EGHI','EIDW',
          'EHKD','EKCH','LGAV','LIEO','KSFO','KMRY','KACK','KEYW','PHNL','YSSY','NZAA',
          'FACT','SBGL','WSSS','RJTT','VTSP'}
INTERIEUR = {'LFBD','LFBT','EHDL','KSAC','KORH'}
PAIRES = [('LFBZ','LFBT'),('KSFO','KSAC'),('KACK','KORH'),('EHKD','EHDL'),('LFOH','LFBD')]
FRANCE = {'LFBZ','LFRB','LFRC','LFMN','LFKJ','LFOH','LFBD','LFBT'}
MODELES = ['meteofrance_seamless','icon_seamless','gfs_seamless','ecmwf_ifs025']

PRECIP = ('RA','DZ','SN','SG','PL','GR','GS','TS','IC','UP')
OKTA = {'SKC':0,'CLR':0,'NCD':0,'NSC':0,'CAVOK':0,'FEW':1.5,'SCT':3.5,'BKN':6.0,'OVC':8.0,'OVX':8.0}

def stats(p):
    n=len(p); e=[a-b for a,b in p]; m=sum(e)/n
    om=sum(b for _,b in p)/n; mm=sum(a for a,_ in p)/n
    so=math.sqrt(sum((b-om)**2 for _,b in p)/n); sm=math.sqrt(sum((a-mm)**2 for a,_ in p)/n)
    cov=sum((a-mm)*(b-om) for a,b in p)/n
    return dict(n=n, biais=round(m,4), rmse=round(math.sqrt(sum(x*x for x in e)/n),4),
                mae=round(sum(abs(x) for x in e)/n,4), obs_moy=round(om,3),
                cor=round(cov/(so*sm),4) if so*sm>0 else None)

def boot(blocs, f, B=600, seed=7):
    """IC95 par bootstrap sur blocs jour × station (la série horaire est autocorrélée)."""
    rnd=random.Random(seed); k=list(blocs); out=[]
    for _ in range(B):
        e=[]
        for _ in range(len(k)): e+=blocs[k[rnd.randrange(len(k))]]
        if e: out.append(f(e))
    out.sort(); return [round(out[int(.025*len(out))],3), round(out[int(.975*len(out))],3)]

def metar_precip(wx):
    if not wx: return False
    return any(any(p in t for p in PRECIP) for t in wx.split() if not t.startswith('VC'))

def metar_oktas(r):
    v=[OKTA.get((c.get('cover') or '').upper()) for c in (r.get('clouds') or [])]
    v=[x for x in v if x is not None]
    return max(v) if v else OKTA.get((r.get('cover') or '').upper())

def charge_metar():
    """(a) obs la plus proche de l'heure ronde  (b) TOUTES les obs de la fenêtre [H, H+1)."""
    proche=defaultdict(dict); fen=defaultdict(lambda: defaultdict(list))
    for f in glob.glob(os.path.join(SCR,'mt_*.json')):
        for r in json.load(open(f)):
            t=datetime.fromtimestamp(r['obsTime'],timezone.utc); i=r['icaoId']
            fen[i][t.replace(minute=0,second=0,microsecond=0)].append(r)
            h=t.replace(minute=0,second=0,microsecond=0)
            if t.minute>=35: h+=timedelta(hours=1)
            elif t.minute>25: continue
            d=abs((t-h).total_seconds()); c=proche[i].get(h)
            if c is None or d<c[0]: proche[i][h]=(d,r)
    return {i:{h:v[1] for h,v in m.items()} for i,m in proche.items()}, fen

def charge_om(nom, ids):
    d=json.load(open(os.path.join(SCR,nom))); assert len(d)==len(ids)
    return {i:{'t':[datetime.strptime(x,'%Y-%m-%dT%H:%M').replace(tzinfo=timezone.utc)
                    for x in pt['hourly']['time']],'h':pt['hourly']} for i,pt in zip(ids,d)}

def main():
    st=json.load(open(os.path.join(SCR,'stations_meteo.json'))); ids=sorted(st)
    proche,fen = charge_metar()
    M=charge_om('om_main.json',ids); MT=charge_om('om_models_tp.json',ids)
    PP=charge_om('om_pp.json',ids);  CC=charge_om('om_cc.json',ids)
    R={'requetes':REQUETES,'stations':{i:{'lat':st[i][0],'lon':st[i][1],'elev_m':st[i][2],
        'cote':i in COTIER} for i in ids}}

    # ---- 0. QUEL MODÈLE best_match SERT-IL ? (série identique = c'est lui) -------
    ident={}
    for i in ids:
        h=MT[i]['h']; bm=h['temperature_2m_best_match']; best=None
        for m in MODELES:
            s=h.get('temperature_2m_'+m) or []
            cp=[(a,b) for a,b in zip(bm,s) if a is not None and b is not None]
            if len(cp)<50: continue
            e=sum(abs(a-b) for a,b in cp)/len(cp)
            if best is None or e<best[1]: best=(m,e)
        ident[i]={'plus_proche':best[0],'ecart_moy_C':round(best[1],4),
                  'identique': best[1]<1e-9}
    R['best_match_identite']=ident

    # ---- 1. TEMPÉRATURE ---------------------------------------------------------
    def rec(var, src, tr):
        pairs=[]; bl=defaultdict(list); ps=defaultdict(list)
        for i in ids:
            s=src[i]['h'].get(var)
            if s is None: continue
            for t,v in zip(src[i]['t'],s):
                r=proche.get(i,{}).get(t)
                if v is None or r is None: continue
                o=tr(r)
                if o is None: continue
                pairs.append((v,o)); bl[(i,t.date())].append((v,o)); ps[i].append((v,o))
        return pairs,bl,ps
    p,bl,ps=rec('temperature_2m',M,lambda r:r.get('temp'))
    R['temperature']={**stats(p),
        'ic95_biais':boot(bl,lambda e:stats(e)['biais']),
        'ic95_rmse':boot(bl,lambda e:stats(e)['rmse']),
        'cotier':stats([x for i in COTIER for x in ps.get(i,[])]),
        'interieur':stats([x for i in INTERIEUR for x in ps.get(i,[])]),
        'paires_cote_interieur':[{'cote':a,'biais_cote':stats(ps[a])['biais'],
            'interieur':b,'biais_interieur':stats(ps[b])['biais'],
            'delta':round(stats(ps[a])['biais']-stats(ps[b])['biais'],3)} for a,b in PAIRES],
        'par_station':{i:stats(q) for i,q in ps.items()}}
    cyc=defaultdict(list)
    for i in ids:
        s=M[i]['h']['temperature_2m']
        for t,v in zip(M[i]['t'],s):
            r=proche.get(i,{}).get(t)
            if v is None or r is None or r.get('temp') is None: continue
            cyc[(t.hour+round(st[i][1]/15))%24].append(v-r['temp'])
    R['temperature']['biais_par_heure_solaire']={f'{h:02d}h':round(sum(v)/len(v),3)
        for h,v in sorted(cyc.items())}

    # ---- 2. PRESSION (contrôle de sanité) ---------------------------------------
    BAS={i for i in ids if (st[i][2] or 0)<=100}   # QNH ≈ MSLP seulement en plaine
    p2,bl2,ps2=rec('pressure_msl',M,lambda r:r.get('altim'))
    pb=[x for i in BAS for x in ps2.get(i,[])]
    blb={k:v for k,v in bl2.items() if k[0] in BAS}
    R['pression']={**stats(pb),'n_stations_basses':len(BAS),
        'ic95_biais':boot(blb,lambda e:stats(e)['biais']),
        'ic95_rmse':boot(blb,lambda e:stats(e)['rmse']),
        'toutes_stations':stats(p2),'par_station':{i:stats(q) for i,q in ps2.items()}}

    # ---- 3. HUMIDITÉ (dérivée du point de rosée METAR, formule Magnus) ----------
    def hr(r):
        t,d=r.get('temp'),r.get('dewp')
        if t is None or d is None: return None
        es=lambda x:6.112*math.exp(17.62*x/(243.12+x))
        return max(0.,min(100.,100*es(d)/es(t)))
    p3,bl3,_=rec('relative_humidity_2m',M,hr)
    R['humidite']={**stats(p3),'ic95_rmse':boot(bl3,lambda e:stats(e)['rmse'])}

    # ---- 4. CODE MÉTÉO / NÉBULOSITÉ / PLUIE -------------------------------------
    def cls(code, nuages):
        if code is None: return None
        if code>=51: return 'precip'
        return 'clair' if nuages else 'nuageux'
    conf=defaultdict(int); conf_b=defaultdict(int); a_t=[0,0]; a_b=[0,0]
    res={'instantane':[0,0,0,0],'fenetre_horaire':[0,0,0,0]}   # hit, miss, FA, CN
    seuils=defaultdict(lambda:[0,0,0,0]); mm_fa=[]; mm_ok=[]
    neb_tot=[]; neb_bas=[]; neb_haut=[]; par_st=defaultdict(lambda:[0,0])
    for i in ids:
        h=M[i]['h']
        for k,t in enumerate(M[i]['t']):
            code=h['weather_code'][k]; cc=h['cloud_cover'][k]; pr=h['precipitation'][k]
            lo=CC[i]['h']['cloud_cover_low'][k]; hi=CC[i]['h']['cloud_cover_high'][k]
            r=proche.get(i,{}).get(t); w=fen[i].get(t)
            if code is None: continue
            if r is not None:
                ok=metar_oktas(r)
                if ok is not None:
                    if cc is not None: neb_tot.append((cc,ok*12.5))
                    if lo is not None: neb_bas.append((lo,ok*12.5))
                    if hi is not None: neb_haut.append((hi,ok*12.5))
            # pluie : instantané vs fenêtre horaire (le code météo décrit l'HEURE)
            for mode,src in (('instantane',[r] if r else None),('fenetre_horaire',w)):
                if not src: continue
                o=any(metar_precip(x.get('wxString')) for x in src); m_=code>=51
                res[mode][0 if (o and m_) else 1 if o else 2 if m_ else 3]+=1
            if w and pr is not None:
                o=any(metar_precip(x.get('wxString')) for x in w)
                if code>=51: (mm_ok if o else mm_fa).append(pr)
                for s in (0.0,0.1,0.2,0.3,0.5,1.0):
                    m_=pr>s; k2=seuils[s]
                    k2[0 if (o and m_) else 1 if o else 2 if m_ else 3]+=1
            # accord 3 classes
            if r is None: continue
            ok=metar_oktas(r); pl=any(metar_precip(x.get('wxString')) for x in (w or []))
            if ok is None and not pl: continue
            obs='precip' if pl else ('clair' if ok<=2 else 'nuageux')
            m1=cls(code, code<=1); m2=cls(code, lo is not None and lo<25)
            a_t[0]+=1; a_t[1]+=(obs==m1); conf[(obs,m1)]+=1
            a_b[0]+=1; a_b[1]+=(obs==m2); conf_b[(obs,m2)]+=1
            par_st[i][0]+=1; par_st[i][1]+=(obs==m1)
    def sc(k):
        hit,miss,fa,cn=k
        return {'n':sum(k),'POD':round(hit/max(1,hit+miss),3),'FAR':round(fa/max(1,hit+fa),3),
                'CSI':round(hit/max(1,hit+miss+fa),3),
                'freq_obs_%':round(100*(hit+miss)/sum(k),2),'freq_modele_%':round(100*(hit+fa)/sum(k),2)}
    R['code_meteo']={'n':a_t[0],
        'accord_3_classes':round(a_t[1]/a_t[0],4),
        'accord_si_base_sur_nuages_BAS':round(a_b[1]/a_b[0],4),
        'matrice_obs_vers_modele':{f'{a}->{b}':v for (a,b),v in sorted(conf.items(),key=lambda x:-x[1])},
        'accord_par_station':{i:round(v[1]/v[0],3) for i,v in sorted(par_st.items())},
        'pluie':{m:sc(v) for m,v in res.items()},
        'pluie_si_seuil_mm':{f'>{s}mm':sc(v) for s,v in sorted(seuils.items())},
        'mm_du_modele':{'fausses_alertes':{'n':len(mm_fa),
              'mediane_mm':round(statistics.median(mm_fa),3) if mm_fa else None,
              'part_sous_0.2mm_%':round(100*sum(1 for x in mm_fa if x<0.2)/max(1,len(mm_fa)),1)},
            'vraies':{'n':len(mm_ok),'mediane_mm':round(statistics.median(mm_ok),3) if mm_ok else None,
              'part_sous_0.2mm_%':round(100*sum(1 for x in mm_ok if x<0.2)/max(1,len(mm_ok)),1)}}}
    R['nebulosite_pct']={'modele_TOTAL_vs_metar':stats(neb_tot),
        'modele_BAS_vs_metar':stats(neb_bas),'modele_HAUT_vs_metar':stats(neb_haut)}

    # ---- 5. PROBABILITÉ DE PLUIE : courbe de fiabilité --------------------------
    tr=defaultdict(lambda:[0,0])
    for i in ids:
        for t,q in zip(PP[i]['t'],PP[i]['h']['precipitation_probability']):
            w=fen[i].get(t)
            if not w or q is None: continue
            b=min(9,int(q//10)); tr[b][0]+=1
            tr[b][1]+= any(metar_precip(x.get('wxString')) for x in w)
    R['proba_pluie_fiabilite']={f'{b*10}-{b*10+9}%':{'n':v[0],'freq_observee_%':round(100*v[1]/v[0],1)}
        for b,v in sorted(tr.items())}

    # ---- 6. COMPARAISON DE MODÈLES ---------------------------------------------
    comp={}
    for var,tr2 in (('temperature_2m',lambda r:r.get('temp')),('pressure_msl',lambda r:r.get('altim'))):
        for m in ['best_match']+MODELES:
            p4,_,_=rec(var+'_'+m,MT,tr2)
            if var=='pressure_msl':
                p4=[x for i in BAS for x in rec(var+'_'+m,MT,tr2)[2].get(i,[])]
            comp.setdefault(var,{})[m]=stats(p4)
    def sousgroupe(grp,nom):
        bl5=defaultdict(lambda: defaultdict(list))
        for i in grp:
            h=MT[i]['h']
            for k,t in enumerate(MT[i]['t']):
                r=proche.get(i,{}).get(t)
                if r is None or r.get('temp') is None: continue
                for m in ['best_match']+MODELES:
                    v=h['temperature_2m_'+m][k]
                    if v is not None: bl5[(i,t.date())][m].append((v,r['temp']))
        rm=lambda q: math.sqrt(sum((a-b)**2 for a,b in q)/len(q))
        tous={m:[x for b in bl5.values() for x in b[m]] for m in ['best_match']+MODELES}
        out={'n':len(tous['best_match']),'rmse':{m:round(rm(tous[m]),3) for m in tous},
             'biais':{m:round(sum(a-b for a,b in tous[m])/len(tous[m]),3) for m in tous}}
        rnd=random.Random(11); k=list(bl5); win=defaultdict(int); dif=[]
        for _ in range(600):
            e=defaultdict(list)
            for _ in range(len(k)):
                b=bl5[k[rnd.randrange(len(k))]]
                for m in b: e[m]+=b[m]
            r_={m:rm(e[m]) for m in e}; win[min(r_,key=r_.get)]+=1
            dif.append(r_['meteofrance_seamless']-r_['best_match'])
        dif.sort()
        out['P_meilleur_%']={m:round(100*win[m]/600,1) for m in tous}
        out['ecart_rmse_MF_moins_bestmatch']={'moyenne':round(sum(dif)/len(dif),3),
            'ic95':[round(dif[15],3),round(dif[-16],3)]}
        # ce que voit l'utilisateur : le DEGRÉ ENTIER affiché (TodayView.tempInt)
        a=tous['best_match']; b=tous['meteofrance_seamless']
        out['degre_entier_different_bm_vs_MF_%']=round(100*sum(1 for (x,_),(y,_) in zip(a,b)
            if round(x)!=round(y))/len(a),1)
        out['degre_affiche_a_1C_pres_%']=round(100*sum(1 for x,o in a if abs(round(x)-round(o))<=1)/len(a),1)
        return out
    comp['FRANCE']=sousgroupe(FRANCE,'FR')
    comp['HORS_FRANCE']=sousgroupe([i for i in ids if i not in FRANCE],'monde')
    comp['MONDE']=sousgroupe(ids,'tout')
    R['comparaison_modeles']=comp

    # ---- 7. COÛT DU SCHÉMA DE REQUÊTES DE L'APP --------------------------------
    def poids(jours, nvars): return math.ceil(jours/7)*math.ceil(nvars/10)
    R['cout_schema_app']={
        'formule':'locations × ceil(jours/7) × ceil(variables×modèles/10)',
        'vent (3 vars × 3 modèles, 15 j)':poids(15,9),
        'extras (7 vars, 15 j)':poids(15,7),
        'marine (16 vars, 15 j)':poids(15,16),
        'total_par_coordonnee_non_cachee':poids(15,9)+poids(15,7)+poids(15,16),
        'si_on_retire_precipitation (extras 7→6)':poids(15,6),
        'si_on_retire_wind_wave_period (marine 16→15)':poids(15,15),
        'pan_carte_premium_zoome (cap 10 spots)':10*(poids(15,9)+poids(15,7)+poids(15,16))}

    R['couverture']={'stations':len(ids),'pays':'FR ES PT UK IE NL DK GR IT US(+HI) AU NZ ZA BR SG JP TH',
        'n_couples_temperature':R['temperature']['n'],'n_couples_pression':R['pression']['n'],
        'periode_utc':[M[ids[0]]['t'][0].isoformat(),M[ids[0]]['t'][-1].isoformat()]}
    json.dump(R,open(os.path.join(D,'resultats_meteo.json'),'w'),indent=1,ensure_ascii=False)
    print('→ resultats_meteo.json')
    return R

if __name__=='__main__': main()

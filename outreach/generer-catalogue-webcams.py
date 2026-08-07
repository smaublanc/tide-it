# Construit le catalogue embarque a partir des resultats de recherche verifies.
import io, json, re, unicodedata, os

REPO = "/Users/maublanc/Desktop/Tide It 18"
res = json.load(io.open(os.path.join(REPO, "outreach/recherche-webcams.json"), encoding="utf-8"))

cams = [it for r in res for it in (r.get("items") or []) if it.get("kind") == "webcam"]


def slug(s):
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode()
    s = re.sub(r"[^a-zA-Z0-9]+", "-", s).strip("-").lower()
    return re.sub(r"-{2,}", "-", s)[:44]


out, seen = [], set()
for c in cams:
    lat, lon, url = c.get("lat"), c.get("lon"), (c.get("pageURL") or "").strip()
    # Une webcam sans position ne peut pas etre "la plus proche", et sans page publique
    # il n'y a rien a ouvrir. Les deux sont donc obligatoires.
    if not lat or not lon or not url.startswith("http"):
        continue
    # Un 200 verifie : on n'embarque pas un lien mort.
    if not str(c.get("httpStatus", "")).strip().startswith("200"):
        continue
    ident = "cam_" + slug(c.get("name") or c.get("spot") or url)
    if ident in seen:
        continue
    seen.add(ident)
    e = {
        "id": ident,
        "name": (c.get("name") or "").strip(),
        "place": (c.get("spot") or "").strip(),
        "lat": round(float(lat), 5),
        "lon": round(float(lon), 5),
        "page": url,
    }
    if c.get("contactEmail"):
        e["operatorContact"] = c["contactEmail"]
    # embed reste absent tant qu'aucun accord ECRIT n'a ete recu : par defaut on ouvre la
    # page de l'exploitant, on ne rejoue jamais son flux.
    out.append(e)

out.sort(key=lambda e: (e["lat"], e["name"]))
doc = {
    "_lisezmoi": (
        "Catalogue des webcams du littoral. Par defaut l'app OUVRE la page de l'exploitant : "
        "un lien n'est pas une contrefacon. Le champ 'embed' n'apparait QUE sur les cameras "
        "dont l'exploitant a donne un accord ECRIT (guideline App Store 5.2 : rejouer le flux "
        "d'un tiers sans accord fait retirer l'APPLICATION, pas la fonctionnalite). "
        "Le retrait a la demande passe par docs/blocklist.json, cle 'webcams'."
    ),
    "version": 1,
    "updated": "2026-08-07",
    "webcams": out,
}

p = os.path.join(REPO, "Tide It/webcams.json")
os.makedirs(os.path.dirname(p), exist_ok=True)
io.open(p, "w", encoding="utf-8").write(json.dumps(doc, ensure_ascii=False, indent=1) + "\n")
print("%d webcams retenues (sur %d recensees)" % (len(out), len(cams)))
from collections import Counter
z = Counter(re.split(r"[—(]", e["place"])[0].strip()[:26] for e in out)
for k, v in z.most_common(12):
    print("   %-30s %d" % (k, v))

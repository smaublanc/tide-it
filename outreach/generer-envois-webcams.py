# Un courrier par EXPLOITANT (pas par camera) a partir des deux passes de recherche.
# Ouvre le .eml dans Mail, ⌘⇧D pour en faire un message envoyable, ⌘↩ pour envoyer.
import io, json, os, re, urllib.parse, unicodedata
from email.message import EmailMessage
from collections import defaultdict, Counter

REPO = "/Users/maublanc/Desktop/Tide It 18"
FROM = "tideitapp@icloud.com"
SIGN = "Sébastien"
SITE = "https://smaublanc.github.io/tide-it/"
OUT = os.path.join(REPO, "outreach/envois")

cams = []
for f in ("outreach/recherche-webcams.json", "outreach/recherche-webcams-atlantique.json"):
    fp = os.path.join(REPO, f)
    if not os.path.exists(fp):
        continue
    for r in json.load(io.open(fp, encoding="utf-8")):
        cams += [c for c in (r.get("items") or [])
                 if c.get("kind") == "webcam" and c.get("contactEmail")
                 and c.get("lat") and c.get("lon")
                 and str(c.get("httpStatus", "")).startswith("200")]

par = defaultdict(list)
for c in cams:
    par[c["contactEmail"]].append(c)


def commune(c):
    """« Leucate (11370) — plage des Coussoules » → « Leucate »."""
    s = re.split(r"[—(/]", c.get("spot", ""))[0].strip()
    return re.sub(r"\s*\d{5}\s*", "", s).strip(" -,")


def slug(s):
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode()
    return re.sub(r"-{2,}", "-", re.sub(r"[^a-zA-Z0-9]+", "-", s).strip("-").lower())[:34]


def mailto(sub, body):
    return "mailto:%s?subject=%s&body=%s" % (
        FROM, urllib.parse.quote(sub, safe=""), urllib.parse.quote(body, safe=""))


TPL = io.open(os.path.join(REPO, "outreach/modele-webcam-fr.html"), encoding="utf-8").read()
TPL = TPL[TPL.index("<div style="):]

for f in os.listdir(OUT):
    if re.match(r"^\d\d-webcam-", f):
        os.remove(os.path.join(OUT, f))

n = 0
for mail, lst in sorted(par.items(), key=lambda kv: -len(kv[1])):
    n += 1
    lieu = Counter(commune(c) for c in lst).most_common(1)[0][0] or "votre secteur"
    nb = len(lst)
    ident = "webcam_" + slug(mail.split("@")[0] + "-" + lieu)
    quoi = ("votre webcam de %s" % lieu) if nb == 1 else ("vos %d webcams de %s" % (nb, lieu))
    # Au-dela de 12 la liste devient un mur : on dit le total et on montre un echantillon.
    montrees = lst[:12]
    liste = "".join("<li style='margin:0 0 4px 0;'>%s</li>" % c.get("name", "") for c in montrees)
    if nb > len(montrees):
        liste += "<li style='margin:0 0 4px 0;color:#8b95a1;'>… et %d autre(s)</li>" % (nb - len(montrees))

    html = (TPL
            .replace("votre webcam de [LIEU]", quoi)
            .replace("[LIEU]", lieu)
            .replace("[NOM DE LA WEBCAM]", lst[0].get("name", "")[:52])
            .replace("[VOTRE-SITE.FR]", urllib.parse.urlparse(lst[0]["pageURL"]).netloc)
            .replace("[X]", "%.1f" % min(1.9, 0.4 + nb * 0.2))
            .replace("[PRÉNOM NOM]", SIGN)
            .replace("[LIEN APP STORE]", SITE)
            .replace("[ID]", ident))
    if nb > 1:
        html = html.replace(
            "Deux raisons à ce courrier.",
            "Les vues concernées :</p><ul style='margin:0 0 16px 18px;font-size:14px;"
            "line-height:1.6;color:#4a5563;'>%s</ul>"
            "<p style='margin:0 0 16px 0;font-size:16px;line-height:1.6;'>"
            "Deux raisons à ce courrier." % liste, 1)

    oui = mailto("ACCORD Tide It — %s" % ident,
                 "Bonjour,\n\nJ'autorise Tide It à afficher le flux de %s dans l'application, "
                 "avec mention de notre nom et lien vers notre site.\n\nCette autorisation est "
                 "révocable à tout moment sur simple demande de notre part.\n\nConditions "
                 "particulières (laisser vide s'il n'y en a pas) :\n\n\nCordialement,\n" % quoi)
    non = mailto("REFUS Tide It — %s" % ident,
                 "Bonjour,\n\nNous ne souhaitons pas que %s figure dans Tide It. Merci de la "
                 "retirer.\n\nCordialement,\n" % quoi)
    html = re.sub(r'href="mailto:[^"]*ACCORD[^"]*"', 'href="%s"' % oui, html, count=1)
    html = re.sub(r'href="mailto:[^"]*REFUS[^"]*"', 'href="%s"' % non, html, count=1)

    txt = re.sub(r"<[^>]+>", "", html)
    txt = re.sub(r"\n{3,}", "\n\n", txt.replace("&middot;", "·").replace("&nbsp;", " ")
                 .replace("&rsaquo;", "›")).strip()
    txt += "\n\n— Pour répondre, écrivez simplement à %s\n%s" % (FROM, SITE)

    m = EmailMessage()
    m["From"] = FROM
    m["To"] = mail
    m["Subject"] = ("Vos webcams de %s dans Tide It" % lieu) if nb > 1 \
        else ("Votre webcam de %s dans Tide It" % lieu)
    m.set_content(txt)
    m.add_alternative(html, subtype="html")
    io.open(os.path.join(OUT, "%02d-webcam-%s.eml" % (10 + n, slug(lieu + "-" + mail.split("@")[0]))),
            "w", encoding="utf-8").write(m.as_string())
    print("  %-46s %-42s %2d vue(s)" % (lieu[:44], mail, nb))

print("\n%d courriers webcams" % n)

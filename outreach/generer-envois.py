# Genere un .eml par destinataire : ouvert dans Mail, le message est pret, il ne reste
# qu'a relire et envoyer. Corps HTML (boutons mailto) + repli texte pour les clients qui
# n'affichent pas le HTML.
import io, os, re, urllib.parse
from email.message import EmailMessage

REPO = "/Users/maublanc/Desktop/Tide It 18"
OUT = os.path.join(REPO, "outreach", "envois")
FROM = "tideitapp@icloud.com"
SIGNATAIRE = "Sébastien"
APPSTORE = "https://apps.apple.com/fr/app/id6743555259"
SITE = "https://smaublanc.github.io/tide-it/"

# ordre = valeur : societes -> collectivites -> particuliers
DESTINATAIRES = [
    dict(to="contact@kitezone-school.com", ident="weameter_lachanau", kind="balise",
         type="société", nom="Kite Zone School", lieu="Lachanau / lac d'Hourtin-Carcans", court="d'Hourtin",
         station="votre station du lac d'Hourtin-Carcans", site="",
         note="DEJA AFFICHEE dans l'app depuis des mois — courrier prioritaire"),
    dict(to="chevrerie.du.cap@tiscali.fr", ident="weewx_capfrehel", kind="balise",
         type="société", nom="La Chèvrerie du Cap", lieu="Cap Fréhel", court="du Cap Fréhel",
         station="votre station météo du Cap Fréhel", site="http://www.chevrerie-du-cap.com",
         note="ajoutee ce jour"),
    dict(to="plaisance.concarneau@portsdecornouaille.fr", ident="diabox_concarneau", kind="balise",
         type="collectivité", nom="Ports de Cornouaille — plaisance Concarneau",
         lieu="Concarneau", court="Concarneau", station="la borne météo du port de plaisance", site="",
         note="PAS ENCORE integree : licence inconnue, on demande AVANT"),
    dict(to="contact@brulesecaille.com", ident="weewx_tauriac", kind="balise",
         type="société", nom="Château Brulesécaille", lieu="Tauriac, estuaire de la Gironde", court="de Tauriac",
         station="votre station météo de Tauriac", site="",
         note="hors spot de glisse — interet moindre"),
]

HTML = """<div style="margin:0;padding:0;background:#f4f6f8;">
<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="background:#f4f6f8;">
<tr><td align="center" style="padding:26px 12px;">
<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="600" style="max-width:600px;width:100%;background:#fff;border-radius:14px;border:1px solid #e2e6ea;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;color:#1c2530;">
<tr><td style="padding:30px 34px 6px 34px;">
<p style="margin:0 0 18px 0;font-size:16px;line-height:1.6;">Bonjour,</p>
<p style="margin:0 0 16px 0;font-size:16px;line-height:1.6;">Je développe <strong>Tide It</strong>, une application iOS indépendante de marées et de vent réel, utilisée surtout par des kitesurfeurs, windsurfeurs et surfeurs du littoral français.</p>
<p style="margin:0 0 16px 0;font-size:16px;line-height:1.6;">{INTRO}</p>
</td></tr>
<tr><td style="padding:6px 34px 6px 34px;">
<p style="margin:0 0 10px 0;font-size:13px;letter-spacing:.06em;text-transform:uppercase;color:#6b7785;font-weight:600;">Ce que voit l'utilisateur</p>
<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="background:#f7f9fb;border:1px solid #e2e6ea;border-radius:10px;">
<tr><td style="padding:14px 16px;font-size:15px;line-height:1.5;">
<span style="color:#1c2530;font-weight:700;font-size:19px;">24 km/h</span><span style="color:#6b7785;font-size:14px;">&nbsp;rafales 31&nbsp;&middot;&nbsp;Ouest</span><br>
<span style="color:#6b7785;font-size:13px;">{NOM} &middot; à 2,1 km &middot; il y a 3 min</span><br>
<span style="color:#0a84c8;font-size:13px;">{LIENAFF} &rsaquo;</span>
</td></tr></table>
<p style="margin:10px 0 18px 0;font-size:13px;line-height:1.5;color:#6b7785;">Votre nom sous chaque mesure, et un lien vers votre site — ouvrable d'un tap.</p>
</td></tr>
<tr><td style="padding:0 34px 6px 34px;">
<p style="margin:0 0 12px 0;font-size:16px;line-height:1.6;">Ce que ça représente concrètement :</p>
<p style="margin:0 0 12px 0;font-size:16px;line-height:1.6;">&bull;&nbsp; Une lecture <strong>toutes les trois minutes au maximum</strong>, et seulement quand quelqu'un regarde ce spot. Aucune collecte massive, aucun archivage de votre historique, aucune revente.</p>
<p style="margin:0 0 12px 0;font-size:16px;line-height:1.6;">&bull;&nbsp; <strong>L'âge de la mesure est toujours affiché</strong>, et rien ne s'affiche si la donnée manque. Je ne présente jamais une valeur ancienne ou absente comme si elle était actuelle : votre station ne dira jamais autre chose que ce qu'elle mesure.</p>
<p style="margin:0 0 16px 0;font-size:16px;line-height:1.6;">&bull;&nbsp; {RETRAIT}</p>
<p style="margin:0 0 22px 0;font-size:16px;line-height:1.6;">Pour être clair d'emblée : Tide It est une application commerciale, certaines fonctions étant accessibles par abonnement. Je préfère vous le dire plutôt que vous le laisser découvrir.</p>
</td></tr>
<tr><td style="padding:4px 34px 8px 34px;">
<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%"><tr>
<td style="padding:0 6px 10px 0;" width="50%"><a href="{OUI}" style="display:block;padding:15px 10px;background:#17994f;color:#fff;text-decoration:none;border-radius:10px;font-size:15px;font-weight:700;text-align:center;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;">Je donne mon accord</a></td>
<td style="padding:0 0 10px 6px;" width="50%"><a href="{NON}" style="display:block;padding:15px 10px;background:#fff;color:#4a5563;text-decoration:none;border:1.5px solid #ccd3da;border-radius:10px;font-size:15px;font-weight:600;text-align:center;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;">Non merci, retirez-moi</a></td>
</tr></table>
<p style="margin:2px 0 0 0;font-size:12.5px;line-height:1.5;color:#8b95a1;">Ces boutons ouvrent simplement votre messagerie avec la réponse déjà écrite : vous n'avez qu'à l'envoyer. Rien n'est transmis avant. Ce courrier ne contient aucun traceur.</p>
</td></tr>
<tr><td style="padding:20px 34px 30px 34px;border-top:1px solid #eef1f4;">
<p style="margin:16px 0 4px 0;font-size:16px;line-height:1.6;">Merci, et bravo pour la station,</p>
<p style="margin:0;font-size:16px;line-height:1.6;"><strong>{SIGN}</strong><br>
<span style="color:#6b7785;font-size:14px;">Tide It &middot; <a href="mailto:{FROM}" style="color:#0a84c8;text-decoration:none;">{FROM}</a><br>
<a href="{SITE}" style="color:#0a84c8;text-decoration:none;">{SITEAFF}</a></span></p>
</td></tr></table></td></tr></table></div>"""


def mailto(subject, body):
    return "mailto:%s?subject=%s&body=%s" % (
        FROM, urllib.parse.quote(subject, safe=""), urllib.parse.quote(body, safe=""))


os.makedirs(OUT, exist_ok=True)
for f in os.listdir(OUT):
    if f.endswith(".eml"):
        os.remove(os.path.join(OUT, f))

index = []
for i, d in enumerate(DESTINATAIRES, 1):
    deja = "PAS ENCORE" not in d["note"]
    if deja:
        intro = ("%s est l'une des rares à mesurer le vent au plus près d'un spot de glisse — "
                 "bien plus près que les stations d'aéroport sur lesquelles la plupart des "
                 "applications se rabattent. Sa mesure est affichée aux utilisateurs qui "
                 "consultent ce secteur, avec votre nom et un lien vers votre site."
                 ) % (d["station"][0].upper() + d["station"][1:])
        retrait = ("Si vous préférez ne pas y figurer, <strong>un mot suffit</strong>. Le retrait "
                   "est immédiat : votre station disparaît de tous les téléphones au lancement "
                   "suivant, sans mise à jour de l'application ni délai.")
        sujet = "Votre station %s dans Tide It" % d["court"]
        oui_body = ("Bonjour,\n\nJe donne mon accord pour que Tide It affiche les mesures de %s "
                    "(%s), avec mention de mon nom et lien vers mon site.\n\nCet accord est "
                    "révocable à tout moment sur simple demande de ma part.\n\nConditions "
                    "particulières (laisser vide s'il n'y en a pas) :\n\n\nCordialement,\n"
                    % (d["station"], d["lieu"]))
        non_body = ("Bonjour,\n\nJe ne souhaite pas que les mesures de %s (%s) figurent dans "
                    "Tide It. Merci de les retirer.\n\nCordialement,\n" % (d["station"], d["lieu"]))
    else:
        intro = ("%s mesure le vent au plus près d'un spot de glisse — bien mieux que les "
                 "stations d'aéroport sur lesquelles la plupart des applications se rabattent. "
                 "J'aimerais pouvoir l'afficher aux utilisateurs qui consultent ce secteur, avec "
                 "votre nom et un lien vers votre site. Je ne l'ai pas fait : aucune condition "
                 "d'utilisation n'étant publiée, je préfère vous demander d'abord."
                 ) % (d["station"][0].upper() + d["station"][1:])
        retrait = ("Rien ne sera affiché sans votre accord, et si vous changez d'avis plus tard, "
                   "un mot suffira : le retrait est immédiat, sans mise à jour de l'application "
                   "ni délai.")
        sujet = "Tide It et la borne météo du port de %s" % d["court"]
        oui_body = ("Bonjour,\n\nJe donne mon accord pour que Tide It affiche les mesures de %s "
                    "(%s), avec mention de notre nom et lien vers notre site.\n\nCet accord est "
                    "révocable à tout moment sur simple demande de notre part.\n\nConditions "
                    "particulières (laisser vide s'il n'y en a pas) :\n\n\nCordialement,\n"
                    % (d["station"], d["lieu"]))
        non_body = ("Bonjour,\n\nNous ne souhaitons pas que les mesures de %s (%s) figurent dans "
                    "Tide It.\n\nCordialement,\n" % (d["station"], d["lieu"]))

    lien_aff = (d["site"] or SITE).replace("https://", "").replace("http://", "").rstrip("/")
    html = (HTML
            .replace("{INTRO}", intro)
            .replace("{NOM}", d["nom"])
            .replace("{LIENAFF}", lien_aff)
            .replace("{RETRAIT}", retrait)
            .replace("{OUI}", mailto("ACCORD Tide It — %s" % d["ident"], oui_body))
            .replace("{NON}", mailto("REFUS Tide It — %s" % d["ident"], non_body))
            .replace("{SIGN}", SIGNATAIRE)
            .replace("{FROM}", FROM)
            .replace("{SITE}", SITE)
            .replace("{SITEAFF}", SITE.replace("https://", "").rstrip("/")))

    texte = re.sub(r"<[^>]+>", "", html)
    texte = re.sub(r"\n{3,}", "\n\n", texte.replace("&middot;", "·").replace("&nbsp;", " ")
                   .replace("&rsaquo;", "›").replace("&bull;", "•")).strip()
    texte += ("\n\n— Pour donner votre accord ou demander le retrait, répondez simplement à ce "
              "message.\n%s\n%s" % (FROM, SITE))

    m = EmailMessage()
    m["From"] = FROM
    m["To"] = d["to"]
    m["Subject"] = sujet
    m.set_content(texte)
    m.add_alternative(html, subtype="html")

    nom = "%02d-%s-%s.eml" % (i, d["type"].replace("é", "e"),
                              re.sub(r"[^a-z0-9]+", "-", d["nom"].lower()).strip("-"))
    io.open(os.path.join(OUT, nom), "w", encoding="utf-8").write(m.as_string())
    index.append((nom, d))

print("%d courriers generes dans outreach/envois/\n" % len(index))
for nom, d in index:
    print("  %-46s -> %-44s [%s]" % (nom, d["to"], d["note"]))

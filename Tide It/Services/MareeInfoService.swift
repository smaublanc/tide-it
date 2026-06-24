//
//  MareeInfoService.swift
//  Tide It
//
//  ⚠️ SERVICE DÉBRANCHÉ (fichier conservé pour la stabilité du pbxproj).
//
//  Historique : ce service scrappait maree.info (données sous licence SHOM) pour
//  recaler les prédictions harmoniques à long terme. Suite à la demande du SHOM
//  d'arrêter le scraping, l'app est passée à des prédictions 100 % maison :
//  HarmonicTideEngine + constituants TICON (CC-BY 4.0) rattachés aux ports
//  français au lancement (voir PortCatalog.linkFrenchHarmonicsInBackground).
//
//  Aucun appel réseau ne doit être réintroduit ici vers maree.info ou le SHOM.
//

import Foundation

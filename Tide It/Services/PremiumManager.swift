//
//  PremiumManager.swift
//  Tide It
//
//  Gestion du tier Premium via StoreKit 2
//  Features Premium : NOTIFICATIONS (sorties parfaites + alertes marée), calendrier GO 7 jours,
//  vent temps réel, prédictions J30, mode vent, export PDF, carte de marée, Live Activity.
//  GRATUIT : créer activités & alertes, calendrier GO 2 jours, marées hors-ligne mondiales,
//  favoris + sync iCloud, Apple Watch. (iCloud/Watch restent gratuits : non verrouillables proprement.)
//

import StoreKit
import SwiftUI
import os.log

@MainActor
final class PremiumManager: ObservableObject {
    static let shared = PremiumManager()

    // MARK: - Product IDs

    enum ProductID: String, CaseIterable {
        case monthly = "com.tideit.premium.monthly"
        case yearly  = "com.tideit.premium.yearly"
    }

    // MARK: - Published State

    /// Entitlement RÉEL : abonnement actif / achat vérifié par StoreKit. NE PAS lire directement pour
    /// verrouiller une feature — passer par `isPremium`, qui inclut le mois Premium offert.
    @Published private(set) var paidPremium = false
    @Published var products: [Product] = []
    @Published var purchaseError: String?
    @Published var isLoading = false
    /// IDs des abonnements pour lesquels l'utilisateur est ÉLIGIBLE à l'essai gratuit (offre
    /// introductive jamais consommée). Calculé après le chargement des produits → le paywall
    /// ne promet l'essai qu'à ceux qui y ont vraiment droit (exigence App Review).
    @Published var introEligibleProductIDs: Set<String> = []

    // MARK: - Mois Premium offert (cadeau d'accueil → puis retour au mode gratuit)

    /// On fait goûter TOUT le premium pendant `welcomeTrialDays` à partir du 1er lancement de cette
    /// version, puis l'app repasse en mode gratuit (« classic »). AUCUN paiement, AUCUNE reconduction :
    /// c'est un cadeau d'accueil local, distinct de l'essai StoreKit (1 sem.) géré par Apple au paywall.
    static let welcomeTrialDays = 30
    private let welcomeTrialKey = "welcomeTrialStart_v1"

    private var welcomeTrialStart: Date? {
        UserDefaults.standard.object(forKey: welcomeTrialKey) as? Date
    }

    /// Démarre le compteur au tout premier lancement (clé absente). Idempotent → un seul mois par
    /// appareil. (Réinstaller réarme le cadeau : toléré pour une app indé ; durcissable via iCloud KVS.)
    private func startWelcomeTrialIfNeeded() {
        guard welcomeTrialStart == nil else { return }
        UserDefaults.standard.set(Date(), forKey: welcomeTrialKey)
        appLogger.info("[Premium] Mois offert démarré (\(Self.welcomeTrialDays) j)")
    }

    /// Le mois offert court-il encore ? (indépendant de l'achat).
    var welcomeTrialActive: Bool {
        guard let start = welcomeTrialStart else { return false }
        return Date().timeIntervalSince(start) < Double(Self.welcomeTrialDays) * 86_400
    }

    /// Jours restants du mois offert (0 si terminé / absent) — pour le bandeau « offert ».
    var welcomeTrialDaysRemaining: Int {
        guard let start = welcomeTrialStart else { return 0 }
        let elapsedDays = Date().timeIntervalSince(start) / 86_400
        return max(0, Int(ceil(Double(Self.welcomeTrialDays) - elapsedDays)))
    }

    /// L'utilisateur profite du mois offert SANS avoir payé → bandeau « offert », pas « abonné ».
    var isInWelcomeTrial: Bool { !paidPremium && welcomeTrialActive }

    /// Accès premium EFFECTIF = abonnement payé OU mois offert en cours. TOUTES les features lisent ceci.
    var isPremium: Bool { paidPremium || welcomeTrialActive }

    // Feature gates
    var canUseExtendedForecast: Bool { isPremium }
    var canExportPDF: Bool { isPremium }
    var canShareCard: Bool { isPremium }
    var canUseLiveActivity: Bool { isPremium }
    var canUseWindMode: Bool { isPremium }
    var canUsePecheAPied: Bool { isPremium }
    /// Vent temps réel (balises anémomètres) — card Aujourd'hui + widget Vent.
    var canUseRealtimeWind: Bool { isPremium }
    /// Notifications (Sorties Parfaites + alertes marée/vent) : 100 % premium.
    var canReceiveNotifications: Bool { isPremium }
    /// ALERTES (personnalisées ET modèles prédéfinis) : leur USAGE est 100 % premium. Le gratuit
    /// peut les CONSULTER (parcourir les modèles) pour donner envie, mais ne peut ni en créer ni en
    /// activer une. Les ACTIVITÉS (« Mes sports » + calendrier GO 2 j) restent libres.
    var canUseAlerts: Bool { isPremium }
    /// Horizon du calendrier GO : 2 jours en gratuit, 7 en premium.
    var goCalendarDays: Int { isPremium ? 7 : 2 }
    /// Nombre d'alertes utilisables : 0 en gratuit (consultation seule), illimité en premium.
    var maxAlerts: Int { isPremium ? .max : 0 }

    // MARK: - Private

    private var transactionListener: Task<Void, Never>?

    private init() {
        startWelcomeTrialIfNeeded()
        transactionListener = listenForTransactions()
        Task { await checkEntitlement() }
    }

    deinit {
        transactionListener?.cancel()
    }

    // MARK: - Load Products

    func loadProducts() async {
        isLoading = true
        do {
            let ids = ProductID.allCases.map(\.rawValue)
            products = try await Product.products(for: ids)
                .sorted { $0.price < $1.price }
            appLogger.info("[Premium] \(self.products.count) produits chargés")
            // Éligibilité à l'essai gratuit (offre introductive) — par groupe d'abonnement.
            var eligible: Set<String> = []
            for product in products {
                if let sub = product.subscription,
                   sub.introductoryOffer != nil,
                   await sub.isEligibleForIntroOffer {
                    eligible.insert(product.id)
                }
            }
            introEligibleProductIDs = eligible
        } catch {
            // Surface l'erreur → la fiche affiche un message plutôt qu'une zone vide.
            // (On échoue FERMÉ : aucun premium accordé, c'est purement de l'UX.)
            purchaseError = String(localized: "Impossible de charger les offres. Vérifie ta connexion et réessaie.")
            appLogger.error("[Premium] Erreur chargement produits: \(error.localizedDescription)")
        }
        isLoading = false
    }

    /// Libellé d'essai gratuit à afficher pour un produit — UNIQUEMENT si l'utilisateur est éligible
    /// ET que le produit a bien une offre d'essai gratuit (sinon nil → aucune promesse trompeuse).
    func freeTrialText(for product: Product) -> String? {
        guard introEligibleProductIDs.contains(product.id),
              let offer = product.subscription?.introductoryOffer,
              offer.paymentMode == .freeTrial else { return nil }
        return Self.trialLabel(for: offer.period)
    }

    /// « 1 semaine d'essai gratuit », dérivé de la période réelle de l'offre (pas codé en dur).
    private static func trialLabel(for period: Product.SubscriptionPeriod) -> String {
        let v = period.value
        let unit: String
        switch period.unit {
        case .day:   unit = v > 1 ? "jours" : "jour"
        case .week:  unit = v > 1 ? "semaines" : "semaine"
        case .month: unit = "mois"
        case .year:  unit = v > 1 ? "ans" : "an"
        @unknown default: unit = "période"
        }
        return "\(v) \(unit) d'essai gratuit"
    }

    // MARK: - Purchase

    func purchase(_ product: Product) async {
        purchaseError = nil
        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                paidPremium = true
                appLogger.info("[Premium] Achat réussi: \(product.id)")

            case .pending:
                appLogger.info("[Premium] Achat en attente d'approbation")

            case .userCancelled:
                appLogger.info("[Premium] Achat annulé par l'utilisateur")

            @unknown default:
                break
            }
        } catch {
            purchaseError = error.localizedDescription
            appLogger.error("[Premium] Erreur achat: \(error.localizedDescription)")
        }
    }

    // MARK: - Restore

    func restore() async {
        isLoading = true
        defer { isLoading = false }

        do {
            try await AppStore.sync()
            await checkEntitlement()
            // Feedback explicite (attendu par l'App Review) : « Restaurer » ne doit pas
            // rester un no-op silencieux quand il n'y a rien à restaurer. On teste l'achat RÉEL
            // (paidPremium) — le mois offert n'est pas un achat « restaurable ».
            if !paidPremium {
                purchaseError = String(localized: "Aucun achat à restaurer")
            }
            appLogger.info("[Premium] Restauration terminée, payé=\(self.paidPremium)")
        } catch {
            purchaseError = error.localizedDescription
            appLogger.error("[Premium] Erreur restauration: \(error.localizedDescription)")
        }
    }

    // MARK: - Entitlement Check

    func checkEntitlement() async {
        #if DEBUG
        // Débogage : permet de tester les features premium sans achat (StoreKit en
        // environnement Xcode est capricieux). Jamais compilé dans le build App Store.
        if UserDefaults.standard.bool(forKey: Self.debugForcePremiumKey) {
            paidPremium = true
            return
        }
        #endif
        for await result in Transaction.currentEntitlements {
            if let transaction = try? checkVerified(result) {
                if ProductID.allCases.map(\.rawValue).contains(transaction.productID) {
                    paidPremium = true
                    return
                }
            }
        }
        paidPremium = false
    }

    #if DEBUG
    static let debugForcePremiumKey = "debugForcePremium"

    /// Active/désactive le premium forcé (DEBUG uniquement, pour tester sans achat).
    func setDebugPremium(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.debugForcePremiumKey)
        if on {
            paidPremium = true
        } else {
            Task { await checkEntitlement() }  // revenir à l'état réel
        }
    }
    #endif

    // MARK: - Transaction Listener

    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                if let transaction = try? await self?.checkVerified(result) {
                    await transaction.finish()
                    await self?.checkEntitlement()
                }
            }
        }
    }

    // MARK: - Helpers

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let value):
            return value
        }
    }
}

// MARK: - Premium Paywall View

struct PremiumPaywallView: View {
    @ObservedObject private var manager = PremiumManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.spacingXL) {
                    // Hero
                    VStack(spacing: DS.spacingMD) {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 50))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.yellow, .orange],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )

                        Text("Tide It Premium")
                            .font(.scaled(size: DS.fontLargeTitle, weight: .bold))
                            .foregroundStyle(.primary)

                        Text("Débloquez toutes les fonctionnalités")
                            .font(.scaled(size: DS.fontBody))
                            .foregroundStyle(.gray)

                        // Mise en avant de l'essai gratuit (seulement si au moins un plan est éligible).
                        if manager.products.contains(where: { manager.freeTrialText(for: $0) != nil }) {
                            Text("Essai gratuit d'une semaine — sans engagement, annulable à tout moment.")
                                .font(.scaled(size: DS.fontCallout, weight: .semibold))
                                .foregroundStyle(Color.tideHigh)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, DS.pagePadding)
                                .padding(.top, 2)
                        }
                    }
                    .padding(.top, DS.spacingXL)

                    // Rappel du tier GRATUIT (clarté App Review + cadrage de la conversion).
                    HStack(alignment: .top, spacing: DS.spacingSM) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text("Gratuit : crée tes activités, marées du monde entier hors-ligne, favoris, iCloud et Apple Watch.")
                            .font(.scaled(size: DS.fontCaption))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, DS.pagePadding)

                    // Features Premium (alignées sur les verrous réels du code).
                    VStack(alignment: .leading, spacing: DS.spacingLG) {
                        FeatureRow(icon: "bell.badge", title: "Notifications",
                                   subtitle: "Sois prévenu·e des sorties parfaites et de tes alertes marée — sans limite")
                        FeatureRow(icon: "calendar.badge.clock", title: "Calendrier GO 7 jours",
                                   subtitle: "Toutes tes fenêtres idéales de la semaine, par sport (gratuit : aperçu flouté)")
                        FeatureRow(icon: "water.waves", title: "Mode surf & houle",
                                   subtitle: "Spots de surf, fenêtres GO surf, hauteur · période · direction de houle et widget dédié")
                        FeatureRow(icon: "dot.radiowaves.left.and.right", title: "Vent en temps réel",
                                   subtitle: "Le vent observé par la balise la plus proche, pas juste une prévision")
                        FeatureRow(icon: "calendar", title: "Prédictions J+30",
                                   subtitle: "Planifie tes marées un mois à l'avance")
                        FeatureRow(icon: "wind", title: "Mode vent",
                                   subtitle: "Vent et rafales superposés à la courbe de marée")
                        FeatureRow(icon: "livephoto", title: "Live Activity & Dynamic Island",
                                   subtitle: "La marée en direct sur ton écran verrouillé")
                        FeatureRow(icon: "doc.richtext", title: "Partage PDF & carte",
                                   subtitle: "Exporte tes horaires en PDF ou en belle carte à partager")
                    }
                    .padding(.horizontal, DS.pagePadding)

                    // Products
                    if manager.isLoading {
                        ProgressView()
                            .padding()
                    } else {
                        VStack(spacing: DS.spacingMD) {
                            ForEach(manager.products, id: \.id) { product in
                                ProductButton(product: product, trialText: manager.freeTrialText(for: product)) {
                                    Task { await manager.purchase(product) }
                                }
                            }
                        }
                        .padding(.horizontal, DS.pagePadding)
                    }

                    if let error = manager.purchaseError {
                        Text(error)
                            .font(.scaled(size: DS.fontCaption))
                            .foregroundStyle(.red)
                            .padding(.horizontal, DS.pagePadding)
                    }

                    // Restore
                    Button("Restaurer les achats") {
                        Task { await manager.restore() }
                    }
                    .font(.scaled(size: DS.fontCallout))
                    .foregroundStyle(Color.tideHigh)

                    // Legal links (guideline 3.1.2c)
                    VStack(spacing: DS.spacingSM) {
                        Text("Le paiement sera débité sur votre compte Apple à la confirmation de l'achat. Tout essai gratuit non résilié au moins 24h avant son terme se transforme automatiquement en abonnement payant au tarif indiqué. L'abonnement se renouvelle ensuite automatiquement sauf annulation au moins 24h avant la fin de la période en cours. Le renouvellement est facturé au tarif en vigueur. Gérez ou annulez vos abonnements dans Réglages > votre compte Apple > Abonnements.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, DS.pagePadding)

                        HStack(spacing: DS.spacingLG) {
                            Link("Politique de confidentialité", destination: URL(string: "https://smaublanc.github.io/tide-it/privacy.html")!)
                            Link("Conditions d'utilisation", destination: URL(string: "https://smaublanc.github.io/tide-it/terms.html")!)
                        }
                        .font(.scaled(size: DS.fontCaption))
                        .foregroundStyle(Color.tideHigh)
                    }

                    Spacer(minLength: 40)
                }
            }
            .sheetBackground()
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            if manager.products.isEmpty {
                await manager.loadProducts()
            }
        }
    }
}

// MARK: - Feature Row

private struct FeatureRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: DS.spacingMD) {
            Image(systemName: icon)
                .font(.scaled(size: DS.fontHeadline))
                .foregroundStyle(Color.tideHigh)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.scaled(size: DS.fontCallout, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.scaled(size: DS.fontCaption))
                    .foregroundStyle(.gray)
            }
        }
    }
}

// MARK: - Product Button

private struct ProductButton: View {
    let product: Product
    var trialText: String? = nil
    let action: () -> Void

    private var isYearly: Bool {
        product.id.contains("yearly")
    }
    private var periodLabel: String { isYearly ? "an" : "mois" }

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DS.spacingSM) {
                        Text(isYearly ? "Annuel" : "Mensuel")
                            .font(.scaled(size: DS.fontCallout, weight: .bold))
                            .foregroundStyle(.primary)
                        if isYearly {
                            Text("POPULAIRE")
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.yellow)
                                .clipShape(Capsule())
                        }
                    }
                    if let trialText {
                        Text("\(trialText), puis \(product.displayPrice) / \(periodLabel)")
                            .font(.scaled(size: DS.fontSubheadline, weight: .semibold))
                            .foregroundStyle(Color.tideHigh)
                    } else {
                        Text("\(product.displayPrice) / \(periodLabel)")
                            .font(.scaled(size: DS.fontSubheadline))
                            .foregroundStyle(.gray)
                    }
                    Text(isYearly
                         ? "Abonnement de 12 mois, renouvelé automatiquement"
                         : "Abonnement de 1 mois, renouvelé automatiquement")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.scaled(size: DS.fontCallout, weight: .semibold))
                    .foregroundStyle(Color.tideHigh)
            }
            .padding(DS.spacingMD)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusLG)
                    .fill(Color.glassHighlight.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.radiusLG)
                            .stroke(isYearly ? Color.yellow.opacity(0.4) : Color.glassHighlight.opacity(0.1), lineWidth: 1)
                    )
            )
        }
    }
}

// MARK: - Premium Gate Modifier

struct PremiumGateModifier: ViewModifier {
    @ObservedObject private var manager = PremiumManager.shared
    @State private var showPaywall = false
    let feature: String

    func body(content: Content) -> some View {
        content
            .onTapGesture {
                if !manager.isPremium {
                    showPaywall = true
                }
            }
            .overlay {
                if !manager.isPremium {
                    VStack(spacing: DS.spacingSM) {
                        Image(systemName: "lock.fill")
                            .font(.scaled(size: DS.fontHeadline))
                        Text("Premium")
                            .font(.scaled(size: DS.fontCaption, weight: .semibold))
                    }
                    .foregroundStyle(.yellow.opacity(0.8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.ultraThinMaterial.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: DS.radiusLG))
                    .onTapGesture {
                        showPaywall = true
                    }
                }
            }
            .sheet(isPresented: $showPaywall) {
                PremiumPaywallView()
            }
    }
}

extension View {
    func premiumGate(_ feature: String) -> some View {
        modifier(PremiumGateModifier(feature: feature))
    }
}

import Foundation
import Combine
import Security

#if canImport(RevenueCat)
import RevenueCat
#endif

/// metadata 里的一段多语言文案，形如 `{"zh-Hans": "年会员", "en": "Yearly"}`。
/// 语言键与 `AppLanguage.resolvedIdentifier` 对齐，因此后台新增语言无需改客户端。
/// 后台也可以直接填一个字符串，表示所有语言共用同一份文案。
struct LocalizedMetadataText: Equatable {
    private static let fallbackLanguage = "en"

    private let byLanguage: [String: String]

    /// 值既不是非空字符串也不是含有效文案的字典时返回 nil，交给调用方当作「后台未配置」处理。
    init?(metadataValue: Any?) {
        switch metadataValue {
        case let localized as [String: Any]:
            let texts = localized.compactMapValues { $0 as? String }.filter { !$0.value.isEmpty }
            guard !texts.isEmpty else { return nil }
            byLanguage = texts
        case let shared as String where !shared.isEmpty:
            byLanguage = [Self.fallbackLanguage: shared]
        default:
            return nil
        }
    }

    /// 当前 App 语言对应的文案。依次退到主语言码、英文、任意一份，保证不会显示空白。
    var text: String {
        let language = AppLanguage.selected.resolvedIdentifier
        if let exact = byLanguage[language] {
            return exact
        }
        if let base = language.split(separator: "-").first.flatMap({ byLanguage[String($0)] }) {
            return base
        }
        return byLanguage[Self.fallbackLanguage] ?? byLanguage.sorted { $0.key < $1.key }.first?.value ?? ""
    }
}

/// 付费墙上的单个方案。文案全部来自 RevenueCat Offering 的 metadata，价格来自商店商品。
/// 刻意不持有 RevenueCat 的 `Package` 类型，这样视图层无需条件编译即可使用；
/// 购买时由 `PurchaseStore` 用 `packageIdentifier` 回查真正的 `Package`。
struct PaywallPlan: Identifiable, Equatable {
    /// 匹配到的 RevenueCat Package identifier，由 metadata 里的 `product_id` 解析得到。
    let packageIdentifier: String
    /// 商店给出的本地化价格，例如「¥98」「US$13.99」，已按用户所在商店地区格式化，不需要翻译。
    let localizedPrice: String
    /// StoreKit 实际返回的免费试用天数；后台尚未生效或不是按天试用时为 nil。
    let freeTrialDays: Int?
    /// 是否作为付费墙默认选中项。
    let isRecommended: Bool

    // 用 fileprivate 而不是 private：合成的 memberwise init 会取最严格的成员级别，
    // 写成 private 的话同文件的 makePlans 也拿不到构造器。
    fileprivate let title: LocalizedMetadataText
    fileprivate let subtitle: LocalizedMetadataText?
    fileprivate let badge: LocalizedMetadataText?
    fileprivate let priceSuffix: LocalizedMetadataText?
    fileprivate let originalPrice: LocalizedMetadataText?

    var id: String { packageIdentifier }

    // 以下取值都推迟到读取时：plans 缓存在 @Published 里，
    // 若解析阶段就挑好语言，切换 App 内语言后文案会停留在旧语言。
    var titleText: String { title.text }
    /// 后台未配置副标题时为空串，由视图决定是否隐藏该行。
    var subtitleText: String { subtitle?.text ?? "" }
    /// 角标文案，例如「推荐」；后台留空时为 nil，不渲染角标。
    var badgeText: String? { badge?.text }
    /// 商店价格加周期后缀，例如「¥98/年」「US$13.99/year」。
    var priceText: String { localizedPrice + (priceSuffix?.text ?? "") }
    /// 划线原价，例如「¥298」。商店不提供该数据，只能由后台按语言分别配置；未配置时为 nil。
    var originalPriceText: String? { originalPrice?.text }

    /// 试用期的续费说明，例如「3日免费试用，之后¥98/年」。
    /// 价格直接用带周期后缀的 priceText（后缀来自后台 metadata 的 price_suffix），和方案行右侧的价格保持一致
    func trialRenewalText(days: Int) -> String {
        L10n.format("%lld日免费试用，之后%@", days, priceText)
    }
}

/// Offering metadata 的字段名，需与 RevenueCat 后台配置保持一致。
private enum PaywallMetadataKey {
    static let plans = "plans"
    static let productID = "product_id"
    static let title = "title"
    static let subtitle = "subtitle"
    static let badge = "badge"
    static let priceSuffix = "price_suffix"
    static let originalPrice = "original_price"
    static let recommended = "recommended"
}

/// 免费版额度上限，累计超过任意一项就需要 Minus Pro。
enum FreeQuota {
    static let deletionCount = 20
    static let releasedBytes: Int64 = 100 * 1_024 * 1_024

    /// 用户从评分入口跳转后可领取一次的额外免费额度。
    static let reviewRewardDeletionCount = 50
    static let reviewRewardReleasedBytes: Int64 = 200 * 1_024 * 1_024

    /// 用于设置页文案，随上限自动变化，避免调试构建里说的和实际拦截的不一致。
    static var summaryText: String {
        L10n.format("%lld 张或 %@", deletionCount, ByteSizeText.full(releasedBytes))
    }

    static var reviewRewardSummaryText: String {
        L10n.format(
            "%lld 张或 %@",
            reviewRewardDeletionCount,
            ByteSizeText.full(reviewRewardReleasedBytes)
        )
    }
}

enum RevenueCatConfiguration {
    static let entitlementIdentifier = "minus_pro"
    static let proxyURL = URL(string: "https://api.rc-backup.com/")

    static var apiKey: String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "RevenueCatAPIKey") as? String else {
            return ""
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSupportedPublicKey = trimmed.hasPrefix("appl_") || trimmed.hasPrefix("test_")
        guard isSupportedPublicKey,
              !trimmed.contains("REPLACE"),
              !trimmed.contains("$(") else { return "" }
        return trimmed
    }

    static var usesTestStore: Bool {
        apiKey.hasPrefix("test_")
    }
}

enum RevenueCatAuthError: LocalizedError {
    case sdkUnavailable
    case notConfigured
    case invalidUserID
    case stableLoginFailed

    var errorDescription: String? {
        switch self {
        case .sdkUnavailable: L10n.text("支付组件未安装。")
        case .notConfigured: L10n.text("RevenueCat 尚未配置。")
        case .invalidUserID: L10n.text("无法创建用户标识。")
        case .stableLoginFailed: L10n.text("用户状态同步失败，请稍后重试。")
        }
    }
}

/// 与 Name 项目相同的稳定匿名用户方案：RevenueCat 负责购买身份，本机钥匙串保存用户 ID。
/// 用户不需要注册账号，重装后钥匙串仍可继续命中同一个 RevenueCat 用户；换设备时可通过“恢复购买”找回权益。
struct RevenueCatAuthService {
    private static let keychainUserIDKey = "com.bieny.minus.revenuecat.userid"
    private static let defaultsUserIDKey = "TidyAlbum.stableRevenueCatUserID"

    @discardableResult
    static func configure() -> Bool {
        #if canImport(RevenueCat)
        guard !Purchases.isConfigured else { return true }
        let key = RevenueCatConfiguration.apiKey
        guard !key.isEmpty else { return false }

        #if DEBUG
        Purchases.logLevel = .debug
        #else
        Purchases.logLevel = .warn
        #endif
        Purchases.proxyURL = RevenueCatConfiguration.proxyURL
        Purchases.configure(withAPIKey: key)
        return true
        #else
        return false
        #endif
    }

    /// 钥匙串里只会保存 RevenueCat 已经生成或确认过的 appUserID。
    static func cachedUserID() -> String? {
        guard let savedID = loadSavedUserID(), !savedID.isEmpty else { return nil }
        return serverUserID(from: savedID)
    }

    /// configure 完成后 RevenueCat 会同步生成匿名 appUserID，无需等待联网请求。
    static func currentUserID() -> String? {
        #if canImport(RevenueCat)
        guard Purchases.isConfigured else { return nil }
        let currentID = Purchases.shared.appUserID
        guard !currentID.isEmpty else { return nil }
        return serverUserID(from: currentID)
        #else
        return nil
        #endif
    }

    func stableUserID() async throws -> String {
        #if canImport(RevenueCat)
        guard Self.configure() else { throw RevenueCatAuthError.notConfigured }
        let currentID = Purchases.shared.appUserID

        if let savedID = Self.loadSavedUserID(), !savedID.isEmpty {
            if savedID != currentID {
                do {
                    _ = try await Purchases.shared.logIn(savedID)
                } catch {
                    throw RevenueCatAuthError.stableLoginFailed
                }
            }
            Self.saveUserID(savedID)
            return Self.serverUserID(from: savedID)
        }

        guard !currentID.isEmpty else { throw RevenueCatAuthError.invalidUserID }
        Self.saveUserID(currentID)
        return Self.serverUserID(from: currentID)
        #else
        throw RevenueCatAuthError.sdkUnavailable
        #endif
    }

    static func serverUserID(from appUserID: String) -> String {
        if let range = appUserID.range(of: ":") {
            return String(appUserID[range.upperBound...])
        }
        return appUserID
    }

    private static func loadSavedUserID() -> String? {
        if let keychainID = KeychainStore.load(key: keychainUserIDKey), !keychainID.isEmpty {
            return keychainID
        }
        return UserDefaults.standard.string(forKey: defaultsUserIDKey)
    }

    private static func saveUserID(_ userID: String) {
        guard !userID.isEmpty else { return }
        KeychainStore.save(userID, key: keychainUserIDKey)
        UserDefaults.standard.set(userID, forKey: defaultsUserIDKey)
    }
}

/// 钥匙串读写。仅用于 RevenueCat 稳定用户 ID，重装后仍能命中同一个付费身份。
enum KeychainStore {
    static func load(key: String) -> String? {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, key: String) {
        let query = baseQuery(key: key)
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else { return }

        var newItem = query
        newItem[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(newItem as CFDictionary, nil)
    }

    private static func baseQuery(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
    }
}

@MainActor
final class PurchaseStore: ObservableObject {
    @Published private(set) var isConfigured = false
    @Published private(set) var isLoading = false
    @Published private(set) var isPurchasing = false
    @Published private(set) var isPro = false
    /// 是否已经拿到过一次会员状态。为 false 时说明还没同步完，此时不应把已付费用户误判成免费用户。
    @Published private(set) var hasSyncedEntitlements = false
    @Published private(set) var userID = ""
    @Published private(set) var statusMessage = ""
    /// 付费墙方案列表，完全由当前 Offering 的 metadata 决定；后台未配置时为空。
    @Published private(set) var plans: [PaywallPlan] = []
    /// 只有 StoreKit 确实提供免费试用、且 RevenueCat 判定当前 Apple ID 符合资格时才会进入此集合。
    @Published private(set) var trialEligiblePlanIDs: Set<String> = []

    #if canImport(RevenueCat)
    @Published private(set) var offering: Offering?
    private var customerInfoTask: Task<Void, Never>?
    private var trialEligibilityTask: Task<Void, Never>?
    #endif

    init() {
        // 已有用户直接显示钥匙串保存的 RevenueCat 编号，不等待网络。
        userID = RevenueCatAuthService.cachedUserID() ?? ""
    }

    /// RevenueCat 首次配置可能做磁盘和钥匙串工作，必须由启动动画结束后的 start() 延迟触发。
    private func configureIfNeeded() -> Bool {
        if isConfigured { return true }
        isConfigured = RevenueCatAuthService.configure()
        #if canImport(RevenueCat)
        guard isConfigured else {
            statusMessage = L10n.text("请配置 Minus 的 RevenueCat Public SDK Key")
            return false
        }
        if customerInfoTask == nil {
            customerInfoTask = Task { [weak self] in
                guard let self else { return }
                for await info in Purchases.shared.customerInfoStream {
                    self.apply(info)
                }
            }
        }
        #endif
        return isConfigured
    }

    deinit {
        #if canImport(RevenueCat)
        customerInfoTask?.cancel()
        trialEligibilityTask?.cancel()
        #endif
    }

    var displayUserID: String {
        guard !userID.isEmpty else { return L10n.text("正在建立用户…") }
        guard userID.count > 12 else { return userID }
        return "\(userID.prefix(6))…\(userID.suffix(4))"
    }

    var membershipLabel: String {
        isPro ? L10n.text("Minus Pro 已解锁") : L10n.text("免费版")
    }

    var storeLabel: String {
        RevenueCatConfiguration.usesTestStore ? "RevenueCat Test Store" : "App Store"
    }

    func eligibleFreeTrialDays(for plan: PaywallPlan) -> Int? {
        guard trialEligiblePlanIDs.contains(plan.id) else { return nil }
        return plan.freeTrialDays
    }

    func start() async {
        guard !isLoading else { return }
        guard configureIfNeeded() else { return }
        // 真正首次安装没有钥匙串记录；配置完成后立刻展示 RevenueCat 生成的匿名编号。
        if userID.isEmpty {
            userID = RevenueCatAuthService.currentUserID() ?? ""
        }
        isLoading = true
        defer { isLoading = false }

        #if canImport(RevenueCat)
        do {
            userID = try await RevenueCatAuthService().stableUserID()
            async let offeringsRequest = Purchases.shared.offerings()
            async let customerInfoRequest = Purchases.shared.customerInfo()
            let (offerings, customerInfo) = try await (offeringsRequest, customerInfoRequest)
            apply(offerings.current)
            apply(customerInfo)
        } catch {
            statusMessage = L10n.format("会员信息加载失败：%@", error.localizedDescription)
        }
        #endif
    }

    func refresh() async {
        guard configureIfNeeded() else { return }

        #if canImport(RevenueCat)
        do {
            // 首次联网失败后再次刷新时，先确保 RevenueCat 已切到本机稳定编号。
            userID = try await RevenueCatAuthService().stableUserID()
            let offerings = try await Purchases.shared.offerings()
            let customerInfo = try await Purchases.shared.customerInfo()
            apply(offerings.current)
            apply(customerInfo)
        } catch {
            statusMessage = L10n.format("会员状态刷新失败：%@", error.localizedDescription)
        }
        #endif
    }

    func restorePurchases() async -> Bool {
        guard configureIfNeeded() else {
            statusMessage = L10n.text("支付服务尚未配置。")
            return false
        }

        isPurchasing = true
        defer { isPurchasing = false }

        #if canImport(RevenueCat)
        do {
            let customerInfo = try await Purchases.shared.restorePurchases()
            apply(customerInfo)
            statusMessage = isPro ? L10n.text("购买已恢复。") : L10n.text("没有找到可恢复的购买。")
            return isPro
        } catch {
            statusMessage = L10n.format("恢复购买失败：%@", error.localizedDescription)
            return false
        }
        #else
        return false
        #endif
    }

    #if canImport(RevenueCat)
    /// 保存 Offering 并按 metadata 重建方案列表。
    private func apply(_ offering: Offering?) {
        self.offering = offering
        plans = Self.makePlans(from: offering)
        refreshTrialEligibility(from: offering)

        // 分三种失败原因给出提示，避免把「商品没上架」误报成「元数据没配」。
        if offering == nil {
            statusMessage = L10n.text("RevenueCat 尚未配置 current Offering。")
        } else if offering?.availablePackages.isEmpty == true {
            let store = RevenueCatConfiguration.usesTestStore ? "Test Store" : "App Store"
            statusMessage = L10n.format("当前 Offering 没有可用商品，请在 RevenueCat 后台为其添加 %@ 商品。", store)
        } else if plans.isEmpty {
            statusMessage = L10n.text("Offering metadata 未配置 plans，或其中的 product_id 与商品不匹配。")
        } else {
            statusMessage = ""
        }
    }

    /// 解析 Offering metadata 中的 `plans` 数组，数组顺序即付费墙展示顺序。
    /// 缺少 metadata 配置、或 metadata 指向的 package 不在当前 Offering 里的方案会被直接丢弃，不做本地兜底。
    private static func makePlans(from offering: Offering?) -> [PaywallPlan] {
        guard let offering,
              let entries = offering.metadata[PaywallMetadataKey.plans] as? [[String: Any]] else {
            return []
        }

        return entries.compactMap { entry in
            guard let identifier = entry[PaywallMetadataKey.productID] as? String,
                  let title = LocalizedMetadataText(metadataValue: entry[PaywallMetadataKey.title]),
                  // 以 App Store 产品 ID（com.bieny.minus.pro.*）匹配；也接受直接填 RevenueCat Package identifier。
                  let package = offering.availablePackages.first(where: {
                      $0.storeProduct.productIdentifier == identifier || $0.identifier == identifier
                  }) else {
                return nil
            }

            // 各语言文案整份带走，具体挑哪一种语言由 PaywallPlan 在读取时决定。
            return PaywallPlan(
                packageIdentifier: package.identifier,
                localizedPrice: package.localizedPriceString,
                freeTrialDays: Self.freeTrialDays(from: package.storeProduct.introductoryDiscount),
                isRecommended: entry[PaywallMetadataKey.recommended] as? Bool ?? false,
                title: title,
                subtitle: LocalizedMetadataText(metadataValue: entry[PaywallMetadataKey.subtitle]),
                badge: LocalizedMetadataText(metadataValue: entry[PaywallMetadataKey.badge]),
                priceSuffix: LocalizedMetadataText(metadataValue: entry[PaywallMetadataKey.priceSuffix]),
                originalPrice: LocalizedMetadataText(metadataValue: entry[PaywallMetadataKey.originalPrice])
            )
        }
    }

    private static func freeTrialDays(from discount: StoreProductDiscount?) -> Int? {
        guard let discount,
              discount.paymentMode == .freeTrial,
              discount.subscriptionPeriod.unit == .day else { return nil }
        let days = discount.subscriptionPeriod.value * max(discount.numberOfPeriods, 1)
        return days > 0 ? days : nil
    }

    /// RevenueCat 的资格判断是 best effort；最终是否应用试用仍由 App Store 付款页决定。
    private func refreshTrialEligibility(from offering: Offering?) {
        trialEligibilityTask?.cancel()
        trialEligiblePlanIDs = []

        guard let offering else { return }
        let trialPackages = offering.availablePackages.filter {
            Self.freeTrialDays(from: $0.storeProduct.introductoryDiscount) != nil
        }
        guard !trialPackages.isEmpty else { return }
        let expectedPlanIDs = Set(plans.map(\.id))

        trialEligibilityTask = Task { [weak self] in
            var eligibleIDs: Set<String> = []
            for package in trialPackages {
                guard !Task.isCancelled else { return }
                let eligibility = await Purchases.shared.checkTrialOrIntroDiscountEligibility(
                    product: package.storeProduct
                )
                if eligibility == .eligible {
                    eligibleIDs.insert(package.identifier)
                }
            }

            guard !Task.isCancelled,
                  let self,
                  Set(self.plans.map(\.id)) == expectedPlanIDs else { return }
            self.trialEligiblePlanIDs = eligibleIDs
        }
    }

    func purchase(_ plan: PaywallPlan) async -> Bool {
        guard let package = offering?.availablePackages.first(where: { $0.identifier == plan.packageIdentifier }) else {
            statusMessage = L10n.text("该套餐尚未在 RevenueCat 发布。")
            return false
        }

        isPurchasing = true
        statusMessage = ""
        defer { isPurchasing = false }

        do {
            let result = try await Purchases.shared.purchase(package: package)
            guard !result.userCancelled else { return false }
            apply(result.customerInfo)

            // 权益偶尔比交易晚一步到账，强制回源再确认一次。
            if !isPro, let refreshed = try? await Purchases.shared.customerInfo(fetchPolicy: .fetchCurrent) {
                apply(refreshed)
            }

            // 只是给后端发一条通知用于漏斗统计，不涉及任何积分或额度变更。
            AnalyticsReporter.shared.track(
                .purchaseSuccess(productID: result.transaction?.productIdentifier ?? plan.packageIdentifier)
            )

            // 钱已经付了就不该继续把用户挡在付费墙上；权益仍未到账时交给 customerInfoStream 兜底。
            statusMessage = isPro
                ? L10n.text("购买成功，Minus Pro 已解锁。")
                : L10n.text("购买已完成，权益稍后自动生效。")
            return true
        } catch ErrorCode.purchaseCancelledError {
            statusMessage = ""
            return false
        } catch {
            statusMessage = L10n.format("购买未完成：%@", error.localizedDescription)
            return false
        }
    }

    private func apply(_ customerInfo: CustomerInfo) {
        isPro = customerInfo.entitlements[RevenueCatConfiguration.entitlementIdentifier]?.isActive == true
        hasSyncedEntitlements = true
    }
    #else
    func purchase(_ plan: PaywallPlan) async -> Bool { false }
    #endif
}

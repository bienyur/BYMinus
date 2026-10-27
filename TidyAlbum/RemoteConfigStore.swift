import Foundation
import Combine

private enum NetworkAvailability {
    /// 用不读取配置正文的 HEAD 请求触发首次联网授权并确认真实连通性。
    /// 授权弹窗可能让第一次请求提前失败，因此在内部短暂重试，不进入业务初始化。
    static func confirmAccess(to url: URL) async -> Bool {
        for attempt in 0..<3 {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 12

            if let (_, response) = try? await URLSession.shared.data(for: request),
               response is HTTPURLResponse {
                return true
            }

            guard attempt < 2, !Task.isCancelled else { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled {
                break
            }
        }
        return false
    }
}

/// 远程配置里的多语言文案。兼容旧版单字符串，也支持按语言代码下发字典。
struct LocalizedRemoteText: Equatable, Decodable {
    static let empty = LocalizedRemoteText(sharedText: "", translations: [:])

    private let sharedText: String
    private let translations: [String: String]

    var text: String {
        if !sharedText.isEmpty { return sharedText }

        let language = AppLanguage.selected.resolvedIdentifier
        if let exact = translations[language], !exact.isEmpty {
            return exact
        }
        let base = language.split(separator: "-").first.map(String.init) ?? language
        if let baseText = translations[base], !baseText.isEmpty {
            return baseText
        }
        if let english = translations["en"], !english.isEmpty {
            return english
        }
        if let chinese = translations["zh-Hans"], !chinese.isEmpty {
            return chinese
        }
        return translations.sorted { $0.key < $1.key }.first?.value ?? ""
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let shared = try? container.decode(String.self) {
            self.init(sharedText: shared, translations: [:])
            return
        }
        if let localized = try? container.decode([String: String].self) {
            self.init(
                sharedText: "",
                translations: localized.filter { !$0.value.isEmpty }
            )
            return
        }
        self = .empty
    }

    private init(sharedText: String, translations: [String: String]) {
        self.sharedText = sharedText
        self.translations = translations
    }
}

/// 远程配置：托管在服务器上，用来在不发版的情况下控制升级提示和支付相关开关。
struct AppRemoteConfig: Equatable {
    struct Update: Equatable {
        /// 商店上的最新版本，高于本机版本时提示更新。
        let latestVersion: String
        /// 是否强制升级。为 true 时提示不可关闭，用户只能去更新。
        let forceUpdate: Bool
        let localizedReleaseNotes: LocalizedRemoteText

        var releaseNotes: String { localizedReleaseNotes.text }
    }

    struct Purchase: Equatable {
        /// 总开关：关闭后隐藏所有付费入口，同时不再做免费额度限制。
        let paywallEnabled: Bool
        /// 恢复购买按钮开关。
        let restoreEnabled: Bool
    }

    let update: Update
    let purchase: Purchase

    /// 字段缺失时的兜底。这里必须保持支付可用，否则一处后台笔误就会让所有人都买不了。
    static let fallback = AppRemoteConfig(
        update: Update(
            latestVersion: "",
            forceUpdate: false,
            localizedReleaseNotes: .empty
        ),
        purchase: Purchase(paywallEnabled: true, restoreEnabled: true)
    )
}

extension AppRemoteConfig: Decodable {
    private enum RootKey: String, CodingKey {
        case update
        case purchase
    }

    private enum UpdateKey: String, CodingKey {
        case latestVersion = "latest_version"
        case forceUpdate = "force_update"
        case releaseNotes = "release_notes"
        case releaseNotesI18n = "release_notes_i18n"
    }

    private enum PurchaseKey: String, CodingKey {
        case paywallEnabled = "paywall_enabled"
        case restoreEnabled = "restore_enabled"
    }

    /// 逐字段容错：任何一个键缺失都退回 fallback 的对应值，不让整份配置作废。
    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKey.self)
        let fallback = AppRemoteConfig.fallback

        if let updateBox = try? root.nestedContainer(keyedBy: UpdateKey.self, forKey: .update) {
            let localizedReleaseNotes: LocalizedRemoteText
            if let value = try updateBox.decodeIfPresent(
                LocalizedRemoteText.self,
                forKey: .releaseNotesI18n
            ) {
                localizedReleaseNotes = value
            } else {
                localizedReleaseNotes = try updateBox.decodeIfPresent(
                    LocalizedRemoteText.self,
                    forKey: .releaseNotes
                ) ?? .empty
            }

            update = Update(
                latestVersion: try updateBox.decodeIfPresent(String.self, forKey: .latestVersion) ?? "",
                forceUpdate: try updateBox.decodeIfPresent(Bool.self, forKey: .forceUpdate) ?? false,
                localizedReleaseNotes: localizedReleaseNotes
            )
        } else {
            update = fallback.update
        }

        if let purchaseBox = try? root.nestedContainer(keyedBy: PurchaseKey.self, forKey: .purchase) {
            purchase = Purchase(
                paywallEnabled: try purchaseBox.decodeIfPresent(Bool.self, forKey: .paywallEnabled)
                    ?? fallback.purchase.paywallEnabled,
                restoreEnabled: try purchaseBox.decodeIfPresent(Bool.self, forKey: .restoreEnabled)
                    ?? fallback.purchase.restoreEnabled
            )
        } else {
            purchase = fallback.purchase
        }
    }
}

/// 升级提示的三种状态。
enum AppUpdateState: Equatable {
    case none
    /// 可忽略，同一个版本只提示一次。
    case optional
    /// 低于最低可用版本，必须更新。
    case forced
}

enum AppVersion {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// 用 .numeric 逐段比较，"1.10" 会正确地大于 "1.9"。
    static func isOlder(_ version: String, than other: String) -> Bool {
        guard !version.isEmpty, !other.isEmpty else { return false }
        return version.compare(other, options: .numeric) == .orderedAscending
    }
}

/// 配置加载状态。拿不到配置就不放行，用户只能停在重试页。
enum RemoteConfigLoadState: Equatable {
    case loading
    case loaded
    case failed(String)

    var isLoaded: Bool { self == .loaded }
}

@MainActor
final class RemoteConfigStore: ObservableObject {
    @Published private(set) var config: AppRemoteConfig = .fallback
    @Published private(set) var updateState: AppUpdateState = .none
    @Published private(set) var loadState: RemoteConfigLoadState = .loading

    private static let configURL = URL(string: "https://text2image.site/app-config-minus.json")!
    private let skippedVersionKey = "tidyAlbum.skippedUpdateVersion"
    private let defaults = UserDefaults.standard

    func refresh() async {
        loadState = .loading

        guard await NetworkAvailability.confirmAccess(to: Self.configURL) else {
            loadState = .failed(L10n.text("未检测到可用网络，请检查系统网络权限后重试。"))
            return
        }

        var request = URLRequest(url: Self.configURL)
        // 配置要尽量新，绕开本地 HTTP 缓存。
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            loadState = .failed(L10n.text("网络连接失败，请检查网络后重试。"))
            return
        }

        guard http.statusCode == 200 else {
            loadState = .failed(L10n.format("服务暂时不可用（%lld），请稍后重试。", http.statusCode))
            return
        }

        guard let decoded = try? JSONDecoder().decode(AppRemoteConfig.self, from: data) else {
            loadState = .failed(L10n.text("配置数据异常，请稍后重试。"))
            return
        }

        config = decoded
        updateState = Self.resolveUpdateState(for: decoded, skippedVersion: defaults.string(forKey: skippedVersionKey))
        loadState = .loaded
    }

    /// 用户选择「稍后再说」后，这个版本不再打扰；出新版本时会重新提示。
    func skipCurrentUpdate() {
        guard updateState == .optional else { return }
        defaults.set(config.update.latestVersion, forKey: skippedVersionKey)
        updateState = .none
    }

    private static func resolveUpdateState(for config: AppRemoteConfig, skippedVersion: String?) -> AppUpdateState {
        // 本机已经不低于线上版本就没什么可提示的，强制开关也不该把用户卡死。
        guard AppVersion.isOlder(AppVersion.current, than: config.update.latestVersion) else { return .none }

        if config.update.forceUpdate { return .forced }
        // 已经被用户忽略过的版本不再弹窗。
        return skippedVersion == config.update.latestVersion ? .none : .optional
    }
}

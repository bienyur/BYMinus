import SwiftUI

@main
struct MinusApp: App {
    @StateObject private var purchaseStore = PurchaseStore()
    @StateObject private var remoteConfig = RemoteConfigStore()
    @StateObject private var accountStore = AccountStore()
    /// 反馈会话放在 App 级别：设置页入口要显示新回复红点，反馈页也要用同一份数据
    @StateObject private var feedbackStore = FeedbackStore()
    @State private var didInitializeUserServices = false
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system.rawValue

    var body: some Scene {
        WindowGroup {
            AppRootView()
                // 石墨主题是深色，锁定深色才能让状态栏、弹窗、系统控件跟着走
                .preferredColorScheme(.dark)
                .environmentObject(purchaseStore)
                .environmentObject(remoteConfig)
                .environmentObject(accountStore)
                .environmentObject(feedbackStore)
                .environment(\.locale, selectedLocale)
                .task {
                    AnalyticsReporter.shared.track(.appOpen(launchSource: "cold_start"))
                    // 先等系统确认网络通路可用，再读取远程配置。
                    await remoteConfig.refresh()
                }
                .task(id: remoteConfig.loadState.isLoaded) {
                    // 配置成功代表联网权限已经放行；此后才初始化 RevenueCat 用户和后端账号。
                    // 首次请求失败后，用户在配置页重试成功也会自动进入这里。
                    guard remoteConfig.loadState.isLoaded,
                          !didInitializeUserServices else { return }
                    didInitializeUserServices = true

                    await purchaseStore.start()
                    let registered = await accountStore.start(userID: purchaseStore.userID)
                    if registered {
                        AnalyticsReporter.shared.track(.accountReady(source: "network"))
                    }
                }
        }
    }

    private var selectedLocale: Locale {
        Locale(identifier: (AppLanguage(rawValue: appLanguage) ?? .system).resolvedIdentifier)
    }
}

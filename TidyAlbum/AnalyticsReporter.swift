import Foundation
import UIKit

/// 上报给后端的埋点事件。事件名与属性名必须落在后端白名单里（zhongjian 的 services/analyticsService.js），
/// 否则属性会被静默丢弃。只传计数和枚举值，不传照片标识、文件名等任何内容数据。
enum AnalyticsEvent {
    case appOpen(launchSource: String)
    case accountReady(source: String)
    case paywallView(entryReason: String)
    case paywallContinue(entryReason: String)
    case purchaseSuccess(productID: String)
    /// 底部标签切换。screen 取 home / timeline / pending / insights，后端用 page == home 统计首页曝光
    case screenView(screen: String)
    /// 首页标题滚轮手动切换合集。method：wheel（按住拖动）/ accessibility（旁白轻扫）
    case homeCollectionSwitch(method: String, collection: String)
    /// 打开整理页。source：library（整个图库）/ collection（某个合集）；collection 是合集标识，图库为 all
    case organizeStart(source: String, collection: String)
    /// 关闭整理页时汇总这一轮，代替逐张上报，避免滑一次发一个请求
    case organizeEnd(source: String, collection: String, reviewedCount: Int, deleteCount: Int, keepCount: Int, durationSec: Int)
    /// 在分类、相簿、时间列表里批量加入待删除。source：group / album / timeline
    case photosStaged(source: String, photoCount: Int)
    /// 删除真正成功（照片已移入系统“最近删除”）。source：pending（待删除页）/ session（整理页或搜索的本次删除）
    case deleteConfirm(source: String, photoCount: Int, freedMB: Int)
    /// 删除时免费额度不够。source 同 deleteConfirm；
    /// prompt：offer（弹出开会员 / 评分提示）/ paywall（评分奖励领过了，直接进付费页）
    case quotaExceeded(source: String, prompt: String)
    /// 额度提示里的选择：upgrade（开会员）/ rate（去评分）/ dismiss（关掉）
    case quotaPromptAction(action: String)
    /// 评分奖励额度到账
    case reviewRewardGranted
    /// 反馈提交成功。category：suggestion / experience / bug / other，与生图 App 的同名事件口径一致
    case feedbackSubmit(category: String)

    var name: String {
        switch self {
        case .appOpen: "app_open"
        case .accountReady: "account_ready"
        case .paywallView: "paywall_view"
        case .paywallContinue: "paywall_continue"
        case .purchaseSuccess: "purchase_success"
        case .screenView: "screen_view"
        case .homeCollectionSwitch: "home_collection_switch"
        case .organizeStart: "organize_start"
        case .organizeEnd: "organize_end"
        case .photosStaged: "photos_staged"
        case .deleteConfirm: "delete_confirm"
        case .quotaExceeded: "quota_exceeded"
        case .quotaPromptAction: "quota_prompt_action"
        case .reviewRewardGranted: "review_reward_granted"
        case .feedbackSubmit: "feedback_submit"
        }
    }

    var page: String {
        switch self {
        case .appOpen, .accountReady: "launch"
        case .paywallView, .paywallContinue, .purchaseSuccess: "paywall"
        case .screenView(let screen): screen
        case .homeCollectionSwitch: "home"
        case .organizeStart, .organizeEnd: "organize"
        case .photosStaged, .deleteConfirm: "cleanup"
        case .quotaExceeded, .quotaPromptAction, .reviewRewardGranted: "quota"
        case .feedbackSubmit: "feedback"
        }
    }

    var properties: [String: Any] {
        switch self {
        case .appOpen(let launchSource): ["launch_source": launchSource]
        case .accountReady(let source): ["source": source]
        case .paywallView(let entryReason): ["entry_reason": entryReason]
        case .paywallContinue(let entryReason): ["entry_reason": entryReason]
        case .purchaseSuccess(let productID): ["product_id": productID]
        case .screenView(let screen): ["screen": screen]
        case let .homeCollectionSwitch(method, collection): ["method": method, "collection": collection]
        case let .organizeStart(source, collection): ["source": source, "collection": collection]
        case let .organizeEnd(source, collection, reviewedCount, deleteCount, keepCount, durationSec):
            [
                "source": source,
                "collection": collection,
                "reviewed_count": reviewedCount,
                "delete_count": deleteCount,
                "keep_count": keepCount,
                "duration_sec": durationSec
            ]
        case let .photosStaged(source, photoCount): ["source": source, "photo_count": photoCount]
        case let .deleteConfirm(source, photoCount, freedMB):
            ["source": source, "photo_count": photoCount, "freed_mb": freedMB]
        case let .quotaExceeded(source, prompt): ["source": source, "prompt": prompt]
        case .quotaPromptAction(let action): ["action": action]
        case .reviewRewardGranted: [:]
        case .feedbackSubmit(let category): ["category": category, "has_images": false]
        }
    }
}

/// 埋点上报。购买成功也走这里，只是一条通知，不涉及任何积分或额度变更。
/// 事件量很小（一次会话通常几条），所以直接逐条发送，失败就丢弃，不做本地队列和重试。
final class AnalyticsReporter: @unchecked Sendable {
    static let shared = AnalyticsReporter()

    private static let endpoint = URL(string: "https://text2image.site/v1/analytics/events")!
    private static let timestampFormatter = ISO8601DateFormatter()
    private let installationIDKey = "tidyAlbum.analytics.installationID"

    private let installationID: String
    /// 每次冷启动换一个，用于区分会话。
    private let sessionID = UUID().uuidString
    private let lock = NSLock()
    private var userID = ""

    private init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: installationIDKey), !saved.isEmpty {
            installationID = saved
        } else {
            installationID = UUID().uuidString
            defaults.set(installationID, forKey: installationIDKey)
        }
    }

    /// 账号就绪后调用，让客户端事件和服务端记录的 account_registered 按同一个 user_id 聚合。
    func setUserID(_ value: String) {
        lock.lock()
        userID = value
        lock.unlock()
    }

    func track(_ event: AnalyticsEvent) {
        let payload = makePayload(for: event)
        Task.detached(priority: .utility) {
            await Self.send(payload)
        }
    }

    private func makePayload(for event: AnalyticsEvent) -> [String: Any] {
        lock.lock()
        let currentUserID = userID
        lock.unlock()

        let body: [String: Any] = [
            "event_id": UUID().uuidString,
            "event_name": event.name,
            "page": event.page,
            "occurred_at": Self.timestampFormatter.string(from: Date()),
            "properties": event.properties
        ]

        return [
            "schema_version": 1,
            // 后台按 app_key 区分项目；不带的话只能靠账号注册渠道反推，登录前的事件常常落进“未识别项目”
            "app_key": "minus_ios",
            "installation_id": installationID,
            "session_id": sessionID,
            "user_id": currentUserID,
            "app_version": DeviceProfile.appVersion,
            "build_version": DeviceProfile.buildVersion,
            "platform": "ios",
            "os_version": DeviceProfile.osVersion,
            "device_model": DeviceProfile.model,
            "locale": DeviceProfile.locale,
            "events": [body]
        ]
    }

    private static func send(_ payload: [String: Any]) async {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = data

        _ = try? await URLSession.shared.data(for: request)
    }
}

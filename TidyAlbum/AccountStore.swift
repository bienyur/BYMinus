import Foundation
import Combine
import UIKit

/// 设备与应用信息，注册和埋点都要带。
enum DeviceProfile {
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    static var buildVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    static var osVersion: String { UIDevice.current.systemVersion }

    /// UIDevice.model 只会返回 "iPhone"，机型要从 uname 拿。
    static let model: String = {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }()

    static var locale: String { Locale.current.identifier }
}

/// 后端账号。注册和登录是同一个接口：后端先尝试登录，失败就自动注册再登录，两边都会落日志。
/// Minus 是会员制不是积分制，所以响应里的 quota 刻意不解析、不使用。
@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var username = ""
    @Published private(set) var isReady = false
    /// 登录返回的 NewAPI key，反馈工单接口用它鉴权（auth_provider=newapi）。只留在内存里，每次启动重新登录获取
    private(set) var apiKey = ""

    private static let endpoint = URL(string: "https://text2image.site/v1/newapi/getToken")!
    /// 后端靠 deviceInfo 里的方括号标记归因注册渠道，缺了它会被算进文生图的用户。
    private static var deviceInfo: String {
        "[minus] iOS \(DeviceProfile.osVersion) \(DeviceProfile.model)"
    }

    private struct TokenResponse: Decodable {
        let code: Int
        let username: String?
        /// 后端同时返回 key 和 access_token，两者是同一个值
        let key: String?
        let accessToken: String?
        let error: String?

        private enum CodingKeys: String, CodingKey {
            case code, username, key, error
            case accessToken = "access_token"
        }
    }

    /// userID 复用 RevenueCat 的稳定用户 ID：后端拿它前 8 位当账号、后 16 位当密码，
    /// 和支付 webhook 里的 app_user_id 是同一个值，后端才能把人和订单对上。
    @discardableResult
    func start(userID: String) async -> Bool {
        guard !userID.isEmpty else { return false }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "userId": userID,
            "deviceInfo": Self.deviceInfo
        ])

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data),
              decoded.code == 200,
              let name = decoded.username, !name.isEmpty else {
            return false
        }

        username = name
        apiKey = decoded.key ?? decoded.accessToken ?? ""
        isReady = true
        // 后端的注册事件也按 username 聚合，这里对齐口径，两边数据才能拼起来。
        AnalyticsReporter.shared.setUserID(name)
        return true
    }
}

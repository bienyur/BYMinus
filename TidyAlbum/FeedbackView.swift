import SwiftUI
import UIKit

/// 反馈分类，取值与后端 ticketService 的 category 一致，未知值后端按 other 保存
enum FeedbackCategory: String, CaseIterable, Identifiable {
    case suggestion
    case experience
    case bug
    case other

    var id: String { rawValue }

    /// 工程用中文原文当本地化 key，取用时仍需显式走 L10n
    var title: String {
        switch self {
        case .suggestion: "功能建议"
        case .experience: "体验优化"
        case .bug: "问题反馈"
        case .other: "其他"
        }
    }

    var symbol: String {
        switch self {
        case .suggestion: "lightbulb.fill"
        case .experience: "wand.and.stars"
        case .bug: "ladybug.fill"
        case .other: "ellipsis.bubble.fill"
        }
    }

    var placeholder: String {
        switch self {
        case .suggestion: "希望 Minus 增加什么功能？"
        case .experience: "哪里用起来不顺手？"
        case .bug: "遇到了什么问题？怎么操作时出现的？"
        case .other: "想对我们说点什么？"
        }
    }

    init(serverValue: String?) {
        self = FeedbackCategory(rawValue: serverValue ?? "") ?? .other
    }
}

/// 工单会话里的一条消息。后端只下发展示字段，不含诊断上下文
struct FeedbackMessage: Identifiable, Equatable, Decodable {
    let id: String
    let role: String
    let category: String?
    let content: String
    let createdAt: String?

    var isFromUser: Bool { role == "user" }

    var date: Date? {
        guard let createdAt else { return nil }
        return Self.fractionalFormatter.date(from: createdAt) ?? Self.plainFormatter.date(from: createdAt)
    }

    // 后端用 toISOString()，带毫秒；兼容不带毫秒的旧记录
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plainFormatter = ISO8601DateFormatter()
}

/// 反馈与建议：复用后端的工单会话（/v1/ticket、/v1/ticket/messages），用登录拿到的 NewAPI key 鉴权。
/// 用户可以随时补充，不用等客服回复；频率和每日条数由后端限制，超限时返回中文原因直接展示。
/// 只收文字和可选联系方式，不上传截图，和“照片不出设备”的承诺保持一致
@MainActor
final class FeedbackStore: ObservableObject {
    @Published private(set) var messages: [FeedbackMessage] = []
    @Published private(set) var contact = ""
    @Published private(set) var isLoading = false
    @Published private(set) var isSubmitting = false
    /// 最近一次失败的原因，已经是可以直接给用户看的文案
    @Published var errorMessage: String?
    /// 有客服回复还没在反馈页里看过，设置页入口据此显示红点
    @Published private(set) var hasUnreadReply = false

    private static let ticketURL = URL(string: "https://text2image.site/v1/ticket")!
    private static let messagesURL = URL(string: "https://text2image.site/v1/ticket/messages")!
    private let defaults = UserDefaults.standard
    private var username = ""

    private struct TicketResponse: Decodable {
        struct Conversation: Decodable {
            let contact: String?
            let messages: [FeedbackMessage]
        }

        let code: Int
        let message: String?
        let data: Conversation?
    }

    /// 读取会话。silent 用在设置页静默检查新回复，失败时不打扰用户
    func refresh(account: AccountStore, silent: Bool = false) async {
        guard let auth = authBody(account) else {
            if !silent { errorMessage = L10n.text("账号还在准备中，请稍后再试") }
            return
        }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        switch await send(to: Self.ticketURL, body: auth) {
        case let .success(conversation):
            apply(conversation, username: account.username)
            if !silent { errorMessage = nil }
        case let .failure(message):
            if !silent { errorMessage = message }
        }
    }

    /// 提交一条反馈，成功返回 true。失败时保留输入内容，由调用方决定是否清空
    func submit(content: String, category: FeedbackCategory, contact: String, account: AccountStore) async -> Bool {
        guard let auth = authBody(account) else {
            errorMessage = L10n.text("账号还在准备中，请稍后再试")
            return false
        }
        guard !isSubmitting else { return false }
        isSubmitting = true
        defer { isSubmitting = false }

        var body = auth
        body["content"] = content
        body["category"] = category.rawValue
        body["contact"] = contact
        // 下面这些只进后台的诊断上下文，用户端读不到；不带设备名，避免把用户起的名字传上去
        body["app_key"] = "minus_ios"
        body["appVersion"] = DeviceProfile.appVersion
        body["buildVersion"] = DeviceProfile.buildVersion
        body["platform"] = "iOS"
        body["locale"] = AppLanguage.selected.resolvedIdentifier
        body["timezone"] = TimeZone.current.identifier
        body["deviceInfo"] = [
            "model": DeviceProfile.model,
            "systemName": "iOS",
            "systemVersion": DeviceProfile.osVersion
        ]

        switch await send(to: Self.messagesURL, body: body) {
        case let .success(conversation):
            apply(conversation, username: account.username)
            errorMessage = nil
            AnalyticsReporter.shared.track(.feedbackSubmit(category: category.rawValue))
            return true
        case let .failure(message):
            errorMessage = message
            return false
        }
    }

    /// 反馈页正在显示时调用：把最新一条客服回复记为已读
    func markRepliesRead(account: AccountStore) {
        guard let latest = messages.last(where: { !$0.isFromUser }) else { return }
        defaults.set(latest.id, forKey: Self.lastSeenKey(account.username))
        hasUnreadReply = false
    }

    private func apply(_ conversation: TicketResponse.Conversation, username: String) {
        // 换了账号就不能沿用上一个账号的会话和已读状态
        if username != self.username {
            self.username = username
            messages = []
        }
        messages = conversation.messages
        contact = conversation.contact ?? ""
        let latestReplyID = conversation.messages.last(where: { !$0.isFromUser })?.id
        hasUnreadReply = latestReplyID != nil && latestReplyID != defaults.string(forKey: Self.lastSeenKey(username))
    }

    /// 已读记录按用户名分开存
    private static func lastSeenKey(_ username: String) -> String {
        "tidyAlbum.feedback.lastSeenReply.\(username)"
    }

    private func authBody(_ account: AccountStore) -> [String: Any]? {
        guard account.isReady, !account.username.isEmpty, !account.apiKey.isEmpty else { return nil }
        return ["username": account.username, "token": account.apiKey, "auth_provider": "newapi"]
    }

    private enum SendResult {
        case success(TicketResponse.Conversation)
        case failure(String)
    }

    private func send(to url: URL, body: [String: Any]) async -> SendResult {
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure(L10n.text("请求失败，请稍后再试"))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = payload

        guard let (data, _) = try? await URLSession.shared.data(for: request) else {
            return .failure(L10n.text("网络连接失败，请检查网络后重试。"))
        }
        // 频率超限是 HTTP 429，但正文同样是 { code, message }，按业务 code 统一处理即可
        guard let decoded = try? JSONDecoder().decode(TicketResponse.self, from: data) else {
            return .failure(L10n.text("请求失败，请稍后再试"))
        }
        guard decoded.code == 200, let conversation = decoded.data else {
            // 后端的原因是中文写死的，英文界面下换成通用说明
            let reason = decoded.message ?? ""
            let usesServerReason = !reason.isEmpty && AppLanguage.selected.resolvedIdentifier.hasPrefix("zh")
            return .failure(usesServerReason ? reason : L10n.text("请求失败，请稍后再试"))
        }
        return .success(conversation)
    }
}

/// 设置页里“反馈与建议”的入口行，有新回复时在右侧显示红点和“有新回复”
struct FeedbackEntryRow: View {
    @EnvironmentObject private var feedback: FeedbackStore
    @EnvironmentObject private var account: AccountStore

    var body: some View {
        NavigationLink {
            FeedbackView()
        } label: {
            HStack {
                Label("反馈与建议", systemImage: "bubble.left.and.text.bubble.right")
                Spacer()
                if feedback.hasUnreadReply {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.tidyDanger)
                            .frame(width: 7, height: 7)
                        Text("有新回复")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.tidyMuted)
                    }
                }
            }
        }
        // 每次打开设置静默看一眼有没有新回复
        .task(id: account.isReady) {
            await feedback.refresh(account: account, silent: true)
        }
    }
}

/// 反馈与建议页：上面是和客服的对话，底部是输入区（分类、内容、选填联系方式）
struct FeedbackView: View {
    @EnvironmentObject private var feedback: FeedbackStore
    @EnvironmentObject private var account: AccountStore

    @State private var category: FeedbackCategory = .suggestion
    @State private var draft = ""
    @State private var contactDraft = ""
    @State private var didPrefillContact = false
    @State private var showsSentNotice = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case content
        case contact
    }

    private static let bottomID = "feedback-bottom"
    /// 后端单条上限 10000 字，这里留足余量，避免超长被截断
    private static let maxLength = 2000

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        !trimmedDraft.isEmpty && !feedback.isSubmitting && account.isReady
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    introCard

                    if feedback.isLoading && feedback.messages.isEmpty {
                        HStack {
                            Spacer()
                            ProgressView().tint(Color.tidyAccent)
                            Spacer()
                        }
                        .padding(.vertical, 24)
                    }

                    ForEach(feedback.messages) { message in
                        messageBubble(message)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomID)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable {
                await feedback.refresh(account: account)
            }
            .onChange(of: feedback.messages.count) { _ in
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
                feedback.markRepliesRead(account: account)
            }
            .onAppear {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        }
        .background(Color.tidyBackground.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer
        }
        .navigationTitle("反馈与建议")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: account.isReady) {
            await feedback.refresh(account: account)
            feedback.markRepliesRead(account: account)
            // 后端记着上次留的联系方式，进来先带上，用户不用每次重填
            if !didPrefillContact, !feedback.contact.isEmpty {
                contactDraft = feedback.contact
                didPrefillContact = true
            }
        }
        .animation(.easeInOut(duration: 0.2), value: feedback.errorMessage)
        .animation(.easeInOut(duration: 0.2), value: showsSentNotice)
    }

    // MARK: - 对话

    /// 顶部说明：没有任何对话时更大一些，当作空状态
    private var introCard: some View {
        let isEmpty = feedback.messages.isEmpty && !feedback.isLoading
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.tidyAccent)
                .frame(width: 40, height: 40)
                .background(Color.tidyAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(isEmpty ? "说说你的想法" : "我们会认真看每一条")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.tidyInk)
                Text("功能建议、体验问题都可以告诉我们。回复会出现在这里，你也可以随时继续补充。")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.tidyMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.tidySurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.tidyHairline, lineWidth: 1)
        }
    }

    /// 用户的消息靠右、柠檬色浅底并带分类；客服回复靠左、灰底并标“Minus 团队”
    private func messageBubble(_ message: FeedbackMessage) -> some View {
        let isUser = message.isFromUser

        return HStack {
            if isUser { Spacer(minLength: 48) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if isUser {
                        let category = FeedbackCategory(serverValue: message.category)
                        Label(L10n.text(category.title), systemImage: category.symbol)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.tidyAccent)
                    } else {
                        Label("Minus 团队", systemImage: "checkmark.seal.fill")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.tidyKeep)
                    }
                    if let date = message.date {
                        Text(L10n.date(date, template: "MMMdjm"))
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.tidyMuted)
                    }
                }

                Text(message.content)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.tidyInk)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        isUser ? Color.tidyAccent.opacity(0.14) : Color.tidySurface,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(isUser ? Color.tidyAccent.opacity(0.22) : Color.tidyHairline, lineWidth: 1)
                    }
            }

            if !isUser { Spacer(minLength: 48) }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - 输入区

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = feedback.errorMessage {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tidyDanger)
                    .transition(.opacity)
            } else if showsSentNotice {
                Label("已收到，感谢你的反馈", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tidyKeep)
                    .transition(.opacity)
            }

            categoryPicker

            HStack(alignment: .bottom, spacing: 10) {
                VStack(spacing: 0) {
                    // placeholder 是纯 String，不会自动查表，必须显式走 L10n
                    TextField(L10n.text(category.placeholder), text: $draft, axis: .vertical)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .lineLimit(1...6)
                        .focused($focusedField, equals: .content)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .onChange(of: draft) { value in
                            if value.count > Self.maxLength {
                                draft = String(value.prefix(Self.maxLength))
                            }
                        }

                    // 写了内容才露出联系方式，平时输入区保持紧凑
                    if !trimmedDraft.isEmpty || !contactDraft.isEmpty {
                        Divider().overlay(Color.tidyHairline)
                        TextField(L10n.text("联系方式（选填，方便我们回访）"), text: $contactDraft)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .contact)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                    }
                }
                .background(Color.tidySurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(focusedField == nil ? Color.tidyHairline : Color.tidyAccent.opacity(0.5), lineWidth: 1)
                }

                Button(action: submit) {
                    Group {
                        if feedback.isSubmitting {
                            ProgressView().tint(Color.tidyOnAccent)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 17, weight: .black))
                        }
                    }
                    .foregroundStyle(Color.tidyOnAccent)
                    .frame(width: 44, height: 44)
                    .background(canSend || feedback.isSubmitting ? Color.tidyAccent : Color.tidyElevated, in: Circle())
                }
                .disabled(!canSend)
                .accessibilityLabel("发送")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
        .animation(.easeInOut(duration: 0.2), value: trimmedDraft.isEmpty)
    }

    /// 四个分类横排，选中的高亮；切换后输入框的提示语跟着变
    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(FeedbackCategory.allCases) { item in
                    let isSelected = item == category
                    Button {
                        category = item
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        Label(L10n.text(item.title), systemImage: item.symbol)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(isSelected ? Color.tidyOnAccent : Color.tidyInk)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .background(isSelected ? Color.tidyAccent : Color.tidySurface, in: Capsule())
                            .overlay {
                                Capsule().stroke(isSelected ? Color.clear : Color.tidyHairline, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
        .disabled(feedback.isSubmitting)
    }

    private func submit() {
        let content = trimmedDraft
        guard !content.isEmpty else { return }
        let contact = contactDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let success = await feedback.submit(content: content, category: category, contact: contact, account: account)
            guard success else { return }
            draft = ""
            focusedField = nil
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            showsSentNotice = true
            try? await Task.sleep(for: .seconds(2.5))
            showsSentNotice = false
        }
    }
}

import SwiftUI

struct PaywallView: View {
    /// 付费墙入口来源，用于后端漏斗分析
    var entryReason: String = "unknown"

    @EnvironmentObject private var purchaseStore: PurchaseStore
    @EnvironmentObject private var remoteConfig: RemoteConfigStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPlanID: String?

    private let privacyURL = URL(string: "https://text2image.site/minus.html#privacy-policy")!
    private let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    hero
                    benefits
                    plans
                    accountCard
                    legalText
                }
                .frame(maxWidth: 720)
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 130)
                .frame(maxWidth: .infinity)
            }
            .background(Color.tidyBackground.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                purchaseBar
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                        .foregroundStyle(Color.tidyInk)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await purchaseStore.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .foregroundStyle(Color.tidyAccent)
                    .disabled(purchaseStore.isLoading || purchaseStore.isPurchasing)
                }
            }
            .task {
                AnalyticsReporter.shared.track(.paywallView(entryReason: entryReason))
                if purchaseStore.userID.isEmpty {
                    await purchaseStore.start()
                } else {
                    await purchaseStore.refresh()
                }
            }
            // 方案来自后台 metadata，列表刷新后重新校准选中项。
            .onAppear { selectAvailablePlan(from: purchaseStore.plans) }
            .onChange(of: purchaseStore.plans) { plans in
                selectAvailablePlan(from: plans)
            }
        }
    }

    private func selectAvailablePlan(from plans: [PaywallPlan]) {
        guard !plans.contains(where: { $0.id == selectedPlanID }) else { return }
        selectedPlanID = (plans.first { $0.isRecommended } ?? plans.first)?.id
    }

    /// 当前选中的方案；metadata 未配置时为 nil，此时不允许购买。
    private var selectedPlan: PaywallPlan? {
        purchaseStore.plans.first { $0.id == selectedPlanID }
    }

    /// 只有商店配置了免费试用且当前用户符合资格时才有值。
    private var selectedTrialDays: Int? {
        guard let selectedPlan else { return nil }
        return purchaseStore.eligibleFreeTrialDays(for: selectedPlan)
    }

    private var hero: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.tidyAccent.opacity(0.13))
                    .frame(width: 90, height: 90)
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(Color.tidyAccent)
            }

            Text(purchaseStore.isPro ? L10n.text("Minus Pro 已解锁") : L10n.text("无限整理你的相册"))
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.tidyInk)
                .multilineTextAlignment(.center)

            Text("保留所有本机隐私能力，解锁不限数量与空间的确认删除。")
                .font(.subheadline)
                .foregroundStyle(Color.tidyMuted)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 12)
    }

    private var benefits: some View {
        VStack(spacing: 0) {
            benefitRow(symbol: "infinity", title: "无限整理", detail: "不受免费 20 张或 100 MB 限制")
            Divider().overlay(Color.tidyHairline).padding(.leading, 54)
            benefitRow(symbol: "square.stack.3d.up.fill", title: "全部智能分组", detail: "持续使用重复、截图、连拍与相似照片分析")
            Divider().overlay(Color.tidyHairline).padding(.leading, 54)
            benefitRow(symbol: "lock.shield.fill", title: "100% 本机处理", detail: "照片分析不上传，不接触你的原图内容")
        }
        .background(Color.tidySurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.tidyHairline, lineWidth: 1)
        }
    }

    private func benefitRow(symbol: String, title: String, detail: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.tidyAccent)
                .frame(width: 34, height: 34)
                .background(Color.tidyAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text(title))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.tidyInk)
                Text(L10n.text(detail))
                    .font(.caption)
                    .foregroundStyle(Color.tidyMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var plans: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择方案")
                .font(.headline)
                .foregroundStyle(Color.tidyInk)

            if purchaseStore.plans.isEmpty {
                emptyPlansPlaceholder
            } else {
                ForEach(purchaseStore.plans) { plan in
                    planRow(plan)
                }
            }
        }
    }

    private func planRow(_ plan: PaywallPlan) -> some View {
        let isSelected = selectedPlanID == plan.id
        // 购买中的那一行用转圈替代选中图标，覆盖系统支付弹窗出现前的空档。
        let isBusy = isSelected && purchaseStore.isPurchasing
        let freeTrialDays = purchaseStore.eligibleFreeTrialDays(for: plan)
        let badgeText = freeTrialDays == nil ? plan.badgeText : L10n.text("免费试用")
        let subtitleText = freeTrialDays.map { plan.trialRenewalText(days: $0) } ?? plan.subtitleText

        return Button {
            startPurchase(plan)
        } label: {
            HStack(spacing: 14) {
                Group {
                    if isBusy {
                        ProgressView().tint(Color.tidyAccent)
                    } else {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(isSelected ? Color.tidyAccent : Color.tidyMuted)
                    }
                }
                .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(plan.titleText)
                            .font(.headline)
                            .foregroundStyle(Color.tidyInk)
                            // 价格很长的地区宁可标题缩一点，也不要把角标挤成两行
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        if let badge = badgeText {
                            Text(badge)
                                .font(.caption2.weight(.heavy))
                                .foregroundStyle(Color.tidyOnAccent)
                                .lineLimit(1)
                                // 角标按内容取足宽度、不参与压缩，否则「Recommended」会换行
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.tidyAccent, in: Capsule())
                        }
                    }
                    if !subtitleText.isEmpty {
                        Text(subtitleText)
                            .font(.caption)
                            .foregroundStyle(Color.tidyMuted)
                    }
                }

                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    if let originalPrice = plan.originalPriceText {
                        Text(originalPrice)
                            .font(.caption)
                            .strikethrough()
                            .foregroundStyle(Color.tidyMuted)
                            .lineLimit(1)
                    }
                    // 价格是关键信息，货币符号长的地区宁可轻微缩字也不能换行
                    Text(plan.priceText)
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(Color.tidyInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .padding(16)
            .background(
                isSelected ? Color.tidyElevated : Color.tidySurface,
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(isSelected ? Color.tidyAccent : Color.tidyHairline, lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(purchaseStore.isPro || purchaseStore.isPurchasing)
    }

    /// 选中方案并立即拉起支付；底部按钮与方案行共用这条路径。
    private func startPurchase(_ plan: PaywallPlan) {
        guard purchaseStore.isConfigured, !purchaseStore.isPro, !purchaseStore.isPurchasing else { return }
        selectedPlanID = plan.id
        AnalyticsReporter.shared.track(.paywallContinue(entryReason: entryReason))
        Task {
            if await purchaseStore.purchase(plan) {
                dismiss()
            }
        }
    }

    private var emptyPlansPlaceholder: some View {
        HStack(spacing: 12) {
            if purchaseStore.isLoading {
                ProgressView().tint(Color.tidyAccent)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.tidyMuted)
            }
            Text(
                purchaseStore.isLoading
                    ? L10n.text("正在获取方案…")
                    : L10n.text("暂时无法获取会员方案，请稍后重试。")
            )
                .font(.subheadline)
                .foregroundStyle(Color.tidyMuted)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color.tidySurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.tidyHairline, lineWidth: 1)
        }
    }

    private var accountCard: some View {
        VStack(spacing: 12) {
            HStack {
                Label(purchaseStore.membershipLabel, systemImage: purchaseStore.isPro ? "checkmark.seal.fill" : "person.crop.circle")
                    .foregroundStyle(purchaseStore.isPro ? Color.tidyAccent : Color.tidyInk)
                Spacer()
                Text(purchaseStore.displayUserID)
                    .font(.caption.monospaced())
                    .foregroundStyle(Color.tidyMuted)
            }

            // 恢复购买是全局唯一入口，可由远程配置关闭
            if remoteConfig.config.purchase.restoreEnabled {
                Divider().overlay(Color.tidyHairline)

                Button {
                    Task { _ = await purchaseStore.restorePurchases() }
                } label: {
                    HStack {
                        Text("恢复购买")
                        Spacer()
                        if purchaseStore.isPurchasing {
                            ProgressView().tint(Color.tidyAccent)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .foregroundStyle(Color.tidyAccent)
                }
                .disabled(purchaseStore.isPurchasing)
            }

            if !purchaseStore.statusMessage.isEmpty {
                Text(purchaseStore.statusMessage)
                    .font(.caption)
                    .foregroundStyle(purchaseStore.isPro ? Color.tidyKeep : Color.tidyMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(Color.tidySurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.tidyHairline, lineWidth: 1)
        }
    }

    private var legalText: some View {
        VStack(spacing: 8) {
            Text(legalDescription)
                .font(.caption2)
                .foregroundStyle(Color.tidyMuted)
                .multilineTextAlignment(.center)

            HStack(spacing: 18) {
                Link("隐私政策", destination: privacyURL)
                Link("使用条款", destination: termsURL)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.tidyAccent)
        }
    }

    private var legalDescription: String {
        let hasEligibleTrial = purchaseStore.plans.contains {
            purchaseStore.eligibleFreeTrialDays(for: $0) != nil
        }
        if hasEligibleTrial {
            return L10n.text("符合资格的新用户选择年会员可享免费试用；试用结束后按年费自动续订，除非提前取消。月会员和年会员均可在 Apple ID 订阅中取消；永久解锁为一次性购买。")
        }
        return L10n.text("月会员和年会员会自动续订，可随时在 Apple ID 订阅中取消；永久解锁为一次性购买。付款将由 Apple 处理。")
    }

    private var purchaseTitle: String {
        if purchaseStore.isPro { return L10n.text("已解锁 Minus Pro") }
        guard let plan = selectedPlan else { return L10n.text("暂无可购买方案") }
        if selectedTrialDays != nil {
            return L10n.text("开始免费试用")
        }
        return L10n.format("继续 · %@", plan.priceText)
    }

    private var purchaseFootnote: String {
        if let plan = selectedPlan, let days = selectedTrialDays {
            return plan.trialRenewalText(days: days)
        }
        return L10n.text("实际价格与币种以 App Store 付款页面为准")
    }

    private var purchaseBar: some View {
        VStack(spacing: 8) {
            Button {
                guard let plan = selectedPlan else { return }
                startPurchase(plan)
            } label: {
                HStack(spacing: 9) {
                    if purchaseStore.isPurchasing {
                        ProgressView().tint(Color.tidyOnAccent)
                    } else {
                        Image(
                            systemName: purchaseStore.isPro
                                ? "checkmark.seal.fill"
                                : (selectedTrialDays == nil ? "lock.open.fill" : "gift.fill")
                        )
                    }
                    Text(purchaseTitle)
                        .fontWeight(.heavy)
                }
                .foregroundStyle(Color.tidyOnAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Color.tidyAccent, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .disabled(purchaseStore.isPro || purchaseStore.isPurchasing || !purchaseStore.isConfigured || selectedPlan == nil)
            .opacity((purchaseStore.isPro || (purchaseStore.isConfigured && selectedPlan != nil)) ? 1 : 0.5)

            Text(purchaseFootnote)
                .font(.caption2)
                .foregroundStyle(Color.tidyMuted)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }
}

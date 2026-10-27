import SwiftUI

enum OnboardingPreference {
    static let completionKey = "tidyAlbum.hasCompletedOnboarding"
}

struct OnboardingView: View {
    let onComplete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedPage = 0

    private let pages = OnboardingPage.allCases

    var body: some View {
        GeometryReader { proxy in
            let isRegular = proxy.size.width >= 700

            VStack(spacing: 0) {
                header(isRegular: isRegular)

                TabView(selection: $selectedPage) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                        OnboardingPageView(
                            page: page,
                            availableHeight: proxy.size.height,
                            availableWidth: proxy.size.width
                        )
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                footer(isRegular: isRegular)
                    .frame(maxWidth: isRegular ? 640 : .infinity)
            }
            .frame(maxWidth: isRegular ? 900 : .infinity)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, isRegular ? 44 : 22)
            .padding(.top, max(proxy.safeAreaInsets.top, 10))
            .padding(.bottom, max(proxy.safeAreaInsets.bottom, isRegular ? 24 : 14))
        }
        .background {
            ZStack {
                Color.tidyBackground
                RadialGradient(
                    colors: [Color.tidyAccent.opacity(0.11), .clear],
                    center: .topTrailing,
                    startRadius: 10,
                    endRadius: 360
                )
            }
            .ignoresSafeArea()
        }
        .animation(
            reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.86),
            value: selectedPage
        )
    }

    private func header(isRegular: Bool) -> some View {
        HStack {
            HStack(spacing: isRegular ? 12 : 9) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: isRegular ? 19 : 15, weight: .black))
                    .foregroundStyle(Color.tidyOnAccent)
                    .frame(width: isRegular ? 42 : 32, height: isRegular ? 42 : 32)
                    .background(Color.tidyAccent, in: RoundedRectangle(cornerRadius: isRegular ? 13 : 10, style: .continuous))

                Text("Minus")
                    .font(.system(size: isRegular ? 24 : 19, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tidyInk)
            }

            Spacer()

            Button("跳过", action: completeWithoutRequestingAccess)
                .font(.system(size: isRegular ? 16 : 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.tidyMuted)
                .padding(.horizontal, isRegular ? 18 : 14)
                .frame(height: isRegular ? 46 : 38)
                .background(Color.tidySurface, in: Capsule())
        }
        .frame(height: isRegular ? 62 : 48)
    }

    private func footer(isRegular: Bool) -> some View {
        VStack(spacing: isRegular ? 20 : 16) {
            HStack(spacing: isRegular ? 9 : 7) {
                ForEach(pages.indices, id: \.self) { index in
                    Capsule()
                        .fill(index == selectedPage ? Color.tidyAccent : Color.tidyHairline)
                        .frame(
                            width: index == selectedPage ? (isRegular ? 32 : 24) : (isRegular ? 9 : 7),
                            height: isRegular ? 9 : 7
                        )
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.format("第 %lld 页，共 %lld 页", selectedPage + 1, pages.count))

            HStack(spacing: 12) {
                if selectedPage > 0 {
                    Button(action: showPreviousPage) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: isRegular ? 19 : 16, weight: .bold))
                            .foregroundStyle(Color.tidyInk)
                            .frame(width: isRegular ? 64 : 52, height: isRegular ? 64 : 54)
                            .background(Color.tidySurface, in: RoundedRectangle(cornerRadius: isRegular ? 21 : 18, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: isRegular ? 21 : 18, style: .continuous)
                                    .stroke(Color.tidyHairline, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("上一页")
                }

                Button(action: primaryAction) {
                    HStack(spacing: 9) {
                        Text(primaryButtonTitle)
                        Image(systemName: isLastPage ? "checkmark" : "arrow.right")
                    }
                    .font(.system(size: isRegular ? 19 : 16, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tidyOnAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: isRegular ? 64 : 54)
                    .background(Color.tidyAccent, in: RoundedRectangle(cornerRadius: isRegular ? 21 : 18, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Text(footerNotice)
                .font(.system(size: isRegular ? 13 : 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.tidyMuted)
                .multilineTextAlignment(.center)
                .frame(minHeight: 14)
        }
    }

    private var isLastPage: Bool {
        selectedPage == pages.count - 1
    }

    private var primaryButtonTitle: String {
        guard isLastPage else { return L10n.text("继续") }
        return L10n.text("开始使用")
    }

    private var footerNotice: String {
        if isLastPage {
            return L10n.text("照片和分析结果都留在这台设备上")
        }
        return L10n.text("左右滑动也可切换引导页")
    }

    private func primaryAction() {
        guard isLastPage else {
            showNextPage()
            return
        }

        // 引导只介绍产品，不弹系统权限框。用户在首页选择连接相册时，
        // 再由 iOS 提供真正的权限选择。
        onComplete()
    }

    private func showNextPage() {
        guard selectedPage < pages.count - 1 else { return }
        selectedPage += 1
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func showPreviousPage() {
        guard selectedPage > 0 else { return }
        selectedPage -= 1
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func completeWithoutRequestingAccess() {
        onComplete()
    }
}

private enum OnboardingPage: Int, CaseIterable, Identifiable {
    case welcome
    case swipe
    case groups
    case privacy

    var id: Int { rawValue }

    var eyebrow: String {
        switch self {
        case .welcome: L10n.text("轻松整理")
        case .swipe: L10n.text("滑动决策")
        case .groups: L10n.text("智能分组")
        case .privacy: L10n.text("隐私优先")
        }
    }

    var title: String {
        switch self {
        case .welcome: L10n.text("把相册里的\n多余减掉")
        case .swipe: L10n.text("一滑一留，\n决定更快")
        case .groups: L10n.text("相似照片，\n放在一起选")
        case .privacy: L10n.text("整个过程，\n只在本机完成")
        }
    }

    var subtitle: String {
        switch self {
        case .welcome: L10n.text("Minus 帮你逐张做决定，保留真正值得的回忆。")
        case .swipe: L10n.text("左滑加入待删除，右滑保留。所有删除都会先等你统一确认。")
        case .groups: L10n.text("截图、完全相同和连拍照片会自动归类，对比后再处理。")
        case .privacy: L10n.text("使用 PhotoKit 和 Vision 在设备上读取与分析，不上传照片，不跟踪整理行为。")
        }
    }
}

private struct OnboardingPageView: View {
    let page: OnboardingPage
    let availableHeight: CGFloat
    let availableWidth: CGFloat

    var body: some View {
        let isRegular = availableWidth >= 700
        let isExpansive = isRegular && availableHeight >= 900

        VStack(spacing: 0) {
            Spacer(minLength: isRegular ? 16 : 8)

            OnboardingArtwork(page: page, isRegular: isRegular)
                .frame(
                    height: isExpansive
                        ? min(max(availableHeight * 0.41, 410), 520)
                        : (isRegular ? min(max(availableHeight * 0.36, 310), 390) : min(max(availableHeight * 0.36, 230), 330))
                )

            Spacer(minLength: isRegular ? 30 : 22)

            VStack(spacing: isRegular ? 18 : 14) {
                Text(page.eyebrow.uppercased())
                    .font(.system(size: isRegular ? 15 : 12, weight: .black, design: .rounded))
                    .tracking(isRegular ? 2.8 : 2.2)
                    .foregroundStyle(Color.tidyAccent)

                Text(page.title)
                    .font(.system(size: isExpansive ? 46 : (isRegular ? 39 : (availableHeight < 700 ? 30 : 34)), weight: .bold, design: .rounded))
                    .tracking(-0.7)
                    .foregroundStyle(Color.tidyInk)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)

                Text(page.subtitle)
                    .font(.system(size: isRegular ? 18 : 15, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.tidyMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)
                    .frame(maxWidth: isRegular ? 540 : 330)
            }

            Spacer(minLength: isRegular ? 30 : 22)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct OnboardingArtwork: View {
    let page: OnboardingPage
    let isRegular: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(Color.tidySurface)
                .overlay {
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .stroke(Color.tidyHairline, lineWidth: 1)
                }

            Group {
                switch page {
                case .welcome:
                    welcomeArtwork
                case .swipe:
                    swipeArtwork
                case .groups:
                    groupsArtwork
                case .privacy:
                    privacyArtwork
                }
            }
            .scaleEffect(isRegular ? 1.38 : 1)
        }
        .frame(maxWidth: isRegular ? 620 : 390)
        .shadow(color: Color.black.opacity(0.20), radius: 26, y: 16)
    }

    private var welcomeArtwork: some View {
        ZStack {
            onboardingCard(imageName: "SampleCity")
                .rotationEffect(.degrees(-11))
                .offset(x: -54, y: 8)
            onboardingCard(imageName: "SampleBreakfast")
                .rotationEffect(.degrees(11))
                .offset(x: 54, y: 8)
            onboardingCard(imageName: "SampleLake")
                .offset(y: -8)
        }
    }

    private var swipeArtwork: some View {
        ZStack {
            Image("SampleCoast")
                .resizable()
                .scaledToFill()
                .frame(width: 156, height: 204)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.54)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .overlay(alignment: .bottomLeading) {
                        Text("海岸公路 · 17:42")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(12)
                    }
                }
                .shadow(color: Color.black.opacity(0.20), radius: 18, y: 10)

            decisionCircle(symbol: "xmark", tint: .tidyDanger)
                .offset(x: -112, y: 70)
            decisionCircle(symbol: "checkmark", tint: .tidyKeep)
                .offset(x: 112, y: 70)

            HStack(spacing: 36) {
                Image(systemName: "arrow.left")
                Image(systemName: "arrow.right")
            }
            .font(.system(size: 18, weight: .black))
            .foregroundStyle(Color.tidyMuted)
            .offset(y: -104)
        }
    }

    private var groupsArtwork: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                groupTile(imageName: "SampleFlowers", symbol: "square.on.square", title: "重复", color: .tidyAccent)
                groupTile(imageName: "SampleCoast", symbol: "rectangle.stack", title: "连拍", color: .tidyCyan)
            }
            HStack(spacing: 12) {
                groupTile(imageName: "SampleBreakfast", symbol: "iphone", title: "截图", color: .tidyViolet)
                groupTile(imageName: "SampleCat", symbol: "eye", title: "相似", color: .tidyAmber)
            }
        }
    }

    private var privacyArtwork: some View {
        ZStack {
            Circle()
                .fill(Color.tidyAccent.opacity(0.12))
                .frame(width: 190, height: 190)
            Circle()
                .stroke(Color.tidyAccent.opacity(0.24), lineWidth: 1)
                .frame(width: 230, height: 230)

            Image(systemName: "iphone.gen3")
                .font(.system(size: 116, weight: .light))
                .foregroundStyle(Color.tidyInk)

            Image(systemName: "lock.fill")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Color.tidyOnAccent)
                .frame(width: 62, height: 62)
                .background(Color.tidyAccent, in: Circle())
                .overlay(Circle().stroke(Color.tidyBackground, lineWidth: 5))
                .offset(x: 56, y: 68)
        }
    }

    private func onboardingCard(imageName: String) -> some View {
        Image(imageName)
            .resizable()
            .scaledToFill()
            .frame(width: 126, height: 174)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.22), radius: 16, y: 10)
    }

    private func decisionCircle(symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 23, weight: .black))
            .foregroundStyle(tint)
            .frame(width: 58, height: 58)
            .background(Color.tidyElevated, in: Circle())
            .overlay(Circle().stroke(tint.opacity(0.4), lineWidth: 2))
    }

    private func groupTile(imageName: String, symbol: String, title: String, color: Color) -> some View {
        ZStack(alignment: .bottomLeading) {
            Image(imageName)
                .resizable()
                .scaledToFill()

            LinearGradient(
                colors: [.clear, .black.opacity(0.68)],
                startPoint: .center,
                endPoint: .bottom
            )

            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(color)
                // title 是纯 String，不会自动查表，必须显式走 L10n 才能跟着语言切换
                Text(L10n.text(title))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .padding(10)
        }
        .frame(width: 116, height: 92)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(color.opacity(0.22), lineWidth: 1)
        }
    }
}

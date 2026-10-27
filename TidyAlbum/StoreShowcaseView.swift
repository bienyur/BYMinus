import SwiftUI

/// 专为 App Store 宣传截图准备的全屏应用说明。
/// 不读取用户照片，避免制作商店素材时泄露隐私。
struct StoreShowcaseView: View {
    let onClose: () -> Void

    @State private var selectedPage = 0
    @State private var showsControls = true
    @State private var controlRevision = 0

    private let pages = StoreShowcasePage.allCases

    var body: some View {
        ZStack {
            TabView(selection: $selectedPage) {
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                    StoreShowcasePageView(page: page, pageNumber: index + 1)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea(.container, edges: [.top, .bottom])

            controls
                .opacity(showsControls ? 1 : 0)
                .allowsHitTesting(showsControls)
        }
        .background(Color.tidyBackground.ignoresSafeArea())
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .simultaneousGesture(
            TapGesture().onEnded {
                if showsControls {
                    withAnimation(.easeOut(duration: 0.18)) { showsControls = false }
                } else {
                    revealControlsTemporarily()
                }
            }
        )
        .onChange(of: selectedPage) { _ in
            UISelectionFeedbackGenerator().selectionChanged()
            revealControlsTemporarily()
        }
        .task(id: controlRevision) {
            guard showsControls else { return }
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.28)) { showsControls = false }
        }
        // 商店截图使用整块设备画布，不保留状态栏与 Home Indicator 区域。
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }

    private var controls: some View {
        VStack {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.tidyInk)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("退出商店截图模式")

                Spacer()

                Text("等待控件隐藏后截图")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tidyInk)
                    .padding(.horizontal, 13)
                    .frame(height: 36)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)

            Spacer()

            HStack(spacing: 14) {
                showcaseArrow(symbol: "chevron.left", isEnabled: selectedPage > 0) {
                    selectedPage -= 1
                }

                Text("\(selectedPage + 1) / \(pages.count)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tidyInk)
                    .frame(width: 64, height: 42)
                    .background(.ultraThinMaterial, in: Capsule())

                showcaseArrow(symbol: "chevron.right", isEnabled: selectedPage < pages.count - 1) {
                    selectedPage += 1
                }
            }
            .padding(.bottom, 14)
        }
    }

    private func showcaseArrow(symbol: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.tidyInk)
                .frame(width: 42, height: 42)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.3)
        .disabled(!isEnabled)
    }

    private func revealControlsTemporarily() {
        withAnimation(.easeIn(duration: 0.18)) { showsControls = true }
        controlRevision += 1
    }
}

private enum StoreShowcasePage: Int, CaseIterable, Identifiable {
    case swipe
    case groups
    case pending
    case progress
    case privacy

    var id: Int { rawValue }

    var eyebrow: String {
        switch self {
        case .swipe: L10n.text("滑动整理")
        case .groups: L10n.text("智能分组")
        case .pending: L10n.text("删除前确认")
        case .progress: L10n.text("整理战绩")
        case .privacy: L10n.text("100% 隐私")
        }
    }

    var title: String {
        switch self {
        case .swipe: L10n.text("滑几下，\n相册就清爽了")
        case .groups: L10n.text("难选的照片，\n放在一起比")
        case .pending: L10n.text("所有删除，\n都留一次反悔")
        case .progress: L10n.text("每一次整理，\n都看得见")
        case .privacy: L10n.text("你的照片，\n只属于你")
        }
    }

    var subtitle: String {
        switch self {
        case .swipe: L10n.text("左滑删除 · 右滑保留")
        case .groups: L10n.text("重复、截图、连拍和相似照片自动归类")
        case .pending: L10n.text("先放入待删除，统一确认后才生效")
        case .progress: L10n.text("进度、释放空间和月度记录一目了然")
        case .privacy: L10n.text("PhotoKit + Vision 全部在设备上完成")
        }
    }

    var accent: Color {
        switch self {
        case .swipe: .tidyAccent
        case .groups: .tidyCyan
        case .pending: .tidyDanger
        case .progress: .tidyViolet
        case .privacy: .tidyKeep
        }
    }
}

private struct StoreShowcasePageView: View {
    let page: StoreShowcasePage
    let pageNumber: Int

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 730
            let isRegular = proxy.size.width >= 700
            let isExpansive = isRegular && proxy.size.height >= 900

            VStack(spacing: 0) {
                brandHeader(isRegular: isRegular)
                    // 不借用安全区留白，同时放到左上角避开灵动岛的实体遮挡。
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, isRegular ? 44 : 24)
                    .padding(.top, isRegular ? 28 : (compact ? 14 : 18))

                VStack(spacing: isRegular ? 18 : (compact ? 10 : 14)) {
                    Text(page.eyebrow)
                        .font(.system(size: isRegular ? 15 : 12, weight: .black, design: .rounded))
                        .tracking(isRegular ? 2.8 : 2.2)
                        .foregroundStyle(page.accent)

                    Text(page.title)
                        .font(.system(size: isExpansive ? 54 : (isRegular ? 45 : (compact ? 32 : 38)), weight: .bold, design: .rounded))
                        .tracking(isRegular ? -1.5 : -1.1)
                        .foregroundStyle(Color.tidyInk)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)

                    Text(page.subtitle)
                        .font(.system(size: isRegular ? 18 : (compact ? 13 : 15), weight: .medium, design: .rounded))
                        .foregroundStyle(Color.tidyMuted)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .frame(maxWidth: isRegular ? 560 : 340)
                }
                .padding(.top, isRegular ? 36 : (compact ? 22 : 30))

                StoreFeatureArtwork(page: page, compact: compact, isRegular: isRegular)
                    .padding(.top, isRegular ? 34 : (compact ? 18 : 28))
                    .padding(.horizontal, isRegular ? 56 : 22)
                    .frame(maxHeight: .infinity)

                HStack(spacing: 7) {
                    Image(systemName: page == .privacy ? "lock.fill" : "sparkles")
                    Text(footerText)
                }
                .font(.system(size: isRegular ? 14 : 11, weight: .bold, design: .rounded))
                .foregroundStyle(page.accent)
                .padding(.horizontal, isRegular ? 19 : 14)
                .frame(height: isRegular ? 46 : 36)
                .background(page.accent.opacity(0.10), in: Capsule())
                .padding(.bottom, isRegular ? 32 : (compact ? 14 : 20))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                ZStack {
                    Color.tidyBackground
                    RadialGradient(
                        colors: [page.accent.opacity(0.15), .clear],
                        center: .bottom,
                        startRadius: 20,
                        endRadius: proxy.size.height * 0.72
                    )
                }
                .ignoresSafeArea()
            }
            .ignoresSafeArea(.container, edges: [.top, .bottom])
        }
    }

    private func brandHeader(isRegular: Bool) -> some View {
        HStack(spacing: isRegular ? 12 : 9) {
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: isRegular ? 18 : 14, weight: .black))
                .foregroundStyle(Color.tidyOnAccent)
                .frame(width: isRegular ? 40 : 30, height: isRegular ? 40 : 30)
                .background(Color.tidyAccent, in: RoundedRectangle(cornerRadius: isRegular ? 12 : 9, style: .continuous))

            Text("MINUS")
                .font(.system(size: isRegular ? 19 : 15, weight: .black, design: .rounded))
                .tracking(isRegular ? 1.9 : 1.5)
                .foregroundStyle(Color.tidyInk)

            Capsule()
                .fill(Color.tidyHairline)
                .frame(width: isRegular ? 34 : 24, height: 1)

            Text(String(format: "%02d", pageNumber))
                .font(.system(size: isRegular ? 15 : 12, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.tidyMuted)
        }
    }

    private var footerText: String {
        switch page {
        case .swipe: L10n.text("保留原图和编辑记录")
        case .groups: L10n.text("先对比，再做决定")
        case .pending: L10n.text("真正删除前再次确认")
        case .progress: L10n.text("清理成果持续累积")
        case .privacy: L10n.text("无服务器 · 无跟踪 · 无第三方 SDK")
        }
    }
}

private struct StoreFeatureArtwork: View {
    let page: StoreShowcasePage
    let compact: Bool
    let isRegular: Bool

    var body: some View {
        Group {
            switch page {
            case .swipe: swipePreview
            case .groups: groupsPreview
            case .pending: pendingPreview
            case .progress: progressPreview
            case .privacy: privacyPreview
            }
        }
        .frame(
            maxWidth: isRegular ? 640 : 390,
            maxHeight: isRegular ? (compact ? 500 : 700) : (compact ? 390 : 480)
        )
    }

    private var swipePreview: some View {
        VStack(spacing: isRegular ? 28 : 18) {
            ZStack {
                StorePhotoCard(imageName: "SampleCity")
                    .rotationEffect(.degrees(5))
                    .offset(x: 12, y: 8)
                    .opacity(0.45)

                StorePhotoCard(imageName: "SampleLake")
                    .overlay(alignment: .topLeading) {
                        Text("今天 · 15:42")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(12)
                    }
            }
            .frame(maxHeight: .infinity)
            // 旋转后的后层卡片会超出 SwiftUI 按旋转前尺寸计算的布局边界。
            // iPad 卡片更高、旋转后的横向外扩更大，因此按设备宽度分别预留绘制余量。
            .padding(.horizontal, isRegular ? 28 : 14)

            HStack {
                storeDecisionButton(symbol: "xmark", title: "删除", color: .tidyDanger)
                Spacer()
                storeDecisionButton(symbol: "checkmark", title: "保留", color: .tidyKeep)
            }
            .padding(.horizontal, isRegular ? 70 : 30)
        }
    }

    private var groupsPreview: some View {
        VStack(spacing: isRegular ? 18 : 12) {
            StorePanelHeader(title: "智能分组", detail: "4 个类别", isRegular: isRegular)

            storeGroupRow(
                title: "完全相同",
                detail: "12 组 · 38 张",
                tint: .tidyAccent,
                symbol: "square.on.square",
                photoNames: ["SampleFlowers", "SampleFlowers", "SampleFlowers"]
            )
            storeGroupRow(
                title: "截图",
                detail: "763 张",
                tint: .tidyViolet,
                symbol: "iphone",
                photoNames: ["SampleCity", "SampleBreakfast", "SampleCoast"]
            )
            storeGroupRow(
                title: "连拍",
                detail: "8 组 · 46 张",
                tint: .tidyCyan,
                symbol: "rectangle.stack",
                photoNames: ["SampleCat", "SampleCat", "SampleCat"]
            )
            storeGroupRow(
                title: "视觉相似",
                detail: "21 组",
                tint: .tidyAmber,
                symbol: "eye",
                photoNames: ["SampleLake", "SampleCoast", "SampleLake"]
            )
        }
        .padding(isRegular ? 28 : 18)
        .storePanelStyle()
    }

    private var pendingPreview: some View {
        VStack(spacing: isRegular ? 20 : 14) {
            StorePanelHeader(title: "待删除", detail: "12 张", isRegular: isRegular)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: isRegular ? 12 : 8), count: 3),
                spacing: isRegular ? 12 : 8
            ) {
                ForEach(0..<(compact ? 6 : 9), id: \.self) { index in
                    Image(samplePhotoNames[index % samplePhotoNames.count])
                        .resizable()
                        .scaledToFill()
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 9, weight: .black))
                                .foregroundStyle(.white)
                                .frame(width: isRegular ? 32 : 23, height: isRegular ? 32 : 23)
                                .background(.black.opacity(0.42), in: Circle())
                                .padding(isRegular ? 8 : 5)
                        }
                }
            }

            HStack {
                Label("128 MB", systemImage: "externaldrive.fill")
                    .foregroundStyle(Color.tidyMuted)
                Spacer()
                Label("确认删除", systemImage: "trash.fill")
                    .foregroundStyle(Color.tidyOnAccent)
                    .padding(.horizontal, isRegular ? 22 : 16)
                    .frame(height: isRegular ? 52 : 42)
                    .background(Color.tidyAccent, in: Capsule())
            }
            .font(.system(size: isRegular ? 15 : 12, weight: .bold, design: .rounded))
        }
        .padding(isRegular ? 28 : 18)
        .storePanelStyle()
    }

    private var progressPreview: some View {
        VStack(spacing: isRegular ? 28 : 18) {
            StorePanelHeader(title: "整理战绩", detail: "本月", isRegular: isRegular)

            HStack(spacing: isRegular ? 48 : 22) {
                ZStack {
                    Circle()
                        .stroke(Color.tidyHairline, lineWidth: 15)
                    Circle()
                        .trim(from: 0, to: 0.72)
                        .stroke(
                            AngularGradient(colors: [.tidyAccent, .tidyCyan, .tidyViolet], center: .center),
                            style: StrokeStyle(lineWidth: 15, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 2) {
                        Text("72%")
                            .font(.system(size: isRegular ? 38 : 27, weight: .black, design: .rounded))
                            .foregroundStyle(Color.tidyInk)
                        Text("已整理")
                            .font(.system(size: isRegular ? 13 : 10, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.tidyMuted)
                    }
                }
                .frame(width: isRegular ? 190 : 132, height: isRegular ? 190 : 132)

                VStack(alignment: .leading, spacing: isRegular ? 22 : 14) {
                    storeMetric(value: "4,868", label: "已整理", tint: .tidyAccent)
                    storeMetric(value: "3.7 GB", label: "累计释放", tint: .tidyViolet)
                }
            }

            HStack(alignment: .bottom, spacing: isRegular ? 20 : 13) {
                ForEach([0.30, 0.54, 0.42, 0.76, 0.60, 1.0], id: \.self) { value in
                    Capsule()
                        .fill(Color.tidyViolet.opacity(0.34 + value * 0.60))
                        .frame(height: (isRegular ? 150 : 92) * value)
                }
            }
            .frame(maxHeight: isRegular ? 158 : 98, alignment: .bottom)
        }
        .padding(isRegular ? 30 : 20)
        .storePanelStyle()
    }

    private var privacyPreview: some View {
        VStack(spacing: isRegular ? 34 : 22) {
            ZStack {
                Circle()
                    .fill(Color.tidyKeep.opacity(0.10))
                    .frame(width: isRegular ? 320 : 220, height: isRegular ? 320 : 220)
                Circle()
                    .stroke(Color.tidyKeep.opacity(0.20), lineWidth: 1)
                    .frame(width: isRegular ? 390 : 270, height: isRegular ? 390 : 270)

                Image(systemName: "iphone.gen3")
                    .font(.system(size: isRegular ? 205 : 140, weight: .ultraLight))
                    .foregroundStyle(Color.tidyInk)

                Image(systemName: "lock.fill")
                    .font(.system(size: isRegular ? 40 : 29, weight: .black))
                    .foregroundStyle(Color.tidyOnAccent)
                    .frame(width: isRegular ? 94 : 68, height: isRegular ? 94 : 68)
                    .background(Color.tidyKeep, in: Circle())
                    .overlay(Circle().stroke(Color.tidyBackground, lineWidth: 6))
                    .offset(x: isRegular ? 94 : 65, y: isRegular ? 112 : 78)
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 8) {
                storePrivacyChip("本机分析", symbol: "cpu")
                storePrivacyChip("不上传", symbol: "icloud.slash")
                storePrivacyChip("不跟踪", symbol: "eye.slash")
            }
        }
    }

    private let samplePhotoNames = [
        "SampleLake",
        "SampleCity",
        "SampleBreakfast",
        "SampleCat",
        "SampleCoast",
        "SampleFlowers"
    ]

    private func storeDecisionButton(symbol: String, title: String, color: Color) -> some View {
        VStack(spacing: isRegular ? 9 : 6) {
            Image(systemName: symbol)
                .font(.system(size: isRegular ? 34 : 25, weight: .black))
                .frame(width: isRegular ? 86 : 62, height: isRegular ? 86 : 62)
                .background(Color.tidySurface, in: Circle())
                .overlay(Circle().stroke(color.opacity(0.48), lineWidth: 2))
            Text(L10n.text(title))
                .font(.system(size: isRegular ? 14 : 11, weight: .bold, design: .rounded))
        }
        .foregroundStyle(color)
    }

    private func storeGroupRow(
        title: String,
        detail: String,
        tint: Color,
        symbol: String,
        photoNames: [String]
    ) -> some View {
        HStack(spacing: isRegular ? 16 : 12) {
            Image(systemName: symbol)
                .font(.system(size: isRegular ? 21 : 16, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: isRegular ? 50 : 38, height: isRegular ? 50 : 38)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: isRegular ? 15 : 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text(title))
                    .font(.system(size: isRegular ? 18 : 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tidyInk)
                Text(L10n.text(detail))
                    .font(.system(size: isRegular ? 13 : 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.tidyMuted)
            }

            Spacer()

            HStack(spacing: -8) {
                ForEach(0..<3, id: \.self) { index in
                    Image(photoNames[index % photoNames.count])
                        .resizable()
                        .scaledToFill()
                        .frame(width: isRegular ? 46 : 34, height: isRegular ? 46 : 34)
                        .clipShape(RoundedRectangle(cornerRadius: isRegular ? 11 : 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: isRegular ? 11 : 8).stroke(Color.tidySurface, lineWidth: 2))
                }
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.tidyMuted)
        }
        .padding(.horizontal, isRegular ? 18 : 12)
        .frame(height: isRegular ? 88 : (compact ? 56 : 66))
        .background(Color.tidyElevated, in: RoundedRectangle(cornerRadius: isRegular ? 22 : 17, style: .continuous))
    }

    private func storeMetric(value: String, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: isRegular ? 34 : 24, weight: .black, design: .rounded))
                .foregroundStyle(tint)
            Text(L10n.text(label))
                .font(.system(size: isRegular ? 14 : 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color.tidyMuted)
        }
    }

    private func storePrivacyChip(_ title: String, symbol: String) -> some View {
        VStack(spacing: isRegular ? 10 : 7) {
            Image(systemName: symbol)
                .font(.system(size: isRegular ? 25 : 18, weight: .bold))
            Text(L10n.text(title))
                .font(.system(size: isRegular ? 13 : 10, weight: .bold, design: .rounded))
        }
        .foregroundStyle(Color.tidyKeep)
        .frame(maxWidth: .infinity)
        .frame(height: isRegular ? 96 : 72)
        .background(Color.tidyKeep.opacity(0.09), in: RoundedRectangle(cornerRadius: isRegular ? 23 : 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: isRegular ? 23 : 18, style: .continuous)
                .stroke(Color.tidyKeep.opacity(0.18), lineWidth: 1)
        }
    }
}

private struct StorePhotoCard: View {
    let imageName: String

    var body: some View {
        GeometryReader { proxy in
            Image(imageName)
                .resizable()
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.28)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(.white.opacity(0.14), lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(0.28), radius: 20, y: 12)
        }
    }
}

private struct StorePanelHeader: View {
    let title: String
    let detail: String
    let isRegular: Bool

    var body: some View {
        HStack {
            Text(L10n.text(title))
                .font(.system(size: isRegular ? 24 : 18, weight: .bold, design: .rounded))
                .foregroundStyle(Color.tidyInk)
            Spacer()
            Text(L10n.text(detail))
                .font(.system(size: isRegular ? 14 : 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color.tidyMuted)
                .padding(.horizontal, isRegular ? 14 : 10)
                .frame(height: isRegular ? 36 : 28)
                .background(Color.tidyElevated, in: Capsule())
        }
    }
}

private extension View {
    func storePanelStyle() -> some View {
        background(Color.tidySurface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.tidyHairline, lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.20), radius: 22, y: 14)
    }
}

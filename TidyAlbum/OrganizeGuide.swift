import SwiftUI

enum OrganizeGuidePreference {
    /// 第一次进整理页自动弹一次，之后只能从设置里重看
    static let seenKey = "minus.organize.hasSeenGuide"
}

// MARK: - 指引主体

/// 整理页操作指引：一页讲一件事，每页都在循环演示这个操作怎么用。
/// 演示内容全按用户当前的方向绑定和按钮排列渲染，不会教一套、用起来是另一套。
struct OrganizeGuideView: View {
    let onDismiss: () -> Void

    @AppStorage(OrganizeControlsPreference.buttonOrderKey)
    private var buttonOrderRaw = OrganizeControlsPreference.defaultButtonOrderRaw
    @AppStorage(OrganizeControlsPreference.swipeActionKey)
    private var swipeActionRaw = OrganizeControlsPreference.defaultSwipeActionRaw

    @State private var pageIndex = 0
    /// 翻页动画落定后才等于 pageIndex。演示只认它，免得开头那几帧被滑动盖过去。
    @State private var settledPageIndex: Int?

    /// 翻页动画和半屏弹出的时长，等这段走完再开演
    private static let settleDelay = 420

    private var controls: OrganizeControlsPreference {
        OrganizeControlsPreference(buttonOrderRaw: buttonOrderRaw, swipeActionRaw: swipeActionRaw)
    }

    /// 页数跟着设置走：没绑相簿就不讲相簿，四个方向全留空就不讲滑动
    private var pages: [GuidePage] {
        var result: [GuidePage] = []
        if !controls.releaseDirections.isEmpty {
            result.append(.swipe)
        }
        if let direction = controls.albumDirections.first {
            result.append(.album(direction))
        }
        result.append(.buttons)
        result.append(.viewing)
        return result
    }

    var body: some View {
        let visiblePages = pages

        VStack(spacing: 0) {
            topBar

            TabView(selection: $pageIndex) {
                ForEach(Array(visiblePages.enumerated()), id: \.element.id) { index, page in
                    // 只让当前页跑动画，翻走的页面把循环停掉
                    pageView(page, index: index, pageCount: visiblePages.count)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            dots(count: visiblePages.count)
        }
        .background(Color.tidyBackground.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // 页码一变先把所有演示停掉，等滑动停下来再点亮当前页
        .task(id: pageIndex) {
            settledPageIndex = nil
            guard await GuideClock.wait(Self.settleDelay) else { return }
            settledPageIndex = pageIndex
        }
    }

    @ViewBuilder
    private func pageView(_ page: GuidePage, index: Int, pageCount: Int) -> some View {
        // 最后一页没有下一页可交棒，就让它一直循环演示
        let context = GuideDemoContext(
            isActive: index == settledPageIndex,
            autoAdvances: index < pageCount - 1,
            onFinished: { advance(from: index) }
        )

        switch page {
        case .swipe:
            GuideSwipePage(controls: controls, demo: context)
        case let .album(direction):
            GuideAlbumPage(direction: direction, demo: context)
        case .buttons:
            GuideButtonsPage(controls: controls, demo: context)
        case .viewing:
            GuideViewingPage(demo: context)
        }
    }

    /// 演示播够遍数后自动翻页；手动翻走过就别再把人拽回来
    private func advance(from index: Int) {
        guard pageIndex == index else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            pageIndex = index + 1
        }
    }

    private var topBar: some View {
        HStack {
            Text("整理手势")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(Color.tidyInk)

            Spacer(minLength: 0)

            // 唯一的退出口，除此之外就是把半屏往下拖走
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.tidyMuted)
                    .frame(width: 30, height: 30)
                    .background(Color.tidyElevated, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
        }
        .padding(.horizontal, 20)
        // 半屏顶上有拖动指示条，标题要往下让开
        .padding(.top, 22)
        .padding(.bottom, 4)
    }

    private func dots(count: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(0 ..< count, id: \.self) { index in
                Capsule()
                    .fill(index == pageIndex ? Color.tidyAccent : Color.tidyHairline)
                    .frame(width: index == pageIndex ? 20 : 7, height: 7)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: pageIndex)
        .padding(.top, 4)
        .padding(.bottom, 18)
    }
}

/// 指引的一页。相簿那页带着实际绑定的方向，演示才对得上。
private enum GuidePage {
    case swipe
    case album(SwipeDirection)
    case buttons
    case viewing

    var id: String {
        switch self {
        case .swipe: "swipe"
        case let .album(direction): "album-\(direction.rawValue)"
        case .buttons: "buttons"
        case .viewing: "viewing"
        }
    }
}

// MARK: - 第一页：滑动做决定

/// 循环演示每个绑了判定的方向：卡片推到位盖印章，再飞出去换下一个方向
private struct GuideSwipePage: View {
    let controls: OrganizeControlsPreference
    let demo: GuideDemoContext

    @State private var step = 0
    @State private var isPushed = false
    @State private var isFlying = false

    private var directions: [SwipeDirection] { controls.releaseDirections }

    /// 当前演示到的方向
    private var activeDirection: SwipeDirection? {
        directions.indices.contains(step) ? directions[step] : directions.first
    }

    var body: some View {
        let direction = activeDirection
        let action = direction.map { controls.action(for: $0) } ?? SwipeDirectionAction.none

        GuidePageChrome(
            title: "滑动做决定",
            subtitle: "把照片朝一个方向拖到位，松手就执行"
        ) {
            GuideStage {
                GuidePhotoCard()
                    .offset(cardOffset(for: direction))
                    // 横向飞出时带一点侧倾，和真机上的甩牌手感一致
                    .rotationEffect(.degrees(rotation(for: direction)))

                GuideTouchDot()
                    .offset(cardOffset(for: direction))
                    .opacity(isPushed && !isFlying ? 1 : 0)

                GuideStamp(action: action)
                    .opacity(isPushed && !isFlying ? 1 : 0)
                    .scaleEffect(isPushed ? 1 : 0.82)
            }
        } caption: {
            VStack(spacing: 10) {
                // 四个方向都列出来，正在演示的那张亮着
                LazyVGrid(columns: [GridItem(spacing: 8), GridItem(spacing: 8)], spacing: 8) {
                    ForEach(SwipeDirection.allCases) { candidate in
                        GuideDirectionChip(
                            direction: candidate,
                            action: controls.action(for: candidate),
                            isHighlighted: candidate == direction
                        )
                    }
                }

                Text("这些绑定可以在「设置 › 整理页操作」里改。")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.tidyMuted)
            }
        }
        .task(id: demo.isActive) { await runLoop() }
    }

    private func cardOffset(for direction: SwipeDirection?) -> CGSize {
        guard let direction else { return .zero }
        let distance: CGFloat = isFlying ? 320 : (isPushed ? 52 : 0)
        return direction.vector(distance)
    }

    private func rotation(for direction: SwipeDirection?) -> Double {
        guard let direction, !direction.isVertical else { return 0 }
        return Double(cardOffset(for: direction).width / 20)
    }

    /// 一遍 = 把绑定了判定的方向依次演示一次
    private func runLoop() async {
        guard demo.isActive, !directions.isEmpty else { return }

        // 上一轮可能是被翻页打断的，先无动画复位，别从半路接着演
        isPushed = false
        isFlying = false

        var playedCount = 0
        while !Task.isCancelled {
            for index in directions.indices {
                step = index

                withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) { isPushed = true }
                guard await GuideClock.wait(750) else { return }

                withAnimation(.easeOut(duration: 0.28)) { isFlying = true }
                guard await GuideClock.wait(300) else { return }

                // 复位不加动画，否则卡片会从屏外飘回来，看着像倒放
                isPushed = false
                isFlying = false
                guard await GuideClock.wait(320) else { return }
            }

            playedCount += 1
            guard demo.shouldKeepPlaying(playedCount: playedCount) else { return }
        }
    }
}

// MARK: - 第二页：加入相簿

/// 循环演示两段式的加入相簿：拖到位不松手 → 顶部展开相簿 → 左右挑 → 松手加入
private struct GuideAlbumPage: View {
    let direction: SwipeDirection
    let demo: GuideDemoContext

    /// 演示用的相簿名，真机上这里是你自己的相簿
    private static let sampleAlbums = ["旅行", "家人", "精选"]
    private static let chipWidth: CGFloat = 66
    private static let chipSpacing: CGFloat = 7
    /// 卡片拖出去的距离
    private static let dragDistance: CGFloat = 34
    /// 卡片整体往下让一点，给顶部的相簿列表腾出位置
    private static let cardDrop: CGFloat = 18

    @State private var isDragging = false
    @State private var selectedIndex = 0
    @State private var addedAlbum: String?

    var body: some View {
        GuidePageChrome(
            title: "加入相簿",
            subtitle: L10n.format("往%@拖到位后先别松手", L10n.text(direction.shortTitle))
        ) {
            GuideStage {
                GuidePhotoCard(height: 96)
                    .offset(cardOffset)

                GuideTouchDot()
                    .offset(cardOffset)
                    .opacity(isDragging ? 1 : 0)

                // 相簿列表固定从顶部展开，和真机一致
                VStack(spacing: 0) {
                    albumStrip
                    Spacer(minLength: 0)
                }
                .opacity(isDragging ? 1 : 0)
                .offset(y: isDragging ? 0 : -28)

                if let addedAlbum {
                    Text(L10n.format("已加入「%@」", L10n.text(addedAlbum)))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color.tidyAccent.opacity(0.92), in: Capsule())
                        .transition(.opacity)
                }
            }
        } caption: {
            VStack(alignment: .leading, spacing: 10) {
                GuideTip(symbol: direction.symbol, text: L10n.format("往%@拖到位，顶部展开相簿列表。", L10n.text(direction.shortTitle)))
                GuideTip(symbol: "arrow.left.and.right", text: L10n.text("手指别松，左右滑动挑一个；滑得远就会连续翻。"))
                GuideTip(symbol: "hand.tap", text: L10n.text("松手加入，照片留在队列里继续做删留决定。"))
            }
        }
        .task(id: demo.isActive) { await runLoop() }
    }

    private var cardOffset: CGSize {
        let pushed = direction.vector(isDragging ? Self.dragDistance : 0)
        return CGSize(width: pushed.width, height: pushed.height + Self.cardDrop)
    }

    private var albumStrip: some View {
        let step = Self.chipWidth + Self.chipSpacing
        let centerOffset = (CGFloat(Self.sampleAlbums.count - 1) / 2 - CGFloat(selectedIndex)) * step

        return HStack(spacing: Self.chipSpacing) {
            ForEach(Array(Self.sampleAlbums.enumerated()), id: \.offset) { index, name in
                let isSelected = index == selectedIndex

                Text(L10n.text(name))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(isSelected ? Color.tidyOnAccent : .white.opacity(0.75))
                    .lineLimit(1)
                    .frame(width: Self.chipWidth, height: 34)
                    .background(isSelected ? Color.tidyAccent : Color.white.opacity(0.14), in: Capsule())
                    .scaleEffect(isSelected ? 1.06 : 1)
            }
        }
        .offset(x: centerOffset)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    /// 一遍 = 拖出相簿、横向挑一个、松手加入
    private func runLoop() async {
        guard demo.isActive else { return }

        // 上一轮可能是被翻页打断的，先无动画复位，别从半路接着演
        isDragging = false
        selectedIndex = 0
        addedAlbum = nil

        var playedCount = 0
        while !Task.isCancelled {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) { isDragging = true }
            guard await GuideClock.wait(820) else { return }

            // 一格一格往右挑，演示横向滑动切换选中项
            for index in 1 ..< Self.sampleAlbums.count {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) { selectedIndex = index }
                guard await GuideClock.wait(560) else { return }
            }

            withAnimation(.spring(response: 0.36, dampingFraction: 0.8)) {
                isDragging = false
                addedAlbum = Self.sampleAlbums[selectedIndex]
            }
            guard await GuideClock.wait(950) else { return }

            withAnimation(.easeOut(duration: 0.24)) { addedAlbum = nil }
            selectedIndex = 0
            guard await GuideClock.wait(360) else { return }

            playedCount += 1
            guard demo.shouldKeepPlaying(playedCount: playedCount) else { return }
        }
    }
}

// MARK: - 第三页：底部按钮

/// 循环点亮每个按钮，同时把它的作用写在下面
private struct GuideButtonsPage: View {
    let controls: OrganizeControlsPreference
    let demo: GuideDemoContext

    @State private var highlightIndex = 0

    private var order: [OrganizeAction] { controls.buttonOrder }

    private var highlighted: OrganizeAction? {
        order.indices.contains(highlightIndex) ? order[highlightIndex] : order.first
    }

    var body: some View {
        GuidePageChrome(
            title: "底部按钮",
            subtitle: "不想滑动时，轻点也能做同样的事"
        ) {
            GuideStage {
                VStack(spacing: 12) {
                    GuidePhotoCard(height: 84)

                    HStack(spacing: 0) {
                        ForEach(Array(order.enumerated()), id: \.element) { index, action in
                            button(action, isHighlighted: index == highlightIndex)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        } caption: {
            VStack(spacing: 8) {
                if let action = highlighted {
                    Text(L10n.text(action.title))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(action.tint)
                    Text(L10n.text(action.guideDetail))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.tidyInk.opacity(0.86))
                        .multilineTextAlignment(.center)
                }

                Text("按钮顺序也能在「设置 › 整理页操作」里拖着改。")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.tidyMuted)
            }
            // 文字整块换内容时淡入淡出，不要逐字跳变
            .animation(.easeInOut(duration: 0.22), value: highlightIndex)
        }
        .task(id: demo.isActive) { await runLoop() }
    }

    private func button(_ action: OrganizeAction, isHighlighted: Bool) -> some View {
        // 演示里的圆圈比真机小一圈，四个排开才留得出间距；真机按钮已收小，系数相应调大保持原有观感
        let size = action.buttonSize * 0.78

        return Image(systemName: action.symbol)
            .font(.system(size: size > 42 ? 18 : 14, weight: .bold))
            .foregroundStyle(action.tint)
            .frame(width: size, height: size)
            .background(Color.tidyElevated, in: Circle())
            .overlay {
                Circle().stroke(action.tint.opacity(isHighlighted ? 1 : 0.32), lineWidth: 2)
            }
            // 点亮的那个像被按下一样鼓起来，外面套一圈涟漪
            .overlay {
                Circle()
                    .stroke(action.tint.opacity(isHighlighted ? 0.45 : 0), lineWidth: 2)
                    .scaleEffect(isHighlighted ? 1.5 : 1)
            }
            .scaleEffect(isHighlighted ? 1.16 : 1)
            .frame(maxWidth: .infinity)
    }

    /// 一遍 = 把四个按钮依次点亮一次
    private func runLoop() async {
        guard demo.isActive, !order.isEmpty else { return }

        var playedCount = 0
        while !Task.isCancelled {
            for index in order.indices {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { highlightIndex = index }
                guard await GuideClock.wait(1_050) else { return }
            }

            playedCount += 1
            guard demo.shouldKeepPlaying(playedCount: playedCount) else { return }
        }
    }
}

// MARK: - 第四页：看得更细

/// 演示放大：双击放大再拖动看局部
private struct GuideViewingPage: View {
    let demo: GuideDemoContext

    @State private var scale: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var showsTapRipple = false

    var body: some View {
        GuidePageChrome(
            title: "看得更细",
            subtitle: "拿不定主意时，先把照片看清楚"
        ) {
            GuideStage {
                GuidePhotoCard()
                    .scaleEffect(scale)
                    .offset(pan)

                GuideTouchDot()
                    .scaleEffect(showsTapRipple ? 1.8 : 1)
                    .opacity(showsTapRipple ? 0 : 0.9)
            }
        } caption: {
            VStack(alignment: .leading, spacing: 10) {
                GuideTip(symbol: "arrow.up.left.and.arrow.down.right", text: L10n.text("双击或双指捏合放大，放大后拖动看局部。"))
                GuideTip(symbol: "play.circle", text: L10n.text("视频轻点播放，再轻点暂停。"))
                GuideTip(symbol: "livephoto", text: L10n.text("Live Photo 和动图长按播放，松手停下。"))
            }
        }
        .task(id: demo.isActive) { await runLoop() }
    }

    /// 一遍 = 双击放大、拖动看局部、再缩回去
    private func runLoop() async {
        guard demo.isActive else { return }

        // 上一轮可能是被翻页打断的，先无动画复位，别从半路接着演
        scale = 1
        pan = .zero

        var playedCount = 0
        while !Task.isCancelled {
            // 先来一下双击的涟漪，再跟着放大，顺序反了就看不出是双击触发的
            showsTapRipple = false
            withAnimation(.easeOut(duration: 0.45)) { showsTapRipple = true }
            guard await GuideClock.wait(180) else { return }

            withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { scale = 1.8 }
            guard await GuideClock.wait(620) else { return }

            withAnimation(.easeInOut(duration: 1)) { pan = CGSize(width: -30, height: 20) }
            guard await GuideClock.wait(1_050) else { return }

            withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
                scale = 1
                pan = .zero
            }
            guard await GuideClock.wait(760) else { return }

            playedCount += 1
            guard demo.shouldKeepPlaying(playedCount: playedCount) else { return }
        }
    }
}

// MARK: - 共用零件

/// 每页统一的骨架：标题、副标题、演示舞台、舞台下的说明
private struct GuidePageChrome<Stage: View, Caption: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var stage: Stage
    @ViewBuilder var caption: Caption

    var body: some View {
        // 小屏上这一页可能装不下，交给滚动而不是被 TabView 裁掉
        ScrollView {
            VStack(spacing: 14) {
                VStack(spacing: 3) {
                    Text(L10n.text(title))
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.tidyInk)
                    Text(L10n.text(subtitle))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.tidyMuted)
                        .multilineTextAlignment(.center)
                }

                stage

                caption
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
    }
}

/// 演示舞台：一块模拟整理页的圆角屏幕，卡片滑到边界就被裁掉
private struct GuideStage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            content
        }
        // 半屏放得下的高度；拉到全屏也不再长，多出来的空间留给下面的说明
        .frame(height: 164)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.tidyHairline, lineWidth: 1)
        }
    }
}

private struct GuidePhotoCard: View {
    var height: CGFloat = 112

    var body: some View {
        Image("SampleLake")
            .resizable()
            .scaledToFill()
            .frame(width: height * 0.73, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.45), radius: 10, y: 6)
    }
}

/// 代表手指的半透明圆点，光看卡片移动不容易读出是在拖动
private struct GuideTouchDot: View {
    var body: some View {
        Circle()
            .fill(.white.opacity(0.32))
            .frame(width: 30, height: 30)
            .overlay { Circle().stroke(.white.opacity(0.6), lineWidth: 1.5) }
    }
}

/// 和真机同款的判定印章，只是尺寸缩了一号
private struct GuideStamp: View {
    let action: SwipeDirectionAction

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: action.symbol)
                .font(.system(size: 13, weight: .black))
            Text(L10n.text(action.title))
                .font(.system(size: 16, weight: .black, design: .rounded))
        }
        .foregroundStyle(action.tint)
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .background(.black.opacity(0.34), in: Capsule())
        .overlay(Capsule().stroke(action.tint, lineWidth: 2.5))
    }
}

/// 只读的方向牌，正在演示的那个亮起来
private struct GuideDirectionChip: View {
    let direction: SwipeDirection
    let action: SwipeDirectionAction
    let isHighlighted: Bool

    var body: some View {
        let isSet = action != .none

        return HStack(spacing: 5) {
            Image(systemName: direction.symbol)
                .font(.system(size: 10, weight: .black))
            Text(L10n.text(action.title))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(isSet ? action.tint : Color.tidyMuted)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(
            isSet ? action.tint.opacity(isHighlighted ? 0.26 : 0.1) : Color.tidyElevated,
            in: Capsule()
        )
        .overlay {
            Capsule().stroke(
                isSet ? action.tint.opacity(isHighlighted ? 0.95 : 0.34) : Color.tidyHairline,
                lineWidth: isHighlighted ? 2 : 1.5
            )
        }
        .animation(.easeInOut(duration: 0.24), value: isHighlighted)
    }
}

private struct GuideTip: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.tidyAccent)
                .frame(width: 20)
            Text(text)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.tidyInk.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// 一页演示的运行条件：是不是当前页、播完要不要翻下一页、翻页怎么通知出去
private struct GuideDemoContext {
    /// 每页演示播几遍就交棒给下一页
    static let repeatCount = 1

    let isActive: Bool
    let autoAdvances: Bool
    let onFinished: () -> Void

    /// 播完一遍后问一次：还要继续播吗？播够了就顺手通知翻页
    func shouldKeepPlaying(playedCount: Int) -> Bool {
        guard autoAdvances, playedCount >= Self.repeatCount else { return true }
        onFinished()
        return false
    }
}

private enum GuideClock {
    /// 等一段时间，返回 false 表示这页已经翻走、循环该停了
    static func wait(_ milliseconds: Int) async -> Bool {
        do {
            try await Task.sleep(for: .milliseconds(milliseconds))
            return true
        } catch {
            return false
        }
    }
}

private extension SwipeDirection {
    /// 方向 + 距离换成位移向量，演示里直接拿来摆卡片
    func vector(_ distance: CGFloat) -> CGSize {
        switch self {
        case .up: CGSize(width: 0, height: -distance)
        case .down: CGSize(width: 0, height: distance)
        case .left: CGSize(width: -distance, height: 0)
        case .right: CGSize(width: distance, height: 0)
        }
    }
}

private extension OrganizeAction {
    /// 指引里对这个按钮的一句话说明
    var guideDetail: String {
        switch self {
        case .undo: "把上一张的判定收回来，重新决定。"
        case .delete: "标记删除，整理结束时统一确认。"
        case .keep: "留在图库里，直接看下一张。"
        case .add: "打开相簿列表，把这张加进去。"
        }
    }
}

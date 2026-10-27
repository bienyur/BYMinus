import SwiftUI
import UIKit

/// 整理页的一次判定。滑动和底部按钮共用同一套语义。
enum SwipeDecision: String, Equatable {
    case delete
    case keep
}

/// 整理页底部可排序的四个按钮。
enum OrganizeAction: String, CaseIterable, Identifiable {
    case undo
    case delete
    case keep
    case add

    var id: String { rawValue }

    /// 工程用中文原文当本地化 key，取用时仍需显式走 L10n
    var title: String {
        switch self {
        case .undo: "撤回"
        case .delete: "删除"
        case .keep: "保留"
        case .add: "添加"
        }
    }

    var symbol: String {
        switch self {
        case .undo: "arrow.uturn.backward"
        case .delete: "xmark"
        case .keep: "checkmark"
        case .add: "plus"
        }
    }

    var tint: Color {
        switch self {
        case .undo: .white
        case .delete: .tidyDanger
        case .keep: .tidyKeep
        case .add: .tidyAccent
        }
    }

    /// 删除和保留是主操作，圆圈更大；撤回和添加是辅助操作。
    /// 整理页的按钮收进了底部操作栏，尺寸跟着收小，四个排开仍有余量
    var buttonSize: CGFloat {
        switch self {
        case .delete, .keep: 60
        case .undo, .add: 46
        }
    }
}

/// 照片可以被拖走的四个方向。
enum SwipeDirection: String, CaseIterable, Identifiable {
    case up
    case down
    case left
    case right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .up: "向上"
        case .down: "向下"
        case .left: "向左"
        case .right: "向右"
        }
    }

    /// 嵌在句子里用的方向名，"向上" 放进 "往…拖" 会读成 "往向上拖"
    var shortTitle: String {
        switch self {
        case .up: "上"
        case .down: "下"
        case .left: "左"
        case .right: "右"
        }
    }

    var symbol: String {
        switch self {
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .left: "arrow.left"
        case .right: "arrow.right"
        }
    }

    var isVertical: Bool { self == .up || self == .down }

    /// 只有上下能绑“加入相簿”：挑相簿要靠垂直于触发方向的那根轴左右扫，
    /// 左右方向扫起来就成了上下扫，别扭且容易和普通拖动打架。
    var allowsAlbumAction: Bool { isVertical }

    /// 位移在这个方向上的投影，正值表示正朝该方向移动
    func distance(in translation: CGSize) -> CGFloat {
        switch self {
        case .up: -translation.height
        case .down: translation.height
        case .left: -translation.width
        case .right: translation.width
        }
    }

    /// 垂直于本方向的那根轴上的位移。挑相簿时用它左右（或上下）切换选中项。
    func crossAxisDistance(in translation: CGSize) -> CGFloat {
        isVertical ? translation.width : translation.height
    }

    /// 卡片飞出屏幕的终点位移。横向飞出时顺带下坠一点，保持原来那种甩牌手感。
    func exitOffset(distance: CGFloat, from current: CGSize) -> CGSize {
        switch self {
        case .up: CGSize(width: current.width, height: -distance)
        case .down: CGSize(width: current.width, height: distance)
        case .left: CGSize(width: -distance, height: current.height + 36)
        case .right: CGSize(width: distance, height: current.height + 36)
        }
    }
}

/// 一个滑动方向绑定的动作，`none` 表示这个方向留空、不触发任何操作。
enum SwipeDirectionAction: String, CaseIterable, Identifiable {
    case none
    case delete
    case keep
    /// 滑到位后先别松手：顶部展开相簿列表，横向滑动挑一个，松手才加入
    case album
    /// 把上一张的判定撤回来，当前这张留在队列里
    case undo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "不设置"
        case .delete: "删除"
        case .keep: "保留"
        case .album: "加入相簿"
        case .undo: "撤回"
        }
    }

    var symbol: String {
        switch self {
        case .none: "minus"
        case .delete: "xmark"
        case .keep: "checkmark"
        case .album: "rectangle.stack.badge.plus"
        case .undo: "arrow.uturn.backward"
        }
    }

    /// 只有删除和保留会把照片从队列里带走，加入相簿和撤回都不改变当前这张的去向
    var decision: SwipeDecision? {
        switch self {
        case .none, .album, .undo: nil
        case .delete: .delete
        case .keep: .keep
        }
    }

    /// 松手就立刻执行。`album` 要等横向挑完相簿，`none` 什么都不做。
    var firesOnRelease: Bool {
        switch self {
        case .delete, .keep, .undo: true
        case .none, .album: false
        }
    }

    var tint: Color {
        switch self {
        case .none: .tidyMuted
        case .delete: .tidyDanger
        case .keep: .tidyKeep
        case .album: .tidyAccent
        case .undo: .white
        }
    }
}

/// 整理页底部按钮顺序与滑动方向绑定的用户设置。
/// 两项都压成紧凑字符串存进 UserDefaults，各处直接用 @AppStorage 订阅，改完立刻生效。
struct OrganizeControlsPreference: Equatable {
    static let buttonOrderKey = "minus.organize.buttonOrder"
    static let swipeActionKey = "minus.organize.swipeAction"

    static let defaultButtonOrderRaw = "undo,delete,keep,add"
    static let defaultSwipeActionRaw = "up:album,down:undo,left:delete,right:keep"

    var buttonOrder: [OrganizeAction]
    var swipeActions: [SwipeDirection: SwipeDirectionAction]

    init(buttonOrderRaw: String, swipeActionRaw: String) {
        buttonOrder = Self.decodeButtonOrder(buttonOrderRaw)
        swipeActions = Self.decodeSwipeActions(swipeActionRaw)
    }

    var buttonOrderRaw: String {
        buttonOrder.map(\.rawValue).joined(separator: ",")
    }

    var swipeActionRaw: String {
        SwipeDirection.allCases
            .map { "\($0.rawValue):\(action(for: $0).rawValue)" }
            .joined(separator: ",")
    }

    func action(for direction: SwipeDirection) -> SwipeDirectionAction {
        swipeActions[direction] ?? .none
    }

    func decision(for direction: SwipeDirection) -> SwipeDecision? {
        action(for: direction).decision
    }

    /// 所有绑定了“加入相簿”的方向。上下都可以绑，朝哪边拖就由哪边接管。
    var albumDirections: [SwipeDirection] {
        SwipeDirection.allCases.filter { action(for: $0) == .album }
    }

    /// 所有松手就直接执行的方向，也就是删除、保留、撤回那几个
    var releaseDirections: [SwipeDirection] {
        SwipeDirection.allCases.filter { action(for: $0).firesOnRelease }
    }

    /// 某个方向能选的动作：左右不给“加入相簿”
    static func options(for direction: SwipeDirection) -> [SwipeDirectionAction] {
        direction.allowsAlbumAction
            ? SwipeDirectionAction.allCases
            : SwipeDirectionAction.allCases.filter { $0 != .album }
    }

    /// 点按钮时卡片该往哪飞：优先用绑定了同一判定的方向，一个都没绑定就退回左删右留
    func exitDirection(for decision: SwipeDecision) -> SwipeDirection {
        if let matched = SwipeDirection.allCases.first(where: { self.decision(for: $0) == decision }) {
            return matched
        }
        return decision == .delete ? .left : .right
    }

    /// 解析时去重并补齐缺失项，保证四个按钮不多不少，读到脏数据也不会丢按钮
    private static func decodeButtonOrder(_ raw: String) -> [OrganizeAction] {
        var order: [OrganizeAction] = []
        for value in raw.split(separator: ",") {
            guard let action = OrganizeAction(rawValue: String(value)), !order.contains(action) else { continue }
            order.append(action)
        }
        order.append(contentsOf: OrganizeAction.allCases.filter { !order.contains($0) })
        return order
    }

    private static func decodeSwipeActions(_ raw: String) -> [SwipeDirection: SwipeDirectionAction] {
        var result: [SwipeDirection: SwipeDirectionAction] = [:]
        for entry in raw.split(separator: ",") {
            let parts = entry.split(separator: ":")
            guard parts.count == 2,
                  let direction = SwipeDirection(rawValue: String(parts[0])),
                  let action = SwipeDirectionAction(rawValue: String(parts[1])) else { continue }
            // 左右若存了“加入相簿”（旧数据或手改），一律当没绑
            result[direction] = (action == .album && !direction.allowsAlbumAction) ? SwipeDirectionAction.none : action
        }
        return result
    }
}

/// 整理页操作自定义。两张卡片就是两块可直接操作的预览：
/// 上面点方向牌选该方向滑走时的判定，下面直接拖动按钮改排列。
struct OrganizeControlsSettingsView: View {
    @AppStorage(OrganizeControlsPreference.buttonOrderKey)
    private var buttonOrderRaw = OrganizeControlsPreference.defaultButtonOrderRaw
    @AppStorage(OrganizeControlsPreference.swipeActionKey)
    private var swipeActionRaw = OrganizeControlsPreference.defaultSwipeActionRaw

    /// 正在被拖动的按钮，以及它离开起始槽位的位移
    @State private var draggingAction: OrganizeAction?
    @State private var dragStartX: CGFloat = 0
    @State private var dragTranslation: CGFloat = 0

    /// 底部按钮预览区高度，够放下最大的圆圈加下方文字
    private static let buttonRowHeight: CGFloat = 92
    /// 真机按钮已收进底部操作栏并缩小，预览直接按真机尺寸画
    private static let buttonScale: CGFloat = 1

    private var controls: OrganizeControlsPreference {
        OrganizeControlsPreference(buttonOrderRaw: buttonOrderRaw, swipeActionRaw: swipeActionRaw)
    }

    var body: some View {
        VStack(spacing: 16) {
            swipeCard
            buttonCard
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.tidyBackground.ignoresSafeArea())
        .navigationTitle("整理页操作")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        buttonOrderRaw = OrganizeControlsPreference.defaultButtonOrderRaw
                        swipeActionRaw = OrganizeControlsPreference.defaultSwipeActionRaw
                    }
                } label: {
                    Text("恢复默认")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                }
                .tint(Color.tidyAccent)
            }
        }
    }

    // MARK: - 滑动方向

    private var swipeCard: some View {
        card(
            symbol: "hand.draw",
            title: "滑动方向",
            subtitle: "点方向牌，选择朝这边滑走时的判定"
        ) {
            VStack(spacing: 8) {
                directionChip(.up)
                HStack(spacing: 6) {
                    directionChip(.left)
                    photoPlaceholder
                    directionChip(.right)
                }
                directionChip(.down)
            }
        }
    }

    private var photoPlaceholder: some View {
        Image("SampleLake")
            .resizable()
            .scaledToFill()
            .frame(width: 76, height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.16), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.36), radius: 10, y: 6)
    }

    /// 方向牌本身就是菜单入口，点开直接选删除、保留还是留空
    private func directionChip(_ direction: SwipeDirection) -> some View {
        let action = controls.action(for: direction)
        let isSet = action != .none

        return Menu {
            Picker(selection: swipeSelection(for: direction)) {
                ForEach(OrganizeControlsPreference.options(for: direction)) { option in
                    Label(L10n.text(option.title), systemImage: option.symbol).tag(option)
                }
            } label: {
                Text(L10n.text(direction.title))
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: direction.symbol)
                    .font(.system(size: 11, weight: .black))
                Text(L10n.text(action.title))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .black))
                    .opacity(0.55)
            }
            .foregroundStyle(action.tint)
            .padding(.horizontal, 10)
            .frame(width: 106, height: 34)
            .background(isSet ? action.tint.opacity(0.14) : Color.tidyElevated, in: Capsule())
            .overlay {
                Capsule().stroke(isSet ? action.tint.opacity(0.5) : Color.tidyHairline, lineWidth: 1.5)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: action)
    }

    // MARK: - 底部按钮

    private var buttonCard: some View {
        card(
            symbol: "circle.grid.2x1.fill",
            title: "底部按钮",
            subtitle: "直接拖动按钮，调整从左到右的排列"
        ) {
            GeometryReader { proxy in
                buttonRow(width: proxy.size.width - 20)
                    .padding(.horizontal, 10)
            }
            .frame(height: Self.buttonRowHeight)
            .background(Color.tidyBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    /// 四个按钮均分槽位摆开，拖动时只有被拖的那个脱离槽位跟手
    private func buttonRow(width: CGFloat) -> some View {
        let order = controls.buttonOrder
        let slotWidth = width / CGFloat(order.count)

        return ZStack(alignment: .topLeading) {
            ForEach(order) { action in
                let index = order.firstIndex(of: action) ?? 0
                let isDragging = draggingAction == action

                actionSlot(action, slotWidth: slotWidth, isDragging: isDragging)
                    .scaleEffect(isDragging ? 1.12 : 1)
                    .shadow(color: .black.opacity(isDragging ? 0.55 : 0), radius: 12, y: 6)
                    .offset(x: isDragging ? dragStartX + dragTranslation : CGFloat(index) * slotWidth)
                    // 只让让位的按钮做动画，被拖的那个必须每帧跟手，不能被弹簧拖慢
                    .animation(isDragging ? nil : Animation.spring(response: 0.3, dampingFraction: 0.8), value: order)
                    .zIndex(isDragging ? 1 : 0)
                    .gesture(reorderGesture(for: action, slotWidth: slotWidth))
            }
        }
        .frame(width: width, height: Self.buttonRowHeight, alignment: .topLeading)
    }

    private func actionSlot(_ action: OrganizeAction, slotWidth: CGFloat, isDragging: Bool) -> some View {
        let size = action.buttonSize * Self.buttonScale

        return VStack(spacing: 6) {
            Image(systemName: action.symbol)
                .font(.system(size: size > 56 ? 22 : 17, weight: .bold))
                .foregroundStyle(action.tint)
                .frame(width: size, height: size)
                .background(Color.tidyElevated, in: Circle())
                .overlay {
                    Circle().stroke(action.tint.opacity(isDragging ? 0.9 : 0.36), lineWidth: 2)
                }
            Text(L10n.text(action.title))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(isDragging ? Color.tidyInk : Color.tidyInk.opacity(0.82))
        }
        .frame(width: slotWidth, height: Self.buttonRowHeight)
        .contentShape(Rectangle())
    }

    /// 手指一动就抓起，不需要长按；中途越过相邻槽位实时换位，松手落到新位置
    private func reorderGesture(for action: OrganizeAction, slotWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if draggingAction != action {
                    let index = controls.buttonOrder.firstIndex(of: action) ?? 0
                    dragStartX = CGFloat(index) * slotWidth
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.7)) {
                        draggingAction = action
                    }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
                }

                dragTranslation = value.translation.width
                reorderWhileDragging(action, slotWidth: slotWidth)
            }
            .onEnded { _ in
                guard draggingAction == action else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    draggingAction = nil
                    dragTranslation = 0
                }
            }
    }

    private func reorderWhileDragging(_ action: OrganizeAction, slotWidth: CGFloat) {
        var order = controls.buttonOrder
        guard slotWidth > 0, let currentIndex = order.firstIndex(of: action) else { return }

        let rawIndex = ((dragStartX + dragTranslation) / slotWidth).rounded()
        let targetIndex = min(max(Int(rawIndex), 0), order.count - 1)
        guard targetIndex != currentIndex else { return }

        order.move(
            fromOffsets: IndexSet(integer: currentIndex),
            toOffset: targetIndex > currentIndex ? targetIndex + 1 : targetIndex
        )
        buttonOrderRaw = order.map(\.rawValue).joined(separator: ",")
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func swipeSelection(for direction: SwipeDirection) -> Binding<SwipeDirectionAction> {
        Binding(
            get: { controls.action(for: direction) },
            set: { newValue in
                var updated = controls
                updated.swipeActions[direction] = newValue
                swipeActionRaw = updated.swipeActionRaw
            }
        )
    }

    /// 与列表页一致的卡片外观：石墨卡面 + 发丝描边
    private func card<Content: View>(
        symbol: String,
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.tidyOnAccent)
                    .frame(width: 26, height: 26)
                    .background(Color.tidyAccent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text(title))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.tidyInk)
                    Text(L10n.text(subtitle))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.tidyMuted)
                }

                Spacer(minLength: 0)
            }

            content()
                .frame(maxWidth: .infinity)
        }
        .padding(16)
        .background(Color.tidySurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.tidyHairline, lineWidth: 1)
        }
    }
}

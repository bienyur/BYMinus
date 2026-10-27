import CoreMotion
import SpriteKit
import SwiftUI

/// 首页的整理进度容器：卡片本身就是个罐子，进度越高里面攒下的小物件越多，
/// 堆起来的高度就是进度。小物件是真刚体，重力跟着手机姿态走，晃手机里面的东西会跟着滚。
struct ProgressJarView: View {
    let progress: Double
    /// 和卡片圆角对齐，小物件才会顺着角落滑下去而不是卡在方角里
    let cornerRadius: CGFloat

    // @StateObject 的初始值是惰性的，首页每次重算 body 不会白造一个场景出来
    @StateObject private var scene = ProgressJarScene()

    var body: some View {
        GeometryReader { geo in
            SpriteView(scene: scene, options: [.allowsTransparency])
                .onAppear {
                    scene.cornerRadius = cornerRadius
                    scene.size = geo.size
                    scene.apply(progress: progress)
                    scene.setActive(true)
                }
                // 离开首页就停渲染和停传感器，这卡片不值得一直烧电
                .onDisappear { scene.setActive(false) }
                .onChange(of: geo.size) { newSize in
                    scene.size = newSize
                }
                .onChange(of: progress) { newValue in
                    scene.apply(progress: newValue)
                }
        }
        .accessibilityHidden(true)
    }
}

/// 只为了配合 @StateObject 才符合 ObservableObject，没有任何 @Published，不会引起界面刷新
final class ProgressJarScene: SKScene, ObservableObject {
    /// 装满时的小物件数量。不追求把卡片填平，攒到下半部就足够看出进度差别。
    private static let capacity = 56
    private static let pelletRadius: CGFloat = 9
    /// 一颗接一颗地掉，凑出往容器里倒东西的手感
    private static let dropInterval: TimeInterval = 0.04
    /// 进度为 0 时的保底数量。孤零零一颗看着像出了错，铺开一小撮才像刚开始攒。
    private static let minimumCount = 4
    /// 容器上沿再往上留一段竖井：小物件从井口掉进来，被晃飞了也甩不出去
    private static let shaftHeight: CGFloat = 140
    private static let pelletName = "pellet"
    private static let wallName = "wall"
    private static let tickKey = "tick"

    private static let pelletColors: [SKColor] = [
        SKColor(Color.tidyAccent),
        SKColor(Color.tidyAccent),
        SKColor(Color.tidyCyan),
        SKColor(Color.tidyViolet)
    ]

    /// 卡片圆角，由外部设好后再建墙
    var cornerRadius: CGFloat = 26

    private let motion = CMMotionManager()
    /// 当前进度换算出来的小物件数量，实际数量每帧朝它靠一颗
    private var targetCount = 0

    /// 尺寸由 SpriteView 按卡片大小回填，这里先建成空的
    override init() {
        super.init(size: .zero)
        scaleMode = .resizeFill
        backgroundColor = .clear
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        scaleMode = .resizeFill
        backgroundColor = .clear
    }

    override func didMove(to view: SKView) {
        super.didMove(to: view)
        buildWalls()

        // 常驻一个对齐动作：不够就补一颗，多了就取一颗。
        // 这样进度中途变化也不用管上一轮掉落有没有掉完。
        let tick = SKAction.sequence([
            SKAction.run { [weak self] in self?.stepTowardTarget() },
            SKAction.wait(forDuration: Self.dropInterval)
        ])
        run(SKAction.repeatForever(tick), withKey: Self.tickKey)
    }

    override func willMove(from view: SKView) {
        super.willMove(from: view)
        motion.stopDeviceMotionUpdates()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        buildWalls()
    }

    /// 首页每次拿到新进度都会调一次。多了就继续往里掉，撤回让进度退回去就取走几颗。
    func apply(progress: Double) {
        let clamped = min(max(progress, 0), 1)
        targetCount = max(Int((clamped * Double(Self.capacity)).rounded()), Self.minimumCount)
    }

    func setActive(_ active: Bool) {
        isPaused = !active
        if active {
            startMotionUpdates()
        } else {
            motion.stopDeviceMotionUpdates()
        }
    }

    override func update(_ currentTime: TimeInterval) {
        // 剧烈晃动偶尔还是能把小物件甩出竖井，跑太远就回收。
        // 回收完 stepTowardTarget 会自动补回来，数量不会越晃越少。
        for pellet in children where pellet.name == Self.pelletName {
            let isLost = pellet.position.y > size.height + Self.shaftHeight * 2
                || pellet.position.y < -Self.pelletRadius * 6
            if isLost { pellet.removeFromParent() }
        }
    }

    // MARK: - 小物件

    private var pellets: [SKNode] {
        children.filter { $0.name == Self.pelletName }
    }

    private func stepTowardTarget() {
        let current = pellets
        if current.count < targetCount {
            addPellet()
        } else if current.count > targetCount, let extra = current.last {
            // 先摘掉名字，淡出这段时间里不再被当成在罐子里的那批
            extra.name = nil
            extra.run(.sequence([.fadeOut(withDuration: 0.22), .removeFromParent()]))
        }
    }

    private func addPellet() {
        guard size.width > Self.pelletRadius * 4 else { return }

        let radius = Self.pelletRadius
        let pellet = SKShapeNode(circleOfRadius: radius)
        pellet.name = Self.pelletName
        pellet.fillColor = Self.pelletColors.randomElement() ?? SKColor(Color.tidyAccent)
        pellet.strokeColor = .clear

        // 从井口落进来，看不到突然冒出来的那一下
        pellet.position = CGPoint(
            x: CGFloat.random(in: (radius * 2)...(size.width - radius * 2)),
            y: size.height + radius * 3
        )

        let body = SKPhysicsBody(circleOfRadius: radius)
        body.restitution = 0.2      // 弹一下就停，不要一直蹦
        body.friction = 0.55
        body.linearDamping = 0.4
        body.angularDamping = 0.6
        pellet.physicsBody = body

        addChild(pellet)
    }

    // MARK: - 容器

    /// 左右两侧和带圆角的底部围一圈，顶部留口。两侧多往上长一段当竖井。
    private func buildWalls() {
        children.filter { $0.name == Self.wallName }.forEach { $0.removeFromParent() }
        guard size.width > cornerRadius * 2, size.height > cornerRadius else { return }

        let inset: CGFloat = 1.5
        let radius = cornerRadius
        let top = size.height + Self.shaftHeight
        let left = inset
        let right = size.width - inset

        let path = CGMutablePath()
        path.move(to: CGPoint(x: left, y: top))
        path.addLine(to: CGPoint(x: left, y: inset + radius))
        path.addQuadCurve(
            to: CGPoint(x: left + radius, y: inset),
            control: CGPoint(x: left, y: inset)
        )
        path.addLine(to: CGPoint(x: right - radius, y: inset))
        path.addQuadCurve(
            to: CGPoint(x: right, y: inset + radius),
            control: CGPoint(x: right, y: inset)
        )
        path.addLine(to: CGPoint(x: right, y: top))

        let walls = SKNode()
        walls.name = Self.wallName
        let body = SKPhysicsBody(edgeChainFrom: path)
        body.friction = 0.5
        walls.physicsBody = body
        addChild(walls)
    }

    private func startMotionUpdates() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }

        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let gravity = data?.gravity else { return }
            // gravity 是单位向量，竖屏拿手机时 y 约为 -1，和 SpriteKit 的 y 轴朝上正好对上
            self?.physicsWorld.gravity = CGVector(dx: gravity.x * 9.8, dy: gravity.y * 9.8)
        }
    }
}

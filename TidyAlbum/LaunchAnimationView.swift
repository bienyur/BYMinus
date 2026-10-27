import SwiftUI

struct AppRootView: View {
    @EnvironmentObject private var remoteConfig: RemoteConfigStore
    @State private var isShowingLaunch = true
    @State private var isInitialContentReady = false
    @AppStorage(OnboardingPreference.completionKey) private var hasCompletedOnboarding = false

    var body: some View {
        ZStack {
            // 目标页面始终在启动动画下方提前创建，动画结束时只移除遮罩，首页不会再重建闪烁。
            if !remoteConfig.loadState.isLoaded {
                // 配置没拿到之前不放行，避免用错误的开关状态渲染任何页面
                RemoteConfigGateView(state: remoteConfig.loadState) {
                    Task { await remoteConfig.refresh() }
                }
                .transition(.opacity)
                .zIndex(2)
            } else if !hasCompletedOnboarding {
                OnboardingView {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        hasCompletedOnboarding = true
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
                .zIndex(1)
            } else {
                ContentView(
                    onShowOnboarding: {
                        withAnimation(.easeInOut(duration: 0.28)) {
                            hasCompletedOnboarding = false
                        }
                    },
                    onInitialContentReady: { isInitialContentReady = true }
                )
                    .transition(.opacity)
            }

            if isShowingLaunch {
                LaunchAnimationView(canFinish: { canRevealDestination }) {
                    withAnimation(.easeOut(duration: 0.32)) {
                        isShowingLaunch = false
                    }
                }
                .transition(.opacity)
                .zIndex(2)
            }

            // 升级提示压在最上层，强制更新时要能挡住引导页和主界面
            if !isShowingLaunch, remoteConfig.loadState.isLoaded, remoteConfig.updateState != .none {
                UpdatePromptView(
                    update: remoteConfig.config.update,
                    isForced: remoteConfig.updateState == .forced,
                    onSkip: { remoteConfig.skipCurrentUpdate() }
                )
                .transition(.opacity)
                .zIndex(3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.tidyBackground.ignoresSafeArea())
    }

    private var canRevealDestination: Bool {
        switch remoteConfig.loadState {
        case .loading:
            return false
        case .failed:
            // 失败页已经可以交互，必须显示出来让用户重试。
            return true
        case .loaded:
            return !hasCompletedOnboarding || isInitialContentReady
        }
    }
}

/// 配置加载中 / 加载失败时的拦截页，失败时只能重试，不提供跳过入口。
private struct RemoteConfigGateView: View {
    let state: RemoteConfigLoadState
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            if case .failed(let message) = state {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(Color.tidyMuted)

                Text("无法加载配置")
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(Color.tidyInk)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Color.tidyMuted)
                    .multilineTextAlignment(.center)

                Button(action: onRetry) {
                    Text("重试")
                        .fontWeight(.heavy)
                        .foregroundStyle(Color.tidyOnAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color.tidyAccent, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
                .frame(maxWidth: 240)
            } else {
                ProgressView()
                    .tint(Color.tidyAccent)
                Text("正在加载…")
                    .font(.subheadline)
                    .foregroundStyle(Color.tidyMuted)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.tidyBackground.ignoresSafeArea())
    }
}

/// 版本升级提示。强制更新时不提供任何关闭入口。
private struct UpdatePromptView: View {
    let update: AppRemoteConfig.Update
    let isForced: Bool
    let onSkip: () -> Void

    @Environment(\.openURL) private var openURL
    private let appStoreURL = URL(string: "https://apps.apple.com/app/id6805741070")!

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(Color.tidyAccent)

                Text(
                    isForced
                        ? L10n.text("请更新到最新版本")
                        : L10n.format("发现新版本 %@", update.latestVersion)
                )
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(Color.tidyInk)
                    .multilineTextAlignment(.center)

                if !update.releaseNotes.isEmpty {
                    Text(update.releaseNotes)
                        .font(.subheadline)
                        .foregroundStyle(Color.tidyMuted)
                        .multilineTextAlignment(.center)
                }

                if isForced {
                    Text("当前版本已停止支持，更新后才能继续使用。")
                        .font(.caption)
                        .foregroundStyle(Color.tidyMuted)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 10) {
                    Button {
                        print("[Minus Update] Opening hardcoded App Store URL: \(appStoreURL.absoluteString)")
                        openURL(appStoreURL) { accepted in
                            print("[Minus Update] openURL accepted: \(accepted)")
                        }
                    } label: {
                        Text("前往 App Store 更新")
                            .fontWeight(.heavy)
                            .foregroundStyle(Color.tidyOnAccent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Color.tidyAccent, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    }

                    if !isForced {
                        Button("稍后再说", action: onSkip)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.tidyMuted)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 340)
            .background(Color.tidySurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.tidyHairline, lineWidth: 1)
            }
            .padding(.horizontal, 28)
        }
    }
}

private struct LaunchAnimationView: View {
    let canFinish: () -> Bool
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0
    @State private var didFinish = false

    var body: some View {
        GeometryReader { proxy in
            let isRegular = proxy.size.width >= 700

            ZStack {
                Color.tidyBackground.ignoresSafeArea()

                Circle()
                    .fill(Color.tidyAccent.opacity(0.10))
                    .frame(width: isRegular ? 500 : 330, height: isRegular ? 500 : 330)
                    .blur(radius: isRegular ? 8 : 4)
                    .scaleEffect(phase >= 3 ? 1.08 : 0.78)
                    .opacity(phase == 0 || phase == 4 ? 0 : 1)

                VStack(spacing: 0) {
                    Spacer(minLength: isRegular ? 64 : 40)

                    LaunchAlbumMark(phase: phase)
                        .frame(width: isRegular ? 360 : 250, height: isRegular ? 360 : 250)
                        .scaleEffect(
                            phase == 0
                                ? (isRegular ? 0.92 : 0.72)
                                : (phase == 4 ? (isRegular ? 1.34 : 1.08) : (isRegular ? 1.28 : 1))
                        )
                        .opacity(phase == 4 ? 0 : 1)
                        .blur(radius: phase == 4 ? 8 : 0)

                    VStack(spacing: isRegular ? 14 : 10) {
                        Text("Minus")
                            .font(.system(size: isRegular ? 56 : 40, weight: .bold, design: .rounded))
                            // 拉丁字标，稍微收一点字距才不散
                            .tracking(-0.6)
                            .foregroundStyle(Color.tidyInk)
                        Text("减掉多余的，留下值得的")
                            .font(.system(size: isRegular ? 20 : 15, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.tidyMuted)
                    }
                    .opacity(phase >= 1 && phase < 4 ? 1 : 0)
                    .offset(y: phase >= 1 ? 0 : 14)

                    Spacer()

                    Label("照片只在本机分析", systemImage: "lock.fill")
                        .font(.system(size: isRegular ? 15 : 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.tidyMuted)
                        .padding(.horizontal, isRegular ? 19 : 14)
                        .padding(.vertical, isRegular ? 12 : 9)
                        .background(Color.tidySurface.opacity(0.92), in: Capsule())
                        .opacity(phase >= 2 && phase < 4 ? 1 : 0)
                        .padding(.bottom, isRegular ? 56 : 34)
                }
                .padding(.horizontal, isRegular ? 44 : 24)
            }
        }
        .animation(.spring(response: 0.58, dampingFraction: 0.78), value: phase)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("Minus，减掉多余的，留下值得的，照片只在本机分析"))
        .task { await runAnimation() }
    }

    @MainActor
    private func runAnimation() async {
        guard !didFinish else { return }

        if reduceMotion {
            withAnimation(.easeOut(duration: 0.2)) { phase = 3 }
            try? await Task.sleep(nanoseconds: 650_000_000)
        } else {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            phase = 1

            try? await Task.sleep(nanoseconds: 480_000_000)
            guard !Task.isCancelled else { return }
            phase = 2

            try? await Task.sleep(nanoseconds: 560_000_000)
            guard !Task.isCancelled else { return }
            phase = 3

            try? await Task.sleep(nanoseconds: 720_000_000)
        }

        guard !Task.isCancelled else { return }
        // 原动画播完后停在最后一帧，首屏准备好才执行原有淡出。
        while !canFinish() {
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
        }
        withAnimation(.easeIn(duration: 0.26)) { phase = 4 }
        try? await Task.sleep(nanoseconds: 260_000_000)
        guard !Task.isCancelled else { return }
        didFinish = true
        onFinished()
    }
}

private struct LaunchAlbumMark: View {
    let phase: Int

    var body: some View {
        ZStack {
            LaunchPhotoCard(
                imageName: "SampleFlowers"
            )
            .rotationEffect(.degrees(phase >= 3 ? -5 : -14))
            .offset(x: phase >= 3 ? -11 : -42, y: phase >= 3 ? 2 : 12)

            LaunchPhotoCard(
                imageName: "SampleLake"
            )
            .rotationEffect(.degrees(phase >= 3 ? 5 : 14))
            .offset(x: phase >= 3 ? 11 : 42, y: phase >= 3 ? 2 : 12)

            LaunchPhotoCard(
                imageName: "SampleCity",
                contentOpacity: phase >= 3 ? 0 : 1
            )
            .scaleEffect(phase >= 3 ? 0.94 : 1)
            .offset(y: phase >= 3 ? -8 : 0)

            DecisionBadge(symbol: "xmark", tint: Color.tidyDanger)
                .offset(x: -88, y: 64)
                .scaleEffect(phase == 2 ? 1 : 0.62)
                .opacity(phase == 2 ? 1 : 0)

            DecisionBadge(symbol: "checkmark", tint: Color.tidyKeep)
                .offset(x: 88, y: 64)
                .scaleEffect(phase == 2 ? 1 : 0.62)
                .opacity(phase == 2 ? 1 : 0)

            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 38, weight: .bold))
                // 落在柠檬色卡面上，用深色
                .foregroundStyle(Color.tidyOnAccent)
                .opacity(phase >= 3 ? 1 : 0)
                .scaleEffect(phase >= 3 ? 1 : 0.55)
                .offset(y: -8)
        }
        .opacity(phase == 0 ? 0 : 1)
        .offset(y: phase == 0 ? 36 : 0)
    }
}

private struct LaunchPhotoCard: View {
    let imageName: String
    var contentOpacity: Double = 1

    var body: some View {
        ZStack {
            Color.tidyAccent

            Image(imageName)
                .resizable()
                .scaledToFill()
                .opacity(contentOpacity)

            LinearGradient(
                colors: [.clear, .black.opacity(0.22)],
                startPoint: .center,
                endPoint: .bottom
            )
            .opacity(contentOpacity)
        }
            .frame(width: 124, height: 164)
            .clipShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 27, style: .continuous)
                    .stroke(.white.opacity(0.30), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.14), radius: 18, y: 10)
    }
}

private struct DecisionBadge: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 19, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 48, height: 48)
            .background(Color.tidySurface, in: Circle())
            .overlay(Circle().stroke(tint.opacity(0.25), lineWidth: 2))
            .shadow(color: tint.opacity(0.20), radius: 12, y: 6)
    }
}

// 色板统一收在 ContentView 的 Color 扩展里，这里不再单独定义一套

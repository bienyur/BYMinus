    import PhotosUI
import Photos
import SwiftUI
import UIKit

struct ContentView: View {
    var onShowOnboarding: () -> Void = { }
    var onInitialContentReady: () -> Void = { }

    @EnvironmentObject private var purchaseStore: PurchaseStore
    @EnvironmentObject private var remoteConfig: RemoteConfigStore
    @Environment(\.openURL) private var openURL
    @StateObject private var photoLibrary = PhotoLibraryStore()
    @State private var selectedSection: AppSection = .home
    @State private var inbox: [PhotoItem] = []
    @State private var pendingPhotos: [PhotoItem] = []
    @State private var keptCount = 0
    @State private var reviewedCount = 0
    @State private var selectedPhoto: PhotoItem?
    /// 首页点开的分类，进去才看得到这一类下面的具体方案
    @State private var selectedCategoryID: String?
    @State private var selectedGroup: PhotoGroup?
    @State private var showAlbums = false
    @State private var albumSelection: PhotoListSelection?
    /// 正在读取的相簿，用来在那一行上转圈
    @State private var loadingAlbumID: String?
    @State private var timeGranularity: TimeGranularity = .month
    /// 时间页左边一列选中的月或年
    @State private var selectedTimeParentID: String?
    @State private var timeSelection: PhotoListSelection?
    /// 正在读取的时间分组，用来在那一行上转圈
    @State private var loadingBucketID: String?
    @AppStorage(PhotoListLimit.key) private var photoListLimit = PhotoListLimit.defaultValue
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system.rawValue
    /// 整理动作全部收进独立的整理页，首页只负责展示进度与入口
    @State private var isOrganizing = false
    /// 首页点封面进来的那张：整理页要从它开始，续批换队列时也得把它顶回队首
    @State private var organizeStartPhoto: PhotoItem?
    /// 正在整理的合集，非空时盖一层只整理这个合集的整理页
    @State private var organizingCollection: PhotoCollectionPreview?
    /// 合集整理页的队列，一次定好不续批
    @State private var collectionQueue: [PhotoItem] = []
    /// 队列刚建好时的长度。进度条要拿它当分母，不能用会越整越短的当前队列长度。
    @State private var collectionTotalCount = 0
    /// 当前这轮整理的埋点汇总，关闭整理页时上报一次
    @State private var organizeSession: OrganizeAnalyticsSession?
    @State private var showSettings = false
    @State private var showPaywall = false
    /// 整理页里弹的付费页。整理页本身就是首页弹出的全屏页，首页不能再叠一个，只能由整理页来弹
    @State private var showOrganizePaywall = false
    @State private var showReviewRewardPrompt = false
    @State private var showPhotoSearch = false
    @State private var paywallEntryReason = "quota_exceeded"
    @State private var showImportPicker = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var toastMessage: ToastMessage?
    @State private var hasShownResumeBanner = false
    @State private var hasReportedInitialContentReady = false
    @State private var hasFinishedInitialLibraryLoad = false
    @State private var isInitialHeroReady = false

    var body: some View {
        ZStack {
            Color.tidyBackground
            pageContent
            // 下钻页在标签栏之外，所以要压在 pageContent 上面
            detailOverlay
            toastOverlay

            // 整理页开着时弹窗改由整理页自己挂，这里不再重复渲染一份被挡住的
            if !isOrganizePresented {
                reviewRewardPrompt
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.tidyBackground.ignoresSafeArea(.all))
        .animation(.easeInOut(duration: 0.2), value: toastMessage)
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: showReviewRewardPrompt)
        .sheet(item: $selectedPhoto) { photo in
            PhotoDetailView(photo: photo)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView {
                showSettings = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                    onShowOnboarding()
                }
            }
                .presentationDetents([.medium, .large])
                // 调试构建的「重置免费额度」需要读写额度账本
                .environmentObject(photoLibrary)
        }
        .fullScreenCover(isPresented: $showPaywall) {
            PaywallView(entryReason: paywallEntryReason)
        }
        // 整理页由首页触发，盖满全屏，退出后回到首页
        .fullScreenCover(isPresented: $isOrganizing) {
            OrganizeView(
                inbox: $inbox,
                source: .library,
                progressTotalCount: photoLibrary.progressTotalCount,
                reviewedCount: reviewedCount,
                albums: photoLibrary.albums,
                onDecision: { photo, decision in
                    // 指定的起点已经做完决定，续批时就不该再把它顶回队首
                    if photo.id == organizeStartPhoto?.id {
                        organizeStartPhoto = nil
                    }
                    photoLibrary.recordDecision(for: photo, delete: decision == .delete)
                    organizeSession?.decisions[photo.id] = decision == .delete
                },
                onUndoDecision: { photo in
                    photoLibrary.undoDecision(for: photo)
                    organizeSession?.decisions[photo.id] = nil
                },
                onLoadNextBatch: {
                    await photoLibrary.loadNextBatch()
                },
                onAddToAlbum: { photo, album in
                    await photoLibrary.addPhoto(photo, to: album)
                },
                onCreateAlbum: { name, photo in
                    await photoLibrary.createAlbum(named: name, initialPhoto: photo)
                },
                onDeleteSession: deleteSessionPhotos,
                onClose: {
                    finishOrganizeSession()
                    isOrganizing = false
                    organizeStartPhoto = nil
                }
            )
            .modifier(OrganizeQuotaPrompts(
                showPaywall: $showOrganizePaywall,
                paywallEntryReason: paywallEntryReason,
                prompt: reviewRewardPrompt
            ))
        }
        // 首页点某个合集：只整理这个合集，整完就结束，不接着捞图库里其他照片
        .fullScreenCover(item: $organizingCollection) { collection in
            OrganizeView(
                inbox: $collectionQueue,
                source: .collection(title: L10n.text(collection.kind.title), totalCount: collectionTotalCount),
                progressTotalCount: photoLibrary.progressTotalCount,
                reviewedCount: reviewedCount,
                albums: photoLibrary.albums,
                onDecision: { photo, decision in
                    photoLibrary.recordDecision(for: photo, delete: decision == .delete)
                    organizeSession?.decisions[photo.id] = decision == .delete
                    // 图库队列里可能也排着这张，别让它在主队列里再出现一次
                    inbox.removeAll { $0.id == photo.id }
                },
                onUndoDecision: { photo in
                    photoLibrary.undoDecision(for: photo)
                    organizeSession?.decisions[photo.id] = nil
                },
                // 合集是一次定好的固定队列，没有下一批，返回 0 让整理页直接收尾
                onLoadNextBatch: { 0 },
                onAddToAlbum: { photo, album in
                    await photoLibrary.addPhoto(photo, to: album)
                },
                onCreateAlbum: { name, photo in
                    await photoLibrary.createAlbum(named: name, initialPhoto: photo)
                },
                onDeleteSession: deleteSessionPhotos,
                onClose: {
                    finishOrganizeSession()
                    organizingCollection = nil
                    collectionQueue = []
                    collectionTotalCount = 0
                }
            )
            .modifier(OrganizeQuotaPrompts(
                showPaywall: $showOrganizePaywall,
                paywallEntryReason: paywallEntryReason,
                prompt: reviewRewardPrompt
            ))
        }
        .photosPicker(
            isPresented: $showImportPicker,
            selection: $pickerItems,
            maxSelectionCount: 30,
            matching: .any(of: [.images, .videos]),
            photoLibrary: .shared()
        )
        .onChange(of: pickerItems) { newItems in
            Task { await importPhotos(newItems) }
        }
        .task {
            // 启动后默认停在首页，标签没切换过也要记一次首页曝光
            AnalyticsReporter.shared.track(.screenView(screen: selectedSection.rawValue))
            let startedAt = Date()
            // 极慢的 iCloud 或图库异常也不能让启动页无限等待。
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                reportInitialContentReady(force: true)
            }
            // 当前队列会优先发布；Vision 扫描等原启动动画完整播放后再开始。
            await photoLibrary.load(scanAfterLoading: false)
            hasFinishedInitialLibraryLoad = true
            if !photoLibrary.isAuthorized || photoLibrary.photos.isEmpty {
                isInitialHeroReady = true
                reportInitialContentReady()
            } else {
                // iCloud 首张封面过慢时允许使用已经准备好的加载状态，不能无限停在启动页。
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(800))
                    isInitialHeroReady = true
                    reportInitialContentReady()
                }
            }
            let remainingDelay = max(2.45 - Date().timeIntervalSince(startedAt), 0)
            if remainingDelay > 0 {
                try? await Task.sleep(for: .seconds(remainingDelay))
            }
            guard !Task.isCancelled else { return }
            await photoLibrary.scanLibraryGroups()
        }
        .onReceive(photoLibrary.$photos) { newPhotos in
            inbox = queue(from: newPhotos)
        }
        .onReceive(photoLibrary.$pendingPhotos) { photos in
            pendingPhotos = photos
        }
        .onReceive(photoLibrary.$keptCount) { keptCount = $0 }
        .onReceive(photoLibrary.$reviewedCount) { reviewedCount = $0 }
        .onChange(of: selectedSection) { section in
            AnalyticsReporter.shared.track(.screenView(screen: section.rawValue))
            if section != .home {
                selectedGroup = nil
                selectedCategoryID = nil
                showAlbums = false
                albumSelection = nil
                showPhotoSearch = false
            }
            if section != .timeline {
                timeSelection = nil
            }
        }
        .onChange(of: appLanguage) { _ in
            photoLibrary.refreshLocalizedContent()
        }
        // 由状态统一驱动 toast 自动消失，子视图直接赋值也能生效；重复触发会重置计时
        .task(id: toastMessage) {
            guard toastMessage != nil else { return }
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            toastMessage = nil
        }
    }

    private func reportInitialContentReady(force: Bool = false) {
        guard !hasReportedInitialContentReady,
              force || (hasFinishedInitialLibraryLoad && isInitialHeroReady) else { return }
        hasReportedInitialContentReady = true
        onInitialContentReady()
    }

    /// 免费用户可以累计确认删除 20 张或 100 MB；支付尚未配置、或会员状态还没同步完时都不锁死核心删除流程。
    private func requiresProForDeletion(_ photos: [PhotoItem]) -> Bool {
        guard isFreeTier else { return false }
        let newBytes = photos.reduce(Int64(0)) { $0 + max($1.byteSize, 0) }
        let exceedsCount = photoLibrary.quotaDeletedCount + photos.count > photoLibrary.quotaDeletionLimit
        let exceedsStorage = photoLibrary.quotaReleasedBytes + newBytes > photoLibrary.quotaReleasedBytesLimit
        return exceedsCount || exceedsStorage
    }

    private func deletePendingPhotos() {
        let photos = pendingPhotos
        guard !photos.isEmpty else { return }
        guard !requiresProForDeletion(photos) else {
            presentQuotaExceededPrompt(source: "pending")
            return
        }

        let count = photos.count
        photoLibrary.delete(photos: photos) { success in
            guard success else {
                showToast("删除失败，请检查照片权限")
                return
            }
            trackDeletion(photos, source: "pending")
            pendingPhotos.removeAll()
            showToast(L10n.format("已将 %lld 项移入最近删除", count))
        }
    }

    /// 整理结束页只删除这一轮选中的项目，不能把以前积累的待删除项目一起带上。
    private func deleteSessionPhotos(
        _ photos: [PhotoItem],
        completion: @escaping (OrganizeDeletionResult) -> Void
    ) {
        guard !photos.isEmpty else {
            completion(.success)
            return
        }
        guard !requiresProForDeletion(photos) else {
            presentQuotaExceededPrompt(source: "session")
            completion(.quotaExceeded)
            return
        }

        photoLibrary.delete(photos: photos) { success in
            if success { trackDeletion(photos, source: "session") }
            completion(success ? .success : .failed)
        }
    }

    /// 删除成功才上报，只传张数和释放的 MB（向上取整，小于 1 MB 也记 1），不传任何照片信息
    private func trackDeletion(_ photos: [PhotoItem], source: String) {
        let bytes = photos.reduce(Int64(0)) { $0 + max($1.byteSize, 0) }
        let freedMB = bytes > 0 ? Int((bytes + 1_048_575) / 1_048_576) : 0
        AnalyticsReporter.shared.track(.deleteConfirm(source: source, photoCount: photos.count, freedMB: freedMB))
    }

    /// 两个整理页（图库、合集）任意一个正盖在首页上
    private var isOrganizePresented: Bool {
        isOrganizing || organizingCollection != nil
    }

    /// 额度用完的弹窗：主推开会员，评分领额度是次要选项。首页和整理页共用同一份，由 isOrganizePresented 决定挂在哪一层
    @ViewBuilder
    private var reviewRewardPrompt: some View {
        if showReviewRewardPrompt {
            QuotaExceededPromptView(
                rewardText: FreeQuota.reviewRewardSummaryText,
                onUpgrade: {
                    AnalyticsReporter.shared.track(.quotaPromptAction(action: "upgrade"))
                    dismissReviewRewardPrompt()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        presentPaywall(reason: "quota_exceeded")
                    }
                },
                onRate: {
                    AnalyticsReporter.shared.track(.quotaPromptAction(action: "rate"))
                    openReviewPageAndScheduleReward()
                },
                onCancel: {
                    AnalyticsReporter.shared.track(.quotaPromptAction(action: "dismiss"))
                    dismissReviewRewardPrompt()
                }
            )
            .transition(.scale(scale: 0.9).combined(with: .opacity))
            .zIndex(20)
        }
    }

    /// 整理页开着时从整理页上弹付费页，否则首页已在展示整理页，再弹一个全屏页会被系统直接忽略
    private func presentPaywall(reason: String) {
        paywallEntryReason = reason
        if isOrganizePresented {
            showOrganizePaywall = true
        } else {
            showPaywall = true
        }
    }

    /// source 只用于埋点：pending（待删除页）/ session（整理页、搜索的本次删除）
    private func presentQuotaExceededPrompt(source: String) {
        if photoLibrary.hasClaimedReviewReward {
            AnalyticsReporter.shared.track(.quotaExceeded(source: source, prompt: "paywall"))
            presentPaywall(reason: "quota_exceeded")
        } else {
            AnalyticsReporter.shared.track(.quotaExceeded(source: source, prompt: "offer"))
            withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) {
                showReviewRewardPrompt = true
            }
        }
    }

    /// 首页卡片点了直接拉起 Apple 支付确认，续费价格由系统支付页展示。
    private func startHomeTrial(_ plan: PaywallPlan) {
        guard purchaseStore.isConfigured,
              !purchaseStore.isPro,
              !purchaseStore.isPurchasing else { return }

        AnalyticsReporter.shared.track(.paywallContinue(entryReason: "home_trial"))
        Task {
            let completed = await purchaseStore.purchase(plan)
            if !completed, !purchaseStore.statusMessage.isEmpty {
                showToast(purchaseStore.statusMessage)
            }
        }
    }

    private func openReviewPageAndScheduleReward() {
        dismissReviewRewardPrompt()
        let reviewURL = URL(string: "https://apps.apple.com/app/id6805741070?action=write-review")!
        print("[Minus Review Reward] Opening App Store URL: \(reviewURL.absoluteString)")
        openURL(reviewURL) { accepted in
            print("[Minus Review Reward] openURL accepted: \(accepted)")
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, photoLibrary.grantReviewReward() else { return }
            AnalyticsReporter.shared.track(.reviewRewardGranted)
            showToast(
                L10n.format(
                    "奖励已到账：额外获得 %@ 免费清理额度。",
                    FreeQuota.reviewRewardSummaryText
                )
            )
        }
    }

    private func dismissReviewRewardPrompt() {
        withAnimation(.easeOut(duration: 0.2)) {
            showReviewRewardPrompt = false
        }
    }

    /// 确认是免费用户才做额度限制：会员状态未同步完成前一律按已解锁处理，避免冷启动误拦。
    /// 远程关掉支付入口时也一并放开限制，否则用户既买不了又用不了。
    private var isFreeTier: Bool {
        remoteConfig.config.purchase.paywallEnabled
            && purchaseStore.isConfigured
            && purchaseStore.hasSyncedEntitlements
            && !purchaseStore.isPro
    }

    @ViewBuilder
    private var pageContent: some View {
        Group {
            switch selectedSection {
            case .home:
                homePage
            case .timeline:
                timePage
            case .pending:
                pendingPage
            case .insights:
                InsightsView(
                    showSettings: $showSettings,
                    progressTotalCount: photoLibrary.progressTotalCount,
                    reviewedCount: reviewedCount,
                    pendingCount: photoLibrary.pendingCount,
                    deletedCount: photoLibrary.deletedCount,
                    totalReleasedBytes: photoLibrary.totalReleasedBytes,
                    currentMonthAddedCount: photoLibrary.currentMonthAddedCount,
                    monthlyReleases: photoLibrary.monthlyReleases
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomBar(selection: $selectedSection, pendingCount: photoLibrary.pendingCount)
        }
    }

    private var homePage: some View {
        // 首页常驻，下钻页由 detailOverlay 盖在最上层，这样进出后 ScrollView 能保住原来的滚动位置
        HomeView(
                inbox: inbox,
                collections: photoLibrary.homeCollections,
                showImportPicker: $showImportPicker,
                isLibraryAuthorized: photoLibrary.isAuthorized,
                isLibraryAccessDenied: photoLibrary.isAccessDenied,
                isLibraryLoading: photoLibrary.isLoading,
                progressTotalCount: photoLibrary.progressTotalCount,
                reviewedCount: reviewedCount,
                remainingCount: max(photoLibrary.progressTotalCount - reviewedCount, 0),
                groups: photoLibrary.groups,
                isScanning: photoLibrary.isScanning || photoLibrary.isLoading,
                albumCount: photoLibrary.albums.count,
                hasShownResumeBanner: $hasShownResumeBanner,
                resumeReviewedCount: photoLibrary.resumeReviewedCount,
                resumeRemainingCount: photoLibrary.resumeRemainingCount,
                onOpenSearch: { showPhotoSearch = true },
                onOpenOrganize: beginOrganizing(collection:startingAt:),
                onHeroReady: {
                    isInitialHeroReady = true
                    reportInitialContentReady()
                },
                onOpenPaywall: {
                    paywallEntryReason = "home_offer"
                    showPaywall = true
                },
                onStartTrial: startHomeTrial,
                onOpenCategory: openCategory,
                onOpenAlbums: {
                    showAlbums = true
                    Task { await photoLibrary.loadAlbums() }
                },
            onLoadNextBatch: { Task { await photoLibrary.loadNextBatch() } },
            onRequestAccess: requestLibraryAccess,
            onScan: { Task { await photoLibrary.scanLibraryGroups() } }
        )
    }

    /// 所有下钻页都画在标签栏之外的这一层：进到分类、图片列表、相册里就该占满整屏
    @ViewBuilder
    private var detailOverlay: some View {
        if let category = selectedCategory {
            CategoryDetailView(
                section: category,
                onBack: { selectedCategoryID = nil },
                onOpenGroup: { selectedGroup = $0 }
            )
        }

        if let group = selectedGroup {
            PhotoListView(
                title: group.listTitle,
                photos: group.photos,
                allowsDuplicateRecommendation: group.kind == .exactDuplicates,
                onBack: { selectedGroup = nil },
                onStageForDeletion: { photos in
                    if stageForDeletion(photos, source: "group") {
                        selectedGroup = nil
                    }
                }
            )
        }

        if showAlbums {
            AlbumsView(
                albums: photoLibrary.albums,
                loadingAlbumID: loadingAlbumID,
                onBack: { showAlbums = false },
                onOpenAlbum: openAlbum,
                onCreateAlbum: { name in
                    Task {
                        let success = await photoLibrary.createAlbum(named: name)
                        showToast(success ? L10n.format("已新建「%@」", name) : L10n.text("新建相簿失败"))
                    }
                },
                onDeleteAlbum: { album in
                    Task {
                        let success = await photoLibrary.deleteAlbum(album)
                        showToast(success ? L10n.format("已删除「%@」", album.title) : L10n.text("删除相簿失败"))
                    }
                }
            )
        }

        if let selection = albumSelection {
            PhotoListView(
                title: selection.title,
                notice: selection.notice,
                photos: selection.photos,
                allowsDuplicateRecommendation: false,
                displayLimit: photoListLimit,
                onBack: { albumSelection = nil },
                onStageForDeletion: { photos in
                    guard stageForDeletion(photos, source: "album") else { return }
                    albumSelection = removingStaged(photos, from: albumSelection)
                }
            )
        }

        if let selection = timeSelection {
            PhotoListView(
                title: selection.title,
                notice: selection.notice,
                photos: selection.photos,
                allowsDuplicateRecommendation: false,
                displayLimit: photoListLimit,
                onBack: { timeSelection = nil },
                onStageForDeletion: { photos in
                    guard stageForDeletion(photos, source: "timeline") else { return }
                    timeSelection = removingStaged(photos, from: timeSelection)
                }
            )
        }

        if showPhotoSearch {
            PhotoSearchView(
                photoLibrary: photoLibrary,
                onDecision: { photo, decision in
                    photoLibrary.recordDecision(for: photo, delete: decision == .delete)
                    inbox.removeAll { $0.id == photo.id }
                },
                onUndoDecision: { photo in
                    photoLibrary.undoDecision(for: photo)
                    Task { await photoLibrary.loadNextBatch() }
                },
                onDeleteSession: deleteSessionPhotos,
                onBack: { showPhotoSearch = false }
            )
        }
    }

    /// 首页点了预览卡：合集卡只整理这个合集，兜底的队列卡接着整理整个图库。
    /// 两种都从卡片当时的封面那张开始。
    private func beginOrganizing(collection: PhotoCollectionPreview?, startingAt photo: PhotoItem) {
        guard let collection else {
            organizeStartPhoto = photo
            inbox = queue(from: inbox)
            startOrganizeSession(source: "library", collection: "all")
            isOrganizing = true
            return
        }

        // 合集是独立队列，不参与图库续批，所以顺序在这里一次定好
        let photos = photoLibrary.photos(in: collection.kind)
        guard !photos.isEmpty else { return }

        collectionQueue = rotated(photos, toStartAt: photo)
        collectionTotalCount = collectionQueue.count
        startOrganizeSession(source: "collection", collection: collection.id)
        organizingCollection = collection
    }

    private func startOrganizeSession(source: String, collection: String) {
        organizeSession = OrganizeAnalyticsSession(source: source, collection: collection)
        AnalyticsReporter.shared.track(.organizeStart(source: source, collection: collection))
    }

    /// 关闭整理页时上报这一轮的汇总；一张都没滑就退出也报，用来看“打开了却没整理”的比例
    private func finishOrganizeSession() {
        guard let session = organizeSession else { return }
        organizeSession = nil
        let deleteCount = session.decisions.values.filter { $0 }.count
        AnalyticsReporter.shared.track(.organizeEnd(
            source: session.source,
            collection: session.collection,
            reviewedCount: session.decisions.count,
            deleteCount: deleteCount,
            keepCount: session.decisions.count - deleteCount,
            durationSec: max(Int(Date().timeIntervalSince(session.startedAt)), 0)
        ))
    }

    /// 把指定的起点顶到队首。续批会整批替换队列，所以每次收到新队列都要再顶一次。
    private func queue(from photos: [PhotoItem]) -> [PhotoItem] {
        guard let startPhoto = organizeStartPhoto else { return photos }
        return rotated(photos, toStartAt: startPhoto)
    }

    /// 整体旋转而不是只把那张抽到最前，后面照片的相对顺序保持原样；
    /// 不在这批里（比如合集封面来自更早的时间段）就直接插到队首。
    private func rotated(_ photos: [PhotoItem], toStartAt photo: PhotoItem) -> [PhotoItem] {
        guard let index = photos.firstIndex(where: { $0.id == photo.id }) else {
            var result = photos
            result.insert(photo, at: 0)
            return result
        }
        return Array(photos[index...]) + Array(photos[..<index])
    }

    /// 分类里只有一个方案时没必要多一层，直接进图片列表
    private func openCategory(_ section: GroupSection) {
        if section.groups.count == 1, let group = section.groups.first {
            selectedGroup = group
        } else {
            selectedCategoryID = section.id
        }
    }

    /// 分类是按最新的分组数据现算的，删完照片回到分类页时会自然消失
    private var selectedCategory: GroupSection? {
        guard let selectedCategoryID else { return nil }
        return makeGroupSections(from: photoLibrary.groups).first { $0.id == selectedCategoryID }
    }

    private var timePage: some View {
        TimeGroupsView(
            granularity: $timeGranularity,
            parents: timeParents,
            children: timeChildren,
            selectedParentID: $selectedTimeParentID,
            isLibraryAuthorized: photoLibrary.isAuthorized,
            isLibraryAccessDenied: photoLibrary.isAccessDenied,
            isLibraryLoading: photoLibrary.isLoading,
            loadingBucketID: loadingBucketID,
            onOpenBucket: openTimeBucket,
            onRequestAccess: requestLibraryAccess
        )
    }

    /// 左边一列：按月看月份，按年看年份
    private var timeParents: [TimeBucket] {
        timeGranularity == .month ? photoLibrary.monthlyBuckets : photoLibrary.yearBuckets
    }

    /// 右边一列：左边选中的那个月下面的天，或那一年下面的月
    private var timeChildren: [TimeBucket] {
        guard let selectedTimeParentID else { return [] }
        let source = timeGranularity == .month ? photoLibrary.dailyBuckets : photoLibrary.monthlyBuckets
        return source.filter { $0.parentID == selectedTimeParentID }
    }

    private var pendingPage: some View {
        PendingView(
            pendingPhotos: $pendingPhotos,
            totalPendingCount: photoLibrary.pendingCount,
            onConfirmDelete: deletePendingPhotos,
            onRestore: { photo in
                pendingPhotos.removeAll { $0.id == photo.id }
                inbox.insert(photo, at: 0)
                photoLibrary.undoDecision(for: photo)
            },
            onOpenPhoto: { selectedPhoto = $0 }
        )
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toastMessage {
            VStack {
                Spacer()
                Text(toastMessage.text)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tidyInk)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    // 深色主题下改成抬起一层的深色胶囊，再补一道描边把它从页面底色里分出来
                    .background(Color.tidyElevated, in: Capsule())
                    .overlay(Capsule().stroke(Color.tidyHairline, lineWidth: 1))
                    .padding(.bottom, 104)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            .allowsHitTesting(false)
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        var imported: [PhotoItem] = []
        var failedCount = 0

        for item in items {
            if let identifier = item.itemIdentifier,
               let media = photoLibrary.item(forAssetIdentifier: identifier) {
                imported.append(media)
                continue
            }
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                do {
                    guard let video = try await item.loadTransferable(type: ImportedVideo.self) else {
                        failedCount += 1
                        continue
                    }
                    imported.append(try await video.makeItem())
                } catch {
                    failedCount += 1
                }
                continue
            }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                failedCount += 1
                continue
            }
            let isAnimated = AnimatedImageSource.isAnimated(data)

            imported.append(
                PhotoItem(
                    title: "刚刚导入",
                    detail: "来自照片图库",
                    pixelWidth: Int(image.size.width * image.scale),
                    pixelHeight: Int(image.size.height * image.scale),
                    byteSize: Int64(data.count),
                    artwork: .imported,
                    image: image,
                    tag: "新导入",
                    assetIdentifier: item.itemIdentifier,
                    motionKind: isAnimated ? .animatedImage : .none,
                    animatedImageData: isAnimated ? data : nil
                )
            )
        }

        pickerItems.removeAll()
        guard !imported.isEmpty else {
            if failedCount > 0 { showToast("所选项目暂时无法读取，请检查网络后重试") }
            return
        }
        let importedIDs = Set(imported.map(\.id))
        inbox.removeAll { importedIDs.contains($0.id) }
        inbox.insert(contentsOf: imported, at: 0)
        await photoLibrary.scanLibraryGroups()
        let successMessage = L10n.format("已导入 %lld 项", imported.count)
        let failureMessage = failedCount > 0 ? L10n.format("，%lld 项读取失败", failedCount) : ""
        showToast(successMessage + failureMessage)
    }

    /// 把一批照片加入待删除，返回是否真的加进去了，调用方据此决定要不要关掉当前列表。
    /// source 只用于埋点：group（智能分类）/ album（相簿）/ timeline（时间分组）
    private func stageForDeletion(_ photos: [PhotoItem], source: String) -> Bool {
        let existingIDs = Set(pendingPhotos.map(\.id))
        let candidates = photos.filter { !existingIDs.contains($0.id) }
        guard !candidates.isEmpty else {
            showToast("选中的照片已经处理过了")
            return false
        }

        pendingPhotos.insert(contentsOf: candidates, at: 0)
        let stagedIDs = Set(candidates.map(\.id))
        inbox.removeAll { stagedIDs.contains($0.id) }
        photoLibrary.stageForDeletion(photos: candidates)
        AnalyticsReporter.shared.track(.photosStaged(source: source, photoCount: candidates.count))
        showToast(L10n.format("已将 %lld 项加入待删除", candidates.count))
        return true
    }

    /// 时间分组里的照片是点开时才加载的，读完再弹列表
    private func openTimeBucket(_ bucket: TimeBucket) {
        guard loadingBucketID == nil else { return }
        loadingBucketID = bucket.id

        Task {
            let photos = await photoLibrary.loadPhotos(forBucket: bucket)
            loadingBucketID = nil

            guard !photos.isEmpty else {
                showToast("这一组照片读不出来")
                return
            }

            // 全量元数据交给列表，先筛选类型再应用显示上限，避免漏掉较早的视频。
            let notice = photos.count < bucket.count
                ? "部分项目已不可用或不在当前照片访问范围内"
                : nil

            timeSelection = PhotoListSelection(
                id: bucket.id,
                label: bucket.label,
                notice: notice,
                photos: photos
            )
        }
    }

    /// 相簿里的照片同样是点开时才加载
    private func openAlbum(_ album: PhotoAlbum) {
        guard loadingAlbumID == nil else { return }
        loadingAlbumID = album.id

        Task {
            let photos = await photoLibrary.loadPhotos(forAlbum: album)
            loadingAlbumID = nil

            guard !photos.isEmpty else {
                showToast("这个相簿里没有可显示的照片")
                return
            }

            let notice = photos.count < album.count
                ? "部分项目已不可用或不在当前照片访问范围内"
                : nil

            albumSelection = PhotoListSelection(
                id: album.id,
                label: album.title,
                notice: notice,
                photos: photos
            )
        }
    }

    /// 暂存之后把这几张从当前列表里去掉：照片还没真删，重新读会把它们又读回来
    private func removingStaged(
        _ photos: [PhotoItem],
        from selection: PhotoListSelection?
    ) -> PhotoListSelection? {
        guard let selection else { return nil }
        let removedIDs = Set(photos.map(\.id))
        let remaining = selection.photos.filter { !removedIDs.contains($0.id) }
        guard remaining.count != selection.photos.count else { return selection }

        return PhotoListSelection(
            id: selection.id,
            label: selection.label,
            notice: selection.notice,
            photos: remaining
        )
    }

    private func requestLibraryAccess() {
        if photoLibrary.isAccessDenied,
           let settingsURL = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(settingsURL)
        } else {
            Task { await photoLibrary.requestAccess() }
        }
    }

    private func showToast(_ message: String) {
        toastMessage = ToastMessage(message)
    }
}

/// 挂在整理页上的额度提示：评分奖励弹窗盖在整理页最上层，付费页从整理页再弹一层全屏
private struct OrganizeQuotaPrompts<Prompt: View>: ViewModifier {
    @Binding var showPaywall: Bool
    let paywallEntryReason: String
    let prompt: Prompt

    func body(content: Content) -> some View {
        content
            .overlay { prompt }
            .fullScreenCover(isPresented: $showPaywall) {
                PaywallView(entryReason: paywallEntryReason)
            }
    }
}

/// 一轮整理的埋点汇总。只在内存里记每张照片最后的决定（true 表示删除），撤销就移除，
/// 关闭整理页时一次性上报，不逐张发请求
private struct OrganizeAnalyticsSession {
    let source: String
    let collection: String
    let startedAt = Date()
    var decisions: [String: Bool] = [:]
}

/// 免费额度用完时的弹窗：主推开通会员（大标题、卖点、主按钮），
/// 评分领取额度退到底部做次要选项，只在还没领过评分奖励时出现（领过的直接进付费页）
private struct QuotaExceededPromptView: View {
    /// 评分奖励的额度说明，例如「20 张 / 100 MB」
    let rewardText: String
    let onUpgrade: () -> Void
    let onRate: () -> Void
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    /// 会员卖点，和付费页的权益文案保持一致
    private static let benefits: [(symbol: String, title: String)] = [
        ("infinity", "无限整理"),
        ("square.grid.2x2.fill", "全部智能分组"),
        ("lock.shield.fill", "100% 本机处理")
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.72)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            VStack(spacing: 0) {
                HStack {
                    Text("免费额度已用完")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.tidyAccent)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(Color.tidyAccent.opacity(0.12), in: Capsule())

                    Spacer()

                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.tidyMuted)
                            .frame(width: 32, height: 32)
                            .background(Color.tidyElevated, in: Circle())
                    }
                    .accessibilityLabel(Text("取消"))
                }

                proArtwork
                    .padding(.top, 8)

                Text("升级 Minus Pro")
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.tidyInk)
                    .multilineTextAlignment(.center)
                    .padding(.top, 14)

                Text("解锁无限整理与清理")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.tidyMuted)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)

                benefitList
                    .padding(.top, 18)

                // 主按钮：开会员
                Button(action: onUpgrade) {
                    HStack(spacing: 9) {
                        Image(systemName: "crown.fill")
                        Text("解锁 Minus Pro")
                    }
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.tidyOnAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(
                        LinearGradient(
                            colors: [Color.tidyAccent, Color.tidyKeep],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .shadow(color: Color.tidyAccent.opacity(0.26), radius: 14, y: 7)
                }
                .buttonStyle(CardPressStyle())
                .padding(.top, 20)

                // 次要选项：去评分换一次额度。描边浅色按钮，明显比主按钮弱一级
                Button(action: onRate) {
                    HStack(spacing: 7) {
                        Image(systemName: "star.fill")
                            .foregroundStyle(Color.tidyAmber)
                        Text(L10n.format("评分领取 %@ 免费额度", rewardText))
                            .foregroundStyle(Color.tidyInk)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.tidyHairline, lineWidth: 1)
                    )
                }
                .buttonStyle(CardPressStyle())
                .padding(.top, 10)
            }
            .padding(22)
            .frame(maxWidth: 390)
            .background(
                LinearGradient(
                    colors: [Color.tidyElevated, Color.tidySurface],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 28, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.42), radius: 34, y: 18)
            .padding(.horizontal, 24)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }

    /// 三条会员权益，放在一块浅底里，每条前面一个柠檬色小图标
    private var benefitList: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Self.benefits, id: \.title) { benefit in
                HStack(spacing: 12) {
                    Image(systemName: benefit.symbol)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.tidyAccent)
                        .frame(width: 28, height: 28)
                        .background(Color.tidyAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    // title 是纯 String，不会自动查表，必须显式走 L10n
                    Text(L10n.text(benefit.title))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.tidyInk)
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(Color.tidyKeep)
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.tidyHairline, lineWidth: 1)
        )
    }

    /// 顶部的皇冠：外圈呼吸、皇冠轻轻摇摆，两颗小星星闪烁
    private var proArtwork: some View {
        ZStack {
            Circle()
                .fill(Color.tidyAccent.opacity(0.10))
                .frame(width: 96, height: 96)
                .scaleEffect(isAnimating ? 1.08 : 0.94)

            Circle()
                .stroke(Color.tidyAccent.opacity(isAnimating ? 0.08 : 0.32), lineWidth: 2)
                .frame(width: 88, height: 88)
                .scaleEffect(isAnimating ? 1.22 : 0.92)

            Image(systemName: "crown.fill")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Color.tidyOnAccent)
                .frame(width: 64, height: 64)
                .background(
                    LinearGradient(
                        colors: [Color.tidyAccent, Color.tidyKeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: Circle()
                )
                .rotationEffect(.degrees(isAnimating ? 4 : -4))
                .shadow(color: Color.tidyAccent.opacity(0.32), radius: 14)

            Image(systemName: "sparkle")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.tidyAccent)
                .offset(x: isAnimating ? 54 : 48, y: isAnimating ? -36 : -29)
                .opacity(isAnimating ? 1 : 0.45)

            Image(systemName: "sparkle")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.tidyKeep)
                .offset(x: isAnimating ? -50 : -43, y: isAnimating ? 33 : 27)
                .opacity(isAnimating ? 0.55 : 1)
        }
        .frame(height: 104)
        .accessibilityHidden(true)
    }
}

/// iOS 16 兼容的空状态，代替 iOS 17 才提供的 ContentUnavailableView。
private struct TidyEmptyStateView: View {
    let title: String
    let systemImage: String
    var description: String? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(Color.tidyMuted)

            Text(title)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(Color.tidyInk)
                .multilineTextAlignment(.center)

            if let description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.tidyMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 通用图片列表要展示的一批照片
private struct PhotoListSelection: Identifiable {
    let id: String
    let label: String
    /// 标题下面的一行说明，没有就不显示
    let notice: String?
    let photos: [PhotoItem]

    /// 张数跟着内容走，处理掉几张标题就跟着变
    var title: String {
        L10n.format("%@ · %@ 项", L10n.text(label), photos.count.formatted())
    }
}

/// 带唯一 id，重复触发同一条文案时也能重置自动消失的计时
private struct ToastMessage: Equatable, Identifiable {
    let id = UUID()
    let text: String

    init(_ text: String) {
        self.text = L10n.text(text)
    }
}

/// 智能分组已经并进首页，标签栏是首页、按时间、待删除、统计
private enum AppSection: String, CaseIterable, Identifiable {
    case home
    case timeline
    case pending
    case insights

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: L10n.text("首页")
        case .timeline: L10n.text("时间")
        case .pending: L10n.text("待删除")
        case .insights: L10n.text("统计")
        }
    }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .timeline: "calendar"
        case .pending: "trash.fill"
        case .insights: "chart.bar.fill"
        }
    }
}

/// 左边一列按月还是按年定位：按月时右边是那个月的每一天，按年时右边是那一年的每个月
private enum TimeGranularity: String, CaseIterable, Identifiable {
    case month
    case year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .month: L10n.text("按月")
        case .year: L10n.text("按年")
        }
    }

    /// 汇总文案里的单位，说的是左边一列
    var unit: String {
        switch self {
        case .month: L10n.text("个月")
        case .year: L10n.text("年")
        }
    }
}

private struct BottomBar: View {
    @Binding var selection: AppSection
    let pendingCount: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppSection.allCases) { section in
                Button {
                    selection = section
                } label: {
                    VStack(spacing: 5) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: section.symbol)
                                .font(.system(size: 22, weight: .bold))

                            if section == .pending, pendingCount > 0 {
                                Text(pendingCount > 99 ? "99+" : "\(pendingCount)")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 3)
                                    .background(Color.tidyDanger, in: Capsule())
                                    .offset(x: 16, y: -12)
                            }
                        }
                        Text(section.title)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(selection == section ? Color.tidyAccent : Color.tidyInk)
                    .frame(maxWidth: .infinity)
                    .frame(height: 66)
                    .background(
                        selection == section ? Color.tidyAccent.opacity(0.13) : .clear,
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.10), radius: 18, y: 8)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

/// 首页：顶部日期与品牌名，接着是进度看板，再是合集轮播大图（点开进整理页），往下是分组磁贴和相册管理
private struct HomeView: View {
    @EnvironmentObject private var purchaseStore: PurchaseStore
    @EnvironmentObject private var remoteConfig: RemoteConfigStore

    /// 首页只展示不修改，所有决定都在整理页里做
    let inbox: [PhotoItem]
    /// 轮播的几个合集：最近新增、那年今月、截图之类，每个占一张卡
    let collections: [PhotoCollectionPreview]
    @Binding var showImportPicker: Bool
    let isLibraryAuthorized: Bool
    let isLibraryAccessDenied: Bool
    let isLibraryLoading: Bool
    let progressTotalCount: Int
    let reviewedCount: Int
    let remainingCount: Int
    let groups: [PhotoGroup]
    let isScanning: Bool
    let albumCount: Int
    @Binding var hasShownResumeBanner: Bool
    let resumeReviewedCount: Int
    let resumeRemainingCount: Int
    let onOpenSearch: () -> Void
    /// 点了预览卡：合集为 nil 表示这张卡展示的是整理队列本身；
    /// 照片是卡片当时的封面，整理页要从它开始
    let onOpenOrganize: (PhotoCollectionPreview?, PhotoItem) -> Void
    let onHeroReady: () -> Void
    let onOpenPaywall: () -> Void
    let onStartTrial: (PaywallPlan) -> Void
    let onOpenCategory: (GroupSection) -> Void
    let onOpenAlbums: () -> Void
    let onLoadNextBatch: () -> Void
    let onRequestAccess: () -> Void
    let onScan: () -> Void

    @State private var isResumeBannerVisible = false
    /// 首页轮播使用两个槽位：一个展示，另一个在背后预加载。
    @State private var heroSlotIDs: [String?] = [nil, nil]
    @State private var activeHeroSlot = 0
    @State private var readyHeroIDs: Set<String> = []
    @State private var wantsHeroSwitch = false
    /// 进度条实际画出来的比例，单独存一份才能做从 0 长出来的入场动画
    @State private var displayedProgress: Double = 0
    /// 用户手动选中的那屏。非空时自动轮播暂停，停在这里
    @State private var pinnedHeroID: String?
    /// 刚在滚轮里选中、正等封面就绪再切过去的那屏
    @State private var pendingHeroID: String?
    /// 标题滚轮：按住标题后展开，上下拖动切换分类
    @State private var isTitleWheelActive = false
    /// 展开那一刻停在第几项，拖动距离在它基础上换算
    @State private var titleWheelBaseIndex = 0
    @State private var titleWheelDrag: CGFloat = 0
    /// 上一次震动反馈时所在的项，跨过一项才震一下
    @State private var titleWheelLastIndex = 0
    /// 手势被系统打断（来电、切后台）时 onEnded 不会触发，靠这个状态复位兜底收起滚轮
    @GestureState private var isTitleWheelTouching = false
    /// 松手后这一小段时间里按钮的点击不算数，免得选完分类顺手打开了整理页
    @State private var heroTapSuppressedUntil = Date.distantPast

    /// 首页可以滚动，图片区域用固定高度就够，不必再按屏幕反推；加高一些让合集大图更有沉浸感
    private static let heroHeight: CGFloat = 320
    /// 首页所有卡片统一的圆角
    private static let cardRadius: CGFloat = 26
    private static let categoryColumns = [
        GridItem(.flexible(minimum: 0), spacing: 12),
        GridItem(.flexible(minimum: 0), spacing: 12)
    ]
    /// 进度容器还在打磨，先藏起来。开回来时卡片会加高，给小物件留出堆积和晃动的空间。
    private static let showsProgressJar = false
    private static let progressCardHeight: CGFloat = 158
    private static let progressCardRadius: CGFloat = 26

    /// TODO: 临时写死 70% 用来调进度容器，验证完把这里改回 actualProgress
    private var progress: Double {
        actualProgress
    }

    private var actualProgress: Double {
        guard progressTotalCount > 0 else { return 0 }
        return min(max(Double(reviewedCount) / Double(progressTotalCount), 0), 1)
    }

    private var sections: [GroupSection] {
        makeGroupSections(from: groups)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                titleRow
                progressCard
                heroSection
                membershipOffer
                groupsHeader
                groupsContent
                albumsEntry
                PrivacyFootnote()
                    .padding(.top, 4)
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 标题滚轮展开后上下拖动归滚轮，首页不跟着滚
        .scrollDisabled(isTitleWheelActive)
        .onChange(of: isTitleWheelTouching) { touching in
            if !touching { endTitleWheel() }
        }
        .overlay(alignment: .top) { resumeBanner }
        .task(id: resumeReviewedCount) {
            guard resumeReviewedCount > 0, !hasShownResumeBanner else { return }
            hasShownResumeBanner = true

            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                isResumeBannerVisible = true
            }

            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard !Task.isCancelled else { return }
            dismissResumeBanner()
        }
        // 合集重算后要从头开始轮播，id 变了就重启这个循环
        .task(id: heroSlides.map(\.id)) {
            await rotateHeroPreview()
        }
    }

    /// 日期小字压在品牌名上方，像一份当天的整理清单；右边是搜索
    private var titleRow: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 1) {
                // 模板交给系统按语言排版：中文“10月27日 星期二”，英文“Tuesday, October 27”
                Text(L10n.date(Date(), template: "MMMMdEEEE"))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tidyMuted)

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("Minus")
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .tracking(-0.8)
                        .foregroundStyle(Color.tidyInk)
                    // 品牌色小圆点当句号，呼应“做减法”
                    Circle()
                        .fill(Color.tidyAccent)
                        .frame(width: 8, height: 8)
                }
            }

            Spacer()

            if isLibraryAuthorized {
                Button(action: onOpenSearch) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color.tidyAccent)
                        .frame(width: 44, height: 44)
                        .background(Color.tidySurface, in: Circle())
                        .overlay(Circle().stroke(Color.tidyHairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("搜索照片")
            }
        }
    }

    /// 进度卡：左边一个进度环、环心是百分比；右边“已整理”大数字领头，下面两格小数字（还剩 / 共计）。
    /// 待删除数量标签栏上已经有角标，这里不再重复。
    /// 进度容器打开时小物件在文字底下堆，所以文字带点阴影保证压在上面也读得清。
    private var progressCard: some View {
        ZStack(alignment: .topLeading) {
            if Self.showsProgressJar {
                ProgressJarView(progress: progress, cornerRadius: Self.progressCardRadius)
            }

            HStack(spacing: 18) {
                progressDial

                if progressTotalCount > 0 {
                    progressSummary
                } else {
                    // 总数还没统计出来时数字都是 0，没有意义，换成一行加载提示
                    Text("正在统计相册…")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.tidyMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            // 文字压在小物件上面，得靠阴影保证读得清；藏起容器时就不需要了
            .shadow(color: Color.tidyBackground.opacity(Self.showsProgressJar ? 0.9 : 0), radius: 6)
            .padding(16)
        }
        .frame(maxWidth: .infinity)
        // 没有容器就不撑高，卡片贴着内容走，底下不留空白
        .frame(height: Self.showsProgressJar ? Self.progressCardHeight : nil)
        .background {
            ZStack {
                Color.tidySurface
                // 进度环背后一团很淡的柠檬色光，让这张卡和其他灰卡片区分开
                RadialGradient(
                    colors: [Color.tidyAccent.opacity(0.13), Color.tidyAccent.opacity(0)],
                    center: UnitPoint(x: 0.14, y: 0.5),
                    startRadius: 0,
                    endRadius: 160
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: Self.progressCardRadius, style: .continuous))
        }
        // 掉进来的小物件不能露到卡片外面
        .clipShape(RoundedRectangle(cornerRadius: Self.progressCardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.progressCardRadius, style: .continuous)
                .stroke(Color.tidyHairline, lineWidth: 1)
        )
    }

    private static let progressDialSize: CGFloat = 92
    private static let progressDialLineWidth: CGFloat = 11

    /// 进度环：从 12 点钟方向顺时针走，绿到柠檬的渐变带一点光晕，环心是百分比。
    /// 进首页时从 0 转到当前进度，之后跟着整理结果平滑变化
    private var progressDial: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.07), lineWidth: Self.progressDialLineWidth)

            Circle()
                // 进度很小时也留一个圆点头，不至于看起来像没开始
                .trim(from: 0, to: displayedProgress > 0 ? max(displayedProgress, 0.012) : 0)
                .stroke(
                    AngularGradient(
                        colors: [Color.tidyKeep, Color.tidyAccent],
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360 * max(displayedProgress, 0.012))
                    ),
                    style: StrokeStyle(lineWidth: Self.progressDialLineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: Color.tidyAccent.opacity(0.4), radius: 6)

            if progressTotalCount > 0 {
                // 数字大、百分号小，一眼先看到数
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(progressPercent)")
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                        .contentTransition(.numericText())
                    Text("%")
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.tidyMuted)
                }
                .monospacedDigit()
                .foregroundStyle(Color.tidyInk)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.tidyAccent)
            }
        }
        .frame(width: Self.progressDialSize, height: Self.progressDialSize)
        .onAppear {
            withAnimation(.spring(response: 0.9, dampingFraction: 0.85).delay(0.15)) {
                displayedProgress = progress
            }
        }
        .onChange(of: progress) { value in
            withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) {
                displayedProgress = value
            }
        }
        .accessibilityHidden(true)
    }

    /// 没整理完之前最多显示 99，避免 99.6% 被四舍五入成 100% 却还剩几张
    private var progressPercent: Int {
        progress >= 1 ? 100 : min(Int(progress * 100), 99)
    }

    /// 进度环右边的文字：“已整理”是主角用大号柠檬色数字，“还剩 / 共计”放成下面并排的两个小格
    private var progressSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text("已整理")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tidyMuted)
                Text(reviewedCount.formatted())
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .tracking(-0.6)
                    .monospacedDigit()
                    .foregroundStyle(Color.tidyAccent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: 8) {
                progressChip(label: "还剩", value: remainingCount, tint: .tidyInk)
                progressChip(label: "共计", value: progressTotalCount, tint: .tidyMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 小格：浅底圆角块，左边说明、右边数字
    private func progressChip(label: String, value: Int, tint: Color) -> some View {
        HStack(spacing: 6) {
            // label 是纯 String，不会自动查表，必须显式走 L10n
            Text(L10n.text(label))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.tidyMuted)
            Spacer(minLength: 0)
            Text(value.formatted())
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// 首页预览：第一屏“全部”是整个图库从最新开始，后面是各个合集。
    /// 没手动选过时每 7 秒自动换下一个，标题跟着上下滚动；按住标题会展开成滚轮，上下拖动切换，
    /// 选过之后就停在用户选的那个。
    @ViewBuilder
    private var heroSection: some View {
        if !isLibraryAuthorized || (isLibraryLoading && inbox.isEmpty) {
            LibraryConnectionView(
                isLoading: isLibraryLoading,
                isAccessDenied: isLibraryAccessDenied,
                contentHeight: Self.heroHeight,
                onRequestAccess: onRequestAccess
            )
        } else if inbox.isEmpty {
            EmptyInboxView(
                showImportPicker: $showImportPicker,
                isAuthorized: true,
                remainingCount: remainingCount,
                contentHeight: Self.heroHeight,
                onLoadNextBatch: onLoadNextBatch,
                onRequestAccess: onRequestAccess
            )
        } else if let slide = currentSlide {
            let titleSlide = highlightedSlide ?? slide

            // 点的是哪个合集、封面是哪张，整理页就从那儿开始
            Button {
                // 刚用标题滚轮选完松手，这一下不算点卡片
                guard !isTitleWheelActive, Date() >= heroTapSuppressedUntil else { return }
                onOpenOrganize(slide.collection, slide.cover)
            } label: {
                ZStack(alignment: .bottomLeading) {
                    heroCard(at: 0)
                    heroCard(at: 1)

                    // 滚轮展开时压暗照片，视线集中到分类名上
                    // 轮播卡片里正在展示的那张是 zIndex(1)，叠在上面的层必须更高，否则一切换就被新卡片盖住
                    Color.black
                        .opacity(isTitleWheelActive ? 0.42 : 0)
                        .allowsHitTesting(false)
                        .zIndex(2)

                    heroTitleBlock(titleSlide)
                        .padding(.leading, 18)
                        .padding(.bottom, 18)
                        // 右下角是“开始整理”圆钮，标题区给它让出位置
                        .padding(.trailing, 18 + PhotoCard.startButtonSize + 14)
                        .zIndex(3)
                }
                .frame(height: Self.heroHeight)
                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            }
            .buttonStyle(CardPressStyle())
            // 字符串插值不会查本地化表，带变量的文案统一交给 L10n.format
            .accessibilityLabel(L10n.format("整理%@ · %lld 项", L10n.text(titleSlide.title), titleSlide.count))
            .accessibilityHint("打开整理页")
            // 旁白用户上下轻扫切换合集，对应按住标题拖动
            .accessibilityAdjustableAction { direction in
                stepHero(by: direction == .increment ? 1 : -1)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// 标题滚轮里每一行的高度，静止时的标题行也用这个高度，展开和收起时位置能严丝合缝
    private static let heroTitleRowHeight: CGFloat = 38

    /// 大卡左下角的标题区：分类名 + 封面日期。分类名就是切换入口——
    /// 自动轮播时新名字从下往上推入，按住后展开成上下滚轮，松手选中。
    private func heroTitleBlock(_ slide: HeroSlide) -> some View {
        let canSwitch = heroSlides.count > 1

        return VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .leading) {
                HStack(spacing: 8) {
                    heroTitleLabel(slide.title)
                    if canSwitch {
                        // 上下箭头暗示这个标题可以上下拨动
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .id(slide.id)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)
                ))
            }
            .frame(height: Self.heroTitleRowHeight, alignment: .leading)
            // 裁在一行高度里，换标题时像翻牌一样上下滚过去
            .clipped()
            // 滚轮激活时静止标题让位给滚轮中间那行，两者字号位置一致，交叉淡化看不出切换
            .opacity(isTitleWheelActive ? 0 : 1)
            // 滚轮挂在裁切之后，可以超出这一行向上下展开
            .overlay(alignment: .leading) {
                if canSwitch {
                    heroTitleWheel
                        .opacity(isTitleWheelActive ? 1 : 0)
                }
            }

            // 封面那张自己的拍摄日期，提示这是合集里的哪个时间段
            Text(slide.cover.title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .id(slide.cover.id)
                .transition(.opacity)
                .opacity(isTitleWheelActive ? 0 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // 用 simultaneous：普通 .gesture 挂在 Button 里会吞掉轻点，点标题就打不开整理页了
        .simultaneousGesture(canSwitch ? titleWheelGesture : nil)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isTitleWheelActive)
    }

    private func heroTitleLabel(_ title: String) -> some View {
        // title 是纯 String，不会自动查表，必须显式走 L10n
        Text(L10n.text(title))
            .font(.system(size: 30, weight: .heavy, design: .rounded))
            .tracking(-0.4)
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(height: Self.heroTitleRowHeight, alignment: .leading)
    }

    /// 按住标题后展开的滚轮：当前项居中，上下的分类越远越小越淡，上下两端再用渐变遮罩淡出
    private var heroTitleWheel: some View {
        let position = titleWheelPosition

        return ZStack(alignment: .leading) {
            ForEach(Array(heroSlides.enumerated()), id: \.element.id) { index, slide in
                let distance = abs(CGFloat(index) - position)
                // 只画中间附近几行，离得远的反正被遮罩挡住
                if distance < 3 {
                    heroTitleLabel(slide.title)
                        .scaleEffect(1 - min(distance, 2) * 0.14, anchor: .leading)
                        .opacity(1 - Double(min(distance, 2.2)) * 0.38)
                        .offset(y: (CGFloat(index) - position) * Self.heroTitleRowHeight)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.heroTitleRowHeight * 5)
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.3),
                    .init(color: .black, location: 0.7),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 滚轮当前停在第几项（带小数，拖动时连续变化）。手指往上推，下一项从下面滚上来；
    /// 拖过两端只走三分之一，像系统滚轮那样有阻尼
    private var titleWheelPosition: CGFloat {
        let raw = CGFloat(titleWheelBaseIndex) - titleWheelDrag / Self.heroTitleRowHeight
        let maxIndex = CGFloat(max(heroSlides.count - 1, 0))
        if raw < 0 { return raw / 3 }
        if raw > maxIndex { return maxIndex + (raw - maxIndex) / 3 }
        return raw
    }

    private var titleWheelIndex: Int {
        min(max(Int(titleWheelPosition.rounded()), 0), max(heroSlides.count - 1, 0))
    }

    /// 先按住 0.25 秒展开滚轮，再拖动切换。按住前手指一动就失败，首页照常上下滚动
    private var titleWheelGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.25, maximumDistance: 10)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($isTitleWheelTouching) { value, state, _ in
                if case .second(true, _) = value { state = true }
            }
            .onChanged { value in
                guard case let .second(true, drag) = value else { return }
                if !isTitleWheelActive { beginTitleWheel() }
                updateTitleWheel(translation: drag?.translation.height ?? 0)
            }
            .onEnded { _ in
                endTitleWheel()
            }
    }

    @MainActor
    private func beginTitleWheel() {
        titleWheelBaseIndex = heroSlides.firstIndex { $0.id == highlightedHeroID } ?? 0
        titleWheelDrag = 0
        titleWheelLastIndex = titleWheelBaseIndex
        isTitleWheelActive = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.8)
    }

    @MainActor
    private func updateTitleWheel(translation: CGFloat) {
        titleWheelDrag = translation
        let index = titleWheelIndex
        if index != titleWheelLastIndex {
            titleWheelLastIndex = index
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    /// 松手：滚轮吸附到最近的一项并收起，然后切到那一屏并钉住
    @MainActor
    private func endTitleWheel() {
        guard isTitleWheelActive, heroSlides.indices.contains(titleWheelIndex) else {
            isTitleWheelActive = false
            return
        }

        let index = titleWheelIndex
        let id = heroSlides[index].id
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            titleWheelBaseIndex = index
            titleWheelDrag = 0
        }
        isTitleWheelActive = false
        heroTapSuppressedUntil = Date().addingTimeInterval(0.4)
        // 按住又放回原处不算切换
        if id != highlightedHeroID {
            AnalyticsReporter.shared.track(.homeCollectionSwitch(method: "wheel", collection: id))
        }
        selectHero(id)
    }

    /// 旁白的上下轻扫：按顺序切到前一个或后一个合集
    @MainActor
    private func stepHero(by step: Int) {
        guard let index = heroSlides.firstIndex(where: { $0.id == highlightedHeroID }) else { return }
        let target = index + step
        guard heroSlides.indices.contains(target) else { return }
        AnalyticsReporter.shared.track(.homeCollectionSwitch(method: "accessibility", collection: heroSlides[target].id))
        selectHero(heroSlides[target].id)
    }

    /// 轮播的一屏内容：第一屏固定是整个图库，后面是各个合集
    private struct HeroSlide {
        let id: String
        /// 卡片上的大标题，也是标题滚轮里的一行
        let title: String
        /// 已经本地化好的范围说明，例如「最近一周」「2024年10月」
        let scopeText: String
        let count: Int
        let symbol: String
        let cover: PhotoItem
        /// nil 表示这张卡展示的是整个图库的整理队列，不是某个合集
        let collection: PhotoCollectionPreview?
    }

    private static let allSlideID = "all"

    private var heroSlides: [HeroSlide] {
        var slides: [HeroSlide] = []

        // 整理队列本来就是按拍摄时间从新到旧、跳过已整理的，队首就是最新一张没整理过的
        if let cover = inbox.first {
            slides.append(HeroSlide(
                id: Self.allSlideID,
                title: "全部照片",
                scopeText: L10n.text("从最新一张开始"),
                // 图库里所有没整理过的，不只是已经装进队列的这一批
                count: remainingCount > 0 ? remainingCount : inbox.count,
                symbol: "photo.on.rectangle.angled",
                cover: cover,
                collection: nil
            ))
        }

        slides += collections.map { collection in
            HeroSlide(
                id: collection.id,
                title: collection.kind.title,
                scopeText: collection.kind.scopeText,
                count: collection.count,
                symbol: collection.kind.symbol,
                cover: collection.cover,
                collection: collection
            )
        }
        return slides
    }

    /// 标题显示哪一屏：用户刚选的那个（封面可能还在加载）优先，否则是正在展示的那个
    private var highlightedHeroID: String? {
        pendingHeroID ?? currentSlide?.id
    }

    private var highlightedSlide: HeroSlide? {
        heroSlides.first { $0.id == highlightedHeroID }
    }

    private var currentSlide: HeroSlide? {
        slide(at: activeHeroSlot) ?? heroSlides.first
    }

    private func slide(at slot: Int) -> HeroSlide? {
        guard heroSlotIDs.indices.contains(slot) else { return nil }
        if let id = heroSlotIDs[slot] {
            return heroSlides.first { $0.id == id }
        }
        // 第一次 task 启动前先显示第一个合集，避免首页出现一帧空白。
        if slot == 0, heroSlotIDs.allSatisfy({ $0 == nil }) {
            return heroSlides.first
        }
        return nil
    }

    @ViewBuilder
    private func heroCard(at slot: Int) -> some View {
        if let slide = slide(at: slot) {
            // 标题不画在卡片里，由 heroSection 统一叠一层，换照片时标题能单独做上下滚动
            PhotoCard(
                photo: slide.cover,
                scopeText: slide.scopeText,
                count: slide.count,
                symbol: slide.symbol,
                isActive: activeHeroSlot == slot,
                cardHeight: Self.heroHeight,
                onArtworkReady: onHeroReady,
                onMediaReady: markHeroReady
            )
            // 带上封面 id：“全部”这屏的封面是队首，整理一张就换一张，id 不变的话 ArtworkView 不会重新取图
            .id("\(slot)-\(slide.id)-\(slide.cover.id)")
            .opacity(activeHeroSlot == slot ? 1 : 0)
            .allowsHitTesting(activeHeroSlot == slot)
            .zIndex(activeHeroSlot == slot ? 1 : 0)
        }
    }

    @MainActor
    private func rotateHeroPreview() async {
        let slides = heroSlides
        guard !slides.isEmpty else {
            heroSlotIDs = [nil, nil]
            readyHeroIDs.removeAll()
            return
        }

        // 合集列表变了会重启这里；用户手动选的那屏还在就接着停在那，不在了才回到第一屏
        let pinnedIndex = pinnedHeroID.flatMap { id in slides.firstIndex { $0.id == id } }
        if pinnedIndex == nil { pinnedHeroID = nil }
        let startIndex = pinnedIndex ?? 0

        // 合集按固定顺序轮播，不再随机，所以背后那个槽位预载的就是下一个合集
        heroSlotIDs = [
            slides[startIndex].id,
            slides.count > 1 ? slides[(startIndex + 1) % slides.count].id : nil
        ]
        activeHeroSlot = 0
        readyHeroIDs.removeAll()
        wantsHeroSwitch = false
        pendingHeroID = nil

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(7))
            guard !Task.isCancelled else { return }
            // 用户手动选过就不再自动换；正按着标题滚轮挑选时也别在底下换图
            guard pinnedHeroID == nil, !isTitleWheelActive else { continue }
            wantsHeroSwitch = true
            advanceHeroIfReady()
        }
    }

    /// 用标题滚轮选中了某个分类：钉住这一屏，把它放进背后的槽位，封面就绪就交叉淡化过去
    @MainActor
    private func selectHero(_ id: String) {
        pinnedHeroID = id
        UISelectionFeedbackGenerator().selectionChanged()

        guard currentSlide?.id != id else {
            // 点的就是正在展示的那屏（或在切换途中又点回来），取消待切换即可
            pendingHeroID = nil
            wantsHeroSwitch = false
            return
        }

        let targetSlot = activeHeroSlot == 0 ? 1 : 0
        if heroSlotIDs[targetSlot] != id {
            heroSlotIDs[targetSlot] = id
            // 槽位换了内容，得等新封面重新报就绪
            if let slide = heroSlides.first(where: { $0.id == id }) {
                readyHeroIDs.remove(slide.cover.id)
            }
        }

        pendingHeroID = id
        wantsHeroSwitch = true
        advanceHeroIfReady()

        // 封面迟迟没好（比如要从 iCloud 下）也不能让点击像没反应，最多等 0.8 秒先切过去，卡片里会转圈
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard pendingHeroID == id else { return }
            advanceHeroIfReady(force: true)
        }
    }

    /// 就绪状态按封面照片的 id 记，PhotoCard 回调给的就是照片 id
    @MainActor
    private func markHeroReady(_ id: String) {
        readyHeroIDs.insert(id)
        advanceHeroIfReady()
    }

    /// force 用于手动选择的兜底：封面没就绪也切过去
    @MainActor
    private func advanceHeroIfReady(force: Bool = false) {
        let nextSlot = activeHeroSlot == 0 ? 1 : 0
        // 滚轮展开期间照片保持不动，松手选完再统一切
        guard wantsHeroSwitch,
              force || !isTitleWheelActive,
              let nextSlide = slide(at: nextSlot),
              force || readyHeroIDs.contains(nextSlide.cover.id) else { return }

        withAnimation(.easeInOut(duration: 0.55)) {
            activeHeroSlot = nextSlot
        }
        wantsHeroSwitch = false
        pendingHeroID = nil

        // 等交叉淡化完成再替换已经退到背后的槽位，避免旧画面提前消失露出底色。
        let preloadSlot = nextSlot == 0 ? 1 : 0
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            // 这期间用户又点了别的标签，背后槽位已被占用，不能再覆盖
            guard !Task.isCancelled, activeHeroSlot == nextSlot, !wantsHeroSwitch else { return }

            let slides = heroSlides
            guard let currentIndex = slides.firstIndex(where: { $0.id == nextSlide.id }) else { return }

            let preload = slides[(currentIndex + 1) % slides.count]
            let previousPreloadID = heroSlotIDs[preloadSlot]
            heroSlotIDs[preloadSlot] = preload.id
            if preload.id != previousPreloadID {
                readyHeroIDs.remove(preload.cover.id)
            }
        }
    }

    @ViewBuilder
    private var membershipOffer: some View {
        if shouldShowMembershipOffer {
            Button(action: openMembershipOffer) {
                HStack(spacing: 14) {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.tidyOnAccent)
                        .frame(width: 48, height: 48)
                        .background(.black.opacity(0.16), in: Circle())

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Text(membershipOfferTitle)
                                .font(.system(size: 18, weight: .black, design: .rounded))
                                // 宽度不够时让标题缩放让位，而不是把角标挤成两行
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Text(membershipOfferBadge)
                                .font(.system(size: 10, weight: .black, design: .rounded))
                                .foregroundStyle(Color.tidyAccent)
                                .lineLimit(1)
                                // 角标按内容取足宽度、不参与压缩，否则英文会换行
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.74), in: Capsule())
                        }
                        if let subtitle = membershipOfferSubtitle {
                            Text(subtitle)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .opacity(0.72)
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                        }
                    }

                    Spacer(minLength: 4)

                    Group {
                        if purchaseStore.isPurchasing {
                            ProgressView()
                                .tint(Color.tidyOnAccent)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .black))
                        }
                    }
                    .frame(width: 34, height: 34)
                    .background(.black.opacity(0.10), in: Circle())
                }
                .foregroundStyle(Color.tidyOnAccent)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(
                        colors: [Color.tidyAccent, Color.tidyKeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(.white.opacity(0.30), lineWidth: 1)
                }
                .shadow(color: Color.tidyAccent.opacity(0.18), radius: 14, y: 7)
            }
            .buttonStyle(.plain)
            .disabled(purchaseStore.isPurchasing || purchaseStore.isPro)
            .accessibilityLabel(membershipOfferAccessibilityLabel)
        }
    }

    private func openMembershipOffer() {
        if let trial = eligibleHomeTrial {
            onStartTrial(trial.plan)
        } else {
            onOpenPaywall()
        }
    }

    /// 首页只宣传 StoreKit 确实返回、且 RevenueCat 判定当前用户可领取的试用。
    private var eligibleHomeTrial: (plan: PaywallPlan, days: Int)? {
        for plan in purchaseStore.plans {
            if let days = purchaseStore.eligibleFreeTrialDays(for: plan) {
                return (plan, days)
            }
        }
        return nil
    }

    /// 标题两种状态都是“升级 Minus Pro”，能领试用时后面的小胶囊换成“免费试用”。
    /// 首页不展示续费价格，续费金额由随后弹出的 Apple 支付确认页展示
    private var membershipOfferTitle: String {
        L10n.text("升级 Minus Pro")
    }

    private var membershipOfferBadge: String {
        guard eligibleHomeTrial != nil else { return L10n.text("限时优惠") }
        return L10n.text("免费试用")
    }

    private var membershipOfferSubtitle: String? {
        guard eligibleHomeTrial == nil else { return L10n.text("解锁全部会员功能") }
        return L10n.text("解锁无限整理与清理")
    }

    private var membershipOfferAccessibilityLabel: String {
        guard eligibleHomeTrial != nil else { return L10n.text("查看 Minus Pro 优惠方案") }
        return L10n.text("升级 Minus Pro") + "，" + L10n.text("免费试用")
    }

    /// 调试包固定保留首页优惠入口，方便反复检查内购页面；正式包只向非会员展示。
    private var shouldShowMembershipOffer: Bool {
#if DEBUG
        true
#else
        isLibraryAuthorized
            && remoteConfig.config.purchase.paywallEnabled
            && !purchaseStore.isPro
#endif
    }

    /// 分组标题：右边在已有分类时显示分类数，后台还在扫描就换成一枚“正在分析”的小标签
    private var groupsHeader: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("分组整理")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tidyInk)
                Text("按类别批量清理，先挑最省心的一组")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.tidyMuted)
            }

            Spacer(minLength: 8)

            if isScanning, !sections.isEmpty {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Color.tidyAccent)
                    Text("正在分析")
                }
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color.tidyAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.tidyAccent.opacity(0.12), in: Capsule())
            } else if !sections.isEmpty {
                Text(L10n.format("%lld 类", sections.count))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tidyMuted)
            }
        }
        .padding(.top, 10)
    }

    @ViewBuilder
    private var groupsContent: some View {
        // 扫描提示与已有分类并存，避免扫描期间整个列表消失
        if isScanning, sections.isEmpty {
            scanningRow
        }

        if sections.isEmpty {
            if !isScanning {
                emptyStateCard
            }
        } else {
            // 首页只留分类入口，两列照片磁贴，具体方案进去再看
            LazyVGrid(columns: Self.categoryColumns, spacing: 12) {
                ForEach(sections) { section in
                    CategoryTile(section: section) { onOpenCategory(section) }
                }
            }
        }
    }

    /// 相册管理入口，和分类入口同一种行样式
    @ViewBuilder
    private var albumsEntry: some View {
        if isLibraryAuthorized {
            EntryRow(
                symbol: "rectangle.stack",
                tint: Color.tidyAccent,
                title: L10n.text("相册管理"),
                subtitle: albumCount > 0
                    ? L10n.format("%@ 个相簿 · 新建或删除", albumCount.formatted())
                    : L10n.text("还没有相簿 · 新建一个"),
                action: onOpenAlbums
            )
            .background(Color.tidySurface, in: RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous)
                    .stroke(Color.tidyHairline, lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private var resumeBanner: some View {
        if isResumeBannerVisible {
            ResumeBanner(
                reviewedCount: resumeReviewedCount,
                remainingCount: resumeRemainingCount,
                onClose: dismissResumeBanner
            )
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
            .zIndex(20)
        }
    }

    /// 还没有任何分类时的扫描占位：两块骨架磁贴 + 一行说明，和扫完后的磁贴网格占同样的位置
    private var scanningRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Self.categoryColumns, spacing: 12) {
                ForEach(0..<2, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.tidySurface)
                        .frame(height: CategoryTile.height)
                        .overlay {
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(Color.tidyHairline, lineWidth: 1)
                        }
                        .overlay {
                            ProgressView()
                                .tint(Color.tidyAccent)
                        }
                }
            }

            Text("正在本机分析相似照片…")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.tidyMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyStateCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color.tidyKeep)
                .frame(width: 42, height: 42)
                .background(Color.tidyKeep.opacity(0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text("暂未发现可合并的相似照片")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tidyInk)
                Text("分析已在本机完成。导入更多照片后可以再次扫描。")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.tidyMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Button { onScan() } label: {
                    Label("重新扫描", systemImage: "arrow.clockwise")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.tidyOnAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.tidyAccent, in: Capsule())
                }
                .buttonStyle(CardPressStyle())
                .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tidySurface, in: RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous)
                .stroke(Color.tidyHairline, lineWidth: 1)
        )
    }

    private func dismissResumeBanner() {
        withAnimation(.easeInOut(duration: 0.22)) {
            isResumeBannerVisible = false
        }
    }
}

/// 首页卡片的按压反馈：大块卡片只微缩一点，按下去有实感又不晃眼
private struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

/// 首页上的入口行：图标、标题、内容量，右边一个箭头。目前只有相册管理在用
private struct EntryRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                // 圆角方块图标，和分组磁贴左上角的图标同一种形状
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 42, height: 42)
                    .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.tidyInk)
                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.tidyMuted)
                        .lineLimit(1)
                }
                .layoutPriority(1)

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.tidyMuted.opacity(0.7))
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPressStyle())
        .accessibilityLabel("\(title)，\(subtitle)")
    }
}

/// 首页分组磁贴：用这一类最新的一张照片当封面，左上角是分类图标，底部大字写数量，
/// 下面一行补充组数和体积。没有封面时退回分类色的渐变底。
private struct CategoryTile: View {
    let section: GroupSection
    let action: () -> Void

    /// 扫描占位的骨架磁贴也用这个高度，扫完替换时页面不跳
    static let height: CGFloat = 168
    private static let radius: CGFloat = 22

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                cover

                // 底部压暗托住文字，顶部轻压一点让图标在亮照片上也清楚
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.28), location: 0),
                        .init(color: .black.opacity(0.05), location: 0.35),
                        .init(color: .black.opacity(0.82), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Image(systemName: section.symbol)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.tidyOnAccent)
                            .frame(width: 30, height: 30)
                            .background(section.tint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                        Spacer(minLength: 0)

                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 26, height: 26)
                            .background(.ultraThinMaterial, in: Circle())
                    }

                    Spacer(minLength: 0)

                    Text(L10n.text(section.id))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(section.photoCount.formatted())
                            .font(.system(size: 24, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                        Text(section.unitText)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .opacity(0.75)
                    }
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                    if !section.detailText.isEmpty {
                        Text(section.detailText)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .stroke(Color.tidyHairline, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        }
        .buttonStyle(CardPressStyle())
        .accessibilityLabel("\(L10n.text(section.id))，\(section.summary)")
    }

    @ViewBuilder
    private var cover: some View {
        if let photo = section.coverPhoto {
            // 分类内容变了封面也要换，ArtworkView 只在出现时取图，靠 id 让它重建
            ArtworkView(photo: photo)
                .id(photo.id)
        } else {
            LinearGradient(
                colors: [section.tint.opacity(0.45), Color.tidySurface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

/// 某个分类下的具体方案，从首页的分类入口进来
private struct CategoryDetailView: View {
    let section: GroupSection
    let onBack: () -> Void
    let onOpenGroup: (PhotoGroup) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {
                    ForEach(section.groups) { group in
                        GroupCard(group: group) { onOpenGroup(group) }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
        }
        // 盖在首页之上，必须撑满并且不透明
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.tidyBackground)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(Color.tidyInk)
                    .frame(width: 54, height: 54)
                    .background(Color.tidySurface, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回")

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(section.id))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tidyInk)
                Text(section.summary)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.tidyMuted)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color.tidyBackground)
    }
}

/// 相册管理：列出用户自己的相簿，可以新建、打开、删除
private struct AlbumsView: View {
    let albums: [PhotoAlbum]
    let loadingAlbumID: String?
    let onBack: () -> Void
    let onOpenAlbum: (PhotoAlbum) -> Void
    let onCreateAlbum: (String) -> Void
    let onDeleteAlbum: (PhotoAlbum) -> Void

    @State private var isNaming = false
    @State private var newAlbumName = ""
    @State private var albumPendingDeletion: PhotoAlbum?

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    if albums.isEmpty {
                        emptyCard
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(albums.enumerated()), id: \.element.id) { index, album in
                                if index > 0 {
                                    Divider()
                                        .overlay(Color.tidyHairline)
                                        .padding(.leading, 66)
                                }
                                albumRow(album)
                            }
                        }
                        .background(Color.tidySurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .stroke(Color.tidyHairline, lineWidth: 1)
                        )
                    }

                    Text("删除相簿只是解散这个分类，里面的照片仍然留在图库里。")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.tidyMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.tidyBackground)
        .alert("新建相簿", isPresented: $isNaming) {
            TextField("相簿名称", text: $newAlbumName)
            Button("取消", role: .cancel) { }
            Button("创建") {
                let name = newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                onCreateAlbum(name)
            }
        }
        .alert(
            // 插值后的标题不再是本地化 key，用 Text + L10n.format 保证英文环境也能翻译
            Text(L10n.format("删除相簿「%@」？", albumPendingDeletion?.title ?? "")),
            isPresented: Binding(
                get: { albumPendingDeletion != nil },
                set: { if !$0 { albumPendingDeletion = nil } }
            )
        ) {
            Button("取消", role: .cancel) { albumPendingDeletion = nil }
            Button("删除相簿", role: .destructive) {
                if let album = albumPendingDeletion { onDeleteAlbum(album) }
                albumPendingDeletion = nil
            }
        } message: {
            Text("相簿里的照片不会被删除。")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(Color.tidyInk)
                    .frame(width: 54, height: 54)
                    .background(Color.tidySurface, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回")

            Text("相册管理")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Color.tidyInk)

            Spacer(minLength: 0)

            Button {
                newAlbumName = ""
                isNaming = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.tidyAccent)
                    .frame(width: 44, height: 44)
                    .background(Color.tidySurface, in: Circle())
                    .overlay(Circle().stroke(Color.tidyHairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("新建相簿")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color.tidyBackground)
    }

    private func albumRow(_ album: PhotoAlbum) -> some View {
        HStack(spacing: 14) {
            Button {
                guard album.count > 0 else { return }
                onOpenAlbum(album)
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color.tidyAccent)
                        .frame(width: 38, height: 38)
                        .background(Color.tidyAccent.opacity(0.13), in: Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text(album.title)
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.tidyInk)
                            .lineLimit(1)
                        Text(album.count > 0 ? L10n.format("%@ 项", album.count.formatted()) : L10n.text("空相簿"))
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.tidyMuted)
                    }

                    Spacer(minLength: 0)

                    if loadingAlbumID == album.id {
                        ProgressView()
                            .tint(Color.tidyAccent)
                    } else if album.count > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.tidyMuted.opacity(0.7))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                albumPendingDeletion = album
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.tidyMuted)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.format("删除相簿 %@", album.title))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("还没有相簿", systemImage: "rectangle.stack.badge.plus")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(Color.tidyInk)
            Text("新建一个相簿，整理时就能把想留的照片顺手归进去。")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color.tidyMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tidySurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.tidyHairline, lineWidth: 1)
        )
    }
}

/// 按时间整理：上面选按月还是按年，左边选具体的月／年，右边是下一级列表，点进去才是图片
private struct TimeGroupsView: View {
    @Binding var granularity: TimeGranularity
    /// 左边一列：按月时是各个月，按年时是各年
    let parents: [TimeBucket]
    /// 右边一列：左边选中项下面的天或月
    let children: [TimeBucket]
    @Binding var selectedParentID: String?
    let isLibraryAuthorized: Bool
    let isLibraryAccessDenied: Bool
    let isLibraryLoading: Bool
    let loadingBucketID: String?
    let onOpenBucket: (TimeBucket) -> Void
    let onRequestAccess: () -> Void

    /// 左边一列的宽度：放得下「2018年3月」和英文的「Mar 2018」，剩下的都留给右边。
    /// 调整这里要同时确认窄屏下右边还能排两个方块（tileColumns 的 minimum 是 104）。
    private static let parentColumnWidth: CGFloat = 118
    /// 右边一列剩下的宽度大概能排两个方块，窄屏时自动退成一个
    private static let tileColumns = [GridItem(.adaptive(minimum: 104), spacing: 10)]

    private var totalPhotoCount: Int {
        parents.reduce(0) { $0 + $1.count }
    }

    private var summary: String {
        guard !parents.isEmpty else { return L10n.text("还没有可归档的照片") }
        return L10n.format("%@ %@ · %@ 项", parents.count.formatted(), granularity.unit, totalPhotoCount.formatted())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            pageHeader
            granularityPicker
            content
        }
        .padding(.top, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 粒度一变、或者归档结果变了，就自动选中最新的那个，右边不留空
        .task(id: autoSelectKey) { ensureSelection() }
    }

    private var autoSelectKey: String {
        "\(granularity.rawValue)|\(parents.count)|\(parents.first?.id ?? "")"
    }

    private func ensureSelection() {
        guard let first = parents.first else { return }
        if let selectedParentID, parents.contains(where: { $0.id == selectedParentID }) { return }
        selectedParentID = first.id
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("按时间整理")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(Color.tidyInk)
            Text(summary)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color.tidyMuted)
        }
        .padding(.horizontal, 18)
    }

    /// 左右两列：左边定位到月或年，右边列出它下面的天或月
    private var columns: some View {
        HStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 4) {
                    ForEach(parents) { bucket in
                        parentRow(bucket)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .frame(width: Self.parentColumnWidth)

            Rectangle()
                .fill(Color.tidyHairline)
                .frame(width: 1)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: Self.tileColumns, spacing: 10) {
                    ForEach(children) { bucket in
                        TimeBucketTile(
                            bucket: bucket,
                            isLoading: loadingBucketID == bucket.id,
                            action: { onOpenBucket(bucket) }
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            // 换一个月／一年就回到顶部，不然会停在上一次滚过的位置
            .id(selectedParentID ?? "")
            .frame(maxWidth: .infinity)
        }
    }

    private func parentRow(_ bucket: TimeBucket) -> some View {
        let isActive = bucket.id == selectedParentID

        return Button {
            guard !isActive else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            selectedParentID = bucket.id
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(bucket.label)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    // 选中态是亮色填充，文字必须换成深色才看得清
                    .foregroundStyle(isActive ? Color.tidyOnAccent : Color.tidyInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(L10n.format("%@ 项", bucket.count.formatted()))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(isActive ? Color.tidyOnAccent.opacity(0.75) : Color.tidyMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(
                isActive ? Color.tidyAccent : Color.clear,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.format("%@，%lld 项", bucket.label, bucket.count))
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    private var granularityPicker: some View {
        HStack(spacing: 8) {
            ForEach(TimeGranularity.allCases) { item in
                let isActive = item == granularity

                Button {
                    guard !isActive else { return }
                    UISelectionFeedbackGenerator().selectionChanged()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        granularity = item
                    }
                } label: {
                    Text(item.title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        // 选中态是亮色填充，文字必须换成深色才看得清
                        .foregroundStyle(isActive ? Color.tidyOnAccent : Color.tidyMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(isActive ? Color.tidyAccent : Color.tidySurface, in: Capsule())
                        .overlay(
                            Capsule().stroke(isActive ? .clear : Color.tidyHairline, lineWidth: 1)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isActive ? [.isSelected] : [])
            }
        }
        .padding(.horizontal, 18)
    }

    @ViewBuilder
    private var content: some View {
        if !isLibraryAuthorized {
            LibraryConnectionView(
                isLoading: isLibraryLoading,
                isAccessDenied: isLibraryAccessDenied,
                contentHeight: 320,
                onRequestAccess: onRequestAccess
            )
            .padding(.horizontal, 18)
        } else if parents.isEmpty {
            Group {
                if isLibraryLoading {
                    loadingRow
                } else {
                    emptyStateCard
                }
            }
            .padding(.horizontal, 18)
        } else {
            columns
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(Color.tidyAccent)
            Text("正在按时间归档…")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.tidyMuted)
            Spacer()
        }
        .padding(18)
        .background(Color.tidySurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var emptyStateCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("相册里还没有照片", systemImage: "calendar.badge.exclamationmark")
                .font(.system(size: 17, weight: .bold, design: .rounded))
            Text("导入或拍摄照片后，这里会按拍摄时间自动归档。")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color.tidyMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tidySurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// 整理页里的一次决定，撤回时从栈顶逐条回退，所以可以连续撤
private struct OrganizeDecision {
    let photo: PhotoItem
    let wasDelete: Bool
}

/// 时间页右边一列的方块：封面是这一组最新的一张，日期压在图上
private struct TimeBucketTile: View {
    let bucket: TimeBucket
    let isLoading: Bool
    let action: () -> Void

    @State private var cover: UIImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                coverLayer
                // 照片亮的时候日期会糊在里面，压一层由下往上的黑到透明
                LinearGradient(
                    colors: [.black.opacity(0.72), .black.opacity(0.28), .clear],
                    startPoint: .bottom,
                    endPoint: .center
                )
                caption

                if isLoading {
                    ZStack {
                        Color.black.opacity(0.4)
                        ProgressView()
                            .tint(.white)
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.tidyHairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear(perform: loadCoverIfNeeded)
        .onDisappear(perform: cancelRequest)
        .accessibilityLabel(L10n.format("%@，%lld 项", bucket.label, bucket.count))
    }

    @ViewBuilder
    private var coverLayer: some View {
        if let cover {
            // 由 Color.clear 定尺寸，图片铺满后裁掉溢出，只留中间那块
            Color.clear
                .overlay {
                    Image(uiImage: cover)
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
        } else {
            Color.tidyElevated
                .overlay {
                    Image(systemName: "photo")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.tidyMuted.opacity(0.6))
                }
        }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(bucket.shortLabel)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(L10n.format("%@ 项", bucket.count.formatted()))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.82))
        }
        .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
        .padding(.horizontal, 10)
        .padding(.bottom, 9)
    }

    private func loadCoverIfNeeded() {
        guard cover == nil,
              requestID == nil,
              let identifier = bucket.coverIdentifier,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
        else { return }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        requestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 320, height: 320),
            contentMode: .aspectFill,
            options: options
        ) { image, info in
            guard let image,
                  (info?[PHImageCancelledKey] as? Bool) != true else { return }
            DispatchQueue.main.async { cover = image }
        }
    }

    private func cancelRequest() {
        guard let requestID else { return }
        PHImageManager.default().cancelImageRequest(requestID)
        self.requestID = nil
    }
}

private enum OrganizeQueueSource {
    case library
    case search(totalCount: Int)
    /// 首页某个合集，标题直接用来拼进度文案，所以传的是已经本地化好的合集名
    case collection(title: String, totalCount: Int)

    var allowsLoadingMore: Bool {
        if case .library = self { return true }
        return false
    }

    var completionTitle: String {
        switch self {
        case .library:
            return L10n.text("全部整理完成")
        case .search:
            return L10n.text("搜索结果已整理完")
        case .collection:
            return L10n.text("这个合集整理完成")
        }
    }
}

private enum OrganizeDeletionResult {
    case success
    case failed
    case quotaExceeded
}

/// 统一的整理页：顶部是这张照片的信息，中间是图片，底部是撤回、删除、保留、添加
private struct OrganizeView: View {
    @Binding var inbox: [PhotoItem]
    let source: OrganizeQueueSource
    let progressTotalCount: Int
    let reviewedCount: Int
    let albums: [PhotoAlbum]
    let onDecision: (PhotoItem, SwipeDecision) -> Void
    let onUndoDecision: (PhotoItem) -> Void
    /// 队列即将用完时在当前页内续批，返回新队列的照片数。
    let onLoadNextBatch: () async -> Int
    /// 把当前这张加进已有相簿，返回是否成功
    let onAddToAlbum: (PhotoItem, PhotoAlbum) async -> Bool
    /// 新建相簿并把当前这张放进去，返回是否成功
    let onCreateAlbum: (String, PhotoItem) async -> Bool
    /// 只确认删除这一轮标记的项目，历史待删除项目不在这个范围里。
    let onDeleteSession: ([PhotoItem], @escaping (OrganizeDeletionResult) -> Void) -> Void
    let onClose: () -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var isAnimatingOut = false
    /// 已做过的决定，越靠后越新
    @State private var history: [OrganizeDecision] = []
    @State private var isAlbumPickerPresented = false
    @State private var isLoadingMore = false
    /// 整理页盖在根视图之上，根视图的 toast 会被挡住，这里自己弹一个
    @State private var hint: ToastMessage?
    /// 本次打开整理页的独立统计；不能用全局累计数据，否则总结会把以前整理过的项目也算进去。
    @State private var sessionKeptCount = 0
    @State private var sessionDeletedPhotoIDs: Set<String> = []
    @State private var sessionDeletedPhotos: [PhotoItem] = []
    @State private var sessionDeleteBytes: [String: Int64] = [:]
    @State private var sessionStartedAt = Date()
    @State private var deletionReviewFinishedQueue: Bool?
    @State private var isDeletingSession = false
    @State private var summary: OrganizeSessionSummary?
    /// 第一次进整理页先讲一遍手势，看过之后不再打扰；设置里可以重看
    @AppStorage(OrganizeGuidePreference.seenKey) private var hasSeenGuide = false

    /// 卡片飞出的距离，取一个大于任何机型宽高的值，保证上下左右都能完全离开屏幕
    private static let exitDistance: CGFloat = 900
    /// 撤回栈的上限：每条都攥着一张缩略图，无限攒下去会吃内存
    private static let undoLimit = 30
    /// 提前续批，给用户留出足够的继续操作时间。
    private static let prefetchThreshold = 40

    /// 顶部进度条的数据：文案照旧，额外给出完成比例让进度条能画出来
    private var progress: SwipeProgress? {
        switch source {
        case .library:
            guard progressTotalCount > 0 else { return nil }
            return SwipeProgress(
                text: L10n.format("已整理 %@ / %@", reviewedCount.formatted(), progressTotalCount.formatted()),
                fraction: Double(reviewedCount) / Double(progressTotalCount)
            )
        case let .search(totalCount):
            let completedCount = min(max(totalCount - inbox.count, 0), totalCount)
            return SwipeProgress(
                text: L10n.format("搜索结果 · 已整理 %@ / %@", completedCount.formatted(), totalCount.formatted()),
                fraction: totalCount > 0 ? Double(completedCount) / Double(totalCount) : 0
            )
        case let .collection(title, totalCount):
            let completedCount = min(max(totalCount - inbox.count, 0), totalCount)
            return SwipeProgress(
                text: L10n.format("%@ · 已整理 %@ / %@", title, completedCount.formatted(), totalCount.formatted()),
                fraction: totalCount > 0 ? Double(completedCount) / Double(totalCount) : 0
            )
        }
    }

    var body: some View {
        ZStack {
            if let summary {
                OrganizeSummaryView(
                    summary: summary,
                    canContinue: !summary.finishedQueue && !inbox.isEmpty,
                    onContinue: continueOrganizing,
                    onDone: onClose
                )
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.96)),
                    removal: .opacity
                ))
                .zIndex(2)
            } else if let finishedQueue = deletionReviewFinishedQueue {
                OrganizeDeletionReviewView(
                    photos: sessionDeletedPhotos,
                    pendingBytes: sessionDeleteBytes.values.reduce(0, +),
                    isDeleting: isDeletingSession,
                    onRestore: restoreFromDeletionReview,
                    onDelete: { deleteReviewedSession(finishedQueue: finishedQueue) },
                    onLater: { presentSummary(finishedQueue: finishedQueue, deletionConfirmed: false) }
                )
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .trailing)),
                    removal: .opacity
                ))
                .zIndex(1)
            } else {
                FullScreenSwipeView(
                    photos: Array(inbox.prefix(2)),
                    progress: progress,
                    dragOffset: $dragOffset,
                    isAnimatingOut: isAnimatingOut,
                    canUndo: !history.isEmpty,
                    isLoadingPhotos: isLoadingMore,
                    closesWhenEmpty: false,
                    onDelete: { finishSwipe(.delete, exitDirection: $0) },
                    onKeep: { finishSwipe(.keep, exitDirection: $0) },
                    onUndo: undoLast,
                    onAdd: inbox.isEmpty ? nil : { isAlbumPickerPresented = true },
                    onClose: { presentCompletion(finishedQueue: false) },
                    albums: albums,
                    onAddToAlbum: { addCurrentPhoto(to: $0) }
                )
                .transition(.opacity)
            }

            if let hint {
                VStack {
                    Spacer()
                    Text(hint.text)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1))
                        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                        // 浮在底部操作栏正上方，不压住按钮
                        .padding(.bottom, 120)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                .allowsHitTesting(false)
            }

        }
        .animation(.easeInOut(duration: 0.2), value: hint)
        .task {
            await loadMoreIfNeeded(force: inbox.isEmpty)
        }
        .sheet(isPresented: $isAlbumPickerPresented) {
            AlbumPickerView(
                albums: albums,
                onPick: { album in addCurrentPhoto(to: album) },
                onCreate: { name in createAlbumWithCurrentPhoto(named: name) }
            )
            .presentationDetents([.medium, .large])
        }
        // 第一次进来自动弹半屏指引；往下拖走也算看过了，不会反复弹
        .sheet(isPresented: Binding(
            get: { !hasSeenGuide },
            set: { if !$0 { hasSeenGuide = true } }
        )) {
            OrganizeGuideView { hasSeenGuide = true }
        }
        .task(id: hint) {
            guard hint != nil else { return }
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            hint = nil
        }
        .onChange(of: sessionDeleteBytes) { values in
            guard var updated = summary else { return }
            updated.pendingBytes = values.values.reduce(0, +)
            summary = updated
        }
    }

    /// exitDirection 决定卡片往哪飞，由滑动的实际方向或按钮绑定的方向给出
    private func finishSwipe(_ decision: SwipeDecision, exitDirection: SwipeDirection) {
        guard !isAnimatingOut, !inbox.isEmpty else { return }
        isAnimatingOut = true

        let feedback = UIImpactFeedbackGenerator(style: .medium)
        feedback.prepare()

        withAnimation(.easeOut(duration: 0.32)) {
            dragOffset = exitDirection.exitOffset(distance: Self.exitDistance, from: dragOffset)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            guard !inbox.isEmpty else {
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    dragOffset = .zero
                    isAnimatingOut = false
                }
                return
            }

            var removedPhoto: PhotoItem?
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                let removed = inbox.removeFirst()
                removedPhoto = removed
                history.append(OrganizeDecision(photo: removed, wasDelete: decision == .delete))
                if history.count > Self.undoLimit {
                    history.removeFirst(history.count - Self.undoLimit)
                }
                if decision == .delete {
                    sessionDeletedPhotoIDs.insert(removed.id)
                    sessionDeletedPhotos.append(removed)
                    sessionDeleteBytes[removed.id] = max(removed.byteSize, 0)
                    resolveSessionStorageIfNeeded(for: removed)
                } else {
                    sessionKeptCount += 1
                }
                dragOffset = .zero
                isAnimatingOut = false
            }

            if let removedPhoto {
                onDecision(removedPhoto, decision)
                feedback.impactOccurred(intensity: decision == .delete ? 0.9 : 0.7)

                // 不等当前批次见底才加载；用户继续滑动时后台已经把下一批接上。
                Task { await loadMoreIfNeeded() }
            }
        }
    }

    /// 一次退一张，栈里有多少就能连着撤多少
    private func undoLast() {
        guard !isAnimatingOut, let last = history.popLast() else {
            hint = ToastMessage("已经回到最开始了")
            return
        }

        if last.wasDelete {
            sessionDeletedPhotoIDs.remove(last.photo.id)
            sessionDeletedPhotos.removeAll { $0.id == last.photo.id }
            sessionDeleteBytes.removeValue(forKey: last.photo.id)
        } else {
            sessionKeptCount = max(0, sessionKeptCount - 1)
        }
        inbox.insert(last.photo, at: 0)
        onUndoDecision(last.photo)
        hint = ToastMessage(
            history.isEmpty
                ? L10n.text("已撤回上一张")
                : L10n.format("已撤回上一张 · 还能再撤 %lld 张", history.count)
        )
    }

    /// 只在还有未装入队列的照片时续批。加载期间不关闭整理页，队列为空时会原地显示准备状态。
    @MainActor
    private func loadMoreIfNeeded(force: Bool = false) async {
        guard !isLoadingMore else { return }

        guard source.allowsLoadingMore else {
            if inbox.isEmpty {
                presentCompletion(finishedQueue: true)
            }
            return
        }

        let remainingCount = max(progressTotalCount - reviewedCount, 0)
        let needsMorePhotos = force
            || (inbox.count <= Self.prefetchThreshold && remainingCount > inbox.count)

        guard needsMorePhotos else {
            if inbox.isEmpty, remainingCount == 0 {
                presentCompletion(finishedQueue: true)
            }
            return
        }

        isLoadingMore = true
        let loadedCount = await onLoadNextBatch()
        isLoadingMore = false

        // 只有图库真的没有任何未处理照片才结束，续批过程中永远留在整理页。
        if inbox.isEmpty, loadedCount == 0 {
            presentCompletion(finishedQueue: true)
        }
    }

    private func resolveSessionStorageIfNeeded(for photo: PhotoItem) {
        guard photo.byteSize <= 0, let identifier = photo.assetIdentifier else { return }
        Task {
            guard let info = await AssetStorage.info(forAssetIdentifier: identifier),
                  sessionDeletedPhotoIDs.contains(photo.id) else { return }
            sessionDeleteBytes[photo.id] = info.byteSize
        }
    }

    private func presentCompletion(finishedQueue: Bool) {
        guard !isAnimatingOut, summary == nil, deletionReviewFinishedQueue == nil else { return }
        isAlbumPickerPresented = false
        let reviewed = sessionKeptCount + sessionDeletedPhotoIDs.count

        // 一张都没处理就主动退出时没什么可总结的，直接回上一页；
        // 队列已经整理完（finishedQueue）仍要给出反馈，否则用户不知道是没有更多了。
        if reviewed == 0, !finishedQueue {
            onClose()
            return
        }

        guard !sessionDeletedPhotos.isEmpty else {
            presentSummary(finishedQueue: finishedQueue, deletionConfirmed: false)
            return
        }

        withAnimation(.easeInOut(duration: 0.24)) {
            deletionReviewFinishedQueue = finishedQueue
        }
    }

    private func presentSummary(finishedQueue: Bool, deletionConfirmed: Bool) {
        let reviewed = sessionKeptCount + sessionDeletedPhotoIDs.count

        let value = OrganizeSessionSummary(
            reviewedCount: reviewed,
            keptCount: sessionKeptCount,
            pendingCount: sessionDeletedPhotoIDs.count,
            pendingBytes: sessionDeleteBytes.values.reduce(0, +),
            deletionConfirmed: deletionConfirmed,
            elapsedSeconds: max(Date().timeIntervalSince(sessionStartedAt), 1),
            finishedQueue: finishedQueue,
            completionTitle: finishedQueue ? source.completionTitle : nil
        )
        withAnimation(.spring(response: 0.48, dampingFraction: 0.86)) {
            deletionReviewFinishedQueue = nil
            summary = value
        }
        if reviewed > 0 {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.35)
        }
    }

    private func restoreFromDeletionReview(_ photo: PhotoItem) {
        guard !isDeletingSession, sessionDeletedPhotoIDs.contains(photo.id) else { return }
        // 撤回后队列重新出现待处理项目，不能再把这一轮标记为“全部完成”。
        deletionReviewFinishedQueue = false
        sessionDeletedPhotoIDs.remove(photo.id)
        sessionDeletedPhotos.removeAll { $0.id == photo.id }
        sessionDeleteBytes.removeValue(forKey: photo.id)
        history.removeAll { $0.photo.id == photo.id }
        inbox.insert(photo, at: 0)
        onUndoDecision(photo)

        if sessionDeletedPhotos.isEmpty {
            presentSummary(finishedQueue: false, deletionConfirmed: false)
        }
    }

    private func deleteReviewedSession(finishedQueue: Bool) {
        guard !isDeletingSession, !sessionDeletedPhotos.isEmpty else { return }
        isDeletingSession = true
        let photos = sessionDeletedPhotos
        onDeleteSession(photos) { result in
            isDeletingSession = false
            switch result {
            case .success:
                presentSummary(finishedQueue: finishedQueue, deletionConfirmed: true)
            case .failed:
                hint = ToastMessage("删除失败，请检查照片权限")
            case .quotaExceeded:
                // 评分奖励弹窗或付费页已由上层盖在整理页之上，这里不再弹提示，免得压在遮罩下面
                break
            }
        }
    }

    private func continueOrganizing() {
        history.removeAll()
        sessionKeptCount = 0
        sessionDeletedPhotoIDs.removeAll()
        sessionDeletedPhotos.removeAll()
        sessionDeleteBytes.removeAll()
        sessionStartedAt = Date()
        withAnimation(.easeInOut(duration: 0.24)) { summary = nil }
    }

    private func addCurrentPhoto(to album: PhotoAlbum) {
        guard let photo = inbox.first else { return }
        Task {
            let success = await onAddToAlbum(photo, album)
            hint = ToastMessage(success ? L10n.format("已加入「%@」", album.title) : L10n.text("加入相簿失败"))
        }
    }

    private func createAlbumWithCurrentPhoto(named name: String) {
        guard let photo = inbox.first else { return }
        Task {
            let success = await onCreateAlbum(name, photo)
            hint = ToastMessage(success ? L10n.format("已新建「%@」并加入这张", name) : L10n.text("新建相簿失败"))
        }
    }
}

private struct OrganizeSessionSummary: Equatable {
    let reviewedCount: Int
    let keptCount: Int
    let pendingCount: Int
    var pendingBytes: Int64
    let deletionConfirmed: Bool
    let elapsedSeconds: TimeInterval
    let finishedQueue: Bool
    let completionTitle: String?

    var elapsedText: String {
        let seconds = max(Int(elapsedSeconds.rounded()), 1)
        if seconds < 60 { return L10n.format("%lld 秒", seconds) }
        let minutes = seconds / 60
        let remainder = seconds % 60
        return remainder == 0
            ? L10n.format("%lld 分钟", minutes)
            : L10n.format("%lld 分 %lld 秒", minutes, remainder)
    }
}

/// 滑动结束后的最后检查，只展示本轮标记删除的项目，不混入历史待删除内容。
private struct OrganizeDeletionReviewView: View {
    let photos: [PhotoItem]
    let pendingBytes: Int64
    let isDeleting: Bool
    let onRestore: (PhotoItem) -> Void
    let onDelete: () -> Void
    let onLater: () -> Void

    @State private var selectedPhoto: PhotoItem?

    private let columns = [
        GridItem(.flexible(minimum: 0), spacing: 10),
        GridItem(.flexible(minimum: 0), spacing: 10),
        GridItem(.flexible(minimum: 0), spacing: 10)
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("确认本次删除")
                            .font(.system(size: 32, weight: .black, design: .rounded))
                            .foregroundStyle(Color.tidyInk)
                        Text("以下是本次整理中标记删除的项目。点左下角可撤回，确认后会统一移入系统“最近删除”。")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.tidyMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        Label(L10n.format("%@ 项", photos.count.formatted()), systemImage: "photo.stack")
                        if pendingBytes > 0 {
                            Label(ByteSizeText.full(pendingBytes), systemImage: "externaldrive")
                        }
                    }
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tidyAccent)

                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(photos) { photo in
                            PendingPhotoCell(photo: photo) {
                                onRestore(photo)
                            } onOpen: {
                                selectedPhoto = photo
                            }
                            .id(photo.id)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 24)
                .padding(.bottom, 20)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }

            VStack(spacing: 10) {
                Button(action: onDelete) {
                    HStack(spacing: 10) {
                        if isDeleting {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "trash.fill")
                        }
                        Text(L10n.format("删除本次 %lld 项", photos.count))
                    }
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Color.tidyDanger, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isDeleting || photos.isEmpty)
                .opacity(isDeleting || photos.isEmpty ? 0.6 : 1)

                Button("稍后再删", action: onLater)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tidyMuted)
                    .frame(height: 40)
                    .disabled(isDeleting)
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 12)
            .background(.ultraThinMaterial)
        }
        .background(Color.tidyBackground.ignoresSafeArea())
        .sheet(item: $selectedPhoto) { photo in
            PhotoDetailView(photo: photo)
        }
    }
}

/// 退出整理页前的会话总结。动画只播放一次，结束后保持静止，避免页面常驻时持续耗电。
private struct OrganizeSummaryView: View {
    let summary: OrganizeSessionSummary
    let canContinue: Bool
    let onContinue: () -> Void
    let onDone: () -> Void

    @State private var revealRing = false
    @State private var revealContent = false
    @State private var burstParticles = false
    @State private var displayedReviewedCount = 0

    private let confettiColors: [Color] = [.tidyAccent, .tidyKeep, .tidyDanger, .tidyCyan, .tidyAmber]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.tidyBackground, Color.tidyAccent.opacity(0.10), Color.tidyBackground],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            GeometryReader { proxy in
                ZStack {
                    ForEach(0..<20, id: \.self) { index in
                        let angle = Double(index) / 20 * Double.pi * 2
                        let distance = min(proxy.size.width, proxy.size.height) * (0.28 + Double(index % 4) * 0.025)
                        Capsule()
                            .fill(confettiColors[index % confettiColors.count])
                            .frame(width: index.isMultiple(of: 3) ? 7 : 5, height: index.isMultiple(of: 3) ? 18 : 12)
                            .rotationEffect(.degrees(burstParticles ? Double(index * 57) : 0))
                            .offset(
                                x: burstParticles ? cos(angle) * distance : 0,
                                y: burstParticles ? sin(angle) * distance : 0
                            )
                            .opacity(burstParticles ? 0 : 0.9)
                    }
                }
                .position(x: proxy.size.width / 2, y: min(proxy.size.height * 0.27, 260))
                .allowsHitTesting(false)
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 22) {
                    Spacer(minLength: 30)

                    ZStack {
                        Circle()
                            .stroke(Color.tidyAccent.opacity(0.15), lineWidth: 12)
                        Circle()
                            .trim(from: 0, to: revealRing ? 1 : 0.02)
                            .stroke(
                                AngularGradient(colors: [.tidyAccent, .tidyKeep, .tidyAccent], center: .center),
                                style: StrokeStyle(lineWidth: 12, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                        Image(systemName: "checkmark")
                            .font(.system(size: 48, weight: .black))
                            .foregroundStyle(Color.tidyKeep)
                            .scaleEffect(revealRing ? 1 : 0.2)
                            .opacity(revealRing ? 1 : 0)
                    }
                    .frame(width: 126, height: 126)

                    VStack(spacing: 8) {
                        Text(summary.reviewedCount == 0
                             ? L10n.text("暂未整理项目")
                             : (summary.completionTitle ?? L10n.text("本次整理完成")))
                            .font(.system(size: 30, weight: .black, design: .rounded))
                            .foregroundStyle(Color.tidyInk)
                        Text(L10n.format("用时 %@ · 每一次选择都已保存", summary.elapsedText))
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.tidyMuted)
                    }
                    .opacity(revealContent ? 1 : 0)
                    .offset(y: revealContent ? 0 : 12)

                    VStack(spacing: 16) {
                        VStack(spacing: 4) {
                            Text(displayedReviewedCount.formatted())
                                .font(.system(size: 58, weight: .black, design: .rounded))
                                .foregroundStyle(Color.tidyAccent)
                                .contentTransition(.numericText())
                            Text("本次整理项目")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.tidyMuted)
                        }

                        HStack(spacing: 12) {
                            summaryMetric(
                                symbol: "checkmark.circle.fill",
                                value: summary.keptCount.formatted(),
                                label: "已保留",
                                tint: .tidyKeep
                            )
                            summaryMetric(
                                symbol: "trash.circle.fill",
                                value: summary.pendingCount.formatted(),
                                label: summary.deletionConfirmed ? "已删除" : "待删除",
                                tint: .tidyDanger
                            )
                        }

                        HStack(spacing: 12) {
                            Image(systemName: "externaldrive.fill.badge.minus")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(Color.tidyAccent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(storageSummaryTitle)
                                    .font(.system(size: 18, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.tidyInk)
                                    .contentTransition(.numericText())
                                Text(L10n.text(summary.pendingCount == 0
                                               ? "这次全部选择了保留"
                                               : (summary.deletionConfirmed
                                                  ? "已移入最近删除，可在系统相册恢复"
                                                  : "前往待删除页确认后才会清理")))
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.tidyMuted)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(16)
                        .background(Color.tidySurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.tidyHairline, lineWidth: 1))
                    }
                    .frame(maxWidth: 520)
                    .opacity(revealContent ? 1 : 0)
                    .offset(y: revealContent ? 0 : 20)

                    VStack(spacing: 10) {
                        Button(action: onDone) {
                            Text("完成")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                                .background(Color.tidyAccent, in: Capsule())
                        }
                        .buttonStyle(.plain)

                        if canContinue {
                            Button("继续整理", action: onContinue)
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.tidyInk)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(Color.tidySurface, in: Capsule())
                                .overlay(Capsule().stroke(Color.tidyHairline, lineWidth: 1))
            .buttonStyle(.plain)
        }
    }

                    .frame(maxWidth: 520)
                    .opacity(revealContent ? 1 : 0)
                    .padding(.bottom, 28)
                }
                .padding(.horizontal, 22)
                .frame(maxWidth: .infinity, minHeight: 650)
            }
        }
        .task {
            withAnimation(.spring(response: 0.65, dampingFraction: 0.72)) { revealRing = true }
            withAnimation(.easeOut(duration: 0.85)) { burstParticles = true }
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.52, dampingFraction: 0.86)) {
                revealContent = true
                displayedReviewedCount = summary.reviewedCount
            }
        }
    }

    private var storageSummaryTitle: String {
        if summary.pendingCount == 0 { return L10n.text("没有待删除项目") }
        if summary.pendingBytes == 0 {
            return L10n.text(summary.deletionConfirmed ? "已完成删除" : "正在计算预计空间…")
        }
        return L10n.format(
            summary.deletionConfirmed ? "已释放 %@" : "预计可释放 %@",
            ByteSizeText.full(summary.pendingBytes)
        )
    }

    private func summaryMetric(symbol: String, value: String, label: String, tint: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 25, weight: .bold))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 27, weight: .black, design: .rounded))
                .foregroundStyle(Color.tidyInk)
                .contentTransition(.numericText())
            // label 是纯 String，不会自动查表，必须显式走 L10n
            Text(L10n.text(label))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Color.tidyMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(Color.tidySurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.tidyHairline, lineWidth: 1))
    }
}

/// 整理页里点「添加」后弹出的相簿选择表
private struct AlbumPickerView: View {
    let albums: [PhotoAlbum]
    let onPick: (PhotoAlbum) -> Void
    let onCreate: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isNaming = false
    @State private var newAlbumName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        newAlbumName = ""
                        isNaming = true
                    } label: {
                        Label("新建相簿", systemImage: "plus.rectangle.on.folder")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                    }
                }

                Section {
                    if albums.isEmpty {
                        Text("还没有相簿，新建一个吧")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(albums) { album in
                            Button {
                                onPick(album)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(album.title)
                                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                                    Spacer()
                                    Text("\(album.count.formatted())")
                                        .font(.system(size: 14, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("我的相簿")
                }
            }
            .navigationTitle("加入相簿")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
            .alert("新建相簿", isPresented: $isNaming) {
                TextField("相簿名称", text: $newAlbumName)
                Button("取消", role: .cancel) { }
                Button("创建") {
                    let name = newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    onCreate(name)
                    dismiss()
                }
            } message: {
                Text("会同时把当前这张照片放进去")
            }
        }
    }
}

private struct ResumeBanner: View {
    let reviewedCount: Int
    let remainingCount: Int
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.right.circle.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.tidyAccent)
                .frame(width: 42, height: 42)
                .background(Color.tidyAccent.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("继续上次整理")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text(L10n.format("上次已整理 %@ 项 · 还剩 %@ 项", reviewedCount.formatted(), remainingCount.formatted()))
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.tidyMuted)
            }

            Spacer(minLength: 8)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.tidyMuted)
                    .frame(width: 32, height: 32)
                    .background(Color.tidyMuted.opacity(0.10), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭继续整理提示")
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.12), radius: 20, y: 10)
    }
}

/// 首页合集大图：照片铺满，左上角合集图标 + 范围，右上角数量，右下角一颗“开始整理”圆钮。
/// 左下角的大标题不在这里画，由首页统一叠加，好做上下滚动切换
private struct PhotoCard: View {
    /// “开始整理”圆钮的直径，首页叠标题时要按它让出右侧空间
    static let startButtonSize: CGFloat = 54

    let photo: PhotoItem
    /// 已经本地化好的范围说明，例如「最近一周」「2024年10月」
    let scopeText: String
    let count: Int
    let symbol: String
    let isActive: Bool
    let cardHeight: CGFloat
    var onArtworkReady: () -> Void = { }
    var onMediaReady: (String) -> Void = { _ in }

    @StateObject private var videoPlayback = VideoPlaybackModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .topLeading) {
            ArtworkView(photo: photo) {
                onArtworkReady()
                if !photo.isVideo { onMediaReady(photo.id) }
            }

            // 视频未准备好时继续显示已经预载的封面，不把“正在加载”盖到首页上。
            if photo.isVideo,
               videoPlayback.activePhotoID == photo.id,
               videoPlayback.isReady,
               videoPlayback.errorMessage == nil {
                InlineVideoContent(playback: videoPlayback, fillsBounds: true)
            }

            // 顶部轻压托住两颗标签，底部重压托住大标题，中间留给照片本身
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.38), location: 0),
                    .init(color: .clear, location: 0.26),
                    .init(color: .clear, location: 0.46),
                    .init(color: .black.opacity(0.82), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Label(scopeText, systemImage: symbol)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))

                    Spacer(minLength: 0)

                    Text(L10n.format("%@ 项", count.formatted()))
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.tidyOnAccent)
                        .lineLimit(1)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(Color.tidyAccent, in: Capsule())
                }

                Spacer(minLength: 0)

                // 左下角的标题和日期由首页叠在上层（要做滚轮切换），这里只留右下角的圆钮
                HStack {
                    Spacer(minLength: 0)

                    // 只放箭头的圆钮，英文长标题时也不会和标题抢宽度；文字含义交给整卡的无障碍提示
                    Image(systemName: "arrow.right")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(Color.tidyOnAccent)
                        .frame(width: Self.startButtonSize, height: Self.startButtonSize)
                        .background(Color.tidyAccent, in: Circle())
                        .shadow(color: Color.tidyAccent.opacity(0.35), radius: 12, y: 4)
                }
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity)
        .frame(height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: Color.black.opacity(0.18), radius: 20, y: 12)
        .contentShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .task(id: photo.id) {
            if photo.isVideo {
                videoPlayback.load(photo, muted: true, autoplay: isActive)
            } else {
                videoPlayback.stop()
            }
        }
        .onChange(of: videoPlayback.isReady) { isReady in
            if isReady { onMediaReady(photo.id) }
        }
        .onChange(of: videoPlayback.errorMessage) { error in
            // 视频不可用时以封面作为降级结果，也不能让轮播永远卡在上一项。
            if error != nil { onMediaReady(photo.id) }
        }
        .onChange(of: isActive) { active in
            guard photo.isVideo else { return }
            if active {
                if videoPlayback.activePhotoID != photo.id || videoPlayback.errorMessage != nil {
                    videoPlayback.load(photo, muted: true, autoplay: true)
                } else if videoPlayback.isReady, !videoPlayback.isPlaying {
                    videoPlayback.togglePlayback()
                }
            } else {
                videoPlayback.pause()
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                videoPlayback.pause()
            } else if isActive, photo.isVideo, videoPlayback.activePhotoID == photo.id,
                      videoPlayback.isReady, !videoPlayback.isPlaying {
                videoPlayback.togglePlayback()
            }
        }
        .onDisappear { videoPlayback.stop() }
    }
}

/// 体积与云端标识，图库没给体积时后台补齐。整理页使用，首页预览不展示。
private struct PhotoStorageChip: View {
    let photo: PhotoItem

    @State private var resolvedStorage: AssetStorageInfo?

    private var storage: AssetStorageInfo? {
        if photo.byteSize > 0 {
            return AssetStorageInfo(byteSize: photo.byteSize, isInCloud: photo.isInCloud)
        }
        return resolvedStorage
    }

    var body: some View {
        Group {
            if let storage {
                HStack(spacing: 5) {
                    // 只有云端照片才加标识，本机照片直接显示大小
                    if storage.isInCloud {
                        Image(systemName: "icloud")
                            .font(.system(size: 11, weight: .bold))
                    }
                    Text(ByteSizeText.full(storage.byteSize))
                }
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                // 和返回按钮同一套毛玻璃，压在模糊背景上也读得清
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1))
            }
        }
        .task(id: photo.id) {
            guard photo.byteSize == 0,
                  let identifier = photo.assetIdentifier,
                  let info = await AssetStorage.info(forAssetIdentifier: identifier) else { return }
            resolvedStorage = info
        }
    }
}

/// 整理页顶部进度条的数据。文案由调用方拼好并本地化，比例单独给，进度条才画得出来
private struct SwipeProgress: Equatable {
    let text: String
    /// 0...1，超出范围画的时候会被夹住
    let fraction: Double
    /// 跟在进度后面的小标签，比如分组标记模式下的“已标记删除”
    var badge: String?
}

/// 拖动过程中的判定反馈：朝哪个方向、绑了什么动作、离阈值还有多远
private struct SwipeDragFeedback: Equatable {
    let direction: SwipeDirection
    let action: SwipeDirectionAction
    /// 0...1，到 1 表示已越过阈值，松手就会生效
    let progress: Double

    var isArmed: Bool { progress >= 1 }

    /// 越过阈值时的方向，用来在刚越线的那一下给触感反馈
    var armedDirection: SwipeDirection? { isArmed ? direction : nil }

    /// 染色渐变从被拖向的那条边铺进来
    var washStart: UnitPoint {
        switch direction {
        case .up: .top
        case .down: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }
}

/// 整理页按钮的按压反馈：按下微缩，松开回弹
private struct SwipePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// 整理页的氛围背景：取当前照片的一张小图糊开铺满，代替纯黑底。
/// 只要极小的图，模糊后看不出像素，加载快也不占内存。
private struct AmbientBackdrop: View {
    let photo: PhotoItem

    @State private var loadedImage: UIImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        // 由 Color.clear 定尺寸，铺满后的溢出部分裁掉，不会把布局撑大
        Color.clear
            .overlay {
                if let image = photo.image ?? loadedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 40, opaque: true)
                        .saturation(1.25)
                        .transition(.opacity)
                }
            }
            .clipped()
            .animation(.easeOut(duration: 0.3), value: loadedImage != nil)
            .task(id: photo.id) { requestImageIfNeeded() }
            .onDisappear(perform: cancelRequest)
    }

    private func requestImageIfNeeded() {
        cancelRequest()
        loadedImage = nil

        guard photo.image == nil,
              let identifier = photo.assetIdentifier,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
        else { return }

        let options = PHImageRequestOptions()
        // 背景要糊掉，最快的低清版本就够用
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        requestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 96, height: 96),
            contentMode: .aspectFill,
            options: options
        ) { image, info in
            guard let image,
                  (info?[PHImageCancelledKey] as? Bool) != true else { return }
            DispatchQueue.main.async { loadedImage = image }
        }
    }

    private func cancelRequest() {
        guard let requestID else { return }
        PHImageManager.default().cancelImageRequest(requestID)
        self.requestID = nil
    }
}

/// 全屏整理：模糊氛围底上悬浮一张照片卡，上下左右滑或底部操作栏做决定
private struct FullScreenSwipeView: View {
    /// 第一张是当前照片，后面的只做预载
    let photos: [PhotoItem]
    /// 顶部进度条，整理页不需要就给 nil
    let progress: SwipeProgress?
    @Binding var dragOffset: CGSize
    let isAnimatingOut: Bool
    let canUndo: Bool
    /// 整理页队列暂时为空时显示原地加载，不退出全屏。
    let isLoadingPhotos: Bool
    /// 分组内预览走完可以自动返回；主整理页则由续批结果决定。
    let closesWhenEmpty: Bool
    /// 参数是卡片飞出屏幕的方向：滑动时用实际方向，点按钮时用设置里绑定的方向
    let onDelete: (SwipeDirection) -> Void
    let onKeep: (SwipeDirection) -> Void
    let onUndo: () -> Void
    /// 只有整理页需要“添加”，分组里的标记模式传 nil 就不显示
    var onAdd: (() -> Void)?
    let onClose: () -> Void
    /// 滑动挑相簿用的候选列表；为空时“加入相簿”方向自动失效
    var albums: [PhotoAlbum] = []
    var onAddToAlbum: ((PhotoAlbum) -> Void)?

    /// 手指没松开时的相簿挑选现场
    private struct AlbumPickSession: Equatable {
        /// 触发挑选的方向，决定卡片保留哪一轴的位移
        let direction: SwipeDirection
        /// 进入挑选那一刻的位移，之后的横向偏移都相对它计算
        let anchor: CGSize
        let index: Int
    }

    /// 进入挑选后退出条件放宽，横向扫动时不会轻易掉出挑选状态
    private static let albumReleaseScale: CGFloat = 0.6
    /// 横向推出这么多才换一格
    private static let albumScrollStepOffset: CGFloat = 52
    /// 换完一格后要退回这个范围内才重新蓄力。回中线比换格线紧得多，
    /// 两者之间留出一大段缓冲，手指往回带过了头也不会顺手在反方向换一格。
    private static let albumScrollRearmOffset: CGFloat = 16
    /// 推过这条线才开始连发，之前都是推一次只走一格
    private static let albumScrollRepeatOffset: CGFloat = 104
    /// 推到这么远达到最高速
    private static let albumScrollMaxOffset: CGFloat = 200
    /// 连发速度区间，单位是每秒几个相簿
    private static let albumScrollMinRate: CGFloat = 3
    private static let albumScrollMaxRate: CGFloat = 14
    private static let albumScrollTick: CGFloat = 1.0 / 60.0
    /// 相簿列表渐显时从上方滑下来的距离
    private static let albumStripSlide: CGFloat = 36
    /// 中间图片/视频的圆角
    private static let photoCornerRadius: CGFloat = 22
    /// 照片卡左右留出的空隙，让卡片浮在模糊背景上而不是贴边
    private static let photoHorizontalInset: CGFloat = 12
    private static let albumChipWidth: CGFloat = 132
    private static let albumChipSpacing: CGFloat = 10

    /// 底部按钮顺序与滑动方向绑定都来自设置页，改完立刻生效
    @AppStorage(OrganizeControlsPreference.buttonOrderKey)
    private var buttonOrderRaw = OrganizeControlsPreference.defaultButtonOrderRaw
    @AppStorage(OrganizeControlsPreference.swipeActionKey)
    private var swipeActionRaw = OrganizeControlsPreference.defaultSwipeActionRaw

    /// 双指缩放保留的倍率，换照片时会回到 1 倍。
    @State private var settledZoomScale: CGFloat = 1
    @GestureState private var gestureZoomScale: CGFloat = 1
    @State private var isPinching = false
    /// 放大后图片的已确认平移量；1 倍时始终归零。
    @State private var settledPanOffset: CGSize = .zero
    @State private var panGestureStart: CGSize = .zero
    @State private var isPanningZoomedPhoto = false
    /// 手指还没松开的相簿挑选现场；为 nil 表示不在挑选状态
    @State private var albumPick: AlbumPickSession?
    /// 连发的方向（-1 / 0 / 1）、速度（每秒几个相簿）与不足一格的累计量
    @State private var albumScrollSign = 0
    @State private var albumScrollRate: CGFloat = 0
    @State private var albumScrollProgress: CGFloat = 0
    @State private var albumScrollTimer: Timer?
    @StateObject private var videoPlayback = VideoPlaybackModel()
    @StateObject private var motionPlayback = MotionPhotoPlaybackModel()
    @GestureState private var isHoldingMotion = false
    @Environment(\.scenePhase) private var scenePhase

    private var currentPhoto: PhotoItem? { photos.first }

    private var controls: OrganizeControlsPreference {
        OrganizeControlsPreference(buttonOrderRaw: buttonOrderRaw, swipeActionRaw: swipeActionRaw)
    }

    /// 当前拖动的主方向：横纵两轴里位移更大的那一边说了算
    private var draggingDirection: SwipeDirection? {
        guard abs(dragOffset.width) > 1 || abs(dragOffset.height) > 1 else { return nil }
        if abs(dragOffset.width) >= abs(dragOffset.height) {
            return dragOffset.width < 0 ? .left : .right
        }
        return dragOffset.height < 0 ? .up : .down
    }

    /// 任意方向上的拖动幅度，用来淡入下一张并让浮层控件让路
    private var dragDistance: CGFloat {
        max(abs(dragOffset.width), abs(dragOffset.height))
    }

    /// 相簿挑选可用的前提：设置里绑了方向，且这个入口确实拿到了相簿
    private var canPickAlbum: Bool {
        !albums.isEmpty && onAddToAlbum != nil && !controls.albumDirections.isEmpty
    }

    private var pickedAlbum: PhotoAlbum? {
        guard let albumPick, albums.indices.contains(albumPick.index) else { return nil }
        return albums[albumPick.index]
    }

    /// 相簿方向比横向分量领先多少。用差值而不是“谁是主方向”，
    /// 这样普通左右滑带的一点上扬永远算不出正值，斜着拖时也是连续变化不会跳。
    private func albumLead(_ translation: CGSize, direction: SwipeDirection) -> CGFloat {
        direction.distance(in: translation) - abs(direction.crossAxisDistance(in: translation))
    }

    /// 取所有“会把当前这张带走”的方向里拖得最远的那个。
    /// 不看主方向，避免斜着拖时下一张的透明度在两个方向间跳变。
    /// 挑相簿时松手是加入相簿、不换照片，横向扫得再远也不该把下一张带出来。
    private func nextPhotoOpacity(threshold: CGFloat) -> Double {
        guard threshold > 0, albumPick == nil else { return 0 }
        let reach = SwipeDirection.allCases
            .filter { controls.decision(for: $0) != nil }
            .map { $0.distance(in: dragOffset) }
            .max() ?? 0
        return min(max(Double(reach / threshold), 0), 1)
    }

    /// 主方向绑了松手即生效的动作才给反馈；方向留空、相簿方向、没得撤的撤回都不染色不盖章
    private func dragFeedback(threshold: CGFloat) -> SwipeDragFeedback? {
        guard threshold > 0, !isZoomed, albumPick == nil, let direction = draggingDirection else { return nil }

        let action = controls.action(for: direction)
        switch action {
        case .delete, .keep:
            break
        case .undo:
            guard canUndo else { return nil }
        case .album, .none:
            return nil
        }

        let progress = min(max(Double(direction.distance(in: dragOffset) / threshold), 0), 1)
        guard progress > 0 else { return nil }
        return SwipeDragFeedback(direction: direction, action: action, progress: progress)
    }

    /// 底部按钮跟着手势点亮：朝哪个判定拖，对应的按钮就逐渐填满颜色；挑相簿时“添加”常亮
    private func dockEmphasis(for action: OrganizeAction, feedback: SwipeDragFeedback?) -> Double {
        if action == .add { return albumPick != nil ? 1 : 0 }
        guard let feedback else { return 0 }

        let matched: OrganizeAction?
        switch feedback.action {
        case .delete: matched = .delete
        case .keep: matched = .keep
        case .undo: matched = .undo
        case .album, .none: matched = nil
        }
        return matched == action ? feedback.progress : 0
    }

    private var zoomScale: CGFloat {
        min(max(settledZoomScale * gestureZoomScale, 1), 5)
    }

    private var isZoomed: Bool {
        zoomScale > 1.01
    }

    var body: some View {
        GeometryReader { proxy in
            let threshold = min(max(proxy.size.width * 0.22, 70), 120)
            let feedback = dragFeedback(threshold: threshold)

            ZStack {
                backdrop(threshold: threshold)
                    .ignoresSafeArea()

                // 竖排三段：信息贴着顶、操作栏贴着底，图片只占中间剩下的空间，三者互不遮挡
                VStack(spacing: 10) {
                    if let currentPhoto {
                        topBar(currentPhoto)
                            // 图片层声明了 zIndex，同层级里没声明的会被排到最底下，所以这两栏也要显式抬高
                            .zIndex(9)
                    }

                    photoStack(threshold: threshold, feedback: feedback)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .zIndex(0)

                    actionBar(feedback: feedback)
                        .zIndex(9)
                }
            }
            // 刚越过阈值的那一下轻震，提示现在松手就会生效；点按钮触发的飞出不重复震
            .onChange(of: feedback?.armedDirection) { direction in
                guard direction != nil, !isAnimatingOut else { return }
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.55)
            }
        }
        .background(Color.black.ignoresSafeArea())
        // 最后一张处理完就自动退出全屏
        .onChange(of: photos.isEmpty) { isEmpty in
            if isEmpty, closesWhenEmpty, !isLoadingPhotos { onClose() }
        }
        .onChange(of: currentPhoto?.id) { _ in
            videoPlayback.stop()
            motionPlayback.reset()
            resetZoom(animated: false)
        }
        .onChange(of: isHoldingMotion) { holding in
            if holding, let photo = currentPhoto, !isAnimatingOut, !isPinching,
               abs(dragOffset.width) < 10, abs(dragOffset.height) < 10 {
                motionPlayback.beginPress(photo)
            } else {
                motionPlayback.endPress()
            }
        }
        .onChange(of: isAnimatingOut) { animating in
            if animating {
                videoPlayback.pause()
                motionPlayback.reset()
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                videoPlayback.pause()
                motionPlayback.reset()
            }
        }
        .onDisappear {
            videoPlayback.stop()
            motionPlayback.reset()
            stopAlbumScroll()
        }
    }

    /// 模糊背景同样预载两张：朝带走当前张的方向拖时，下一张的背景跟着照片一起淡入
    private func backdrop(threshold: CGFloat) -> some View {
        ZStack {
            Color.black

            ForEach(Array(photos.prefix(2).enumerated()).reversed(), id: \.element.id) { offset, photo in
                AmbientBackdrop(photo: photo)
                    .opacity(offset == 0 ? 1 : nextPhotoOpacity(threshold: threshold))
            }

            // 上下两端压得更暗，保证顶部文字和底部操作栏在亮照片上也读得清
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.66), location: 0),
                    .init(color: .black.opacity(0.4), location: 0.3),
                    .init(color: .black.opacity(0.46), location: 0.7),
                    .init(color: .black.opacity(0.84), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        // 撤回时插回来的那张没有经过拖动淡入，这里补一段淡入淡出
        .animation(.easeInOut(duration: 0.35), value: photos.first?.id)
        .allowsHitTesting(false)
    }

    /// 图片与判定印章共用中间这块区域
    private func photoStack(threshold: CGFloat, feedback: SwipeDragFeedback?) -> some View {
        GeometryReader { proxy in
            // 照片卡左右各留一道缝，缩放平移的边界也要按收窄后的尺寸算
            let mediaViewport = CGSize(
                width: max(proxy.size.width - Self.photoHorizontalInset * 2, 1),
                height: proxy.size.height
            )

            ZStack {
                if currentPhoto == nil {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color.tidyAccent)
                            .frame(width: 72, height: 72)
                            .background(.ultraThinMaterial, in: Circle())
                        Text(L10n.text(isLoadingPhotos ? "正在准备接下来的照片和视频…" : "正在检查剩余项目…"))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                }

                // 按 id 保持各自身份，滑走当前张时下一张已经带着图留在视图树里，不会闪黑屏
                ForEach(Array(photos.prefix(2).enumerated()).reversed(), id: \.element.id) { offset, photo in
                    let panOffset = clampedPanOffset(
                        settledPanOffset,
                        viewportSize: mediaViewport,
                        photo: photo,
                        scale: zoomScale
                    )

                    ZStack {
                        FullScreenArtwork(photo: photo)
                        if offset == 0, videoPlayback.activePhotoID == photo.id {
                            InlineVideoContent(playback: videoPlayback)
                        }
                        if offset == 0, motionPlayback.activePhotoID == photo.id, motionPlayback.isHolding {
                            MotionPhotoContent(playback: motionPlayback)
                        }
                        if offset == 0, let feedback {
                            decisionWash(feedback)
                        }
                    }
                        // 先按真实比例收成媒体自己的大小再切圆角，圆角才贴着画面边缘而不是整屏；
                        // 视频和动态照片的播放层带黑底，收进同一个盒子里才会被一起裁圆
                        .mediaAspect(photo.displayAspectRatio)
                        .clipShape(RoundedRectangle(cornerRadius: Self.photoCornerRadius, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: Self.photoCornerRadius, style: .continuous)
                                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
                        .padding(.horizontal, Self.photoHorizontalInset)
                        // 圆角只收窄画面，手势区域仍然是整块中间区域
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .contentShape(Rectangle())
                        .scaleEffect(offset == 0 ? zoomScale : 1)
                        // 静止时藏住下一张，避免两张长宽比不同的图边缘互相露出；
                        // 只有朝着会把当前这张带走的方向拖，下一张才跟着淡入
                        .opacity(offset == 0 ? 1 : nextPhotoOpacity(threshold: threshold))
                        .offset(
                            x: offset == 0 ? dragOffset.width + panOffset.width : 0,
                            y: offset == 0 ? dragOffset.height + panOffset.height : 0
                        )
                        .rotationEffect(.degrees(offset == 0 && !isZoomed ? Double(dragOffset.width / 28) : 0))
                        .allowsHitTesting(offset == 0)
                        .gesture(offset == 0 ? organizingGesture(threshold: threshold, viewportSize: mediaViewport, photo: photo) : nil)
                        .simultaneousGesture(offset == 0 ? zoomGesture(viewportSize: mediaViewport, photo: photo) : nil)
                        .onTapGesture(count: photo.isVideo ? 1 : 2) {
                            guard offset == 0, !isAnimatingOut else { return }
                            if photo.isVideo {
                                playOrPauseVideo(photo)
                            } else if isZoomed {
                                resetZoom(animated: true)
                            } else {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                                    settledZoomScale = 2
                                }
                            }
                        }
                        .zIndex(Double(2 - offset))
                }

                // 反馈本身已排除缩放和挑相簿的情况，挑相簿时不会冒出删除/保留的印章
                if currentPhoto != nil, let feedback {
                    // 印章盖在图片上方，必须放弃点击否则会吞掉中间的拖动
                    decisionStamp(feedback)
                        .allowsHitTesting(false)
                        .zIndex(8)
                }

                // 到达触发高度前完全不露，到了才淡入滑下；常驻视图树是为了进出都能走同一段动画
                if canPickAlbum {
                    let isPicking = albumPick != nil

                    VStack(spacing: 0) {
                        albumStrip(width: proxy.size.width)
                        Spacer(minLength: 0)
                    }
                    .opacity(isPicking ? 1 : 0)
                    .offset(y: isPicking ? 0 : -Self.albumStripSlide)
                    .animation(.spring(response: 0.34, dampingFraction: 0.86), value: isPicking)
                    .allowsHitTesting(false)
                    .zIndex(10)
                }

                if let photo = currentPhoto, photo.motionKind != .none,
                   !isAnimatingOut, dragDistance < 8 {
                    VStack {
                        HStack {
                            Label(motionPlayback.isHolding ? L10n.text("松手停止") : L10n.format("%@ · 长按播放", photo.motionKind.title),
                                  systemImage: photo.motionKind == .livePhoto ? "livephoto" : "photo.stack")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 7)
                                .background(.ultraThinMaterial, in: Capsule())
                                .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1))
                            Spacer(minLength: 0)
                        }
                        Spacer(minLength: 0)
                    }
                    // 照片卡左右缩进了，角标跟着往里收，才落在卡片里面
                    .padding(.vertical, 14)
                    .padding(.horizontal, 14 + Self.photoHorizontalInset)
                    .allowsHitTesting(false)
                    .zIndex(9)
                }

                if let photo = currentPhoto, photo.isVideo, videoPlayback.activePhotoID != photo.id, !isZoomed,
                   !isAnimatingOut, dragDistance < 8 {
                    // 大号圆形播放键 + 下方时长，比一整条文字胶囊更像播放器
                    Button {
                        playOrPauseVideo(photo)
                    } label: {
                        VStack(spacing: 10) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(.white)
                                // play 图形视觉重心偏左，往右挪一点才显得居中
                                .offset(x: 3)
                                .frame(width: 76, height: 76)
                                .background(.ultraThinMaterial, in: Circle())
                                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                            Text(photo.durationText)
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(.black.opacity(0.4), in: Capsule())
                        }
                        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                    }
                    .buttonStyle(SwipePressStyle())
                    .accessibilityLabel(L10n.format("播放视频 · %@", photo.durationText))
                    .zIndex(9)
                }

                if let photo = currentPhoto, photo.isVideo, videoPlayback.activePhotoID == photo.id,
                   videoPlayback.player != nil, videoPlayback.errorMessage == nil,
                   !isAnimatingOut, dragDistance < 8 {
                    VStack {
                        Spacer(minLength: 0)
                        InlineVideoControls(playback: videoPlayback)
                            .id(photo.id)
                            .padding(.horizontal, 16 + Self.photoHorizontalInset)
                            .padding(.bottom, 12)
                    }
                    .zIndex(9)
                }
            }
        }
        // 放大后仅在中间的照片区域里显示，不覆盖顶部信息和底部按钮；
        // 平时把裁切框放得极大，卡片阴影和拖出屏幕的过程都不会被一刀切断。
        // 用同一种形状改内缩量而不是条件加 .clipped()，避免切换时子视图被重建、图片重新加载。
        .clipShape(Rectangle().inset(by: isZoomed ? 0 : -2000))
    }

    /// 拖动时照片从被拖向的那条边染上判定色，描边同步加深，越接近阈值越浓
    private func decisionWash(_ feedback: SwipeDragFeedback) -> some View {
        let tint = feedback.action.tint

        return ZStack {
            LinearGradient(
                colors: [tint.opacity(0.55 * feedback.progress), tint.opacity(0)],
                startPoint: feedback.washStart,
                endPoint: .center
            )
            RoundedRectangle(cornerRadius: Self.photoCornerRadius, style: .continuous)
                .strokeBorder(tint.opacity(feedback.progress), lineWidth: 3)
        }
        .allowsHitTesting(false)
    }

    private func playOrPauseVideo(_ photo: PhotoItem) {
        guard !isAnimatingOut else { return }
        if videoPlayback.activePhotoID != photo.id || videoPlayback.errorMessage != nil {
            videoPlayback.load(photo)
        } else {
            videoPlayback.togglePlayback()
        }
    }

    /// 顶部两层：第一行左边返回、紧跟日期时间分辨率，右边体积；第二行是细进度条
    private func topBar(_ photo: PhotoItem) -> some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.1), lineWidth: 1))
                        // 圆圈只有 40，点击区域补到 44 才符合系统最小可点尺寸
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(SwipePressStyle())
                .accessibilityLabel("返回")

                VStack(alignment: .leading, spacing: 2) {
                    Text(photo.title)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(photo.detail) · \(photo.resolutionText)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }

                Spacer(minLength: 8)

                PhotoStorageChip(photo: photo)
            }

            if let progress {
                progressStrip(progress)
                    .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 14)
        // 尽量贴着安全区顶端，把纵向空间留给图片
        .padding(.top, 2)
    }

    /// 细进度条 + 右侧数字。文字优先保证完整，长文案时让进度条去缩
    private func progressStrip(_ progress: SwipeProgress) -> some View {
        let fraction = min(max(progress.fraction, 0), 1)

        return HStack(spacing: 10) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.14))
                    Capsule()
                        .fill(Color.tidyAccent)
                        // 刚开始整理时也露出一小截，让人知道这是进度条
                        .frame(width: max(proxy.size.width * fraction, 4))
                }
            }
            .frame(minWidth: 40)
            .frame(height: 4)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: fraction)

            Text(progress.text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .layoutPriority(1)

            if let badge = progress.badge {
                Text(badge)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tidyDanger)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.tidyDanger.opacity(0.18), in: Capsule())
                    .layoutPriority(1)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: progress.badge)
    }

    /// 圆形徽章印章：没到阈值时是描边空心、跟着位移渐显放大，越过阈值变成实心并弹一下，表示松手就生效。
    /// 相簿方向、留空方向和没得撤的撤回在 dragFeedback 里已经被排除，这里不会出现。
    private func decisionStamp(_ feedback: SwipeDragFeedback) -> some View {
        let tint = feedback.action.tint
        let isArmed = feedback.isArmed

        return VStack(spacing: 10) {
            Image(systemName: feedback.action.symbol)
                .font(.system(size: 30, weight: .black))
                .foregroundStyle(isArmed ? Color.tidyOnAccent : tint)
                .frame(width: 80, height: 80)
                .background {
                    Circle()
                        .fill(isArmed ? AnyShapeStyle(tint) : AnyShapeStyle(.ultraThinMaterial))
                }
                .overlay { Circle().strokeBorder(tint, lineWidth: 3) }
                .scaleEffect(isArmed ? 1.08 : 1)

            // title 是纯 String，不会自动查表，必须显式走 L10n
            Text(L10n.text(feedback.action.title))
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.black.opacity(0.45), in: Capsule())
        }
        .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
        .scaleEffect(0.7 + 0.3 * feedback.progress)
        .opacity(feedback.progress)
        .animation(.spring(response: 0.26, dampingFraction: 0.55), value: isArmed)
    }

    /// 挑相簿时顶部铺开的横向列表，选中的那张停在正中间
    private func albumStrip(width: CGFloat) -> some View {
        let strip = albums
        let selectedIndex = albumPick?.index ?? 0
        let step = Self.albumChipWidth + Self.albumChipSpacing
        // 把第 selectedIndex 张推到容器正中：整排中心与目标项中心的差就是位移
        let centerOffset = (CGFloat(strip.count - 1) / 2 - CGFloat(selectedIndex)) * step

        // 面板左右各缩进一点浮在照片上方，列表宽度跟着面板走
        let panelWidth = max(width - Self.photoHorizontalInset * 2, 1)

        return VStack(spacing: 10) {
            Label("左右滑动选相簿 · 松手加入", systemImage: "hand.draw")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))

            HStack(spacing: Self.albumChipSpacing) {
                ForEach(Array(strip.enumerated()), id: \.element.id) { index, album in
                    albumChip(album, isSelected: index == selectedIndex)
                }
            }
            .offset(x: centerOffset)
            .frame(width: panelWidth, alignment: .center)
            .animation(.spring(response: 0.26, dampingFraction: 0.84), value: selectedIndex)
            // 两侧淡出，暗示还有更多相簿在列表外
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.16),
                        .init(color: .black, location: 0.84),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        }
        .padding(.vertical, 14)
        .frame(width: panelWidth)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
        }
        // 圆角面板要把两侧淡出的列表一起收进去
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .padding(.top, 8)
        .frame(width: width)
    }

    private func albumChip(_ album: PhotoAlbum, isSelected: Bool) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                // 选中项带个勾，松手会加到哪里一眼就能看出来
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .black))
                }
                Text(album.title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.tidyOnAccent : .white.opacity(0.9))
            Text(L10n.format("%@ 项", album.count.formatted()))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(isSelected ? Color.tidyOnAccent.opacity(0.7) : .white.opacity(0.5))
        }
        .padding(.horizontal, 10)
        .frame(width: Self.albumChipWidth, height: 54)
        .background(
            isSelected ? Color.tidyAccent : Color.white.opacity(0.1),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(isSelected ? 0 : 0.08), lineWidth: 1)
        }
        .scaleEffect(isSelected ? 1 : 0.88)
    }

    /// 底部操作栏：按钮收进一块毛玻璃底板，亮照片上也压得住；每个按钮均分一格
    private func actionBar(feedback: SwipeDragFeedback?) -> some View {
        // 按设置里的顺序排；分组标记模式没有“添加”，直接跳过它
        let actions = controls.buttonOrder.filter { $0 != .add || onAdd != nil }

        return HStack(spacing: 0) {
            ForEach(actions) { action in
                actionButton(action, emphasis: dockEmphasis(for: action, feedback: feedback))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
        .padding(.horizontal, 14)
        // 尽量贴着安全区底端
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func actionButton(_ action: OrganizeAction, emphasis: Double) -> some View {
        switch action {
        case .undo:
            FullScreenActionButton(action: action, emphasis: emphasis, perform: onUndo)
                .opacity(canUndo ? 1 : 0.38)
                .disabled(!canUndo)
        case .delete:
            FullScreenActionButton(action: action, emphasis: emphasis) {
                onDelete(controls.exitDirection(for: .delete))
            }
            .opacity(currentPhoto == nil ? 0.38 : 1)
            .disabled(currentPhoto == nil)
        case .keep:
            FullScreenActionButton(action: action, emphasis: emphasis) {
                onKeep(controls.exitDirection(for: .keep))
            }
            .opacity(currentPhoto == nil ? 0.38 : 1)
            .disabled(currentPhoto == nil)
        case .add:
            if let onAdd {
                FullScreenActionButton(action: action, emphasis: emphasis, perform: onAdd)
                    .opacity(currentPhoto == nil ? 0.38 : 1)
                    .disabled(currentPhoto == nil)
            }
        }
    }

    private func organizingGesture(threshold: CGFloat, viewportSize: CGSize, photo: PhotoItem) -> AnyGesture<Void> {
        let swipe = dragGesture(threshold: threshold, viewportSize: viewportSize, photo: photo)
        guard photo.motionKind != .none else { return AnyGesture(swipe.map { _ in () }) }

        // 长按成功后由零距离拖动维持到松手；普通滑动超过 10pt 时长按失败，交回原来的整理手势。
        // 用互斥手势避免“先长按播放，再移动松手”意外触发删除。
        let hold = LongPressGesture(minimumDuration: 0.3, maximumDistance: 10)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($isHoldingMotion) { value, state, _ in
                if case .second(true, _) = value { state = true }
            }
        return AnyGesture(hold.exclusively(before: swipe).map { _ in () })
    }

    private func dragGesture(threshold: CGFloat, viewportSize: CGSize, photo: PhotoItem) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !isAnimatingOut, !isPinching else { return }

                if isZoomed {
                    if !isPanningZoomedPhoto {
                        isPanningZoomedPhoto = true
                        panGestureStart = settledPanOffset
                        dragOffset = .zero
                    }
                    let proposedOffset = CGSize(
                        width: panGestureStart.width + value.translation.width,
                        height: panGestureStart.height + value.translation.height
                    )
                    settledPanOffset = clampedPanOffset(
                        proposedOffset,
                        viewportSize: viewportSize,
                        photo: photo,
                        scale: zoomScale
                    )
                    return
                }

                updateAlbumPick(translation: value.translation, threshold: threshold)

                // 挑相簿时卡片照样完全跟手，四个方向都能拖出屏幕；
                // 横向位移额外拿去算滚动速度，但不因此限制卡片怎么走。
                dragOffset = value.translation
            }
            .onEnded { value in
                guard !isAnimatingOut else { return }

                if isPinching {
                    isPanningZoomedPhoto = false
                    cancelAlbumPick()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        dragOffset = .zero
                    }
                    return
                }

                // 挑相簿时松手就加入，照片留在队列里继续做删留决定
                if let album = pickedAlbum {
                    onAddToAlbum?(album)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    cancelAlbumPick()
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                        dragOffset = .zero
                    }
                    return
                }

                if isPanningZoomedPhoto || isZoomed {
                    let proposedOffset = CGSize(
                        width: panGestureStart.width + value.translation.width,
                        height: panGestureStart.height + value.translation.height
                    )
                    settledPanOffset = clampedPanOffset(
                        proposedOffset,
                        viewportSize: viewportSize,
                        photo: photo,
                        scale: zoomScale
                    )
                    panGestureStart = settledPanOffset
                    isPanningZoomedPhoto = false
                    dragOffset = .zero
                    return
                }

                // 没越过阈值、方向留空、或撤回时已经没得撤，一律弹回原位。
                let bounceBack = {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                        dragOffset = .zero
                    }
                }

                guard let direction = resolvedDirection(value, threshold: threshold) else {
                    bounceBack()
                    return
                }

                switch controls.action(for: direction) {
                case .delete: onDelete(direction)
                case .keep: onKeep(direction)
                case .undo:
                    // 撤回不带走当前这张，卡片弹回原位，上一张插到队首
                    guard canUndo else {
                        bounceBack()
                        return
                    }
                    onUndo()
                    bounceBack()
                case .none, .album:
                    bounceBack()
                }
            }
    }

    /// 挑出越过阈值且绑定了“松手即触发”动作的方向；多个方向同时越界时取位移最大的那个
    private func resolvedDirection(_ value: DragGesture.Value, threshold: CGFloat) -> SwipeDirection? {
        let projectedThreshold = threshold * 1.35

        return SwipeDirection.allCases
            .filter { controls.action(for: $0).firesOnRelease }
            .filter {
                $0.distance(in: value.translation) >= threshold
                    || $0.distance(in: value.predictedEndTranslation) >= projectedThreshold
            }
            .max { $0.distance(in: value.translation) < $1.distance(in: value.translation) }
    }

    /// 相簿方向领先够多就进入挑选：记下当时的位移作锚点，之后横向推多远决定列表滚多快。
    /// 进入后只看该方向的原始位移，低于放宽后的退出线才退出，横向扫动不会把挑选状态甩掉。
    private func updateAlbumPick(translation: CGSize, threshold: CGFloat) {
        guard canPickAlbum else {
            cancelAlbumPick()
            return
        }

        let session: AlbumPickSession
        if let albumPick {
            // 已经在挑了就只认当初那个方向，退出线放宽，横向扫动不会把挑选状态甩掉
            guard albumPick.direction.distance(in: translation) >= threshold * Self.albumReleaseScale else {
                cancelAlbumPick()
                return
            }
            session = albumPick
        } else {
            // 上下都能绑“加入相簿”，谁领先得多就由谁接管
            guard let direction = controls.albumDirections
                .filter({ albumLead(translation, direction: $0) >= threshold })
                .max(by: { albumLead(translation, direction: $0) < albumLead(translation, direction: $1) })
            else { return }

            // 列表的显隐由拖动进度驱动，这里只记录挑选现场，不需要额外动画
            session = AlbumPickSession(direction: direction, anchor: translation, index: 0)
            albumScrollSign = 0
            albumScrollProgress = 0
            albumPick = session
            UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.8)
            startAlbumScroll()
        }

        // 横向偏移分三段：换格线内蓄力，推过换格线换一格就停住，推过连发线才持续滚。
        // sign 记着这一下已经用掉了，手指必须退回回中线以内才能再换下一格。
        let cross = albumCrossOffset(translation: translation, session: session)

        if albumScrollSign == 0 {
            let sign = cross >= Self.albumScrollStepOffset ? 1 : (cross <= -Self.albumScrollStepOffset ? -1 : 0)
            if sign != 0 {
                albumScrollSign = sign
                stepAlbumSelection(by: sign)
                // 首格之后先退一整格，进了连发区也不会紧跟着第一下连成一片
                albumScrollProgress = -1
            }
        } else if abs(cross) <= Self.albumScrollRearmOffset {
            albumScrollSign = 0
            albumScrollProgress = 0
        }

        albumScrollRate = scrollRate(forCrossOffset: cross)
    }

    private func albumCrossOffset(translation: CGSize, session: AlbumPickSession) -> CGFloat {
        session.direction.crossAxisDistance(in: translation)
            - session.direction.crossAxisDistance(in: session.anchor)
    }

    /// 横向偏移映射成“每秒滚过几个相簿”。只推到换一格的距离时速度为零，
    /// 停在原地等手指回中间；推过连发线才持续滚，越远越快。
    private func scrollRate(forCrossOffset offset: CGFloat) -> CGFloat {
        let magnitude = abs(offset)
        guard magnitude >= Self.albumScrollRepeatOffset else { return 0 }

        let span = Self.albumScrollMaxOffset - Self.albumScrollRepeatOffset
        let normalized = span > 0 ? min((magnitude - Self.albumScrollRepeatOffset) / span, 1) : 1
        let speed = Self.albumScrollMinRate
            + (Self.albumScrollMaxRate - Self.albumScrollMinRate) * normalized * normalized
        return offset < 0 ? -speed : speed
    }

    /// 按帧攒进度，攒够一整格才换，所以慢推是一格一格走、推到头就连成连续滚动
    private func advanceAlbumScroll() {
        guard albumPick != nil, albumScrollRate != 0, albums.count > 1 else { return }

        albumScrollProgress += albumScrollRate * Self.albumScrollTick
        let steps = Int(albumScrollProgress.rounded(.towardZero))
        guard steps != 0 else { return }

        albumScrollProgress -= CGFloat(steps)
        stepAlbumSelection(by: steps)
    }

    private func stepAlbumSelection(by steps: Int) {
        guard let albumPick, !albums.isEmpty else { return }

        let index = min(max(albumPick.index + steps, 0), albums.count - 1)
        guard index != albumPick.index else { return }

        self.albumPick = AlbumPickSession(
            direction: albumPick.direction,
            anchor: albumPick.anchor,
            index: index
        )
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func startAlbumScroll() {
        guard albumScrollTimer == nil else { return }
        let timer = Timer(timeInterval: TimeInterval(Self.albumScrollTick), repeats: true) { _ in
            self.advanceAlbumScroll()
        }
        // 必须挂在 common 模式，手势跟踪期间默认模式的定时器会被挂起
        RunLoop.main.add(timer, forMode: .common)
        albumScrollTimer = timer
    }

    private func stopAlbumScroll() {
        albumScrollTimer?.invalidate()
        albumScrollTimer = nil
        albumScrollSign = 0
        albumScrollRate = 0
        albumScrollProgress = 0
    }

    private func cancelAlbumPick() {
        guard albumPick != nil else { return }
        stopAlbumScroll()
        albumPick = nil
    }

    /// 捕获双指捏合；缩放期间强制收回可能已产生的单指位移，避免误触决策。
    private func zoomGesture(viewportSize: CGSize, photo: PhotoItem) -> some Gesture {
        MagnificationGesture(minimumScaleDelta: 0.01)
            .updating($gestureZoomScale) { value, state, _ in
                state = value
            }
            .onChanged { _ in
                if !isPinching {
                    isPinching = true
                    motionPlayback.endPress()
                    cancelAlbumPick()
                    dragOffset = .zero
                }
            }
            .onEnded { value in
                let newScale = min(max(settledZoomScale * value, 1), 5)
                settledZoomScale = newScale
                settledPanOffset = clampedPanOffset(
                    settledPanOffset,
                    viewportSize: viewportSize,
                    photo: photo,
                    scale: newScale
                )
                panGestureStart = settledPanOffset
                isPinching = false
                UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.45)
            }
    }

    /// 按照照片 aspectFit 后的真实尺寸限制平移，避免拖过头露出黑边。
    private func clampedPanOffset(
        _ proposedOffset: CGSize,
        viewportSize: CGSize,
        photo: PhotoItem,
        scale: CGFloat
    ) -> CGSize {
        guard scale > 1.01,
              viewportSize.width > 0,
              viewportSize.height > 0,
              photo.pixelWidth > 0,
              photo.pixelHeight > 0 else { return .zero }

        let imageAspectRatio = CGFloat(photo.pixelWidth) / CGFloat(photo.pixelHeight)
        let viewportAspectRatio = viewportSize.width / viewportSize.height
        let fittedSize: CGSize

        if imageAspectRatio > viewportAspectRatio {
            fittedSize = CGSize(
                width: viewportSize.width,
                height: viewportSize.width / imageAspectRatio
            )
        } else {
            fittedSize = CGSize(
                width: viewportSize.height * imageAspectRatio,
                height: viewportSize.height
            )
        }

        let horizontalLimit = max((fittedSize.width * scale - viewportSize.width) / 2, 0)
        let verticalLimit = max((fittedSize.height * scale - viewportSize.height) / 2, 0)

        return CGSize(
            width: min(max(proposedOffset.width, -horizontalLimit), horizontalLimit),
            height: min(max(proposedOffset.height, -verticalLimit), verticalLimit)
        )
    }

    private func resetZoom(animated: Bool) {
        let changes = {
            settledZoomScale = 1
            settledPanOffset = .zero
            panGestureStart = .zero
            isPanningZoomedPhoto = false
            isPinching = false
            stopAlbumScroll()
            albumPick = nil
            dragOffset = .zero
        }

        if animated {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82), changes)
        } else {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction, changes)
        }
    }
}

/// 分组内的全屏整理：左右滑或按钮标记删除/保留，标记结果回到网格里继续用
private struct GroupReviewView: View {
    let photos: [PhotoItem]
    @Binding var selectedPhotoIDs: Set<String>
    let onClose: () -> Void

    @State private var index: Int
    @State private var dragOffset: CGSize = .zero
    @State private var isAnimatingOut = false
    /// 每一步改动前的标记状态，撤回时用它精确还原
    @State private var history: [(id: String, wasSelected: Bool)] = []

    init(
        photos: [PhotoItem],
        startIndex: Int,
        selectedPhotoIDs: Binding<Set<String>>,
        onClose: @escaping () -> Void
    ) {
        self.photos = photos
        _selectedPhotoIDs = selectedPhotoIDs
        self.onClose = onClose
        _index = State(initialValue: startIndex)
    }

    private var currentPhoto: PhotoItem? {
        photos.indices.contains(index) ? photos[index] : nil
    }

    /// 当前张加一张预载，交给全屏视图做无缝衔接
    private var upcomingPhotos: [PhotoItem] {
        guard photos.indices.contains(index) else { return [] }
        return Array(photos[index...].prefix(2))
    }

    /// 分组里按张数走进度；当前这张已被标记时在进度后挂一枚红色小标签
    private var progress: SwipeProgress? {
        guard let currentPhoto, !photos.isEmpty else { return nil }
        return SwipeProgress(
            text: "\(index + 1) / \(photos.count)",
            fraction: Double(index + 1) / Double(photos.count),
            badge: selectedPhotoIDs.contains(currentPhoto.id) ? L10n.text("已标记删除") : nil
        )
    }

    var body: some View {
        // 走完最后一张后列表变空，全屏视图会自动退出
        FullScreenSwipeView(
            photos: upcomingPhotos,
            progress: progress,
            dragOffset: $dragOffset,
            isAnimatingOut: isAnimatingOut,
            canUndo: !history.isEmpty,
            isLoadingPhotos: false,
            closesWhenEmpty: true,
            onDelete: { advance(markDelete: true, exitDirection: $0) },
            onKeep: { advance(markDelete: false, exitDirection: $0) },
            onUndo: undoLast,
            onClose: onClose
        )
    }

    /// 分组里的删除只是打标记，回到网格后仍由“加入待删除”统一生效
    private func advance(markDelete: Bool, exitDirection: SwipeDirection) {
        guard !isAnimatingOut, let photo = currentPhoto else { return }
        isAnimatingOut = true

        let feedback = UIImpactFeedbackGenerator(style: .medium)
        feedback.prepare()
        // 取一个大于任何机型宽高的距离，保证卡片完全飞出屏幕
        let exitDistance: CGFloat = 900

        withAnimation(.easeOut(duration: 0.32)) {
            dragOffset = exitDirection.exitOffset(distance: exitDistance, from: dragOffset)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                history.append((photo.id, selectedPhotoIDs.contains(photo.id)))
                if markDelete {
                    selectedPhotoIDs.insert(photo.id)
                } else {
                    selectedPhotoIDs.remove(photo.id)
                }
                index += 1
                dragOffset = .zero
                isAnimatingOut = false
            }
            feedback.impactOccurred(intensity: markDelete ? 0.9 : 0.7)
        }
    }

    private func undoLast() {
        guard !isAnimatingOut, let last = history.popLast() else { return }

        if last.wasSelected {
            selectedPhotoIDs.insert(last.id)
        } else {
            selectedPhotoIDs.remove(last.id)
        }
        index = max(index - 1, 0)
        dragOffset = .zero
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

/// 全屏下按屏幕尺寸取图，完整显示不裁切
private extension View {
    /// 按给定比例收成 aspectFit 后的大小；比例未知就保持铺满，不去猜内容的固有尺寸
    @ViewBuilder
    func mediaAspect(_ ratio: CGFloat?) -> some View {
        if let ratio {
            aspectRatio(ratio, contentMode: .fit)
        } else {
            self
        }
    }
}

private struct FullScreenArtwork: View {
    let photo: PhotoItem

    @State private var loadedImage: UIImage?
    @State private var imageRequestID: PHImageRequestID?

    var body: some View {
        Group {
            if let image = photo.image ?? loadedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                if photo.isVideo, photo.assetIdentifier == nil {
                    Image(systemName: "video.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.6))
                } else {
                    ProgressView().tint(.white)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: photo.id) { requestImageIfNeeded() }
        .onDisappear(perform: cancelRequest)
    }

    private func requestImageIfNeeded() {
        cancelRequest()
        loadedImage = nil

        guard photo.image == nil,
              let identifier = photo.assetIdentifier else { return }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = assets.firstObject else { return }

        let options = PHImageRequestOptions()
        // 先给模糊图再补清晰图，避免全屏切换时长时间白屏
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        imageRequestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 1600, height: 1600),
            contentMode: .aspectFit,
            options: options
        ) { image, info in
            guard let image,
                  (info?[PHImageCancelledKey] as? Bool) != true else { return }
            DispatchQueue.main.async {
                loadedImage = image
            }
        }
    }

    private func cancelRequest() {
        guard let imageRequestID else { return }
        PHImageManager.default().cancelImageRequest(imageRequestID)
        self.imageRequestID = nil
    }
}

/// 底部操作栏里的一格。删除、保留是主操作：底色带判定色、圆更大；撤回、添加是辅助操作：只用浅色底。
/// emphasis 由拖动驱动，朝这个按钮对应的判定拖得越远，圆里填的颜色越满。
private struct FullScreenActionButton: View {
    let action: OrganizeAction
    /// 0...1
    var emphasis: Double = 0
    let perform: () -> Void

    private var isPrimary: Bool { action == .delete || action == .keep }

    var body: some View {
        let tint = action.tint
        let size = action.buttonSize

        Button(action: perform) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(isPrimary ? tint.opacity(0.16) : Color.white.opacity(0.08))
                    Circle()
                        .fill(tint)
                        .opacity(emphasis)
                    Image(systemName: action.symbol)
                        .font(.system(size: isPrimary ? 24 : 18, weight: .bold))
                        // 颜色填过一半后图标换成深色，避免同色图标糊在色块里
                        .foregroundStyle(emphasis > 0.5 ? Color.tidyOnAccent : tint)
                }
                .frame(width: size, height: size)
                .overlay {
                    Circle().strokeBorder(tint.opacity(isPrimary ? 0.45 : 0.16), lineWidth: 1.5)
                }
                .scaleEffect(1 + 0.1 * emphasis)

                // title 是纯 String，不会自动查表，必须显式走 L10n
                Text(L10n.text(action.title))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(emphasis > 0.5 ? 1 : 0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(SwipePressStyle())
        .animation(.easeOut(duration: 0.12), value: emphasis > 0.5)
    }
}

private struct LibraryConnectionView: View {
    let isLoading: Bool
    let isAccessDenied: Bool
    let contentHeight: CGFloat
    let onRequestAccess: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if isLoading {
                ProgressView()
                    .controlSize(.large)
                    .tint(Color.tidyAccent)
                Text("正在读取照片和视频…")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text("数据只在这台设备上处理")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.tidyMuted)
            } else {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(Color.tidyAccent)
                Text("选择照片图库")
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                Text(L10n.text(isAccessDenied ? "你已关闭照片访问，可在系统设置中重新开启。" : "在下一步选择要整理的照片和视频。"))
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.tidyMuted)
                    .multilineTextAlignment(.center)

                Button(action: onRequestAccess) {
                    Text(L10n.text(isAccessDenied ? "前往设置" : "继续"))
                }
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tidyOnAccent)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.tidyAccent, in: Capsule())
                    .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: contentHeight)
        .padding(.horizontal, 24)
        .background(Color.tidySurface, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }
}

private struct EmptyInboxView: View {
    @Binding var showImportPicker: Bool
    let isAuthorized: Bool
    let remainingCount: Int
    let contentHeight: CGFloat
    let onLoadNextBatch: () -> Void
    let onRequestAccess: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: remainingCount == 0 && isAuthorized ? "checkmark.seal.fill" : "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundStyle(remainingCount == 0 && isAuthorized ? Color.tidyKeep : Color.tidyAccent)
            Text(L10n.text(isAuthorized ? (remainingCount == 0 ? "相册已经整理完成" : "当前批次已完成") : "选择照片图库"))
                .font(.system(size: 23, weight: .bold, design: .rounded))
            Text(emptyDescription)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(Color.tidyMuted)

            Button {
                if !isAuthorized {
                    onRequestAccess()
                } else if remainingCount > 0 {
                    onLoadNextBatch()
                } else {
                    showImportPicker = true
                }
            } label: {
                Text(L10n.text(isAuthorized ? (remainingCount == 0 ? "导入照片或视频" : "加载下一批") : "继续"))
            }
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Color.tidyOnAccent)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(Color.tidyAccent, in: Capsule())
        }
        .frame(maxWidth: .infinity)
        .frame(height: contentHeight)
        .background(Color.tidySurface, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    private var emptyDescription: String {
        guard isAuthorized else { return L10n.text("在下一步选择要整理的照片和视频。") }
        guard remainingCount > 0 else { return L10n.text("暂时没有更多待整理项目。") }
        return L10n.format("还有 %lld 项等待整理。", remainingCount)
    }
}

/// 同一分类下的所有方案，分类名只在分区标题出现一次
private struct GroupSection: Identifiable {
    let id: String
    let symbol: String
    let tint: Color
    let groups: [PhotoGroup]

    var photoCount: Int {
        groups.reduce(0) { $0 + $1.photoCount }
    }

    var byteSize: Int64 {
        groups.reduce(0) { $0 + $1.byteSize }
    }

    /// 首页磁贴的封面：这个类别里最新的一张。只要一张，单次遍历取最大值，不必整体排序
    var coverPhoto: PhotoItem? {
        groups
            .lazy
            .flatMap(\.photos)
            .max { ($0.capturedAt ?? .distantPast) < ($1.capturedAt ?? .distantPast) }
    }

    /// 全是视频时按“段”计，否则按“项”
    var unitText: String {
        groups.allSatisfy { $0.photos.allSatisfy(\.isVideo) }
            ? L10n.text("段")
            : L10n.text("项")
    }

    /// 数量之外的补充信息：几组、占多大。体积是后台回填的，还没算出来时先不显示，避免闪一下 0 KB
    var detailText: String {
        var parts: [String] = []
        if groups.count > 1 {
            parts.append(L10n.format("%lld 组", groups.count))
        }
        if byteSize > 0 {
            parts.append(ByteSizeText.full(byteSize))
        }
        return parts.joined(separator: " · ")
    }

    var summary: String {
        var parts: [String] = []
        if groups.count > 1 {
            parts.append(L10n.format("%lld 组", groups.count))
        }
        parts.append(L10n.format("%@ %@", photoCount.formatted(), unitText))
        if byteSize > 0 {
            parts.append(ByteSizeText.full(byteSize))
        }
        return parts.joined(separator: " · ")
    }
}

/// 把分组按分类名归并：首页只展示分类入口，具体方案进分类页再看
private func makeGroupSections(from groups: [PhotoGroup]) -> [GroupSection] {
    var order: [String] = []
    var buckets: [String: [PhotoGroup]] = [:]

    for group in groups {
        if buckets[group.title] == nil {
            order.append(group.title)
        }
        buckets[group.title, default: []].append(group)
    }

    return order.compactMap { title in
        guard let items = buckets[title], let first = items.first else { return nil }
        return GroupSection(
            id: title,
            symbol: first.symbol,
            tint: first.tint,
            groups: items
        )
    }
}

private struct GroupCard: View {
    let group: PhotoGroup
    let action: () -> Void

    private let previewColumns = [
        GridItem(.flexible(minimum: 0), spacing: 8),
        GridItem(.flexible(minimum: 0), spacing: 8)
    ]

    /// 分类名已经在分区标题上，卡片只放预览图，因此每格可以给得更大
    private var previewPhotos: [PhotoItem] {
        Array(group.photos.prefix(2))
    }

    private var hiddenCount: Int {
        max(group.photoCount - previewPhotos.count, 0)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: previewColumns, spacing: 8) {
                    ForEach(Array(previewPhotos.enumerated()), id: \.element.id) { index, photo in
                        ArtworkView(photo: photo)
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay {
                                if index == previewPhotos.count - 1, hiddenCount > 0 {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .fill(.black.opacity(0.42))
                                        Text("+\(hiddenCount.formatted())")
                                            .font(.system(size: 24, weight: .bold, design: .rounded))
                                            .foregroundStyle(.white)
                                    }
                                }
                            }
                    }
                }

                HStack(spacing: 6) {
                    Text(L10n.format("%@ 张", group.photoCount.formatted()))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.tidyInk)

                    if group.byteSize > 0 {
                        Text("·")
                            .foregroundStyle(Color.tidyMuted)
                        HStack(spacing: 4) {
                            // 组内存在未下载的照片时才加云端标识
                            if group.hasCloudPhotos {
                                Image(systemName: "icloud")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            Text(ByteSizeText.full(group.byteSize))
                        }
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(group.tint)
                        .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(group.tint)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.tidySurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.tidyHairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

private struct PendingView: View {
    @Binding var pendingPhotos: [PhotoItem]
    let totalPendingCount: Int
    let onConfirmDelete: () -> Void
    let onRestore: (PhotoItem) -> Void
    let onOpenPhoto: (PhotoItem) -> Void

    private let columns = [
        GridItem(.flexible(minimum: 0), spacing: 12),
        GridItem(.flexible(minimum: 0), spacing: 12),
        GridItem(.flexible(minimum: 0), spacing: 12)
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(L10n.format("%@ 项", totalPendingCount.formatted()))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.tidyAccent)
                        .padding(.horizontal, 18)
                        .frame(height: 44)
                        .background(Color.tidySurface, in: Capsule())

                    Spacer()

                    Button(action: onConfirmDelete) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(Color.tidyDanger, in: Circle())
                            .shadow(color: Color.tidyDanger.opacity(0.24), radius: 12, y: 6)
                    }
                    .buttonStyle(.plain)
                    .disabled(pendingPhotos.isEmpty)
                    .opacity(pendingPhotos.isEmpty ? 0.4 : 1)
                }

                Text("待删除")
                    .font(.system(size: 40, weight: .bold, design: .rounded))

                if pendingPhotos.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "trash.slash")
                            .font(.system(size: 42, weight: .medium))
                            .foregroundStyle(Color.tidyMuted)
                        Text("这里还没有待删除的照片或视频")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                        Text("在整理页左滑，或在首页的分组整理里批量清理")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.tidyMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 100)
                } else {
                    Text(pendingSummary)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.tidyMuted)

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(pendingPhotos) { photo in
                            PendingPhotoCell(photo: photo) {
                                onRestore(photo)
                            } onOpen: {
                                onOpenPhoto(photo)
                            }
                            .id(photo.id)
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 22)
        }
    }

    private var pendingSummary: String {
        if totalPendingCount == pendingPhotos.count {
            return L10n.format("已暂存 %lld 项 · 确认后才会真正生效", totalPendingCount)
        }
        return L10n.format("待确认 %lld 项 · 当前显示最近 %lld 项", totalPendingCount, pendingPhotos.count)
    }
}

private struct PendingPhotoCell: View {
    let photo: PhotoItem
    let onUndo: () -> Void
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            ZStack(alignment: .bottomLeading) {
                Color.clear

                ArtworkView(photo: photo)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)

                HStack {
                    Spacer()
                    Text(photo.isVideo ? "▶ \(photo.durationText)" : photo.resolutionText)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.50), in: Capsule())
                }
                .padding(9)
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottomLeading) {
            Button(action: onUndo) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.black.opacity(0.48), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(9)
        }
        .clipped()
    }
}

private struct InsightsView: View {
    @Binding var showSettings: Bool
    let progressTotalCount: Int
    let reviewedCount: Int
    let pendingCount: Int
    let deletedCount: Int
    let totalReleasedBytes: Int64
    let currentMonthAddedCount: Int
    let monthlyReleases: [MonthlyRelease]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                HStack {
                    Text("整理战绩")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                    Spacer()
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Color.tidyAccent)
                            .frame(width: 50, height: 50)
                            .background(Color.tidySurface, in: Circle())
                    }
                    .buttonStyle(.plain)
                }

                ProgressSummaryCard(
                    totalCount: progressTotalCount,
                    reviewedCount: reviewedCount,
                    pendingCount: pendingCount
                )
                ReleaseCard(
                    deletedCount: deletedCount,
                    totalReleasedBytes: totalReleasedBytes,
                    currentMonthAddedCount: currentMonthAddedCount,
                    releases: monthlyReleases
                )
                AchievementCard(reviewedCount: reviewedCount)
                PrivacyFootnote()
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 22)
        }
    }
}

private struct ProgressSummaryCard: View {
    let totalCount: Int
    let reviewedCount: Int
    let pendingCount: Int

    private var progress: Double {
        guard totalCount > 0 else { return 0 }
        return min(max(Double(reviewedCount) / Double(totalCount), 0), 1)
    }

    var body: some View {
        HStack(spacing: 20) {
            ProgressRing(progress: progress)
                .frame(width: 126, height: 126)

            VStack(alignment: .leading, spacing: 4) {
                Text("当前相册")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tidyMuted)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(reviewedCount.formatted())
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                    Text("/ \(totalCount.formatted())")
                        .font(.system(size: 19, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.tidyMuted)
                }
                Label(L10n.format("待确认 %@", pendingCount.formatted()), systemImage: "trash.fill")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tidyAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.tidyAccent.opacity(0.12), in: Capsule())
            }

            Spacer(minLength: 0)
        }
        .padding(22)
        .background(Color.tidySurface, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }
}

private struct ReleaseCard: View {
    let deletedCount: Int
    let totalReleasedBytes: Int64
    let currentMonthAddedCount: Int
    let releases: [MonthlyRelease]

    private var maximumReleaseBytes: Int64 {
        max(releases.map(\.bytes).max() ?? 0, 1)
    }

    private var currentMonthCleanedCount: Int {
        releases.last?.deletedCount ?? 0
    }

    private func barHeight(for bytes: Int64) -> CGFloat {
        max(3, 86 * CGFloat(bytes) / CGFloat(maximumReleaseBytes))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("累计清理")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.tidyMuted)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(deletedCount.formatted())
                            .font(.system(size: 58, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.tidyAccent)
                        Text("项")
                            .font(.system(size: 23, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.tidyMuted)
                    }
                    Text(L10n.format("累计释放 %@", ByteSizeText.full(totalReleasedBytes)))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.tidyMuted)
                }
                Spacer()
                Image(systemName: "trophy.fill")
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(Color.tidyAccent)
                    .frame(width: 60, height: 60)
                    .background(Color.tidyAccent.opacity(0.12), in: Circle())
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("每月释放空间")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tidyMuted)

                HStack(spacing: 12) {
                    ForEach(ReleasedMediaKind.allCases) { kind in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(kind.chartColor)
                                .frame(width: 8, height: 8)
                            Text(kind.chartTitle)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.tidyMuted)

                VStack(spacing: 7) {
                    HStack(alignment: .bottom, spacing: 12) {
                        ForEach(releases) { release in
                            VStack(spacing: 6) {
                                Text(ByteSizeText.compact(release.bytes))
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.tidyMuted)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                                ReleaseStackedBar(release: release)
                                    .frame(height: barHeight(for: release.bytes))
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }

                    Rectangle()
                        .fill(Color.tidyMuted.opacity(0.18))
                        .frame(height: 1)

                    HStack(spacing: 12) {
                        ForEach(releases) { release in
                            Text(release.label)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.tidyAccent.opacity(0.72))
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }

            HStack(spacing: 0) {
                StatItem(symbol: "trash.slash", value: currentMonthCleanedCount.formatted(), label: "本月已清理")
                Divider().frame(height: 40)
                StatItem(symbol: "calendar.badge.plus", value: currentMonthAddedCount.formatted(), label: "本月新增")
            }
        }
        .padding(22)
        .background(Color.tidySurface, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }
}

private struct ReleaseStackedBar: View {
    let release: MonthlyRelease

    private var visibleKinds: [ReleasedMediaKind] {
        ReleasedMediaKind.allCases.filter { release.bytes(for: $0) > 0 }
    }

    var body: some View {
        GeometryReader { proxy in
            if release.bytes > 0 {
                VStack(spacing: 1) {
                    // 体积大的类型占据更高的段；每月都使用同一套固定颜色。
                    ForEach(visibleKinds) { kind in
                        kind.chartColor
                            .frame(
                                height: max(
                                    1,
                                    (proxy.size.height - CGFloat(max(visibleKinds.count - 1, 0)))
                                        * CGFloat(release.bytes(for: kind)) / CGFloat(release.bytes)
                                )
                            )
                    }
                }
            } else {
                Color.tidyHairline
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(release.accessibilityBreakdown)
    }
}

private extension ReleasedMediaKind {
    var chartTitle: String {
        switch self {
        case .photo: L10n.text("照片")
        case .video: L10n.text("视频")
        case .motion: L10n.text("动态")
        case .other: L10n.text("其他")
        }
    }

    var chartColor: Color {
        switch self {
        case .photo: .tidyKeep
        case .video: .tidyCyan
        case .motion: .tidyAmber
        case .other: .tidyMuted
        }
    }
}

private extension MonthlyRelease {
    var accessibilityBreakdown: String {
        let details = ReleasedMediaKind.allCases.compactMap { kind -> String? in
            let value = bytes(for: kind)
            return value > 0 ? "\(kind.chartTitle) \(ByteSizeText.full(value))" : nil
        }
        let total = L10n.format("%@，总计 %@", label, ByteSizeText.full(bytes))
        return total + (details.isEmpty ? "" : L10n.text("，") + details.joined(separator: L10n.text("，")))
    }
}

/// 勋章的唯一定义来源，解锁门槛按已整理张数
private struct Achievement: Identifiable {
    let threshold: Int
    let symbol: String
    let title: String
    let tint: Color

    var id: Int { threshold }

    static let all: [Achievement] = [
        Achievement(threshold: 1, symbol: "drop.fill", title: "破冰", tint: .tidyAccent),
        Achievement(threshold: 10, symbol: "sparkles", title: "小试身手", tint: .tidyCyan),
        Achievement(threshold: 50, symbol: "leaf.fill", title: "渐入佳境", tint: .tidyKeep),
        Achievement(threshold: 100, symbol: "rosette", title: "百张挑战", tint: .tidyDanger),
        Achievement(threshold: 500, symbol: "flame.fill", title: "五百精选", tint: .tidyAmber),
        Achievement(threshold: 1_000, symbol: "star.fill", title: "千张达人", tint: .tidyAccent),
        Achievement(threshold: 2_000, symbol: "bolt.fill", title: "两千里", tint: .tidyCyan),
        Achievement(threshold: 5_000, symbol: "shield.fill", title: "五千大关", tint: .tidyKeep),
        Achievement(threshold: 10_000, symbol: "trophy.fill", title: "万张宗师", tint: .tidyDanger),
        Achievement(threshold: 20_000, symbol: "mountain.2.fill", title: "两万征程", tint: .tidyAmber),
        Achievement(threshold: 50_000, symbol: "seal.fill", title: "五万传奇", tint: .tidyAccent),
        Achievement(threshold: 100_000, symbol: "crown.fill", title: "十万巅峰", tint: .tidyCyan)
    ]
}

private struct AchievementCard: View {
    let reviewedCount: Int

    private var achievedCount: Int {
        Achievement.all.filter { reviewedCount >= $0.threshold }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("荣誉勋章")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Spacer()
                Text("\(achievedCount) / \(Achievement.all.count)")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.tidyMuted.opacity(0.10), in: Capsule())
            }
            .padding(.horizontal, 22)

            // 横向滚动，左滑即可查看尚未解锁的挑战
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(Achievement.all) { achievement in
                        AchievementTile(achievement: achievement, reviewedCount: reviewedCount)
                    }
                }
                .padding(.horizontal, 22)
            }
        }
        .padding(.vertical, 22)
        .background(Color.tidySurface, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }
}

private struct AchievementTile: View {
    let achievement: Achievement
    let reviewedCount: Int

    private var isUnlocked: Bool {
        reviewedCount >= achievement.threshold
    }

    private var progress: Double {
        min(Double(reviewedCount) / Double(achievement.threshold), 1)
    }

    private var subtitle: String {
        isUnlocked
            ? L10n.format("已整理 %@ 张", achievement.threshold.formatted())
            : L10n.format("还差 %@ 张", (achievement.threshold - reviewedCount).formatted())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: isUnlocked ? achievement.symbol : "lock.fill")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(isUnlocked ? achievement.tint : Color.tidyMuted)
                .frame(width: 58, height: 58)
                .background((isUnlocked ? achievement.tint : Color.tidyMuted).opacity(0.13), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text(achievement.title))
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.tidyMuted)
                    .lineLimit(1)
            }

            // 用真实进度展示离解锁还有多远
            Capsule()
                .fill(Color.tidyMuted.opacity(0.16))
                .frame(height: 5)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(isUnlocked ? achievement.tint : Color.tidyAccent)
                            .frame(width: proxy.size.width * progress)
                    }
                }
        }
        .frame(width: 138, alignment: .leading)
        .padding(16)
        .background(Color.tidyBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct StatItem: View {
    let symbol: String
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.tidyMuted)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                // label 是纯 String，不会自动查表，必须显式走 L10n
                Text(L10n.text(label))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.tidyMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProgressRing: View {
    let progress: Double

    private var percentageText: String {
        "\(Int((min(max(progress, 0), 1) * 100).rounded()))%"
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.tidyMuted.opacity(0.13), lineWidth: 13)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    Color.tidyAccent,
                    style: StrokeStyle(lineWidth: 13, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Text(percentageText)
                .font(.system(size: 22, weight: .bold, design: .rounded))
        }
    }
}

private struct PrivacyFootnote: View {
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "lock.fill")
            Text("所有分析都在本机完成 · 不上传照片 · 支持 iCloud")
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .foregroundStyle(Color.tidyMuted)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

private struct ArtworkView: View {
    let photo: PhotoItem
    var onImageReady: () -> Void = { }

    @State private var loadedImage: UIImage?
    @State private var imageRequestID: PHImageRequestID?

    var body: some View {
        Group {
            if let image = photo.image ?? loadedImage {
                // 由 Color.clear 决定布局尺寸，图片以 overlay 居中铺满后裁掉溢出，保证只显示中间部分
                Color.clear
                    .overlay {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
            } else {
                SampleArtwork(kind: photo.artwork)
                    .overlay {
                        if photo.assetIdentifier != nil {
                            ProgressView()
                                .tint(.white)
                        }
                    }
            }
        }
        .onAppear {
            if photo.image != nil { onImageReady() }
            requestThumbnailIfNeeded()
        }
        .onDisappear {
            if let imageRequestID {
                PHImageManager.default().cancelImageRequest(imageRequestID)
                self.imageRequestID = nil
            }
        }
    }

    private func requestThumbnailIfNeeded() {
        guard photo.image == nil,
              loadedImage == nil,
              imageRequestID == nil,
              let identifier = photo.assetIdentifier else { return }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = assets.firstObject else { return }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        imageRequestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 420, height: 420),
            contentMode: .aspectFill,
            options: options
        ) { image, info in
            guard let image,
                  (info?[PHImageCancelledKey] as? Bool) != true else { return }
            DispatchQueue.main.async {
                loadedImage = image
                onImageReady()
            }
        }
    }
}

private struct SampleArtwork: View {
    let kind: ArtworkKind

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                switch kind {
                case .bedroom:
                    LinearGradient(colors: [Color(red: 0.38, green: 0.33, blue: 0.26), Color(red: 0.78, green: 0.70, blue: 0.58)], startPoint: .top, endPoint: .bottom)
                    Image(systemName: "bed.double.fill")
                        .font(.system(size: proxy.size.width * 0.52, weight: .black))
                        .foregroundStyle(.white.opacity(0.74))
                        .rotationEffect(.degrees(-8))
                    Circle()
                        .fill(Color(red: 0.94, green: 0.66, blue: 0.44).opacity(0.88))
                        .frame(width: proxy.size.width * 0.20)
                        .offset(x: proxy.size.width * 0.22, y: proxy.size.height * 0.16)

                case .mountain:
                    LinearGradient(colors: [Color(red: 0.24, green: 0.54, blue: 0.86), Color(red: 0.13, green: 0.25, blue: 0.48)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Circle()
                        .fill(Color.yellow.opacity(0.80))
                        .frame(width: proxy.size.width * 0.24)
                        .offset(x: proxy.size.width * 0.22, y: -proxy.size.height * 0.20)
                    Image(systemName: "mountain.2.fill")
                        .font(.system(size: proxy.size.width * 0.62, weight: .black))
                        .foregroundStyle(Color.white.opacity(0.82))
                        .offset(y: proxy.size.height * 0.12)

                case .cafe:
                    LinearGradient(colors: [Color(red: 0.90, green: 0.56, blue: 0.30), Color(red: 0.38, green: 0.17, blue: 0.12)], startPoint: .top, endPoint: .bottom)
                    Circle()
                        .fill(Color.orange.opacity(0.85))
                        .frame(width: proxy.size.width * 0.35)
                        .offset(x: -proxy.size.width * 0.23, y: -proxy.size.height * 0.22)
                    Image(systemName: "cup.and.saucer.fill")
                        .font(.system(size: proxy.size.width * 0.46, weight: .black))
                        .foregroundStyle(.white.opacity(0.86))
                        .offset(y: proxy.size.height * 0.08)

                case .plant:
                    LinearGradient(colors: [Color(red: 0.45, green: 0.70, blue: 0.47), Color(red: 0.09, green: 0.29, blue: 0.22)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "leaf.fill")
                        .font(.system(size: proxy.size.width * 0.58, weight: .black))
                        .foregroundStyle(Color.white.opacity(0.80))
                        .rotationEffect(.degrees(-22))
                    Circle()
                        .fill(Color.yellow.opacity(0.42))
                        .frame(width: proxy.size.width * 0.18)
                        .offset(x: proxy.size.width * 0.27, y: -proxy.size.height * 0.28)

                case .city:
                    LinearGradient(colors: [Color(red: 0.39, green: 0.68, blue: 0.91), Color(red: 0.13, green: 0.27, blue: 0.43)], startPoint: .top, endPoint: .bottom)
                    Image(systemName: "building.2.fill")
                        .font(.system(size: proxy.size.width * 0.60, weight: .black))
                        .foregroundStyle(.white.opacity(0.76))
                        .offset(y: proxy.size.height * 0.08)
                    Circle()
                        .fill(Color.yellow.opacity(0.70))
                        .frame(width: proxy.size.width * 0.18)
                        .offset(x: -proxy.size.width * 0.28, y: -proxy.size.height * 0.28)

                case .food:
                    LinearGradient(colors: [Color(red: 0.96, green: 0.79, blue: 0.48), Color(red: 0.69, green: 0.28, blue: 0.16)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "fork.knife")
                        .font(.system(size: proxy.size.width * 0.55, weight: .black))
                        .foregroundStyle(.white.opacity(0.84))
                        .rotationEffect(.degrees(-18))
                    Circle()
                        .fill(.white.opacity(0.60))
                        .frame(width: proxy.size.width * 0.20)
                        .offset(x: proxy.size.width * 0.26, y: proxy.size.height * 0.24)

                case .screenshot:
                    LinearGradient(colors: [Color(red: 0.90, green: 0.88, blue: 0.94), Color(red: 0.66, green: 0.65, blue: 0.74)], startPoint: .top, endPoint: .bottom)
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.white.opacity(0.88))
                        .frame(width: proxy.size.width * 0.62, height: proxy.size.height * 0.48)
                        .rotationEffect(.degrees(-6))
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.white)
                        .frame(width: proxy.size.width * 0.62, height: proxy.size.height * 0.48)
                        .overlay {
                            VStack(spacing: 7) {
                                ForEach(0..<5, id: \.self) { index in
                                    Capsule()
                                        .fill(Color.tidyMuted.opacity(0.22))
                                        .frame(width: proxy.size.width * (index == 2 ? 0.34 : 0.46), height: 5)
                                }
                            }
                        }
                        .rotationEffect(.degrees(5))

                case .car:
                    LinearGradient(colors: [Color(red: 0.20, green: 0.22, blue: 0.24), Color(red: 0.72, green: 0.49, blue: 0.27)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "car.fill")
                        .font(.system(size: proxy.size.width * 0.56, weight: .black))
                        .foregroundStyle(.white.opacity(0.76))
                        .rotationEffect(.degrees(-6))
                    Circle()
                        .fill(Color.white.opacity(0.48))
                        .frame(width: proxy.size.width * 0.16)
                        .offset(x: proxy.size.width * 0.28, y: -proxy.size.height * 0.28)

                case .game:
                    LinearGradient(colors: [Color(red: 0.20, green: 0.35, blue: 0.76), Color(red: 0.37, green: 0.15, blue: 0.56)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: proxy.size.width * 0.52, weight: .black))
                        .foregroundStyle(.white.opacity(0.86))
                    Circle()
                        .fill(Color.cyan.opacity(0.68))
                        .frame(width: proxy.size.width * 0.16)
                        .offset(x: -proxy.size.width * 0.27, y: -proxy.size.height * 0.24)

                case .shipping:
                    LinearGradient(colors: [Color(red: 0.92, green: 0.90, blue: 0.86), Color(red: 0.62, green: 0.67, blue: 0.70)], startPoint: .top, endPoint: .bottom)
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: proxy.size.width * 0.54, weight: .black))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .offset(y: proxy.size.height * 0.06)
                    Text("快递")
                        // 这层是模拟照片，底色固定是浅灰，文字不能跟着主题走
                        .foregroundStyle(Color(red: 0.18, green: 0.19, blue: 0.22).opacity(0.72))
                        .font(.system(size: proxy.size.width * 0.15, weight: .black, design: .rounded))

                case .imported:
                    LinearGradient(colors: [Color(red: 0.38, green: 0.62, blue: 0.92), Color(red: 0.18, green: 0.20, blue: 0.44)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "photo.fill")
                        .font(.system(size: proxy.size.width * 0.50, weight: .bold))
                        .foregroundStyle(.white.opacity(0.86))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .clipped()
    }
}

private struct PhotoSearchRequest: Equatable {
    let id = UUID()
    let query: String
    let scope: PhotoSearchScope
}

private struct PhotoSearchView: View {
    @ObservedObject var photoLibrary: PhotoLibraryStore
    let onDecision: (PhotoItem, SwipeDecision) -> Void
    let onUndoDecision: (PhotoItem) -> Void
    let onDeleteSession: ([PhotoItem], @escaping (OrganizeDeletionResult) -> Void) -> Void
    let onBack: () -> Void

    @State private var query = ""
    @State private var request: PhotoSearchRequest?
    @State private var results: [PhotoItem] = []
    @State private var hasSearched = false
    @State private var organizeQueue: [PhotoItem] = []
    @State private var organizeTotalCount = 0
    @State private var showsOrganizer = false
    @State private var handledSearchPhotoIDs: Set<String> = []
    @State private var scope = PhotoSearchScope()
    @State private var showsScopeSettings = false
    @State private var didPrepareScope = false
    @AppStorage("photoSearch.scope.mode") private var storedScopeMode = PhotoSearchScopeMode.recent.rawValue
    @AppStorage("photoSearch.scope.recentLimit") private var storedRecentLimit = 1_000
    @AppStorage("photoSearch.scope.startYear") private var storedStartYear = Calendar.current.component(.year, from: Date())
    @AppStorage("photoSearch.scope.endYear") private var storedEndYear = Calendar.current.component(.year, from: Date())
    @FocusState private var isSearchFocused: Bool

    private let suggestions = ["证件", "水果", "宠物", "美食", "汽车", "截图"]
    private let columns = [
        GridItem(.adaptive(minimum: 136, maximum: 210), spacing: 10)
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            scopeIndicator
            searchContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.tidyBackground)
        .fullScreenCover(isPresented: $showsOrganizer) {
            OrganizeView(
                inbox: $organizeQueue,
                source: .search(totalCount: organizeTotalCount),
                progressTotalCount: photoLibrary.progressTotalCount,
                reviewedCount: photoLibrary.reviewedCount,
                albums: photoLibrary.albums,
                onDecision: { photo, decision in
                    handledSearchPhotoIDs.insert(photo.id)
                    onDecision(photo, decision)
                },
                onUndoDecision: { photo in
                    handledSearchPhotoIDs.remove(photo.id)
                    onUndoDecision(photo)
                },
                onLoadNextBatch: { 0 },
                onAddToAlbum: { photo, album in
                    await photoLibrary.addPhoto(photo, to: album)
                },
                onCreateAlbum: { name, photo in
                    await photoLibrary.createAlbum(named: name, initialPhoto: photo)
                },
                onDeleteSession: onDeleteSession,
                onClose: { showsOrganizer = false }
            )
        }
        .sheet(isPresented: $showsScopeSettings, onDismiss: refreshSearchForScope) {
            PhotoSearchScopeSettingsView(
                scope: $scope,
                totalPhotoCount: photoLibrary.searchablePhotoCount,
                availableYears: availableYears
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .task(id: request?.id) {
            guard let request else { return }
            hasSearched = false
            results = []
            handledSearchPhotoIDs = []
            let found = await photoLibrary.searchPhotos(matching: request.query, scope: request.scope)
            guard !Task.isCancelled else { return }
            results = found
            hasSearched = true
        }
        .onChange(of: query) { value in
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                results = []
                hasSearched = false
            }
        }
        .onChange(of: scope) { value in
            storedScopeMode = value.mode.rawValue
            storedRecentLimit = value.recentLimit
            storedStartYear = value.startYear
            storedEndYear = value.endYear
        }
        .onAppear {
            prepareInitialScope()
            isSearchFocused = true
        }
    }

    private var header: some View {
        ZStack {
            Text("搜索照片")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(Color.tidyInk)

            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 23, weight: .bold))
                        .foregroundStyle(Color.tidyInk)
                        .frame(width: 54, height: 54)
                        .background(Color.tidySurface, in: Circle())
                        .shadow(color: Color.black.opacity(0.07), radius: 16, y: 8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回")

                Spacer()

                Button { showsScopeSettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.tidyAccent)
                        .frame(width: 54, height: 54)
                        .background(Color.tidySurface, in: Circle())
                        .shadow(color: Color.black.opacity(0.07), radius: 16, y: 8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("分析范围")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.tidyMuted)

            TextField("搜索证件、水果、宠物…", text: $query)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(Color.tidyInk)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isSearchFocused)
                .onSubmit(submitSearch)

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.tidyMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }

            Button(action: submitSearch) {
                Text("搜索")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tidyOnAccent)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(Color.tidyAccent, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || photoLibrary.isSearchingPhotos)
            .opacity(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
        }
        .padding(.leading, 16)
        .padding(.trailing, 7)
        .frame(height: 52)
        .background(Color.tidySurface, in: Capsule())
        .overlay(Capsule().stroke(Color.tidyHairline, lineWidth: 1))
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    private var scopeIndicator: some View {
        Button { showsScopeSettings = true } label: {
            HStack(spacing: 7) {
                Image(systemName: scope.mode == .recent ? "photo.stack" : "calendar")
                Text(scopeSummary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(Color.tidyAccent)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Color.tidyAccent.opacity(0.10), in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var searchContent: some View {
        if photoLibrary.isSearchingPhotos {
            VStack(spacing: 12) {
                VStack(spacing: 10) {
                    ProgressView(value: photoLibrary.photoSearchProgress?.fraction ?? 0)
                        .tint(Color.tidyAccent)
                        .frame(maxWidth: 320)

                    Text(searchProgressText)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.tidyMuted)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)

                if photoLibrary.photoSearchLiveResults.isEmpty {
                    Spacer()
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        resultGrid(photoLibrary.photoSearchLiveResults)
                            .padding(.horizontal, 18)
                            .padding(.bottom, 28)
                            .frame(maxWidth: 1_000)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if hasSearched, visibleResults(results).isEmpty {
            TidyEmptyStateView(
                title: L10n.text(results.isEmpty ? "没有找到相关照片" : "搜索结果已整理完"),
                systemImage: results.isEmpty ? "photo.badge.magnifyingglass" : "checkmark.circle",
                description: L10n.text(
                    results.isEmpty
                        ? "可以换一个更常见的类别试试"
                        : "这些选择已经同步到首页整理进度"
                )
            )
        } else if hasSearched {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.format("找到 %@ 张照片", visibleResults(results).count.formatted()))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.tidyMuted)

                    resultGrid(results)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 28)
                .frame(maxWidth: 1_000)
                .frame(maxWidth: .infinity)
            }
        } else {
            VStack(spacing: 18) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Color.tidyAccent)

                VStack(spacing: 6) {
                    Text("用内容查找照片")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.tidyInk)
                    Text("识别在本机完成，不会上传照片或保存证件文字")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.tidyMuted)
                        .multilineTextAlignment(.center)
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 88, maximum: 128), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button {
                            let localizedSuggestion = L10n.text(suggestion)
                            query = localizedSuggestion
                            isSearchFocused = false
                            request = PhotoSearchRequest(query: suggestion, scope: scope)
                        } label: {
                            Text(L10n.text(suggestion))
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.tidyAccent)
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                                .background(Color.tidyAccent.opacity(0.11), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 480)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var searchProgressText: String {
        guard let progress = photoLibrary.photoSearchProgress else {
            return L10n.text("正在准备本机照片索引…")
        }
        return L10n.format("正在分析 %@ / %@ 张照片", progress.completed.formatted(), progress.total.formatted())
    }

    private func resultGrid(_ photos: [PhotoItem]) -> some View {
        let visiblePhotos = visibleResults(photos)
        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(visiblePhotos) { photo in
                PhotoSearchResultCell(photo: photo) {
                    beginOrganizing(at: photo, in: visiblePhotos)
                }
            }
        }
    }

    private func visibleResults(_ photos: [PhotoItem]) -> [PhotoItem] {
        photos.filter {
            !handledSearchPhotoIDs.contains($0.id) && !photoLibrary.isReviewed($0)
        }
    }

    private func beginOrganizing(at selectedPhoto: PhotoItem, in photos: [PhotoItem]) {
        guard let selectedIndex = photos.firstIndex(where: { $0.id == selectedPhoto.id }) else { return }

        organizeQueue = Array(photos[selectedIndex...]) + Array(photos[..<selectedIndex])
        organizeTotalCount = organizeQueue.count
        showsOrganizer = true
    }

    private func submitSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSearchFocused = false
        request = PhotoSearchRequest(query: trimmed, scope: scope)
    }

    private var availableYears: [Int] {
        let years = photoLibrary.yearBuckets.compactMap { Int($0.id) }.sorted()
        return years.isEmpty ? [Calendar.current.component(.year, from: Date())] : years
    }

    private var scopeSummary: String {
        switch scope.mode {
        case .recent:
            return L10n.format("最近 %@ 张", min(scope.recentLimit, max(photoLibrary.searchablePhotoCount, 1)).formatted())
        case .years:
            let start = min(scope.startYear, scope.endYear)
            let end = max(scope.startYear, scope.endYear)
            return start == end
                ? L10n.format("%@ 年", start.formatted(.number.grouping(.never)))
                : L10n.format("%@ 年至 %@ 年", start.formatted(.number.grouping(.never)), end.formatted(.number.grouping(.never)))
        }
    }

    private func prepareInitialScope() {
        guard !didPrepareScope else { return }
        didPrepareScope = true
        let firstYear = availableYears.first ?? scope.startYear
        let lastYear = availableYears.last ?? scope.endYear
        let startYear = min(max(storedStartYear, firstYear), lastYear)
        let endYear = min(max(storedEndYear, startYear), lastYear)
        scope = PhotoSearchScope(
            mode: PhotoSearchScopeMode(rawValue: storedScopeMode) ?? .recent,
            recentLimit: max(min(storedRecentLimit, photoLibrary.searchablePhotoCount), 1),
            startYear: startYear,
            endYear: endYear
        )
    }

    private func refreshSearchForScope() {
        guard request?.scope != scope,
              hasSearched || photoLibrary.isSearchingPhotos else { return }
        submitSearch()
    }
}

private struct PhotoSearchResultCell: View {
    let photo: PhotoItem
    let onOpen: () -> Void

    @State private var resolvedStorage: AssetStorageInfo?

    private var storage: AssetStorageInfo? {
        if photo.byteSize > 0 {
            return AssetStorageInfo(byteSize: photo.byteSize, isInCloud: photo.isInCloud)
        }
        return resolvedStorage
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                ArtworkView(photo: photo)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .clipped()

                VStack(alignment: .leading, spacing: 4) {
                    Text(photo.title)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.tidyInk)
                        .lineLimit(1)

                    Text(photo.detail)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.tidyMuted)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        if let storage {
                            if storage.isInCloud {
                                Image(systemName: "icloud")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            Text(ByteSizeText.full(storage.byteSize))
                        } else {
                            Text("读取大小…")
                        }

                        Spacer(minLength: 2)

                        Text(photo.resolutionText)
                            .lineLimit(1)
                    }
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tidyMuted)
                }
                .padding(10)
            }
            .background(Color.tidySurface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.tidyHairline, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(photo.title)，\(photo.detail)，\(storageDescription)，\(photo.resolutionText)")
        .task(id: photo.id) {
            guard photo.byteSize == 0,
                  let identifier = photo.assetIdentifier,
                  let info = await AssetStorage.info(forAssetIdentifier: identifier) else { return }
            resolvedStorage = info
        }
    }

    private var storageDescription: String {
        guard let storage else { return L10n.text("大小读取中") }
        let size = ByteSizeText.full(storage.byteSize)
        return storage.isInCloud ? L10n.format("iCloud · %@", size) : size
    }
}

private struct PhotoSearchScopeSettingsView: View {
    @Binding var scope: PhotoSearchScope
    let totalPhotoCount: Int
    let availableYears: [Int]

    @Environment(\.dismiss) private var dismiss
    @State private var draft: PhotoSearchScope

    init(
        scope: Binding<PhotoSearchScope>,
        totalPhotoCount: Int,
        availableYears: [Int]
    ) {
        _scope = scope
        self.totalPhotoCount = totalPhotoCount
        self.availableYears = availableYears
        _draft = State(initialValue: scope.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("筛选方式", selection: $draft.mode) {
                        Text("最近张数").tag(PhotoSearchScopeMode.recent)
                        Text("年份范围").tag(PhotoSearchScopeMode.years)
                    }
                    .pickerStyle(.segmented)
                }

                switch draft.mode {
                case .recent:
                    countSection
                case .years:
                    yearSection
                }
            }
            .navigationTitle("分析范围")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        normalizeDraft()
                        scope = draft
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
        }
    }

    private var countSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("最近照片")
                    Spacer()
                    Text(L10n.format("%@ 张", min(draft.recentLimit, effectiveTotal).formatted()))
                        .fontWeight(.bold)
                        .foregroundStyle(Color.tidyAccent)
                }

                Slider(
                    value: Binding(
                        get: { Double(min(max(draft.recentLimit, 1), sliderUpperBound)) },
                        set: { draft.recentLimit = Int($0.rounded()) }
                    ),
                    in: 1...Double(sliderUpperBound),
                    step: 1
                )
                .tint(Color.tidyAccent)
                .disabled(totalPhotoCount <= 1)

                HStack {
                    Text("1")
                    Spacer()
                    Text(L10n.format("共 %@ 张", totalPhotoCount.formatted()))
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if !quickCounts.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(quickCounts, id: \.self) { count in
                            Button {
                                draft.recentLimit = count
                            } label: {
                                Text(count == effectiveTotal ? L10n.text("全部") : count.formatted())
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .tint(Color.tidyAccent)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        } footer: {
            Text("从最新照片开始，只分析选择的张数。")
        }
    }

    private var yearSection: some View {
        Section {
            Picker("开始年份", selection: $draft.startYear) {
                ForEach(normalizedYears, id: \.self) { year in
                    Text(verbatim: year.formatted(.number.grouping(.never))).tag(year)
                }
            }
            .onChange(of: draft.startYear) { value in
                if value > draft.endYear { draft.endYear = value }
            }

            Picker("结束年份", selection: $draft.endYear) {
                ForEach(normalizedYears, id: \.self) { year in
                    Text(verbatim: year.formatted(.number.grouping(.never))).tag(year)
                }
            }
            .onChange(of: draft.endYear) { value in
                if value < draft.startYear { draft.startYear = value }
            }
        } footer: {
            Text("包含开始年份和结束年份内拍摄的照片。")
        }
    }

    private var effectiveTotal: Int { max(totalPhotoCount, 1) }
    private var sliderUpperBound: Int { max(effectiveTotal, 2) }

    private var quickCounts: [Int] {
        guard totalPhotoCount > 0 else { return [] }
        return Array(Set([min(500, totalPhotoCount), min(1_000, totalPhotoCount), totalPhotoCount])).sorted()
    }

    private var normalizedYears: [Int] {
        let years = Array(Set(availableYears)).sorted()
        return years.isEmpty ? [Calendar.current.component(.year, from: Date())] : years
    }

    private func normalizeDraft() {
        draft.recentLimit = min(max(draft.recentLimit, 1), effectiveTotal)
        guard let firstYear = normalizedYears.first, let lastYear = normalizedYears.last else { return }
        draft.startYear = min(max(draft.startYear, firstYear), lastYear)
        draft.endYear = min(max(draft.endYear, draft.startYear), lastYear)
    }
}

private struct PhotoDetailView: View {
    let photo: PhotoItem
    @Environment(\.dismiss) private var dismiss
    @State private var fullImage: UIImage?

    init(photo: PhotoItem) {
        self.photo = photo
        _fullImage = State(initialValue: photo.image)
    }

    var body: some View {
        Group {
            if photo.isVideo {
                VideoPreviewView(photo: photo)
            } else {
                imagePreview
            }
        }
    }

    private var imagePreview: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let fullImage {
                Image(uiImage: fullImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 16)
            } else {
                ProgressView()
                    .tint(.white)
            }

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.40), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
            .padding(.trailing, 16)
        }
        .presentationDragIndicator(.visible)
        .task { await loadFullResolutionImage() }
    }

    private func loadFullResolutionImage() async {
        guard let identifier = photo.assetIdentifier else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = assets.firstObject else { return }

        let image: UIImage? = await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .none
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: PHImageManagerMaximumSize,
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }

        if let image {
            fullImage = image
        }
    }
}

/// 通用图片列表：任何一批照片都能用它浏览、勾选、放大整理
private struct PhotoListView: View {
    let title: String
    /// 标题下面的一行说明，比如被加载上限截断时的提示
    let notice: String?
    let photos: [PhotoItem]
    /// 完全重复的组才需要预选和推荐星标
    let allowsDuplicateRecommendation: Bool
    let displayLimit: Int?
    /// 内嵌在别的页面里时传 nil，不显示返回按钮
    let onBack: (() -> Void)?
    let onStageForDeletion: ([PhotoItem]) -> Void

    @State private var selectedPhotoIDs: Set<String>
    @State private var reviewStart: GroupReviewStart?
    @State private var mediaFilter: MediaFilter = .all
    private let recommendedPhotoID: String?
    private let columns = [
        GridItem(.flexible(minimum: 0), spacing: 6),
        GridItem(.flexible(minimum: 0), spacing: 6),
        GridItem(.flexible(minimum: 0), spacing: 6)
    ]

    init(
        title: String,
        notice: String? = nil,
        photos: [PhotoItem],
        allowsDuplicateRecommendation: Bool,
        displayLimit: Int? = nil,
        onBack: (() -> Void)? = nil,
        onStageForDeletion: @escaping ([PhotoItem]) -> Void
    ) {
        self.title = title
        self.notice = notice
        self.photos = photos
        self.allowsDuplicateRecommendation = allowsDuplicateRecommendation
        self.displayLimit = displayLimit
        self.onBack = onBack
        self.onStageForDeletion = onStageForDeletion

        let recommendedID = allowsDuplicateRecommendation ? Self.recommendedPhotoID(in: photos) : nil
        self.recommendedPhotoID = recommendedID
        let initialSelection = allowsDuplicateRecommendation
            ? Set(photos.lazy.filter { $0.id != recommendedID }.map(\.id))
            : []
        _selectedPhotoIDs = State(initialValue: initialSelection)
    }

    private var selectedPhotos: [PhotoItem] {
        visiblePhotos.filter { selectedPhotoIDs.contains($0.id) }
    }

    private var filteredPhotos: [PhotoItem] {
        photos.filter { mediaFilter.includes($0) }
    }

    private var visiblePhotos: [PhotoItem] {
        Array(filteredPhotos.prefix(displayLimit ?? photos.count))
    }

    private var displayNotice: String? {
        if visiblePhotos.count < filteredPhotos.count {
            return L10n.format("当前筛选共 %@ 项，显示最新 %@ 项 · 可在设置里调高上限", filteredPhotos.count.formatted(), visiblePhotos.count.formatted())
        }
        return notice.map(L10n.text)
    }

    var body: some View {
        VStack(spacing: 0) {
            listHeader

            if !allowsDuplicateRecommendation {
                Picker("筛选类型", selection: $mediaFilter) {
                    ForEach(MediaFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
            }

            if let notice = displayNotice {
                HStack(spacing: 7) {
                    Image(systemName: "info.circle")
                    Text(notice)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.tidyMuted)
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
            }

            if allowsDuplicateRecommendation {
                DuplicateRecommendationBar(
                    selectedCount: selectedPhotoIDs.count,
                    onKeepRecommendedOnly: selectAllExceptRecommended,
                    onClearAll: { selectedPhotoIDs = Set(photos.map(\.id)) }
                )
            }

            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(Array(visiblePhotos.enumerated()), id: \.element.id) { index, photo in
                        PhotoListCell(
                            photo: photo,
                            isSelected: selectedPhotoIDs.contains(photo.id),
                            isRecommended: allowsDuplicateRecommendation && photo.id == recommendedPhotoID,
                            onOpen: { reviewStart = GroupReviewStart(id: index) },
                            onToggleSelection: { toggleSelection(for: photo) }
                        )
                        .id(photo.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .background(Color.tidyBackground)
            .overlay {
                if visiblePhotos.isEmpty {
                    TidyEmptyStateView(
                        title: mediaFilter.emptyTitle,
                        systemImage: mediaFilter == .videos ? "video.slash" : "photo"
                    )
                        .allowsHitTesting(false)
                }
            }
        }
        // 盖在首页之上，必须撑满并且不透明，否则会漏出下层内容
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.tidyBackground)
        .onChange(of: mediaFilter) { _ in
            // 切换类型后不保留隐藏勾选，预览与网格共用同一份排序。
            selectedPhotoIDs.removeAll()
        }
        .fullScreenCover(item: $reviewStart) { start in
            GroupReviewView(
                photos: visiblePhotos,
                startIndex: start.id,
                selectedPhotoIDs: $selectedPhotoIDs,
                onClose: { reviewStart = nil }
            )
        }
    }

    @ViewBuilder
    private var listHeader: some View {
        Group {
            if let onBack {
                // 独立成页时标题居中，两侧留给返回和操作按钮
                ZStack {
                    Text(title)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.tidyInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 116)

                    HStack {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 23, weight: .bold))
                                .foregroundStyle(Color.tidyInk)
                                .frame(width: 54, height: 54)
                                .background(Color.tidySurface, in: Circle())
                                .shadow(color: Color.black.opacity(0.07), radius: 16, y: 8)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("返回")

                        Spacer()

                        actionCluster
                    }
                }
            } else {
                // 内嵌时没有返回按钮，标题靠左排更省地方
                HStack(spacing: 12) {
                    Text(title)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.tidyInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Spacer(minLength: 0)

                    actionCluster
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color.tidyBackground)
    }

    private var actionCluster: some View {
        HStack(spacing: 0) {
            Button(action: stageSelectedPhotos) {
                Image(systemName: "trash")
                    .font(.system(size: 21, weight: .semibold))
                    // 按选中的照片判断而不是选中的 id：处理过的照片移出列表后 id 会留着
                    .foregroundStyle(Color.tidyAccent.opacity(selectedPhotos.isEmpty ? 0.38 : 1))
                    .frame(width: 50, height: 48)
            }
            .buttonStyle(.plain)
            .disabled(selectedPhotos.isEmpty)
            .accessibilityLabel("将选中项目加入待删除")

            Divider()
                .frame(height: 28)

            Menu {
                Button("全选", systemImage: "checkmark.circle") {
                    selectedPhotoIDs = Set(visiblePhotos.map(\.id))
                }
                Button("取消全选", systemImage: "circle") {
                    selectedPhotoIDs.removeAll()
                }
                if allowsDuplicateRecommendation {
                    Divider()
                    Button("仅保留推荐照片", systemImage: "star.fill") {
                        selectAllExceptRecommended()
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(Color.tidyAccent)
                    .frame(width: 50, height: 48)
            }
            .accessibilityLabel("更多选择操作")
        }
        .padding(.horizontal, 4)
        .background(Color.tidySurface, in: Capsule())
        .shadow(color: Color.black.opacity(0.07), radius: 16, y: 8)
    }

    private func toggleSelection(for photo: PhotoItem) {
        if selectedPhotoIDs.contains(photo.id) {
            selectedPhotoIDs.remove(photo.id)
        } else {
            selectedPhotoIDs.insert(photo.id)
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func selectAllExceptRecommended() {
        selectedPhotoIDs = Set(photos.lazy.filter { $0.id != recommendedPhotoID }.map(\.id))
    }

    private func stageSelectedPhotos() {
        guard !selectedPhotos.isEmpty else { return }
        onStageForDeletion(selectedPhotos)
    }

    private static func recommendedPhotoID(in photos: [PhotoItem]) -> String? {
        photos.max { $0.pixelArea < $1.pixelArea }?.id
    }
}

private struct DuplicateRecommendationBar: View {
    let selectedCount: Int
    let onKeepRecommendedOnly: () -> Void
    let onClearAll: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                recommendationText
                Spacer(minLength: 8)
                actions
            }
            VStack(alignment: .leading, spacing: 10) {
                recommendationText
                actions
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.tidyMuted.opacity(0.07))
    }

    private var recommendationText: some View {
        HStack(spacing: 7) {
            Image(systemName: "star.fill")
                .foregroundStyle(Color.tidyAmber)
            Text(L10n.format("已为你预选 %lld 张（保留★最佳）", selectedCount))
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color.tidyMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("仅留★", action: onKeepRecommendedOnly)
            Button("清空", action: onClearAll)
        }
        .font(.system(size: 14, weight: .bold, design: .rounded))
        .foregroundStyle(Color.tidyAccent)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(Color.tidyAccent.opacity(0.14))
    }
}

private struct PhotoListCell: View {
    let photo: PhotoItem
    let isSelected: Bool
    let isRecommended: Bool
    let onOpen: () -> Void
    let onToggleSelection: () -> Void

    var body: some View {
        Button(action: onOpen) {
            ZStack {
                Color.clear

                ArtworkView(photo: photo)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        isSelected ? Color.tidyAccent : isRecommended ? Color.tidyAmber : Color.tidyHairline,
                        lineWidth: isRecommended || isSelected ? 3 : 1
                    )
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(photo.title)
        .accessibilityHint("放大整理")
        .overlay(alignment: .bottomTrailing) {
            if photo.isVideo {
                Label(photo.durationText, systemImage: "video.fill")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        // 勾选框独立成一个按钮：点图片是放大整理，点这里才是选中
        .overlay(alignment: .topTrailing) {
            Button(action: onToggleSelection) {
                selectionIndicator
                    .frame(width: 30, height: 30)
                    .padding(9)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 三元表达式的结果是 String 而非 LocalizedStringKey，不会自动查表，显式走 L10n
            .accessibilityLabel(L10n.text(photo.isVideo ? "选择视频" : "选择照片"))
            .accessibilityValue(L10n.text(isRecommended ? "推荐保留" : isSelected ? "已选中" : "未选中"))
        }
    }

    @ViewBuilder
    private var selectionIndicator: some View {
        if isSelected {
            ZStack {
                Circle()
                    .fill(Color.tidyAccent)
                Circle()
                    .stroke(Color.white, lineWidth: 2)
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    // 勾落在柠檬色圆点上，必须用深色
                    .foregroundStyle(Color.tidyOnAccent)
            }
        } else if isRecommended {
            Image(systemName: "star.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.tidyAmber)
                .background(Color.black.opacity(0.48), in: Circle())
        } else {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.18))
                Circle()
                    .stroke(Color.white, lineWidth: 2)
            }
        }
    }
}

/// 全屏整理的起始位置，包一层 Identifiable 方便直接绑定 fullScreenCover
private struct GroupReviewStart: Identifiable {
    let id: Int
}

/// 单组最多加载多少张照片。设置页可改，默认 300
enum PhotoListLimit {
    static let key = "tidyAlbum.photoListLimit"
    static let defaultValue = 300
    static let options = [100, 300, 500, 1000, 2000]

    static func label(_ value: Int) -> String {
        L10n.format("%@ 张", value.formatted())
    }
}

private struct SettingsView: View {
    let onShowOnboarding: () -> Void

    @EnvironmentObject private var purchaseStore: PurchaseStore
    @EnvironmentObject private var remoteConfig: RemoteConfigStore
    @EnvironmentObject private var photoLibrary: PhotoLibraryStore
    @AppStorage(PhotoListLimit.key) private var photoListLimit = PhotoListLimit.defaultValue
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system.rawValue
    @State private var showsPaywall = false
    @State private var showsOrganizeGuide = false
#if DEBUG
    @State private var showsStoreShowcase = false
    @State private var showsScanDebug = false
#endif

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return [version, build].compactMap { $0 }.joined(separator: " (") + (version != nil && build != nil ? ")" : "")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // 远程可关闭支付入口，用于审核或临时下架内购
                    if remoteConfig.config.purchase.paywallEnabled {
                        Button {
                            showsPaywall = true
                        } label: {
                            HStack(spacing: 12) {
                                Label(
                                    purchaseStore.membershipLabel,
                                    systemImage: purchaseStore.isPro ? "checkmark.seal.fill" : "sparkles"
                                )
                                .foregroundStyle(purchaseStore.isPro ? Color.tidyAccent : Color.tidyInk)
                                Spacer()
                                Text(L10n.text(purchaseStore.isPro ? "已解锁" : "查看方案"))
                                    .foregroundStyle(Color.tidyMuted)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Color.tidyMuted)
                            }
                        }
                    }

                    HStack {
                        Label("用户编号", systemImage: "person.crop.circle")
                        Spacer()
                        Text(purchaseStore.displayUserID)
                            .font(.caption.monospaced())
                            .foregroundStyle(Color.tidyMuted)
                    }

#if DEBUG
                    Button(role: .destructive) {
                        photoLibrary.resetQuotaLedger()
                    } label: {
                        Label("重置免费额度（调试）", systemImage: "arrow.counterclockwise.circle")
                    }
#endif
                } header: {
                    Text("Minus Pro")
                } footer: {
                    if remoteConfig.config.purchase.paywallEnabled {
                        Text(L10n.format("免费版可累计确认删除 %@。实际价格以 App Store 为准。", FreeQuota.summaryText))
                    } else {
                        Text("当前版本不限量开放全部整理能力。")
                    }
                }

                Section {
                    Picker(selection: $photoListLimit) {
                        ForEach(PhotoListLimit.options, id: \.self) { value in
                            Text(PhotoListLimit.label(value)).tag(value)
                        }
                    } label: {
                        Label("单组最多加载", systemImage: "square.stack.3d.down.right")
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("加载上限")
                } footer: {
                    Text("时间和相簿列表按当前类型筛选后，最多显示这么多项。照片和视频的缩略图按需加载；超出上限时列表顶部会说明。")
                }

                Section {
                    HStack {
                        Label("缓存占用", systemImage: "internaldrive")
                        Spacer()
                        if photoLibrary.isClearingCache {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(ByteSizeText.full(photoLibrary.cacheSizeBytes))
                                .foregroundStyle(Color.tidyMuted)
                                .contentTransition(.numericText())
                        }
                    }

                    Button(role: .destructive) {
                        Task { await photoLibrary.clearCache() }
                    } label: {
                        Label(
                            L10n.text(photoLibrary.isClearingCache ? "正在清理…" : "清理缓存"),
                            systemImage: "trash"
                        )
                    }
                    .disabled(photoLibrary.isClearingCache)
                } header: {
                    Text("缓存")
                } footer: {
                    Text("照片原图和缩略图由系统照片图库按需提供，不会保存副本。清理会删除搜索分析索引和其他可重新生成的缓存；下次搜索可能需要重新分析。整理记录和待删除列表不会受影响。")
                }

                Section {
                    Picker(selection: $appLanguage) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.titleKey).tag(language.rawValue)
                        }
                    } label: {
                        Label("App 语言", systemImage: "globe")
                    }
                    .pickerStyle(.menu)
                } footer: {
                    Text("默认跟随系统；也可以只为 Minus 选择语言。")
                }

                Section {
                    NavigationLink {
                        OrganizeControlsSettingsView()
                    } label: {
                        Label("整理页操作", systemImage: "hand.draw")
                    }
                } footer: {
                    Text("自定义整理页底部按钮从左到右的排列，以及上下左右四个滑动方向分别触发删除、保留、撤回、加入相簿还是留空。")
                }

                Section("整理偏好") {
                    Label("仅在设备上分析", systemImage: "lock.fill")
                    Label("保留原图和编辑记录", systemImage: "photo.on.rectangle")
                    Label("确认后才移入最近删除", systemImage: "checkmark.shield")
                }
                Section("使用帮助") {
                    Button {
                        showsOrganizeGuide = true
                    } label: {
                        Label("整理手势指引", systemImage: "hand.draw.fill")
                    }
                    Button(action: onShowOnboarding) {
                        Label("重新查看启动引导", systemImage: "sparkles.rectangle.stack")
                    }
                    // 反馈会话走后端工单，客服在管理台回复；有新回复时这一行显示红点
                    FeedbackEntryRow()
                }
#if DEBUG
                Section {
                    Button {
                        showsStoreShowcase = true
                    } label: {
                        Label("打开应用说明", systemImage: "iphone.gen3.radiowaves.left.and.right")
                    }
                } header: {
                    Text("商店截图")
                } footer: {
                    Text("共 5 张宣传页。进入后等待控件自动隐藏，再使用系统截图即可。")
                }

                Section {
                    Button {
                        showsScanDebug = true
                    } label: {
                        Label("打分引擎验证", systemImage: "sparkle.magnifyingglass")
                    }
                } header: {
                    Text("一键整理")
                } footer: {
                    Text("在真实相册上跑一遍打分引擎，逐张标记误判以统计各类判断的准确率。不会改动任何照片。")
                }
#endif
                Section("关于") {
                    HStack {
                        Text("Minus")
                        Spacer()
                        Text(versionText.isEmpty ? "—" : versionText)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await photoLibrary.refreshCacheSize()
            }
            .fullScreenCover(isPresented: $showsPaywall) {
                PaywallView(entryReason: "settings")
            }
            .sheet(isPresented: $showsOrganizeGuide) {
                OrganizeGuideView { showsOrganizeGuide = false }
            }
#if DEBUG
            .fullScreenCover(isPresented: $showsStoreShowcase) {
                StoreShowcaseView {
                    showsStoreShowcase = false
                }
            }
            .fullScreenCover(isPresented: $showsScanDebug) {
                TidyScanDebugView {
                    showsScanDebug = false
                }
            }
#endif
        }
    }
}

struct PhotoItem: Identifiable {
    let id: String
    /// 拍摄日期
    private let originalTitle: String
    /// 拍摄时间 + 类型
    private let originalDetail: String
    let pixelWidth: Int
    let pixelHeight: Int
    /// 0 表示还未知，需要时再按 assetIdentifier 异步读取
    var byteSize: Int64
    /// 由后台的存储信息回填；导入的照片本来就在本机
    var isInCloud = false
    let artwork: ArtworkKind
    var image: UIImage?
    let tag: String
    let assetIdentifier: String?
    /// 拍摄时间，按天或按月归档时用它排序
    let capturedAt: Date?
    let mediaType: PHAssetMediaType
    let duration: TimeInterval
    /// 通过系统选择器导入、但尚未获图库访问的影片使用本地副本播放。
    let localVideoURL: URL?
    let motionKind: MotionPhotoKind
    /// 未获得整个图库访问时，保留选择器导入的原始动图，不能只存首帧 UIImage。
    let animatedImageData: Data?

    var isVideo: Bool { mediaType == .video }
    var durationText: String { VideoDuration.text(duration) }

    var title: String {
        guard let capturedAt else { return L10n.text(originalTitle) }
        return L10n.date(capturedAt, template: "yMMMMd")
    }

    var detail: String {
        guard let capturedAt else {
            if isVideo { return L10n.format("视频 · %@", durationText) }
            return L10n.text(originalDetail)
        }
        let kind = isVideo
            ? L10n.format("视频 · %@", durationText)
            : L10n.text(tag == "相册照片" ? "照片" : tag)
        return L10n.format("%@ · %@", L10n.time(capturedAt), kind)
    }

    var resolutionText: String {
        guard pixelWidth > 0, pixelHeight > 0 else { return "—" }
        return "\(pixelWidth) × \(pixelHeight)"
    }

    var pixelArea: Int {
        pixelWidth * pixelHeight
    }

    /// aspectFit 后画面的真实宽高比；尺寸未知时返回 nil
    var displayAspectRatio: CGFloat? {
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        return CGFloat(pixelWidth) / CGFloat(pixelHeight)
    }

    init(
        title: String,
        detail: String,
        pixelWidth: Int,
        pixelHeight: Int,
        byteSize: Int64 = 0,
        artwork: ArtworkKind,
        image: UIImage? = nil,
        tag: String = "待整理",
        assetIdentifier: String? = nil,
        capturedAt: Date? = nil,
        mediaType: PHAssetMediaType = .image,
        duration: TimeInterval = 0,
        localVideoURL: URL? = nil,
        motionKind: MotionPhotoKind = .none,
        animatedImageData: Data? = nil
    ) {
        self.id = assetIdentifier ?? UUID().uuidString
        self.originalTitle = title
        self.originalDetail = detail
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteSize = byteSize
        self.artwork = artwork
        self.image = image
        self.tag = tag
        self.assetIdentifier = assetIdentifier
        self.capturedAt = capturedAt
        self.mediaType = mediaType
        self.duration = duration
        self.localVideoURL = localVideoURL
        self.motionKind = motionKind
        self.animatedImageData = animatedImageData
    }
}

enum ArtworkKind: CaseIterable {
    case bedroom
    case mountain
    case cafe
    case plant
    case city
    case food
    case screenshot
    case car
    case game
    case shipping
    case imported
}

enum PhotoGroupKind: Equatable {
    case screenshots
    case exactDuplicates
    case similar
    case bursts
    case blurry
    /// 按 PhotoKit 元数据划分的照片类型（实况、全景、HDR 等）
    case mediaKind

    /// 重复、相似、连拍这类方案要成组才有清理价值，只剩一张时应整组丢弃
    var minimumPhotoCount: Int {
        switch self {
        case .exactDuplicates, .similar, .bursts: 2
        case .screenshots, .blurry, .mediaKind: 1
        }
    }
}

struct PhotoGroup: Identifiable {
    let id = UUID()
    let title: String
    let groupCount: Int
    let photoCount: Int
    let symbol: String
    let tint: Color
    let kind: PhotoGroupKind
    var photos: [PhotoItem]

    /// 分组占用空间，逐张累加；照片大小尚未回填时为 0
    var byteSize: Int64 {
        photos.reduce(0) { $0 + $1.byteSize }
    }

    var hasCloudPhotos: Bool {
        photos.contains { $0.isInCloud }
    }

    /// 打开通用图片列表时的标题
    var listTitle: String {
        if kind == .exactDuplicates {
            return L10n.format("完全相同 · %@ 张", photoCount.formatted())
        }
        let unit = photos.allSatisfy(\.isVideo) ? L10n.text("段") : L10n.text("项")
        return "\(L10n.text(title)) \(photoCount.formatted()) \(unit)"
    }

    init(
        title: String,
        groupCount: Int,
        photoCount: Int,
        symbol: String,
        tint: Color,
        kind: PhotoGroupKind = .similar,
        photos: [PhotoItem]
    ) {
        self.title = title
        self.groupCount = groupCount
        self.photoCount = photoCount
        self.symbol = symbol
        self.tint = tint
        self.kind = kind
        self.photos = photos
    }
}

/// 石墨主题：深底 + 电光柠檬。非 private，让 store 也能用同一套分类色
extension Color {
    /// 页面底色
    static let tidyBackground = Color(red: 0.067, green: 0.071, blue: 0.086)
    /// 卡片底色
    static let tidySurface = Color(red: 0.106, green: 0.114, blue: 0.133)
    /// 卡片之上再抬一层，用于选中态和次级色块
    static let tidyElevated = Color(red: 0.145, green: 0.157, blue: 0.180)
    /// 主文字
    static let tidyInk = Color(red: 0.945, green: 0.949, blue: 0.957)
    /// 次要文字
    static let tidyMuted = Color(red: 0.533, green: 0.557, blue: 0.596)
    /// 描边与分隔线
    static let tidyHairline = Color(red: 0.165, green: 0.176, blue: 0.204)
    /// 品牌主色
    static let tidyAccent = Color(red: 0.769, green: 0.937, blue: 0.290)
    /// 落在主色等亮色块上的文字，必须是深色
    static let tidyOnAccent = Color(red: 0.078, green: 0.082, blue: 0.098)
    /// 保留
    static let tidyKeep = Color(red: 0.482, green: 0.851, blue: 0.341)
    /// 删除
    static let tidyDanger = Color(red: 1.0, green: 0.353, blue: 0.373)
    /// 以下为分类辅助色，亮度都按深底调过
    static let tidyCyan = Color(red: 0.310, green: 0.847, blue: 0.910)
    static let tidyAmber = Color(red: 0.961, green: 0.698, blue: 0.239)
    static let tidyViolet = Color(red: 0.663, green: 0.545, blue: 1.0)
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(PurchaseStore())
            .environmentObject(RemoteConfigStore())
    }
}

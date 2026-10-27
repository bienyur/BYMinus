import Combine
import CryptoKit
import Photos
import SwiftUI
import UIKit
import Vision

/// 用户自己建的相簿。系统智能相簿不能增删照片，所以不收进来
struct PhotoAlbum: Identifiable, Equatable {
    let id: String
    let title: String
    let count: Int
}

/// 按天或按月归档的一批照片。只存标识符，点开某一组时才真正加载缩略图
struct TimeBucket: Identifiable, Equatable {
    let id: String
    /// 带年份的完整名字，用作图片列表的标题
    let label: String
    /// 上级已经交代了年月，列表行里只显示这一段
    let shortLabel: String
    let count: Int
    let assetIdentifiers: [String]
    /// 上一级的分桶键：天挂在月下面，月挂在年下面
    let parentID: String?

    /// 方块封面取这一组里最新的那张
    var coverIdentifier: String? { assetIdentifiers.first }
}

/// 归档时的中间态。资产是按拍摄时间倒序取出的，所以 key 首次出现的顺序就是从新到旧
private struct BucketAccumulator {
    private var order: [String] = []
    private var labels: [String: (full: String, short: String)] = [:]
    private var parents: [String: String?] = [:]
    private var identifiers: [String: [String]] = [:]

    mutating func add(
        _ identifier: String,
        key: String,
        parentID: String?,
        makeLabels: () -> (String, String)
    ) {
        if identifiers[key] == nil {
            order.append(key)
            labels[key] = makeLabels()
            parents[key] = parentID
        }
        identifiers[key, default: []].append(identifier)
    }

    var buckets: [TimeBucket] {
        order.compactMap { key in
            guard let ids = identifiers[key], let label = labels[key] else { return nil }
            return TimeBucket(
                id: key,
                label: label.full,
                shortLabel: label.short,
                count: ids.count,
                assetIdentifiers: ids,
                parentID: parents[key] ?? nil
            )
        }
    }
}

enum ReleasedMediaKind: String, CaseIterable, Identifiable {
    case photo
    case video
    case motion
    case other

    var id: Self { self }
}

/// 某个自然月里通过确认删除释放掉的空间，按媒体类型保留明细。
struct MonthlyRelease: Identifiable, Equatable {
    let id: String
    let label: String
    let deletedCount: Int
    let photoBytes: Int64
    let videoBytes: Int64
    let motionBytes: Int64
    /// 升级前只保存了总数的历史记录，以及以后无法识别的媒体类型。
    let otherBytes: Int64

    var bytes: Int64 { photoBytes + videoBytes + motionBytes + otherBytes }

    func bytes(for kind: ReleasedMediaKind) -> Int64 {
        switch kind {
        case .photo: photoBytes
        case .video: videoBytes
        case .motion: motionBytes
        case .other: otherBytes
        }
    }
}

struct PhotoSearchProgress: Equatable {
    let completed: Int
    let total: Int

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(completed) / Double(total), 0), 1)
    }
}

enum PhotoSearchScopeMode: String, CaseIterable, Identifiable, Sendable {
    case recent
    case years

    var id: Self { self }
}

struct PhotoSearchScope: Equatable, Sendable {
    var mode: PhotoSearchScopeMode = .recent
    var recentLimit = 1_000
    var startYear = Calendar.current.component(.year, from: Date())
    var endYear = Calendar.current.component(.year, from: Date())
}

private struct PhotoSearchIndexEntry: Codable, Sendable {
    var modificationTime: TimeInterval? = nil
    var labels: Set<String> = []
    var didClassify = false
    var didInspectDocument = false
}

private struct PhotoSearchImageInput: @unchecked Sendable {
    let cgImage: CGImage
}

private struct PhotoSearchJob: Sendable {
    let order: Int
    let identifier: String
    let modificationTime: TimeInterval?
    let shouldClassify: Bool
    let shouldInspectDocument: Bool
}

private struct PhotoSearchAnalysisOutcome: Sendable {
    let job: PhotoSearchJob
    let analysis: PhotoSemanticSearchAnalyzer.Result?
}

private struct ReleaseBreakdown {
    var photo = 0
    var video = 0
    var motion = 0
    var other = 0

    var total: Int { photo + video + motion + other }
}

struct AssetStorageInfo: Equatable {
    let byteSize: Int64
    /// 原图不在本机，需要从 iCloud 下载
    let isInCloud: Bool
}

enum AssetStorage {
    /// 文件大小和本机可用性都不是 PHAssetResource 的公开属性，只能用 KVC 读
    static func info(of asset: PHAsset) -> AssetStorageInfo {
        let resources = PHAssetResource.assetResources(for: asset)

        let resourceSize = resources
            .compactMap { ($0.value(forKey: "fileSize") as? NSNumber)?.int64Value }
            .max()

        // 读不到 locallyAvailable 时按本机处理，最多是少显示一个云端标识
        let hasLocalResource = resources.contains { resource in
            (resource.value(forKey: "locallyAvailable") as? NSNumber)?.boolValue ?? true
        }

        return AssetStorageInfo(
            // 视频大小不能按单张图片的像素面积估算；读不到时保留“未知”。
            byteSize: resourceSize ?? (asset.mediaType == .video ? 0 : Int64(Double(asset.pixelWidth * asset.pixelHeight) * 0.25)),
            isInCloud: !resources.isEmpty && !hasLocalResource
        )
    }

    /// 资源查询是同步的，批量调用会卡主线程，所以按需在后台取单张
    static func info(forAssetIdentifier identifier: String) async -> AssetStorageInfo? {
        await Task.detached(priority: .userInitiated) {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
            guard let asset = assets.firstObject else { return nil }
            return info(of: asset)
        }.value
    }

    /// 整批放到后台一次算完，避免上千次同步资源查询堆在主线程上
    static func infos(forAssetIdentifiers identifiers: [String]) async -> [String: AssetStorageInfo] {
        guard !identifiers.isEmpty else { return [:] }

        return await Task.detached(priority: .utility) {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            var result: [String: AssetStorageInfo] = [:]
            result.reserveCapacity(assets.count)
            assets.enumerateObjects { asset, _, _ in
                result[asset.localIdentifier] = info(of: asset)
            }
            return result
        }.value
    }
}

enum ByteSizeText {
    /// 柱状图标签用，每根柱子横向只有 40pt 左右，必须尽量短
    static func compact(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0" }

        let kilobytes = Double(bytes) / 1_024
        if kilobytes < 1_024 {
            return String(format: "%.0fK", max(kilobytes, 1))
        }

        let megabytes = kilobytes / 1_024
        if megabytes < 1_024 {
            return String(format: megabytes < 10 ? "%.1fM" : "%.0fM", megabytes)
        }

        return String(format: "%.1fG", megabytes / 1_024)
    }

    /// 卡片正文用的完整体积文案
    static func full(_ bytes: Int64) -> String {
        let kilobytes = Double(bytes) / 1_024
        if kilobytes < 1_024 {
            return String(format: "%.0f KB", kilobytes.rounded())
        }

        let megabytes = kilobytes / 1_024
        if megabytes < 1_024 {
            return String(format: "%.1f MB", megabytes)
        }

        return String(format: "%.2f GB", megabytes / 1_024)
    }
}

@MainActor
final class PhotoLibraryStore: ObservableObject {
    @Published private(set) var authorization: PHAuthorizationStatus = .notDetermined
    @Published private(set) var photos: [PhotoItem] = []
    @Published private(set) var homeCollections: [PhotoCollectionPreview] = []
    @Published private(set) var pendingPhotos: [PhotoItem] = []
    @Published private(set) var groups: [PhotoGroup] = []
    @Published private(set) var dailyBuckets: [TimeBucket] = []
    @Published private(set) var monthlyBuckets: [TimeBucket] = []
    @Published private(set) var yearBuckets: [TimeBucket] = []
    @Published private(set) var albums: [PhotoAlbum] = []
    @Published private(set) var monthlyReleases: [MonthlyRelease] = []
    @Published private(set) var totalReleasedBytes: Int64 = 0
    @Published private(set) var currentMonthAddedCount = 0
    @Published private(set) var libraryCount = 0
    @Published private(set) var searchablePhotoCount = 0
    @Published private(set) var reviewedCount = 0
    @Published private(set) var resumeReviewedCount = 0
    @Published private(set) var resumeRemainingCount = 0
    @Published private(set) var keptCount = 0
    @Published private(set) var pendingCount = 0
    @Published private(set) var deletedCount = 0
    /// 免费额度账本：与展示用的 deletedCount / totalReleasedBytes 分开维护。
    /// 刻意只存在本地 UserDefaults，卸载重装即归零，额度随之恢复。
    @Published private(set) var quotaDeletedCount = 0
    @Published private(set) var quotaReleasedBytes: Int64 = 0
    @Published private(set) var hasClaimedReviewReward = false
    @Published private(set) var isLoading = false
    @Published private(set) var isScanning = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var isSearchingPhotos = false
    @Published private(set) var photoSearchProgress: PhotoSearchProgress?
    @Published private(set) var photoSearchLiveResults: [PhotoItem] = []
    @Published private(set) var cacheSizeBytes: Int64 = 0
    @Published private(set) var isClearingCache = false

    private let imageManager = PHCachingImageManager()
    private let defaults = UserDefaults.standard
    private let batchSize = 120
    /// 封面从合集最前面这么多张里随机挑，免得每次打开都是同一张
    private let coverCandidateLimit = 8
    /// 最近一周少于这个数就把范围放宽到一个月，卡片上不至于只有两三张
    private let recentWideningThreshold = 6
    /// 回忆类合集往前找几年
    private let flashbackYearSpan = 6
    /// 点合集进整理页时最多建多少条队列，几千条元数据一次性建出来没必要
    private let collectionQueueLimit = 300
    private let scanSampleSize = 600
    private let keptKey = "tidyAlbum.keptAssetIdentifiers"
    private let pendingKey = "tidyAlbum.pendingAssetIdentifiers"
    private let deletedCountKey = "tidyAlbum.deletedAssetCount"
    private let releasedBytesKey = "tidyAlbum.releasedBytesByMonth"
    private let releasedBreakdownKey = "tidyAlbum.releasedBytesByMonthAndType"
    private let releasedCountKey = "tidyAlbum.deletedCountByMonth"
    private let quotaDeletedCountKey = "tidyAlbum.quota.deletedCount"
    private let quotaReleasedBytesKey = "tidyAlbum.quota.releasedBytes"
    private let reviewRewardClaimedKey = "tidyAlbum.quota.reviewRewardClaimed"

    private var keptIdentifiers: Set<String> = []
    private var pendingIdentifiers: Set<String> = []
    private var systemGroups: [PhotoGroup] = []
    private var photoSearchIndex: [String: PhotoSearchIndexEntry] = [:]
    private var hasLoadedPhotoSearchIndex = false
    /// 月份 key -> 该月累计释放的字节数
    private var releasedBytesByMonth: [String: Int] = [:]
    private var releasedBreakdownByMonth: [String: [String: Int]] = [:]
    private var releasedCountByMonth: [String: Int] = [:]

    var isAuthorized: Bool {
        authorization == .authorized || authorization == .limited
    }

    var isAccessDenied: Bool {
        authorization == .denied || authorization == .restricted
    }

    var progressTotalCount: Int {
        libraryCount + deletedCount
    }

    var quotaDeletionLimit: Int {
        FreeQuota.deletionCount
            + (hasClaimedReviewReward ? FreeQuota.reviewRewardDeletionCount : 0)
    }

    var quotaReleasedBytesLimit: Int64 {
        FreeQuota.releasedBytes
            + (hasClaimedReviewReward ? FreeQuota.reviewRewardReleasedBytes : 0)
    }

    func load(scanAfterLoading: Bool = true) async {
        guard !isLoading else { return }
        isLoading = true
        hasLoaded = false

        // 首次权限由首页按钮主动发起，不在应用启动时突然弹出。
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)

        // 清理记录只依赖本地存档，未授权时也要能显示历史战绩
        restoreDecisionState()
        updateReleaseStats()

        guard isAuthorized else {
            photos = []
            homeCollections = []
            pendingPhotos = []
            groups = []
            dailyBuckets = []
            monthlyBuckets = []
            yearBuckets = []
            albums = []
            currentMonthAddedCount = 0
            libraryCount = 0
            searchablePhotoCount = 0
            updateProgressCounts()
            resumeRemainingCount = 0
            resumeReviewedCount = 0
            isLoading = false
            hasLoaded = true
            return
        }

        let allAssets = PHAsset.fetchAssets(with: mediaFetchOptions())
        libraryCount = allAssets.count
        homeCollections = makeHomeCollections()
        searchablePhotoCount = PHAsset.fetchAssets(with: .image, options: nil).count
        let validIdentifiers = identifiers(in: allAssets)
        keptIdentifiers.formIntersection(validIdentifiers)
        pendingIdentifiers.formIntersection(validIdentifiers)
        persistDecisionState()
        updateProgressCounts()
        resumeRemainingCount = max(progressTotalCount - reviewedCount, 0)
        resumeReviewedCount = reviewedCount

        // 首屏只需要当前整理队列，先发布它；月份、分组和待删除数据随后补齐。
        await loadNextBatch()

        currentMonthAddedCount = countAddedInCurrentMonth(from: allAssets)
        rebuildTimeBuckets(from: allAssets)
        let pendingAssets = PHAsset.fetchAssets(
            withLocalIdentifiers: Array(pendingIdentifiers),
            options: sortedFetchOptions()
        )
        // 待删除页由单元格按需取图；启动时只建元数据，不能串行等待数百张缩略图。
        pendingPhotos = (0..<min(pendingAssets.count, 300)).map {
            makePhotoItem(asset: pendingAssets.object(at: $0), image: nil)
        }
        systemGroups = makeSystemGroups(from: allAssets)
        groups = systemGroups
        await loadAlbums()

        isLoading = false
        hasLoaded = true

        // Vision 扫描较慢，放在最后，让界面先可用
        if scanAfterLoading { await scanLibraryGroups() }
    }

    /// 语言切换时只重建轻量的日期和月度文案，不重新读取缩略图或执行 Vision 扫描。
    func refreshLocalizedContent() {
        guard isAuthorized else { return }
        let allAssets = PHAsset.fetchAssets(with: mediaFetchOptions())
        homeCollections = makeHomeCollections()
        rebuildTimeBuckets(from: allAssets)
        updateReleaseStats()
    }

    /// 用户点击连接相册后再请求权限，授权完成立即加载真实图库。
    func requestAccess() async {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        authorization = currentStatus == .notDetermined
            ? await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            : currentStatus
        await load()
    }

    /// 滑动整理用的队列只先装元数据，大图由当前卡片自己按需读取。
    /// 返回这次可用的照片数，整理页用它判断整个图库是否已处理完。
    @discardableResult
    func loadNextBatch() async -> Int {
        guard isAuthorized else { return 0 }
        let managesLoadingState = !isLoading
        if managesLoadingState { isLoading = true }

        let allAssets = PHAsset.fetchAssets(with: mediaFetchOptions())
        var assetsToLoad: [PHAsset] = []
        assetsToLoad.reserveCapacity(batchSize)

        allAssets.enumerateObjects { asset, _, stop in
            let identifier = asset.localIdentifier
            guard !self.keptIdentifiers.contains(identifier),
                  !self.pendingIdentifiers.contains(identifier) else { return }
            assetsToLoad.append(asset)
            if assetsToLoad.count == self.batchSize {
                stop.pointee = true
            }
        }

        // 不在这里串行下载 120 张缩略图；ArtworkView / FullScreenArtwork
        // 会对屏幕上真正可见的照片按需加载，因此续批可以瞬时完成。
        let decidedIdentifiers = keptIdentifiers.union(pendingIdentifiers)
        photos = assetsToLoad
            .filter { !decidedIdentifiers.contains($0.localIdentifier) }
            .map { makePhotoItem(asset: $0, image: nil) }
        if managesLoadingState { isLoading = false }
        return photos.count
    }

    /// 只读元数据把整个图库按天、按月、按年归档：这一步不取图，所以几千张也能秒出
    private func rebuildTimeBuckets(from assets: PHFetchResult<PHAsset>) {
        var days = BucketAccumulator()
        var months = BucketAccumulator()
        var years = BucketAccumulator()

        assets.enumerateObjects { asset, _, _ in
            guard let date = asset.creationDate else { return }
            let identifier = asset.localIdentifier
            let monthID = self.monthKey(for: date)
            let yearID = self.yearKey(for: date)

            days.add(identifier, key: Self.dayKeyFormatter.string(from: date), parentID: monthID) {
                (
                    L10n.date(date, template: "yMMMMd"),
                    L10n.date(date, template: "MMMd")
                )
            }
            months.add(identifier, key: monthID, parentID: yearID) {
                (
                    // 用缩写月名：左侧列宽固定，英文的 "September 2026" 放不下会被截断，
                    // 换成 "Sep 2026" 刚好；中文的 yMMM 与 yMMMM 同为「2026年9月」，显示不变。
                    L10n.date(date, template: "yMMM"),
                    L10n.date(date, template: "MMM")
                )
            }
            years.add(identifier, key: yearID, parentID: nil) {
                let label = L10n.date(date, template: "y")
                return (label, label)
            }
        }

        dailyBuckets = days.buckets
        monthlyBuckets = months.buckets
        yearBuckets = years.buckets
    }

    /// 列表持有全量轻量元数据，缩略图由可见单元按需读取，显示上限在类型筛选之后应用。
    func loadPhotos(forBucket bucket: TimeBucket) async -> [PhotoItem] {
        guard isAuthorized else { return [] }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: bucket.assetIdentifiers, options: mediaFetchOptions())
        return (0..<assets.count).map { makePhotoItem(asset: assets.object(at: $0), image: nil) }
    }

    /// 相簿列表。只取用户自己建的：系统智能相簿（最近项目、个人收藏等）不允许增删照片
    func loadAlbums() async {
        guard isAuthorized else {
            albums = []
            return
        }

        let collections = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: nil
        )

        var result: [PhotoAlbum] = []
        collections.enumerateObjects { collection, _, _ in
            let count = PHAsset.fetchAssets(in: collection, options: self.mediaFetchOptions()).count
            result.append(
                PhotoAlbum(
                    id: collection.localIdentifier,
                    title: collection.localizedTitle ?? L10n.text("未命名相簿"),
                    count: count
                )
            )
        }
        albums = result.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// 与时间分组一致，先读取元数据，图片按可见区域加载。
    func loadPhotos(forAlbum album: PhotoAlbum) async -> [PhotoItem] {
        guard isAuthorized,
              let collection = fetchCollection(with: album.id) else { return [] }

        let assets = PHAsset.fetchAssets(in: collection, options: mediaFetchOptions())
        return (0..<assets.count).map { makePhotoItem(asset: assets.object(at: $0), image: nil) }
    }

    /// 把照片加进相簿。相簿里已经有这张时直接算成功，不重复添加
    func addPhoto(_ photo: PhotoItem, to album: PhotoAlbum) async -> Bool {
        guard let identifier = photo.assetIdentifier,
              let collection = fetchCollection(with: album.id),
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
        else { return false }

        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localIdentifier = %@", identifier)
        if PHAsset.fetchAssets(in: collection, options: options).count > 0 {
            return true
        }

        let success = await performLibraryChanges {
            PHAssetCollectionChangeRequest(for: collection)?.addAssets([asset] as NSArray)
        }
        if success { await loadAlbums() }
        return success
    }

    /// 新建相簿，可以顺手把一张照片放进去
    func createAlbum(named name: String, initialPhoto: PhotoItem? = nil) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAuthorized, !trimmed.isEmpty else { return false }

        var asset: PHAsset?
        if let identifier = initialPhoto?.assetIdentifier {
            asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
        }

        let success = await performLibraryChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: trimmed)
            if let asset {
                request.addAssets([asset] as NSArray)
            }
        }
        if success { await loadAlbums() }
        return success
    }

    /// 删除相簿本身，里面的照片仍然留在图库里
    func deleteAlbum(_ album: PhotoAlbum) async -> Bool {
        guard let collection = fetchCollection(with: album.id) else { return false }

        let success = await performLibraryChanges {
            PHAssetCollectionChangeRequest.deleteAssetCollections([collection] as NSArray)
        }
        if success { await loadAlbums() }
        return success
    }

    private func fetchCollection(with identifier: String) -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [identifier],
            options: nil
        ).firstObject
    }

    /// 首页轮播的几个合集。数组顺序就是轮播顺序：先看最近的，
    /// 再穿插回忆类和几种最容易清理的类型，相邻两张不会是同一路的东西。
    /// “往年今日”已去掉：按天筛出来的照片太少，单独占一个分类意义不大。
    private func makeHomeCollections() -> [PhotoCollectionPreview] {
        guard isAuthorized else { return [] }

        return [
            recentPreview(),
            makePreview(for: .screenshots),
            flashbackPreview(makeKind: PhotoCollectionKind.monthYearsAgo(yearsAgo:)),
            makePreview(for: .videos),
            makePreview(for: .livePhotos),
            makePreview(for: .selfies)
        ].compactMap { $0 }
    }

    /// 最近一周太少就放宽到一个月
    private func recentPreview() -> PhotoCollectionPreview? {
        if let week = makePreview(for: .recentlyAdded(days: 7)), week.count >= recentWideningThreshold {
            return week
        }
        return makePreview(for: .recentlyAdded(days: 30))
    }

    /// 回忆类合集：往前找几年，在还留着照片的年份里随机挑一年，
    /// 所以这张卡可能是去年的，也可能是前年的。
    private func flashbackPreview(makeKind: (Int) -> PhotoCollectionKind) -> PhotoCollectionPreview? {
        (1...flashbackYearSpan)
            .compactMap { makePreview(for: makeKind($0)) }
            .randomElement()
    }

    /// 一次遍历同时数出还没整理的数量、并留下前几张做封面候选。
    /// 数量只算没做过决定的，点进去的队列才和卡片上写的数对得上。
    private func makePreview(for kind: PhotoCollectionKind) -> PhotoCollectionPreview? {
        guard let assets = kind.fetchAssets(), assets.count > 0 else { return nil }

        let decidedIdentifiers = keptIdentifiers.union(pendingIdentifiers)
        var remainingCount = 0
        var coverCandidates: [PHAsset] = []

        assets.enumerateObjects { asset, _, _ in
            guard !decidedIdentifiers.contains(asset.localIdentifier) else { return }
            remainingCount += 1
            if coverCandidates.count < self.coverCandidateLimit {
                coverCandidates.append(asset)
            }
        }

        guard remainingCount >= kind.minimumCount,
              let cover = coverCandidates.randomElement() else { return nil }

        return PhotoCollectionPreview(
            kind: kind,
            cover: makePhotoItem(asset: cover, image: nil),
            count: remainingCount
        )
    }

    /// 点了首页某个合集：取它还没整理的照片当整理队列
    func photos(in kind: PhotoCollectionKind) -> [PhotoItem] {
        guard let assets = kind.fetchAssets() else { return [] }

        let decidedIdentifiers = keptIdentifiers.union(pendingIdentifiers)
        var result: [PhotoItem] = []
        assets.enumerateObjects { asset, _, stop in
            guard !decidedIdentifiers.contains(asset.localIdentifier) else { return }
            result.append(self.makePhotoItem(asset: asset, image: nil))
            if result.count == self.collectionQueueLimit { stop.pointee = true }
        }
        return result
    }

    private func mediaFetchOptions() -> PHFetchOptions {
        let options = sortedFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType IN %@",
            [PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue]
        )
        return options
    }

    /// 系统选择器选中的资产优先使用原始标识符，视频无需整段下载即可加入整理队列。
    func item(forAssetIdentifier identifier: String) -> PhotoItem? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
              asset.mediaType == .image || asset.mediaType == .video else { return nil }
        return makePhotoItem(asset: asset, image: nil)
    }

    /// 使用 Vision 在本机建立分类索引。PhotoKit 不提供系统“照片”App 的语义搜索结果，
    /// 所以这里只保存资产标识符和类别标签，不保存图片或证件 OCR 原文。
    func searchPhotos(matching rawQuery: String, scope: PhotoSearchScope) async -> [PhotoItem] {
        let query = PhotoSearchVocabulary.normalized(rawQuery)
        guard isAuthorized, !query.isEmpty else { return [] }

        isSearchingPhotos = true
        defer {
            isSearchingPhotos = false
            photoSearchProgress = nil
        }

        await loadPhotoSearchIndexIfNeeded()

        let options = sortedFetchOptions()
        switch scope.mode {
        case .recent:
            options.fetchLimit = max(scope.recentLimit, 1)
        case .years:
            let calendar = Calendar.current
            if let startDate = calendar.date(
                from: DateComponents(year: min(scope.startYear, scope.endYear), month: 1, day: 1)
            ), let endDate = calendar.date(
                from: DateComponents(year: max(scope.startYear, scope.endYear) + 1, month: 1, day: 1)
            ) {
                options.predicate = NSPredicate(
                    format: "creationDate >= %@ AND creationDate < %@",
                    startDate as NSDate,
                    endDate as NSDate
                )
            }
        }
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        let total = assets.count
        let terms = PhotoSearchVocabulary.terms(for: query)
        let needsDocumentAnalysis = PhotoSearchVocabulary.needsDocumentAnalysis(query)
        let needsClassification = !PhotoSearchVocabulary.isMetadataOnly(query)
        var matchedPhotos: [Int: PhotoItem] = [:]
        var jobs: [PhotoSearchJob] = []
        jobs.reserveCapacity(total)
        var didChangeIndex = false

        photoSearchLiveResults = []
        photoSearchProgress = PhotoSearchProgress(completed: 0, total: total)

        for index in 0..<total {
            guard !Task.isCancelled else { break }

            let asset = assets.object(at: index)
            let identifier = asset.localIdentifier
            var entry = photoSearchIndex[identifier] ?? PhotoSearchIndexEntry()
            let modificationTime = asset.modificationDate?.timeIntervalSinceReferenceDate
            if entry.modificationTime != modificationTime {
                entry = PhotoSearchIndexEntry(modificationTime: modificationTime)
                didChangeIndex = true
            }
            let previousLabelCount = entry.labels.count

            if asset.mediaSubtypes.contains(.photoScreenshot) {
                entry.labels.formUnion(["screenshot", "screen capture"])
            }

            if entry.labels.count != previousLabelCount {
                didChangeIndex = true
            }

            photoSearchIndex[identifier] = entry

            let shouldClassify = needsClassification && !entry.didClassify
            let shouldInspectDocument = needsDocumentAnalysis && !entry.didInspectDocument
            if shouldClassify || shouldInspectDocument {
                jobs.append(
                    PhotoSearchJob(
                        order: index,
                        identifier: identifier,
                        modificationTime: modificationTime,
                        shouldClassify: shouldClassify,
                        shouldInspectDocument: shouldInspectDocument
                    )
                )
                continue
            }

            if PhotoSearchVocabulary.matches(labels: entry.labels, terms: terms) {
                matchedPhotos[index] = makePhotoItem(asset: asset, image: nil)
            }
        }

        var completed = total - jobs.count
        photoSearchProgress = PhotoSearchProgress(completed: completed, total: total)
        photoSearchLiveResults = matchedPhotos.keys.sorted().compactMap { matchedPhotos[$0] }

        // Vision 分类本身较重；并行数跟随设备核心数但封顶为 6，避免大图库搜索时内存突增。
        let parallelism = min(max(ProcessInfo.processInfo.activeProcessorCount / 2, 2), 6)
        for batchStart in stride(from: 0, to: jobs.count, by: parallelism) {
            guard !Task.isCancelled else { break }
            let batchEnd = min(batchStart + parallelism, jobs.count)
            let batch = Array(jobs[batchStart..<batchEnd])
            let targetDimension: CGFloat = needsDocumentAnalysis ? 768 : 256

            let outcomes = await withTaskGroup(
                of: PhotoSearchAnalysisOutcome.self,
                returning: [PhotoSearchAnalysisOutcome].self
            ) { group in
                for job in batch {
                    group.addTask {
                        await PhotoSearchWorker.analyze(job, targetDimension: targetDimension)
                    }
                }

                var values: [PhotoSearchAnalysisOutcome] = []
                values.reserveCapacity(batch.count)
                for await outcome in group { values.append(outcome) }
                return values
            }

            for outcome in outcomes {
                completed += 1
                guard let analysis = outcome.analysis else { continue }

                let job = outcome.job
                var entry = photoSearchIndex[job.identifier]
                    ?? PhotoSearchIndexEntry(modificationTime: job.modificationTime)
                entry.labels.formUnion(analysis.labels)
                if job.shouldClassify { entry.didClassify = analysis.didClassify }
                if job.shouldInspectDocument { entry.didInspectDocument = analysis.didInspectDocument }
                photoSearchIndex[job.identifier] = entry
                didChangeIndex = true

                if PhotoSearchVocabulary.matches(labels: entry.labels, terms: terms) {
                    let asset = assets.object(at: job.order)
                    matchedPhotos[job.order] = makePhotoItem(asset: asset, image: nil)
                }
            }

            photoSearchProgress = PhotoSearchProgress(completed: completed, total: total)
            photoSearchLiveResults = matchedPhotos.keys.sorted().compactMap { matchedPhotos[$0] }
        }

        if didChangeIndex { await persistPhotoSearchIndex() }
        return matchedPhotos.keys.sorted().compactMap { matchedPhotos[$0] }
    }

    private var photoSearchIndexURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("photo-search-index-v1.json")
    }

    func refreshCacheSize() async {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheSizeBytes = await Task.detached(priority: .utility) {
            Self.directorySize(at: directory)
        }.value
    }

    func clearCache() async {
        guard !isClearingCache else { return }
        isClearingCache = true

        photoSearchIndex = [:]
        hasLoadedPhotoSearchIndex = true
        imageManager.stopCachingImagesForAllAssets()
        URLCache.shared.removeAllCachedResponses()

        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let contents = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )) ?? []
            for url in contents {
                try? fileManager.removeItem(at: url)
            }
        }.value

        await refreshCacheSize()
        isClearingCache = false
    }

    private nonisolated static func directorySize(at directory: URL) -> Int64 {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: nil
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    private func loadPhotoSearchIndexIfNeeded() async {
        guard !hasLoadedPhotoSearchIndex else { return }
        hasLoadedPhotoSearchIndex = true
        let url = photoSearchIndexURL
        photoSearchIndex = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url),
                  let index = try? JSONDecoder().decode([String: PhotoSearchIndexEntry].self, from: data) else {
                return [:]
            }
            return index
        }.value
    }

    private func persistPhotoSearchIndex() async {
        let snapshot = photoSearchIndex
        let url = photoSearchIndexURL
        await Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }.value
    }

    private func performLibraryChanges(_ changes: @escaping () -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges(changes) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    /// 分组扫描必须独立于滑动批次：滑动一次只加载 120 张，拿它做分组会漏掉绝大部分照片
    func scanLibraryGroups() async {
        guard isAuthorized, !isScanning else { return }
        isScanning = true

        let candidates = await loadScanCandidates(from: assetsForScan(limit: scanSampleSize))
        let visionGroups = await VisionGroupDetector.detect(from: candidates)
        groups = systemGroups + visionGroups
        isScanning = false

        await annotateGroupStorage()
    }

    /// 体积和云端状态要逐张查资源，放到后台一次算完再回填，界面上先显示张数
    private func annotateGroupStorage() async {
        let identifiers = Array(Set(groups.flatMap { $0.photos.compactMap(\.assetIdentifier) }))
        let infos = await AssetStorage.infos(forAssetIdentifiers: identifiers)
        guard !infos.isEmpty else { return }

        groups = groups.map { group in
            var updated = group
            updated.photos = group.photos.map { photo in
                guard let identifier = photo.assetIdentifier,
                      let info = infos[identifier] else { return photo }
                var item = photo
                item.byteSize = info.byteSize
                item.isInCloud = info.isInCloud
                return item
            }
            return updated
        }
    }

    func recordDecision(for photo: PhotoItem, delete: Bool) {
        guard let identifier = photo.assetIdentifier else { return }

        if delete {
            keptIdentifiers.remove(identifier)
            pendingIdentifiers.insert(identifier)
            if !pendingPhotos.contains(where: { $0.assetIdentifier == identifier }) {
                pendingPhotos.insert(photo, at: 0)
            }
        } else {
            pendingIdentifiers.remove(identifier)
            keptIdentifiers.insert(identifier)
            pendingPhotos.removeAll { $0.assetIdentifier == identifier }
        }

        persistDecisionState()
        updateProgressCounts()
    }

    func isReviewed(_ photo: PhotoItem) -> Bool {
        guard let identifier = photo.assetIdentifier else { return false }
        return keptIdentifiers.contains(identifier) || pendingIdentifiers.contains(identifier)
    }

    /// 从分组方案里批量加入待删除：记录决定的同时同步清理分组，避免返回列表后残留已处理完的方案
    func stageForDeletion(photos: [PhotoItem]) {
        photos.forEach { recordDecision(for: $0, delete: true) }
        pruneGroups(removingIdentifiers: Set(photos.compactMap(\.assetIdentifier)))
    }

    func undoDecision(for photo: PhotoItem) {
        guard let identifier = photo.assetIdentifier else { return }
        keptIdentifiers.remove(identifier)
        pendingIdentifiers.remove(identifier)
        pendingPhotos.removeAll { $0.assetIdentifier == identifier }
        persistDecisionState()
        updateProgressCounts()
    }

    func delete(photos: [PhotoItem], completion: @escaping (Bool) -> Void) {
        let identifiers = photos.compactMap(\.assetIdentifier)
        guard !identifiers.isEmpty else {
            completion(true)
            return
        }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        guard assets.count > 0 else {
            completion(true)
            return
        }

        let assetArray = (0..<assets.count).map { assets.object(at: $0) }
        // 必须在真正删除前统计，删掉之后就读不到资源大小了
        var releaseBreakdown = ReleaseBreakdown()
        for asset in assetArray {
            let bytes = Int(max(AssetStorage.info(of: asset).byteSize, 0))
            switch releaseKind(for: asset) {
            case .photo: releaseBreakdown.photo += bytes
            case .video: releaseBreakdown.video += bytes
            case .motion: releaseBreakdown.motion += bytes
            case .other: releaseBreakdown.other += bytes
            }
        }
        let freedBytes = Int64(releaseBreakdown.total)

        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(assetArray as NSArray)
        }) { [weak self] success, _ in
            Task { @MainActor in
                guard let self else {
                    completion(success)
                    return
                }

                if success {
                    let deletedIDs = Set(identifiers)
                    self.keptIdentifiers.subtract(deletedIDs)
                    self.pendingIdentifiers.subtract(deletedIDs)
                    self.deletedCount += deletedIDs.count
                    self.pendingPhotos.removeAll { photo in
                        guard let identifier = photo.assetIdentifier else { return false }
                        return deletedIDs.contains(identifier)
                    }
                    self.pruneGroups(removingIdentifiers: deletedIDs)
                    self.pruneTimeBuckets(removingIdentifiers: deletedIDs)
                    self.recordRelease(releaseBreakdown, deletedCount: deletedIDs.count)
                    self.quotaDeletedCount += deletedIDs.count
                    self.quotaReleasedBytes += max(freedBytes, 0)
                    self.persistQuotaLedger()
                    self.persistDecisionState()
                    self.updateProgressCounts()

                    if self.pendingPhotos.isEmpty, !self.pendingIdentifiers.isEmpty {
                        self.pendingPhotos = await self.loadPhotos(
                            from: PHAsset.fetchAssets(
                                withLocalIdentifiers: Array(self.pendingIdentifiers),
                                options: self.sortedFetchOptions()
                            ),
                            limit: 300
                        )
                    }

                    let updatedAssets = PHAsset.fetchAssets(with: self.mediaFetchOptions())
                    self.libraryCount = updatedAssets.count
                    self.homeCollections = self.makeHomeCollections()
                    self.currentMonthAddedCount = self.countAddedInCurrentMonth(from: updatedAssets)
                }
                completion(success)
            }
        }
    }

    /// 真正删除之后同步时间归档：整组被删空就把这一天／这个月／这一年去掉
    private func pruneTimeBuckets(removingIdentifiers identifiers: Set<String>) {
        guard !identifiers.isEmpty else { return }

        func prune(_ buckets: [TimeBucket]) -> [TimeBucket] {
            buckets.compactMap { bucket in
                let remaining = bucket.assetIdentifiers.filter { !identifiers.contains($0) }
                guard remaining.count != bucket.assetIdentifiers.count else { return bucket }
                guard !remaining.isEmpty else { return nil }
                return TimeBucket(
                    id: bucket.id,
                    label: bucket.label,
                    shortLabel: bucket.shortLabel,
                    count: remaining.count,
                    assetIdentifiers: remaining,
                    parentID: bucket.parentID
                )
            }
        }

        dailyBuckets = prune(dailyBuckets)
        monthlyBuckets = prune(monthlyBuckets)
        yearBuckets = prune(yearBuckets)
    }

    /// 把指定照片从所有分组里剔除，剩余数量不足以成组的方案整个丢弃
    private func pruneGroups(removingIdentifiers identifiers: Set<String>) {
        guard !identifiers.isEmpty else { return }

        groups = groups.compactMap { group in
            let remainingPhotos = group.photos.filter { photo in
                guard let identifier = photo.assetIdentifier else { return true }
                return !identifiers.contains(identifier)
            }

            guard remainingPhotos.count != group.photos.count else { return group }
            guard remainingPhotos.count >= group.kind.minimumPhotoCount else { return nil }

            return PhotoGroup(
                title: group.title,
                groupCount: group.groupCount,
                photoCount: remainingPhotos.count,
                symbol: group.symbol,
                tint: group.tint,
                kind: group.kind,
                photos: remainingPhotos
            )
        }
    }

    /// 这些分组只靠 PHAsset 的元数据判断，覆盖整个相册且几乎没有开销
    private func makeSystemGroups(from allAssets: PHFetchResult<PHAsset>) -> [PhotoGroup] {
        var screenshots: [PHAsset] = []
        var bursts: [PHAsset] = []
        var livePhotos: [PHAsset] = []
        var panoramas: [PHAsset] = []
        var hdrPhotos: [PHAsset] = []
        var videos: [PHAsset] = []
        var burstIdentifiers: Set<String> = []

        allAssets.enumerateObjects { asset, _, _ in
            if asset.mediaType == .video {
                videos.append(asset)
                return
            }
            let subtypes = asset.mediaSubtypes
            if subtypes.contains(.photoScreenshot) {
                screenshots.append(asset)
            }
            if subtypes.contains(.photoLive) {
                livePhotos.append(asset)
            }
            if subtypes.contains(.photoPanorama) {
                panoramas.append(asset)
            }
            if subtypes.contains(.photoHDR) {
                hdrPhotos.append(asset)
            }
            if let burstIdentifier = asset.burstIdentifier {
                burstIdentifiers.insert(burstIdentifier)
                bursts.append(asset)
            }
        }

        var result: [PhotoGroup] = []

        func appendGroup(
            _ assets: [PHAsset],
            title: String,
            symbol: String,
            tint: Color,
            kind: PhotoGroupKind,
            groupCount: Int = 1
        ) {
            guard !assets.isEmpty else { return }
            let sorted = assets.sorted {
                ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
            }
            result.append(
                PhotoGroup(
                    title: title,
                    groupCount: groupCount,
                    photoCount: sorted.count,
                    symbol: symbol,
                    tint: tint,
                    kind: kind,
                    photos: sorted.map { makePhotoItem(asset: $0, image: nil) }
                )
            )
        }

        appendGroup(
            videos,
            title: "视频",
            symbol: "video.fill",
            tint: .tidyCyan,
            kind: .mediaKind
        )
        appendGroup(
            screenshots,
            title: "截图",
            symbol: "doc.on.doc.fill",
            tint: .tidyViolet,
            kind: .screenshots
        )
        appendGroup(
            bursts,
            title: "连续抓拍",
            symbol: "square.stack.3d.up.fill",
            tint: .tidyAmber,
            kind: .bursts,
            groupCount: burstIdentifiers.count
        )
        appendGroup(
            livePhotos,
            title: "实况照片",
            symbol: "livephoto",
            tint: .tidyCyan,
            kind: .mediaKind
        )
        appendGroup(
            panoramas,
            title: "全景照片",
            symbol: "pano.fill",
            tint: .tidyKeep,
            kind: .mediaKind
        )
        appendGroup(
            hdrPhotos,
            title: "HDR 照片",
            symbol: "camera.filters",
            tint: .tidyViolet,
            kind: .mediaKind
        )

        return result
    }

    private func assetsForScan(limit: Int) -> [PHAsset] {
        let fetchResult = PHAsset.fetchAssets(with: .image, options: sortedFetchOptions())
        let count = min(fetchResult.count, limit)
        return (0..<count).map { fetchResult.object(at: $0) }
    }

    private func loadScanCandidates(from assets: [PHAsset]) async -> [PhotoItem] {
        var candidates: [PhotoItem] = []
        candidates.reserveCapacity(assets.count)

        for asset in assets {
            guard let image = await requestScanImage(for: asset) else { continue }
            candidates.append(makePhotoItem(asset: asset, image: image))
        }
        return candidates
    }

    /// 扫描只需要能做比对的小图，且不走网络，避免为了分组去下载 iCloud 原图
    private func requestScanImage(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false

            imageManager.requestImage(
                for: asset,
                targetSize: CGSize(width: 256, height: 256),
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    private func loadPhotos(from fetchResult: PHFetchResult<PHAsset>, limit: Int) async -> [PhotoItem] {
        var assets: [PHAsset] = []
        let count = min(fetchResult.count, limit)
        assets.reserveCapacity(count)
        for index in 0..<count {
            assets.append(fetchResult.object(at: index))
        }
        return await loadPhotos(from: assets)
    }

    private func loadPhotos(from assets: [PHAsset]) async -> [PhotoItem] {
        var loadedPhotos: [PhotoItem] = []
        loadedPhotos.reserveCapacity(assets.count)

        for asset in assets {
            let image = await requestThumbnail(for: asset)
            loadedPhotos.append(makePhotoItem(asset: asset, image: image))
        }
        return loadedPhotos
    }

    private func requestThumbnail(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true

            imageManager.requestImage(
                for: asset,
                targetSize: CGSize(width: 720, height: 720),
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    private func makePhotoItem(asset: PHAsset, image: UIImage?) -> PhotoItem {
        let date = asset.creationDate ?? Date()
        // kind 直接参与拼接展示，这里就要取到译文；tag 仍存中文 key，由展示层再查表
        let kind: String
        let tag: String
        if asset.mediaType == .video {
            kind = L10n.format("视频 · %@", VideoDuration.text(asset.duration))
            tag = "视频"
        } else if asset.mediaSubtypes.contains(.photoScreenshot) {
            kind = L10n.text("截图")
            tag = "截图"
        } else if asset.mediaSubtypes.contains(.photoLive) {
            kind = L10n.text("实况照片")
            tag = "实况照片"
        } else if asset.playbackStyle == .imageAnimated {
            kind = L10n.text("动态图")
            tag = "动态图"
        } else if asset.burstIdentifier != nil {
            kind = L10n.text("连拍")
            tag = "连续抓拍"
        } else {
            kind = L10n.text("照片")
            tag = "相册照片"
        }

        return PhotoItem(
            title: L10n.date(date, template: "yMMMMd"),
            detail: L10n.format("%@ · %@", L10n.time(date), kind),
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            artwork: .imported,
            image: image,
            tag: tag,
            assetIdentifier: asset.localIdentifier,
            capturedAt: asset.creationDate,
            mediaType: asset.mediaType,
            duration: asset.duration,
            motionKind: asset.mediaSubtypes.contains(.photoLive) ? .livePhoto
                : (asset.playbackStyle == .imageAnimated ? .animatedImage : .none)
        )
    }

    /// 把本次释放的空间计入当前自然月
    private func recordRelease(_ breakdown: ReleaseBreakdown, deletedCount: Int) {
        guard deletedCount > 0 else { return }
        let key = monthKey(for: Date())
        releasedBytesByMonth[key, default: 0] += breakdown.total
        releasedCountByMonth[key, default: 0] += deletedCount
        var stored = releasedBreakdownByMonth[key] ?? [:]
        stored[ReleasedMediaKind.photo.rawValue, default: 0] += breakdown.photo
        stored[ReleasedMediaKind.video.rawValue, default: 0] += breakdown.video
        stored[ReleasedMediaKind.motion.rawValue, default: 0] += breakdown.motion
        stored[ReleasedMediaKind.other.rawValue, default: 0] += breakdown.other
        releasedBreakdownByMonth[key] = stored
        updateReleaseStats()
    }

    private func releaseKind(for asset: PHAsset) -> ReleasedMediaKind {
        if asset.mediaType == .video { return .video }
        if asset.mediaType == .image {
            if asset.mediaSubtypes.contains(.photoLive) || asset.playbackStyle == .imageAnimated {
                return .motion
            }
            return .photo
        }
        return .other
    }

    private func updateReleaseStats() {
        monthlyReleases = makeMonthlyReleases()
        totalReleasedBytes = Int64(releasedBytesByMonth.values.reduce(0, +))
    }

    /// 最近六个月的释放量，数据来自每次确认删除时累计的真实文件大小
    private func makeMonthlyReleases() -> [MonthlyRelease] {
        let calendar = Calendar.current
        guard let currentMonth = calendar.date(
            from: calendar.dateComponents([.year, .month], from: Date())
        ) else { return [] }

        return (0..<6).reversed().compactMap { offset -> MonthlyRelease? in
            guard let date = calendar.date(byAdding: .month, value: -offset, to: currentMonth) else {
                return nil
            }
            let key = monthKey(for: date)
            let stored = releasedBreakdownByMonth[key] ?? [:]
            let photo = Int64(stored[ReleasedMediaKind.photo.rawValue] ?? 0)
            let video = Int64(stored[ReleasedMediaKind.video.rawValue] ?? 0)
            let motion = Int64(stored[ReleasedMediaKind.motion.rawValue] ?? 0)
            let recordedOther = Int64(stored[ReleasedMediaKind.other.rawValue] ?? 0)
            // 旧版本只有总数，差额保留在“其他”里，保证柱高与累计释放数一致。
            let legacyTotal = Int64(releasedBytesByMonth[key] ?? 0)
            let other = recordedOther + max(legacyTotal - photo - video - motion - recordedOther, 0)
            return MonthlyRelease(
                id: key,
                label: L10n.date(date, template: "MMM"),
                deletedCount: releasedCountByMonth[key] ?? 0,
                photoBytes: photo,
                videoBytes: video,
                motionBytes: motion,
                otherBytes: other
            )
        }
    }

    private func countAddedInCurrentMonth(from assets: PHFetchResult<PHAsset>) -> Int {
        let currentKey = monthKey(for: Date())
        var count = 0
        assets.enumerateObjects { asset, _, _ in
            guard let date = asset.creationDate else { return }
            if self.monthKey(for: date) == currentKey {
                count += 1
            }
        }
        return count
    }

    private func monthKey(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)"
    }

    private func yearKey(for date: Date) -> String {
        "\(Calendar.current.component(.year, from: date))"
    }

    private func identifiers(in assets: PHFetchResult<PHAsset>) -> Set<String> {
        var result: Set<String> = []
        result.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            result.insert(asset.localIdentifier)
        }
        return result
    }

    private func sortedFetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return options
    }

    private func restoreDecisionState() {
        keptIdentifiers = Set(defaults.stringArray(forKey: keptKey) ?? [])
        pendingIdentifiers = Set(defaults.stringArray(forKey: pendingKey) ?? [])
        deletedCount = defaults.integer(forKey: deletedCountKey)
        releasedBytesByMonth = defaults.dictionary(forKey: releasedBytesKey) as? [String: Int] ?? [:]
        releasedBreakdownByMonth = defaults.dictionary(forKey: releasedBreakdownKey) as? [String: [String: Int]] ?? [:]
        releasedCountByMonth = defaults.dictionary(forKey: releasedCountKey) as? [String: Int] ?? [:]
        restoreQuotaLedger()
    }

    private func restoreQuotaLedger() {
        quotaDeletedCount = defaults.integer(forKey: quotaDeletedCountKey)
        quotaReleasedBytes = Int64(defaults.integer(forKey: quotaReleasedBytesKey))
        hasClaimedReviewReward = defaults.bool(forKey: reviewRewardClaimedKey)
    }

    private func persistQuotaLedger() {
        defaults.set(quotaDeletedCount, forKey: quotaDeletedCountKey)
        defaults.set(Int(quotaReleasedBytes), forKey: quotaReleasedBytesKey)
    }

    /// 评分结果无法从 App Store 回传；按产品约定，点击跳转并等待 5 秒后即可领取一次。
    @discardableResult
    func grantReviewReward() -> Bool {
        guard !hasClaimedReviewReward else { return false }
        hasClaimedReviewReward = true
        defaults.set(true, forKey: reviewRewardClaimedKey)
        return true
    }

#if DEBUG
    /// 调试时不用卸载重装也能把额度归零。
    func resetQuotaLedger() {
        quotaDeletedCount = 0
        quotaReleasedBytes = 0
        hasClaimedReviewReward = false
        defaults.removeObject(forKey: reviewRewardClaimedKey)
        persistQuotaLedger()
    }
#endif

    private func persistDecisionState() {
        defaults.set(Array(keptIdentifiers), forKey: keptKey)
        defaults.set(Array(pendingIdentifiers), forKey: pendingKey)
        defaults.set(deletedCount, forKey: deletedCountKey)
        defaults.set(releasedBytesByMonth, forKey: releasedBytesKey)
        defaults.set(releasedBreakdownByMonth, forKey: releasedBreakdownKey)
        defaults.set(releasedCountByMonth, forKey: releasedCountKey)
    }

    private func updateProgressCounts() {
        keptCount = keptIdentifiers.count
        pendingCount = pendingIdentifiers.count
        reviewedCount = keptIdentifiers.union(pendingIdentifiers).count + deletedCount
    }

    /// 按天归档的分桶键，只用来聚合，不展示，所以固定用与语言无关的数字格式。
    /// 展示用的日期文案统一走 L10n.date(_:template:)，会跟着 App 内语言设置切换。
    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private enum PhotoSearchVocabulary {
    private static let groups: [[String]] = [
        ["水果", "苹果", "香蕉", "橙子", "梨", "桃", "葡萄", "西瓜", "草莓", "菠萝", "芒果", "猕猴桃", "樱桃", "fruit", "apple", "banana", "orange", "citrus", "pear", "peach", "grape", "watermelon", "strawberry", "pineapple", "mango", "kiwi", "cherry", "berry"],
        ["宠物", "动物", "猫", "狗", "兔子", "鸟", "pet", "animal", "cat", "dog", "kitten", "puppy", "rabbit", "hamster", "bird"],
        ["美食", "食物", "早餐", "午餐", "晚餐", "甜点", "蛋糕", "面包", "food", "meal", "dish", "cuisine", "breakfast", "lunch", "dinner", "dessert", "cake", "bread"],
        ["汽车", "车辆", "轿车", "卡车", "car", "automobile", "vehicle", "truck", "suv", "sedan"],
        ["花", "鲜花", "flower", "flowers", "plant", "blossom"],
        ["风景", "景色", "landscape", "scenery", "mountain", "lake", "beach", "ocean", "forest"],
        ["人物", "人像", "人", "person", "people", "portrait", "human"],
        ["截图", "screenshot", "screenshots", "screen capture"],
        ["二维码", "qr code", "barcode"],
        ["票据", "收据", "发票", "receipt", "invoice"],
        ["文档", "文件", "document", "paper"],
        ["证件", "身份证", "护照", "驾照", "驾驶证", "id", "ids", "identity card", "identification card", "id card", "passport", "driver license", "driving licence"]
    ]

    private static let documentQueries: Set<String> = [
        "证件", "身份证", "护照", "驾照", "驾驶证", "文档", "文件", "票据", "收据", "发票",
        "id", "ids", "identity card", "identification card", "id card", "passport", "driver license", "driving licence",
        "document", "paper", "receipt", "invoice"
    ]

    static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static func terms(for query: String) -> Set<String> {
        var result: Set<String> = [query]
        result.formUnion(query.split(whereSeparator: \.isWhitespace).map(String.init))

        for group in groups {
            let normalizedGroup = Set(group.map { normalized($0) })
            if normalizedGroup.contains(query) {
                result.formUnion(normalizedGroup)
            }
        }
        return result
    }

    static func needsDocumentAnalysis(_ query: String) -> Bool {
        documentQueries.map { normalized($0) }.contains(query)
    }

    static func isMetadataOnly(_ query: String) -> Bool {
        ["截图", "screenshot", "screenshots", "screen capture"].contains(query)
    }

    static func matches(labels: Set<String>, terms: Set<String>) -> Bool {
        labels.contains { rawLabel in
            let label = normalized(rawLabel)
            return terms.contains { term in
                label == term
                    || label.hasPrefix(term + " ")
                    || label.hasSuffix(" " + term)
                    || label.contains(" " + term + " ")
            }
        }
    }
}

private enum PhotoSemanticSearchAnalyzer {
    struct Result: Sendable {
        let labels: Set<String>
        let didClassify: Bool
        let didInspectDocument: Bool
    }

    static func analyze(
        _ input: PhotoSearchImageInput,
        classify: Bool,
        inspectDocument: Bool
    ) -> Result {
        var labels: Set<String> = []
        var didClassify = false
        var didInspectDocument = false

        if classify {
            let request = VNClassifyImageRequest()
            let handler = VNImageRequestHandler(cgImage: input.cgImage, options: [:])
            if (try? handler.perform([request])) != nil {
                didClassify = true
                let classifications = request.results ?? []
                for observation in classifications.prefix(16) where observation.confidence >= 0.08 {
                    labels.insert(PhotoSearchVocabulary.normalized(observation.identifier))
                }
            }
        }

        if inspectDocument {
            let documentRequest = VNDetectDocumentSegmentationRequest()
            let handler = VNImageRequestHandler(cgImage: input.cgImage, options: [:])
            if (try? handler.perform([documentRequest])) != nil {
                didInspectDocument = true
            }

            guard documentRequest.results?.isEmpty == false else {
                return Result(
                    labels: labels,
                    didClassify: didClassify,
                    didInspectDocument: didInspectDocument
                )
            }

            labels.insert("document")
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.automaticallyDetectsLanguage = true
            textRequest.usesLanguageCorrection = false

            let textHandler = VNImageRequestHandler(cgImage: input.cgImage, options: [:])
            if (try? textHandler.perform([textRequest])) != nil {
                let recognizedText = (textRequest.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ")
                    .lowercased()

                addDocumentLabels(from: recognizedText, to: &labels)
            }
        }

        return Result(
            labels: labels,
            didClassify: didClassify,
            didInspectDocument: didInspectDocument
        )
    }

    private static func addDocumentLabels(from text: String, to labels: inout Set<String>) {
        if containsAny(text, ["居民身份证", "公民身份号码", "identity card", "identification card"]) {
            labels.formUnion(["identity card", "id card"])
        }
        if containsAny(text, ["护照", "passport"]) {
            labels.insert("passport")
        }
        if containsAny(text, ["机动车驾驶证", "驾驶证", "driver license", "driving licence"]) {
            labels.formUnion(["driver license", "driving licence"])
        }
        if containsAny(text, ["发票", "invoice"]) {
            labels.insert("invoice")
        }
        if containsAny(text, ["收据", "receipt"]) {
            labels.insert("receipt")
        }
    }

    private static func containsAny(_ text: String, _ candidates: [String]) -> Bool {
        candidates.contains { text.localizedCaseInsensitiveContains($0) }
    }
}

private enum PhotoSearchWorker {
    static func analyze(
        _ job: PhotoSearchJob,
        targetDimension: CGFloat
    ) async -> PhotoSearchAnalysisOutcome {
        guard !Task.isCancelled,
              let image = await requestImage(
                forAssetIdentifier: job.identifier,
                targetDimension: targetDimension
              ),
              let cgImage = image.cgImage else {
            return PhotoSearchAnalysisOutcome(job: job, analysis: nil)
        }

        let analysis = PhotoSemanticSearchAnalyzer.analyze(
            PhotoSearchImageInput(cgImage: cgImage),
            classify: job.shouldClassify,
            inspectDocument: job.shouldInspectDocument
        )
        return PhotoSearchAnalysisOutcome(job: job, analysis: analysis)
    }

    private static func requestImage(
        forAssetIdentifier identifier: String,
        targetDimension: CGFloat
    ) async -> UIImage? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = assets.firstObject else { return nil }

        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            // 搜索分析不主动下载 iCloud 原图，避免首次建立索引时消耗大量流量。
            options.isNetworkAccessAllowed = false

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: targetDimension, height: targetDimension),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let isDegraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
                guard !isDegraded else { return }
                continuation.resume(returning: image)
            }
        }
    }
}

private enum VisionGroupDetector {
    /// VNFeaturePrintObservation 的距离阈值。0.18 过严，同场景连拍大多落在 0.2~0.35
    private static let similarityThreshold: Float = 0.32

    private struct Input: @unchecked Sendable {
        let photo: PhotoItem
        let cgImage: CGImage
    }

    static func detect(from photos: [PhotoItem]) async -> [PhotoGroup] {
        let inputs = photos.compactMap { photo -> Input? in
            guard !photo.isVideo, let cgImage = photo.image?.cgImage else { return nil }
            return Input(photo: photo, cgImage: cgImage)
        }

        guard inputs.count > 1 else { return [] }
        return await Task.detached(priority: .utility) {
            detectSynchronously(inputs)
        }.value
    }

    private static func detectSynchronously(_ inputs: [Input]) -> [PhotoGroup] {
        var exactBuckets: [Data: [Input]] = [:]
        for input in inputs {
            guard let signature = exactSignature(for: input) else { continue }
            exactBuckets[signature, default: []].append(input)
        }

        let duplicateBuckets = exactBuckets.values
            .filter { $0.count > 1 }
            .sorted { $0.count > $1.count }
        let duplicateIDs = Set(duplicateBuckets.flatMap { $0.map(\.photo.id) })
        let exactGroups = duplicateBuckets.map { bucket in
            let items = bucket.map(\.photo)
            return PhotoGroup(
                title: "完全相同",
                groupCount: 1,
                photoCount: items.count,
                symbol: "square.on.square.fill",
                tint: .tidyCyan,
                kind: .exactDuplicates,
                photos: items
            )
        }

        let blurryItems = inputs
            .filter {
                !duplicateIDs.contains($0.photo.id)
                    && $0.photo.tag != "截图"
                    && isLikelyBlurry($0.cgImage)
            }
            .map(\.photo)
        let blurryIDs = Set(blurryItems.map(\.id))
        let blurryGroups = blurryItems.isEmpty ? [] : [
            PhotoGroup(
                title: "可能模糊",
                groupCount: 1,
                photoCount: blurryItems.count,
                symbol: "camera.metering.unknown",
                tint: .tidyAmber,
                kind: .blurry,
                photos: blurryItems
            )
        ]

        var observations: [(Input, VNFeaturePrintObservation)] = []
        observations.reserveCapacity(inputs.count)

        for input in inputs where !duplicateIDs.contains(input.photo.id) && !blurryIDs.contains(input.photo.id) {
            let request = VNGenerateImageFeaturePrintRequest()
            let handler = VNImageRequestHandler(cgImage: input.cgImage, options: [:])
            guard (try? handler.perform([request])) != nil,
                  let observation = request.results?.first as? VNFeaturePrintObservation else {
                continue
            }
            observations.append((input, observation))
        }

        var buckets: [[Int]] = []
        for index in observations.indices {
            var matchedBucket: Int?

            for bucketIndex in buckets.indices {
                guard let representativeIndex = buckets[bucketIndex].first else { continue }
                var distance: Float = 0
                try? observations[index].1.computeDistance(
                    &distance,
                    to: observations[representativeIndex].1
                )

                if distance < similarityThreshold {
                    matchedBucket = bucketIndex
                    break
                }
            }

            if let matchedBucket {
                buckets[matchedBucket].append(index)
            } else {
                buckets.append([index])
            }
        }

        let similarGroups = buckets
            .filter { $0.count > 1 }
            .map { indexes in
                let items = indexes.map { observations[$0].0.photo }
                return PhotoGroup(
                    title: "视觉相似",
                    groupCount: 1,
                    photoCount: items.count,
                    symbol: "viewfinder.circle.fill",
                    tint: .tidyAccent,
                    kind: .similar,
                    photos: items
                )
            }

        return exactGroups + blurryGroups + similarGroups
    }

    private static func exactSignature(for input: Input) -> Data? {
        guard let providerData = input.cgImage.dataProvider?.data else { return nil }

        var width = UInt64(input.cgImage.width).bigEndian
        var height = UInt64(input.cgImage.height).bigEndian
        var hasher = SHA256()
        withUnsafeBytes(of: &width) { hasher.update(bufferPointer: $0) }
        withUnsafeBytes(of: &height) { hasher.update(bufferPointer: $0) }
        hasher.update(data: providerData as Data)
        return Data(hasher.finalize())
    }

    private static func isLikelyBlurry(_ image: CGImage) -> Bool {
        let width = 64
        let height = 64
        var pixels = [UInt8](repeating: 0, count: width * height)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }

            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return false }

        var sum = 0.0
        var squaredSum = 0.0
        var sampleCount = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let center = Int(pixels[y * width + x])
                let neighborSum = Int(pixels[(y - 1) * width + x])
                    + Int(pixels[(y + 1) * width + x])
                    + Int(pixels[y * width + x - 1])
                    + Int(pixels[y * width + x + 1])
                let laplacian = Double(neighborSum - center * 4)
                sum += laplacian
                squaredSum += laplacian * laplacian
                sampleCount += 1
            }
        }

        guard sampleCount > 0 else { return false }
        let mean = sum / sampleCount
        let variance = squaredSum / sampleCount - mean * mean
        return variance < 120
    }
}

import Photos
import SwiftUI

/// 首页预览轮播的合集类型。取图条件、标题和范围文案都由各自的 case 自己给出，
/// 首页只负责轮播，不需要知道每种合集是怎么筛出来的。
enum PhotoCollectionKind: Hashable {
    /// 最近 N 天新增
    case recentlyAdded(days: Int)
    /// N 年前的这个月
    case monthYearsAgo(yearsAgo: Int)
    case screenshots
    case videos
    case livePhotos
    case selfies

    var id: String {
        switch self {
        case let .recentlyAdded(days): "recent-\(days)"
        case let .monthYearsAgo(yearsAgo): "monthYearsAgo-\(yearsAgo)"
        case .screenshots: "screenshots"
        case .videos: "videos"
        case .livePhotos: "livePhotos"
        case .selfies: "selfies"
        }
    }

    /// 工程用中文原文当本地化 key，取用时仍需显式走 L10n
    var title: String {
        switch self {
        case .recentlyAdded: "最近新增"
        case .monthYearsAgo: "那年今月"
        case .screenshots: "截图"
        case .videos: "视频"
        case .livePhotos: "实况照片"
        case .selfies: "自拍"
        }
    }

    var symbol: String {
        switch self {
        case .recentlyAdded: "clock.badge.checkmark"
        case .monthYearsAgo: "calendar"
        case .screenshots: "rectangle.dashed"
        case .videos: "video.fill"
        case .livePhotos: "livephoto"
        case .selfies: "person.crop.square"
        }
    }

    /// 标题下那行范围说明。含日期，所以这里直接返回已经本地化好的成品文案。
    var scopeText: String {
        switch self {
        case let .recentlyAdded(days):
            return days <= 7 ? L10n.text("最近一周") : L10n.format("最近 %lld 天", days)
        case let .monthYearsAgo(yearsAgo):
            guard let anchor = Calendar.current.date(byAdding: .year, value: -yearsAgo, to: Date()) else { return "" }
            return L10n.date(anchor, template: "yMMMM")
        case .screenshots:
            return L10n.text("看过就能删")
        case .videos:
            return L10n.text("最占空间")
        case .livePhotos:
            return L10n.text("每张都带一小段视频")
        case .selfies:
            return L10n.text("前置摄像头拍的")
        }
    }

    /// 少于这个数量就不值得单独占一张卡。回忆类哪怕只剩一张也想看到。
    var minimumCount: Int {
        switch self {
        case .recentlyAdded, .monthYearsAgo: 1
        case .screenshots, .videos, .livePhotos, .selfies: 4
        }
    }

    /// 这个合集的全部资产，按拍摄时间从新到旧。返回 nil 表示系统里没有对应的智能相簿。
    func fetchAssets() -> PHFetchResult<PHAsset>? {
        switch self {
        case let .recentlyAdded(days):
            guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else { return nil }
            return Self.fetch(matching: NSPredicate(format: "creationDate >= %@", cutoff as NSDate))

        case let .monthYearsAgo(yearsAgo):
            guard let range = Self.range(of: .month, yearsAgo: yearsAgo) else { return nil }
            return Self.fetch(matching: Self.predicate(in: range))

        case .videos:
            return Self.fetch(matching: NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue))

        case .screenshots:
            return Self.fetchSmartAlbum(.smartAlbumScreenshots)

        case .livePhotos:
            return Self.fetchSmartAlbum(.smartAlbumLivePhotos)

        case .selfies:
            return Self.fetchSmartAlbum(.smartAlbumSelfPortraits)
        }
    }

    // MARK: - 取图

    private static func baseOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return options
    }

    /// 只要照片和视频，整理页处理不了其他类型
    private static var mediaPredicate: NSPredicate {
        NSPredicate(
            format: "mediaType IN %@",
            [PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue]
        )
    }

    private static func fetch(matching predicate: NSPredicate) -> PHFetchResult<PHAsset> {
        let options = baseOptions()
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [mediaPredicate, predicate])
        return PHAsset.fetchAssets(with: options)
    }

    /// 智能相簿里可能混着别的类型，取出来后仍按照片和视频过一遍
    private static func fetchSmartAlbum(_ subtype: PHAssetCollectionSubtype) -> PHFetchResult<PHAsset>? {
        let albums = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil)
        guard let album = albums.firstObject else { return nil }

        let options = baseOptions()
        options.predicate = mediaPredicate
        return PHAsset.fetchAssets(in: album, options: options)
    }

    /// N 年前的那一天或那一个月的起止时间
    private static func range(of component: Calendar.Component, yearsAgo: Int) -> DateInterval? {
        let calendar = Calendar.current
        guard let anchor = calendar.date(byAdding: .year, value: -yearsAgo, to: Date()),
              let interval = calendar.dateInterval(of: component, for: anchor) else { return nil }
        return interval
    }

    private static func predicate(in range: DateInterval) -> NSPredicate {
        NSPredicate(
            format: "creationDate >= %@ AND creationDate < %@",
            range.start as NSDate,
            range.end as NSDate
        )
    }
}

/// 首页一张预览卡的全部内容。`count` 只算还没做过决定的，和点进去的整理队列对得上。
struct PhotoCollectionPreview: Identifiable {
    let kind: PhotoCollectionKind
    /// 卡片封面，从合集最前面几张里随机挑一张
    let cover: PhotoItem
    let count: Int

    var id: String { kind.id }
}

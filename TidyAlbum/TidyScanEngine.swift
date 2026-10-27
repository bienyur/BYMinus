import CryptoKit
import Photos
import UIKit
import Vision

/// 建议清理的归因。它不只是内部分类：结果页要靠它向用户解释「为什么是这张」，
/// 所以每一项都自带标题、图标和一句「替你保留了什么」的说明。
enum TidyScanReason: String, CaseIterable, Identifiable, Sendable {
    /// 像素完全一致，整组只留一张
    case exactDuplicate
    /// 纯黑／纯白／糊成一片的口袋误拍
    case blankFrame
    /// 连拍冗余，苹果自己已经标出了最佳帧
    case burstRedundant
    /// 严重模糊
    case severelyBlurry
    /// 同一场景连拍之外的近重复，留最清晰的一张
    case nearDuplicate
    /// 网图、表情包这类非相机拍摄的图片
    case webImage
    /// 超过保鲜期的旧截图
    case staleScreenshot
    /// 普通截图
    case screenshot

    var id: String { rawValue }

    /// 基础置信度。精细程度滑杆就是拿这个分数做阈值，
    /// 所以以后新增一类判断只要给一个分数，界面逻辑一行都不用改。
    var baseScore: Double {
        switch self {
        case .exactDuplicate: 0.98
        case .blankFrame: 0.95
        case .burstRedundant: 0.92
        case .severelyBlurry: 0.88
        case .nearDuplicate: 0.85
        case .webImage: 0.75
        case .staleScreenshot: 0.70
        case .screenshot: 0.55
        }
    }

    /// 结果页的分组标题。正式版接入 L10n，原型阶段先用中文常量。
    var title: String {
        switch self {
        case .exactDuplicate: "完全重复"
        case .blankFrame: "误拍废片"
        case .burstRedundant: "连拍冗余"
        case .severelyBlurry: "模糊照片"
        case .nearDuplicate: "几乎一样"
        case .webImage: "网图和表情包"
        case .staleScreenshot: "过期截图"
        case .screenshot: "截图"
        }
    }

    var symbol: String {
        switch self {
        case .exactDuplicate: "square.on.square.dashed"
        case .blankFrame: "circle.slash"
        case .burstRedundant: "square.stack.3d.up.fill"
        case .severelyBlurry: "camera.metering.unknown"
        case .nearDuplicate: "viewfinder.circle.fill"
        case .webImage: "arrow.down.circle"
        case .staleScreenshot: "clock.badge.xmark"
        case .screenshot: "doc.on.doc.fill"
        }
    }

    /// 刻意说「保留了什么」而不是「要删什么」：同一个事实，用户的接受度差很多。
    var explanation: String {
        switch self {
        case .exactDuplicate: "这些和已保留的那张像素完全一致"
        case .blankFrame: "几乎全黑或全白，多半是误触快门"
        case .burstRedundant: "已按系统标记保留每组连拍里的最佳帧"
        case .severelyBlurry: "清晰度明显不足，且画面里没有人"
        case .nearDuplicate: "同一场景的多张里已保留最清晰的一张"
        case .webImage: "不是相机拍摄，多为保存的网图或表情包"
        case .staleScreenshot: "很久以前的截图，通常已经没用了"
        case .screenshot: "截图通常是临时信息"
        }
    }
}

/// 命中即出局的保护规则。这些不是扣分项，是硬否决——
/// 误删一次的代价远高于少清理几张。
struct TidyScanProtection: OptionSet, Sendable {
    let rawValue: Int

    static let favorite = TidyScanProtection(rawValue: 1 << 0)
    static let inUserAlbum = TidyScanProtection(rawValue: 1 << 1)
    static let recentlyCaptured = TidyScanProtection(rawValue: 1 << 2)
    static let containsFace = TidyScanProtection(rawValue: 1 << 3)
    static let userEdited = TidyScanProtection(rawValue: 1 << 4)

    var labels: [String] {
        var result: [String] = []
        if contains(.favorite) { result.append("已收藏") }
        if contains(.inUserAlbum) { result.append("在相簿中") }
        if contains(.recentlyCaptured) { result.append("最近拍摄") }
        if contains(.containsFace) { result.append("有人脸") }
        if contains(.userEdited) { result.append("编辑过") }
        return result
    }
}

/// 一条清理建议。
struct TidyScanCandidate: Identifiable, Sendable {
    let assetIdentifier: String
    let reason: TidyScanReason
    let score: Double
    let bytes: Int64
    let protections: TidyScanProtection
    /// 成组判断时，这一组里替用户保留下来的那张。单张判断为 nil。
    let keptIdentifier: String?

    var id: String { assetIdentifier }
    var isProtected: Bool { !protections.isEmpty }
}

/// 精细程度。本质就是可删分的阈值，界面上用结果说话而不是用「保守／激进」这种词。
enum TidyScanAggressiveness: String, CaseIterable, Identifiable, Sendable {
    case safe
    case recommended
    case maximal

    var id: String { rawValue }

    var threshold: Double {
        switch self {
        case .safe: 0.85
        case .recommended: 0.65
        case .maximal: 0.45
        }
    }

    var title: String {
        switch self {
        case .safe: "只清理绝对安全的"
        case .recommended: "推荐"
        case .maximal: "尽可能多清理"
        }
    }
}

struct TidyScanResult: Sendable {
    /// 实际完成分析的张数
    let scannedCount: Int
    /// 取到了资产但本机没有可用图片（多为 iCloud 未下载），这部分要如实告诉用户
    let skippedCount: Int
    let candidates: [TidyScanCandidate]

    static let empty = TidyScanResult(scannedCount: 0, skippedCount: 0, candidates: [])

    /// 拖动滑杆时只走这一层过滤，纯内存 O(n)，不需要重新扫描。
    func filtered(
        for aggressiveness: TidyScanAggressiveness,
        includingProtected: Bool = false
    ) -> [TidyScanCandidate] {
        candidates.filter {
            $0.score >= aggressiveness.threshold && (includingProtected || !$0.isProtected)
        }
    }

    func bytes(for aggressiveness: TidyScanAggressiveness) -> Int64 {
        filtered(for: aggressiveness).reduce(0) { $0 + $1.bytes }
    }
}

/// 一键整理的打分引擎。
///
/// 结构上刻意和界面解耦：扫描一次产出全部候选和分数，界面只负责按阈值过滤。
/// 当前这一版只用已有信号（元数据 + Vision），不依赖任何捆绑模型；
/// 语义那一档（MobileCLIP）之后作为新的打分器接进来即可。
enum TidyScanEngine {
    struct Configuration: Sendable {
        /// 免费档只整理最近这么多张。这同时也把首次扫描的耗时压到了几秒。
        var scanLimit = 100
        /// 这段时间内拍的一律保护，用户往往还没来得及处理
        var recentProtectionDays = 7
        /// 超过这个天数的截图降级为「过期截图」，置信度更高
        var staleScreenshotDays = 90
        /// 近重复聚类阈值。VisionGroupDetector 用 0.32 是为了「找出相似照片」给用户看，
        /// 这里是要据此删除，必须更严：宁可漏掉几组，也不能把不相干的照片并进同一桶。
        var nearDuplicateDistance: Float = 0.22
        /// Laplacian 方差低于此值判定为模糊。注意采样分辨率比旧的 64×64 高，阈值不能直接照搬。
        var blurVarianceThreshold: Double = 90
        /// 像素面积小于这个值且不是截图时，倾向判定为网图
        var webImagePixelArea = 1_200_000

        init() { }
    }

    /// progress 固定在主线程回调，界面可以直接赋值给 @State，不用自己做线程跳转。
    static func scan(
        configuration: Configuration = Configuration(),
        progress: @escaping @MainActor (Int, Int) -> Void = { _, _ in }
    ) async -> TidyScanResult {
        let samples = await collectSamples(configuration: configuration, progress: progress)
        guard !samples.isEmpty else { return .empty }

        return await Task.detached(priority: .userInitiated) {
            evaluate(samples, configuration: configuration)
        }.value
    }
}

// MARK: - 取数

/// 单张照片在扫描期间需要的全部事实。
/// PHAsset 不是 Sendable，所以先在取数阶段摊平成值类型，后续分析全部在后台线程跑。
private struct ScanSample: @unchecked Sendable {
    let identifier: String
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let bytes: Int64
    let isFavorite: Bool
    let isScreenshot: Bool
    let burstIdentifier: String?
    let burstSelection: PHAssetBurstSelectionType
    let hasLocation: Bool
    let originalFilename: String?
    let hasAdjustments: Bool
    let inUserAlbum: Bool
    /// 本机拿不到图时为 nil（多为 iCloud 未下载），这类只能靠元数据判断
    let cgImage: CGImage?

    var pixelArea: Int { pixelWidth * pixelHeight }
}

private extension TidyScanEngine {
    static func collectSamples(
        configuration: Configuration,
        progress: @escaping @MainActor (Int, Int) -> Void
    ) async -> [ScanSample] {
        // 视频不参与像素级判断，原型阶段只扫图片；视频清理靠体积和时长另走一套规则。
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = max(configuration.scanLimit, 1)
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        guard assets.count > 0 else { return [] }

        let albumMembers = identifiersInUserAlbums()
        let total = assets.count
        var samples: [ScanSample] = []
        samples.reserveCapacity(total)

        for index in 0..<total {
            let asset = assets.object(at: index)
            let resources = PHAssetResource.assetResources(for: asset)
            let byteSize = resources
                .compactMap { ($0.value(forKey: "fileSize") as? NSNumber)?.int64Value }
                .max() ?? 0

            let image = await requestAnalysisImage(for: asset)
            samples.append(
                ScanSample(
                    identifier: asset.localIdentifier,
                    creationDate: asset.creationDate,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight,
                    bytes: byteSize,
                    isFavorite: asset.isFavorite,
                    isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
                    burstIdentifier: asset.burstIdentifier,
                    burstSelection: asset.burstSelectionTypes,
                    hasLocation: asset.location != nil,
                    originalFilename: resources.first?.originalFilename,
                    // 存在调整数据说明用户手动编辑过，是很强的「我在乎这张」信号
                    hasAdjustments: resources.contains { $0.type == .adjustmentData },
                    inUserAlbum: albumMembers.contains(asset.localIdentifier),
                    cgImage: image?.cgImage
                )
            )
            await MainActor.run { progress(index + 1, total) }
        }
        return samples
    }

    /// 只统计用户自己建的相簿：系统智能相簿是自动归类的，不代表用户的主动意愿。
    static func identifiersInUserAlbums() -> Set<String> {
        var result: Set<String> = []
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: nil
        )
        collections.enumerateObjects { collection, _, _ in
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            assets.enumerateObjects { asset, _, _ in
                result.insert(asset.localIdentifier)
            }
        }
        return result
    }

    /// 分析用小图。和搜索索引一致地禁用网络，避免为了扫描去下载 iCloud 原图。
    /// 256 是清晰度排序能用的最低分辨率——旧的 64×64 会把清晰度差异整个抹平。
    ///
    /// 必须用 aspectFill：aspectFit 会给非正方形照片补黑边，竖拍照片两侧的大块纯黑
    /// 会让 FeaturePrint 把彼此无关的照片判成相似，近重复聚类直接失效。
    static func requestAnalysisImage(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false
            options.isSynchronous = false

            var didResume = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 256, height: 256),
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                let isDegraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
                guard !isDegraded, !didResume else { return }
                didResume = true
                continuation.resume(returning: image)
            }
        }
    }
}

// MARK: - 逐张分析

private struct ScanAnalysis {
    var sharpness: Double = 0
    var meanLuminance: Double = 0
    var faceCount: Int = 0
    /// 完全相同判定用的像素指纹
    var signature: Data?
    var featurePrint: VNFeaturePrintObservation?
}

private extension TidyScanEngine {
    static func evaluate(_ samples: [ScanSample], configuration: Configuration) -> TidyScanResult {
        var analyses: [String: ScanAnalysis] = [:]
        analyses.reserveCapacity(samples.count)
        var skipped = 0

        for sample in samples {
            guard let cgImage = sample.cgImage else {
                skipped += 1
                continue
            }
            analyses[sample.identifier] = analyze(cgImage)
        }

        let protections = samples.reduce(into: [String: TidyScanProtection]()) { result, sample in
            result[sample.identifier] = protection(
                for: sample,
                analysis: analyses[sample.identifier],
                configuration: configuration
            )
        }

        // 一张照片只归一个因。每一级认领掉的照片不再进入后面的判断，
        // 顺序就是优先级，排错了会让低置信度的类别吞掉高置信度的归因。
        var candidates: [TidyScanCandidate] = []
        var claimed: Set<String> = []

        func claim(_ proposals: [TidyScanCandidate]) {
            for candidate in proposals where !claimed.contains(candidate.assetIdentifier) {
                claimed.insert(candidate.assetIdentifier)
                candidates.append(candidate)
            }
        }

        func single(
            _ sample: ScanSample,
            _ reason: TidyScanReason,
            score: Double? = nil
        ) -> TidyScanCandidate {
            TidyScanCandidate(
                assetIdentifier: sample.identifier,
                reason: reason,
                score: score ?? reason.baseScore,
                bytes: sample.bytes,
                protections: protections[sample.identifier] ?? [],
                keptIdentifier: nil
            )
        }

        let analyzed = samples.filter { analyses[$0.identifier] != nil }

        // 1. 完全重复和连拍：置信度最高，而且要由它们决定「替你保留了哪张」。
        claim(exactDuplicates(analyzed, analyses: analyses, protections: protections))
        claim(burstRedundants(samples, analyses: analyses, protections: protections))

        // 2. 纯黑纯白的误拍。必须排在聚类之前：这类照片彼此之间本来就极其相似，
        //    放进近重复聚类只会得到一个「什么都有」的大桶。
        claim(
            analyzed
                .filter { !claimed.contains($0.identifier) }
                .filter { isBlankFrame(analyses[$0.identifier]!) }
                .map { single($0, .blankFrame) }
        )

        // 3. 截图同理，先单独摘出去，否则同一个 App 的截图会把聚类结果搅乱。
        claim(
            samples
                .filter { !claimed.contains($0.identifier) && $0.isScreenshot }
                .map {
                    let isStale = ageInDays(of: $0) > Double(configuration.staleScreenshotDays)
                    return single($0, isStale ? .staleScreenshot : .screenshot)
                }
        )

        // 4. 到这里剩下的才是真正的相机照片，近重复聚类只在这个池子里跑。
        claim(
            nearDuplicates(
                analyzed.filter { !claimed.contains($0.identifier) },
                analyses: analyses,
                protections: protections,
                configuration: configuration
            )
        )

        // 5. 模糊排在聚类之后：一组近似照片可能整组都偏糊，先判模糊会把仅有的那张
        //    最清晰的也一起标记掉，交给聚类才能保证至少留下一张。
        //    另外只对没有人的照片下手——糊掉的风景删了没人心疼，糊掉的合影删了用户会卸载。
        claim(
            analyzed
                .filter { !claimed.contains($0.identifier) }
                .compactMap { sample in
                    let analysis = analyses[sample.identifier]!
                    guard analysis.faceCount == 0,
                          analysis.sharpness < configuration.blurVarianceThreshold else { return nil }
                    // 越糊越确定，但不超过基础分
                    let severity = 1 - (analysis.sharpness / configuration.blurVarianceThreshold)
                    return single(
                        sample,
                        .severelyBlurry,
                        score: TidyScanReason.severelyBlurry.baseScore * (0.75 + 0.25 * severity)
                    )
                }
        )

        // 6. 兜底的网图判定，置信度最低，只吃前面都没认领的。
        claim(
            samples
                .filter { !claimed.contains($0.identifier) }
                .filter { isLikelyWebImage($0, configuration: configuration) }
                .map { single($0, .webImage) }
        )

        let sorted = candidates.sorted {
            $0.score == $1.score ? $0.bytes > $1.bytes : $0.score > $1.score
        }
        return TidyScanResult(
            scannedCount: samples.count - skipped,
            skippedCount: skipped,
            candidates: sorted
        )
    }

    static func analyze(_ cgImage: CGImage) -> ScanAnalysis {
        var analysis = ScanAnalysis()
        analysis.signature = pixelSignature(cgImage)

        let stats = luminanceStatistics(cgImage)
        analysis.sharpness = stats.laplacianVariance
        analysis.meanLuminance = stats.mean

        // 只做人脸「检测」，不涉及身份识别，纯粹当保护信号用，不需要任何模型。
        let faceRequest = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        if (try? handler.perform([faceRequest])) != nil {
            analysis.faceCount = faceRequest.results?.count ?? 0
        }

        let printRequest = VNGenerateImageFeaturePrintRequest()
        if (try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([printRequest])) != nil {
            analysis.featurePrint = printRequest.results?.first as? VNFeaturePrintObservation
        }
        return analysis
    }

    static func protection(
        for sample: ScanSample,
        analysis: ScanAnalysis?,
        configuration: Configuration
    ) -> TidyScanProtection {
        var result: TidyScanProtection = []
        if sample.isFavorite { result.insert(.favorite) }
        if sample.inUserAlbum { result.insert(.inUserAlbum) }
        if sample.hasAdjustments { result.insert(.userEdited) }
        if ageInDays(of: sample) < Double(configuration.recentProtectionDays) {
            result.insert(.recentlyCaptured)
        }
        // 截图里的人脸多半是别人发来的图，不构成保护理由
        if let analysis, analysis.faceCount > 0, !sample.isScreenshot {
            result.insert(.containsFace)
        }
        return result
    }

    static func ageInDays(of sample: ScanSample) -> Double {
        guard let date = sample.creationDate else { return .greatestFiniteMagnitude }
        return Date().timeIntervalSince(date) / 86_400
    }
}

// MARK: - 成组打分器

private extension TidyScanEngine {
    /// 组内排序：分数最高的那张被保留。
    /// 受保护的排在最前面，这样「重复照片里有一张被收藏」时删掉的是没收藏的那张，
    /// 而不是整组因为保护规则而放弃清理。
    static func keepPriority(
        _ sample: ScanSample,
        analysis: ScanAnalysis?,
        protections: TidyScanProtection
    ) -> Double {
        var score = 0.0
        if !protections.isEmpty { score += 1_000_000 }
        if sample.burstSelection.contains(.userPick) { score += 100_000 }
        if sample.burstSelection.contains(.autoPick) { score += 50_000 }
        score += (analysis?.sharpness ?? 0) * 10
        score += Double(sample.pixelArea) / 1_000_000
        score += Double(sample.bytes) / 1_000_000
        return score
    }

    static func exactDuplicates(
        _ samples: [ScanSample],
        analyses: [String: ScanAnalysis],
        protections: [String: TidyScanProtection]
    ) -> [TidyScanCandidate] {
        var buckets: [Data: [ScanSample]] = [:]
        for sample in samples {
            guard let signature = analyses[sample.identifier]?.signature else { continue }
            buckets[signature, default: []].append(sample)
        }

        return buckets.values.filter { $0.count > 1 }.flatMap { bucket in
            redundants(
                in: bucket,
                reason: .exactDuplicate,
                analyses: analyses,
                protections: protections
            )
        }
    }

    static func burstRedundants(
        _ samples: [ScanSample],
        analyses: [String: ScanAnalysis],
        protections: [String: TidyScanProtection]
    ) -> [TidyScanCandidate] {
        var buckets: [String: [ScanSample]] = [:]
        for sample in samples {
            guard let burstIdentifier = sample.burstIdentifier else { continue }
            buckets[burstIdentifier, default: []].append(sample)
        }

        return buckets.values.filter { $0.count > 1 }.flatMap { bucket in
            redundants(
                in: bucket,
                reason: .burstRedundant,
                analyses: analyses,
                protections: protections
            )
        }
    }

    static func nearDuplicates(
        _ samples: [ScanSample],
        analyses: [String: ScanAnalysis],
        protections: [String: TidyScanProtection],
        configuration: Configuration
    ) -> [TidyScanCandidate] {
        let entries = samples.compactMap { sample -> (ScanSample, VNFeaturePrintObservation)? in
            guard let print = analyses[sample.identifier]?.featurePrint else { return nil }
            return (sample, print)
        }
        guard entries.count > 1 else { return [] }

        // 与代表帧比距离的贪心聚类，和 VisionGroupDetector 里的做法一致。
        // 注意不能写成 try? + 预置 0：计算失败时距离会停在 0，判定恒为真，
        // 结果是所有照片都被并进第一个桶。失败必须当作「不相似」。
        var buckets: [[Int]] = []
        for index in entries.indices {
            var matched: Int?
            for bucketIndex in buckets.indices {
                guard let representative = buckets[bucketIndex].first else { continue }
                var distance = Float.greatestFiniteMagnitude
                do {
                    try entries[index].1.computeDistance(&distance, to: entries[representative].1)
                } catch {
                    continue
                }
                if distance < configuration.nearDuplicateDistance {
                    matched = bucketIndex
                    break
                }
            }
            if let matched {
                buckets[matched].append(index)
            } else {
                buckets.append([index])
            }
        }

        return buckets.filter { $0.count > 1 }.flatMap { indexes in
            redundants(
                in: indexes.map { entries[$0].0 },
                reason: .nearDuplicate,
                analyses: analyses,
                protections: protections
            )
        }
    }

    /// 一组里留最好的那张，其余全部作为候选返回。
    static func redundants(
        in bucket: [ScanSample],
        reason: TidyScanReason,
        analyses: [String: ScanAnalysis],
        protections: [String: TidyScanProtection]
    ) -> [TidyScanCandidate] {
        let ranked = bucket.sorted {
            keepPriority($0, analysis: analyses[$0.identifier], protections: protections[$0.identifier] ?? [])
                > keepPriority($1, analysis: analyses[$1.identifier], protections: protections[$1.identifier] ?? [])
        }
        guard let kept = ranked.first else { return [] }

        return ranked.dropFirst().map { sample in
            TidyScanCandidate(
                assetIdentifier: sample.identifier,
                reason: reason,
                score: reason.baseScore,
                bytes: sample.bytes,
                protections: protections[sample.identifier] ?? [],
                keptIdentifier: kept.identifier
            )
        }
    }
}

// MARK: - 单张打分器

private extension TidyScanEngine {
    /// 几乎全黑或全白，且没有任何细节——口袋误拍、镜头被挡的典型特征。
    static func isBlankFrame(_ analysis: ScanAnalysis) -> Bool {
        let isExtreme = analysis.meanLuminance < 18 || analysis.meanLuminance > 244
        return isExtreme && analysis.sharpness < 12
    }

    /// 网图判定。没有 EXIF 可用的廉价代理信号：文件名不是相机命名、无定位、分辨率偏小。
    /// 这一档置信度本来就不高，原型跑出来的误判率正好用来决定要不要保留它。
    static func isLikelyWebImage(_ sample: ScanSample, configuration: Configuration) -> Bool {
        guard !sample.isScreenshot, sample.burstIdentifier == nil, !sample.hasLocation else {
            return false
        }
        let isCameraFilename = sample.originalFilename.map {
            $0.uppercased().hasPrefix("IMG_") || $0.uppercased().hasPrefix("DSC")
        } ?? false
        return !isCameraFilename && sample.pixelArea < configuration.webImagePixelArea
    }
}

// MARK: - 像素统计

private extension TidyScanEngine {
    static func pixelSignature(_ image: CGImage) -> Data? {
        guard let providerData = image.dataProvider?.data else { return nil }
        var width = UInt64(image.width).bigEndian
        var height = UInt64(image.height).bigEndian
        var hasher = SHA256()
        withUnsafeBytes(of: &width) { hasher.update(bufferPointer: $0) }
        withUnsafeBytes(of: &height) { hasher.update(bufferPointer: $0) }
        hasher.update(data: providerData as Data)
        return Data(hasher.finalize())
    }

    /// 一次灰度重采样同时算出平均亮度和 Laplacian 方差。
    /// 采样定在 256×256：64×64 足够判断「糊没糊」，但没法在几张近似照片之间排出清晰度名次。
    static func luminanceStatistics(_ image: CGImage) -> (mean: Double, laplacianVariance: Double) {
        let side = 256
        var pixels = [UInt8](repeating: 0, count: side * side)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard rendered else { return (0, 0) }

        var luminanceSum = 0.0
        var sum = 0.0
        var squaredSum = 0.0
        var sampleCount = 0.0

        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) {
                let center = Int(pixels[y * side + x])
                luminanceSum += Double(center)
                let neighborSum = Int(pixels[(y - 1) * side + x])
                    + Int(pixels[(y + 1) * side + x])
                    + Int(pixels[y * side + x - 1])
                    + Int(pixels[y * side + x + 1])
                let laplacian = Double(neighborSum - center * 4)
                sum += laplacian
                squaredSum += laplacian * laplacian
                sampleCount += 1
            }
        }

        guard sampleCount > 0 else { return (0, 0) }
        let mean = sum / sampleCount
        return (luminanceSum / sampleCount, squaredSum / sampleCount - mean * mean)
    }
}

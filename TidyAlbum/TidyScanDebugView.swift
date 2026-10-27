#if DEBUG
import Photos
import SwiftUI

/// 打分引擎的准确率验证台，只在调试包里出现。
///
/// 用法：扫描后逐张点选「这张判错了」，界面实时给出每一类的准确率。
/// 目的是在投入做正式结果页之前，先确认各个打分器在真实相册上到底准不准。
struct TidyScanDebugView: View {
    let onClose: () -> Void

    @State private var scanLimit = 100
    /// 近重复聚类阈值直接摆在界面上调，省得为了试一个数字重编译一次
    @State private var nearDuplicateDistance: Float = 0.22
    @State private var aggressiveness: TidyScanAggressiveness = .recommended
    @State private var showsProtected = false
    @State private var isScanning = false
    @State private var progress: (done: Int, total: Int)?
    @State private var result: TidyScanResult?
    /// 用户标记为误判的资产。判定准确率时作为分母里的错误数。
    @State private var misjudged: Set<String> = []
    @State private var comparison: TidyScanCandidate?

    private let limitOptions = [100, 300, 500, 1_000]
    private let distanceOptions: [Float] = [0.14, 0.18, 0.22, 0.26, 0.32]
    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 8)]

    var body: some View {
        NavigationStack {
            List {
                controlSection
                if let result {
                    summarySection(result)
                    ForEach(orderedReasons(in: result), id: \.self) { reason in
                        reasonSection(reason, in: result)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("打分引擎验证")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", action: onClose)
                }
            }
            .sheet(item: $comparison) { candidate in
                TidyScanComparisonView(candidate: candidate)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    // MARK: - 控制区

    private var controlSection: some View {
        Section {
            Picker("扫描范围", selection: $scanLimit) {
                ForEach(limitOptions, id: \.self) { value in
                    Text("最近 \(value) 张").tag(value)
                }
            }
            .pickerStyle(.menu)
            .disabled(isScanning)

            Picker("近重复严格度", selection: $nearDuplicateDistance) {
                ForEach(distanceOptions, id: \.self) { value in
                    Text(String(format: "%.2f", value)).tag(value)
                }
            }
            .pickerStyle(.menu)
            .disabled(isScanning)

            Button {
                Task { await runScan() }
            } label: {
                if isScanning {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(progressText)
                    }
                } else {
                    Label("开始扫描", systemImage: "sparkle.magnifyingglass")
                }
            }
            .disabled(isScanning)
        } footer: {
            Text("扫描不下载 iCloud 原图，本机没有图片的会计入「未分析」。近重复严格度越小越严，只有极其接近的照片才会被归为一组。")
        }
    }

    private var progressText: String {
        guard let progress else { return "准备中…" }
        return "正在分析 \(progress.done) / \(progress.total)"
    }

    // MARK: - 汇总区

    private func summarySection(_ result: TidyScanResult) -> some View {
        Section {
            Picker("精细程度", selection: $aggressiveness) {
                ForEach(TidyScanAggressiveness.allCases) { level in
                    Text(level.title).tag(level)
                }
            }
            .pickerStyle(.menu)

            Toggle("显示被保护的照片", isOn: $showsProtected)

            LabeledContent("已分析", value: "\(result.scannedCount) 张")
            if result.skippedCount > 0 {
                LabeledContent("未分析", value: "\(result.skippedCount) 张（iCloud）")
            }
            LabeledContent("建议清理", value: "\(visibleCandidates(result).count) 项")
            LabeledContent("可释放", value: ByteSizeText.full(visibleBytes(result)))

            let judged = judgedCount(result)
            if judged > 0 {
                LabeledContent("已判定") {
                    Text("\(judged) 项中标错 \(misjudgedCount(result)) 项")
                        .foregroundStyle(Color.tidyMuted)
                }
                LabeledContent("整体准确率") {
                    Text(accuracyText(correct: judged - misjudgedCount(result), total: judged))
                        .font(.body.bold())
                        .foregroundStyle(Color.tidyAccent)
                }
            }
        } header: {
            Text("结果")
        } footer: {
            Text("点一下缩略图标记「这张判错了」，长按可以看对比详情。准确率按当前精细程度下可见的候选统计。")
        }
    }

    // MARK: - 分类区

    private func reasonSection(_ reason: TidyScanReason, in result: TidyScanResult) -> some View {
        let items = visibleCandidates(result).filter { $0.reason == reason }
        let wrong = items.filter { misjudged.contains($0.assetIdentifier) }.count
        let bytes = items.reduce(Int64(0)) { $0 + $1.bytes }

        return Section {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(items) { candidate in
                    TidyScanCandidateCell(
                        candidate: candidate,
                        isMisjudged: misjudged.contains(candidate.assetIdentifier)
                    )
                    .onTapGesture { toggleMisjudged(candidate) }
                    .onLongPressGesture { comparison = candidate }
                }
            }
            .padding(.vertical, 4)
        } header: {
            HStack {
                Label("\(reason.title) · \(items.count) 项", systemImage: reason.symbol)
                Spacer()
                if wrong > 0 {
                    Text(accuracyText(correct: items.count - wrong, total: items.count))
                        .foregroundStyle(.red)
                }
            }
        } footer: {
            Text("\(reason.explanation) · 可释放 \(ByteSizeText.full(bytes))")
        }
    }

    // MARK: - 逻辑

    @MainActor
    private func runScan() async {
        isScanning = true
        progress = nil
        misjudged = []
        result = nil

        var configuration = TidyScanEngine.Configuration()
        configuration.scanLimit = scanLimit
        configuration.nearDuplicateDistance = nearDuplicateDistance

        let scanned = await TidyScanEngine.scan(configuration: configuration) { done, total in
            progress = (done, total)
        }

        result = scanned
        progress = nil
        isScanning = false
    }

    private func toggleMisjudged(_ candidate: TidyScanCandidate) {
        if misjudged.contains(candidate.assetIdentifier) {
            misjudged.remove(candidate.assetIdentifier)
        } else {
            misjudged.insert(candidate.assetIdentifier)
        }
    }

    private func visibleCandidates(_ result: TidyScanResult) -> [TidyScanCandidate] {
        result.filtered(for: aggressiveness, includingProtected: showsProtected)
    }

    private func visibleBytes(_ result: TidyScanResult) -> Int64 {
        visibleCandidates(result).reduce(0) { $0 + $1.bytes }
    }

    private func orderedReasons(in result: TidyScanResult) -> [TidyScanReason] {
        let present = Set(visibleCandidates(result).map(\.reason))
        return TidyScanReason.allCases.filter { present.contains($0) }
    }

    /// 只要标过一次错，就认为这一批已经过目；未标记的默认算判对。
    private func judgedCount(_ result: TidyScanResult) -> Int {
        misjudged.isEmpty ? 0 : visibleCandidates(result).count
    }

    private func misjudgedCount(_ result: TidyScanResult) -> Int {
        visibleCandidates(result).filter { misjudged.contains($0.assetIdentifier) }.count
    }

    private func accuracyText(correct: Int, total: Int) -> String {
        guard total > 0 else { return "—" }
        return String(format: "%.0f%%", Double(correct) / Double(total) * 100)
    }
}

// MARK: - 候选单元格

private struct TidyScanCandidateCell: View {
    let candidate: TidyScanCandidate
    let isMisjudged: Bool

    var body: some View {
        VStack(spacing: 0) {
            TidyScanThumbnail(assetIdentifier: candidate.assetIdentifier)
                .aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    if isMisjudged {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white, .red)
                            .padding(4)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    Text(String(format: "%.2f", candidate.score))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(4)
                }

            if candidate.isProtected {
                Text(candidate.protections.labels.joined(separator: " · "))
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.tidyAmber)
                    .lineLimit(1)
                    .padding(.top, 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isMisjudged ? Color.red : Color.clear, lineWidth: 2)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - 对比详情

/// 成组判断最容易出问题的地方是「留错了那张」，所以要能并排看到保留的和建议删的。
private struct TidyScanComparisonView: View {
    let candidate: TidyScanCandidate

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    if let keptIdentifier = candidate.keptIdentifier {
                        labeledImage("替你保留", identifier: keptIdentifier, tint: .tidyKeep)
                    }
                    labeledImage("建议清理", identifier: candidate.assetIdentifier, tint: .red)
                }

                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("归因", value: candidate.reason.title)
                    LabeledContent("可删分", value: String(format: "%.2f", candidate.score))
                    LabeledContent("体积", value: ByteSizeText.full(candidate.bytes))
                    if candidate.isProtected {
                        LabeledContent("保护规则", value: candidate.protections.labels.joined(separator: " · "))
                    }
                }
                .font(.system(size: 14, design: .rounded))

                Text(candidate.reason.explanation)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.tidyMuted)
            }
            .padding(20)
        }
        .background(Color.tidyBackground)
    }

    private func labeledImage(_ title: String, identifier: String, tint: Color) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
            TidyScanThumbnail(assetIdentifier: identifier, targetDimension: 600)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 缩略图

/// 验证台自带一个最小实现，不去动正式流程里的 ArtworkView。
private struct TidyScanThumbnail: View {
    let assetIdentifier: String
    var targetDimension: CGFloat = 240

    @State private var image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.tidySurface
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .task(id: assetIdentifier) {
            image = await load()
        }
    }

    private func load() async -> UIImage? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil)
        guard let asset = assets.firstObject else { return nil }

        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false

            var didResume = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: targetDimension, height: targetDimension),
                contentMode: .aspectFill,
                options: options
            ) { result, info in
                let isDegraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
                guard !isDegraded, !didResume else { return }
                didResume = true
                continuation.resume(returning: result)
            }
        }
    }
}
#endif

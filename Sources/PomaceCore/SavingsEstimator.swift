import Foundation

/// A file the estimator may sample. `size` is its physical (allocated) size.
public struct SampleCandidate: Sendable, Equatable {
    public let path: String
    public let size: Int64
    public init(path: String, size: Int64) { self.path = path; self.size = size }
}

/// What one compressor did to the sample.
public struct CompressorMeasurement: Sendable, Equatable {
    public let compressor: String
    /// Mean fraction of each sampled file's on-disk size that compression released.
    public let savedFraction: Double
    public init(compressor: String, savedFraction: Double) {
        self.compressor = compressor; self.savedFraction = savedFraction
    }
}

/// A prediction of what compressing a folder's eligible files would reclaim.
public struct SavingsEstimate: Sendable, Equatable {
    public let measurements: [CompressorMeasurement]
    public let recommendedCompressor: String
    public let sampleFiles: Int
    /// On-disk bytes that were copied and compressed, per compressor.
    public let sampleBytes: Int64
    /// The on-disk size of the eligible files the estimate extrapolates to.
    public let eligibleBytes: Int64

    public func estimatedReclaim(for compressor: String) -> Int64? {
        measurements.first { $0.compressor == compressor }
            .map { Int64(($0.savedFraction * Double(eligibleBytes)).rounded()) }
    }

    public var recommendedReclaim: Int64 { estimatedReclaim(for: recommendedCompressor) ?? 0 }
}

/// Measures a folder's compressibility on temporary copies of a sample of its files.
///
/// This is the per-directory measurement ADR-0010 calls for and the sampling estimator on
/// the 1.2 roadmap. The user's files are only ever read: a size-weighted sample is copied
/// (at most `maxBytesPerFile` from each) into a private temporary directory on the same
/// volume, compressed there with each available compressor exactly as a real run would
/// (`--verify` and the Automatic threshold), measured with `FileInspector`, and deleted.
///
/// Sampling is proportional to size, without replacement, and the per-file saved
/// fractions are averaged. That makes the estimate an unbiased predictor of the
/// byte-weighted saving, which is what reclaimed space is. Its accuracy against real runs
/// still has to be checked before it is treated as more than an estimate (ROADMAP 1.2).
public enum SavingsEstimator {

    public static let maxSampleFiles = 120
    public static let maxSampleBytes: Int64 = 96 * 1024 * 1024
    public static let maxBytesPerFile: Int64 = 8 * 1024 * 1024

    /// Another compressor must save at least this much more of the sample than LZFSE to be
    /// recommended over it. LZFSE reads fastest of the high-ratio options (DEFAULTS.md), so
    /// a marginal gain is not worth slower reads for the life of the files.
    public static let preferenceMargin = 0.03

    /// Weighted sampling without replacement (Efraimidis–Spirakis), within the budgets.
    public static func chooseSample<G: RandomNumberGenerator>(from candidates: [SampleCandidate],
                                                              using generator: inout G) -> [SampleCandidate] {
        let keyed: [(key: Double, candidate: SampleCandidate)] = candidates.compactMap { candidate in
            guard candidate.size > 0 else { return nil }
            // log(u)/w orders identically to u^(1/w) without underflowing for large w.
            let u = Double.random(in: Double.leastNonzeroMagnitude..<1, using: &generator)
            return (key: log(u) / Double(candidate.size), candidate: candidate)
        }
        var chosen: [SampleCandidate] = []
        var bytes: Int64 = 0
        for entry in keyed.sorted(by: { $0.key > $1.key }) {
            guard chosen.count < maxSampleFiles else { break }
            let copied = min(entry.candidate.size, maxBytesPerFile)
            if bytes + copied > maxSampleBytes { continue }
            chosen.append(entry.candidate)
            bytes += copied
        }
        return chosen
    }

    /// LZFSE unless another compressor beats it by `preferenceMargin`.
    public static func recommend(_ measurements: [CompressorMeasurement]) -> String? {
        guard let best = measurements.max(by: { $0.savedFraction < $1.savedFraction }) else { return nil }
        if best.compressor != "lzfse",
           let lzfse = measurements.first(where: { $0.compressor == "lzfse" }),
           best.savedFraction - lzfse.savedFraction < preferenceMargin {
            return "lzfse"
        }
        return best.compressor
    }

    public static func estimate(candidates: [SampleCandidate],
                                eligibleBytes: Int64,
                                root: String,
                                installation: ToolInstallation,
                                cancellation: CompressionCancellation? = nil,
                                logger: MutationLog? = nil,
                                runCompressor: @Sendable (String, [String]) -> Subprocess.Output = {
                                    Subprocess.capture($0, $1)
                                }) -> SavingsEstimate? {
        var generator = SystemRandomNumberGenerator()
        let sample = chooseSample(from: candidates, using: &generator)
        guard !sample.isEmpty, installation.capabilities.isUsable else { return nil }

        let fm = FileManager.default
        guard let workspace = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                          appropriateFor: URL(fileURLWithPath: root), create: true) else {
            return nil
        }
        defer { try? fm.removeItem(at: workspace) }

        let compressors = ["lzfse", "zlib", "lzvn"].filter { installation.capabilities.compressors.contains($0) }
        var measurements: [CompressorMeasurement] = []
        var sampledBytes: Int64 = 0

        for compressor in compressors {
            if Task.isCancelled || cancellation?.isRequested == true { return nil }
            let directory = workspace.appendingPathComponent(compressor, isDirectory: true)
            guard (try? fm.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return nil }

            // Copy the sample: (path of copy, on-disk size before compression).
            var copies: [(path: String, before: Int64)] = []
            for (index, file) in sample.enumerated() {
                let copy = directory.appendingPathComponent("\(index)").path
                guard copyPrefix(of: file.path, to: copy, limit: maxBytesPerFile),
                      let facts = FileInspector.inspect(copy), facts.physicalSize > 0 else { continue }
                copies.append((copy, facts.physicalSize))
            }
            guard !copies.isEmpty else { continue }
            // The basis figure describes the measured sample. Every compressor copies the
            // same sample set, but a copy can fail per compressor (a source file deleted
            // mid-estimate), so take the first successful round rather than letting the
            // last compressor's — possibly partial — total speak for all of them.
            if sampledBytes == 0 { sampledBytes = copies.reduce(0) { $0 + $1.before } }

            var settings = CompressionSettings()
            settings.compressor = compressor
            let arguments = CompressionPolicy.compressArguments(for: settings) + ["--"] + copies.map { $0.path }
            _ = runCompressor(installation.path, arguments)

            let fractions = copies.map { copy -> Double in
                let after = FileInspector.inspect(copy.path)?.physicalSize ?? copy.before
                return Double(max(0, copy.before - after)) / Double(copy.before)
            }
            let mean = fractions.reduce(0, +) / Double(fractions.count)
            measurements.append(CompressorMeasurement(compressor: compressor, savedFraction: mean))
        }

        guard let recommended = recommend(measurements) else { return nil }
        let summary = measurements.map { "\($0.compressor)=\(String(format: "%.3f", $0.savedFraction))" }
            .joined(separator: " ")
        logger?.note("estimate root=\(root) sample=\(sample.count) bytes=\(sampledBytes) \(summary) recommended=\(recommended)")
        return SavingsEstimate(measurements: measurements, recommendedCompressor: recommended,
                               sampleFiles: sample.count, sampleBytes: sampledBytes,
                               eligibleBytes: eligibleBytes)
    }

    /// Copies at most `limit` bytes. A prefix of a large file compresses like the file.
    static func copyPrefix(of source: String, to destination: String, limit: Int64) -> Bool {
        guard let input = FileHandle(forReadingAtPath: source) else { return false }
        defer { try? input.close() }
        guard let data = try? input.read(upToCount: Int(limit)), !data.isEmpty else { return false }
        return FileManager.default.createFile(atPath: destination, contents: data)
    }
}

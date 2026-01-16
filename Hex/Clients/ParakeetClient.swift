import Foundation
import AVFoundation
import HexCore

#if canImport(FluidAudio)
import FluidAudio

actor ParakeetClient {
  private var asr: AsrManager?
  private var nemotron: NemotronStreamingAsrManager?
  private var currentVariant: ParakeetModel?
  private let logger = HexLog.parakeet
  private let vendorDirs = [
    // Our app-specific cache path convention (under XDG or com.kitlangton.Hex/cache)
    "fluidaudio/Models",
    "FluidAudio/Models",
    // FluidAudio default under Application Support root
    "FluidAudio/Models"
  ]

  func isModelAvailable(_ modelName: String) async -> Bool {
    guard let variant = ParakeetModel(rawValue: modelName) else {
      logger.error("Unknown Parakeet variant requested: \(modelName)")
      return false
    }
    if currentVariant == variant {
      return isReady(variant: variant)
    }

    logger.debug("Checking Parakeet availability variant=\(variant.identifier)")
    for dir in modelDirectories(variant) {
      if directoryContainsMLModelC(dir) {
        logger.notice("Found Parakeet cache at \(dir.path)")
        return true
      }
    }
    logger.debug("No Parakeet cache detected variant=\(variant.identifier)")
    return false
  }

  private func directoryContainsMLModelC(_ dir: URL) -> Bool {
    let fm = FileManager.default
    guard fm.fileExists(atPath: dir.path) else { return false }
    if let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil) {
      for case let url as URL in en {
        let last = url.lastPathComponent
        if url.pathExtension == "mlmodelc" || last.hasSuffix(".mlmodelc") || last.hasSuffix(".mlpackage") { return true }
      }
    }
    return false
  }

  func ensureLoaded(modelName: String, progress: @escaping (Progress) -> Void) async throws {
    guard let variant = ParakeetModel(rawValue: modelName) else {
      throw NSError(
        domain: "Parakeet",
        code: -4,
        userInfo: [NSLocalizedDescriptionKey: "Unsupported Parakeet variant: \(modelName)"]
      )
    }
    if currentVariant == variant, isReady(variant: variant) { return }
    if currentVariant != variant {
      asr = nil
      nemotron = nil
    }
    let t0 = Date()
    logger.notice("Starting Parakeet load variant=\(variant.identifier)")
    let p = Progress(totalUnitCount: 100)
    p.completedUnitCount = 1
    progress(p)

    // Best-effort progress polling while FluidAudio downloads
    let fm = FileManager.default
    let support = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let faDir = support?.appendingPathComponent("FluidAudio/Models/\(variant.cacheFolderName)", isDirectory: true)
    let pollTask = Task {
      while p.completedUnitCount < 95 {
        try? await Task.sleep(nanoseconds: 250_000_000)
        if let dir = faDir, let size = directorySize(dir) {
          let target: Double = variant.downloadTargetBytes
          let frac = max(0.0, min(1.0, Double(size) / target))
          p.completedUnitCount = Int64(5 + frac * 90)
          progress(p)
        }
        if Task.isCancelled { break }
      }
    }
    defer { pollTask.cancel() }

    switch variant {
    case .nemotronStreaming:
      let modelDirectory = try await downloadNemotronModels()
      let manager = NemotronStreamingAsrManager(configuration: .init())
      try await manager.loadModels(modelDir: modelDirectory, encoderVariant: .int8)
      self.nemotron = manager
    case .englishV2, .multilingualV3:
      let models = try await AsrModels.downloadAndLoad(version: variant.asrVersion)
      let manager = AsrManager(config: .init())
      try await manager.initialize(models: models)
      self.asr = manager
    }

    self.currentVariant = variant
    p.completedUnitCount = 100
    progress(p)
    logger.notice("Parakeet ensureLoaded completed in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
  }

  private func directorySize(_ dir: URL) -> UInt64? {
    let fm = FileManager.default
    guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: .skipsHiddenFiles) else { return nil }
    var total: UInt64 = 0
    for case let url as URL in en {
      if let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), vals.isRegularFile == true {
        total &+= UInt64(vals.fileSize ?? 0)
      }
    }
    return total
  }

  private func isReady(variant: ParakeetModel) -> Bool {
    switch variant {
    case .nemotronStreaming:
      return nemotron != nil
    case .englishV2, .multilingualV3:
      return asr != nil
    }
  }

  func transcribe(_ url: URL) async throws -> String {
    guard let variant = currentVariant else {
      throw NSError(domain: "Parakeet", code: -1, userInfo: [NSLocalizedDescriptionKey: "Parakeet not initialized"])
    }
    let t0 = Date()
    logger.notice("Transcribing with Parakeet model=\(variant.identifier) file=\(url.lastPathComponent)")
    switch variant {
    case .nemotronStreaming:
      guard let nemotron else {
        throw NSError(domain: "Parakeet", code: -1, userInfo: [NSLocalizedDescriptionKey: "Nemotron not initialized"])
      }
      await nemotron.reset()
      let buffer = try await loadPCMBuffer(from: url)
      _ = try await nemotron.process(audioBuffer: buffer)
      let text = try await nemotron.finish()
      logger.info("Nemotron transcription finished in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
      return text
    case .englishV2, .multilingualV3:
      guard let asr else {
        throw NSError(domain: "Parakeet", code: -1, userInfo: [NSLocalizedDescriptionKey: "Parakeet not initialized"])
      }
      let result = try await asr.transcribe(url)
      logger.info("Parakeet transcription finished in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
      return result.text
    }
  }

  // Delete cached Parakeet models from known locations and reset state
  func deleteCaches(modelName: String) async throws {
    guard let variant = ParakeetModel(rawValue: modelName) else { return }
    let fm = FileManager.default

    var removedAny = false
    for dir in modelDirectories(variant) {
      if fm.fileExists(atPath: dir.path) {
        try? fm.removeItem(at: dir)
        removedAny = true
      }
    }

    // Reset live objects so a future download can proceed cleanly
    if removedAny {
      self.asr = nil
      self.nemotron = nil
      if currentVariant == variant {
        currentVariant = nil
      }
    }
  }

  /// Returns all candidate directories where a Parakeet model might be cached.
  /// Includes both exact matches and prefixed directories (e.g. versioned folders).
  private func modelDirectories(_ variant: ParakeetModel) -> [URL] {
    let fm = FileManager.default
    var result: [URL] = []

    for root in candidateRoots() {
      for vendor in vendorDirs {
        let base = root.appendingPathComponent(vendor, isDirectory: true)
        // Exact match directory
        let direct = base.appendingPathComponent(variant.cacheFolderName, isDirectory: true)
        result.append(direct)
        // Prefixed directories (e.g. versioned folders)
        if let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
          for item in items where item.lastPathComponent.hasPrefix(variant.cacheFolderName) && item != direct {
            result.append(item)
          }
        }
      }
    }
    return result
  }

  private func candidateRoots() -> [URL] {
    let fm = FileManager.default
    let xdg = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].flatMap { URL(fileURLWithPath: $0, isDirectory: true) }
    let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    let appCache = appSupport?.appendingPathComponent("com.kitlangton.Hex/cache", isDirectory: true)
    let userCache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache", isDirectory: true)
    return [xdg, appCache, appSupport, userCache].compactMap { $0 }
  }

  private func downloadNemotronModels() async throws -> URL {
    let appSupport = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let baseDir = appSupport.appendingPathComponent("FluidAudio/Models", isDirectory: true)
    let repo = Repo.nemotronStreaming
    let subpath = ParakeetModel.nemotronStreaming.cacheFolderName
    let nestedDir = baseDir.appendingPathComponent(subpath, isDirectory: true)

    let decoderPath = nestedDir.appendingPathComponent("decoder.mlmodelc")
    let encoderPath = nestedDir.appendingPathComponent("encoder/encoder_int8.mlmodelc")
    
    if FileManager.default.fileExists(atPath: decoderPath.path),
       FileManager.default.fileExists(atPath: encoderPath.path)
    {
      return nestedDir
    }

    let remoteSubpath = ParakeetModel.nemotronStreaming.remoteSubpath
    logger.info("Nemotron models missing or incomplete; downloading from HuggingFace remoteSubpath=\(remoteSubpath)")
    try await downloadNemotronSubpath(repo: repo, baseDir: baseDir, remoteSubpath: remoteSubpath, localSubpath: subpath)

    if FileManager.default.fileExists(atPath: decoderPath.path),
       FileManager.default.fileExists(atPath: encoderPath.path)
    {
      return nestedDir
    }

    throw CocoaError(
      .fileNoSuchFile,
      userInfo: [NSLocalizedDescriptionKey: "Nemotron models missing after download (checked decoder and encoder)"]
    )
  }

  private func downloadNemotronSubpath(repo: Repo, baseDir: URL, remoteSubpath: String, localSubpath: String) async throws {
    let baseURL = ModelRegistry.baseURL
    let repoPath = repo.remotePath
    let targetDir = baseDir.appendingPathComponent(localSubpath, isDirectory: true)
    try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

    let token = ProcessInfo.processInfo.environment["HF_TOKEN"]
      ?? ProcessInfo.processInfo.environment["HUGGING_FACE_HUB_TOKEN"]
      ?? ProcessInfo.processInfo.environment["HUGGINGFACEHUB_API_TOKEN"]

    func authorizedRequest(_ url: URL) -> URLRequest {
      var request = URLRequest(url: url)
      if let token {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      }
      return request
    }

    guard let treeURL = URL(string: "\(baseURL)/api/models/\(repoPath)/tree/main/\(remoteSubpath)?recursive=1") else {
      throw CocoaError(
        .fileReadCorruptFile,
        userInfo: [NSLocalizedDescriptionKey: "Invalid Nemotron subpath URL"]
      )
    }

    let (data, response) = try await DownloadUtils.sharedSession.data(for: authorizedRequest(treeURL))
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw CocoaError(
        .fileReadCorruptFile,
        userInfo: [NSLocalizedDescriptionKey: "Failed to list Nemotron model files"]
      )
    }

    let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
    let files = items.filter { ($0["type"] as? String) == "file" }

    for item in files {
      guard let path = item["path"] as? String else { continue }
      let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
      let fileURL = try ModelRegistry.resolveModel(repoPath, encodedPath)
      let request = authorizedRequest(fileURL)
      let (tempFileURL, fileResponse) = try await DownloadUtils.sharedSession.download(for: request)
      guard let fileHttp = fileResponse as? HTTPURLResponse, (200..<300).contains(fileHttp.statusCode) else {
        throw CocoaError(
          .fileReadCorruptFile,
          userInfo: [NSLocalizedDescriptionKey: "Failed to download Nemotron file: \(path)"]
        )
      }

      let relative = path.replacingOccurrences(of: "\(remoteSubpath)/", with: "")
      let destination = targetDir.appendingPathComponent(relative)
      try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: destination.path) {
        try? FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.moveItem(at: tempFileURL, to: destination)
    }
  }

  private func loadPCMBuffer(from url: URL) async throws -> AVAudioPCMBuffer {
    let file = try AVAudioFile(forReading: url)
    let frameCount = AVAudioFrameCount(file.length)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
      throw NSError(domain: "Parakeet", code: -5, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate audio buffer"]) }
    try file.read(into: buffer)
    return buffer
  }
}

private extension ParakeetModel {
  var asrVersion: AsrModelVersion {
    switch self {
    case .englishV2: return .v2
    case .multilingualV3: return .v3
    case .nemotronStreaming: return .v3
    }
  }
}

#else

actor ParakeetClient {
  func isModelAvailable(_ modelName: String) async -> Bool { false }
  func ensureLoaded(modelName: String, progress: @escaping (Progress) -> Void) async throws {
    throw NSError(
      domain: "Parakeet",
      code: -2,
      userInfo: [NSLocalizedDescriptionKey: "Parakeet support not linked. Add Swift Package: https://github.com/FluidInference/FluidAudio.git and link FluidAudio to Hex."]
    )
  }
  func transcribe(_ url: URL) async throws -> String { throw NSError(domain: "Parakeet", code: -3, userInfo: [NSLocalizedDescriptionKey: "Parakeet not available"]) }
  func deleteCaches(modelName: String) async throws {}
}

#endif

import AppKit
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import Vision

/// The shelf's instant actions — Dropover's and Dropzone's verbs, all on
/// this Mac: Compress with `ditto` (Finder's own zip), Copy Text read by
/// Vision on-device or from a PDF's own text, Convert an image between
/// PNG and JPEG with ImageIO, and Copy to… or Move to… a folder. Nothing
/// is ever overwritten: every new file takes a free name the way Finder
/// does ("report.pdf 2.zip"), and a name taken meanwhile is skipped past
/// rather than replaced.
enum ShelfActions {
    enum ActionError: LocalizedError {
        case nothingToDo
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .nothingToDo: return "none of the files is here any more"
            case .failed(let why): return why
            }
        }
    }

    enum ImageFormat: String, CaseIterable, Sendable {
        case png, jpeg

        var type: UTType { self == .png ? .png : .jpeg }
        var fileExtension: String { self == .png ? "png" : "jpg" }
        var title: String { self == .png ? "PNG" : "JPEG" }

        /// Whether `url` is already this format, by its name: a PNG is
        /// never offered or made into a PNG.
        func holds(_ url: URL) -> Bool {
            UTType(filenameExtension: url.pathExtension)?.conforms(to: type) == true
        }
    }

    // MARK: Names

    /// The `n`th free-name candidate for `base` + `ext` in Finder's
    /// style: "base.ext", then "base 2.ext", "base 3.ext", …
    nonisolated static func candidate(_ base: String, ext: String?, attempt: Int) -> String {
        let stem = attempt <= 1 ? base : "\(base) \(attempt)"
        guard let ext, !ext.isEmpty else { return stem }
        return "\(stem).\(ext)"
    }

    /// Move `file` into `folder` under the first free name — the rename
    /// fails rather than replaces when a name is taken, so a file that
    /// appears between the check and the move is never overwritten.
    nonisolated static func place(_ file: URL, in folder: URL, base: String, ext: String?,
                                  copy: Bool = false,
                                  fileManager: FileManager = .default) throws -> URL {
        for attempt in 1...500 {
            let target = folder.appendingPathComponent(candidate(base, ext: ext, attempt: attempt))
            if fileManager.fileExists(atPath: target.path) { continue }
            do {
                if copy {
                    try fileManager.copyItem(at: file, to: target)
                } else {
                    try fileManager.moveItem(at: file, to: target)
                }
                return target
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw ActionError.failed("no free name for \(base) in \(folder.lastPathComponent)")
    }

    // MARK: Compress

    /// A zip of `urls` beside the first of them, made by `ditto -c -k
    /// --sequesterRsrc --keepParent` (Finder's Compress): one file keeps
    /// its own name ("report.pdf.zip"), several go into "Archive.zip"
    /// through a staging folder of APFS clones, which take no room.
    nonisolated static func compress(_ urls: [URL], fileManager: FileManager = .default) async throws -> URL {
        guard let first = urls.first else { throw ActionError.nothingToDo }
        let folder = first.deletingLastPathComponent()
        let work = fileManager.temporaryDirectory
            .appendingPathComponent("jrbar-shelf-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }
        let source: URL
        let base: String
        if urls.count == 1 {
            source = first
            base = first.lastPathComponent
        } else {
            source = work.appendingPathComponent("Archive", isDirectory: true)
            try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
            for url in urls {
                let name = url.deletingPathExtension().lastPathComponent
                let ext = url.pathExtension.isEmpty ? nil : url.pathExtension
                _ = try place(url, in: source, base: name, ext: ext, copy: true, fileManager: fileManager)
            }
            base = "Archive"
        }
        let zip = work.appendingPathComponent("out.zip")
        try await run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, zip.path])
        return try place(zip, in: folder, base: base, ext: "zip", fileManager: fileManager)
    }

    /// Run a tool to its end off the main thread; a non-zero exit is an
    /// error carrying what the tool said.
    nonisolated static func run(_ tool: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            process.terminationHandler = { finished in
                let said = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let why = said.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: ActionError.failed(why.isEmpty ? "\(tool) failed" : why))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: Copy Text

    /// Whether Copy Text has something to read in `url`: an image, a
    /// PDF, or a text file.
    nonisolated static func hasText(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .pdf) || type.conforms(to: .text)
    }

    /// The text in a file: a PDF's own text layer, the words Vision
    /// reads in an image (on this Mac; nothing is sent anywhere), or a
    /// text file's contents. nil when there is none.
    nonisolated static func text(of url: URL) throws -> String? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        let raw: String?
        if type.conforms(to: .pdf) {
            raw = PDFDocument(url: url)?.string
        } else if type.conforms(to: .image) {
            raw = try recognizeText(in: url)
        } else if type.conforms(to: .text) {
            raw = try String(contentsOf: url, encoding: .utf8)
        } else {
            raw = nil
        }
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// Vision's accurate recognizer over the image, line by line in
    /// reading order.
    nonisolated static func recognizeText(in url: URL) throws -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: Convert

    nonisolated static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    /// The image re-encoded as PNG or JPEG beside the original, under a
    /// free name ("photo.png", "photo 2.png"); the original stays. An
    /// image already in that format is left alone.
    nonisolated static func convert(_ url: URL, to format: ImageFormat,
                                    fileManager: FileManager = .default) throws -> URL {
        guard !format.holds(url) else {
            throw ActionError.failed("\(url.lastPathComponent) is already a \(format.title)")
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ActionError.failed("\(url.lastPathComponent) isn't an image ImageIO can read")
        }
        let staged = fileManager.temporaryDirectory
            .appendingPathComponent("jrbar-shelf-\(UUID().uuidString).\(format.fileExtension)")
        defer { try? fileManager.removeItem(at: staged) }
        guard let destination = CGImageDestinationCreateWithURL(
            staged as CFURL, format.type.identifier as CFString, 1, nil) else {
            throw ActionError.failed("ImageIO can't write \(format.title)")
        }
        let properties: [CFString: Any] = format == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: 0.9] : [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ActionError.failed("ImageIO couldn't finish the \(format.title)")
        }
        return try place(staged, in: url.deletingLastPathComponent(),
                         base: url.deletingPathExtension().lastPathComponent,
                         ext: format.fileExtension, fileManager: fileManager)
    }

    // MARK: Copy to, move to

    /// What a Copy to… or Move to… did: the (old, new) pairs that landed,
    /// and why the first file that didn't failed. Files before a failure
    /// have already gone, so their pairs are kept, never lost with it.
    struct Transfer: Sendable {
        var landed: [(from: URL, to: URL)] = []
        var failure: String?
    }

    /// Copy or move each file into `folder` under a free name, stopping
    /// at the first that fails.
    nonisolated static func transfer(_ urls: [URL], to folder: URL, move: Bool,
                                     fileManager: FileManager = .default) -> Transfer {
        var result = Transfer()
        for url in urls {
            let ext = url.pathExtension.isEmpty ? nil : url.pathExtension
            do {
                let landed = try place(url, in: folder, base: url.deletingPathExtension().lastPathComponent,
                                       ext: ext, copy: !move, fileManager: fileManager)
                result.landed.append((url, landed))
            } catch {
                result.failure = error.localizedDescription
                break
            }
        }
        return result
    }

    /// Convert each image not already in `format`; returns what was made
    /// and the last failure, if any.
    nonisolated static func convert(_ urls: [URL], to format: ImageFormat,
                                    fileManager: FileManager = .default) -> (made: [URL], failure: String?) {
        var made: [URL] = []
        var failure: String?
        for url in urls where isImage(url) && !format.holds(url) {
            do {
                made.append(try convert(url, to: format, fileManager: fileManager))
            } catch {
                failure = error.localizedDescription
            }
        }
        return (made, failure)
    }

    /// The folder picker for Copy to… and Move to….
    @MainActor
    static func chooseFolder(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// The verbs as the shelf runs them: each acts on the chip's files — or
/// on the whole selection when the chip is part of one — and says what
/// happened in the line under the strip.
extension ShelfTrayModel {
    /// Compress: the zip lands beside the files and on the shelf.
    func compress(_ entries: [ShelfEntry]) {
        let urls = presentURLs(of: entries)
        guard !urls.isEmpty else { return }
        Task { [weak self] in
            do {
                let zip = try await ShelfActions.compress(urls)
                self?.add([zip])
                self?.actionNotice = "Compressed into \(zip.lastPathComponent)"
            } catch {
                self?.actionNotice = "Couldn't compress: \(error.localizedDescription)"
            }
        }
    }

    /// Copy Text: every file's text, joined, on the pasteboard.
    func copyText(_ entries: [ShelfEntry], to board: NSPasteboard = .general) {
        let urls = presentURLs(of: entries).filter(ShelfActions.hasText)
        guard !urls.isEmpty else { return }
        Task { [weak self] in
            let texts = await Task.detached(priority: .userInitiated) {
                urls.compactMap { try? ShelfActions.text(of: $0) }
            }.value
            guard !texts.isEmpty else {
                self?.actionNotice = urls.count == 1 ? "No text found in \(urls[0].lastPathComponent)"
                    : "No text found in those files"
                return
            }
            board.clearContents()
            board.setString(texts.joined(separator: "\n\n"), forType: .string)
            self?.actionNotice = texts.count == 1 ? "Copied the text" : "Copied the text of \(texts.count) files"
        }
    }

    /// Convert: each image not already in `format` re-encoded beside
    /// itself, off the main thread, then shelved.
    func convert(_ entries: [ShelfEntry], to format: ShelfActions.ImageFormat) {
        let urls = presentURLs(of: entries).filter { ShelfActions.isImage($0) && !format.holds($0) }
        guard !urls.isEmpty else { return }
        _ = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                ShelfActions.convert(urls, to: format)
            }.value
            self?.finishConvert(made: result.made, failure: result.failure, format: format)
        }
    }

    /// Convert's result, back on the main thread: the new files join the
    /// shelf and the line says what happened.
    func finishConvert(made: [URL], failure: String?, format: ShelfActions.ImageFormat) {
        if !made.isEmpty { add(made) }
        actionNotice = failure.map { "Couldn't convert: \($0)" }
            ?? (made.count == 1 ? "Saved \(made[0].lastPathComponent)" : "Saved \(made.count) \(format.title) files")
    }

    /// Copy to… or Move to…: a folder picked, the files carried there off
    /// the main thread, so a big copy to another disk never freezes the
    /// notch or the panel. A moved file's chip follows it to its new home.
    func transfer(_ entries: [ShelfEntry], move: Bool) {
        let urls = presentURLs(of: entries)
        guard !urls.isEmpty,
              let folder = ShelfActions.chooseFolder(prompt: move ? "Move Here" : "Copy Here") else { return }
        _ = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                ShelfActions.transfer(urls, to: folder, move: move)
            }.value
            self?.finishTransfer(result, to: folder, move: move)
        }
    }

    /// Copy to… or Move to…'s result, back on the main thread. Every file
    /// that landed before a failure keeps its chip — a moved one follows
    /// its file — and then the line names the failure.
    func finishTransfer(_ result: ShelfActions.Transfer, to folder: URL, move: Bool) {
        if move {
            for pair in result.landed { relocate(from: pair.from.path, to: pair.to.path) }
        }
        let verb = move ? "Moved" : "Copied"
        if let failure = result.failure {
            let done = result.landed.isEmpty ? "" : "\(verb) \(result.landed.count), then couldn't \(move ? "move" : "copy") the next: "
            actionNotice = done.isEmpty ? "Couldn't \(move ? "move" : "copy"): \(failure)" : done + failure
            return
        }
        let what = result.landed.count == 1 ? result.landed[0].to.lastPathComponent : "\(result.landed.count) files"
        actionNotice = "\(verb) \(what) to \(folder.lastPathComponent)"
    }
}

/// The verbs a shelf chip's menu offers for its files — the list is
/// pure, so the menu, its proof and the tests read the same one.
enum ShelfActionMenu {
    enum Verb: Hashable, Sendable {
        case compress, copyText, convert(ShelfActions.ImageFormat), copyTo, moveTo
    }

    /// Compress and the two folder verbs always; Copy Text when a file
    /// has text to read; a conversion only when some picked image is not
    /// already in that format.
    nonisolated static func verbs(for urls: [URL]) -> [Verb] {
        var verbs: [Verb] = [.compress]
        if urls.contains(where: ShelfActions.hasText) { verbs.append(.copyText) }
        let images = urls.filter(ShelfActions.isImage)
        for format in ShelfActions.ImageFormat.allCases where images.contains(where: { !format.holds($0) }) {
            verbs.append(.convert(format))
        }
        return verbs + [.copyTo, .moveTo]
    }

    nonisolated static func title(_ verb: Verb, count: Int) -> String {
        switch verb {
        case .compress: return count > 1 ? "Compress \(count) Items" : "Compress"
        case .copyText: return "Copy Text"
        case .convert(let format): return "Convert to \(format.title)"
        case .copyTo: return "Copy to…"
        case .moveTo: return "Move to…"
        }
    }
}

/// The action verbs as menu content, for a chip and for the selection it
/// belongs to.
@MainActor
struct ShelfActionMenuItems: View {
    let tray: ShelfTrayModel
    let targets: [ShelfTrayModel.ShelfEntry]

    var body: some View {
        let files = targets.flatMap(\.items).filter { !$0.missing }
        let verbs = ShelfActionMenu.verbs(for: files.map(\.url))
        ForEach(verbs, id: \.self) { verb in
            Button(ShelfActionMenu.title(verb, count: files.count)) { perform(verb) }
        }
        if tray.selectedIDs.count > 1 {
            Button("Deselect All") { tray.clearSelection() }
        }
    }

    private func perform(_ verb: ShelfActionMenu.Verb) {
        switch verb {
        case .compress: tray.compress(targets)
        case .copyText: tray.copyText(targets)
        case .convert(let format): tray.convert(targets, to: format)
        case .copyTo: tray.transfer(targets, move: false)
        case .moveTo: tray.transfer(targets, move: true)
        }
    }
}

import SwiftUI
import AppKit

@main
struct WasherApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 620, minHeight: 460)
        }
        .windowResizability(.contentSize)
    }
}

struct Finding: Identifiable {
    let id = UUID()
    let key: String
    let value: String
    var isSuspicious: Bool
}

@MainActor
final class WasherModel: ObservableObject {
    @Published var fileURL: URL?
    @Published var findings: [Finding] = []
    @Published var status = "Drop an image to inspect it"
    @Published var isScanning = false
    @Published var isWashing = false
    @Published var errorMessage: String?
    @Published var washedURL: URL?

    var canWash: Bool { fileURL != nil && !isScanning && !isWashing }

    func inspect(_ url: URL) {
        guard ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp"].contains(url.pathExtension.lowercased()) else {
            errorMessage = "Washer supports JPEG, PNG, HEIC, TIFF and WebP images."
            return
        }
        fileURL = url
        findings = []
        washedURL = nil
        errorMessage = nil
        status = "Scanning hidden metadata…"
        isScanning = true
        Task { [weak self] in
            do {
                let metadata = try Self.readMetadata(from: url)
                let results = metadata.flatMap { key, value in
                    let text = String(describing: value)
                    guard !text.isEmpty else { return [Finding]() }
                    let suspicious = Self.looksLikeCode(text) || Self.looksLikeCode(key)
                    return [Finding(key: key, value: text, isSuspicious: suspicious)]
                }.sorted { ($0.isSuspicious ? 0 : 1, $0.key) < ($1.isSuspicious ? 0 : 1, $1.key) }
                await MainActor.run {
                    self?.findings = results
                    self?.isScanning = false
                    self?.status = results.isEmpty ? "No readable metadata found" : "Review the metadata, then choose Wash"
                }
            } catch {
                await MainActor.run {
                    self?.isScanning = false
                    self?.errorMessage = error.localizedDescription
                    self?.status = "Couldn’t scan this image"
                }
            }
        }
    }

    func wash() {
        guard let fileURL else { return }
        isWashing = true
        errorMessage = nil
        status = "Removing metadata without re-encoding…"
        Task { [weak self] in
            do {
                let tool = try Self.findExifTool()
                let output = fileURL.deletingLastPathComponent().appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent + "-washed." + fileURL.pathExtension)
                if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
                let result = try Self.run(tool, arguments: ["-overwrite_original", "-o", output.path, "-all=", fileURL.path])
                guard result.status == 0, FileManager.default.fileExists(atPath: output.path) else { throw WasherError.commandFailed(result.output) }
                await MainActor.run {
                    self?.washedURL = output
                    self?.isWashing = false
                    self?.status = "Washed copy saved beside the original"
                }
            } catch {
                await MainActor.run {
                    self?.isWashing = false
                    self?.errorMessage = error.localizedDescription
                    self?.status = "Wash failed"
                }
            }
        }
    }

    private static func readMetadata(from url: URL) throws -> [String: Any] {
        let tool = try findExifTool()
        let result = try run(tool, arguments: ["-json", "-G1", "-a", "-u", "-s", url.path])
        guard result.status == 0 else { throw WasherError.commandFailed(result.output) }
        guard let data = result.output.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], let first = object.first else { return [:] }
        return first.filter { $0.key != "SourceFile" && !($0.value is NSNull) }
    }

    private static func looksLikeCode(_ value: String) -> Bool {
        let lower = value.lowercased()
        return ["javascript:", "<script", "<?php", "powershell", "cmd.exe", "os.system", "eval(", "base64", "prompt injection", "ignore previous", "#!/bin/"].contains { lower.contains($0) }
    }

    private static func findExifTool() throws -> String {
        let paths = ["/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool", "/usr/bin/exiftool"]
        if let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return path }
        throw WasherError.missingTool
    }

    private static func run(_ executable: String, arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process(); let outputPipe = Pipe(); let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = outputPipe; process.standardError = errorPipe
        try process.run()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let error = String(data: errorData, encoding: .utf8) ?? ""
        return (process.terminationStatus, process.terminationStatus == 0 ? output : (output + "\n" + error))
    }
}

enum WasherError: LocalizedError {
    case missingTool, commandFailed(String)
    var errorDescription: String? {
        switch self { case .missingTool: return "Washer needs ExifTool to remove metadata without recompressing the image. Install it with Homebrew, then reopen Washer."; case .commandFailed(let output): return output.isEmpty ? "ExifTool could not process this image." : output.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

struct ContentView: View {
    @StateObject private var model = WasherModel()
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) { Text("Washer").font(.system(size: 28, weight: .bold, design: .rounded)); Text("Inspect hidden image metadata, then wash it clean.").foregroundStyle(.secondary) }
                Spacer(); Image(systemName: "drop.fill").font(.system(size: 28)).foregroundStyle(.blue)
            }.padding(28)
            Divider()
            if model.fileURL == nil { dropZone }
            else { inspection }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in model.inspect(url) } } }
            return true
        }
        .alert("Washer", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(model.errorMessage ?? "") }
    }

    private var dropZone: some View {
        VStack(spacing: 16) { Image(systemName: "arrow.down.doc").font(.system(size: 46, weight: .light)).foregroundStyle(.blue); Text("Drop an image here").font(.title2.weight(.semibold)); Text("JPEG · PNG · HEIC · TIFF · WebP").foregroundStyle(.secondary); Text("Washer reads metadata first. Nothing changes until you choose Wash.").font(.footnote).foregroundStyle(.tertiary) }
            .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle()).padding(42).overlay(RoundedRectangle(cornerRadius: 18).stroke(isTargeted ? .blue : .gray.opacity(0.25), style: StrokeStyle(lineWidth: 2, dash: [8])).padding(24))
    }

    private var inspection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Image(systemName: "photo").foregroundStyle(.blue); Text(model.fileURL?.lastPathComponent ?? "Image").font(.headline); Spacer(); Button("Choose another") { model.fileURL = nil; model.findings = []; model.washedURL = nil; model.status = "Drop an image to inspect it" } }
            Text(model.status).font(.subheadline).foregroundStyle(.secondary)
            if model.isScanning { ProgressView().frame(maxWidth: .infinity, alignment: .center).padding(36) }
            else if model.findings.isEmpty { Text("No readable metadata found. The file may already be clean.").foregroundStyle(.secondary).padding(.vertical, 24) }
            else { ScrollView { VStack(alignment: .leading, spacing: 10) { ForEach(model.findings) { item in VStack(alignment: .leading, spacing: 3) { HStack { Text(item.key).font(.caption.weight(.bold)); if item.isSuspicious { Text("CODE-LIKE").font(.caption2.weight(.bold)).foregroundStyle(.orange) } }; Text(item.value).font(.system(.callout, design: .monospaced)).textSelection(.enabled).lineLimit(3) }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(item.isSuspicious ? Color.orange.opacity(0.1) : Color.gray.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 8)) } } }.frame(maxHeight: 245) }
            HStack { Spacer(); Button("Wash metadata") { model.wash() }.buttonStyle(.borderedProminent).disabled(!model.canWash || model.washedURL != nil) }
            if let washedURL = model.washedURL { Label(washedURL.path, systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green).textSelection(.enabled) }
        }.padding(28)
    }
}

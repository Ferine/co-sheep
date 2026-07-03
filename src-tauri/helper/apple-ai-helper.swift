// apple-ai-helper — on-device AI sidecar for co-sheep.
//
// Bridges the Rust backend to Apple's on-device foundation model
// (Apple Intelligence, FoundationModels framework) and to Vision OCR.
// The Tauri process spawns this binary per request and talks to it
// over stdin/stdout, since FoundationModels is a Swift-only API.
//
// Subcommands:
//   check     → prints {"available": bool, "reason": "..."}
//   ocr       → stdin: base64 JPEG          → stdout: recognized screen text
//   generate  → stdin: {"system","prompt","history"?} → stdout: model reply text
//               history is an optional [{"role": "human"|"sheep", "text": ...}]
//               list of prior turns, replayed as a native Transcript so the
//               model's chat template handles multi-turn structure itself
//
// `generate` needs macOS 26+ with Apple Intelligence enabled on Apple
// Silicon. `ocr` works on any supported macOS. The file still compiles
// against older SDKs — FoundationModels usage is gated so a helper built
// with pre-26 Xcode reports "builtWithoutFoundationModels" at runtime.

import CoreGraphics
import Foundation
import ImageIO
import Vision

#if canImport(FoundationModels)
import FoundationModels
#endif

struct HistoryTurn: Codable {
    let role: String
    let text: String
}

struct GenerateRequest: Codable {
    let system: String
    let prompt: String
    let history: [HistoryTurn]?
}

func readStdin() -> Data {
    FileHandle.standardInput.readDataToEndOfFile()
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func availability() -> (Bool, String) {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
        switch SystemLanguageModel.default.availability {
        case .available:
            return (true, "available")
        case .unavailable(let reason):
            return (false, String(describing: reason))
        }
    }
    return (false, "requiresMacOS26")
    #else
    return (false, "builtWithoutFoundationModels")
    #endif
}

func runOCR(base64: String) -> String {
    let trimmed = base64.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = Data(base64Encoded: trimmed, options: [.ignoreUnknownCharacters]) else {
        fail("ocr: invalid base64 input")
    }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fail("ocr: could not decode image")
    }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true

    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do {
        try handler.perform([request])
    } catch {
        fail("ocr: \(error)")
    }

    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    return lines.joined(separator: "\n")
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
func textSegment(_ content: String) -> Transcript.Segment {
    .text(Transcript.TextSegment(content: content))
}

@available(macOS 26.0, *)
func runGenerate(system: String, prompt: String, history: [HistoryTurn]) async -> String {
    let session: LanguageModelSession
    if history.isEmpty {
        session = LanguageModelSession(instructions: system)
    } else {
        // Rebuild the conversation as a native Transcript — the model's own
        // chat template then owns turn structure, which a small model handles
        // far better than history folded into prose
        var entries: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(segments: [textSegment(system)], toolDefinitions: []))
        ]
        for turn in history {
            if turn.role == "sheep" {
                entries.append(.response(Transcript.Response(assetIDs: [], segments: [textSegment(turn.text)])))
            } else {
                entries.append(.prompt(Transcript.Prompt(segments: [textSegment(turn.text)])))
            }
        }
        session = LanguageModelSession(transcript: Transcript(entries: entries))
    }
    do {
        let response = try await session.respond(to: prompt)
        return response.content
    } catch {
        fail("generate: \(error)")
    }
}
#endif

@main
struct AppleAIHelper {
    static func main() async {
        let command = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "check"

        switch command {
        case "check":
            let (ok, reason) = availability()
            print("{\"available\": \(ok), \"reason\": \"\(reason)\"}")

        case "ocr":
            guard let b64 = String(data: readStdin(), encoding: .utf8) else {
                fail("ocr: stdin was not UTF-8")
            }
            print(runOCR(base64: b64))

        case "generate":
            guard let request = try? JSONDecoder().decode(GenerateRequest.self, from: readStdin()) else {
                fail("generate: expected JSON {\"system\": ..., \"prompt\": ...} on stdin")
            }
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                print(await runGenerate(system: request.system, prompt: request.prompt, history: request.history ?? []))
            } else {
                fail("generate: requires macOS 26 (Tahoe) or newer")
            }
            #else
            fail("generate: helper was built without the FoundationModels SDK (build with Xcode 26+)")
            #endif

        default:
            fail("unknown command: \(command) (expected check|ocr|generate)")
        }
    }
}

// NanoAppRuntime: run code-switching corpus utterances through the app's own FunASR-Nano path.
//
// Usage (from the repository root; needs Vendor/SherpaOnnx/Binaries, see the eval doc):
//   B=tmp_agent_output/asr-code-switching-eval/nano-app-runtime/build
//   swift build -c release -Xswiftc -enable-testing --package-path Tools/ASRCodeSwitchEval/NanoAppRuntime --scratch-path $B
//   X=$B/out/Products/Release/NanoAppRuntime   # new SwiftPM build layout
//   $X run --model MODEL_DIR --corpus CORPUS_DIR --output RUN_DIR \
//       [--subsets a,b] [--shard K/N] [--limit N] [--resume] [--cache DIR]
//   $X merge --output RUN_DIR SHARD_DIR...
//
// Recognition goes through MoMoSpeech.SherpaRuntime (FunASRNano.cpp / FunASRNanoCoreML.mm: n_aud slicing,
// centred LFR, repetition penalty 1.12 + no-repeat 5-gram, CoreML ANE) with the app's SpeechConfiguration()
// defaults (language automatic -> "", ITN on, 2 threads) and DownloadableSpeechModel.funASRNano(). Each
// utterance is the window core. Like SpeechEngine.recognizeArchive with continuousArchive (the iPhone
// app's setting), exact-zero samples at both ends are trimmed and all-zero input yields "".
// Speaker diarization re-decoding is not part of this harness.
//
// Output matches Tools/ASRCodeSwitchEval/models.py (hypotheses.jsonl + run.json), so score.py works unchanged.

import AVFoundation
import Darwin
import Foundation
import MoMoContracts
@testable import MoMoSpeech

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func peakRSSBytes() -> Int {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int(usage.ru_maxrss) // Bytes on macOS.
}

func readJSONLines(_ url: URL) -> [[String: Any]] {
    guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { line in
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }
}

func jsonLine(_ object: [String: Any]) -> Data {
    var data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    data.append(0x0A)
    return data
}

func writeJSON(_ object: [String: Any], to url: URL) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try! (data + Data("\n".utf8)).write(to: url, options: .atomic)
}

/// Same decoder the app uses for archive audio (AVAudioFile, Float32 processing format).
func readWave(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
        throw NSError(domain: "NanoAppRuntime", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected 16 kHz mono: \(url.path)"])
    }
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

func modelBytes(_ directory: URL) -> Int {
    let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
    var total = 0
    for case let url as URL in FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys))! {
        let values = try? url.resourceValues(forKeys: keys)
        if values?.isRegularFile == true, ["onnx", "txt", "json"].contains(url.pathExtension) { total += values?.fileSize ?? 0 }
    }
    return total
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail("usage: NanoAppRuntime run|merge ...") }
arguments.removeFirst()
var options: [String: String] = [:]
var flags: Set<String> = []
var positional: [String] = []
var index = 0
while index < arguments.count {
    let argument = arguments[index]
    if argument == "--resume" { flags.insert("resume") }
    else if argument.hasPrefix("--") {
        guard index + 1 < arguments.count else { fail("Missing value for \(argument)") }
        options[String(argument.dropFirst(2))] = arguments[index + 1]
        index += 1
    } else { positional.append(argument) }
    index += 1
}
func path(_ key: String) -> URL {
    guard let value = options[key] else { fail("Missing --\(key)") }
    return URL(fileURLWithPath: value).standardizedFileURL
}

if command == "merge" {
    // Concatenate shard outputs into one run directory and pool their timing.
    let output = path("output")
    guard !FileManager.default.fileExists(atPath: output.path) else { fail("Output directory must not exist: \(output.path)") }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    var rows = Data(), seen = Set<String>(), runs: [[String: Any]] = []
    for shard in positional.map({ URL(fileURLWithPath: $0) }) {
        for row in readJSONLines(shard.appendingPathComponent("hypotheses.jsonl")) {
            let uid = row["uid"] as! String
            guard seen.insert(uid).inserted else { fail("Duplicate \(uid) in \(shard.path)") }
            rows += jsonLine(row)
        }
        guard let data = try? Data(contentsOf: shard.appendingPathComponent("run.json")),
              let run = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { fail("Missing run.json in \(shard.path)") }
        runs.append(run)
    }
    try rows.write(to: output.appendingPathComponent("hypotheses.jsonl"))
    var merged = runs[0]
    let audio = runs.reduce(0.0) { $0 + ($1["audioSeconds"] as! Double) }
    let decode = runs.reduce(0.0) { $0 + ($1["decodeSeconds"] as! Double) }
    merged["shards"] = runs.map { ["shard": $0["shard"] ?? "", "rtf": $0["rtf"]!, "peakRSSBytes": $0["peakRSSBytes"]!,
                                   "utterances": $0["utterances"]!, "audioSeconds": $0["audioSeconds"]!] }
    merged["shard"] = "merged \(runs.count)"
    merged["utterances"] = seen.count
    merged["errors"] = runs.reduce(0) { $0 + ($1["errors"] as! Int) }
    merged["audioSeconds"] = audio
    merged["decodeSeconds"] = decode
    merged["rtf"] = decode / audio
    merged["rtfNote"] = "Pooled over concurrent shards; use a single-process run for RTF."
    merged["peakRSSBytes"] = runs.map { $0["peakRSSBytes"] as! Int }.max()!
    writeJSON(merged, to: output.appendingPathComponent("run.json"))
    print("merged \(seen.count) utterances into \(output.path)")
    exit(0)
}
guard command == "run" else { fail("Unknown command \(command)") }

let modelDirectory = path("model")
let corpus = path("corpus")
let output = path("output")
let cacheRoot = options["cache"].map { URL(fileURLWithPath: $0).standardizedFileURL }
    ?? output.appendingPathComponent("cache")
let subsets = options["subsets"].map { Set($0.split(separator: ",").map(String.init)) }
let limit = options["limit"].map { Int($0)! }
let shard: (index: Int, count: Int)? = options["shard"].map {
    let parts = $0.split(separator: "/").map { Int($0)! }
    return (parts[0], parts[1])
}
let resume = flags.contains("resume")

if FileManager.default.fileExists(atPath: output.path), !resume { fail("Output directory must not exist: \(output.path)") }
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

var items = readJSONLines(corpus.appendingPathComponent("manifest.jsonl"))
if let subsets { items = items.filter { subsets.contains($0["subset"] as! String) } }
if let shard { items = items.enumerated().filter { $0.offset % shard.count == shard.index }.map(\.element) }
if let limit { items = Array(items.prefix(limit)) }
guard !items.isEmpty else { fail("No utterances selected") }

// Resume: keep complete lines only, then append.
let hypothesesURL = output.appendingPathComponent("hypotheses.jsonl")
var done: [String: [String: Any]] = [:]
if resume {
    let kept = readJSONLines(hypothesesURL)
    for row in kept { done[row["uid"] as! String] = row }
    try kept.reduce(Data()) { $0 + jsonLine($1) }.write(to: hypothesesURL, options: .atomic)
}
if !FileManager.default.fileExists(atPath: hypothesesURL.path) { FileManager.default.createFile(atPath: hypothesesURL.path, contents: nil) }

// App configuration: PhoneComposition uses SpeechConfiguration() (auto, ITN, 2 threads).
let configuration = try SpeechConfiguration()
let catalog = try DownloadableSpeechModel.funASRNano()
let download = DownloadedSpeechModel(directory: modelDirectory, catalog: catalog)
// SherpaRuntime only validates the SenseVoice bundle when no download is selected; Nano never reads it.
let placeholder = String(repeating: "0", count: 64)
let bundle = SpeechModelBundle(directory: modelDirectory,
    manifest: try SpeechModelManifest(asrSHA256: placeholder, tokensSHA256: placeholder, vadSHA256: placeholder))
let attempt = SpeechAttempt()
func recorder(_ id: String?) -> SpeechDiagnosticRecorder {
    SpeechDiagnosticRecorder(operation: .transcribe, attemptID: attempt.id, windowID: id, fingerprint: "nano-app-eval")
}

let rssBeforeLoad = peakRSSBytes()
var started = Date()
let loadRecorder = recorder(nil)
let runtime = try SherpaRuntime(bundle: bundle, configuration: configuration, backend: .sherpaCoreML, download: download,
                                cacheRoot: cacheRoot, attempt: attempt, recorder: loadRecorder)
try runtime.warmUp(attempt: attempt, recorder: loadRecorder) // As SpeechEngine.selectRecognitionModel does.
let loadSeconds = Date().timeIntervalSince(started)

/// SpeechEngine.recognizeArchive for Nano: core slice (= whole utterance here), then with
/// continuousArchive the exact-zero edges are trimmed; an all-zero core is not decoded.
func recognize(_ samples: [Float], id: String) throws -> String {
    guard let first = samples.firstIndex(where: { $0 != 0 }), let last = samples.lastIndex(where: { $0 != 0 }) else { return "" }
    return try runtime.recognizeBatch([.init(samples: Array(samples[first...last]), windowID: id)],
        fingerprint: "nano-app-eval", attempt: attempt, onEvent: { _ in }, recorder: recorder(id))[0].text
}

// One warm-up decode on the first utterance, excluded from RTF (same as models.py).
started = Date()
_ = try recognize(try readWave(corpus.appendingPathComponent(items[0]["audio"] as! String)), id: "warmup")
let warmupSeconds = Date().timeIntervalSince(started)

let seconds = Dictionary(uniqueKeysWithValues: items.map { ($0["uid"] as! String, $0["seconds"] as! Double) })
var totalAudio = done.keys.reduce(0.0) { $0 + (seconds[$1] ?? 0) }
var totalDecode = done.reduce(0.0) { $0 + (seconds[$1.key] != nil ? ($1.value["decodeSeconds"] as! Double) : 0) }
var errors = done.reduce(0) { $0 + (seconds[$1.key] != nil && ($1.value["status"] as! String) != "completed" ? 1 : 0) }
let handle = try FileHandle(forWritingTo: hypothesesURL)
try handle.seekToEnd()
var processed = 0
for item in items {
    let uid = item["uid"] as! String
    if done[uid] != nil { continue }
    var row: [String: Any] = ["uid": uid, "subset": item["subset"] as! String, "lang": ""]
    let samples: [Float]
    do { samples = try readWave(corpus.appendingPathComponent(item["audio"] as! String)) }
    catch { fail("Cannot read audio for \(uid): \(error)") }
    let start = Date()
    do {
        row["text"] = try recognize(samples, id: uid)
        row["status"] = "completed"
    } catch {
        errors += 1
        row["status"] = "error"; row["text"] = ""; row["error"] = String(describing: error)
    }
    row["decodeSeconds"] = Date().timeIntervalSince(start)
    totalDecode += row["decodeSeconds"] as! Double
    totalAudio += item["seconds"] as! Double
    try handle.write(contentsOf: jsonLine(row))
    processed += 1
    if processed % 50 == 0 {
        print("\(processed) decoded, rtf \(String(format: "%.3f", totalDecode / totalAudio)), rss \(peakRSSBytes() >> 20) MiB")
        fflush(stdout)
    }
}
try handle.close()

let summary: [String: Any] = [
    "model": "funasr-nano-app-runtime",
    "harness": "Tools/ASRCodeSwitchEval/NanoAppRuntime",
    "runtime": "MoMoSpeech.SherpaRuntime -> MoMoCreateFunASRNanoRuntime/MoMoTranscribeFunASRNano (runtimeTag funasr-nano-ort-cpu-naud-v2)",
    "settings": ["language": configuration.language, "nanoLanguagePrompt": SherpaRuntime.nanoLanguage(.automatic),
                 "useITN": configuration.useITN, "threads": configuration.threads, "backend": "sherpa (Nano always ORT CPU)",
                 "input": "whole utterance as window core; exact-zero edges trimmed (continuousArchive)",
                 "catalog": catalog.identifier, "catalogRevision": try catalog.revision] as [String: Any],
    "threads": configuration.threads, "provider": "cpu", "machine": "arm64", "platform": ProcessInfo.processInfo.operatingSystemVersionString,
    "modelDirectory": modelDirectory.path, "shard": options["shard"] ?? "", "subsets": (subsets.map { Array($0).sorted() } ?? []),
    "utterances": items.count, "resumedUtterances": done.count, "errors": errors,
    "audioSeconds": totalAudio, "decodeSeconds": totalDecode, "rtf": totalDecode / totalAudio,
    "loadSeconds": loadSeconds, "warmupSeconds": warmupSeconds,
    "peakRSSBytesBeforeLoad": rssBeforeLoad, "peakRSSBytes": peakRSSBytes(), "modelBytesOnDisk": modelBytes(modelDirectory)
]
runtime.close()
writeJSON(summary, to: output.appendingPathComponent("run.json"))
print("done \(items.count) utterances (\(done.count) resumed), errors \(errors), rtf \(String(format: "%.3f", totalDecode / totalAudio)), load \(String(format: "%.1f", loadSeconds)) s, peak RSS \(peakRSSBytes() >> 20) MiB")

// Apple's on-device speech recognition as a Noi engine.
//
// macOS 26 ships SpeechAnalyzer / SpeechTranscriber: Apple's own dictation
// model, running on the Neural Engine, no download, no network. It is the
// engine Talkify (github.com/tornikegomareli/Talkify) is built on, and it is
// fast. Here it is one more entry in the model list; the pipeline hands it
// the same 16 kHz mono float samples every other engine gets.
//
// The Rust side calls from a blocking worker thread. Swift's API is async, so
// each call runs a Task and waits on a semaphore — simple, and correct for a
// batch transcribe.

import AVFoundation
import Foundation
import Speech

private func duplicate(_ s: String) -> UnsafeMutablePointer<CChar>? {
    s.withCString { strdup($0) }
}

@available(macOS 26.0, *)
private enum AppleSpeech {
    /// Match a Handy language code ("en", "auto", "zh") to a locale the
    /// transcriber supports; falls back to the system locale.
    static func resolveLocale(_ tag: String) async -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        if tag.isEmpty || tag == "auto" {
            let current = Locale.current
            if supported.contains(where: { $0.identifier(.bcp47) == current.identifier(.bcp47) }) {
                return current
            }
            if let sameLang = supported.first(where: { $0.language.languageCode == current.language.languageCode }) {
                return sameLang
            }
            return supported.first ?? current
        }
        let wanted = Locale(identifier: tag)
        if let exact = supported.first(where: { $0.identifier(.bcp47) == wanted.identifier(.bcp47) }) {
            return exact
        }
        if let sameLang = supported.first(where: { $0.language.languageCode == wanted.language.languageCode }) {
            return sameLang
        }
        return Locale.current
    }

    /// Per-locale setup that does not change between calls: the resolved
    /// locale, whether assets are installed, and the analyzer's preferred
    /// format. Querying these cost more than the recognition itself.
    private struct Warm {
        let locale: Locale
        let format: AVAudioFormat?
    }
    private static var warmByTag: [String: Warm] = [:]
    private static let warmLock = NSLock()

    private static func warm(for tag: String, sourceFormat: AVAudioFormat) async throws -> Warm {
        warmLock.lock()
        let cached = warmByTag[tag]
        warmLock.unlock()
        if let cached { return cached }

        let locale = await resolveLocale(tag)
        let probe = SpeechTranscriber(locale: locale, preset: .transcription)
        // First use of a locale pulls its assets down once; afterwards it is
        // entirely local.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            try await request.downloadAndInstall()
        }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe])
        let w = Warm(locale: locale, format: format)
        warmLock.lock(); warmByTag[tag] = w; warmLock.unlock()
        return w
    }

    static func prepare(localeTag: String) async throws {
        guard let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false) else { return }
        _ = try await warm(for: localeTag, sourceFormat: f)
    }

    static func transcribe(samples: [Float], sampleRate: Double, localeTag: String) async throws -> String {
        guard let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw NSError(domain: "AppleSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad source format"])
        }
        let warm = try await warm(for: localeTag, sourceFormat: sourceFormat)
        let transcriber = SpeechTranscriber(locale: warm.locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Our samples → the analyzer's preferred format.
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw NSError(domain: "AppleSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not create audio buffer"]) }
        sourceBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            sourceBuffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        let targetFormat = warm.format ?? sourceFormat
        let buffer: AVAudioPCMBuffer
        if targetFormat == sourceFormat {
            buffer = sourceBuffer
        } else {
            guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                throw NSError(domain: "AppleSpeech", code: 2, userInfo: [NSLocalizedDescriptionKey: "no converter to \(targetFormat)"])
            }
            let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(samples.count) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                throw NSError(domain: "AppleSpeech", code: 3, userInfo: [NSLocalizedDescriptionKey: "could not create output buffer"])
            }
            var consumed = false
            var convError: NSError?
            converter.convert(to: out, error: &convError) { _, status in
                if consumed { status.pointee = .endOfStream; return nil }
                consumed = true
                status.pointee = .haveData
                return sourceBuffer
            }
            if let convError { throw convError }
            buffer = out
        }

        // Collect results concurrently with feeding input; the sequence ends
        // when the analyzer finishes.
        let collector = Task { () -> String in
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }

        let (input, builder) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: input)
        builder.yield(AnalyzerInput(buffer: buffer))
        builder.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@_cdecl("apple_speech_available")
public func apple_speech_available() -> Int32 {
    if #available(macOS 26.0, *) { return 1 }
    return 0
}

@_cdecl("apple_speech_transcribe")
public func apple_speech_transcribe(
    _ samples: UnsafePointer<Float>?, _ count: Int, _ sampleRate: Int32, _ locale: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    guard #available(macOS 26.0, *), let samples, count > 0 else { return nil }
    let audio = Array(UnsafeBufferPointer(start: samples, count: count))
    let tag = locale.map { String(cString: $0) } ?? ""
    let rate = Double(sampleRate)

    let done = DispatchSemaphore(value: 0)
    var out: String?
    Task.detached(priority: .userInitiated) {
        do {
            out = try await AppleSpeech.transcribe(samples: audio, sampleRate: rate, localeTag: tag)
        } catch {
            NSLog("[apple-speech] transcription failed: \(error)")
        }
        done.signal()
    }
    done.wait()
    return out.flatMap(duplicate)
}

/// Do the per-locale setup now, off the caller's thread, so the first real
/// transcription is as fast as the second. Fire and forget.
@_cdecl("apple_speech_prepare")
public func apple_speech_prepare(_ locale: UnsafePointer<CChar>?) {
    guard #available(macOS 26.0, *) else { return }
    let tag = locale.map { String(cString: $0) } ?? ""
    Task.detached(priority: .utility) {
        _ = try? await AppleSpeech.prepare(localeTag: tag)
    }
}

@_cdecl("apple_speech_free")
public func apple_speech_free(_ text: UnsafeMutablePointer<CChar>?) {
    if let text { free(text) }
}

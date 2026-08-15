// Stub for toolchains whose SDK predates macOS 26's SpeechAnalyzer.
import Foundation

@_cdecl("apple_speech_available")
public func apple_speech_available() -> Int32 { 0 }

@_cdecl("apple_speech_transcribe")
public func apple_speech_transcribe(
    _ samples: UnsafePointer<Float>?, _ count: Int, _ sampleRate: Int32, _ locale: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? { nil }

@_cdecl("apple_speech_prepare")
public func apple_speech_prepare(_ locale: UnsafePointer<CChar>?) {}

@_cdecl("apple_speech_free")
public func apple_speech_free(_ text: UnsafeMutablePointer<CChar>?) {
    if let text { free(text) }
}

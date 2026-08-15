#ifndef apple_speech_bridge_h
#define apple_speech_bridge_h

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// 1 when Apple's on-device SpeechAnalyzer is usable on this machine
// (macOS 26+, Apple Silicon), else 0.
int32_t apple_speech_available(void);

// Transcribe mono float32 PCM. `locale` is a BCP-47 tag ("en-US") or "" for
// the system locale. Returns a malloc'd UTF-8 string (free with
// apple_speech_free) or NULL on failure; the failure reason is logged.
// `vocabulary` is newline-separated names/terms to bias recognition toward, or "".
char* apple_speech_transcribe(const float* samples, size_t count, int32_t sample_rate, const char* locale, const char* vocabulary);

void apple_speech_free(char* text);

// Warm the engine for a locale ahead of the first transcription (async).
void apple_speech_prepare(const char* locale);

#ifdef __cplusplus
}
#endif

#endif /* apple_speech_bridge_h */

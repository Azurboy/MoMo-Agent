#include "MoMoSherpaBridge.h"
#include "CancelToken.hpp"
#include <cstdio>
#include <exception>
#include <new>

MoMoCancelToken *MoMoCreateCancelToken(void) {
  return new (std::nothrow) MoMoCancelToken();
}

void MoMoTriggerCancelToken(MoMoCancelToken *token) {
  if (token) token->Cancel();
}

void MoMoDestroyCancelToken(MoMoCancelToken *token) {
  delete token;
}

namespace {
void save_error(char *buffer, size_t capacity, const char *text) {
  if (buffer && capacity) std::snprintf(buffer, capacity, "%s", text);
}
}

const SherpaOnnxOfflineRecognizer *MoMoCreateOfflineRecognizer(
    const SherpaOnnxOfflineRecognizerConfig *config, char *error, size_t capacity) {
  try {
    auto result = SherpaOnnxCreateOfflineRecognizer(config);
    if (!result) save_error(error, capacity, "Invalid recognizer configuration");
    return result;
  } catch (const std::exception &exception) {
    save_error(error, capacity, exception.what());
  } catch (...) {
    save_error(error, capacity, "Native model initialization failed");
  }
  return nullptr;
}

int MoMoAcceptWaveform(const SherpaOnnxOfflineStream *stream, const float *samples,
                      int32_t count, char *error, size_t capacity) {
  try {
    if (!stream || !samples || count <= 0) return 0;
    SherpaOnnxAcceptWaveformOffline(stream, 16000, samples, count);
    return 1;
  } catch (const std::exception &exception) {
    save_error(error, capacity, exception.what());
  } catch (...) {
    save_error(error, capacity, "Native audio preparation failed");
  }
  return 0;
}

int MoMoDecodeOfflineStreams(const SherpaOnnxOfflineRecognizer *recognizer,
    const SherpaOnnxOfflineStream **streams, int32_t count, char *error, size_t capacity) {
  try {
    if (!recognizer || !streams || count <= 0) return 0;
    SherpaOnnxDecodeMultipleOfflineStreams(recognizer, streams, count);
    return 1;
  } catch (const std::exception &exception) {
    save_error(error, capacity, exception.what());
  } catch (...) {
    save_error(error, capacity, "Native recognition failed");
  }
  return 0;
}

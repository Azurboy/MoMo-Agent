#ifndef MOMO_SHERPA_BRIDGE_H
#define MOMO_SHERPA_BRIDGE_H
#include <stddef.h>
#include <SherpaOnnxC/sherpa-onnx/c-api/c-api.h>

#ifdef __cplusplus
extern "C" {
#endif
// C++ exceptions must not cross Swift's C ABI boundary.
const SherpaOnnxOfflineRecognizer *MoMoCreateOfflineRecognizer(
    const SherpaOnnxOfflineRecognizerConfig *config, char *error, size_t capacity);
int MoMoAcceptWaveform(const SherpaOnnxOfflineStream *stream, const float *samples,
                      int32_t count, char *error, size_t capacity);
int MoMoDecodeOfflineStreams(const SherpaOnnxOfflineRecognizer *recognizer,
    const SherpaOnnxOfflineStream **streams, int32_t count, char *error, size_t capacity);
typedef int (*MoMoCancelCallback)(const void *context);

typedef struct MoMoCancelToken MoMoCancelToken;
MoMoCancelToken *MoMoCreateCancelToken(void);
void MoMoTriggerCancelToken(MoMoCancelToken *token);
void MoMoDestroyCancelToken(MoMoCancelToken *token);

typedef struct MoMoFunASRNanoRuntime MoMoFunASRNanoRuntime;
typedef struct {
  char *text;
  char *raw_json;
} MoMoFunASRNanoResult;

MoMoFunASRNanoRuntime *MoMoCreateFunASRNanoRuntime(
    const char *encoder_adaptor_path, const char *llm_path,
    const char *embedding_path, const char *tokenizer_dir,
    int32_t num_threads, char *error, size_t error_capacity);
void MoMoDestroyFunASRNanoRuntime(MoMoFunASRNanoRuntime *runtime);
int32_t MoMoGetFunASRNanoAcceleratorMask(const MoMoFunASRNanoRuntime *runtime);
// Returns 1 on success, -2 if cancelled, 0 on error.
int MoMoTranscribeFunASRNano(
    MoMoFunASRNanoRuntime *runtime, const float *samples, int32_t sample_count,
    const char *language, int32_t use_itn,
    MoMoCancelCallback is_cancelled, const void *cancel_context,
    MoMoFunASRNanoResult **out_result, char *error, size_t error_capacity);
int MoMoTranscribeFunASRNanoCancellable(
    MoMoFunASRNanoRuntime *runtime, const float *samples, int32_t sample_count,
    const char *language, int32_t use_itn,
    MoMoCancelCallback is_cancelled, const void *cancel_context,
    MoMoCancelToken *cancel_token,
    MoMoFunASRNanoResult **out_result, char *error, size_t error_capacity);
void MoMoDestroyFunASRNanoResult(MoMoFunASRNanoResult *result);
char *MoMoCleanFunASRText(const char *raw_text);
void MoMoFreeCString(char *str);

typedef struct MoMoSpeakerRuntime MoMoSpeakerRuntime;
typedef struct {
  int32_t start_sample, end_sample, local_speaker, embedding_dim;
  float clean_seconds;
  float embedding[256];
} MoMoSpeakerTurn;
MoMoSpeakerRuntime *MoMoCreateSpeakerRuntime(const char *segmentation,
    const char *embedding, const char *provider, char *error, size_t capacity);
MoMoSpeakerRuntime *MoMoCreateSpeakerRuntimeWithThreads(const char *segmentation,
    const char *embedding, const char *provider, int32_t num_threads,
    char *error, size_t capacity);
void MoMoDestroySpeakerRuntime(MoMoSpeakerRuntime *runtime);
int32_t MoMoGetSpeakerEmbeddingDim(const MoMoSpeakerRuntime *runtime);
int32_t MoMoGetSpeakerAcceleratorMask(const MoMoSpeakerRuntime *runtime);
// Overlapping segmentation windows with permutation stitching.
// Returns >= 0 turn count on success, -2 if cancelled, -1 on error.
int MoMoAnalyzeSpeakers(MoMoSpeakerRuntime *runtime, const float *samples,
    int32_t count, MoMoCancelCallback is_cancelled, const void *cancel_context,
    MoMoSpeakerTurn *turns, int32_t capacity,
    char *error, size_t error_capacity);
int MoMoAnalyzeSpeakersWithProfiles(
    MoMoSpeakerRuntime *runtime, const float *samples, int32_t count,
    const float *enrolled_embeddings, const int32_t *enrolled_person_ids,
    int32_t enrolled_count,
    MoMoCancelCallback is_cancelled, const void *cancel_context,
    MoMoSpeakerTurn *turns, int32_t capacity,
    char *error, size_t error_capacity);
int MoMoAnalyzeSpeakersWithProfilesCancellable(
    MoMoSpeakerRuntime *runtime, const float *samples, int32_t count,
    const float *enrolled_embeddings, const int32_t *enrolled_person_ids,
    int32_t enrolled_count,
    MoMoCancelCallback is_cancelled, const void *cancel_context,
    MoMoCancelToken *cancel_token,
    MoMoSpeakerTurn *turns, int32_t capacity,
    char *error, size_t error_capacity);
// Extracts a verified single-speaker voiceprint from a confirmed audio slice.
// Returns embedding_dim (> 0) if pure single-speaker speech (>= 0.80 s) is found,
// 0 if multi-speaker / impure / too short, -2 if cancelled, -1 on error.
int MoMoExtractCleanVoiceprint(
    MoMoSpeakerRuntime *runtime, const float *samples, int32_t count,
    MoMoCancelCallback is_cancelled, const void *cancel_context,
    float *out_embedding, int32_t embedding_capacity, float *out_clean_seconds,
    char *error, size_t error_capacity);
int MoMoExtractCleanVoiceprintCancellable(
    MoMoSpeakerRuntime *runtime, const float *samples, int32_t count,
    MoMoCancelCallback is_cancelled, const void *cancel_context,
    MoMoCancelToken *cancel_token,
    float *out_embedding, int32_t embedding_capacity, float *out_clean_seconds,
    char *error, size_t error_capacity);
#ifdef __cplusplus
}
#endif
#endif

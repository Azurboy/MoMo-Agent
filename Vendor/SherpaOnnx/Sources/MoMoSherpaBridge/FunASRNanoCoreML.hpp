#ifndef MOMO_FUNASR_NANO_COREML_HPP
#define MOMO_FUNASR_NANO_COREML_HPP

#include "MoMoSherpaBridge.h"
#include "CancelToken.hpp"

#include <cstddef>
#include <cstdint>
#include <exception>
#include <memory>

namespace momo_funasr {

struct CancelledError : public std::exception {
  const char *what() const noexcept override { return "cancelled"; }
};

class CoreMLBackend {
 public:
  static std::unique_ptr<CoreMLBackend> Create(
      const char *encoder_model_path,
      const char *llm_model_path,
      const char *embedding_bin_path);

  ~CoreMLBackend();

  CoreMLBackend(const CoreMLBackend &) = delete;
  CoreMLBackend &operator=(const CoreMLBackend &) = delete;

  int32_t hidden_size() const noexcept { return hidden_size_; }
  int32_t vocab_size() const noexcept { return vocab_size_; }
  int32_t max_total_len() const noexcept { return max_total_len_; }
  int32_t max_lfr_frames() const noexcept { return max_lfr_frames_; }
  int32_t accelerator_mask() const noexcept { return accelerator_mask_; }

  void EmbedTokenSpan(const int64_t *ids, size_t count, float *out_fp32) const;
  void LookupSingleToken(int64_t token_id, float *out_fp32) const;

  // Runs bucketed CoreML ANE SenseVoiceEncoderSmall + Transformer adaptor and writes
  // the first n_aud_out frames ([n_aud_out, hidden_size]) to out_audio_embeds_fp32.
  void RunEncoderAdaptor(const float *lfr_fp32, int32_t t_lfr,
                         int32_t *out_effective_t_lfr,
                         int32_t *out_n_aud,
                         float *out_audio_embeds_fp32,
                         int32_t max_audio_slots);

  // Runs static S=96 ANE prefill + final prompt token(s) through S=1 ANE decode,
  // returning FP32 logits ([vocab_size]) for the first generated token.
  void RunPrefill(const float *context_embeds_fp32, int32_t context_len,
                  MoMoCancelCallback is_cancelled, const void *cancel_ctx,
                  const MoMoCancelToken *cancel_token,
                  float *out_logits_fp32);

  // Runs one S=1 ANE autoregressive decode step at KV slot write_pos for token_id.
  void RunDecodeStep(int64_t token_id, int32_t write_pos,
                     float *out_logits_fp32);

 private:
  struct Impl;
  explicit CoreMLBackend(std::unique_ptr<Impl> impl);

  std::unique_ptr<Impl> impl_;
  int32_t hidden_size_ = 1024;
  int32_t vocab_size_ = 151936;
  int32_t max_total_len_ = 512;
  int32_t max_lfr_frames_ = 512;
  int32_t accelerator_mask_ = 3;
};

bool IsCoreMLModelPath(const char *path) noexcept;

}  // namespace momo_funasr

#endif  // MOMO_FUNASR_NANO_COREML_HPP

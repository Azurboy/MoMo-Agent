#ifndef MOMO_XASR_COREML_HPP
#define MOMO_XASR_COREML_HPP

#include "MoMoSherpaBridge.h"
#include "CancelToken.hpp"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace momo_xasr {

struct DecodedOutput {
  std::string text;
  std::vector<std::string> tokens;
  std::vector<float> timestamps;
  std::string raw_json;
};

class CoreMLRuntime {
 public:
  static std::unique_ptr<CoreMLRuntime> Create(
      const char *encoder_mlmodelc_path,
      const char *decoder_joiner_bin_path,
      const char *tokens_path,
      int32_t num_threads);

  ~CoreMLRuntime();

  CoreMLRuntime(const CoreMLRuntime &) = delete;
  CoreMLRuntime &operator=(const CoreMLRuntime &) = delete;

  int32_t accelerator_mask() const noexcept { return accelerator_mask_; }

  DecodedOutput Transcribe(const float *samples, int32_t sample_count,
                           MoMoCancelCallback is_cancelled,
                           const void *cancel_ctx,
                           const MoMoCancelToken *cancel_token);

 private:
  struct Impl;
  explicit CoreMLRuntime(std::unique_ptr<Impl> impl, int32_t accelerator_mask);

  std::unique_ptr<Impl> impl_;
  int32_t accelerator_mask_ = 3;
};

}  // namespace momo_xasr

#endif  // MOMO_XASR_COREML_HPP

#ifndef MOMO_SHERPA_CANCEL_TOKEN_HPP
#define MOMO_SHERPA_CANCEL_TOKEN_HPP

#include "MoMoSherpaBridge.h"
#include <onnxruntime/onnxruntime_cxx_api.h>

#include <atomic>
#include <mutex>

struct MoMoCancelToken {
  std::atomic<bool> cancelled{false};
  std::mutex mutex;
  Ort::RunOptions *active_run_options = nullptr;

  void Cancel() {
    cancelled.store(true, std::memory_order_release);
    std::lock_guard<std::mutex> lock(mutex);
    if (active_run_options != nullptr) {
      active_run_options->SetTerminate();
    }
  }

  bool IsCancelled() const {
    return cancelled.load(std::memory_order_acquire);
  }
};

namespace momo_bridge {

class ScopedCancellableRunOptions {
 public:
  explicit ScopedCancellableRunOptions(MoMoCancelToken *token)
      : token_(token), options_(nullptr) {
    if (!token_) return;
    options_ = Ort::RunOptions{};
    std::lock_guard<std::mutex> lock(token_->mutex);
    if (token_->cancelled.load(std::memory_order_acquire)) {
      options_.SetTerminate();
    }
    token_->active_run_options = &options_;
  }

  ~ScopedCancellableRunOptions() {
    if (!token_) return;
    std::lock_guard<std::mutex> lock(token_->mutex);
    if (token_->active_run_options == &options_) {
      token_->active_run_options = nullptr;
    }
  }

  ScopedCancellableRunOptions(const ScopedCancellableRunOptions &) = delete;
  ScopedCancellableRunOptions &operator=(const ScopedCancellableRunOptions &) =
      delete;

  Ort::RunOptions &get() { return options_; }

 private:
  MoMoCancelToken *token_ = nullptr;
  Ort::RunOptions options_{nullptr};
};

}  // namespace momo_bridge

#endif

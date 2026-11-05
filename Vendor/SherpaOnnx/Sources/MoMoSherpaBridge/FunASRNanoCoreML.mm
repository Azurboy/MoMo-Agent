#import <CoreML/CoreML.h>
#import <Foundation/Foundation.h>
#include <TargetConditionals.h>

#include "FunASRNanoCoreML.hpp"

#if defined(__ARM_NEON) || defined(__aarch64__)
#include <arm_neon.h>
#endif

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

namespace momo_funasr {
namespace {

constexpr int32_t kHiddenSize = 1024;
constexpr int32_t kVocabSize = 151936;
constexpr int32_t kMaxTotalLen = 512;
constexpr int32_t kMaxLfrFrames = 512;
constexpr int32_t kPrefillLen = 96;
constexpr int32_t kHeadDim = 128;
constexpr int32_t kLfrDim = 560;
constexpr int32_t kEncInputDim = 561;
constexpr std::array<int32_t, 5> kEncoderBuckets = {64, 128, 256, 384, 512};

inline void CheckCancel(MoMoCancelCallback cb, const void *ctx,
                        const MoMoCancelToken *token) {
  if ((token && token->IsCancelled()) || (cb && cb(ctx) != 0)) {
    throw momo_funasr::CancelledError();
  }
}

inline float HalfBitsToFloat(uint16_t h) noexcept {
#if defined(__ARM_NEON) || defined(__aarch64__)
  __fp16 fh;
  std::memcpy(&fh, &h, sizeof(fh));
  return static_cast<float>(fh);
#else
  uint32_t sign = static_cast<uint32_t>(h & 0x8000u) << 16;
  uint32_t exp = (h >> 10) & 0x1Fu;
  uint32_t mant = h & 0x03FFu;
  uint32_t bits = 0;
  if (exp == 0) {
    if (mant == 0) {
      bits = sign;
    } else {
      exp = 1;
      while ((mant & 0x0400u) == 0) {
        mant <<= 1;
        --exp;
      }
      mant &= 0x03FFu;
      bits = sign | ((exp + (127 - 15)) << 23) | (mant << 13);
    }
  } else if (exp == 0x1Fu) {
    bits = sign | 0x7F800000u | (mant << 13);
  } else {
    bits = sign | ((exp + (127 - 15)) << 23) | (mant << 13);
  }
  float f = 0.0f;
  std::memcpy(&f, &bits, sizeof(float));
  return f;
#endif
}

inline uint16_t FloatToHalfBits(float f) noexcept {
#if defined(__ARM_NEON) || defined(__aarch64__)
  __fp16 fh = static_cast<__fp16>(f);
  uint16_t h = 0;
  std::memcpy(&h, &fh, sizeof(h));
  return h;
#else
  uint32_t bits = 0;
  std::memcpy(&bits, &f, sizeof(uint32_t));
  uint32_t sign = (bits >> 16) & 0x8000u;
  int32_t exp = static_cast<int32_t>((bits >> 23) & 0xFFu) - 127 + 15;
  uint32_t mant = bits & 0x007FFFFFu;
  if (exp <= 0) {
    if (exp < -10) return static_cast<uint16_t>(sign);
    mant = (mant | 0x00800000u) >> (1 - exp);
    return static_cast<uint16_t>(sign | ((mant + 0x00001000u) >> 13));
  }
  if (exp == 0xFF - 127 + 15) {
    if (mant == 0) return static_cast<uint16_t>(sign | 0x7C00u);
    return static_cast<uint16_t>(sign | 0x7C00u | (mant >> 13) | 1u);
  }
  uint32_t rounded = mant + 0x00001000u;
  if (rounded & 0x00800000u) {
    rounded = 0;
    ++exp;
  }
  if (exp >= 31) return static_cast<uint16_t>(sign | 0x7C00u);
  return static_cast<uint16_t>(sign | (static_cast<uint32_t>(exp) << 10) |
                               (rounded >> 13));
#endif
}

inline void ConvertHalfToFloatContiguous(const uint16_t *src, float *dst,
                                         size_t n) noexcept {
#if defined(__ARM_NEON) || defined(__aarch64__)
  size_t i = 0;
  for (; i + 8 <= n; i += 8) {
    uint16x8_t h = vld1q_u16(src + i);
    float16x8_t fh = vreinterpretq_f16_u16(h);
    vst1q_f32(dst + i, vcvt_f32_f16(vget_low_f16(fh)));
    vst1q_f32(dst + i + 4, vcvt_f32_f16(vget_high_f16(fh)));
  }
  for (; i < n; ++i) {
    dst[i] = HalfBitsToFloat(src[i]);
  }
#else
  for (size_t i = 0; i < n; ++i) {
    dst[i] = HalfBitsToFloat(src[i]);
  }
#endif
}

inline void ConvertFloatToHalfContiguous(const float *src, uint16_t *dst,
                                         size_t n) noexcept {
#if defined(__ARM_NEON) || defined(__aarch64__)
  size_t i = 0;
  for (; i + 8 <= n; i += 8) {
    float16x4_t lo = vcvt_f16_f32(vld1q_f32(src + i));
    float16x4_t hi = vcvt_f16_f32(vld1q_f32(src + i + 4));
    vst1q_u16(dst + i, vreinterpretq_u16_f16(vcombine_f16(lo, hi)));
  }
  for (; i < n; ++i) {
    dst[i] = FloatToHalfBits(src[i]);
  }
#else
  for (size_t i = 0; i < n; ++i) {
    dst[i] = FloatToHalfBits(src[i]);
  }
#endif
}

#pragma pack(push, 1)
struct MomoEmbHeader {
  char magic[8];
  uint32_t version;
  uint32_t vocab_size;
  uint32_t hidden_size;
  uint32_t quant_type;
  uint64_t scales_offset;
  uint64_t weights_offset;
  uint8_t reserved[24];
};
#pragma pack(pop)
static_assert(sizeof(MomoEmbHeader) == 64, "MomoEmbHeader must be 64 bytes");

class MmapEmbeddingTable {
 public:
  explicit MmapEmbeddingTable(const char *path) {
    if (!path || path[0] == '\0') {
      throw std::runtime_error("Missing FunASR-Nano embedding.int8.bin path");
    }
    const int fd = ::open(path, O_RDONLY);
    if (fd < 0) {
      throw std::runtime_error(std::string("Cannot open embedding table: ") + path);
    }
    struct stat st {};
    if (::fstat(fd, &st) != 0 || st.st_size < static_cast<off_t>(sizeof(MomoEmbHeader))) {
      ::close(fd);
      throw std::runtime_error(std::string("Invalid embedding table size: ") + path);
    }
    mapped_size_ = static_cast<size_t>(st.st_size);
    void *addr = ::mmap(nullptr, mapped_size_, PROT_READ, MAP_PRIVATE, fd, 0);
    ::close(fd);
    if (addr == MAP_FAILED || !addr) {
      throw std::runtime_error(std::string("mmap failed for embedding table: ") + path);
    }
    mapped_ = static_cast<const uint8_t *>(addr);

    MomoEmbHeader hdr{};
    std::memcpy(&hdr, mapped_, sizeof(MomoEmbHeader));
    if (std::memcmp(hdr.magic, "MOMO_EMB", 8) != 0 || hdr.version != 1 ||
        hdr.quant_type != 1) {
      Unmap();
      throw std::runtime_error("Unsupported MOMO_EMB header in embedding.int8.bin");
    }
    if (hdr.vocab_size == 0 || hdr.hidden_size == 0) {
      Unmap();
      throw std::runtime_error("Zero dimension in MOMO_EMB header");
    }
    const uint64_t scales_bytes =
        static_cast<uint64_t>(hdr.vocab_size) * sizeof(uint16_t);
    const uint64_t weights_bytes =
        static_cast<uint64_t>(hdr.vocab_size) * static_cast<uint64_t>(hdr.hidden_size);
    if (hdr.scales_offset < sizeof(MomoEmbHeader) ||
        hdr.scales_offset + scales_bytes > hdr.weights_offset ||
        hdr.weights_offset + weights_bytes > mapped_size_) {
      Unmap();
      throw std::runtime_error("Truncated MOMO_EMB file bounds");
    }

    vocab_size_ = static_cast<int32_t>(hdr.vocab_size);
    hidden_size_ = static_cast<int32_t>(hdr.hidden_size);
    scales_fp16_ = reinterpret_cast<const uint16_t *>(mapped_ + hdr.scales_offset);
    weights_int8_ = reinterpret_cast<const int8_t *>(mapped_ + hdr.weights_offset);
  }

  ~MmapEmbeddingTable() { Unmap(); }

  MmapEmbeddingTable(const MmapEmbeddingTable &) = delete;
  MmapEmbeddingTable &operator=(const MmapEmbeddingTable &) = delete;

  int32_t vocab_size() const noexcept { return vocab_size_; }
  int32_t hidden_size() const noexcept { return hidden_size_; }

  void LookupFp32(int64_t token_id, float *dst) const noexcept {
    const size_t H = static_cast<size_t>(hidden_size_);
    if (token_id < 0 || token_id >= vocab_size_) {
      std::memset(dst, 0, H * sizeof(float));
      return;
    }
    const float scale = HalfBitsToFloat(scales_fp16_[token_id]);
    const int8_t *row = weights_int8_ + static_cast<size_t>(token_id) * H;
#if defined(__ARM_NEON) || defined(__aarch64__)
    const float32x4_t vscale = vdupq_n_f32(scale);
    size_t d = 0;
    for (; d + 16 <= H; d += 16) {
      const int8x16_t q8 = vld1q_s8(row + d);
      const int16x8_t lo16 = vmovl_s8(vget_low_s8(q8));
      const int16x8_t hi16 = vmovl_s8(vget_high_s8(q8));
      vst1q_f32(dst + d,
                vmulq_f32(vcvtq_f32_s32(vmovl_s16(vget_low_s16(lo16))), vscale));
      vst1q_f32(dst + d + 4,
                vmulq_f32(vcvtq_f32_s32(vmovl_s16(vget_high_s16(lo16))), vscale));
      vst1q_f32(dst + d + 8,
                vmulq_f32(vcvtq_f32_s32(vmovl_s16(vget_low_s16(hi16))), vscale));
      vst1q_f32(dst + d + 12,
                vmulq_f32(vcvtq_f32_s32(vmovl_s16(vget_high_s16(hi16))), vscale));
    }
    for (; d < H; ++d) {
      dst[d] = static_cast<float>(row[d]) * scale;
    }
#else
    for (size_t d = 0; d < H; ++d) {
      dst[d] = static_cast<float>(row[d]) * scale;
    }
#endif
  }

  void LookupFp16Contiguous(int64_t token_id, uint16_t *dst) const noexcept {
    const size_t H = static_cast<size_t>(hidden_size_);
    if (token_id < 0 || token_id >= vocab_size_) {
      std::memset(dst, 0, H * sizeof(uint16_t));
      return;
    }
    const float scale = HalfBitsToFloat(scales_fp16_[token_id]);
    const int8_t *row = weights_int8_ + static_cast<size_t>(token_id) * H;
#if defined(__ARM_NEON) || defined(__aarch64__)
    const float32x4_t vscale = vdupq_n_f32(scale);
    size_t d = 0;
    for (; d + 16 <= H; d += 16) {
      const int8x16_t q8 = vld1q_s8(row + d);
      const int16x8_t lo16 = vmovl_s8(vget_low_s8(q8));
      const int16x8_t hi16 = vmovl_s8(vget_high_s8(q8));
      const float16x4_t f0 =
          vcvt_f16_f32(vmulq_f32(vcvtq_f32_s32(vmovl_s16(vget_low_s16(lo16))), vscale));
      const float16x4_t f1 =
          vcvt_f16_f32(vmulq_f32(vcvtq_f32_s32(vmovl_s16(vget_high_s16(lo16))), vscale));
      const float16x4_t f2 =
          vcvt_f16_f32(vmulq_f32(vcvtq_f32_s32(vmovl_s16(vget_low_s16(hi16))), vscale));
      const float16x4_t f3 =
          vcvt_f16_f32(vmulq_f32(vcvtq_f32_s32(vmovl_s16(vget_high_s16(hi16))), vscale));
      vst1q_u16(dst + d, vreinterpretq_u16_f16(vcombine_f16(f0, f1)));
      vst1q_u16(dst + d + 8, vreinterpretq_u16_f16(vcombine_f16(f2, f3)));
    }
    for (; d < H; ++d) {
      dst[d] = FloatToHalfBits(static_cast<float>(row[d]) * scale);
    }
#else
    for (size_t d = 0; d < H; ++d) {
      dst[d] = FloatToHalfBits(static_cast<float>(row[d]) * scale);
    }
#endif
  }

 private:
  void Unmap() noexcept {
    if (mapped_ && mapped_size_ > 0) {
      ::munmap(const_cast<uint8_t *>(mapped_), mapped_size_);
    }
    mapped_ = nullptr;
    mapped_size_ = 0;
  }

  const uint8_t *mapped_ = nullptr;
  size_t mapped_size_ = 0;
  int32_t vocab_size_ = 0;
  int32_t hidden_size_ = 0;
  const uint16_t *scales_fp16_ = nullptr;
  const int8_t *weights_int8_ = nullptr;
};

std::string NormalizePathSuffix(const char *path) {
  if (!path) return {};
  std::string s(path);
  while (s.size() > 1 && s.back() == '/') s.pop_back();
  return s;
}

bool EndsWith(const std::string &s, const char *suffix) {
  const size_t n = std::strlen(suffix);
  return s.size() >= n && s.compare(s.size() - n, n, suffix) == 0;
}

NSURL *ResolveCompiledModelURL(const char *raw_path, NSURL **out_temp_compiled) {
  *out_temp_compiled = nil;
  const std::string norm = NormalizePathSuffix(raw_path);
  if (norm.empty()) {
    throw std::runtime_error("Empty CoreML model path");
  }
  NSString *nsPath = [NSString stringWithUTF8String:norm.c_str()];
  BOOL isDir = NO;
  if (![[NSFileManager defaultManager] fileExistsAtPath:nsPath isDirectory:&isDir]) {
    throw std::runtime_error("CoreML model path does not exist: " + norm);
  }
  NSURL *srcURL = [NSURL fileURLWithPath:nsPath isDirectory:isDir];
  if (EndsWith(norm, ".mlmodelc")) {
    return srcURL;
  }
  NSError *compileErr = nil;
  NSURL *compiledURL = [MLModel compileModelAtURL:srcURL error:&compileErr];
  if (!compiledURL) {
    std::string msg = compileErr ? [[compileErr localizedDescription] UTF8String]
                                 : "Unknown compile error";
    throw std::runtime_error("Failed to compile CoreML model " + norm + ": " + msg);
  }
  *out_temp_compiled = compiledURL;
  return compiledURL;
}

API_AVAILABLE(macos(15.0), ios(18.0))
MLModel *LoadModelWithFallback(NSURL *compiledURL, NSString *functionName,
                               bool *out_uses_ane) {
  NSArray<NSNumber *> *candidates =
#if TARGET_OS_SIMULATOR
      @[ @(MLComputeUnitsCPUOnly) ];
#elif TARGET_OS_IOS
      // Never include MLComputeUnitsAll (Metal GPU) on iOS so background
      // Watch-sync wakeups never trigger kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted.
      @[ @(MLComputeUnitsCPUAndNeuralEngine), @(MLComputeUnitsCPUOnly) ];
#else
      @[ @(MLComputeUnitsCPUAndNeuralEngine), @(MLComputeUnitsAll), @(MLComputeUnitsCPUOnly) ];
#endif

  NSError *lastErr = nil;
  for (NSNumber *cuNum in candidates) {
    MLModelConfiguration *cfg = [[MLModelConfiguration alloc] init];
    cfg.computeUnits = static_cast<MLComputeUnits>(cuNum.integerValue);
    if (functionName != nil) {
      cfg.functionName = functionName;
    }
    NSError *err = nil;
    MLModel *model = [MLModel modelWithContentsOfURL:compiledURL
                                       configuration:cfg
                                               error:&err];
    if (model != nil) {
      *out_uses_ane = (cfg.computeUnits == MLComputeUnitsCPUAndNeuralEngine ||
                       cfg.computeUnits == MLComputeUnitsAll);
      return model;
    }
    lastErr = err;
  }
  std::string msg =
      lastErr ? [[lastErr localizedDescription] UTF8String] : "Unknown load error";
  std::string fn = functionName ? [functionName UTF8String] : "main";
  throw std::runtime_error("Failed to load CoreML model (" + fn + "): " + msg);
}

MLMultiArray *MakeMultiArray(NSArray<NSNumber *> *shape,
                             MLMultiArrayDataType dtype,
                             const char *label) {
  NSError *err = nil;
  MLMultiArray *arr = [[MLMultiArray alloc] initWithShape:shape
                                                 dataType:dtype
                                                    error:&err];
  if (!arr) {
    std::string msg =
        err ? [[err localizedDescription] UTF8String] : "allocation failed";
    throw std::runtime_error(std::string("Failed to allocate MLMultiArray (") +
                             label + "): " + msg);
  }
  return arr;
}

MLDictionaryFeatureProvider *MakeFeatureProvider(
    NSDictionary<NSString *, MLFeatureValue *> *dict, const char *label) {
  NSError *err = nil;
  MLDictionaryFeatureProvider *prov =
      [[MLDictionaryFeatureProvider alloc] initWithDictionary:dict error:&err];
  if (!prov) {
    std::string msg =
        err ? [[err localizedDescription] UTF8String] : "provider init failed";
    throw std::runtime_error(std::string("Failed to create feature provider (") +
                             label + "): " + msg);
  }
  return prov;
}

int32_t ComputeOfficialNAud(int32_t t_enc) noexcept {
  int32_t ol = 1 + (t_enc - 3 + 2) / 2;
  ol = 1 + (ol - 3 + 2) / 2;
  return std::clamp<int32_t>((ol - 1) / 2 + 1, 1, t_enc);
}

}  // namespace

bool IsCoreMLModelPath(const char *path) noexcept {
  const std::string norm = NormalizePathSuffix(path);
  return EndsWith(norm, ".mlmodelc") || EndsWith(norm, ".mlpackage") ||
         EndsWith(norm, ".mlmodel");
}

struct EncoderBucketSlot {
  int32_t bucket_frames = 0;
  MLMultiArray *speech_and_mask = nil;
  MLDictionaryFeatureProvider *provider = nil;
};

struct CoreMLBackend::Impl {
  std::unique_ptr<MmapEmbeddingTable> embedding;
  NSURL *temp_enc_url = nil;
  NSURL *temp_llm_url = nil;

  MLModel *enc_model = nil;
  MLPredictionOptions *enc_options = nil;
  std::vector<EncoderBucketSlot> enc_buckets;

  MLModel *prefill_model = nil;
  MLModel *decode_model = nil;
  id llm_state = nil;  // MLState * (guarded by macOS 15 / iOS 18 availability)

  MLMultiArray *prefill_embeds = nil;
  MLMultiArray *prefill_cos = nil;
  MLMultiArray *prefill_sin = nil;
  MLMultiArray *prefill_mask = nil;
  MLDictionaryFeatureProvider *prefill_provider = nil;
  MLPredictionOptions *prefill_options = nil;

  MLMultiArray *decode_embeds = nil;
  MLMultiArray *decode_cos = nil;
  MLMultiArray *decode_sin = nil;
  MLMultiArray *decode_mask = nil;
  MLMultiArray *decode_write_pos = nil;
  MLMultiArray *decode_logits_backing = nil;
  MLDictionaryFeatureProvider *decode_provider = nil;
  MLPredictionOptions *decode_options = nil;

  std::vector<uint16_t> rope_cos_fp16;
  std::vector<uint16_t> rope_sin_fp16;
  std::array<uint16_t, kHiddenSize> scratch_tok_fp16{};

  int32_t accelerator_mask = 0;

  API_AVAILABLE(macos(15.0), ios(18.0))
  void RunSingleDecode(const uint16_t *embed_fp16, int32_t write_pos,
                       float *out_logits_fp32, int32_t vocab_size);

  ~Impl() {
    @autoreleasepool {
      if (temp_enc_url) {
        [[NSFileManager defaultManager] removeItemAtURL:temp_enc_url error:nil];
      }
      if (temp_llm_url) {
        [[NSFileManager defaultManager] removeItemAtURL:temp_llm_url error:nil];
      }
    }
  }
};

CoreMLBackend::CoreMLBackend(std::unique_ptr<Impl> impl)
    : impl_(std::move(impl)) {
  hidden_size_ = impl_->embedding->hidden_size();
  vocab_size_ = impl_->embedding->vocab_size();
  max_total_len_ = kMaxTotalLen;
  max_lfr_frames_ =
      impl_->enc_buckets.empty() ? kMaxLfrFrames : impl_->enc_buckets.back().bucket_frames;
  accelerator_mask_ = impl_->accelerator_mask;
}

CoreMLBackend::~CoreMLBackend() = default;

std::unique_ptr<CoreMLBackend> CoreMLBackend::Create(
    const char *encoder_model_path,
    const char *llm_model_path,
    const char *embedding_bin_path) {
  if (@available(macOS 15.0, iOS 18.0, *)) {
    @autoreleasepool {
      auto impl = std::make_unique<Impl>();
      impl->embedding = std::make_unique<MmapEmbeddingTable>(embedding_bin_path);
      if (impl->embedding->hidden_size() != kHiddenSize ||
          impl->embedding->vocab_size() != kVocabSize) {
        throw std::runtime_error("Unexpected embedding.int8.bin dimensions");
      }

      NSURL *tempEnc = nil;
      NSURL *encURL = ResolveCompiledModelURL(encoder_model_path, &tempEnc);
      impl->temp_enc_url = tempEnc;

      NSURL *tempLlm = nil;
      NSURL *llmURL = ResolveCompiledModelURL(llm_model_path, &tempLlm);
      impl->temp_llm_url = tempLlm;

      __block MLModel *loadedEnc = nil;
      __block MLModel *loadedPrefill = nil;
      __block MLModel *loadedDecode = nil;
      __block bool enc_ane = false;
      __block bool prefill_ane = false;
      __block bool decode_ane = false;
      std::string errEnc, errPrefill, errDecode;
#if TARGET_OS_IOS
      // Load sequentially inside separate autoreleasepools on iOS so CoreML
      // MIL/E5 load scratch buffers do not stack 3-way (+848 MB peak spike)
      // against XNU background Jetsam limits during Watch-sync cold wakeups.
      @autoreleasepool {
        try {
          bool ane = false;
          loadedEnc = LoadModelWithFallback(encURL, nil, &ane);
          enc_ane = ane;
        } catch (const std::exception &e) {
          errEnc = e.what();
        }
      }
      if (errEnc.empty()) {
        @autoreleasepool {
          try {
            bool ane = false;
            loadedPrefill = LoadModelWithFallback(llmURL, @"prefill", &ane);
            prefill_ane = ane;
          } catch (const std::exception &e) {
            errPrefill = e.what();
          }
        }
      }
      if (errEnc.empty() && errPrefill.empty()) {
        @autoreleasepool {
          try {
            bool ane = false;
            loadedDecode = LoadModelWithFallback(llmURL, @"decode", &ane);
            decode_ane = ane;
          } catch (const std::exception &e) {
            errDecode = e.what();
          }
        }
      }
#else
      std::string *pErrEnc = &errEnc;
      std::string *pErrPrefill = &errPrefill;
      std::string *pErrDecode = &errDecode;

      dispatch_group_t loadGroup = dispatch_group_create();
      dispatch_queue_t loadQueue =
          dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);

      dispatch_group_async(loadGroup, loadQueue, ^{
        @autoreleasepool {
          try {
            bool ane = false;
            loadedEnc = LoadModelWithFallback(encURL, nil, &ane);
            enc_ane = ane;
          } catch (const std::exception &e) {
            *pErrEnc = e.what();
          }
        }
      });
      dispatch_group_async(loadGroup, loadQueue, ^{
        @autoreleasepool {
          try {
            bool ane = false;
            loadedPrefill = LoadModelWithFallback(llmURL, @"prefill", &ane);
            prefill_ane = ane;
          } catch (const std::exception &e) {
            *pErrPrefill = e.what();
          }
        }
      });
      dispatch_group_async(loadGroup, loadQueue, ^{
        @autoreleasepool {
          try {
            bool ane = false;
            loadedDecode = LoadModelWithFallback(llmURL, @"decode", &ane);
            decode_ane = ane;
          } catch (const std::exception &e) {
            *pErrDecode = e.what();
          }
        }
      });
      dispatch_group_wait(loadGroup, DISPATCH_TIME_FOREVER);
#endif

      if (!errEnc.empty()) throw std::runtime_error(errEnc);
      if (!errPrefill.empty()) throw std::runtime_error(errPrefill);
      if (!errDecode.empty()) throw std::runtime_error(errDecode);

      impl->enc_model = loadedEnc;
      impl->prefill_model = loadedPrefill;
      impl->decode_model = loadedDecode;
      impl->enc_options = [[MLPredictionOptions alloc] init];

      MLFeatureDescription *encInDesc =
          impl->enc_model.modelDescription.inputDescriptionsByName[@"speech_and_mask"];
      const MLMultiArrayDataType encInDtype =
          (encInDesc && encInDesc.multiArrayConstraint)
              ? encInDesc.multiArrayConstraint.dataType
              : MLMultiArrayDataTypeFloat32;

      std::vector<int32_t> bucket_list;
      if (encInDesc && encInDesc.multiArrayConstraint) {
        MLMultiArrayShapeConstraint *sc =
            encInDesc.multiArrayConstraint.shapeConstraint;
        if (sc && sc.type == MLMultiArrayShapeConstraintTypeEnumerated &&
            sc.enumeratedShapes.count > 0) {
          for (NSArray<NSNumber *> *sh in sc.enumeratedShapes) {
            if (sh.count >= 2 && sh[1].intValue > 0) {
              bucket_list.push_back(sh[1].intValue);
            }
          }
          std::sort(bucket_list.begin(), bucket_list.end());
          bucket_list.erase(
              std::unique(bucket_list.begin(), bucket_list.end()),
              bucket_list.end());
        } else if (encInDesc.multiArrayConstraint.shape.count >= 2 &&
                   encInDesc.multiArrayConstraint.shape[1].intValue > 0) {
          bucket_list.push_back(
              encInDesc.multiArrayConstraint.shape[1].intValue);
        }
      }
      if (bucket_list.empty()) {
        bucket_list.assign(kEncoderBuckets.begin(), kEncoderBuckets.end());
      }

      impl->enc_buckets.reserve(bucket_list.size());
      for (int32_t b : bucket_list) {
        EncoderBucketSlot slot;
        slot.bucket_frames = b;
        slot.speech_and_mask = MakeMultiArray(
            @[ @1, @(b), @(kEncInputDim) ], encInDtype, "speech_and_mask");
        slot.provider = MakeFeatureProvider(
            @{@"speech_and_mask" : [MLFeatureValue featureValueWithMultiArray:slot.speech_and_mask]},
            "encoder_provider");
        impl->enc_buckets.push_back(slot);
      }

      impl->llm_state = [impl->prefill_model newState];
      if (!impl->llm_state) {
        throw std::runtime_error("Failed to allocate CoreML MLState for Qwen3 KV cache");
      }

      impl->accelerator_mask = 0;
      if (enc_ane) impl->accelerator_mask |= 1;
      if (prefill_ane && decode_ane) impl->accelerator_mask |= 2;

      // Precompute RoPE cos/sin tables [512, 128] in IEEE-754 binary16.
      constexpr int32_t kHalfDim = kHeadDim / 2;
      constexpr double kTheta = 1000000.0;
      std::array<double, kHalfDim> inv_freq{};
      for (int32_t i = 0; i < kHalfDim; ++i) {
        inv_freq[static_cast<size_t>(i)] =
            1.0 / std::pow(kTheta, static_cast<double>(2 * i) /
                                       static_cast<double>(kHeadDim));
      }
      impl->rope_cos_fp16.resize(static_cast<size_t>(kMaxTotalLen * kHeadDim));
      impl->rope_sin_fp16.resize(static_cast<size_t>(kMaxTotalLen * kHeadDim));
      for (int32_t pos = 0; pos < kMaxTotalLen; ++pos) {
        uint16_t *cos_row =
            impl->rope_cos_fp16.data() + static_cast<size_t>(pos * kHeadDim);
        uint16_t *sin_row =
            impl->rope_sin_fp16.data() + static_cast<size_t>(pos * kHeadDim);
        for (int32_t i = 0; i < kHalfDim; ++i) {
          const double angle =
              static_cast<double>(pos) * inv_freq[static_cast<size_t>(i)];
          const uint16_t ch = FloatToHalfBits(static_cast<float>(std::cos(angle)));
          const uint16_t sh = FloatToHalfBits(static_cast<float>(std::sin(angle)));
          cos_row[i] = ch;
          cos_row[i + kHalfDim] = ch;
          sin_row[i] = sh;
          sin_row[i + kHalfDim] = sh;
        }
      }

      // Allocate & populate static S=96 prefill inputs.
      impl->prefill_embeds = MakeMultiArray(
          @[ @1, @(kHiddenSize), @1, @(kPrefillLen) ],
          MLMultiArrayDataTypeFloat16, "prefill_embeds");
      impl->prefill_cos = MakeMultiArray(
          @[ @1, @1, @(kPrefillLen), @(kHeadDim) ],
          MLMultiArrayDataTypeFloat16, "prefill_cos");
      impl->prefill_sin = MakeMultiArray(
          @[ @1, @1, @(kPrefillLen), @(kHeadDim) ],
          MLMultiArrayDataTypeFloat16, "prefill_sin");
      impl->prefill_mask = MakeMultiArray(
          @[ @1, @1, @(kPrefillLen), @(kMaxTotalLen) ],
          MLMultiArrayDataTypeFloat16, "prefill_mask");

      const uint16_t *cos_ptr = impl->rope_cos_fp16.data();
      const uint16_t *sin_ptr = impl->rope_sin_fp16.data();
      [impl->prefill_cos getMutableBytesWithHandler:^(
                             void *mutableBytes, NSInteger,
                             NSArray<NSNumber *> *strides) {
        auto *dst = static_cast<uint16_t *>(mutableBytes);
        const ptrdiff_t s2 = strides[2].integerValue;
        const ptrdiff_t s3 = strides[3].integerValue;
        for (int32_t i = 0; i < kPrefillLen; ++i) {
          const uint16_t *src_row = cos_ptr + static_cast<size_t>(i * kHeadDim);
          uint16_t *dst_row = dst + i * s2;
          if (s3 == 1) {
            std::memcpy(dst_row, src_row, kHeadDim * sizeof(uint16_t));
          } else {
            for (int32_t d = 0; d < kHeadDim; ++d) dst_row[d * s3] = src_row[d];
          }
        }
      }];
      [impl->prefill_sin getMutableBytesWithHandler:^(
                             void *mutableBytes, NSInteger,
                             NSArray<NSNumber *> *strides) {
        auto *dst = static_cast<uint16_t *>(mutableBytes);
        const ptrdiff_t s2 = strides[2].integerValue;
        const ptrdiff_t s3 = strides[3].integerValue;
        for (int32_t i = 0; i < kPrefillLen; ++i) {
          const uint16_t *src_row = sin_ptr + static_cast<size_t>(i * kHeadDim);
          uint16_t *dst_row = dst + i * s2;
          if (s3 == 1) {
            std::memcpy(dst_row, src_row, kHeadDim * sizeof(uint16_t));
          } else {
            for (int32_t d = 0; d < kHeadDim; ++d) dst_row[d * s3] = src_row[d];
          }
        }
      }];
      const uint16_t neg_mask_h = FloatToHalfBits(-10000.0f);
      [impl->prefill_mask getMutableBytesWithHandler:^(
                              void *mutableBytes, NSInteger,
                              NSArray<NSNumber *> *strides) {
        auto *dst = static_cast<uint16_t *>(mutableBytes);
        const ptrdiff_t s2 = strides[2].integerValue;
        const ptrdiff_t s3 = strides[3].integerValue;
        for (int32_t i = 0; i < kPrefillLen; ++i) {
          uint16_t *dst_row = dst + i * s2;
          for (int32_t j = 0; j < kMaxTotalLen; ++j) {
            dst_row[j * s3] = (j <= i) ? uint16_t(0) : neg_mask_h;
          }
        }
      }];

      impl->prefill_provider = MakeFeatureProvider(
          @{
            @"inputs_embeds" : [MLFeatureValue featureValueWithMultiArray:impl->prefill_embeds],
            @"cos" : [MLFeatureValue featureValueWithMultiArray:impl->prefill_cos],
            @"sin" : [MLFeatureValue featureValueWithMultiArray:impl->prefill_sin],
            @"attn_mask" : [MLFeatureValue featureValueWithMultiArray:impl->prefill_mask],
          },
          "prefill_provider");
      impl->prefill_options = [[MLPredictionOptions alloc] init];

      // Allocate reusable S=1 decode inputs + output backing.
      impl->decode_embeds = MakeMultiArray(
          @[ @1, @(kHiddenSize), @1, @1 ], MLMultiArrayDataTypeFloat16,
          "decode_embeds");
      impl->decode_cos = MakeMultiArray(
          @[ @1, @1, @1, @(kHeadDim) ], MLMultiArrayDataTypeFloat16,
          "decode_cos");
      impl->decode_sin = MakeMultiArray(
          @[ @1, @1, @1, @(kHeadDim) ], MLMultiArrayDataTypeFloat16,
          "decode_sin");
      impl->decode_mask = MakeMultiArray(
          @[ @1, @1, @1, @(kMaxTotalLen) ], MLMultiArrayDataTypeFloat16,
          "decode_mask");
      impl->decode_write_pos = MakeMultiArray(
          @[ @1 ], MLMultiArrayDataTypeInt32, "decode_write_pos");

      MLFeatureDescription *logitsDesc =
          impl->decode_model.modelDescription.outputDescriptionsByName[@"logits"];
      const MLMultiArrayDataType logitsDtype =
          (logitsDesc && logitsDesc.multiArrayConstraint)
              ? logitsDesc.multiArrayConstraint.dataType
              : MLMultiArrayDataTypeFloat16;
      impl->decode_logits_backing = MakeMultiArray(
          @[ @1, @(kVocabSize) ], logitsDtype, "decode_logits_backing");

      impl->decode_provider = MakeFeatureProvider(
          @{
            @"inputs_embeds" : [MLFeatureValue featureValueWithMultiArray:impl->decode_embeds],
            @"cos" : [MLFeatureValue featureValueWithMultiArray:impl->decode_cos],
            @"sin" : [MLFeatureValue featureValueWithMultiArray:impl->decode_sin],
            @"attn_mask" : [MLFeatureValue featureValueWithMultiArray:impl->decode_mask],
            @"write_pos" : [MLFeatureValue featureValueWithMultiArray:impl->decode_write_pos],
          },
          "decode_provider");
      impl->decode_options = [[MLPredictionOptions alloc] init];
      impl->decode_options.outputBackings =
          @{@"logits" : impl->decode_logits_backing};

      return std::unique_ptr<CoreMLBackend>(new CoreMLBackend(std::move(impl)));
    }
  }
  throw std::runtime_error(
      "FunASR-Nano CoreML ANE requires macOS 15.0 or iOS 18.0+");
}

void CoreMLBackend::EmbedTokenSpan(const int64_t *ids, size_t count,
                                   float *out_fp32) const {
  const size_t H = static_cast<size_t>(hidden_size_);
  for (size_t i = 0; i < count; ++i) {
    impl_->embedding->LookupFp32(ids[i], out_fp32 + i * H);
  }
}

void CoreMLBackend::LookupSingleToken(int64_t token_id, float *out_fp32) const {
  impl_->embedding->LookupFp32(token_id, out_fp32);
}

void CoreMLBackend::RunEncoderAdaptor(const float *lfr_fp32, int32_t t_lfr,
                                      int32_t *out_effective_t_lfr,
                                      int32_t *out_n_aud,
                                      float *out_audio_embeds_fp32,
                                      int32_t max_audio_slots) {
  if (t_lfr <= 0 || !lfr_fp32 || !out_audio_embeds_fp32) {
    throw std::runtime_error("Invalid EncoderAdaptor input");
  }
  const int32_t t_valid = std::min<int32_t>(t_lfr, max_lfr_frames_);
  const EncoderBucketSlot *slot = &impl_->enc_buckets.back();
  for (const auto &cand : impl_->enc_buckets) {
    if (cand.bucket_frames >= t_valid) {
      slot = &cand;
      break;
    }
  }
  const int32_t B = slot->bucket_frames;
  const MLMultiArrayDataType inDtype = slot->speech_and_mask.dataType;

  @autoreleasepool {
    [slot->speech_and_mask getMutableBytesWithHandler:^(
                               void *mutableBytes, NSInteger,
                               NSArray<NSNumber *> *strides) {
      const ptrdiff_t s1 = strides[1].integerValue;
      const ptrdiff_t s2 = strides[2].integerValue;
      if (inDtype == MLMultiArrayDataTypeFloat32) {
        auto *dst = static_cast<float *>(mutableBytes);
        for (int32_t t = 0; t < t_valid; ++t) {
          float *row = dst + t * s1;
          const float *src = lfr_fp32 + static_cast<size_t>(t) * kLfrDim;
          if (s2 == 1) {
            std::memcpy(row, src, kLfrDim * sizeof(float));
            row[kLfrDim] = 1.0f;
          } else {
            for (int32_t d = 0; d < kLfrDim; ++d) row[d * s2] = src[d];
            row[kLfrDim * s2] = 1.0f;
          }
        }
        for (int32_t t = t_valid; t < B; ++t) {
          float *row = dst + t * s1;
          if (s2 == 1) {
            std::memset(row, 0, kEncInputDim * sizeof(float));
          } else {
            for (int32_t d = 0; d < kEncInputDim; ++d) row[d * s2] = 0.0f;
          }
        }
      } else {
        auto *dst = static_cast<uint16_t *>(mutableBytes);
        const uint16_t one_h = FloatToHalfBits(1.0f);
        for (int32_t t = 0; t < t_valid; ++t) {
          uint16_t *row = dst + t * s1;
          const float *src = lfr_fp32 + static_cast<size_t>(t) * kLfrDim;
          if (s2 == 1) {
            ConvertFloatToHalfContiguous(src, row, kLfrDim);
            row[kLfrDim] = one_h;
          } else {
            for (int32_t d = 0; d < kLfrDim; ++d) {
              row[d * s2] = FloatToHalfBits(src[d]);
            }
            row[kLfrDim * s2] = one_h;
          }
        }
        for (int32_t t = t_valid; t < B; ++t) {
          uint16_t *row = dst + t * s1;
          if (s2 == 1) {
            std::memset(row, 0, kEncInputDim * sizeof(uint16_t));
          } else {
            for (int32_t d = 0; d < kEncInputDim; ++d) row[d * s2] = 0;
          }
        }
      }
    }];

    NSError *predErr = nil;
    id<MLFeatureProvider> out =
        [impl_->enc_model predictionFromFeatures:slot->provider
                                         options:impl_->enc_options
                                           error:&predErr];
    if (!out) {
      std::string msg = predErr ? [[predErr localizedDescription] UTF8String]
                                : "prediction failed";
      throw std::runtime_error("CoreML FunASREncoderAdaptor failed: " + msg);
    }

    MLMultiArray *audioEmbeds =
        [[out featureValueForName:@"audio_embeds"] multiArrayValue];
    if (!audioEmbeds || audioEmbeds.shape.count != 3) {
      throw std::runtime_error("Unexpected CoreML audio_embeds output shape");
    }

    const int32_t q_avail = audioEmbeds.shape[1].intValue;
    const int32_t h_out = audioEmbeds.shape[2].intValue;
    if (q_avail <= 0 || h_out != hidden_size_) {
      throw std::runtime_error("Mismatched CoreML audio_embeds hidden dim");
    }

    const int32_t raw_n_aud = ComputeOfficialNAud(t_valid);
    const int32_t n_aud =
        std::min<int32_t>(raw_n_aud, std::min<int32_t>(q_avail, max_audio_slots));

    NSArray<NSNumber *> *strides = audioEmbeds.strides;
    const ptrdiff_t s1 = strides[1].integerValue;
    const ptrdiff_t s2 = strides[2].integerValue;
    const MLMultiArrayDataType outDtype = audioEmbeds.dataType;

    [audioEmbeds getBytesWithHandler:^(const void *bytes, NSInteger) {
      if (outDtype == MLMultiArrayDataTypeFloat32) {
        const auto *src = static_cast<const float *>(bytes);
        for (int32_t t = 0; t < n_aud; ++t) {
          const float *row = src + t * s1;
          float *dst = out_audio_embeds_fp32 + static_cast<size_t>(t) * hidden_size_;
          for (int32_t d = 0; d < hidden_size_; ++d) {
            const float v = row[d * s2];
            dst[d] = std::isfinite(v) ? v : 0.0f;
          }
        }
      } else {
        const auto *src = static_cast<const uint16_t *>(bytes);
        for (int32_t t = 0; t < n_aud; ++t) {
          const uint16_t *row = src + t * s1;
          float *dst = out_audio_embeds_fp32 + static_cast<size_t>(t) * hidden_size_;
          if (s2 == 1) {
            ConvertHalfToFloatContiguous(row, dst, static_cast<size_t>(hidden_size_));
            for (int32_t d = 0; d < hidden_size_; ++d) {
              if (!std::isfinite(dst[d])) dst[d] = 0.0f;
            }
          } else {
            for (int32_t d = 0; d < hidden_size_; ++d) {
              const float v = HalfBitsToFloat(row[d * s2]);
              dst[d] = std::isfinite(v) ? v : 0.0f;
            }
          }
        }
      }
    }];

    if (out_effective_t_lfr) *out_effective_t_lfr = t_valid;
    if (out_n_aud) *out_n_aud = n_aud;
  }
}

API_AVAILABLE(macos(15.0), ios(18.0))
void CoreMLBackend::Impl::RunSingleDecode(const uint16_t *embed_fp16,
                                          int32_t write_pos,
                                          float *out_logits_fp32,
                                          int32_t vocab_size) {
  CoreMLBackend::Impl *impl = this;
  if (write_pos < 0 || write_pos >= kMaxTotalLen) {
    throw std::runtime_error("Decode write_pos out of KV cache bounds");
  }

  @autoreleasepool {
    [impl->decode_embeds getMutableBytesWithHandler:^(
                             void *mutableBytes, NSInteger,
                             NSArray<NSNumber *> *strides) {
      auto *dst = static_cast<uint16_t *>(mutableBytes);
      const ptrdiff_t s1 = strides[1].integerValue;
      if (s1 == 1) {
        std::memcpy(dst, embed_fp16, kHiddenSize * sizeof(uint16_t));
      } else {
        for (int32_t c = 0; c < kHiddenSize; ++c) {
          dst[c * s1] = embed_fp16[static_cast<size_t>(c)];
        }
      }
    }];

    const uint16_t *cos_src =
        impl->rope_cos_fp16.data() + static_cast<size_t>(write_pos * kHeadDim);
    const uint16_t *sin_src =
        impl->rope_sin_fp16.data() + static_cast<size_t>(write_pos * kHeadDim);

    [impl->decode_cos getMutableBytesWithHandler:^(
                          void *mutableBytes, NSInteger,
                          NSArray<NSNumber *> *strides) {
      auto *dst = static_cast<uint16_t *>(mutableBytes);
      const ptrdiff_t s3 = strides[3].integerValue;
      if (s3 == 1) {
        std::memcpy(dst, cos_src, kHeadDim * sizeof(uint16_t));
      } else {
        for (int32_t d = 0; d < kHeadDim; ++d) dst[d * s3] = cos_src[d];
      }
    }];

    [impl->decode_sin getMutableBytesWithHandler:^(
                          void *mutableBytes, NSInteger,
                          NSArray<NSNumber *> *strides) {
      auto *dst = static_cast<uint16_t *>(mutableBytes);
      const ptrdiff_t s3 = strides[3].integerValue;
      if (s3 == 1) {
        std::memcpy(dst, sin_src, kHeadDim * sizeof(uint16_t));
      } else {
        for (int32_t d = 0; d < kHeadDim; ++d) dst[d * s3] = sin_src[d];
      }
    }];

    const uint16_t neg_mask_h = FloatToHalfBits(-10000.0f);
    [impl->decode_mask getMutableBytesWithHandler:^(
                           void *mutableBytes, NSInteger,
                           NSArray<NSNumber *> *strides) {
      auto *dst = static_cast<uint16_t *>(mutableBytes);
      const ptrdiff_t s3 = strides[3].integerValue;
      if (s3 == 1) {
        std::memset(dst, 0, static_cast<size_t>(write_pos + 1) * sizeof(uint16_t));
        for (int32_t j = write_pos + 1; j < kMaxTotalLen; ++j) {
          dst[j] = neg_mask_h;
        }
      } else {
        for (int32_t j = 0; j <= write_pos; ++j) dst[j * s3] = 0;
        for (int32_t j = write_pos + 1; j < kMaxTotalLen; ++j) {
          dst[j * s3] = neg_mask_h;
        }
      }
    }];

    [impl->decode_write_pos getMutableBytesWithHandler:^(
                                void *mutableBytes, NSInteger,
                                NSArray<NSNumber *> *) {
      static_cast<int32_t *>(mutableBytes)[0] = write_pos;
    }];

    NSError *predErr = nil;
    id<MLFeatureProvider> out =
        [impl->decode_model predictionFromFeatures:impl->decode_provider
                                        usingState:(MLState *)impl->llm_state
                                           options:impl->decode_options
                                             error:&predErr];
    if (!out) {
      std::string msg = predErr ? [[predErr localizedDescription] UTF8String]
                                : "decode failed";
      throw std::runtime_error("CoreML FunASRLlm decode failed: " + msg);
    }

    if (!out_logits_fp32) return;

    MLMultiArray *logitsArr =
        [[out featureValueForName:@"logits"] multiArrayValue];
    if (!logitsArr) {
      throw std::runtime_error("Missing logits output from CoreML FunASRLlm");
    }

    const ptrdiff_t s_last = logitsArr.strides.lastObject.integerValue;
    const MLMultiArrayDataType dtype = logitsArr.dataType;
    [logitsArr getBytesWithHandler:^(const void *bytes, NSInteger) {
      if (dtype == MLMultiArrayDataTypeFloat16) {
        const auto *src = static_cast<const uint16_t *>(bytes);
        if (s_last == 1) {
          ConvertHalfToFloatContiguous(src, out_logits_fp32,
                                       static_cast<size_t>(vocab_size));
        } else {
          for (int32_t v = 0; v < vocab_size; ++v) {
            out_logits_fp32[v] = HalfBitsToFloat(src[v * s_last]);
          }
        }
      } else {
        const auto *src = static_cast<const float *>(bytes);
        if (s_last == 1) {
          std::memcpy(out_logits_fp32, src,
                      static_cast<size_t>(vocab_size) * sizeof(float));
        } else {
          for (int32_t v = 0; v < vocab_size; ++v) {
            out_logits_fp32[v] = src[v * s_last];
          }
        }
      }
    }];
  }
}

void CoreMLBackend::RunPrefill(const float *context_embeds_fp32,
                               int32_t context_len,
                               MoMoCancelCallback is_cancelled,
                               const void *cancel_ctx,
                               const MoMoCancelToken *cancel_token,
                               float *out_logits_fp32) {
  if (!context_embeds_fp32 || context_len <= 0 ||
      context_len > max_total_len_ || !out_logits_fp32) {
    throw std::runtime_error("Invalid FunASR-Nano CoreML prefill arguments");
  }

  if (@available(macOS 15.0, iOS 18.0, *)) {
    const int32_t prefill_n = std::min<int32_t>(context_len - 1, kPrefillLen);
    if (prefill_n > 0) {
      CheckCancel(is_cancelled, cancel_ctx, cancel_token);
      @autoreleasepool {
        [impl_->prefill_embeds getMutableBytesWithHandler:^(
                                   void *mutableBytes, NSInteger,
                                   NSArray<NSNumber *> *strides) {
          auto *dst = static_cast<uint16_t *>(mutableBytes);
          const ptrdiff_t s1 = strides[1].integerValue;
          const ptrdiff_t s3 = strides[3].integerValue;
          for (int32_t c = 0; c < kHiddenSize; ++c) {
            uint16_t *dst_c = dst + c * s1;
            for (int32_t s = 0; s < prefill_n; ++s) {
              dst_c[s * s3] = FloatToHalfBits(
                  context_embeds_fp32[static_cast<size_t>(s) * kHiddenSize + c]);
            }
            if (s3 == 1 && prefill_n < kPrefillLen) {
              std::memset(dst_c + prefill_n, 0,
                          static_cast<size_t>(kPrefillLen - prefill_n) *
                              sizeof(uint16_t));
            } else {
              for (int32_t s = prefill_n; s < kPrefillLen; ++s) {
                dst_c[s * s3] = 0;
              }
            }
          }
        }];

        NSError *predErr = nil;
        id<MLFeatureProvider> out =
            [impl_->prefill_model predictionFromFeatures:impl_->prefill_provider
                                              usingState:(MLState *)impl_->llm_state
                                                 options:impl_->prefill_options
                                                   error:&predErr];
        if (!out) {
          std::string msg = predErr ? [[predErr localizedDescription] UTF8String]
                                    : "prefill failed";
          throw std::runtime_error("CoreML FunASRLlm prefill failed: " + msg);
        }
      }
    }

    for (int32_t pos = prefill_n; pos < context_len; ++pos) {
      CheckCancel(is_cancelled, cancel_ctx, cancel_token);
      const float *src_emb =
          context_embeds_fp32 + static_cast<size_t>(pos) * kHiddenSize;
      ConvertFloatToHalfContiguous(src_emb, impl_->scratch_tok_fp16.data(),
                                   kHiddenSize);
      float *logits_dst = (pos == context_len - 1) ? out_logits_fp32 : nullptr;
      impl_->RunSingleDecode(impl_->scratch_tok_fp16.data(), pos, logits_dst,
                             vocab_size_);
    }
    return;
  }
  throw std::runtime_error(
      "FunASR-Nano CoreML ANE requires macOS 15.0 or iOS 18.0+");
}

void CoreMLBackend::RunDecodeStep(int64_t token_id, int32_t write_pos,
                                  float *out_logits_fp32) {
  if (@available(macOS 15.0, iOS 18.0, *)) {
    impl_->embedding->LookupFp16Contiguous(token_id,
                                           impl_->scratch_tok_fp16.data());
    impl_->RunSingleDecode(impl_->scratch_tok_fp16.data(), write_pos,
                           out_logits_fp32, vocab_size_);
    return;
  }
  throw std::runtime_error(
      "FunASR-Nano CoreML ANE requires macOS 15.0 or iOS 18.0+");
}

}  // namespace momo_funasr

#ifndef ACCELERATE_NEW_LAPACK
#define ACCELERATE_NEW_LAPACK
#endif
#import <CoreML/CoreML.h>
#import <Foundation/Foundation.h>
#include <Accelerate/Accelerate.h>
#include <TargetConditionals.h>

#include "XASRCoreML.hpp"

#if defined(__ARM_NEON) || defined(__aarch64__)
#include <arm_neon.h>
#endif

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <fstream>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

struct MoMoXASRCoreMLRuntime {
  std::unique_ptr<momo_xasr::CoreMLRuntime> impl;
};

namespace momo_xasr {
namespace {

constexpr int32_t kStaticFbankT = 2311;
constexpr int32_t kStaticSubT = 1152;
constexpr int32_t kStaticOutT = 576;
constexpr int32_t kNumMels = 80;
constexpr int32_t kFrameShift = 160;
constexpr int32_t kFrameLen = 400;
constexpr int32_t kFftSize = 512;
constexpr int32_t kFftLog2 = 9;
constexpr int32_t kFftBins = kFftSize / 2 + 1;  // 257
constexpr float kSampleRate = 16000.0f;
constexpr float kPreemph = 0.97f;
constexpr float kEnergyFloor = 1.1920929e-7f;

struct CancelledError : public std::exception {
  const char *what() const noexcept override { return "cancelled"; }
};

inline void CheckCancel(MoMoCancelCallback cb, const void *ctx,
                        const MoMoCancelToken *token) {
  if ((token && token->IsCancelled()) || (cb && cb(ctx) != 0)) {
    throw CancelledError();
  }
}

inline void SaveError(char *buffer, size_t capacity, const char *text) {
  if (buffer && capacity > 0) {
    std::snprintf(buffer, capacity, "%s", text ? text : "Unknown X-ASR CoreML error");
  }
}

inline char *DupCString(const std::string &s) {
  char *out = static_cast<char *>(std::malloc(s.size() + 1));
  if (!out) throw std::bad_alloc();
  std::memcpy(out, s.data(), s.size());
  out[s.size()] = '\0';
  return out;
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
struct MomoXasrDJHeader {
  char magic[8];
  uint32_t version;
  uint32_t vocab_size;
  uint32_t decoder_dim;
  uint32_t joiner_dim;
  uint32_t context_size;
  uint32_t conv_groups;
  uint32_t blank_id;
  uint32_t reserved0;
  uint64_t emb_fp16_offset;
  uint64_t conv_fp32_offset;
  uint64_t dproj_w_fp16_offset;
  uint64_t dproj_b_fp32_offset;
  uint64_t out_w_fp16_offset;
  uint64_t out_b_fp32_offset;
  uint8_t reserved1[40];
};
#pragma pack(pop)
static_assert(sizeof(MomoXasrDJHeader) == 128, "MomoXasrDJHeader must be 128 bytes");

std::vector<uint8_t> ReadBinaryFile(const char *path) {
  if (!path || path[0] == '\0') {
    throw std::runtime_error("Empty file path");
  }
  std::ifstream ifs(path, std::ios::binary | std::ios::ate);
  if (!ifs) {
    throw std::runtime_error(std::string("Cannot open file: ") + path);
  }
  std::streamsize sz = ifs.tellg();
  if (sz <= 0) {
    throw std::runtime_error(std::string("Invalid file size: ") + path);
  }
  std::vector<uint8_t> buf(static_cast<size_t>(sz));
  ifs.seekg(0, std::ios::beg);
  if (!ifs.read(reinterpret_cast<char *>(buf.data()), sz)) {
    throw std::runtime_error(std::string("Failed reading file: ") + path);
  }
  return buf;
}

std::vector<std::string> LoadTokensTable(const char *tokens_path, int32_t vocab_size) {
  if (!tokens_path || tokens_path[0] == '\0') {
    throw std::runtime_error("Missing X-ASR tokens.txt path");
  }
  std::ifstream ifs(tokens_path);
  if (!ifs) {
    throw std::runtime_error(std::string("Cannot open tokens.txt: ") + tokens_path);
  }
  std::vector<std::string> table(static_cast<size_t>(vocab_size));
  std::string line;
  while (std::getline(ifs, line)) {
    while (!line.empty() && (line.back() == '\r' || line.back() == '\n' || line.back() == ' ' || line.back() == '\t')) {
      line.pop_back();
    }
    size_t first = line.find_first_not_of(" \t");
    if (first == std::string::npos) continue;
    line = line.substr(first);
    size_t sp = line.find_last_of(" \t");
    std::string piece;
    int32_t id = -1;
    if (sp == std::string::npos) {
      id = std::atoi(line.c_str());
    } else {
      piece = line.substr(0, sp);
      while (!piece.empty() && (piece.back() == ' ' || piece.back() == '\t')) {
        piece.pop_back();
      }
      id = std::atoi(line.c_str() + sp + 1);
    }
    if (id >= 0 && id < vocab_size) {
      // Replace UTF-8 SentencePiece '▁' (\xE2\x96\x81) with ASCII space ' '
      std::string replaced;
      replaced.reserve(piece.size());
      for (size_t i = 0; i < piece.size();) {
        if (i + 2 < piece.size() &&
            static_cast<uint8_t>(piece[i]) == 0xE2 &&
            static_cast<uint8_t>(piece[i + 1]) == 0x96 &&
            static_cast<uint8_t>(piece[i + 2]) == 0x81) {
          replaced.push_back(' ');
          i += 3;
        } else {
          replaced.push_back(piece[i]);
          ++i;
        }
      }
      table[static_cast<size_t>(id)] = std::move(replaced);
    }
  }
  return table;
}

bool Utf8NextCodepoint(const std::string &s, size_t *idx, uint32_t *cp) {
  if (*idx >= s.size()) return false;
  const uint8_t c0 = static_cast<uint8_t>(s[*idx]);
  if (c0 < 0x80u) {
    *cp = c0;
    *idx += 1;
    return true;
  }
  if ((c0 >> 5) == 0x6u && *idx + 1 < s.size()) {
    *cp = ((c0 & 0x1Fu) << 6) | (static_cast<uint8_t>(s[*idx + 1]) & 0x3Fu);
    *idx += 2;
    return true;
  }
  if ((c0 >> 4) == 0xEu && *idx + 2 < s.size()) {
    *cp = ((c0 & 0x0Fu) << 12) |
          ((static_cast<uint8_t>(s[*idx + 1]) & 0x3Fu) << 6) |
          (static_cast<uint8_t>(s[*idx + 2]) & 0x3Fu);
    *idx += 3;
    return true;
  }
  if ((c0 >> 3) == 0x1Eu && *idx + 3 < s.size()) {
    *cp = ((c0 & 0x07u) << 18) |
          ((static_cast<uint8_t>(s[*idx + 1]) & 0x3Fu) << 12) |
          ((static_cast<uint8_t>(s[*idx + 2]) & 0x3Fu) << 6) |
          (static_cast<uint8_t>(s[*idx + 3]) & 0x3Fu);
    *idx += 4;
    return true;
  }
  *cp = c0;
  *idx += 1;
  return true;
}

uint32_t FirstCodepoint(const std::string &s) {
  size_t i = 0;
  uint32_t cp = 0;
  Utf8NextCodepoint(s, &i, &cp);
  return cp;
}

uint32_t LastCodepoint(const std::string &s) {
  size_t i = 0;
  uint32_t cp = 0, last = 0;
  while (Utf8NextCodepoint(s, &i, &cp)) {
    last = cp;
  }
  return last;
}

inline bool IsCjkCodepoint(uint32_t cp) noexcept {
  return (cp >= 0x3400u && cp <= 0x4DBFu) ||
         (cp >= 0x4E00u && cp <= 0x9FFFu) ||
         (cp >= 0xF900u && cp <= 0xFAFFu) ||
         (cp >= 0x20000u && cp <= 0x2CEAFu);
}

inline bool IsCjkPunct(uint32_t cp) noexcept {
  return cp == 0xFF0Cu || cp == 0x3002u || cp == 0xFF01u ||
         cp == 0xFF1Fu || cp == 0xFF1Au || cp == 0xFF1Bu ||
         cp == 0x3001u;
}

inline bool IsNoSpaceBefore(uint32_t cp) noexcept {
  switch (cp) {
    case ',':
    case '.':
    case '!':
    case '?':
    case ':':
    case ';':
    case ')':
    case ']':
    case '}':
    case '%':
    case 0xFF0Cu:  // ，
    case 0x3002u:  // 。
    case 0xFF01u:  // ！
    case 0xFF1Fu:  // ？
    case 0xFF1Au:  // ：
    case 0xFF1Bu:  // ；
    case 0x3001u:  // 、
    case 0xFF09u:  // ）
    case 0x3011u:  // 】
    case 0x300Bu:  // 》
    case 0x201Du:  // ”
    case 0x2019u:  // ’
      return true;
    default:
      return false;
  }
}

std::string TrimAsciiSpaces(const std::string &s) {
  size_t b = s.find_first_not_of(' ');
  if (b == std::string::npos) return std::string();
  size_t e = s.find_last_not_of(' ');
  return s.substr(b, e - b + 1);
}

void AppendJsonEscaped(const std::string &s, std::string *out) {
  out->push_back('"');
  for (unsigned char c : s) {
    switch (c) {
      case '"':
        out->append("\\\"");
        break;
      case '\\':
        out->append("\\\\");
        break;
      case '\b':
        out->append("\\b");
        break;
      case '\f':
        out->append("\\f");
        break;
      case '\n':
        out->append("\\n");
        break;
      case '\r':
        out->append("\\r");
        break;
      case '\t':
        out->append("\\t");
        break;
      default:
        if (c < 0x20u) {
          char hex[8];
          std::snprintf(hex, sizeof(hex), "\\u%04x", static_cast<unsigned int>(c));
          out->append(hex);
        } else {
          out->push_back(static_cast<char>(c));
        }
        break;
    }
  }
  out->push_back('"');
}

std::string BuildRawJson(const std::string &text,
                         const std::vector<std::string> &tokens,
                         const std::vector<float> &timestamps,
                         const std::vector<float> &log_probs) {
  std::string out;
  out.reserve(256 + text.size() + tokens.size() * 20);
  out.append("{\"lang\": \"\", \"emotion\": \"\", \"event\": \"\", \"text\": ");
  AppendJsonEscaped(text, &out);
  out.append(", \"timestamps\": [");
  char num_buf[32];
  for (size_t i = 0; i < timestamps.size(); ++i) {
    if (i > 0) out.append(", ");
    std::snprintf(num_buf, sizeof(num_buf), "%.2f", static_cast<double>(timestamps[i]));
    out.append(num_buf);
  }
  out.append("], \"durations\": [], \"tokens\": [");
  for (size_t i = 0; i < tokens.size(); ++i) {
    if (i > 0) out.append(", ");
    AppendJsonEscaped(tokens[i], &out);
  }
  out.append("], \"ys_log_probs\": [");
  for (size_t i = 0; i < log_probs.size(); ++i) {
    if (i > 0) out.append(", ");
    std::snprintf(num_buf, sizeof(num_buf), "%.6f", static_cast<double>(log_probs[i]));
    out.append(num_buf);
  }
  out.append("], \"words\": []}");
  return out;
}

class KaldiPoveyFbank {
 public:
  KaldiPoveyFbank() {
    fft_setup_ = vDSP_create_fftsetup(kFftLog2, kFFTRadix2);
    if (!fft_setup_) {
      throw std::runtime_error("vDSP_create_fftsetup failed");
    }
    povey_.resize(kFrameLen);
    const double a = 2.0 * M_PI / static_cast<double>(kFrameLen - 1);
    for (int32_t i = 0; i < kFrameLen; ++i) {
      povey_[i] = static_cast<float>(std::pow(0.5 - 0.5 * std::cos(a * static_cast<double>(i)), 0.85));
    }

    auto mel = [](float f) -> float {
      return 1127.0f * std::log(1.0f + f / 700.0f);
    };
    const float ml = mel(20.0f);
    const float mh = mel(7600.0f);  // high_freq = -400 -> Nyquist - 400 = 7600 Hz
    const float dm = (mh - ml) / static_cast<float>(kNumMels + 1);

    std::array<float, kFftBins> bins_mel{};
    for (int32_t b = 0; b < kFftBins; ++b) {
      bins_mel[b] = mel((kSampleRate / static_cast<float>(kFftSize)) * static_cast<float>(b));
    }
    // Store transposed [kFftBins, kNumMels] so [T, 257] @ [257, 80] is a single contiguous cblas_sgemm!
    mel_banks_t_.assign(static_cast<size_t>(kFftBins * kNumMels), 0.0f);
    for (int32_t m = 0; m < kNumMels; ++m) {
      const float left_m = ml + static_cast<float>(m) * dm;
      const float center_m = ml + static_cast<float>(m + 1) * dm;
      const float right_m = ml + static_cast<float>(m + 2) * dm;
      for (int32_t b = 0; b < kFftBins; ++b) {
        const float bm = bins_mel[b];
        const float up = (bm - left_m) / (center_m - left_m);
        const float down = (right_m - bm) / (right_m - center_m);
        const float w = std::max(0.0f, std::min(up, down));
        mel_banks_t_[static_cast<size_t>(b) * kNumMels + m] = w;
      }
    }
  }

  ~KaldiPoveyFbank() {
    if (fft_setup_) {
      vDSP_destroy_fftsetup(fft_setup_);
      fft_setup_ = nullptr;
    }
  }

  KaldiPoveyFbank(const KaldiPoveyFbank &) = delete;
  KaldiPoveyFbank &operator=(const KaldiPoveyFbank &) = delete;

  int32_t Compute(const float *samples, int32_t n_samples, std::vector<float> *out_feats) const {
    if (!samples || n_samples <= 0) {
      out_feats->clear();
      return 0;
    }
    const int32_t num_frames = (n_samples + kFrameShift / 2) / kFrameShift;
    if (num_frames <= 0) {
      out_feats->clear();
      return 0;
    }

    std::vector<float> power_mat(static_cast<size_t>(num_frames) * kFftBins, 0.0f);
    std::array<float, kFftSize> padded{};
    std::array<float, kFftSize / 2> real_buf{};
    std::array<float, kFftSize / 2> imag_buf{};
    DSPSplitComplex split{real_buf.data(), imag_buf.data()};

    for (int32_t t = 0; t < num_frames; ++t) {
      const int32_t start = t * kFrameShift + (kFrameShift / 2) - (kFrameLen / 2);
      for (int32_t i = 0; i < kFrameLen; ++i) {
        int32_t idx = start + i;
        while (idx < 0 || idx >= n_samples) {
          if (idx < 0) idx = -idx - 1;
          if (idx >= n_samples) idx = 2 * n_samples - 1 - idx;
        }
        padded[i] = samples[idx];
      }
      std::fill(padded.begin() + kFrameLen, padded.end(), 0.0f);

      float mean = 0.0f;
      vDSP_meanv(padded.data(), 1, &mean, kFrameLen);
      const float neg_mean = -mean;
      vDSP_vsadd(padded.data(), 1, &neg_mean, padded.data(), 1, kFrameLen);

      for (int32_t i = kFrameLen - 1; i >= 1; --i) {
        padded[i] -= kPreemph * padded[i - 1];
      }
      padded[0] *= (1.0f - kPreemph);

      vDSP_vmul(padded.data(), 1, povey_.data(), 1, padded.data(), 1, kFrameLen);

      vDSP_ctoz(reinterpret_cast<const DSPComplex *>(padded.data()), 2, &split, 1, kFftSize / 2);
      vDSP_fft_zrip(fft_setup_, &split, 1, kFftLog2, FFT_FORWARD);

      // vDSP_fft_zrip returns 2 * DFT, so |X[k]|^2 = 0.25 * (re^2 + im^2).
      float *prow = power_mat.data() + static_cast<size_t>(t) * kFftBins;
      prow[0] = 0.25f * split.realp[0] * split.realp[0];
      prow[kFftSize / 2] = 0.25f * split.imagp[0] * split.imagp[0];
      for (int32_t k = 1; k < kFftSize / 2; ++k) {
        const float re = split.realp[k];
        const float im = split.imagp[k];
        prow[k] = 0.25f * (re * re + im * im);
      }
    }

    out_feats->resize(static_cast<size_t>(num_frames) * kNumMels);
    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans,
                num_frames, kNumMels, kFftBins,
                1.0f, power_mat.data(), kFftBins,
                mel_banks_t_.data(), kNumMels,
                0.0f, out_feats->data(), kNumMels);

    const int32_t total_elems = num_frames * kNumMels;
    float *fptr = out_feats->data();
    for (int32_t i = 0; i < total_elems; ++i) {
      if (fptr[i] < kEnergyFloor) fptr[i] = kEnergyFloor;
    }
    vvlogf(fptr, fptr, &total_elems);
    return num_frames;
  }

 private:
  FFTSetup fft_setup_ = nullptr;
  std::vector<float> povey_;
  std::vector<float> mel_banks_t_;
};

MLMultiArray *AllocFp16Array(NSArray<NSNumber *> *shape) {
  NSError *err = nil;
  MLMultiArray *arr = [[MLMultiArray alloc] initWithShape:shape
                                                 dataType:MLMultiArrayDataTypeFloat16
                                                    error:&err];
  if (!arr || err) {
    std::string msg = err ? [[err localizedDescription] UTF8String] : "MLMultiArray alloc failed";
    throw std::runtime_error(msg);
  }
  return arr;
}

void ZeroFp16Array(MLMultiArray *arr, int32_t d0, int32_t d1, int32_t d2, int32_t d3) {
  uint16_t *ptr = static_cast<uint16_t *>(arr.dataPointer);
  NSArray<NSNumber *> *st = arr.strides;
  const int64_t s0 = st[0].longLongValue;
  const int64_t s1 = st[1].longLongValue;
  const int64_t s2 = st[2].longLongValue;
  const int64_t s3 = st[3].longLongValue;
  if (s3 == 1 && s2 == d3 && s1 == static_cast<int64_t>(d2) * d3) {
    std::memset(ptr, 0, static_cast<size_t>(d0) * d1 * d2 * d3 * sizeof(uint16_t));
    return;
  }
  for (int32_t i0 = 0; i0 < d0; ++i0) {
    for (int32_t i1 = 0; i1 < d1; ++i1) {
      for (int32_t i2 = 0; i2 < d2; ++i2) {
        uint16_t *row = ptr + i0 * s0 + i1 * s1 + i2 * s2;
        if (s3 == 1) {
          std::memset(row, 0, static_cast<size_t>(d3) * sizeof(uint16_t));
        } else {
          for (int32_t i3 = 0; i3 < d3; ++i3) row[i3 * s3] = 0;
        }
      }
    }
  }
}

void FillMaskArray(MLMultiArray *arr, int32_t seq_len, int32_t valid_len) {
  uint16_t *ptr = static_cast<uint16_t *>(arr.dataPointer);
  const int64_t s3 = arr.strides[3].longLongValue;
  const uint16_t one = FloatToHalfBits(1.0f);
  const int32_t v = valid_len > 0 ? std::min(valid_len, seq_len) : 1;
  for (int32_t i = 0; i < seq_len; ++i) {
    ptr[i * s3] = (i < v) ? one : 0;
  }
}

void FillRshift3D(MLMultiArray *arr, int32_t k, int32_t seq_len, int32_t valid_len) {
  uint16_t *ptr = static_cast<uint16_t *>(arr.dataPointer);
  NSArray<NSNumber *> *st = arr.strides;
  const int64_t s1 = st[1].longLongValue;
  const int64_t s2 = st[2].longLongValue;
  for (int32_t r = 0; r < k; ++r) {
    uint16_t *row = ptr + r * s1;
    if (s2 == 1) {
      std::memset(row, 0, static_cast<size_t>(seq_len) * sizeof(uint16_t));
    } else {
      for (int32_t c = 0; c < seq_len; ++c) row[c * s2] = 0;
    }
  }
  const uint16_t one = FloatToHalfBits(1.0f);
  const int32_t v = std::max<int32_t>(1, valid_len);
  if (v < k) {
    for (int32_t idx = 0; idx < v; ++idx) {
      ptr[(k - v + idx) * s1 + idx * s2] = one;
    }
  } else {
    const int32_t start = v - k;
    for (int32_t idx = 0; idx < k; ++idx) {
      const int32_t col = start + idx;
      if (col < seq_len) {
        ptr[idx * s1 + col * s2] = one;
      }
    }
  }
}

}  // namespace

struct CoreMLRuntime::Impl {
  NSURL *encoder_url = nil;
  MLComputeUnits chosen_units = MLComputeUnitsAll;
  MLModel *stage0_model = nil;
  MLModel *stage1_model = nil;
  MLModel *stage2_model = nil;
  KaldiPoveyFbank fbank;

  int32_t vocab_size = 5000;
  int32_t decoder_dim = 512;
  int32_t joiner_dim = 512;
  int32_t context_size = 2;
  int32_t conv_groups = 128;
  int32_t blank_id = 0;

  std::vector<float> emb_fp32;      // [vocab_size, decoder_dim]
  std::vector<float> conv_fp32;     // [conv_groups, group_dim, group_dim, 2]
  std::vector<float> dproj_w_fp32;  // [joiner_dim, decoder_dim]
  std::vector<float> dproj_b_fp32;  // [joiner_dim]
  std::vector<float> out_w_fp32;    // [vocab_size, joiner_dim]
  std::vector<float> out_b_fp32;    // [vocab_size]
  std::vector<std::string> tokens_table;

  // Pre-allocated static CoreML inputs & reusable stage0 provider (protected by infer_mu)
  std::mutex infer_mu;
  MLMultiArray *in_fbank = nil;
  MLMultiArray *in_mask_1152 = nil;
  MLMultiArray *in_mask_576 = nil;
  MLMultiArray *in_mask_288 = nil;
  MLMultiArray *in_mask_144 = nil;
  MLMultiArray *in_rshift_1152 = nil;
  MLMultiArray *in_rshift_576 = nil;
  MLMultiArray *in_rshift_288 = nil;
  MLMultiArray *in_rshift_144 = nil;
  MLDictionaryFeatureProvider *stage0_provider = nil;
  MLPredictionOptions *pred_opts = nil;
  bool ane_warmed = false;

  static MLModel *LoadFunction(NSURL *url, NSString *fn_name, MLComputeUnits preferred_units) {
    const std::array<MLComputeUnits, 3> fallbacks = {{
        preferred_units,
        MLComputeUnitsAll,
        MLComputeUnitsCPUOnly,
    }};
    std::string last_err = "Failed loading XASREncoder function";
    for (MLComputeUnits units : fallbacks) {
      MLModelConfiguration *cfg = [[MLModelConfiguration alloc] init];
      cfg.computeUnits = units;
      if (@available(macOS 15.0, iOS 18.0, *)) {
        cfg.functionName = fn_name;
      } else {
        throw std::runtime_error("X-ASR CoreML requires macOS 15.0+ or iOS 18.0+");
      }
      NSError *err = nil;
      MLModel *loaded = [MLModel modelWithContentsOfURL:url configuration:cfg error:&err];
      if (loaded && !err) {
        return loaded;
      }
      if (err) {
        last_err = [[err localizedDescription] UTF8String];
      }
    }
    throw std::runtime_error(last_err);
  }

  void EnsureStagesLoaded(MoMoCancelCallback is_cancelled,
                          const void *cancel_ctx,
                          const MoMoCancelToken *cancel_token) {
    if (!stage1_model) {
      CheckCancel(is_cancelled, cancel_ctx, cancel_token);
      @autoreleasepool {
        stage1_model = LoadFunction(encoder_url, @"stage1", chosen_units);
      }
    }
    if (!stage2_model) {
      CheckCancel(is_cancelled, cancel_ctx, cancel_token);
      @autoreleasepool {
        stage2_model = LoadFunction(encoder_url, @"stage2", chosen_units);
      }
    }
  }

  void ComputeDecoderProj(int32_t prev0, int32_t prev1, float *out_dec_proj) const {
    const int32_t ddim = decoder_dim;
    const int32_t gdim = ddim / conv_groups;  // 4
    const float *e0 = (prev0 == blank_id) ? nullptr : (emb_fp32.data() + static_cast<size_t>(prev0) * ddim);
    const float *e1 = (prev1 == blank_id) ? nullptr : (emb_fp32.data() + static_cast<size_t>(prev1) * ddim);

    std::array<float, 1024> conv_relu{};
    for (int32_t g = 0; g < conv_groups; ++g) {
      const int32_t c_base = g * gdim;
      const float *gw = conv_fp32.data() + static_cast<size_t>(g) * gdim * gdim * 2;
      for (int32_t o = 0; o < gdim; ++o) {
        const float *ow = gw + o * gdim * 2;
        float acc = 0.0f;
        for (int32_t i = 0; i < gdim; ++i) {
          const float v0 = e0 ? e0[c_base + i] : 0.0f;
          const float v1 = e1 ? e1[c_base + i] : 0.0f;
          acc += ow[i * 2 + 0] * v0 + ow[i * 2 + 1] * v1;
        }
        conv_relu[c_base + o] = acc > 0.0f ? acc : 0.0f;
      }
    }

    std::memcpy(out_dec_proj, dproj_b_fp32.data(), static_cast<size_t>(joiner_dim) * sizeof(float));
    cblas_sgemv(CblasRowMajor, CblasNoTrans,
                joiner_dim, ddim,
                1.0f, dproj_w_fp32.data(), ddim,
                conv_relu.data(), 1,
                1.0f, out_dec_proj, 1);
  }
};

CoreMLRuntime::CoreMLRuntime(std::unique_ptr<Impl> impl, int32_t accelerator_mask)
    : impl_(std::move(impl)), accelerator_mask_(accelerator_mask) {}

CoreMLRuntime::~CoreMLRuntime() = default;

std::unique_ptr<CoreMLRuntime> CoreMLRuntime::Create(
    const char *encoder_mlmodelc_path,
    const char *decoder_joiner_bin_path,
    const char *tokens_path,
    int32_t /*num_threads*/) {
  @autoreleasepool {
    if (!encoder_mlmodelc_path || encoder_mlmodelc_path[0] == '\0') {
      throw std::runtime_error("Missing XASREncoder.mlmodelc path");
    }
    auto impl = std::make_unique<Impl>();

    // 1. Load MOMO_XDJ v1 decoder_joiner.bin
    std::vector<uint8_t> dj_bytes = ReadBinaryFile(decoder_joiner_bin_path);
    if (dj_bytes.size() < sizeof(MomoXasrDJHeader)) {
      throw std::runtime_error("Truncated decoder_joiner.bin header");
    }
    MomoXasrDJHeader hdr{};
    std::memcpy(&hdr, dj_bytes.data(), sizeof(hdr));
    if (std::memcmp(hdr.magic, "MOMO_XDJ", 8) != 0 || hdr.version != 1) {
      throw std::runtime_error("Invalid MOMO_XDJ header in decoder_joiner.bin");
    }
    if (hdr.vocab_size == 0 || hdr.decoder_dim == 0 || hdr.decoder_dim > 1024 ||
        hdr.joiner_dim == 0 || hdr.context_size != 2 || hdr.conv_groups == 0 ||
        (hdr.decoder_dim % hdr.conv_groups) != 0) {
      throw std::runtime_error("Unsupported dimensions in decoder_joiner.bin");
    }

    impl->vocab_size = static_cast<int32_t>(hdr.vocab_size);
    impl->decoder_dim = static_cast<int32_t>(hdr.decoder_dim);
    impl->joiner_dim = static_cast<int32_t>(hdr.joiner_dim);
    impl->context_size = static_cast<int32_t>(hdr.context_size);
    impl->conv_groups = static_cast<int32_t>(hdr.conv_groups);
    impl->blank_id = static_cast<int32_t>(hdr.blank_id);

    const size_t n_emb = static_cast<size_t>(hdr.vocab_size) * hdr.decoder_dim;
    const size_t n_conv = static_cast<size_t>(hdr.decoder_dim) * (hdr.decoder_dim / hdr.conv_groups) * hdr.context_size;
    const size_t n_dproj_w = static_cast<size_t>(hdr.joiner_dim) * hdr.decoder_dim;
    const size_t n_dproj_b = static_cast<size_t>(hdr.joiner_dim);
    const size_t n_out_w = static_cast<size_t>(hdr.vocab_size) * hdr.joiner_dim;
    const size_t n_out_b = static_cast<size_t>(hdr.vocab_size);

    auto check_bounds = [&](uint64_t off, size_t byte_len) {
      if (off < sizeof(MomoXasrDJHeader) || off + byte_len > dj_bytes.size()) {
        throw std::runtime_error("Out-of-bounds tensor offset in decoder_joiner.bin");
      }
    };
    check_bounds(hdr.emb_fp16_offset, n_emb * sizeof(uint16_t));
    check_bounds(hdr.conv_fp32_offset, n_conv * sizeof(float));
    check_bounds(hdr.dproj_w_fp16_offset, n_dproj_w * sizeof(uint16_t));
    check_bounds(hdr.dproj_b_fp32_offset, n_dproj_b * sizeof(float));
    check_bounds(hdr.out_w_fp16_offset, n_out_w * sizeof(uint16_t));
    check_bounds(hdr.out_b_fp32_offset, n_out_b * sizeof(float));

    impl->emb_fp32.resize(n_emb);
    ConvertHalfToFloatContiguous(
        reinterpret_cast<const uint16_t *>(dj_bytes.data() + hdr.emb_fp16_offset),
        impl->emb_fp32.data(), n_emb);

    impl->conv_fp32.resize(n_conv);
    std::memcpy(impl->conv_fp32.data(), dj_bytes.data() + hdr.conv_fp32_offset, n_conv * sizeof(float));

    impl->dproj_w_fp32.resize(n_dproj_w);
    ConvertHalfToFloatContiguous(
        reinterpret_cast<const uint16_t *>(dj_bytes.data() + hdr.dproj_w_fp16_offset),
        impl->dproj_w_fp32.data(), n_dproj_w);

    impl->dproj_b_fp32.resize(n_dproj_b);
    std::memcpy(impl->dproj_b_fp32.data(), dj_bytes.data() + hdr.dproj_b_fp32_offset, n_dproj_b * sizeof(float));

    impl->out_w_fp32.resize(n_out_w);
    ConvertHalfToFloatContiguous(
        reinterpret_cast<const uint16_t *>(dj_bytes.data() + hdr.out_w_fp16_offset),
        impl->out_w_fp32.data(), n_out_w);

    impl->out_b_fp32.resize(n_out_b);
    std::memcpy(impl->out_b_fp32.data(), dj_bytes.data() + hdr.out_b_fp32_offset, n_out_b * sizeof(float));
    dj_bytes.clear();
    dj_bytes.shrink_to_fit();

    // 2. Load tokens.txt
    impl->tokens_table = LoadTokensTable(tokens_path, impl->vocab_size);

    // 3. Load XASREncoder.mlmodelc stage0 eagerly (< 5s even on cold compile, < 0.1s warm);
    //    stage1 & stage2 compile lazily on warmUp() / first Transcribe() so cold XPC memory stays low.
    NSString *enc_ns = [NSString stringWithUTF8String:encoder_mlmodelc_path];
    NSURL *enc_url = [NSURL fileURLWithPath:enc_ns isDirectory:YES];
    impl->encoder_url = enc_url;

    struct Candidate {
      MLComputeUnits units;
      int32_t mask;
    };
#if TARGET_OS_SIMULATOR
    const std::array<Candidate, 2> candidates = {{{MLComputeUnitsCPUOnly, 1}, {MLComputeUnitsAll, 2}}};
#else
    const std::array<Candidate, 3> candidates = {{
        {MLComputeUnitsCPUAndNeuralEngine, 3},
        {MLComputeUnitsAll, 2},
        {MLComputeUnitsCPUOnly, 1},
    }};
#endif
    int32_t chosen_mask = 0;
    std::string last_err = "Failed loading XASREncoder.mlmodelc (stage0)";
    for (const auto &cand : candidates) {
      MLModelConfiguration *cfg = [[MLModelConfiguration alloc] init];
      cfg.computeUnits = cand.units;
      if (@available(macOS 15.0, iOS 18.0, *)) {
        cfg.functionName = @"stage0";
      } else {
        throw std::runtime_error("X-ASR CoreML requires macOS 15.0+ or iOS 18.0+");
      }
      NSError *err = nil;
      MLModel *loaded = [MLModel modelWithContentsOfURL:enc_url configuration:cfg error:&err];
      if (loaded && !err) {
        impl->stage0_model = loaded;
        impl->chosen_units = cand.units;
        chosen_mask = cand.mask;
        break;
      }
      if (err) {
        last_err = [[err localizedDescription] UTF8String];
      }
    }
    if (!impl->stage0_model) {
      throw std::runtime_error(last_err);
    }

    // 4. Pre-allocate static MLMultiArray input buffers & stage0 dictionary provider
    impl->in_fbank = AllocFp16Array(@[@1, @1, @(kStaticFbankT), @(kNumMels)]);
    impl->in_mask_1152 = AllocFp16Array(@[@1, @1, @1, @1152]);
    impl->in_mask_576 = AllocFp16Array(@[@1, @1, @1, @576]);
    impl->in_mask_288 = AllocFp16Array(@[@1, @1, @1, @288]);
    impl->in_mask_144 = AllocFp16Array(@[@1, @1, @1, @144]);
    impl->in_rshift_1152 = AllocFp16Array(@[@1, @31, @1152]);
    impl->in_rshift_576 = AllocFp16Array(@[@1, @31, @576]);
    impl->in_rshift_288 = AllocFp16Array(@[@1, @15, @288]);
    impl->in_rshift_144 = AllocFp16Array(@[@1, @15, @144]);

    NSDictionary<NSString *, id> *s0_dict = @{
      @"fbank" : [MLFeatureValue featureValueWithMultiArray:impl->in_fbank],
      @"mask_1152" : [MLFeatureValue featureValueWithMultiArray:impl->in_mask_1152],
      @"mask_576" : [MLFeatureValue featureValueWithMultiArray:impl->in_mask_576],
      @"rshift_1152" : [MLFeatureValue featureValueWithMultiArray:impl->in_rshift_1152],
      @"rshift_576" : [MLFeatureValue featureValueWithMultiArray:impl->in_rshift_576],
    };
    NSError *prov_err = nil;
    impl->stage0_provider = [[MLDictionaryFeatureProvider alloc] initWithDictionary:s0_dict error:&prov_err];
    if (!impl->stage0_provider || prov_err) {
      throw std::runtime_error("Failed creating MLDictionaryFeatureProvider for X-ASR stage0");
    }
    impl->pred_opts = [[MLPredictionOptions alloc] init];

    return std::unique_ptr<CoreMLRuntime>(new CoreMLRuntime(std::move(impl), chosen_mask));
  }
}

DecodedOutput CoreMLRuntime::Transcribe(const float *samples, int32_t sample_count,
                                        MoMoCancelCallback is_cancelled,
                                        const void *cancel_ctx,
                                        const MoMoCancelToken *cancel_token) {
  CheckCancel(is_cancelled, cancel_ctx, cancel_token);
  if (!samples || sample_count <= 0) {
    DecodedOutput empty;
    empty.raw_json = BuildRawJson("", {}, {}, {});
    return empty;
  }

  bool is_constant = true;
  const float s0 = samples[0];
  for (int32_t i = 1; i < sample_count; ++i) {
    if (samples[i] != s0) {
      is_constant = false;
      break;
    }
  }
  float max_abs = 0.0f;
  vDSP_maxmgv(samples, 1, &max_abs, static_cast<vDSP_Length>(sample_count));
  const bool is_silent = is_constant || (max_abs < 2e-4f);

  std::lock_guard<std::mutex> lock(impl_->infer_mu);
  impl_->EnsureStagesLoaded(is_cancelled, cancel_ctx, cancel_token);
  if (is_silent && impl_->ane_warmed) {
    DecodedOutput empty;
    empty.raw_json = BuildRawJson("", {}, {}, {});
    return empty;
  }

  std::vector<float> feats;
  const int32_t total_frames = impl_->fbank.Compute(samples, sample_count, &feats);
  CheckCancel(is_cancelled, cancel_ctx, cancel_token);
  if (total_frames < 7) {
    DecodedOutput empty;
    empty.raw_json = BuildRawJson("", {}, {}, {});
    return empty;
  }

  int32_t prev0 = impl_->blank_id;
  int32_t prev1 = impl_->blank_id;
  std::vector<float> dec_proj(static_cast<size_t>(impl_->joiner_dim), 0.0f);
  impl_->ComputeDecoderProj(prev0, prev1, dec_proj.data());

  std::vector<int32_t> raw_ids;
  std::vector<int32_t> raw_frames;
  std::vector<float> raw_log_probs;

  std::vector<float> enc_row(static_cast<size_t>(impl_->joiner_dim));
  std::vector<float> joint(static_cast<size_t>(impl_->joiner_dim));
  std::vector<float> logits(static_cast<size_t>(impl_->vocab_size));

  int32_t frame_cursor = 0;
  int32_t out_frame_offset = 0;

  while (frame_cursor < total_frames) {
    CheckCancel(is_cancelled, cancel_ctx, cancel_token);
    const int32_t t_valid = std::min<int32_t>(total_frames - frame_cursor, kStaticFbankT);
    if (t_valid < 7) break;
    const int32_t sub_valid = std::max<int32_t>(1, (t_valid - 7) / 2);
    const int32_t t_out = std::min<int32_t>(kStaticOutT, (sub_valid + 1) / 2);

    // Populate fbank [1, 1, 2311, 80] respecting MLMultiArray strides
    {
      ZeroFp16Array(impl_->in_fbank, 1, 1, kStaticFbankT, kNumMels);
      uint16_t *dst = static_cast<uint16_t *>(impl_->in_fbank.dataPointer);
      NSArray<NSNumber *> *st = impl_->in_fbank.strides;
      const int64_t s_t = st[2].longLongValue;
      const int64_t s_m = st[3].longLongValue;
      const float *src = feats.data() + static_cast<size_t>(frame_cursor) * kNumMels;
      if (s_m == 1 && s_t == kNumMels) {
        ConvertFloatToHalfContiguous(src, dst, static_cast<size_t>(t_valid) * kNumMels);
      } else {
        for (int32_t t = 0; t < t_valid; ++t) {
          uint16_t *row_dst = dst + t * s_t;
          const float *row_src = src + static_cast<size_t>(t) * kNumMels;
          if (s_m == 1) {
            ConvertFloatToHalfContiguous(row_src, row_dst, kNumMels);
          } else {
            for (int32_t m = 0; m < kNumMels; ++m) {
              row_dst[m * s_m] = FloatToHalfBits(row_src[m]);
            }
          }
        }
      }
    }

    const int32_t v1 = sub_valid;
    const int32_t v2 = (sub_valid + 1) / 2;
    const int32_t v4 = (sub_valid + 3) / 4;
    const int32_t v8 = (sub_valid + 7) / 8;
    FillMaskArray(impl_->in_mask_1152, 1152, v1);
    FillMaskArray(impl_->in_mask_576, 576, v2);
    FillMaskArray(impl_->in_mask_288, 288, v4);
    FillMaskArray(impl_->in_mask_144, 144, v8);
    FillRshift3D(impl_->in_rshift_1152, 31, 1152, v1);
    FillRshift3D(impl_->in_rshift_576, 31, 576, v2);
    FillRshift3D(impl_->in_rshift_288, 15, 288, v4);
    FillRshift3D(impl_->in_rshift_144, 15, 144, v8);

    @autoreleasepool {
      NSError *pred_err = nil;
      id<MLFeatureProvider> out0 =
          [impl_->stage0_model predictionFromFeatures:impl_->stage0_provider
                                              options:impl_->pred_opts
                                                error:&pred_err];
      if (!out0 || pred_err) {
        std::string msg = pred_err ? [[pred_err localizedDescription] UTF8String]
                                   : "XASREncoder stage0 prediction failed";
        throw std::runtime_error(msg);
      }
      MLFeatureValue *s1_fv = [out0 featureValueForName:@"s1_out"];
      if (!s1_fv || !s1_fv.multiArrayValue) {
        throw std::runtime_error("Missing s1_out feature in XASREncoder stage0 output");
      }
      CheckCancel(is_cancelled, cancel_ctx, cancel_token);

      NSDictionary<NSString *, id> *s1_dict = @{
        @"s1_out" : s1_fv,
        @"mask_288" : [MLFeatureValue featureValueWithMultiArray:impl_->in_mask_288],
        @"mask_144" : [MLFeatureValue featureValueWithMultiArray:impl_->in_mask_144],
        @"rshift_288" : [MLFeatureValue featureValueWithMultiArray:impl_->in_rshift_288],
        @"rshift_144" : [MLFeatureValue featureValueWithMultiArray:impl_->in_rshift_144],
      };
      MLDictionaryFeatureProvider *prov1 =
          [[MLDictionaryFeatureProvider alloc] initWithDictionary:s1_dict error:&pred_err];
      if (!prov1 || pred_err) {
        std::string msg = pred_err ? [[pred_err localizedDescription] UTF8String]
                                   : "Failed creating XASREncoder stage1 provider";
        throw std::runtime_error(msg);
      }
      id<MLFeatureProvider> out1 =
          [impl_->stage1_model predictionFromFeatures:prov1
                                              options:impl_->pred_opts
                                                error:&pred_err];
      if (!out1 || pred_err) {
        std::string msg = pred_err ? [[pred_err localizedDescription] UTF8String]
                                   : "XASREncoder stage1 prediction failed";
        throw std::runtime_error(msg);
      }
      MLFeatureValue *s3_fv = [out1 featureValueForName:@"s3_out"];
      if (!s3_fv || !s3_fv.multiArrayValue) {
        throw std::runtime_error("Missing s3_out feature in XASREncoder stage1 output");
      }
      CheckCancel(is_cancelled, cancel_ctx, cancel_token);

      NSDictionary<NSString *, id> *s2_dict = @{
        @"s3_out" : s3_fv,
        @"mask_288" : [MLFeatureValue featureValueWithMultiArray:impl_->in_mask_288],
        @"mask_576" : [MLFeatureValue featureValueWithMultiArray:impl_->in_mask_576],
        @"rshift_288" : [MLFeatureValue featureValueWithMultiArray:impl_->in_rshift_288],
        @"rshift_576" : [MLFeatureValue featureValueWithMultiArray:impl_->in_rshift_576],
      };
      MLDictionaryFeatureProvider *prov2 =
          [[MLDictionaryFeatureProvider alloc] initWithDictionary:s2_dict error:&pred_err];
      if (!prov2 || pred_err) {
        std::string msg = pred_err ? [[pred_err localizedDescription] UTF8String]
                                   : "Failed creating XASREncoder stage2 provider";
        throw std::runtime_error(msg);
      }
      id<MLFeatureProvider> out2 =
          [impl_->stage2_model predictionFromFeatures:prov2
                                              options:impl_->pred_opts
                                                error:&pred_err];
      if (!out2 || pred_err) {
        std::string msg = pred_err ? [[pred_err localizedDescription] UTF8String]
                                   : "XASREncoder stage2 prediction failed";
        throw std::runtime_error(msg);
      }
      MLMultiArray *enc_arr = [[out2 featureValueForName:@"encoder_out"] multiArrayValue];
      if (!enc_arr) {
        throw std::runtime_error("Missing encoder_out feature in XASREncoder stage2 output");
      }
      impl_->ane_warmed = true;
      if (is_silent) {
        DecodedOutput empty;
        empty.raw_json = BuildRawJson("", {}, {}, {});
        return empty;
      }

      NSArray<NSNumber *> *est = enc_arr.strides;
      const int64_t es_t = est[1].longLongValue;
      const int64_t es_d = est[2].longLongValue;
      const bool is_fp16 = (enc_arr.dataType == MLMultiArrayDataTypeFloat16);
      const uint16_t *enc_fp16 = is_fp16 ? static_cast<const uint16_t *>(enc_arr.dataPointer) : nullptr;
      const float *enc_fp32 = !is_fp16 ? static_cast<const float *>(enc_arr.dataPointer) : nullptr;

      const int32_t jdim = impl_->joiner_dim;
      const int32_t vocab = impl_->vocab_size;

      for (int32_t t = 0; t < t_out; ++t) {
        if ((t & 31) == 0) {
          CheckCancel(is_cancelled, cancel_ctx, cancel_token);
        }
        if (is_fp16) {
          const uint16_t *row_h = enc_fp16 + t * es_t;
          if (es_d == 1) {
            ConvertHalfToFloatContiguous(row_h, enc_row.data(), static_cast<size_t>(jdim));
          } else {
            for (int32_t d = 0; d < jdim; ++d) {
              enc_row[d] = HalfBitsToFloat(row_h[d * es_d]);
            }
          }
        } else {
          const float *row_f = enc_fp32 + t * es_t;
          if (es_d == 1) {
            std::memcpy(enc_row.data(), row_f, static_cast<size_t>(jdim) * sizeof(float));
          } else {
            for (int32_t d = 0; d < jdim; ++d) {
              enc_row[d] = row_f[d * es_d];
            }
          }
        }

        vDSP_vadd(enc_row.data(), 1, dec_proj.data(), 1, joint.data(), 1, jdim);
        vvtanhf(joint.data(), joint.data(), &jdim);

        std::memcpy(logits.data(), impl_->out_b_fp32.data(), static_cast<size_t>(vocab) * sizeof(float));
        cblas_sgemv(CblasRowMajor, CblasNoTrans,
                    vocab, jdim,
                    1.0f, impl_->out_w_fp32.data(), jdim,
                    joint.data(), 1,
                    1.0f, logits.data(), 1);

        float max_logit = -INFINITY;
        vDSP_Length best_idx = 0;
        vDSP_maxvi(logits.data(), 1, &max_logit, &best_idx, vocab);
        const int32_t y = static_cast<int32_t>(best_idx);

        if (y != impl_->blank_id) {
          double sum_exp = 0.0;
          for (int32_t v = 0; v < vocab; ++v) {
            sum_exp += std::exp(static_cast<double>(logits[v] - max_logit));
          }
          const float log_prob = -static_cast<float>(std::log(sum_exp));
          raw_ids.push_back(y);
          raw_frames.push_back(out_frame_offset + t);
          raw_log_probs.push_back(log_prob);

          prev0 = prev1;
          prev1 = y;
          impl_->ComputeDecoderProj(prev0, prev1, dec_proj.data());
        }
      }
    }

    frame_cursor += t_valid;
    out_frame_offset += t_out;
  }

  CheckCancel(is_cancelled, cancel_ctx, cancel_token);

  // Merge standalone whitespace prefix tokens ('▁' -> ' ') onto the next non-whitespace token
  // so every token in DecodedOutput::tokens has a non-empty trimmed spelling for RecognitionContext.
  DecodedOutput out;
  std::vector<float> merged_log_probs;
  bool pending_space = false;
  float pending_lp = 0.0f;

  for (size_t i = 0; i < raw_ids.size(); ++i) {
    const int32_t tid = raw_ids[i];
    if (tid <= 1 || tid >= static_cast<int32_t>(impl_->tokens_table.size())) {
      continue;
    }
    std::string piece = impl_->tokens_table[static_cast<size_t>(tid)];
    if (TrimAsciiSpaces(piece).empty()) {
      pending_space = true;
      pending_lp += raw_log_probs[i];
      continue;
    }
    if (pending_space && (piece.empty() || piece[0] != ' ')) {
      piece.insert(piece.begin(), ' ');
    }
    const float lp = raw_log_probs[i] + (pending_space ? pending_lp : 0.0f);
    pending_space = false;
    pending_lp = 0.0f;

    out.tokens.push_back(std::move(piece));
    out.timestamps.push_back(static_cast<float>(raw_frames[i]) * 0.04f);
    merged_log_probs.push_back(lp);
  }

  // Detokenize Chinese + English + code-switched pieces with exact token-to-text alignment
  uint32_t prev_cp = 0;
  bool has_prev = false;
  for (const std::string &tok : out.tokens) {
    const bool has_leading_space = (!tok.empty() && tok[0] == ' ');
    const std::string spelling = TrimAsciiSpaces(tok);
    if (spelling.empty()) continue;

    const uint32_t first_cp = FirstCodepoint(spelling);
    if (has_prev && has_leading_space) {
      bool need_space = true;
      if (IsNoSpaceBefore(first_cp)) {
        need_space = false;
      } else if ((IsCjkCodepoint(prev_cp) || IsCjkPunct(prev_cp)) && IsCjkCodepoint(first_cp)) {
        need_space = false;
      }
      if (need_space) {
        out.text.push_back(' ');
      }
    }
    out.text.append(spelling);
    prev_cp = LastCodepoint(spelling);
    has_prev = true;
  }

  out.raw_json = BuildRawJson(out.text, out.tokens, out.timestamps, merged_log_probs);
  return out;
}

}  // namespace momo_xasr

extern "C" {

MoMoXASRCoreMLRuntime *MoMoCreateXASRCoreMLRuntime(
    const char *encoder_mlmodelc_path,
    const char *decoder_joiner_bin_path,
    const char *tokens_path,
    int32_t num_threads,
    char *error, size_t error_capacity) {
  try {
    auto core = momo_xasr::CoreMLRuntime::Create(
        encoder_mlmodelc_path, decoder_joiner_bin_path, tokens_path, num_threads);
    auto *handle = new MoMoXASRCoreMLRuntime();
    handle->impl = std::move(core);
    return handle;
  } catch (const std::exception &ex) {
    momo_xasr::SaveError(error, error_capacity, ex.what());
    return nullptr;
  } catch (...) {
    momo_xasr::SaveError(error, error_capacity, "Unknown C++ exception creating X-ASR CoreML runtime");
    return nullptr;
  }
}

void MoMoDestroyXASRCoreMLRuntime(MoMoXASRCoreMLRuntime *runtime) {
  delete runtime;
}

int32_t MoMoGetXASRCoreMLAcceleratorMask(const MoMoXASRCoreMLRuntime *runtime) {
  if (!runtime || !runtime->impl) return 0;
  return runtime->impl->accelerator_mask();
}

int MoMoTranscribeXASRCoreMLCancellable(
    MoMoXASRCoreMLRuntime *runtime,
    const float *samples, int32_t sample_count,
    MoMoCancelCallback is_cancelled, const void *cancel_context,
    MoMoCancelToken *cancel_token,
    MoMoXASRCoreMLResult **out_result,
    char *error, size_t error_capacity) {
  if (!out_result) {
    momo_xasr::SaveError(error, error_capacity, "Null out_result pointer");
    return 0;
  }
  *out_result = nullptr;
  if (!runtime || !runtime->impl) {
    momo_xasr::SaveError(error, error_capacity, "Null MoMoXASRCoreMLRuntime");
    return 0;
  }

  try {
    momo_xasr::DecodedOutput decoded = runtime->impl->Transcribe(
        samples, sample_count, is_cancelled, cancel_context, cancel_token);

    auto *res = static_cast<MoMoXASRCoreMLResult *>(std::calloc(1, sizeof(MoMoXASRCoreMLResult)));
    if (!res) throw std::bad_alloc();

    try {
      res->text = momo_xasr::DupCString(decoded.text);
      res->raw_json = momo_xasr::DupCString(decoded.raw_json);
      const int32_t n = static_cast<int32_t>(decoded.tokens.size());
      res->count = n;
      if (n > 0) {
        res->tokens = static_cast<char **>(std::calloc(static_cast<size_t>(n), sizeof(char *)));
        res->timestamps = static_cast<float *>(std::malloc(static_cast<size_t>(n) * sizeof(float)));
        if (!res->tokens || !res->timestamps) throw std::bad_alloc();
        for (int32_t i = 0; i < n; ++i) {
          res->tokens[i] = momo_xasr::DupCString(decoded.tokens[static_cast<size_t>(i)]);
          res->timestamps[i] = decoded.timestamps[static_cast<size_t>(i)];
        }
      }
    } catch (...) {
      MoMoDestroyXASRCoreMLResult(res);
      throw;
    }

    *out_result = res;
    return 1;
  } catch (const momo_xasr::CancelledError &) {
    return -2;
  } catch (const std::exception &ex) {
    momo_xasr::SaveError(error, error_capacity, ex.what());
    return 0;
  } catch (...) {
    momo_xasr::SaveError(error, error_capacity, "Unknown C++ exception during X-ASR CoreML decode");
    return 0;
  }
}

void MoMoDestroyXASRCoreMLResult(MoMoXASRCoreMLResult *result) {
  if (!result) return;
  std::free(result->text);
  std::free(result->raw_json);
  if (result->tokens) {
    for (int32_t i = 0; i < result->count; ++i) {
      std::free(result->tokens[i]);
    }
    std::free(result->tokens);
  }
  std::free(result->timestamps);
  std::free(result);
}

}  // extern "C"

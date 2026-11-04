#include "MoMoSherpaBridge.h"
#include "CancelToken.hpp"
#include <onnxruntime/onnxruntime_cxx_api.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <exception>
#include <limits>
#include <memory>
#include <mutex>
#include <numeric>
#include <stdexcept>
#include <string>
#include <sys/stat.h>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {

constexpr int kMaxEmbDim = 256;

struct SpeakerCancelled : public std::exception {
  const char *what() const noexcept override { return "cancelled"; }
};

inline void CheckSpeakerCancel(MoMoCancelCallback cb, const void *ctx,
                               const MoMoCancelToken *token = nullptr) {
  if ((token && token->IsCancelled()) || (cb && cb(ctx) != 0)) {
    throw SpeakerCancelled();
  }
}

inline float DotN(const float *a, const float *b, int dim) {
  double sum = 0.0;
  for (int i = 0; i < dim; ++i) sum += double(a[i]) * double(b[i]);
  return static_cast<float>(sum);
}

inline bool HasValidEmbeddingN(const float *emb, int dim) {
  for (int i = 0; i < dim; ++i) {
    if (emb[i] != 0.0f) return true;
  }
  return false;
}

inline bool NormalizeN(float *vec, int dim) {
  double norm = 0.0;
  for (int i = 0; i < dim; ++i) norm += double(vec[i]) * double(vec[i]);
  if (!std::isfinite(norm) || norm < 1e-12) return false;
  const float inv = static_cast<float>(1.0 / std::sqrt(norm));
  for (int i = 0; i < dim; ++i) vec[i] *= inv;
  for (int i = dim; i < kMaxEmbDim; ++i) vec[i] = 0.0f;
  return true;
}

void ExtractCpuEmbedding(const SherpaOnnxSpeakerEmbeddingExtractor *ext,
                         int dim, const float *clip, int clip_samples,
                         float out_emb[kMaxEmbDim]) {
  auto stream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(ext);
  if (!stream) throw std::runtime_error("Cannot create embedding stream");
  std::unique_ptr<const SherpaOnnxOnlineStream,
                  decltype(&SherpaOnnxDestroyOnlineStream)>
      owner(stream, SherpaOnnxDestroyOnlineStream);
  SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, clip, clip_samples);
  SherpaOnnxOnlineStreamInputFinished(stream);
  if (!SherpaOnnxSpeakerEmbeddingExtractorIsReady(ext, stream)) {
    throw std::runtime_error("Incomplete embedding features");
  }
  auto vector = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(ext, stream);
  if (!vector) throw std::runtime_error("Missing embedding");
  std::unique_ptr<const float,
                  decltype(&SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding)>
      vector_owner(vector, SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding);
  for (int j = 0; j < dim; ++j) out_emb[j] = vector[j];
  for (int j = dim; j < kMaxEmbDim; ++j) out_emb[j] = 0.0f;
  if (!NormalizeN(out_emb, dim)) {
    throw std::runtime_error("Invalid embedding");
  }
}

// Kaldi 80-bin Mel-Fbank (snip_edges=false -> 300 frames for 48,000 samples at 16 kHz,
// matching sherpa-onnx FeatureExtractorConfig default) with per-bin global-mean CMVN.
class KaldiStaticFbank80 {
 public:
  static constexpr int kSampleRate = 16000;
  static constexpr int kStaticSamples = 48000;  // 3.0 s
  static constexpr int kWinLen = 400;           // 25 ms
  static constexpr int kShift = 160;            // 10 ms
  static constexpr int kStaticFrames = (kStaticSamples + kShift / 2) / kShift;  // 300
  static constexpr int kNfft = 512;
  static constexpr int kNumBins = kNfft / 2 + 1;
  static constexpr int kNumMels = 80;
  static constexpr float kPreemph = 0.97f;

  KaldiStaticFbank80(float high_freq, bool use_povey) {
    window_.resize(kWinLen);
    constexpr double kTwoPi = 6.28318530717958647692;
    for (int i = 0; i < kWinLen; ++i) {
      if (use_povey) {
        const double hann = 0.5 - 0.5 * std::cos(kTwoPi * i / (kWinLen - 1));
        window_[static_cast<size_t>(i)] =
            static_cast<float>(std::pow(std::max(0.0, hann), 0.85));
      } else {
        window_[static_cast<size_t>(i)] =
            static_cast<float>(0.54 - 0.46 * std::cos(kTwoPi * i / (kWinLen - 1)));
      }
    }

    bitrev_.assign(kNfft, 0);
    for (int i = 1, j = 0; i < kNfft; ++i) {
      int bit = kNfft >> 1;
      for (; j & bit; bit >>= 1) j ^= bit;
      j ^= bit;
      bitrev_[static_cast<size_t>(i)] = j;
    }

    twiddle_re_.resize(kNfft);
    twiddle_im_.resize(kNfft);
    for (int len = 2; len <= kNfft; len <<= 1) {
      const int half = len >> 1;
      const double ang = -kTwoPi / len;
      for (int k = 0; k < half; ++k) {
        twiddle_re_[static_cast<size_t>(half + k)] =
            static_cast<float>(std::cos(ang * k));
        twiddle_im_[static_cast<size_t>(half + k)] =
            static_cast<float>(std::sin(ang * k));
      }
    }

    auto mel = [](float f) -> float {
      return 1127.0f * std::log(1.0f + f / 700.0f);
    };
    const float ml = mel(20.0f);
    const float mh = mel(high_freq);
    const float dm = (mh - ml) / static_cast<float>(kNumMels + 1);
    const float bin_width = static_cast<float>(kSampleRate) / kNfft;

    mel_bins_.resize(kNumMels);
    for (int m = 0; m < kNumMels; ++m) {
      const float L = ml + m * dm;
      const float C = ml + (m + 1) * dm;
      const float R = ml + (m + 2) * dm;
      MelFilter flt;
      flt.start_bin = kNumBins;
      for (int k = 0; k < kNumBins; ++k) {
        const float mf = mel(bin_width * k);
        if (mf > L && mf < R) {
          const float w = (mf <= C) ? ((mf - L) / (C - L)) : ((R - mf) / (R - C));
          if (w > 0.0f) {
            if (flt.weights.empty()) flt.start_bin = k;
            flt.weights.push_back(w);
          }
        }
      }
      mel_bins_[static_cast<size_t>(m)] = std::move(flt);
    }
  }

  void Compute48k(const float *samples_48k, float *out_fbank) const {
    std::array<float, kWinLen> frame{};
    std::array<float, kNfft> re{};
    std::array<float, kNfft> im{};
    std::array<float, kNumBins> power{};
    std::array<double, kNumMels> col_sum{};
    constexpr float kEps = std::numeric_limits<float>::epsilon();

    for (int t = 0; t < kStaticFrames; ++t) {
      const int first_sample = t * kShift + (kShift / 2) - (kWinLen / 2);  // t*160 - 120
      double mean = 0.0;
      for (int i = 0; i < kWinLen; ++i) {
        int s = first_sample + i;
        while (s < 0 || s >= kStaticSamples) {
          if (s < 0) s = -s - 1;
          else s = 2 * kStaticSamples - 1 - s;
        }
        const float v = samples_48k[s];
        frame[static_cast<size_t>(i)] = v;
        mean += v;
      }
      const float dc = static_cast<float>(mean / kWinLen);
      for (int i = 0; i < kWinLen; ++i) {
        frame[static_cast<size_t>(i)] -= dc;
      }
      for (int i = kWinLen - 1; i > 0; --i) {
        frame[static_cast<size_t>(i)] -= kPreemph * frame[static_cast<size_t>(i - 1)];
      }
      frame[0] *= (1.0f - kPreemph);

      re.fill(0.0f);
      im.fill(0.0f);
      for (int i = 0; i < kWinLen; ++i) {
        re[static_cast<size_t>(bitrev_[static_cast<size_t>(i)])] =
            frame[static_cast<size_t>(i)] * window_[static_cast<size_t>(i)];
      }

      for (int len = 2; len <= kNfft; len <<= 1) {
        const int half = len >> 1;
        for (int i = 0; i < kNfft; i += len) {
          for (int k = 0; k < half; ++k) {
            const float cr = twiddle_re_[static_cast<size_t>(half + k)];
            const float ci = twiddle_im_[static_cast<size_t>(half + k)];
            const size_t u_idx = static_cast<size_t>(i + k);
            const size_t v_idx = static_cast<size_t>(i + k + half);
            const float ur = re[u_idx], ui = im[u_idx];
            const float vr = re[v_idx] * cr - im[v_idx] * ci;
            const float vi = re[v_idx] * ci + im[v_idx] * cr;
            re[u_idx] = ur + vr;
            im[u_idx] = ui + vi;
            re[v_idx] = ur - vr;
            im[v_idx] = ui - vi;
          }
        }
      }

      for (int k = 0; k < kNumBins; ++k) {
        const float r = re[static_cast<size_t>(k)];
        const float m = im[static_cast<size_t>(k)];
        power[static_cast<size_t>(k)] = r * r + m * m;
      }

      float *dst = out_fbank + static_cast<size_t>(t) * kNumMels;
      for (int m = 0; m < kNumMels; ++m) {
        const auto &flt = mel_bins_[static_cast<size_t>(m)];
        float e = 0.0f;
        for (size_t j = 0; j < flt.weights.size(); ++j) {
          e += flt.weights[j] * power[static_cast<size_t>(flt.start_bin) + j];
        }
        const float val = std::log(std::max(e, kEps));
        dst[m] = val;
        col_sum[static_cast<size_t>(m)] += val;
      }
    }

    std::array<float, kNumMels> col_mean{};
    for (int m = 0; m < kNumMels; ++m) {
      col_mean[static_cast<size_t>(m)] =
          static_cast<float>(col_sum[static_cast<size_t>(m)] / kStaticFrames);
    }
    for (int t = 0; t < kStaticFrames; ++t) {
      float *dst = out_fbank + static_cast<size_t>(t) * kNumMels;
      for (int m = 0; m < kNumMels; ++m) {
        dst[m] -= col_mean[static_cast<size_t>(m)];
      }
    }
  }

 private:
  struct MelFilter {
    int start_bin = 0;
    std::vector<float> weights;
  };
  std::vector<float> window_;
  std::vector<int> bitrev_;
  std::vector<float> twiddle_re_;
  std::vector<float> twiddle_im_;
  std::vector<MelFilter> mel_bins_;
};

// Static-shape [1, 298, 80] CoreML ANE extractor for 192-d 3D-Speaker ERes2NetV2.
// Fixing N=1, T=298 avoids CoreML E5RT dynamic statistical-pooling NaNs and
// fuses 312/315 Conv+Pooling nodes onto Apple Neural Engine (~8.9x speedup).
class Eres2NetCoreMLExtractor {
 public:
  static std::unique_ptr<Eres2NetCoreMLExtractor> TryCreate(
      Ort::Env &env, const char *model_path, const std::string &cache_dir,
      int32_t cpu_threads, const SherpaOnnxSpeakerEmbeddingExtractor *cpu_ref) {
    if (!model_path || !cpu_ref) return nullptr;
    try {
      std::string in_name, out_name;
      std::string sym_n = "N", sym_t = "T";
      {
        Ort::SessionOptions probe_opts;
        probe_opts.SetIntraOpNumThreads(1);
        probe_opts.SetInterOpNumThreads(1);
        probe_opts.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_DISABLE_ALL);
        Ort::Session probe(env, model_path, probe_opts);
        if (probe.GetInputCount() != 1 || probe.GetOutputCount() < 1) {
          return nullptr;
        }
        Ort::AllocatorWithDefaultOptions alloc;
        auto in_alloc = probe.GetInputNameAllocated(0, alloc);
        auto out_alloc = probe.GetOutputNameAllocated(0, alloc);
        if (!in_alloc || !out_alloc) return nullptr;
        in_name = in_alloc.get();
        out_name = out_alloc.get();
        auto ti = probe.GetInputTypeInfo(0);
        auto ts = ti.GetTensorTypeAndShapeInfo();
        auto shape = ts.GetShape();
        if (shape.size() != 3 || (shape[2] > 0 && shape[2] != 80)) {
          return nullptr;
        }
        std::vector<const char *> syms(shape.size(), nullptr);
        ts.GetSymbolicDimensions(syms.data(), syms.size());
        if (syms[0] && syms[0][0] != '\0') sym_n = syms[0];
        if (syms[1] && syms[1][0] != '\0') sym_t = syms[1];
      }

      Ort::SessionOptions opts;
      opts.SetIntraOpNumThreads(std::clamp<int32_t>(cpu_threads, 1, 2));
      opts.SetInterOpNumThreads(1);
      opts.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
      opts.AddConfigEntry("session.intra_op.allow_spinning", "0");
      opts.AddConfigEntry("session.inter_op.allow_spinning", "0");
      Ort::ThrowOnError(Ort::GetApi().AddFreeDimensionOverrideByName(
          opts, sym_n.c_str(), 1));
      Ort::ThrowOnError(Ort::GetApi().AddFreeDimensionOverrideByName(
          opts, sym_t.c_str(), KaldiStaticFbank80::kStaticFrames));

      std::unordered_map<std::string, std::string> coreml_opts{
          {"ModelFormat", "NeuralNetwork"},
          {"MLComputeUnits", "CPUAndNeuralEngine"},
          {"RequireStaticInputShapes", "1"},
      };
      if (!cache_dir.empty()) {
        ::mkdir(cache_dir.c_str(), 0755);
        coreml_opts["ModelCacheDirectory"] = cache_dir;
      }
      opts.AppendExecutionProvider("CoreML", coreml_opts);

      auto session = std::make_unique<Ort::Session>(env, model_path, opts);

      // Calibrate Mel high_freq / window against SherpaOnnx CPU reference on a
      // deterministic multi-harmonic + fricative 3.0 s signal and verify >= 0.995 cosine.
      std::vector<float> test_sig(KaldiStaticFbank80::kStaticSamples, 0.0f);
      constexpr double kTwoPi = 6.28318530717958647692;
      for (int i = 0; i < KaldiStaticFbank80::kStaticSamples; ++i) {
        const double t = double(i) / 16000.0;
        const double env_mod = 0.35 + 0.65 * (0.5 - 0.5 * std::cos(kTwoPi * 2.3 * t));
        const double f0 = 145.0 + 18.0 * std::sin(kTwoPi * 1.1 * t);
        double s = 0.0;
        for (int h = 1; h <= 24; ++h) {
          s += (1.0 / double(h)) * std::sin(kTwoPi * f0 * h * t + 0.3 * h);
        }
        // High-frequency fricative energy across 7.2-7.95 kHz to disambiguate 7600 vs 8000 Hz.
        s += 0.08 * std::sin(kTwoPi * 7750.0 * t) + 0.06 * std::cos(kTwoPi * 7910.0 * t);
        test_sig[static_cast<size_t>(i)] = static_cast<float>(0.08 * env_mod * s);
      }

      std::array<float, kMaxEmbDim> ref_emb{};
      ExtractCpuEmbedding(cpu_ref, 192, test_sig.data(),
                          KaldiStaticFbank80::kStaticSamples, ref_emb.data());

      // Verify exact Kaldi Fbank parity (7600 Hz Nyquist-400, Povey window -> >= 0.999 cosine)
      // against SherpaOnnx CPU reference before promoting CoreML ANE session.
      auto fb = std::make_unique<KaldiStaticFbank80>(7600.0f, true);
      std::vector<float> feats(
          static_cast<size_t>(KaldiStaticFbank80::kStaticFrames) *
          KaldiStaticFbank80::kNumMels);
      fb->Compute48k(test_sig.data(), feats.data());
      Ort::MemoryInfo mem_info =
          Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
      std::array<int64_t, 3> shape{1, KaldiStaticFbank80::kStaticFrames,
                                   KaldiStaticFbank80::kNumMels};
      auto in_tensor = Ort::Value::CreateTensor<float>(
          mem_info, feats.data(), feats.size(), shape.data(), shape.size());
      const char *in_ptrs[] = {in_name.c_str()};
      const char *out_ptrs[] = {out_name.c_str()};
      auto outs = session->Run(Ort::RunOptions{nullptr}, in_ptrs, &in_tensor,
                               1, out_ptrs, 1);
      if (outs.empty() || !outs[0].IsTensor()) return nullptr;
      auto out_shape = outs[0].GetTensorTypeAndShapeInfo().GetShape();
      size_t elem_cnt = 1;
      for (int64_t d : out_shape) {
        if (d <= 0) elem_cnt = 0;
        else elem_cnt *= static_cast<size_t>(d);
      }
      if (elem_cnt != 192) return nullptr;
      const float *raw = outs[0].GetTensorData<float>();
      std::array<float, kMaxEmbDim> cand_emb{};
      for (int j = 0; j < 192; ++j) {
        if (!std::isfinite(raw[j])) return nullptr;
        cand_emb[static_cast<size_t>(j)] = raw[j];
      }
      if (!NormalizeN(cand_emb.data(), 192)) return nullptr;
      const float best_sim = DotN(cand_emb.data(), ref_emb.data(), 192);
      if (best_sim < 0.995f) {
        return nullptr;
      }

      return std::unique_ptr<Eres2NetCoreMLExtractor>(
          new Eres2NetCoreMLExtractor(std::move(session), std::move(fb),
                                      std::move(in_name), std::move(out_name)));
    } catch (...) {
      return nullptr;
    }
  }

  bool ComputeNormalized(const float *clip, int clip_samples,
                         float out_emb[kMaxEmbDim]) const {
    if (!clip || clip_samples <= 0) return false;
    constexpr int kStatic = KaldiStaticFbank80::kStaticSamples;
    if (clip_samples == kStatic) {
      return RunSingle48k(clip, out_emb);
    }
    if (clip_samples > 54000) {
      std::array<float, kMaxEmbDim> emb_a{}, emb_b{};
      if (!RunSingle48k(clip, emb_a.data()) ||
          !RunSingle48k(clip + (clip_samples - kStatic), emb_b.data())) {
        return false;
      }
      for (int j = 0; j < 192; ++j) {
        out_emb[j] = emb_a[static_cast<size_t>(j)] + emb_b[static_cast<size_t>(j)];
      }
      for (int j = 192; j < kMaxEmbDim; ++j) out_emb[j] = 0.0f;
      return NormalizeN(out_emb, 192);
    }
    if (clip_samples > kStatic) {
      const int origin = (clip_samples - kStatic) / 2;
      return RunSingle48k(clip + origin, out_emb);
    }

    // Tile shorter speech clips (< 3.0 s) to static 48,000 samples with 64-sample
    // raised-cosine crossfades; statistical mean+std pooling is duration-invariant.
    std::vector<float> buf(kStatic, 0.0f);
    constexpr int kFade = 64;
    constexpr double kPi = 3.14159265358979323846;
    int filled = clip_samples;
    std::copy(clip, clip + clip_samples, buf.begin());
    while (filled < kStatic) {
      if (filled >= kFade && clip_samples > kFade * 2) {
        for (int k = 0; k < kFade; ++k) {
          const float alpha = static_cast<float>(
              0.5 - 0.5 * std::cos(kPi * double(k + 1) / double(kFade + 1)));
          const int dst = filled - kFade + k;
          buf[static_cast<size_t>(dst)] =
              (1.0f - alpha) * buf[static_cast<size_t>(dst)] + alpha * clip[k];
        }
        const int copy_n = std::min(kStatic - filled, clip_samples - kFade);
        std::copy(clip + kFade, clip + kFade + copy_n, buf.begin() + filled);
        filled += copy_n;
      } else {
        const int copy_n = std::min(kStatic - filled, clip_samples);
        std::copy(clip, clip + copy_n, buf.begin() + filled);
        filled += copy_n;
      }
    }
    return RunSingle48k(buf.data(), out_emb);
  }

 private:
  Eres2NetCoreMLExtractor(std::unique_ptr<Ort::Session> session,
                          std::unique_ptr<KaldiStaticFbank80> fbank,
                          std::string in_name, std::string out_name)
      : session_(std::move(session)),
        fbank_(std::move(fbank)),
        in_name_(std::move(in_name)),
        out_name_(std::move(out_name)) {}

  bool RunSingle48k(const float *samples_48k, float out_emb[kMaxEmbDim]) const {
    std::vector<float> feats(
        static_cast<size_t>(KaldiStaticFbank80::kStaticFrames) *
        KaldiStaticFbank80::kNumMels);
    fbank_->Compute48k(samples_48k, feats.data());
    std::array<int64_t, 3> shape{1, KaldiStaticFbank80::kStaticFrames,
                                 KaldiStaticFbank80::kNumMels};
    auto in_tensor = Ort::Value::CreateTensor<float>(
        mem_info_, feats.data(), feats.size(), shape.data(), shape.size());
    const char *in_ptrs[] = {in_name_.c_str()};
    const char *out_ptrs[] = {out_name_.c_str()};
    auto outs = session_->Run(Ort::RunOptions{nullptr}, in_ptrs, &in_tensor, 1,
                              out_ptrs, 1);
    if (outs.empty() || !outs[0].IsTensor()) return false;
    const float *raw = outs[0].GetTensorData<float>();
    for (int j = 0; j < 192; ++j) {
      if (!std::isfinite(raw[j])) return false;
      out_emb[j] = raw[j];
    }
    for (int j = 192; j < kMaxEmbDim; ++j) out_emb[j] = 0.0f;
    return NormalizeN(out_emb, 192);
  }

  std::unique_ptr<Ort::Session> session_;
  std::unique_ptr<KaldiStaticFbank80> fbank_;
  std::string in_name_;
  std::string out_name_;
  Ort::MemoryInfo mem_info_ =
      Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
};

struct SpeakerEmbeddingBackend {
  const SherpaOnnxSpeakerEmbeddingExtractor *cpu_ext = nullptr;
  std::unique_ptr<Eres2NetCoreMLExtractor> coreml_ext;
};

void ExtractNormalizedEmbedding(const SpeakerEmbeddingBackend &backend,
                                int dim, const float *clip, int clip_samples,
                                float out_emb[kMaxEmbDim]) {
  if (dim == 192 && backend.coreml_ext &&
      backend.coreml_ext->ComputeNormalized(clip, clip_samples, out_emb)) {
    return;
  }
  ExtractCpuEmbedding(backend.cpu_ext, dim, clip, clip_samples, out_emb);
}

// Assemble clean speech spans with 64-sample raised-cosine joins.
// - For dynamic 192-dim ERes2NetV2: preserves true natural duration (up to
//   max_192_samples, default 4.0 s) without artificial 3 s loop-tiling; only
//   crossfade-pads sub-0.60 s fragments up to 0.60 s (9,600 samples) so
//   attentive pooling has enough frames.
// - For legacy fixed-shape 256-dim extractors: normalizes envelope and pads/crops
//   to 48,000 samples (3.0 s).
bool BuildCleanSpeechClip(const float *audio,
                          const std::vector<std::pair<int, int>> &spans,
                          int min_samples, int emb_dim,
                          std::vector<float> &out_clip,
                          int max_192_samples = 64000) {
  int total_raw = 0;
  for (const auto &[s, e] : spans) {
    if (e > s) total_raw += (e - s);
  }
  if (total_raw < min_samples) return false;

  constexpr int kFade = 64;
  constexpr double kPi = 3.14159265358979323846;
  std::vector<float> pooled;
  pooled.reserve(static_cast<size_t>(total_raw));
  float max_abs = 0.0f;
  for (const auto &[s, e] : spans) {
    const int seg_len = e - s;
    if (seg_len <= 0) continue;
    for (int i = s; i < e; ++i) {
      const float a = std::abs(audio[i]);
      if (a > max_abs) max_abs = a;
    }
    if (pooled.size() >= static_cast<size_t>(kFade) && seg_len >= kFade) {
      const size_t base = pooled.size() - static_cast<size_t>(kFade);
      for (int k = 0; k < kFade; ++k) {
        const float alpha = static_cast<float>(
            0.5 - 0.5 * std::cos(kPi * double(k + 1) / double(kFade + 1)));
        pooled[base + static_cast<size_t>(k)] =
            (1.0f - alpha) * pooled[base + static_cast<size_t>(k)] +
            alpha * audio[s + k];
      }
      pooled.insert(pooled.end(), audio + s + kFade, audio + e);
    } else {
      pooled.insert(pooled.end(), audio + s, audio + e);
    }
  }
  const int p_len = static_cast<int>(pooled.size());
  if (p_len < min_samples || max_abs < 1e-5f) return false;

  // Normalize active speech envelope to -22 dBFS across near/far-field recordings
  // with p15 noise-floor protection and soft tanh limiting for both 192-dim and 256-dim.
  {
    constexpr int kRmsWin = 320;
    const int nf = p_len / kRmsWin;
    if (nf >= 2) {
      std::vector<float> frms(static_cast<size_t>(nf));
      for (int f = 0; f < nf; ++f) {
        double sq = 0.0;
        const float *p = pooled.data() + f * kRmsWin;
        for (int k = 0; k < kRmsWin; ++k) sq += double(p[k]) * double(p[k]);
        frms[static_cast<size_t>(f)] = static_cast<float>(std::sqrt(sq / kRmsWin));
      }
      auto sorted = frms;
      std::sort(sorted.begin(), sorted.end());
      const float p85 = sorted[static_cast<size_t>(nf * 85 / 100)];
      const float p15 = sorted[static_cast<size_t>(nf * 15 / 100)];
      const float gate = std::max(0.0008f, p85 * 0.25f);
      double active_sq = 0.0;
      int active_n = 0;
      for (int f = 0; f < nf; ++f) {
        if (frms[static_cast<size_t>(f)] >= gate) {
          const float *p = pooled.data() + f * kRmsWin;
          for (int k = 0; k < kRmsWin; ++k) {
            active_sq += double(p[k]) * double(p[k]);
          }
          active_n += kRmsWin;
        }
      }
      const float active_rms =
          active_n > 0 ? static_cast<float>(std::sqrt(active_sq / active_n))
                       : p85;
      if (active_rms > 1e-4f) {
        float g = std::clamp(0.08f / active_rms, 0.18f, 16.0f);
        if (p15 > 0.0018f) g = std::min(g, 0.025f / p15);
        if (std::abs(g - 1.0f) > 0.03f) {
          for (float &x : pooled) {
            float y = x * g;
            const float ay = std::abs(y);
            if (ay > 0.55f) {
              y = std::copysign(0.55f + 0.40f * std::tanh((ay - 0.55f) / 0.40f),
                                y);
            }
            x = y;
          }
        }
      }
    }
  }

  if (emb_dim == 192) {
    constexpr int kMinModelSamples = 9600;   // 0.60 s
    const int max_model_samples = std::clamp(max_192_samples, kMinModelSamples, 96000);
    if (p_len >= max_model_samples) {
      const int origin = (p_len - max_model_samples) / 2;
      out_clip.assign(pooled.begin() + origin,
                      pooled.begin() + origin + max_model_samples);
      return true;
    }
    if (p_len >= kMinModelSamples) {
      out_clip = std::move(pooled);
      return true;
    }
    out_clip.assign(static_cast<size_t>(kMinModelSamples), 0.0f);
    int filled = p_len;
    std::copy(pooled.begin(), pooled.end(), out_clip.begin());
    while (filled < kMinModelSamples) {
      if (filled >= kFade && p_len > kFade * 2) {
        for (int k = 0; k < kFade; ++k) {
          const float alpha = static_cast<float>(
              0.5 - 0.5 * std::cos(kPi * double(k + 1) / double(kFade + 1)));
          const int dst = filled - kFade + k;
          out_clip[static_cast<size_t>(dst)] =
              (1.0f - alpha) * out_clip[static_cast<size_t>(dst)] +
              alpha * pooled[static_cast<size_t>(k)];
        }
        const int copy_n = std::min(kMinModelSamples - filled, p_len - kFade);
        std::copy(pooled.begin() + kFade, pooled.begin() + kFade + copy_n,
                  out_clip.begin() + filled);
        filled += copy_n;
      } else {
        const int copy_n = std::min(kMinModelSamples - filled, p_len);
        std::copy(pooled.begin(), pooled.begin() + copy_n,
                  out_clip.begin() + filled);
        filled += copy_n;
      }
    }
    return true;
  }

  // Legacy 256-dim fixed 3 s WeSpeaker path.

  out_clip.assign(48000, 0.0f);
  if (p_len >= 48000) {
    const int origin = (p_len - 48000) / 2;
    std::copy(pooled.begin() + origin, pooled.begin() + origin + 48000,
              out_clip.begin());
    return true;
  }

  int filled = std::min(48000, p_len);
  std::copy(pooled.begin(), pooled.begin() + filled, out_clip.begin());
  while (filled < 48000) {
    if (filled >= kFade && p_len > kFade * 2) {
      for (int k = 0; k < kFade; ++k) {
        const float alpha = static_cast<float>(
            0.5 - 0.5 * std::cos(kPi * double(k + 1) / double(kFade + 1)));
        const int dst = filled - kFade + k;
        out_clip[static_cast<size_t>(dst)] =
            (1.0f - alpha) * out_clip[static_cast<size_t>(dst)] +
            alpha * pooled[static_cast<size_t>(k)];
      }
      const int copy_n = std::min(48000 - filled, p_len - kFade);
      std::copy(pooled.begin() + kFade, pooled.begin() + kFade + copy_n,
                out_clip.begin() + filled);
      filled += copy_n;
    } else {
      const int copy_n = std::min(48000 - filled, p_len);
      std::copy(pooled.begin(), pooled.begin() + copy_n,
                out_clip.begin() + filled);
      filled += copy_n;
    }
  }
  return true;
}

// Gentle floor-only envelope lift for segmentation ONLY (never fed to the
// embedding extractor). Normal near-field and mid-field speech (>= -22.5 dBFS)
// keeps unity gain (1.0x), while ultra-quiet far-field / Watch speech is lifted
// into the segmentation model's active operating range.
const float *LevelAudioForDiarization(const float *samples, int32_t count,
                                      std::vector<float> &scratch,
                                      float *out_noise_rms = nullptr) {
  constexpr int kFrame = 512;  // 32 ms @ 16 kHz
  const int num_frames = (count + kFrame - 1) / kFrame;
  if (num_frames <= 0) {
    if (out_noise_rms) *out_noise_rms = 0.0f;
    return samples;
  }

  struct FrameStat {
    float rms = 0.0f;
    float max_abs = 0.0f;
    float p90 = 0.0f;
  };
  std::vector<FrameStat> stats(static_cast<size_t>(num_frames));
  std::vector<float> mags;
  mags.reserve(kFrame);
  std::vector<float> all_rms(static_cast<size_t>(num_frames));

  for (int m = 0; m < num_frames; ++m) {
    const int s0 = m * kFrame;
    const int s1 = std::min<int>(count, s0 + kFrame);
    const int len = s1 - s0;
    mags.clear();
    double sum_sq = 0.0;
    float max_a = 0.0f;
    for (int i = s0; i < s1; ++i) {
      const float v = std::abs(samples[i]);
      if (v > max_a) max_a = v;
      sum_sq += double(v) * double(v);
      mags.push_back(v);
    }
    const size_t p90_idx = static_cast<size_t>((len - 1) * 9 / 10);
    std::nth_element(mags.begin(), mags.begin() + p90_idx, mags.end());
    const float rms = static_cast<float>(std::sqrt(sum_sq / std::max(1, len)));
    stats[static_cast<size_t>(m)] = {rms, max_a, mags[p90_idx]};
    all_rms[static_cast<size_t>(m)] = rms;
  }

  const size_t noise_idx = static_cast<size_t>((num_frames - 1) * 2 / 10);
  std::nth_element(all_rms.begin(), all_rms.begin() + noise_idx, all_rms.end());
  const float noise_rms = all_rms[noise_idx];
  if (out_noise_rms) *out_noise_rms = noise_rms;

  std::vector<float> gains(static_cast<size_t>(num_frames), 1.0f);
  std::vector<float> active_p90;
  active_p90.reserve(31);
  bool needs_gain = false;

  for (int m = 0; m < num_frames; ++m) {
    const int w0 = std::max(0, m - 15);
    const int w1 = std::min(num_frames - 1, m + 15);
    active_p90.clear();
    float local_max = 0.0f;
    for (int k = w0; k <= w1; ++k) {
      const auto &st = stats[static_cast<size_t>(k)];
      if (st.rms >= 0.0012f && st.max_abs >= 0.0045f &&
          st.rms >= std::max(0.0012f, noise_rms * 1.8f) &&
          st.max_abs >= 2.1f * st.rms) {
        active_p90.push_back(st.p90);
        if (st.max_abs > local_max) local_max = st.max_abs;
      }
    }
    if (active_p90.size() >= 3) {
      const size_t idx =
          std::min(active_p90.size() - 1, (active_p90.size() * 9) / 10);
      std::nth_element(active_p90.begin(), active_p90.begin() + idx,
                       active_p90.end());
      const float local_p95 = active_p90[idx];
      if (local_p95 >= 0.0018f && local_p95 < 0.075f) {
        float g = std::min(14.0f, 0.085f / local_p95);
        if (noise_rms > 1e-4f) g = std::min(g, 0.028f / noise_rms);
        if (local_max > 1e-4f) g = std::min(g, 0.90f / local_max);
        if (g > 1.03f) {
          gains[static_cast<size_t>(m)] = g;
          needs_gain = true;
        }
      }
    }
  }

  if (!needs_gain) return samples;

  for (int m = 1; m < num_frames; ++m) {
    gains[static_cast<size_t>(m)] =
        0.85f * gains[static_cast<size_t>(m - 1)] +
        0.15f * gains[static_cast<size_t>(m)];
  }
  for (int m = num_frames - 2; m >= 0; --m) {
    gains[static_cast<size_t>(m)] =
        0.85f * gains[static_cast<size_t>(m + 1)] +
        0.15f * gains[static_cast<size_t>(m)];
  }

  scratch.resize(static_cast<size_t>(count));
  float prev_g = gains[0];
  for (int m = 0; m < num_frames; ++m) {
    const float next_g = gains[static_cast<size_t>(m)];
    const int s0 = m * kFrame;
    const int s1 = std::min<int>(count, s0 + kFrame);
    const int len = std::max(1, s1 - s0);
    for (int i = s0; i < s1; ++i) {
      const float alpha = static_cast<float>(i - s0) / static_cast<float>(len);
      const float g = prev_g + (next_g - prev_g) * alpha;
      float y = samples[i] * g;
      const float ay = std::abs(y);
      if (ay > 0.85f) {
        y = std::copysign(0.85f + 0.15f * std::tanh((ay - 0.85f) / 0.15f), y);
      }
      scratch[static_cast<size_t>(i)] = y;
    }
    prev_g = next_g;
  }
  return scratch.data();
}

void SplitSpansInHalf(const std::vector<std::pair<int, int>> &spans,
                      std::vector<std::pair<int, int>> &first_half,
                      std::vector<std::pair<int, int>> &second_half) {
  first_half.clear();
  second_half.clear();
  int total = 0;
  for (const auto &[s, e] : spans) {
    if (e > s) total += (e - s);
  }
  const int target = total / 2;
  int acc = 0;
  for (const auto &[s, e] : spans) {
    if (e <= s) continue;
    const int len = e - s;
    if (acc + len <= target) {
      first_half.emplace_back(s, e);
    } else if (acc >= target) {
      second_half.emplace_back(s, e);
    } else {
      const int cut = s + (target - acc);
      if (cut > s) first_half.emplace_back(s, cut);
      if (e > cut) second_half.emplace_back(cut, e);
    }
    acc += len;
  }
}

bool ExtractTurnEmbeddingWithPurity(
    const SpeakerEmbeddingBackend &ext, int emb_dim,
    const float *raw_audio, const std::vector<std::pair<int, int>> &spans,
    int min_samples, MoMoCancelCallback is_cancelled, const void *cancel_context,
    const MoMoCancelToken *cancel_token,
    std::vector<float> &clip_buf, float out_emb[kMaxEmbDim], float *out_purity,
    float *out_emb_a = nullptr, float *out_emb_b = nullptr,
    bool *out_has_halves = nullptr) {
  if (out_purity) *out_purity = 1.0f;
  if (out_has_halves) *out_has_halves = false;
  int total = 0;
  for (const auto &[s, e] : spans) {
    if (e > s) total += (e - s);
  }
  if (total < min_samples) return false;

  if (emb_dim == 192) {
    if (total >= 44800) {  // >= 2.8 s: check half-to-half acoustic purity first
      std::vector<std::pair<int, int>> half_a, half_b;
      SplitSpansInHalf(spans, half_a, half_b);
      std::array<float, kMaxEmbDim> emb_a{}, emb_b{};
      if (BuildCleanSpeechClip(raw_audio, half_a, 14400, emb_dim, clip_buf, 48000) &&
          [&]() {
            CheckSpeakerCancel(is_cancelled, cancel_context, cancel_token);
            ExtractNormalizedEmbedding(ext, emb_dim, clip_buf.data(),
                                       static_cast<int>(clip_buf.size()),
                                       emb_a.data());
            return BuildCleanSpeechClip(raw_audio, half_b, 14400, emb_dim,
                                        clip_buf, 48000);
          }()) {
        CheckSpeakerCancel(is_cancelled, cancel_context, cancel_token);
        ExtractNormalizedEmbedding(ext, emb_dim, clip_buf.data(),
                                   static_cast<int>(clip_buf.size()),
                                   emb_b.data());
        if (out_emb_a) {
          std::copy(emb_a.begin(), emb_a.begin() + emb_dim, out_emb_a);
        }
        if (out_emb_b) {
          std::copy(emb_b.begin(), emb_b.begin() + emb_dim, out_emb_b);
        }
        if (out_has_halves) *out_has_halves = true;
        const float purity = DotN(emb_a.data(), emb_b.data(), emb_dim);
        if (out_purity) *out_purity = purity;
        if (purity >= 0.42f) {
          std::array<float, kMaxEmbDim> sum{};
          for (int d = 0; d < emb_dim; ++d) {
            sum[static_cast<size_t>(d)] =
                emb_a[static_cast<size_t>(d)] + emb_b[static_cast<size_t>(d)];
          }
          if (NormalizeN(sum.data(), emb_dim)) {
            std::copy(sum.begin(), sum.end(), out_emb);
            return true;
          }
        }
      }
    }
    if (!BuildCleanSpeechClip(raw_audio, spans, min_samples, emb_dim, clip_buf,
                              64000)) {
      return false;
    }
    CheckSpeakerCancel(is_cancelled, cancel_context, cancel_token);
    ExtractNormalizedEmbedding(ext, emb_dim, clip_buf.data(),
                               static_cast<int>(clip_buf.size()), out_emb);
    return true;
  }

  // Legacy 256-dim path.
  if (total >= 38400) {
    std::vector<std::pair<int, int>> half_a, half_b;
    SplitSpansInHalf(spans, half_a, half_b);
    std::array<float, kMaxEmbDim> emb_a{}, emb_b{};
    if (BuildCleanSpeechClip(raw_audio, half_a, 9600, emb_dim, clip_buf)) {
      CheckSpeakerCancel(is_cancelled, cancel_context, cancel_token);
      ExtractNormalizedEmbedding(ext, emb_dim, clip_buf.data(),
                                 static_cast<int>(clip_buf.size()), emb_a.data());
      if (BuildCleanSpeechClip(raw_audio, half_b, 9600, emb_dim, clip_buf)) {
        CheckSpeakerCancel(is_cancelled, cancel_context, cancel_token);
        ExtractNormalizedEmbedding(ext, emb_dim, clip_buf.data(),
                                   static_cast<int>(clip_buf.size()),
                                   emb_b.data());
        if (out_emb_a) {
          std::copy(emb_a.begin(), emb_a.begin() + emb_dim, out_emb_a);
        }
        if (out_emb_b) {
          std::copy(emb_b.begin(), emb_b.begin() + emb_dim, out_emb_b);
        }
        if (out_has_halves) *out_has_halves = true;
        const float purity = DotN(emb_a.data(), emb_b.data(), emb_dim);
        if (out_purity) *out_purity = purity;
        std::array<float, kMaxEmbDim> sum{};
        for (int d = 0; d < emb_dim; ++d) {
          sum[static_cast<size_t>(d)] =
              emb_a[static_cast<size_t>(d)] + emb_b[static_cast<size_t>(d)];
        }
        if (total >= 96000 &&
            BuildCleanSpeechClip(raw_audio, spans, 48000, emb_dim, clip_buf)) {
          CheckSpeakerCancel(is_cancelled, cancel_context, cancel_token);
          std::array<float, kMaxEmbDim> emb_mid{};
          ExtractNormalizedEmbedding(ext, emb_dim, clip_buf.data(),
                                     static_cast<int>(clip_buf.size()),
                                     emb_mid.data());
          for (int d = 0; d < emb_dim; ++d) {
            sum[static_cast<size_t>(d)] += emb_mid[static_cast<size_t>(d)];
          }
        }
        if (NormalizeN(sum.data(), emb_dim)) {
          std::copy(sum.begin(), sum.end(), out_emb);
          return true;
        }
      }
    }
  }

  if (!BuildCleanSpeechClip(raw_audio, spans, min_samples, emb_dim, clip_buf)) {
    return false;
  }
  CheckSpeakerCancel(is_cancelled, cancel_context, cancel_token);
  ExtractNormalizedEmbedding(ext, emb_dim, clip_buf.data(),
                             static_cast<int>(clip_buf.size()), out_emb);
  return true;
}

struct EnrolledMatch {
  int person_id = -1;
  float score = -1.0f;
};

void CollectScoresByEnrolledPerson(
    const float *vec, int emb_dim, const float *enrolled_embeddings,
    const int32_t *enrolled_person_ids, int32_t enrolled_count,
    std::vector<std::pair<int, float>> &out_by_person) {
  out_by_person.clear();
  if (!enrolled_embeddings || !enrolled_person_ids || enrolled_count <= 0) {
    return;
  }
  for (int k = 0; k < enrolled_count; ++k) {
    const int pid = enrolled_person_ids[k];
    const float s = DotN(
        vec, enrolled_embeddings + static_cast<size_t>(k) * static_cast<size_t>(emb_dim),
        emb_dim);
    auto it = std::find_if(out_by_person.begin(), out_by_person.end(),
                           [pid](const auto &p) { return p.first == pid; });
    if (it == out_by_person.end()) {
      out_by_person.emplace_back(pid, s);
    } else if (s > it->second) {
      it->second = s;
    }
  }
}

EnrolledMatch MatchEnrolledPerson(const float *vec, int emb_dim,
                                  const float *enrolled_embeddings,
                                  const int32_t *enrolled_person_ids,
                                  int32_t enrolled_count) {
  std::vector<std::pair<int, float>> by_person;
  CollectScoresByEnrolledPerson(vec, emb_dim, enrolled_embeddings,
                                enrolled_person_ids, enrolled_count, by_person);
  if (by_person.empty()) return {};
  int best_person = -1;
  float best_score = -2.0f;
  float second_person_score = -2.0f;
  for (const auto &[pid, s] : by_person) {
    if (s > best_score) {
      second_person_score = best_score;
      best_score = s;
      best_person = pid;
    } else if (s > second_person_score) {
      second_person_score = s;
    }
  }
  const float min_score = (emb_dim == 192) ? 0.60f : 0.76f;
  const float min_margin = (emb_dim == 192) ? 0.07f : 0.045f;
  if (best_score >= min_score &&
      (by_person.size() == 1 || best_score - second_person_score >= min_margin)) {
    return {best_person, best_score};
  }
  return {};
}

bool HasOneSidedEnrolledDropoff(const float *left_vec, const float *right_vec,
                                int emb_dim, float disjoint_sim,
                                const float *enrolled_embeddings,
                                const int32_t *enrolled_person_ids,
                                int32_t enrolled_count) {
  const float max_sim_ceil = (emb_dim == 192) ? 0.56f : 0.74f;
  if (disjoint_sim >= max_sim_ceil || !enrolled_embeddings ||
      !enrolled_person_ids || enrolled_count <= 0) {
    return false;
  }
  std::vector<std::pair<int, float>> left_scores, right_scores;
  CollectScoresByEnrolledPerson(left_vec, emb_dim, enrolled_embeddings,
                                enrolled_person_ids, enrolled_count, left_scores);
  CollectScoresByEnrolledPerson(right_vec, emb_dim, enrolled_embeddings,
                                enrolled_person_ids, enrolled_count, right_scores);
  const float strong_floor = (emb_dim == 192) ? 0.60f : 0.76f;
  const float drop_min = (emb_dim == 192) ? 0.16f : 0.13f;
  for (const auto &[pid, sL] : left_scores) {
    float sR = -1.0f;
    for (const auto &[rpid, rs] : right_scores) {
      if (rpid == pid) {
        sR = rs;
        break;
      }
    }
    if (std::max(sL, sR) >= strong_floor && std::abs(sL - sR) >= drop_min) {
      return true;
    }
  }
  return false;
}

int FindEnergyValleySample(const float *audio, int count, int search_start,
                           int search_end) {
  const int lo = std::max(0, std::min(count - 1, search_start));
  const int hi = std::max(lo + 1, std::min(count, search_end));
  constexpr int kWin = 320;   // 20 ms
  constexpr int kHop = 160;   // 10 ms
  if (hi - lo <= kWin) return (lo + hi) / 2;

  int best_pos = (lo + hi) / 2;
  double best_energy = 1e30;
  const int center = (lo + hi) / 2;
  const double half_span = std::max(1.0, 0.5 * double(hi - lo));

  for (int pos = lo; pos + kWin <= hi; pos += kHop) {
    double sum_sq = 0.0;
    for (int i = pos; i < pos + kWin; ++i) {
      sum_sq += double(audio[i]) * double(audio[i]);
    }
    const int mid = pos + kWin / 2;
    const double dist_bias =
        1.0 + 0.15 * std::abs(double(mid - center)) / half_span;
    const double cost = (sum_sq / kWin + 1e-7) * dist_bias;
    if (cost < best_energy) {
      best_energy = cost;
      best_pos = mid;
    }
  }
  return best_pos;
}

inline void ComputePowersetMarginals(const float *probs, int num_speakers,
                                     float inv_weight, float out_m[5]) {
  out_m[0] = 0.0f;
  if (num_speakers == 4) {
    out_m[1] = (probs[1] + probs[5] + probs[6] + probs[7]) * inv_weight;
    out_m[2] = (probs[2] + probs[5] + probs[8] + probs[9]) * inv_weight;
    out_m[3] = (probs[3] + probs[6] + probs[8] + probs[10]) * inv_weight;
    out_m[4] = (probs[4] + probs[7] + probs[9] + probs[10]) * inv_weight;
  } else {
    out_m[1] = (probs[1] + probs[4] + probs[5]) * inv_weight;
    out_m[2] = (probs[2] + probs[4] + probs[6]) * inv_weight;
    out_m[3] = (probs[3] + probs[5] + probs[6]) * inv_weight;
    out_m[4] = 0.0f;
  }
}

inline int MapPowersetClass(int c, int num_speakers, const int *pi) {
  if (c == 0) return 0;
  if (c <= num_speakers) return 1 + pi[c - 1];
  if (num_speakers == 4) {
    constexpr int kPairs[6][2] = {{0, 1}, {0, 2}, {0, 3}, {1, 2}, {1, 3}, {2, 3}};
    constexpr int kPairClass[4][4] = {
        {-1, 5, 6, 7}, {5, -1, 8, 9}, {6, 8, -1, 10}, {7, 9, 10, -1}};
    const int a = pi[kPairs[c - 5][0]];
    const int b = pi[kPairs[c - 5][1]];
    return kPairClass[a][b];
  }
  if (c == 4) return pi[0] + pi[1] + 3;
  if (c == 5) return pi[0] + pi[2] + 3;
  return pi[1] + pi[2] + 3;
}

}  // namespace

struct MoMoSpeakerRuntime {
  Ort::Env env{ORT_LOGGING_LEVEL_ERROR, "MoMoSpeakers"};
  std::unique_ptr<Ort::Session> segmentation;
  SpeakerEmbeddingBackend embedding;
  bool seg_uses_coreml = false;
  bool emb_uses_coreml = false;
  int window_samples = 160000;
  int half_window_samples = 80000;
  int shift = 270;
  int offset = 495;
  int num_speakers = 3;
  int num_classes = 7;
  int embedding_dim = 192;
  std::string seg_in_name;
  std::string seg_out_name;
  Ort::MemoryInfo seg_memory =
      Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
  std::vector<std::array<int, 4>> perms;
  std::mutex seg_scratch_mutex;
  std::vector<float> seg_padded;
  ~MoMoSpeakerRuntime() {
    if (embedding.cpu_ext) {
      SherpaOnnxDestroySpeakerEmbeddingExtractor(embedding.cpu_ext);
    }
  }
};

namespace {

void RunSlidingPowersetSegmentation(
    MoMoSpeakerRuntime *runtime, const float *seg_samples, int32_t count,
    MoMoCancelCallback is_cancelled, const void *cancel_context,
    MoMoCancelToken *cancel_token,
    int total_frames, std::vector<int> &exclusive_labels,
    std::vector<int> &labels, int *out_overlap_frames = nullptr) {
  const int C = runtime->num_classes;
  const int K = runtime->num_speakers;
  const int win_samples = runtime->window_samples;
  const int step_frames = std::max(1, runtime->half_window_samples / runtime->shift);
  const int win_step = step_frames * runtime->shift;

  std::vector<float> global_probs(
      static_cast<size_t>(total_frames) * static_cast<size_t>(C), 0.0f);
  std::vector<float> global_weights(static_cast<size_t>(total_frames), 0.0f);

  std::unique_lock<std::mutex> scratch_lock(runtime->seg_scratch_mutex,
                                            std::try_to_lock);
  std::vector<float> fallback_padded;
  std::vector<float> &padded =
      scratch_lock.owns_lock() ? runtime->seg_padded : fallback_padded;
  if (padded.size() != static_cast<size_t>(win_samples)) {
    padded.assign(static_cast<size_t>(win_samples), 0.0f);
  }
  int64_t shape[] = {1, 1, win_samples};
  const char *inputs[] = {runtime->seg_in_name.c_str()};
  const char *outputs[] = {runtime->seg_out_name.c_str()};
  const auto &perms = runtime->perms;
  momo_bridge::ScopedCancellableRunOptions shared_run_opts(cancel_token);

  for (int win_idx = 0;; ++win_idx) {
    CheckSpeakerCancel(is_cancelled, cancel_context, cancel_token);
    const int win_start = win_idx * win_step;
    if (win_start >= count) break;

    const int copy_n = std::min<int>(win_samples, count - win_start);
    std::copy(seg_samples + win_start, seg_samples + win_start + copy_n,
              padded.begin());
    if (copy_n < win_samples) {
      std::fill(padded.begin() + copy_n, padded.end(), 0.0f);
    }

    auto input = Ort::Value::CreateTensor<float>(
        runtime->seg_memory, padded.data(), padded.size(), shape, 3);
    auto result = runtime->segmentation->Run(
        shared_run_opts.get(), inputs, &input, 1, outputs, 1);
    auto dims = result[0].GetTensorTypeAndShapeInfo().GetShape();
    if (dims.size() != 3 || dims[0] != 1 || dims[2] != C || dims[1] < 1 ||
        dims[1] > 1600) {
      throw std::runtime_error("Invalid segmentation output");
    }

    const float *scores = result[0].GetTensorData<float>();
    const int win_frames = static_cast<int>(dims[1]);
    int valid_local_frames = 0;
    while (valid_local_frames < win_frames &&
           win_start + valid_local_frames * runtime->shift + runtime->offset <
               count) {
      ++valid_local_frames;
    }
    if (valid_local_frames <= 0) break;

    std::vector<std::array<float, 11>> local_probs(
        static_cast<size_t>(valid_local_frames));
    for (int f = 0; f < valid_local_frames; ++f) {
      const float *row = scores + f * C;
      float max_s = row[0];
      if (!std::isfinite(row[0])) {
        throw std::runtime_error("Nonfinite segmentation output");
      }
      for (int c = 1; c < C; ++c) {
        if (!std::isfinite(row[c])) {
          throw std::runtime_error("Nonfinite segmentation output");
        }
        if (row[c] > max_s) max_s = row[c];
      }
      float sum = 0.0f;
      for (int c = 0; c < C; ++c) {
        float e = std::exp(row[c] - max_s);
        local_probs[static_cast<size_t>(f)][static_cast<size_t>(c)] = e;
        sum += e;
      }
      const float inv = sum > 0.0f ? (1.0f / sum) : (1.0f / float(C));
      for (int c = 0; c < C; ++c) {
        local_probs[static_cast<size_t>(f)][static_cast<size_t>(c)] *= inv;
      }
    }

    const int base_global_frame = win_idx * step_frames;
    size_t best_perm = 0;
    if (win_idx > 0) {
      double best_cost = 1e30;
      for (size_t p = 0; p < perms.size(); ++p) {
        const int *pi = perms[p].data();
        double cost = 0.0;
        for (int f = 0; f < valid_local_frames; ++f) {
          const int g = base_global_frame + f;
          if (g >= total_frames) break;
          const float gw = global_weights[static_cast<size_t>(g)];
          if (gw <= 0.0f) continue;
          const float *gp =
              global_probs.data() + static_cast<size_t>(g) * static_cast<size_t>(C);
          float ref_m[5];
          ComputePowersetMarginals(gp, K, 1.0f / gw, ref_m);
          float loc_m[5];
          ComputePowersetMarginals(local_probs[static_cast<size_t>(f)].data(), K,
                                   1.0f, loc_m);
          float permuted_s[4] = {0.0f, 0.0f, 0.0f, 0.0f};
          for (int s = 0; s < K; ++s) permuted_s[pi[s]] = loc_m[s + 1];
          for (int s = 0; s < K; ++s) {
            cost += std::abs(double(ref_m[s + 1]) - double(permuted_s[s]));
          }
        }
        if (cost < best_cost) {
          best_cost = cost;
          best_perm = p;
        }
      }
    }

    const int *pi = perms[best_perm].data();
    constexpr double kTwoPi = 6.28318530717958647692;
    for (int f = 0; f < valid_local_frames; ++f) {
      const int g = base_global_frame + f;
      if (g >= total_frames) break;
      const float hann = static_cast<float>(
          0.5 - 0.5 * std::cos(kTwoPi * (f + 0.5) /
                               std::max(1, valid_local_frames)));
      const float w = std::max(0.05f, hann);
      float *gp =
          global_probs.data() + static_cast<size_t>(g) * static_cast<size_t>(C);
      const auto &lp = local_probs[static_cast<size_t>(f)];
      for (int c = 0; c < C; ++c) {
        const int gc = MapPowersetClass(c, K, pi);
        gp[gc] += w * lp[static_cast<size_t>(c)];
      }
      global_weights[static_cast<size_t>(g)] += w;
    }

    if (win_start + win_samples >= count) break;
  }

  exclusive_labels.assign(static_cast<size_t>(total_frames), 0);
  labels.assign(static_cast<size_t>(total_frames), 0);
  std::vector<std::array<float, 5>> marginals(
      static_cast<size_t>(total_frames), {0.0f, 0.0f, 0.0f, 0.0f, 0.0f});
  int overlap_frames = 0;

  for (int g = 0; g < total_frames; ++g) {
    const float *gp =
        global_probs.data() + static_cast<size_t>(g) * static_cast<size_t>(C);
    const float inv_gw =
        global_weights[static_cast<size_t>(g)] > 0.0f
            ? (1.0f / global_weights[static_cast<size_t>(g)])
            : 1.0f;
    const float p_sil = gp[0] * inv_gw;
    ComputePowersetMarginals(gp, K, inv_gw,
                             marginals[static_cast<size_t>(g)].data());

    int top1 = 1, top2 = 2;
    for (int s = 2; s <= K; ++s) {
      const float ms = marginals[static_cast<size_t>(g)][static_cast<size_t>(s)];
      if (ms > marginals[static_cast<size_t>(g)][static_cast<size_t>(top1)]) {
        top2 = top1;
        top1 = s;
      } else if (s != top1 &&
                 ms > marginals[static_cast<size_t>(g)][static_cast<size_t>(top2)]) {
        top2 = s;
      }
    }

    const float top1_m = marginals[static_cast<size_t>(g)][static_cast<size_t>(top1)];
    const float top2_m = marginals[static_cast<size_t>(g)][static_cast<size_t>(top2)];
    const int best_c = static_cast<int>(std::max_element(gp, gp + C) - gp);

    if ((best_c >= 1 && best_c <= K && top2_m < 0.26f) ||
        (1.0f - p_sil >= 0.48f && top1_m >= 0.45f && top2_m < 0.24f)) {
      exclusive_labels[static_cast<size_t>(g)] =
          (best_c >= 1 && best_c <= K) ? best_c : top1;
    } else {
      exclusive_labels[static_cast<size_t>(g)] = 0;
    }

    if (best_c > K ||
        (1.0f - p_sil >= 0.45f && top1_m >= 0.34f && top2_m >= 0.30f)) {
      labels[static_cast<size_t>(g)] = -1;
      ++overlap_frames;
    } else if (best_c >= 1 && best_c <= K) {
      labels[static_cast<size_t>(g)] = best_c;
    } else if (1.0f - p_sil >= 0.46f && top1_m >= 0.36f) {
      labels[static_cast<size_t>(g)] = top1;
    } else {
      labels[static_cast<size_t>(g)] = 0;
    }
  }
  if (out_overlap_frames) *out_overlap_frames = overlap_frames;

  // Partition conversational overlaps (<= ~1.6 s) between flanking speakers
  // at posterior crossover while keeping exclusive_labels untouched (0).
  const int max_handoff_frames = std::max(2, 25600 / runtime->shift);
  const int max_look_sil = std::max(1, 2400 / runtime->shift);
  for (int g = 0; g < total_frames;) {
    if (labels[static_cast<size_t>(g)] != -1) {
      ++g;
      continue;
    }
    const int ov_start = g;
    while (g < total_frames && labels[static_cast<size_t>(g)] == -1) ++g;
    const int ov_end = g;
    const int ov_len = ov_end - ov_start;
    if (ov_len <= max_handoff_frames) {
      int left_spk = 0;
      for (int k = ov_start - 1;
           k >= std::max(0, ov_start - max_look_sil); --k) {
        if (labels[static_cast<size_t>(k)] >= 1) {
          left_spk = labels[static_cast<size_t>(k)];
          break;
        }
        if (labels[static_cast<size_t>(k)] < 0) break;
      }
      int right_spk = 0;
      for (int k = ov_end;
           k < std::min(total_frames, ov_end + max_look_sil); ++k) {
        if (labels[static_cast<size_t>(k)] >= 1) {
          right_spk = labels[static_cast<size_t>(k)];
          break;
        }
        if (labels[static_cast<size_t>(k)] < 0) break;
      }

      if (left_spk >= 1 && left_spk == right_spk) {
        for (int k = ov_start; k < ov_end; ++k) {
          labels[static_cast<size_t>(k)] = left_spk;
        }
        continue;
      } else if (left_spk >= 1 && right_spk >= 1 && left_spk != right_spk) {
        int best_split = (ov_start + ov_end) / 2;
        double best_gain = -1e30;
        for (int s = ov_start; s <= ov_end; ++s) {
          double gain = 0.0;
          for (int k = ov_start; k < s; ++k) {
            gain += marginals[static_cast<size_t>(k)][static_cast<size_t>(left_spk)] -
                    marginals[static_cast<size_t>(k)][static_cast<size_t>(right_spk)];
          }
          for (int k = s; k < ov_end; ++k) {
            gain += marginals[static_cast<size_t>(k)][static_cast<size_t>(right_spk)] -
                    marginals[static_cast<size_t>(k)][static_cast<size_t>(left_spk)];
          }
          if (gain > best_gain) {
            best_gain = gain;
            best_split = s;
          }
        }
        for (int k = ov_start; k < best_split; ++k) {
          labels[static_cast<size_t>(k)] = left_spk;
        }
        for (int k = best_split; k < ov_end; ++k) {
          labels[static_cast<size_t>(k)] = right_spk;
        }
        continue;
      } else if ((left_spk >= 1 || right_spk >= 1) &&
                 ov_len <= max_handoff_frames / 2) {
        const int adj = left_spk >= 1 ? left_spk : right_spk;
        double mean_p = 0.0;
        for (int k = ov_start; k < ov_end; ++k) {
          mean_p += marginals[static_cast<size_t>(k)][static_cast<size_t>(adj)];
        }
        if (mean_p / std::max(1, ov_len) >= 0.33) {
          for (int k = ov_start; k < ov_end; ++k) {
            labels[static_cast<size_t>(k)] = adj;
          }
          continue;
        }
      }
    }

    for (int k = ov_start; k < ov_end; ++k) {
      float acc[5] = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
      for (int u = std::max(ov_start, k - 2);
           u <= std::min(ov_end - 1, k + 2); ++u) {
        for (int s = 1; s <= K; ++s) {
          acc[s] += marginals[static_cast<size_t>(u)][static_cast<size_t>(s)];
        }
      }
      int dom = 1;
      for (int s = 2; s <= K; ++s) {
        if (acc[s] > acc[dom]) dom = s;
      }
      labels[static_cast<size_t>(k)] = dom;
    }
  }

  // De-flicker zero-gap sub-220 ms islands flanked on both sides by the exact
  // same speaker while keeping exclusive_labels untouched (0 on island frames).
  const int max_flicker_frames = std::max(1, 3520 / runtime->shift);
  for (int g = 1; g < total_frames - 1;) {
    const int cur = labels[static_cast<size_t>(g)];
    if (cur <= 0) {
      ++g;
      continue;
    }
    const int f0 = g;
    while (g < total_frames && labels[static_cast<size_t>(g)] == cur) ++g;
    const int f1 = g;
    if (f0 > 0 && f1 < total_frames && f1 - f0 <= max_flicker_frames) {
      const int left_s = labels[static_cast<size_t>(f0 - 1)];
      const int right_s = labels[static_cast<size_t>(f1)];
      if (left_s >= 1 && left_s == right_s && left_s != cur) {
        for (int k = f0; k < f1; ++k) {
          labels[static_cast<size_t>(k)] = left_s;
          exclusive_labels[static_cast<size_t>(k)] = 0;
        }
      }
    }
  }
}

}  // namespace

MoMoSpeakerRuntime *MoMoCreateSpeakerRuntime(const char *segmentation,
    const char *embedding, const char *provider, char *error, size_t capacity) {
  return MoMoCreateSpeakerRuntimeWithThreads(
      segmentation, embedding, provider, 2, error, capacity);
}

MoMoSpeakerRuntime *MoMoCreateSpeakerRuntimeWithThreads(
    const char *segmentation, const char *embedding, const char *provider,
    int32_t num_threads, char *error, size_t capacity) {
  try {
    if (!segmentation || !embedding) {
      throw std::runtime_error("Missing speaker model path");
    }
    const int32_t threads = std::clamp<int32_t>(num_threads, 1, 6);
    const bool requested_coreml =
        provider && std::strncmp(provider, "coreml", 6) == 0;
    std::string coreml_cache_root;
    if (requested_coreml && provider[6] == ':') {
      coreml_cache_root = provider + 7;
      while (!coreml_cache_root.empty() &&
             (coreml_cache_root.back() == '\n' ||
              coreml_cache_root.back() == '\r')) {
        coreml_cache_root.pop_back();
      }
      // SherpaOnnx passes "coreml:/path/to/file.config"; SpeakerRuntime passes
      // "coreml:/path/to/dir". Strip trailing ".config" filename if present.
      if (coreml_cache_root.size() > 7 &&
          coreml_cache_root.compare(coreml_cache_root.size() - 7, 7, ".config") == 0) {
        const size_t slash = coreml_cache_root.find_last_of('/');
        if (slash != std::string::npos) {
          coreml_cache_root.resize(slash);
        }
      }
    }

    auto make_cpu_seg_options = [&](GraphOptimizationLevel opt_level) {
      Ort::SessionOptions opts;
      opts.SetIntraOpNumThreads(threads);
      opts.SetInterOpNumThreads(1);
      opts.SetGraphOptimizationLevel(opt_level);
      opts.AddConfigEntry("session.intra_op.allow_spinning", "0");
      opts.AddConfigEntry("session.inter_op.allow_spinning", "0");
      return opts;
    };

    auto runtime = std::make_unique<MoMoSpeakerRuntime>();
    // When CoreML is requested, skip expensive ORT_ENABLE_ALL CPU graph fusions on
    // the 135 MB DiariZen probe session; only build an optimized CPU session on fallback.
    auto probe_opts = make_cpu_seg_options(
        requested_coreml ? GraphOptimizationLevel::ORT_DISABLE_ALL
                         : GraphOptimizationLevel::ORT_ENABLE_ALL);
    runtime->segmentation =
        std::make_unique<Ort::Session>(runtime->env, segmentation, probe_opts);

    Ort::AllocatorWithDefaultOptions allocator;
    auto metadata = runtime->segmentation->GetModelMetadata();
    auto optional_int = [&](const char *key, int fallback) {
      auto value = metadata.LookupCustomMetadataMapAllocated(key, allocator);
      return value ? std::stoi(value.get()) : fallback;
    };

    auto out_shape = runtime->segmentation->GetOutputTypeInfo(0)
                         .GetTensorTypeAndShapeInfo()
                         .GetShape();
    const int out_classes =
        (out_shape.size() == 3 && out_shape[2] > 0)
            ? static_cast<int>(out_shape[2])
            : optional_int("num_classes", -1);
    if (out_classes == 11) {
      // DiariZen WavLM-Base-s80-md: 16 s window (8 s step), 20 ms WavLM clock,
      // 4-speaker powerset (max_set_size = 2 -> 11 classes).
      runtime->window_samples = optional_int("window_size", 256000);
      runtime->half_window_samples = runtime->window_samples / 2;
      runtime->shift = optional_int("receptive_field_shift", 320);
      const int rf_size = optional_int("receptive_field_size", 400);
      runtime->offset = rf_size / 2;
      runtime->num_speakers = 4;
      runtime->num_classes = 11;
    } else if (out_classes == 7) {
      // PyAnnote Community-1 / Segmentation-3.0: 10 s window (5 s step),
      // 3-speaker powerset (7 classes).
      runtime->window_samples = optional_int("window_size", 160000);
      runtime->half_window_samples = runtime->window_samples / 2;
      runtime->shift = optional_int("receptive_field_shift", 270);
      const int rf_size = optional_int("receptive_field_size", 990);
      runtime->offset = rf_size / 2;
      runtime->num_speakers = 3;
      runtime->num_classes = 7;
    } else {
      throw std::runtime_error("Unsupported segmentation model");
    }
    if (optional_int("sample_rate", 16000) != 16000 || runtime->shift <= 0 ||
        runtime->offset < 0) {
      throw std::runtime_error("Invalid segmentation frame clock");
    }
    auto in_name = runtime->segmentation->GetInputNameAllocated(0, allocator);
    auto out_name = runtime->segmentation->GetOutputNameAllocated(0, allocator);
    if (!in_name || !out_name) {
      throw std::runtime_error("Missing segmentation tensor names");
    }
    runtime->seg_in_name = in_name.get();
    runtime->seg_out_name = out_name.get();
    runtime->seg_padded.assign(static_cast<size_t>(runtime->window_samples), 0.0f);
    runtime->perms.reserve(24);
    {
      std::array<int, 4> p = {0, 1, 2, 3};
      do {
        runtime->perms.push_back(p);
      } while (
          std::next_permutation(p.begin(), p.begin() + runtime->num_speakers));
    }

    // Upgrade segmentation (DiariZen WavLM / PyAnnote Community-1) to CoreML ANE
    // with static window shape overrides and CPUAndNeuralEngine (background-safe!).
    if (requested_coreml) {
      try {
        auto seg_in_ti = runtime->segmentation->GetInputTypeInfo(0);
        auto seg_in_ts = seg_in_ti.GetTensorTypeAndShapeInfo();
        auto seg_in_shape = seg_in_ts.GetShape();
        if (seg_in_shape.size() == 3) {
          std::vector<const char *> syms(3, nullptr);
          seg_in_ts.GetSymbolicDimensions(syms.data(), syms.size());
          Ort::SessionOptions coreml_seg_opts;
          coreml_seg_opts.SetIntraOpNumThreads(std::clamp<int32_t>(threads, 1, 2));
          coreml_seg_opts.SetInterOpNumThreads(1);
          coreml_seg_opts.SetGraphOptimizationLevel(
              GraphOptimizationLevel::ORT_ENABLE_ALL);
          coreml_seg_opts.AddConfigEntry("session.intra_op.allow_spinning", "0");
          coreml_seg_opts.AddConfigEntry("session.inter_op.allow_spinning", "0");
          const int64_t target_dims[3] = {1, 1, runtime->window_samples};
          for (size_t ax = 0; ax < 3; ++ax) {
            if (syms[ax] && syms[ax][0] != '\0') {
              Ort::ThrowOnError(Ort::GetApi().AddFreeDimensionOverrideByName(
                  coreml_seg_opts, syms[ax], target_dims[ax]));
            }
          }
          std::unordered_map<std::string, std::string> ep_opts{
              {"ModelFormat", "MLProgram"},
              {"MLComputeUnits", "CPUAndNeuralEngine"},
              {"RequireStaticInputShapes", "1"},
          };
          if (!coreml_cache_root.empty()) {
            ::mkdir(coreml_cache_root.c_str(), 0755);
            const std::string seg_cache = coreml_cache_root + "/seg";
            ::mkdir(seg_cache.c_str(), 0755);
            ep_opts["ModelCacheDirectory"] = seg_cache;
          }
          coreml_seg_opts.AppendExecutionProvider("CoreML", ep_opts);
          auto coreml_seg = std::make_unique<Ort::Session>(
              runtime->env, segmentation, coreml_seg_opts);

          // Verify finite output on static window shape before promoting.
          int64_t test_shape[3] = {1, 1, runtime->window_samples};
          auto test_in = Ort::Value::CreateTensor<float>(
              runtime->seg_memory, runtime->seg_padded.data(),
              runtime->seg_padded.size(), test_shape, 3);
          const char *in_names[] = {runtime->seg_in_name.c_str()};
          const char *out_names[] = {runtime->seg_out_name.c_str()};
          auto test_out = coreml_seg->Run(Ort::RunOptions{nullptr}, in_names,
                                          &test_in, 1, out_names, 1);
          if (!test_out.empty() && test_out[0].IsTensor()) {
            auto td = test_out[0].GetTensorTypeAndShapeInfo().GetShape();
            if (td.size() == 3 && td[0] == 1 && td[2] == runtime->num_classes &&
                td[1] >= 1) {
              const float *ptr = test_out[0].GetTensorData<float>();
              const size_t total_out =
                  static_cast<size_t>(td[1]) * static_cast<size_t>(td[2]);
              bool all_finite = true;
              for (size_t u = 0; u < total_out; ++u) {
                if (!std::isfinite(ptr[u])) {
                  all_finite = false;
                  break;
                }
              }
              if (all_finite) {
                runtime->segmentation = std::move(coreml_seg);
                runtime->seg_uses_coreml = true;
              }
            }
          }
        }
      } catch (...) {
        // Fallback below upgrades the probe session to ORT_ENABLE_ALL CPU.
      }
      if (!runtime->seg_uses_coreml) {
        auto cpu_opts =
            make_cpu_seg_options(GraphOptimizationLevel::ORT_ENABLE_ALL);
        runtime->segmentation =
            std::make_unique<Ort::Session>(runtime->env, segmentation, cpu_opts);
      }
    }

    SherpaOnnxSpeakerEmbeddingExtractorConfig config{};
    config.model = embedding;
    config.num_threads = threads;
    config.provider = requested_coreml ? "cpu" : (provider ? provider : "cpu");
    runtime->embedding.cpu_ext = SherpaOnnxCreateSpeakerEmbeddingExtractor(&config);
    if (!runtime->embedding.cpu_ext) {
      throw std::runtime_error("Cannot create speaker embedding extractor");
    }
    const int dim =
        SherpaOnnxSpeakerEmbeddingExtractorDim(runtime->embedding.cpu_ext);
    if (dim != 192 && dim != 256) {
      throw std::runtime_error("Unsupported speaker embedding dimension");
    }
    if (dim == 192 && requested_coreml) {
      const std::string emb_cache =
          coreml_cache_root.empty() ? std::string{} : (coreml_cache_root + "/emb");
      runtime->embedding.coreml_ext = Eres2NetCoreMLExtractor::TryCreate(
          runtime->env, embedding, emb_cache, threads, runtime->embedding.cpu_ext);
      runtime->emb_uses_coreml = (runtime->embedding.coreml_ext != nullptr);
    } else if (dim == 256 && requested_coreml) {
      SherpaOnnxDestroySpeakerEmbeddingExtractor(runtime->embedding.cpu_ext);
      config.provider = provider;
      runtime->embedding.cpu_ext =
          SherpaOnnxCreateSpeakerEmbeddingExtractor(&config);
      if (!runtime->embedding.cpu_ext ||
          SherpaOnnxSpeakerEmbeddingExtractorDim(runtime->embedding.cpu_ext) !=
              256) {
        throw std::runtime_error("Invalid 256-dim speaker extractor");
      }
      runtime->emb_uses_coreml = true;
    }
    runtime->embedding_dim = dim;
    return runtime.release();
  } catch (const std::exception &e) {
    if (error && capacity) std::snprintf(error, capacity, "%s", e.what());
  } catch (...) {
    if (error && capacity) {
      std::snprintf(error, capacity, "Speaker initialization failed");
    }
  }
  return nullptr;
}

void MoMoDestroySpeakerRuntime(MoMoSpeakerRuntime *runtime) { delete runtime; }

int32_t MoMoGetSpeakerEmbeddingDim(const MoMoSpeakerRuntime *runtime) {
  return runtime ? runtime->embedding_dim : 0;
}

int32_t MoMoGetSpeakerAcceleratorMask(const MoMoSpeakerRuntime *runtime) {
  if (!runtime) return 0;
  int32_t mask = 0;
  if (runtime->seg_uses_coreml) mask |= 1;
  if (runtime->emb_uses_coreml) mask |= 2;
  return mask;
}

int MoMoExtractCleanVoiceprint(
    MoMoSpeakerRuntime *runtime, const float *samples, int32_t count,
    MoMoCancelCallback is_cancelled, const void *cancel_context,
    float *out_embedding, int32_t embedding_capacity, float *out_clean_seconds,
    char *error, size_t error_capacity) {
  return MoMoExtractCleanVoiceprintCancellable(
      runtime, samples, count, is_cancelled, cancel_context, nullptr,
      out_embedding, embedding_capacity, out_clean_seconds, error,
      error_capacity);
}

int MoMoExtractCleanVoiceprintCancellable(
    MoMoSpeakerRuntime *runtime, const float *samples, int32_t count,
    MoMoCancelCallback is_cancelled, const void *cancel_context,
    MoMoCancelToken *cancel_token,
    float *out_embedding, int32_t embedding_capacity, float *out_clean_seconds,
    char *error, size_t error_capacity) {
  try {
    if (!runtime || !samples || !out_embedding ||
        embedding_capacity < runtime->embedding_dim || count < 0) {
      throw std::runtime_error("Invalid voiceprint extraction input");
    }
    if (out_clean_seconds) *out_clean_seconds = 0.0f;
    CheckSpeakerCancel(is_cancelled, cancel_context, cancel_token);

    // Require at least 0.80 s of audio; center-crop clips > 16 s.
    if (count < 12800) return 0;
    const float *slice = samples;
    int32_t slice_count = count;
    if (slice_count > 256000) {
      slice += (slice_count - 256000) / 2;
      slice_count = 256000;
    }
    for (int32_t i = 0; i < slice_count; ++i) {
      if (!std::isfinite(slice[i])) return 0;
    }
    if (slice_count <= runtime->offset) return 0;
    const int total_frames =
        (slice_count - 1 - runtime->offset) / runtime->shift + 1;
    if (total_frames <= 0) return 0;

    std::vector<float> leveled_scratch;
    const float *seg_samples =
        LevelAudioForDiarization(slice, slice_count, leveled_scratch);
    std::vector<int> exclusive_labels, labels;
    RunSlidingPowersetSegmentation(runtime, seg_samples, slice_count,
                                   is_cancelled, cancel_context, cancel_token,
                                   total_frames, exclusive_labels, labels);

    const int K = runtime->num_speakers;
    std::array<int, 5> excl_counts{};
    int active_frames = 0;
    for (int f = 0; f < total_frames; ++f) {
      const int l = labels[static_cast<size_t>(f)];
      if (l != 0) ++active_frames;
      const int ex = exclusive_labels[static_cast<size_t>(f)];
      if (ex >= 1 && ex <= K) ++excl_counts[static_cast<size_t>(ex)];
    }
    int dom = 1;
    for (int s = 2; s <= K; ++s) {
      if (excl_counts[static_cast<size_t>(s)] >
          excl_counts[static_cast<size_t>(dom)]) {
        dom = s;
      }
    }
    const int dom_excl = excl_counts[static_cast<size_t>(dom)];
    int dom_active = 0;
    for (int f = 0; f < total_frames; ++f) {
      if (labels[static_cast<size_t>(f)] == dom) ++dom_active;
    }
    const int other_active = std::max(0, active_frames - dom_active);
    const float dom_excl_sec =
        float(dom_excl * runtime->shift) / 16000.0f;
    const float other_sec =
        float(other_active * runtime->shift) / 16000.0f;

    // Reject multi-speaker or heavily overlapped spans so bulk-confirmed
    // contaminated intervals never pollute seed voiceprints.
    if (dom_excl_sec < 0.80f || other_sec > 0.25f ||
        other_sec > 0.15f * dom_excl_sec) {
      return 0;
    }

    std::vector<std::pair<int, int>> clean_spans;
    for (int f = 0; f < total_frames;) {
      if (exclusive_labels[static_cast<size_t>(f)] != dom) {
        ++f;
        continue;
      }
      const int f0 = f;
      while (f < total_frames &&
             exclusive_labels[static_cast<size_t>(f)] == dom) {
        ++f;
      }
      const int s = std::max(0, f0 * runtime->shift + runtime->offset);
      const int e =
          std::min<int>(slice_count, f * runtime->shift + runtime->offset);
      if (e > s) clean_spans.emplace_back(s, e);
    }

    std::vector<float> clip_buf;
    std::array<float, kMaxEmbDim> emb{};
    float purity = 1.0f;
    if (!ExtractTurnEmbeddingWithPurity(
            runtime->embedding, runtime->embedding_dim, slice, clean_spans,
            12800, is_cancelled, cancel_context, cancel_token, clip_buf,
            emb.data(), &purity)) {
      return 0;
    }
    const float min_purity = (runtime->embedding_dim == 192) ? 0.50f : 0.68f;
    if (purity < min_purity) return 0;

    std::copy(emb.begin(), emb.begin() + runtime->embedding_dim, out_embedding);
    if (out_clean_seconds) {
      *out_clean_seconds = std::min(10.0f, dom_excl_sec);
    }
    return runtime->embedding_dim;
  } catch (const SpeakerCancelled &) {
    return -2;
  } catch (const Ort::Exception &e) {
    if ((cancel_token && cancel_token->IsCancelled()) ||
        (is_cancelled && is_cancelled(cancel_context) != 0)) {
      return -2;
    }
    if (error && error_capacity) {
      std::snprintf(error, error_capacity, "%s", e.what());
    }
  } catch (const std::exception &e) {
    if (error && error_capacity) {
      std::snprintf(error, error_capacity, "%s", e.what());
    }
  } catch (...) {
    if (error && error_capacity) {
      std::snprintf(error, error_capacity, "Voiceprint extraction failed");
    }
  }
  return -1;
}

int MoMoAnalyzeSpeakers(MoMoSpeakerRuntime *runtime, const float *samples,
    int32_t count, MoMoCancelCallback is_cancelled, const void *cancel_context,
    MoMoSpeakerTurn *turns, int32_t capacity,
    char *error, size_t error_capacity) {
  return MoMoAnalyzeSpeakersWithProfiles(
      runtime, samples, count, nullptr, nullptr, 0,
      is_cancelled, cancel_context, turns, capacity, error, error_capacity);
}

int MoMoAnalyzeSpeakersWithProfiles(
    MoMoSpeakerRuntime *runtime, const float *raw_samples, int32_t count,
    const float *enrolled_embeddings, const int32_t *enrolled_person_ids,
    int32_t enrolled_count,
    MoMoCancelCallback is_cancelled, const void *cancel_context,
    MoMoSpeakerTurn *turns, int32_t capacity,
    char *error, size_t error_capacity) {
  return MoMoAnalyzeSpeakersWithProfilesCancellable(
      runtime, raw_samples, count, enrolled_embeddings, enrolled_person_ids,
      enrolled_count, is_cancelled, cancel_context, nullptr, turns, capacity,
      error, error_capacity);
}

int MoMoAnalyzeSpeakersWithProfilesCancellable(
    MoMoSpeakerRuntime *runtime, const float *raw_samples, int32_t count,
    const float *enrolled_embeddings, const int32_t *enrolled_person_ids,
    int32_t enrolled_count,
    MoMoCancelCallback is_cancelled, const void *cancel_context,
    MoMoCancelToken *cancel_token,
    MoMoSpeakerTurn *turns, int32_t capacity,
    char *error, size_t error_capacity) {
  try {
    if (!runtime || !raw_samples || !turns || count <= 0 || count > 640000 ||
        capacity < 1 || enrolled_count < 0 ||
        (enrolled_count > 0 && (!enrolled_embeddings || !enrolled_person_ids))) {
      throw std::runtime_error("Invalid speaker input");
    }
    CheckSpeakerCancel(is_cancelled, cancel_context, cancel_token);

    for (int32_t i = 0; i < count; ++i) {
      if (!std::isfinite(raw_samples[i])) {
        throw std::runtime_error("Nonfinite speaker input");
      }
    }

    if (count <= runtime->offset) return 0;
    const int total_frames =
        (count - 1 - runtime->offset) / runtime->shift + 1;
    if (total_frames <= 0) return 0;

    const int K = runtime->num_speakers;
    const int rescue_track = K + 1;
    const int emb_dim = runtime->embedding_dim;
    const bool is_eres2net = (emb_dim == 192);

    std::vector<float> leveled_scratch;
    float raw_noise_rms = 0.0f;
    const float *seg_samples = LevelAudioForDiarization(
        raw_samples, count, leveled_scratch, &raw_noise_rms);

    std::vector<int> exclusive_labels, labels;
    int overlap_frames = 0;
    RunSlidingPowersetSegmentation(runtime, seg_samples, count, is_cancelled,
                                   cancel_context, cancel_token, total_frames,
                                   exclusive_labels, labels, &overlap_frames);

    // Active-speech gap rescue: if an additional quiet speaker spoke in a
    // >= 0.70 s "silence" gap, emit synthetic rescue_track so it is never
    // swallowed across adjacent turns of another speaker.
    const int min_rescue_gap_frames = std::max(3, 11200 / runtime->shift);
    const int guard_gap_frames = std::max(1, 1920 / runtime->shift);
    const int min_rescue_speech_frames = std::max(2, 8800 / runtime->shift);
    const float rescue_rms_floor = std::max(0.0024f, raw_noise_rms * 2.8f);
    for (int g = 0; g < total_frames;) {
      if (labels[static_cast<size_t>(g)] != 0) {
        ++g;
        continue;
      }
      const int gap_s = g;
      while (g < total_frames && labels[static_cast<size_t>(g)] == 0) ++g;
      const int gap_e = g;
      if (gap_e - gap_s < min_rescue_gap_frames) continue;
      const int inner_s = gap_s > 0 ? gap_s + guard_gap_frames : gap_s;
      const int inner_e = gap_e < total_frames ? gap_e - guard_gap_frames : gap_e;
      if (inner_e - inner_s < min_rescue_speech_frames) continue;

      int first_vo = -1, last_vo = -1, voiced_cnt = 0;
      for (int f = inner_s; f < inner_e; ++f) {
        const int s0 = std::max(0, f * runtime->shift + runtime->offset - 256);
        const int s1 = std::min<int>(count, s0 + 512);
        if (s1 <= s0) continue;
        double sum_sq = 0.0;
        float max_a = 0.0f;
        for (int si = s0; si < s1; ++si) {
          const float v = std::abs(raw_samples[si]);
          if (v > max_a) max_a = v;
          sum_sq += double(v) * double(v);
        }
        const float rms = static_cast<float>(std::sqrt(sum_sq / (s1 - s0)));
        if (rms >= rescue_rms_floor && max_a >= 0.008f && max_a >= 2.1f * rms) {
          if (first_vo < 0) first_vo = f;
          last_vo = f;
          ++voiced_cnt;
        }
      }
      if (voiced_cnt >= min_rescue_speech_frames && first_vo >= inner_s &&
          last_vo - first_vo + 1 >= min_rescue_speech_frames) {
        for (int f = first_vo; f <= last_vo; ++f) {
          labels[static_cast<size_t>(f)] = rescue_track;
          exclusive_labels[static_cast<size_t>(f)] = rescue_track;
        }
      }
    }

    // Bridge micro-silence closures (<= ~85 ms) within the exact same speaker.
    const int max_micro_gap_frames = std::max(1, 1360 / runtime->shift);
    for (int g = 0; g < total_frames;) {
      if (labels[static_cast<size_t>(g)] != 0) {
        ++g;
        continue;
      }
      int gap_start = g;
      while (g < total_frames && labels[static_cast<size_t>(g)] == 0) ++g;
      const int gap_len = g - gap_start;
      if (gap_start > 0 && g < total_frames &&
          gap_len <= max_micro_gap_frames) {
        const int prev_lbl = labels[static_cast<size_t>(gap_start - 1)];
        const int next_lbl = labels[static_cast<size_t>(g)];
        if (prev_lbl >= 1 && prev_lbl == next_lbl) {
          for (int k = gap_start; k < g; ++k) {
            labels[static_cast<size_t>(k)] = prev_lbl;
          }
        }
      }
    }

    auto collect_exclusive_spans = [&](int track, int sample_lo, int sample_hi) {
      std::vector<std::pair<int, int>> out;
      if (track < 1 || track > rescue_track || sample_hi <= sample_lo) return out;
      for (int f = 0; f < total_frames;) {
        if (exclusive_labels[static_cast<size_t>(f)] != track) {
          ++f;
          continue;
        }
        const int f0 = f;
        while (f < total_frames &&
               exclusive_labels[static_cast<size_t>(f)] == track) {
          ++f;
        }
        const int s = std::max(sample_lo, f0 * runtime->shift + runtime->offset);
        const int e = std::min(
            sample_hi, std::min<int>(count, f * runtime->shift + runtime->offset));
        if (e > s) out.emplace_back(s, e);
      }
      return out;
    };

    constexpr int kMinTurnSamples = 4000;           // 0.25 s
    constexpr int kMinSessionEmbedSamples = 5600;   // 0.35 s (session-only floor)
    constexpr int kMinDirectEmbedSamples = 9600;    // 0.60 s (clean voiceprint floor)
    const int split_trigger_samples = is_eres2net ? 28800 : 25600;
    constexpr int kScanStepSamples = 6400;          // 0.40 s boundary scan step
    const int disjoint_wing_samples = 3 * kScanStepSamples;  // 19200 (1.20 s)
    const int kMinSplitPieceSamples = is_eres2net ? 16800 : 12000;  // 1.05 s for 192-d ERes2NetV2

    std::vector<float> clip_buf;
    clip_buf.reserve(96000);

    // Monologue fast-path: when powerset segmentation + gap rescue sees <= 1
    // active track and zero multi-speaker overlap frames, verify half-to-half
    // voice consistency in at most 1-2 embeddings instead of running the
    // exhaustive 6400-step sliding-window wing scan (~95 embeddings on 20 s).
    int single_active_track = 0;
    int active_track_count = 0;
    for (int f = 0; f < total_frames; ++f) {
      const int lbl = labels[static_cast<size_t>(f)];
      if (lbl >= 1) {
        if (single_active_track == 0) {
          single_active_track = lbl;
          active_track_count = 1;
        } else if (lbl != single_active_track) {
          active_track_count = 2;
          break;
        }
      }
    }
    if (active_track_count == 0) return 0;
    auto partition_clean_spans = [](const std::vector<std::pair<int, int>> &tc,
                                    int t_clean, int n_parts,
                                    std::vector<std::vector<std::pair<int, int>>> &out) {
      if (n_parts <= 1) {
        out.push_back(tc);
        return;
      }
      const int target_per_part = t_clean / n_parts;
      std::vector<std::pair<int, int>> cur;
      int cur_acc = 0;
      int parts_built = 0;
      for (const auto &[cs, ce] : tc) {
        int pos = cs;
        while (pos < ce) {
          if (parts_built == n_parts - 1) {
            cur.emplace_back(pos, ce);
            pos = ce;
          } else {
            const int need = target_per_part - cur_acc;
            const int take = std::min(ce - pos, need);
            if (take > 0) {
              cur.emplace_back(pos, pos + take);
              pos += take;
              cur_acc += take;
            }
            if (cur_acc >= target_per_part) {
              out.push_back(std::move(cur));
              cur.clear();
              cur_acc = 0;
              ++parts_built;
            }
          }
        }
      }
      if (!cur.empty()) out.push_back(std::move(cur));
    };

    auto active_rms_step_ratio = [&](int lo, int hi) -> float {
      constexpr int kBlock = 19200;  // 1.20 s matching disjoint_wing_samples
      constexpr int kStep = 9600;    // 0.60 s step
      if (hi - lo < kBlock + kStep) return 1.0f;
      const float floor_rms = std::max(0.0025f, raw_noise_rms * 2.4f);
      float min_r = 1e9f, max_r = 0.0f;
      int active_blocks = 0;
      for (int p = lo; p + kBlock <= hi; p += kStep) {
        double sq = 0.0;
        for (int k = p; k < p + kBlock; ++k) {
          sq += double(raw_samples[k]) * double(raw_samples[k]);
        }
        const float r = static_cast<float>(std::sqrt(sq / kBlock));
        if (r >= floor_rms) {
          min_r = std::min(min_r, r);
          max_r = std::max(max_r, r);
          ++active_blocks;
        }
      }
      if (active_blocks >= 2 && min_r > 1e-5f) return max_r / min_r;
      return 1.0f;
    };

    if (active_track_count == 1 && overlap_frames * runtime->shift <= 4800) {
      std::vector<std::pair<int, int>> mono_turns;
      for (int i = 0; i < total_frames;) {
        const int begin = i;
        const int label = labels[static_cast<size_t>(i)];
        while (i < total_frames && labels[static_cast<size_t>(i)] == label) ++i;
        const int start = begin * runtime->shift + runtime->offset;
        const int end =
            std::min<int>(count, i * runtime->shift + runtime->offset);
        if (label == single_active_track && end - start >= kMinTurnSamples) {
          mono_turns.emplace_back(start, end);
        }
      }
      if (mono_turns.empty()) return 0;
      const auto all_clean = collect_exclusive_spans(
          single_active_track, mono_turns.front().first,
          mono_turns.back().second);
      int total_clean = 0;
      for (const auto &[cs, ce] : all_clean) total_clean += (ce - cs);

      std::array<float, kMaxEmbDim> mono_emb{};
      bool has_mono_emb = false;
      bool verified_monologue = true;
      const int split_check_threshold = is_eres2net ? 28800 : 25600;
      const int min_part_samples = is_eres2net ? 11200 : 9600;
      const float mono_min_sim = is_eres2net ? 0.55f : 0.72f;
      const float two_sided_ceil = is_eres2net ? 0.64f : 0.82f;

      if (total_clean >= split_check_threshold || mono_turns.size() > 1) {
        // Partition clean speech into 2-4 non-overlapping parts and verify ALL
        // pairs match so symmetric turns like A->B->A cannot cancel out.
        std::vector<std::vector<std::pair<int, int>>> part_spans;
        for (const auto &[ts, te] : mono_turns) {
          auto tc = collect_exclusive_spans(single_active_track, ts, te);
          int t_clean = 0;
          for (const auto &[cs, ce] : tc) t_clean += (ce - cs);
          if (t_clean < min_part_samples) continue;
          int n_parts = 1;
          if (te - ts >= split_check_threshold && t_clean >= 2 * min_part_samples) {
            n_parts = std::clamp((t_clean + 15999) / 48000, 2, 4);
          }
          partition_clean_spans(tc, t_clean, n_parts, part_spans);
        }

        if (part_spans.size() >= 2) {
          const float eff_mono_min =
              (is_eres2net &&
               active_rms_step_ratio(mono_turns.front().first,
                                     mono_turns.back().second) >= 2.5f)
                  ? 0.60f
                  : mono_min_sim;
          std::vector<std::array<float, kMaxEmbDim>> part_embs;
          part_embs.reserve(part_spans.size());
          for (const auto &ps : part_spans) {
            if (!BuildCleanSpeechClip(raw_samples, ps, min_part_samples, emb_dim,
                                      clip_buf, 40000)) {
              verified_monologue = false;
              break;
            }
            CheckSpeakerCancel(is_cancelled, cancel_context, cancel_token);
            std::array<float, kMaxEmbDim> pe{};
            ExtractNormalizedEmbedding(runtime->embedding, emb_dim,
                                       clip_buf.data(),
                                       static_cast<int>(clip_buf.size()),
                                       pe.data());
            const auto m_cur = MatchEnrolledPerson(
                pe.data(), emb_dim, enrolled_embeddings, enrolled_person_ids,
                enrolled_count);
            for (const auto &prev : part_embs) {
              const float sim = DotN(prev.data(), pe.data(), emb_dim);
              const auto m_prev = MatchEnrolledPerson(
                  prev.data(), emb_dim, enrolled_embeddings, enrolled_person_ids,
                  enrolled_count);
              const bool enrolled_conflict =
                  (m_prev.person_id >= 0 && m_cur.person_id >= 0 &&
                   m_prev.person_id != m_cur.person_id &&
                   sim < two_sided_ceil) ||
                  HasOneSidedEnrolledDropoff(
                      prev.data(), pe.data(), emb_dim, sim, enrolled_embeddings,
                      enrolled_person_ids, enrolled_count);
              if (enrolled_conflict || sim < eff_mono_min) {
                verified_monologue = false;
                break;
              }
            }
            if (!verified_monologue) break;
            part_embs.push_back(pe);
          }
          if (verified_monologue && !part_embs.empty()) {
            mono_emb.fill(0.0f);
            for (const auto &pe : part_embs) {
              for (int d = 0; d < emb_dim; ++d) {
                mono_emb[static_cast<size_t>(d)] += pe[static_cast<size_t>(d)];
              }
            }
            has_mono_emb = NormalizeN(mono_emb.data(), emb_dim);
          }
        } else if (mono_turns.size() > 1 || total_clean >= split_check_threshold) {
          verified_monologue = false;
        }
      }
      if (verified_monologue && !has_mono_emb) {
        if (total_clean >= kMinSessionEmbedSamples &&
            BuildCleanSpeechClip(raw_samples, all_clean,
                                 kMinSessionEmbedSamples, emb_dim, clip_buf)) {
          CheckSpeakerCancel(is_cancelled, cancel_context, cancel_token);
          ExtractNormalizedEmbedding(runtime->embedding, emb_dim,
                                     clip_buf.data(),
                                     static_cast<int>(clip_buf.size()),
                                     mono_emb.data());
          has_mono_emb = HasValidEmbeddingN(mono_emb.data(), emb_dim);
        } else if (BuildCleanSpeechClip(raw_samples, mono_turns,
                                        kMinSessionEmbedSamples, emb_dim,
                                        clip_buf)) {
          CheckSpeakerCancel(is_cancelled, cancel_context, cancel_token);
          ExtractNormalizedEmbedding(runtime->embedding, emb_dim,
                                     clip_buf.data(),
                                     static_cast<int>(clip_buf.size()),
                                     mono_emb.data());
          has_mono_emb = HasValidEmbeddingN(mono_emb.data(), emb_dim);
        }
      }
      if (verified_monologue) {
        if (static_cast<int32_t>(mono_turns.size()) > capacity) {
          throw std::runtime_error("Speaker output capacity exceeded");
        }
        const int written = static_cast<int>(mono_turns.size());
        for (int idx = 0; idx < written; ++idx) {
          const auto [s, e] = mono_turns[static_cast<size_t>(idx)];
          const auto turn_clean =
              collect_exclusive_spans(single_active_track, s, e);
          int clean_n = 0;
          for (const auto &[cs, ce] : turn_clean) clean_n += (ce - cs);
          auto &dst = turns[idx];
          dst = {};
          dst.start_sample = s;
          dst.end_sample = e;
          dst.local_speaker = 1;
          dst.embedding_dim = emb_dim;
          if (has_mono_emb) {
            std::copy(mono_emb.begin(), mono_emb.end(), dst.embedding);
            if (clean_n >= kMinSessionEmbedSamples ||
                (written > 1 && total_clean >= kMinDirectEmbedSamples)) {
              dst.clean_seconds = std::min(10.0f, float(clean_n) / 16000.0f);
            } else if (e - s >= kMinSessionEmbedSamples) {
              dst.clean_seconds =
                  std::min(0.65f, 0.70f * float(e - s) / 16000.0f);
            }
          }
        }
        return written;
      }
    }

    struct RawTurn {
      int start = 0;
      int end = 0;
      int orig_track = 0;
      int local_speaker = 0;
      bool was_split = false;
      bool strong_split_after = false;
      float clean_seconds = 0.0f;
      std::array<float, kMaxEmbDim> embedding{};
      std::vector<std::pair<int, int>> clean_spans;
    };
    std::vector<RawTurn> raw_turns;

    auto populate_raw_turn = [&](RawTurn &rt, float *out_purity,
                                 float *out_emb_a = nullptr,
                                 float *out_emb_b = nullptr,
                                 bool *out_has_halves = nullptr) {
      if (out_purity) *out_purity = 1.0f;
      if (out_has_halves) *out_has_halves = false;
      if (rt.orig_track < 1 || rt.orig_track > rescue_track) return;
      rt.clean_spans = collect_exclusive_spans(rt.orig_track, rt.start, rt.end);
      int clean_n = 0;
      for (const auto &[cs, ce] : rt.clean_spans) clean_n += (ce - cs);
      if (clean_n >= kMinDirectEmbedSamples &&
          ExtractTurnEmbeddingWithPurity(
              runtime->embedding, emb_dim, raw_samples, rt.clean_spans,
              kMinDirectEmbedSamples, is_cancelled, cancel_context,
              cancel_token, clip_buf, rt.embedding.data(), out_purity,
              out_emb_a, out_emb_b, out_has_halves)) {
        rt.clean_seconds = std::min(10.0f, float(clean_n) / 16000.0f);
      } else if (clean_n >= kMinSessionEmbedSamples &&
                 BuildCleanSpeechClip(raw_samples, rt.clean_spans,
                                      kMinSessionEmbedSamples, emb_dim,
                                      clip_buf)) {
        CheckSpeakerCancel(is_cancelled, cancel_context, cancel_token);
        ExtractNormalizedEmbedding(runtime->embedding, emb_dim, clip_buf.data(),
                                   static_cast<int>(clip_buf.size()),
                                   rt.embedding.data());
        rt.clean_seconds = float(clean_n) / 16000.0f;
      } else if (rt.end - rt.start >= kMinSessionEmbedSamples) {
        std::vector<std::pair<int, int>> full_span = {{rt.start, rt.end}};
        if (BuildCleanSpeechClip(raw_samples, full_span, kMinSessionEmbedSamples,
                                 emb_dim, clip_buf)) {
          CheckSpeakerCancel(is_cancelled, cancel_context, cancel_token);
          ExtractNormalizedEmbedding(runtime->embedding, emb_dim,
                                     clip_buf.data(),
                                     static_cast<int>(clip_buf.size()),
                                     rt.embedding.data());
          const int f_lo = std::max(
              0, (rt.start - runtime->offset) / std::max(1, runtime->shift));
          const int f_hi = std::min(
              total_frames,
              (rt.end - runtime->offset + runtime->shift - 1) /
                  std::max(1, runtime->shift));
          int span_frames = std::max(1, f_hi - f_lo);
          int conflict_frames = 0;
          for (int f = f_lo; f < f_hi; ++f) {
            const int lbl = labels[static_cast<size_t>(f)];
            if (lbl < 0 || (lbl >= 1 && lbl != rt.orig_track)) ++conflict_frames;
          }
          if (conflict_frames * 5 <= span_frames) {
            rt.clean_seconds = std::min(
                0.65f, 0.70f * float(rt.end - rt.start) / 16000.0f);
          } else {
            rt.clean_seconds = 0.0f;
          }
        }
      }
    };

    for (int i = 0; i < total_frames;) {
      const int begin = i;
      const int label = labels[static_cast<size_t>(i)];
      while (i < total_frames && labels[static_cast<size_t>(i)] == label) ++i;
      const int start = begin * runtime->shift + runtime->offset;
      const int end = std::min<int>(count, i * runtime->shift + runtime->offset);
      if (label <= 0 || end - start < kMinTurnSamples) continue;

      std::vector<int> boundaries = {start, end};
      std::vector<bool> boundary_strong;
      bool certified_pure_turn = false;
      std::array<float, kMaxEmbDim> certified_turn_emb{};
      std::vector<std::pair<int, int>> certified_clean_spans;
      int certified_clean_n = 0;
      float certified_purity = 1.0f;

      if (label >= 1 && label <= rescue_track &&
          end - start >= split_trigger_samples) {
        const float two_sided_ceil = is_eres2net ? 0.64f : 0.82f;
        const float turn_rms_ratio = active_rms_step_ratio(start, end);
        const float probe_min_sim =
            is_eres2net ? (turn_rms_ratio >= 2.5f ? 0.61f : 0.56f) : 0.75f;
        // Fast pre-check: if a segmented turn has bounded loudness variation and 2-4
        // non-overlapping sub-parts agree acoustically with zero enrolled
        // speaker dropoff, skip the 0.40 s sliding wing scan AND reuse the
        // pooled embedding directly.
        if (turn_rms_ratio < 4.2f) {
          auto pre_clean = collect_exclusive_spans(label, start, end);
          int pre_clean_n = 0;
          for (const auto &[cs, ce] : pre_clean) pre_clean_n += (ce - cs);
          if (pre_clean_n >= 2 * kMinDirectEmbedSamples &&
              static_cast<int64_t>(pre_clean_n) * 10 >=
                  static_cast<int64_t>(end - start) * 7) {
            const int n_probe =
                std::clamp((pre_clean_n + 15999) / 36000, 2, 4);
            std::vector<std::vector<std::pair<int, int>>> probe_parts;
            probe_parts.reserve(static_cast<size_t>(n_probe));
            partition_clean_spans(pre_clean, pre_clean_n, n_probe, probe_parts);
            if (probe_parts.size() >= 2) {
              std::vector<std::array<float, kMaxEmbDim>> probe_embs;
              probe_embs.reserve(probe_parts.size());
              bool all_pure = true;
              float min_pair_sim = 1.0f;
              for (const auto &pp : probe_parts) {
                if (!BuildCleanSpeechClip(raw_samples, pp, kMinDirectEmbedSamples,
                                          emb_dim, clip_buf, 36000)) {
                  all_pure = false;
                  break;
                }
                CheckSpeakerCancel(is_cancelled, cancel_context, cancel_token);
                std::array<float, kMaxEmbDim> pe{};
                ExtractNormalizedEmbedding(runtime->embedding, emb_dim,
                                           clip_buf.data(),
                                           static_cast<int>(clip_buf.size()),
                                           pe.data());
                const auto m_cur = MatchEnrolledPerson(
                    pe.data(), emb_dim, enrolled_embeddings,
                    enrolled_person_ids, enrolled_count);
                for (const auto &prev : probe_embs) {
                  const float sim = DotN(prev.data(), pe.data(), emb_dim);
                  min_pair_sim = std::min(min_pair_sim, sim);
                  const auto m_prev = MatchEnrolledPerson(
                      prev.data(), emb_dim, enrolled_embeddings,
                      enrolled_person_ids, enrolled_count);
                  const bool enrolled_conflict =
                      (m_prev.person_id >= 0 && m_cur.person_id >= 0 &&
                       m_prev.person_id != m_cur.person_id &&
                       sim < two_sided_ceil) ||
                      HasOneSidedEnrolledDropoff(
                          prev.data(), pe.data(), emb_dim, sim,
                          enrolled_embeddings, enrolled_person_ids,
                          enrolled_count);
                  if (enrolled_conflict || sim < probe_min_sim) {
                    all_pure = false;
                    break;
                  }
                }
                if (!all_pure) break;
                probe_embs.push_back(pe);
              }
              if (all_pure && probe_embs.size() == probe_parts.size()) {
                certified_turn_emb.fill(0.0f);
                for (const auto &pe : probe_embs) {
                  for (int d = 0; d < emb_dim; ++d) {
                    certified_turn_emb[static_cast<size_t>(d)] +=
                        pe[static_cast<size_t>(d)];
                  }
                }
                if (NormalizeN(certified_turn_emb.data(), emb_dim)) {
                  certified_pure_turn = true;
                  certified_clean_spans = std::move(pre_clean);
                  certified_clean_n = pre_clean_n;
                  certified_purity = min_pair_sim;
                }
              }
            }
          }
        }
      }

      if (!certified_pure_turn && label >= 1 && label <= rescue_track &&
          end - start >= split_trigger_samples) {
        struct WingMemo {
          int lo = 0;
          int hi = 0;
          bool valid = false;
          std::array<float, kMaxEmbDim> emb{};
        };
        std::vector<WingMemo> wing_cache;
        auto get_wing_embedding = [&](int w_lo, int w_hi,
                                      std::array<float, kMaxEmbDim> &out) -> bool {
          for (const auto &m : wing_cache) {
            if (m.lo == w_lo && m.hi == w_hi) {
              if (m.valid) out = m.emb;
              return m.valid;
            }
          }
          WingMemo memo;
          memo.lo = w_lo;
          memo.hi = w_hi;
          auto spans = collect_exclusive_spans(label, w_lo, w_hi);
          if (BuildCleanSpeechClip(raw_samples, spans, 8000, emb_dim, clip_buf)) {
            CheckSpeakerCancel(is_cancelled, cancel_context, cancel_token);
            ExtractNormalizedEmbedding(runtime->embedding, emb_dim,
                                       clip_buf.data(),
                                       static_cast<int>(clip_buf.size()),
                                       memo.emb.data());
            memo.valid = true;
          } else if (w_hi - w_lo >= 10400) {
            std::vector<std::pair<int, int>> raw_wing = {{w_lo, w_hi}};
            if (BuildCleanSpeechClip(raw_samples, raw_wing, 10400, emb_dim,
                                     clip_buf)) {
              CheckSpeakerCancel(is_cancelled, cancel_context, cancel_token);
              ExtractNormalizedEmbedding(runtime->embedding, emb_dim,
                                         clip_buf.data(),
                                         static_cast<int>(clip_buf.size()),
                                         memo.emb.data());
              memo.valid = true;
            }
          }
          wing_cache.push_back(memo);
          if (memo.valid) out = memo.emb;
          return memo.valid;
        };

        struct CutCandidate {
          int sample = 0;
          float disjoint_sim = 1.0f;
          float rms_ratio = 1.0f;
          bool evaluated = false;
          bool valid_wings = false;
          bool enrolled_trig = false;
          bool triggered = false;
          bool strong = false;
        };
        std::vector<CutCandidate> cands;
        const int first_cut = start + kMinSplitPieceSamples;
        const int last_cut = end - kMinSplitPieceSamples;
        if (end - start < 2 * disjoint_wing_samples) {
          const int mid = (start + end) / 2;
          if (mid >= first_cut && mid <= last_cut) {
            cands.push_back({mid});
          }
        } else {
          for (int c = first_cut; c <= last_cut; c += kScanStepSamples) {
            cands.push_back({c});
          }
          if (cands.empty() ||
              last_cut - cands.back().sample >= kScanStepSamples / 2) {
            if (last_cut >= first_cut) {
              cands.push_back({last_cut});
            }
          }
        }

        const int turn_len = end - start;
        std::vector<double> turn_prefix_sq(static_cast<size_t>(turn_len + 1), 0.0);
        for (int p = 0; p < turn_len; ++p) {
          const double v = raw_samples[start + p];
          turn_prefix_sq[static_cast<size_t>(p + 1)] =
              turn_prefix_sq[static_cast<size_t>(p)] + v * v;
        }
        auto wing_rms = [&](int lo, int hi) -> float {
          const int c_lo = std::clamp(lo, start, end) - start;
          const int c_hi = std::clamp(hi, start, end) - start;
          if (c_hi <= c_lo) return 0.0f;
          const double sq = std::max(
              0.0, turn_prefix_sq[static_cast<size_t>(c_hi)] -
                       turn_prefix_sq[static_cast<size_t>(c_lo)]);
          return static_cast<float>(std::sqrt(sq / (c_hi - c_lo)));
        };

        for (auto &cand : cands) {
          const int l_lo = std::max(start, cand.sample - disjoint_wing_samples);
          const int r_hi = std::min(end, cand.sample + disjoint_wing_samples);
          const float rL = std::max(1e-4f, wing_rms(l_lo, cand.sample));
          const float rR = std::max(1e-4f, wing_rms(cand.sample, r_hi));
          cand.rms_ratio = std::max(rL / rR, rR / rL);
        }

        const float two_sided_ceil = is_eres2net ? 0.64f : 0.82f;
        auto evaluate_cand = [&](size_t idx,
                                 std::array<float, kMaxEmbDim> *out_left = nullptr,
                                 std::array<float, kMaxEmbDim> *out_right = nullptr) {
          auto &cand = cands[idx];
          if (cand.evaluated) {
            if (cand.valid_wings && (out_left || out_right)) {
              const int l_lo = std::max(start, cand.sample - disjoint_wing_samples);
              const int r_hi = std::min(end, cand.sample + disjoint_wing_samples);
              if (out_left) get_wing_embedding(l_lo, cand.sample, *out_left);
              if (out_right) get_wing_embedding(cand.sample, r_hi, *out_right);
            }
            return;
          }
          cand.evaluated = true;
          const int l_lo = std::max(start, cand.sample - disjoint_wing_samples);
          const int r_hi = std::min(end, cand.sample + disjoint_wing_samples);
          std::array<float, kMaxEmbDim> left_emb{}, right_emb{};
          if (!get_wing_embedding(l_lo, cand.sample, left_emb) ||
              !get_wing_embedding(cand.sample, r_hi, right_emb)) {
            return;
          }
          cand.valid_wings = true;
          if (out_left) *out_left = left_emb;
          if (out_right) *out_right = right_emb;
          const float sim = DotN(left_emb.data(), right_emb.data(), emb_dim);
          cand.disjoint_sim = sim;

          const auto m_left = MatchEnrolledPerson(
              left_emb.data(), emb_dim, enrolled_embeddings,
              enrolled_person_ids, enrolled_count);
          const auto m_right = MatchEnrolledPerson(
              right_emb.data(), emb_dim, enrolled_embeddings,
              enrolled_person_ids, enrolled_count);
          const bool two_sided_enrolled =
              (m_left.person_id >= 0 && m_right.person_id >= 0 &&
               m_left.person_id != m_right.person_id && sim < two_sided_ceil);
          const bool one_sided_enrolled = HasOneSidedEnrolledDropoff(
              left_emb.data(), right_emb.data(), emb_dim, sim,
              enrolled_embeddings, enrolled_person_ids, enrolled_count);
          cand.enrolled_trig = two_sided_enrolled || one_sided_enrolled;
        };

        const float abs_switch_th = is_eres2net ? 0.34f : 0.64f;
        const float strong_switch_th = is_eres2net ? 0.26f : 0.58f;
        const float base_min = is_eres2net ? 0.64f : 0.80f;
        const float dip_min = is_eres2net ? 0.20f : 0.14f;
        const float dip_ceil = is_eres2net ? 0.48f : 0.72f;
        const float ch_ceil = is_eres2net ? 0.48f : 0.74f;

        if (cands.size() <= 9) {
          for (size_t k = 0; k < cands.size(); ++k) {
            evaluate_cand(k);
          }
        } else {
          // Stage 1: Evaluate stride-3 coarse cuts aligned with
          // disjoint_wing_samples (3 * 6,400 = 19,200), so adjacent coarse
          // wings share exact [lo, hi] intervals and hit wing_cache 100%.
          struct CoarseNode {
            size_t idx = 0;
            std::array<float, kMaxEmbDim> left_emb{};
            std::array<float, kMaxEmbDim> right_emb{};
          };
          std::vector<CoarseNode> coarse;
          coarse.reserve(cands.size() / 3 + 2);
          for (size_t k = 0; k < cands.size(); k += 3) {
            CoarseNode node;
            node.idx = k;
            evaluate_cand(k, &node.left_emb, &node.right_emb);
            coarse.push_back(node);
          }
          if (coarse.back().idx + 1 < cands.size()) {
            CoarseNode tail;
            tail.idx = cands.size() - 1;
            evaluate_cand(tail.idx, &tail.left_emb, &tail.right_emb);
            coarse.push_back(tail);
          }

          float coarse_max_sim = -1.0f;
          for (const auto &node : coarse) {
            if (cands[node.idx].valid_wings) {
              coarse_max_sim =
                  std::max(coarse_max_sim, cands[node.idx].disjoint_sim);
            }
          }

          // Stage 2: Refine fine 0.40 s candidates only around coarse cuts or
          // skip-1 block pairs showing voice drop, enrolled conflict, or step.
          const float suspect_sim_th = is_eres2net ? 0.56f : 0.76f;
          const float suspect_dip_min = is_eres2net ? 0.14f : 0.10f;
          const float suspect_ch_ceil = is_eres2net ? 0.62f : 0.80f;
          std::vector<bool> need_eval(cands.size(), false);
          auto mark_range = [&](int lo_idx, int hi_idx) {
            const int a = std::max(0, lo_idx);
            const int b = std::min(static_cast<int>(cands.size()) - 1, hi_idx);
            for (int u = a; u <= b; ++u) {
              need_eval[static_cast<size_t>(u)] = true;
            }
          };

          for (size_t m = 0; m < coarse.size(); ++m) {
            const int ci = static_cast<int>(coarse[m].idx);
            const auto &cc = cands[coarse[m].idx];
            if (!cc.valid_wings) {
              mark_range(ci - 3, ci + 3);
              continue;
            }
            bool local_rms_step = false;
            for (int u = std::max(0, ci - 2);
                 u <= std::min(static_cast<int>(cands.size()) - 1, ci + 2);
                 ++u) {
              if (cands[static_cast<size_t>(u)].rms_ratio >= 2.2f) {
                local_rms_step = true;
                break;
              }
            }
            const bool direct_suspect =
                cc.enrolled_trig || (cc.disjoint_sim < suspect_sim_th) ||
                (coarse_max_sim >= base_min &&
                 (coarse_max_sim - cc.disjoint_sim >= suspect_dip_min)) ||
                (local_rms_step && cc.disjoint_sim < suspect_ch_ceil);
            if (direct_suspect) {
              mark_range(ci - 5, ci + 5);
            }

            if (m > 0 && cands[coarse[m - 1].idx].valid_wings) {
              const float skip_sim = DotN(coarse[m - 1].left_emb.data(),
                                          coarse[m].right_emb.data(), emb_dim);
              const auto ml = MatchEnrolledPerson(
                  coarse[m - 1].left_emb.data(), emb_dim, enrolled_embeddings,
                  enrolled_person_ids, enrolled_count);
              const auto mr = MatchEnrolledPerson(
                  coarse[m].right_emb.data(), emb_dim, enrolled_embeddings,
                  enrolled_person_ids, enrolled_count);
              const bool skip_enrolled =
                  (ml.person_id >= 0 && mr.person_id >= 0 &&
                   ml.person_id != mr.person_id && skip_sim < two_sided_ceil) ||
                  HasOneSidedEnrolledDropoff(
                      coarse[m - 1].left_emb.data(),
                      coarse[m].right_emb.data(), emb_dim, skip_sim,
                      enrolled_embeddings, enrolled_person_ids, enrolled_count);
              const bool skip_suspect =
                  skip_enrolled || (skip_sim < suspect_sim_th) ||
                  (coarse_max_sim >= base_min &&
                   (coarse_max_sim - skip_sim >= suspect_dip_min));
              if (skip_suspect) {
                mark_range(static_cast<int>(coarse[m - 1].idx) - 3, ci + 3);
              }
            }
          }

          for (size_t k = 0; k < cands.size(); ++k) {
            if (need_eval[k]) evaluate_cand(k);
          }
        }

        for (size_t k = 0; k < cands.size(); ++k) {
          auto &cand = cands[k];
          if (!cand.valid_wings) continue;
          float baseline = -1.0f;
          for (int d = -3; d <= 3; ++d) {
            if (d >= -1 && d <= 1) continue;
            const int nb = static_cast<int>(k) + d;
            if (nb >= 0 && nb < static_cast<int>(cands.size()) &&
                cands[static_cast<size_t>(nb)].valid_wings) {
              baseline = std::max(
                  baseline, cands[static_cast<size_t>(nb)].disjoint_sim);
            }
          }
          const float sim = cand.disjoint_sim;
          const bool abs_switch = (sim < abs_switch_th);
          const bool contrast_dip =
              (baseline >= base_min && (baseline - sim >= dip_min) &&
               sim < dip_ceil);
          const bool channel_step = (cand.rms_ratio >= 2.8f && sim < ch_ceil);
          if (cand.enrolled_trig || abs_switch || contrast_dip || channel_step) {
            cand.triggered = true;
            cand.strong = cand.enrolled_trig || (sim < strong_switch_th) ||
                          contrast_dip || channel_step;
          }
        }

        int last_split_sample = start;
        for (size_t k = 0; k < cands.size(); ++k) {
          if (!cands[k].triggered) continue;
          if (k > 0 && cands[k - 1].triggered &&
              cands[k].disjoint_sim >= cands[k - 1].disjoint_sim) {
            continue;
          }
          if (k + 1 < cands.size() && cands[k + 1].triggered &&
              cands[k].disjoint_sim > cands[k + 1].disjoint_sim) {
            continue;
          }
          const int search_lo = std::max(last_split_sample + kMinSplitPieceSamples,
                                         cands[k].sample - 4000);
          const int search_hi = std::min(end - kMinSplitPieceSamples,
                                         cands[k].sample + 4000);
          if (search_hi <= search_lo) continue;
          const int valley =
              FindEnergyValleySample(raw_samples, count, search_lo, search_hi);
          if (valley - last_split_sample >= kMinSplitPieceSamples &&
              end - valley >= kMinSplitPieceSamples) {
            boundaries.insert(boundaries.end() - 1, valley);
            boundary_strong.push_back(cands[k].strong);
            last_split_sample = valley;
          }
        }
      }

      const float purity_split_th = is_eres2net ? 0.42f : 0.62f;
      const float purity_drop_th = is_eres2net ? 0.36f : 0.55f;
      const bool did_split = boundaries.size() > 2;
      for (size_t b = 0; b + 1 < boundaries.size(); ++b) {
        RawTurn rt;
        rt.start = boundaries[b];
        rt.end = boundaries[b + 1];
        rt.orig_track = label;
        rt.local_speaker = label;
        rt.was_split = did_split;
        rt.strong_split_after =
            (b < boundary_strong.size()) ? boundary_strong[b] : false;
        float purity = 1.0f;
        std::array<float, kMaxEmbDim> half_a_emb{}, half_b_emb{};
        bool has_halves = false;
        if (certified_pure_turn && !did_split) {
          rt.clean_spans = std::move(certified_clean_spans);
          rt.embedding = certified_turn_emb;
          rt.clean_seconds =
              std::min(10.0f, float(certified_clean_n) / 16000.0f);
          purity = certified_purity;
        } else {
          populate_raw_turn(rt, &purity, half_a_emb.data(), half_b_emb.data(),
                            &has_halves);
        }

        const int min_purity_split_span =
            is_eres2net ? 44800 : (2 * kMinSplitPieceSamples);
        if (purity < purity_split_th &&
            rt.end - rt.start >= min_purity_split_span) {
          const int mid = (rt.start + rt.end) / 2;
          const int lo = std::max(rt.start + kMinSplitPieceSamples, mid - 5600);
          const int hi = std::min(rt.end - kMinSplitPieceSamples, mid + 5600);
          const int valley =
              (hi > lo) ? FindEnergyValleySample(raw_samples, count, lo, hi)
                        : mid;
          if (valley - rt.start >= kMinSplitPieceSamples &&
              rt.end - valley >= kMinSplitPieceSamples) {
            RawTurn left_rt;
            left_rt.start = rt.start;
            left_rt.end = valley;
            left_rt.orig_track = label;
            left_rt.local_speaker = label;
            left_rt.was_split = true;
            left_rt.strong_split_after =
                purity < (is_eres2net ? 0.28f : 0.50f);

            RawTurn right_rt;
            right_rt.start = valley;
            right_rt.end = rt.end;
            right_rt.orig_track = label;
            right_rt.local_speaker = label;
            right_rt.was_split = true;
            right_rt.strong_split_after = rt.strong_split_after;

            if (has_halves && std::abs(valley - mid) <= 1600) {
              left_rt.clean_spans =
                  collect_exclusive_spans(label, left_rt.start, left_rt.end);
              int left_clean = 0;
              for (const auto &[cs, ce] : left_rt.clean_spans) {
                left_clean += (ce - cs);
              }
              left_rt.embedding = half_a_emb;
              left_rt.clean_seconds =
                  std::min(10.0f, float(left_clean) / 16000.0f);

              right_rt.clean_spans =
                  collect_exclusive_spans(label, right_rt.start, right_rt.end);
              int right_clean = 0;
              for (const auto &[cs, ce] : right_rt.clean_spans) {
                right_clean += (ce - cs);
              }
              right_rt.embedding = half_b_emb;
              right_rt.clean_seconds =
                  std::min(10.0f, float(right_clean) / 16000.0f);
            } else {
              float left_purity = 1.0f;
              populate_raw_turn(left_rt, &left_purity);
              if (left_purity < purity_drop_th) {
                left_rt.clean_seconds = 0.0f;
                left_rt.embedding.fill(0.0f);
              }
              float right_purity = 1.0f;
              populate_raw_turn(right_rt, &right_purity);
              if (right_purity < purity_drop_th) {
                right_rt.clean_seconds = 0.0f;
                right_rt.embedding.fill(0.0f);
              }
            }

            raw_turns.push_back(std::move(left_rt));
            raw_turns.push_back(std::move(right_rt));
            continue;
          }
        }
        if (purity < purity_drop_th) {
          rt.clean_seconds = 0.0f;
          rt.embedding.fill(0.0f);
        }
        raw_turns.push_back(std::move(rt));
      }
    }

    constexpr int kMaxConnectedGapSamples = 40000;  // 2.5 s
    struct Tracklet {
      int orig_track = 0;
      std::vector<size_t> turn_indices;
      std::vector<std::pair<int, int>> clean_spans;
      std::array<float, kMaxEmbDim> proto{};
      bool has_proto = false;
    };
    std::vector<Tracklet> tracklets;
    std::vector<int> turn_to_tracklet(raw_turns.size(), -1);
    std::vector<std::pair<int, int>> acoustic_split_links;

    const float attach_conflict_ceil = is_eres2net ? 0.64f : 0.82f;
    const float attach_min_sim = is_eres2net ? 0.46f : 0.72f;
    const float attach_incompat_sim = is_eres2net ? 0.36f : 0.60f;

    for (size_t i = 0; i < raw_turns.size(); ++i) {
      const auto &rt = raw_turns[i];
      if (rt.orig_track < 1 || rt.orig_track > rescue_track) continue;
      int attach = -1;
      int incompatible_prev_tr = -1;
      if (!rt.was_split && rt.orig_track <= K) {
        for (int t = static_cast<int>(tracklets.size()) - 1; t >= 0; --t) {
          if (tracklets[static_cast<size_t>(t)].orig_track != rt.orig_track) {
            continue;
          }
          const auto &t_turns = tracklets[static_cast<size_t>(t)].turn_indices;
          const size_t prev_turn_idx = t_turns.back();
          if (!raw_turns[prev_turn_idx].was_split &&
              rt.start - raw_turns[prev_turn_idx].end < kMaxConnectedGapSamples) {
            bool voice_mismatch = false;
            if (HasValidEmbeddingN(rt.embedding.data(), emb_dim)) {
              for (auto it = t_turns.rbegin(); it != t_turns.rend(); ++it) {
                if (!HasValidEmbeddingN(raw_turns[*it].embedding.data(), emb_dim)) {
                  continue;
                }
                const float sim = DotN(rt.embedding.data(),
                                       raw_turns[*it].embedding.data(), emb_dim);
                const auto ma = MatchEnrolledPerson(
                    rt.embedding.data(), emb_dim, enrolled_embeddings,
                    enrolled_person_ids, enrolled_count);
                const auto mb = MatchEnrolledPerson(
                    raw_turns[*it].embedding.data(), emb_dim,
                    enrolled_embeddings, enrolled_person_ids, enrolled_count);
                const bool enrolled_conflict =
                    (ma.person_id >= 0 && mb.person_id >= 0 &&
                     ma.person_id != mb.person_id && sim < attach_conflict_ceil);
                const bool one_sided_conflict = HasOneSidedEnrolledDropoff(
                    raw_turns[*it].embedding.data(), rt.embedding.data(),
                    emb_dim, sim, enrolled_embeddings, enrolled_person_ids,
                    enrolled_count);
                if (enrolled_conflict || one_sided_conflict ||
                    sim < attach_min_sim) {
                  voice_mismatch = true;
                  if (enrolled_conflict || one_sided_conflict ||
                      sim < attach_incompat_sim) {
                    incompatible_prev_tr = t;
                  }
                }
                break;
              }
            }
            if (!voice_mismatch) attach = t;
          }
          break;
        }
      }
      if (attach < 0) {
        attach = static_cast<int>(tracklets.size());
        Tracklet tr;
        tr.orig_track = rt.orig_track;
        tracklets.push_back(std::move(tr));
        if (incompatible_prev_tr >= 0) {
          acoustic_split_links.emplace_back(incompatible_prev_tr, attach);
        }
      }
      turn_to_tracklet[i] = attach;
      auto &tr = tracklets[static_cast<size_t>(attach)];
      tr.turn_indices.push_back(i);
      tr.clean_spans.insert(tr.clean_spans.end(), rt.clean_spans.begin(),
                            rt.clean_spans.end());
    }

    for (auto &tr : tracklets) {
      int best_turn = -1;
      for (size_t idx : tr.turn_indices) {
        if (raw_turns[idx].clean_seconds >= 0.6f &&
            HasValidEmbeddingN(raw_turns[idx].embedding.data(), emb_dim) &&
            (best_turn < 0 ||
             raw_turns[idx].clean_seconds >
                 raw_turns[static_cast<size_t>(best_turn)].clean_seconds)) {
          best_turn = static_cast<int>(idx);
        }
      }
      if (best_turn >= 0) {
        for (size_t idx : tr.turn_indices) {
          if (!HasValidEmbeddingN(raw_turns[idx].embedding.data(), emb_dim)) {
            raw_turns[idx].embedding =
                raw_turns[static_cast<size_t>(best_turn)].embedding;
          }
        }
      } else if (BuildCleanSpeechClip(raw_samples, tr.clean_spans,
                                      kMinSessionEmbedSamples, emb_dim,
                                      clip_buf)) {
        CheckSpeakerCancel(is_cancelled, cancel_context, cancel_token);
        std::array<float, kMaxEmbDim> pooled_emb{};
        ExtractNormalizedEmbedding(runtime->embedding, emb_dim, clip_buf.data(),
                                   static_cast<int>(clip_buf.size()),
                                   pooled_emb.data());
        for (size_t idx : tr.turn_indices) {
          if (!HasValidEmbeddingN(raw_turns[idx].embedding.data(), emb_dim)) {
            raw_turns[idx].embedding = pooled_emb;
          }
        }
      }

      tr.proto.fill(0.0f);
      tr.has_proto = false;
      for (size_t idx : tr.turn_indices) {
        if (HasValidEmbeddingN(raw_turns[idx].embedding.data(), emb_dim)) {
          const float w = std::max(0.25f, raw_turns[idx].clean_seconds);
          for (int d = 0; d < emb_dim; ++d) {
            tr.proto[static_cast<size_t>(d)] +=
                w * raw_turns[idx].embedding[static_cast<size_t>(d)];
          }
          tr.has_proto = true;
        }
      }
      if (tr.has_proto) tr.has_proto = NormalizeN(tr.proto.data(), emb_dim);
    }

    const size_t num_tr = tracklets.size();
    std::vector<std::vector<bool>> tr_cannot_link(
        num_tr, std::vector<bool>(num_tr, false));

    auto tracklet_active_samples_in = [&](size_t t, int w_lo, int w_hi) {
      int total = 0;
      for (size_t idx : tracklets[t].turn_indices) {
        const int s = std::max(w_lo, raw_turns[idx].start);
        const int e = std::min(w_hi, raw_turns[idx].end);
        if (e > s) total += (e - s);
      }
      return total;
    };

    const int step_frames =
        std::max(1, runtime->half_window_samples / runtime->shift);
    const int win_step = step_frames * runtime->shift;
    const int min_cooccur_samples = is_eres2net ? 9600 : 3200;
    for (int win_idx = 0;; ++win_idx) {
      const int w_lo = win_idx * win_step;
      if (w_lo >= count) break;
      const int w_hi = std::min<int>(count, w_lo + runtime->window_samples);
      for (size_t a = 0; a < num_tr; ++a) {
        if (tracklets[a].orig_track > K) continue;
        if (tracklet_active_samples_in(a, w_lo, w_hi) < min_cooccur_samples) {
          continue;
        }
        for (size_t b = a + 1; b < num_tr; ++b) {
          if (tracklets[b].orig_track > K) continue;
          if (tracklets[a].orig_track == tracklets[b].orig_track) continue;
          if (tracklet_active_samples_in(b, w_lo, w_hi) >= min_cooccur_samples) {
            tr_cannot_link[a][b] = true;
            tr_cannot_link[b][a] = true;
          }
        }
      }
      if (w_lo + runtime->window_samples >= count) break;
    }

    const float split_incompat_sim = is_eres2net ? 0.48f : 0.68f;
    for (size_t i = 1; i < raw_turns.size(); ++i) {
      if (raw_turns[i - 1].was_split && raw_turns[i].was_split &&
          raw_turns[i - 1].orig_track == raw_turns[i].orig_track) {
        const int ta = turn_to_tracklet[i - 1];
        const int tb = turn_to_tracklet[i];
        if (ta >= 0 && tb >= 0 && ta != tb) {
          bool incompatible = raw_turns[i - 1].strong_split_after;
          if (!incompatible &&
              HasValidEmbeddingN(raw_turns[i - 1].embedding.data(), emb_dim) &&
              HasValidEmbeddingN(raw_turns[i].embedding.data(), emb_dim)) {
            incompatible = DotN(raw_turns[i - 1].embedding.data(),
                                raw_turns[i].embedding.data(), emb_dim) <
                           split_incompat_sim;
          }
          if (incompatible) {
            tr_cannot_link[static_cast<size_t>(ta)][static_cast<size_t>(tb)] = true;
            tr_cannot_link[static_cast<size_t>(tb)][static_cast<size_t>(ta)] = true;
          }
        }
      }
    }
    for (const auto &[ta, tb] : acoustic_split_links) {
      if (ta >= 0 && tb >= 0 && ta != tb &&
          static_cast<size_t>(ta) < num_tr && static_cast<size_t>(tb) < num_tr) {
        tr_cannot_link[static_cast<size_t>(ta)][static_cast<size_t>(tb)] = true;
        tr_cannot_link[static_cast<size_t>(tb)][static_cast<size_t>(ta)] = true;
      }
    }

    std::vector<int> tr_cluster(num_tr);
    std::iota(tr_cluster.begin(), tr_cluster.end(), 0);
    std::vector<bool> tr_alive(num_tr, true);
    const float ahc_same_enrolled = is_eres2net ? 0.52f : 0.74f;
    const float ahc_anon = is_eres2net ? 0.50f : 0.78f;

    while (true) {
      int best_a = -1, best_b = -1;
      float best_sim = -2.0f;
      for (size_t a = 0; a < num_tr; ++a) {
        if (!tr_alive[a] || !tracklets[a].has_proto) continue;
        for (size_t b = a + 1; b < num_tr; ++b) {
          if (!tr_alive[b] || !tracklets[b].has_proto) continue;
          if (tr_cannot_link[a][b]) continue;
          const float sim =
              DotN(tracklets[a].proto.data(), tracklets[b].proto.data(), emb_dim);
          const auto ma = MatchEnrolledPerson(
              tracklets[a].proto.data(), emb_dim, enrolled_embeddings,
              enrolled_person_ids, enrolled_count);
          const auto mb = MatchEnrolledPerson(
              tracklets[b].proto.data(), emb_dim, enrolled_embeddings,
              enrolled_person_ids, enrolled_count);
          if (ma.person_id >= 0 && mb.person_id >= 0 &&
              ma.person_id != mb.person_id) {
            continue;
          }
          if (HasOneSidedEnrolledDropoff(
                  tracklets[a].proto.data(), tracklets[b].proto.data(), emb_dim,
                  sim, enrolled_embeddings, enrolled_person_ids, enrolled_count)) {
            continue;
          }
          const bool same_enrolled =
              (ma.person_id >= 0 && ma.person_id == mb.person_id);
          const float min_sim = same_enrolled ? ahc_same_enrolled : ahc_anon;
          if (sim >= min_sim && sim > best_sim) {
            best_sim = sim;
            best_a = static_cast<int>(a);
            best_b = static_cast<int>(b);
          }
        }
      }
      if (best_a < 0) break;
      const size_t ka = static_cast<size_t>(best_a);
      const size_t kb = static_cast<size_t>(best_b);
      for (size_t t = 0; t < num_tr; ++t) {
        if (tr_cluster[t] == static_cast<int>(kb)) {
          tr_cluster[t] = static_cast<int>(ka);
        }
      }
      for (size_t c = 0; c < num_tr; ++c) {
        if (c != ka && tr_cannot_link[kb][c]) {
          tr_cannot_link[ka][c] = true;
          tr_cannot_link[c][ka] = true;
        }
      }
      tracklets[ka].turn_indices.insert(tracklets[ka].turn_indices.end(),
                                        tracklets[kb].turn_indices.begin(),
                                        tracklets[kb].turn_indices.end());
      tracklets[ka].proto.fill(0.0f);
      for (size_t idx : tracklets[ka].turn_indices) {
        if (HasValidEmbeddingN(raw_turns[idx].embedding.data(), emb_dim)) {
          const float w = std::max(0.25f, raw_turns[idx].clean_seconds);
          for (int d = 0; d < emb_dim; ++d) {
            tracklets[ka].proto[static_cast<size_t>(d)] +=
                w * raw_turns[idx].embedding[static_cast<size_t>(d)];
          }
        }
      }
      NormalizeN(tracklets[ka].proto.data(), emb_dim);
      tr_alive[kb] = false;
    }

    // Absorb unverified sub-second noise/backchannel clusters (< 0.95 s active,
    // < 0.55 s clean) into their nearest compatible dominant speaker cluster so
    // Watch far-field noise cannot spawn 8-11 phantom speakers per 15 s window.
    if (is_eres2net && num_tr > 1) {
      std::vector<int> cluster_samples(num_tr, 0);
      std::vector<float> cluster_clean(num_tr, 0.0f);
      for (size_t c = 0; c < num_tr; ++c) {
        if (!tr_alive[c]) continue;
        for (size_t idx : tracklets[c].turn_indices) {
          cluster_samples[c] +=
              std::max(0, raw_turns[idx].end - raw_turns[idx].start);
          cluster_clean[c] += raw_turns[idx].clean_seconds;
        }
      }
      for (size_t c = 0; c < num_tr; ++c) {
        if (!tr_alive[c]) continue;
        if (cluster_samples[c] >= 15200 || cluster_clean[c] >= 0.55f) continue;
        EnrolledMatch mc{};
        if (tracklets[c].has_proto) {
          mc = MatchEnrolledPerson(tracklets[c].proto.data(), emb_dim,
                                   enrolled_embeddings, enrolled_person_ids,
                                   enrolled_count);
          if (mc.person_id >= 0) continue;
        }
        int best_target = -1;
        int best_gap = std::numeric_limits<int>::max();
        for (size_t idx : tracklets[c].turn_indices) {
          const auto &micro = raw_turns[idx];
          for (int dir : {-1, 1}) {
            const int nb = static_cast<int>(idx) + dir;
            if (nb < 0 || nb >= static_cast<int>(raw_turns.size())) continue;
            const auto &nb_turn = raw_turns[static_cast<size_t>(nb)];
            if (nb_turn.orig_track < 1) continue;
            const int nb_tr = turn_to_tracklet[static_cast<size_t>(nb)];
            if (nb_tr < 0) continue;
            const size_t cand =
                static_cast<size_t>(tr_cluster[static_cast<size_t>(nb_tr)]);
            if (cand == c || !tr_alive[cand]) continue;
            if (cluster_samples[cand] < 16000) continue;
            if (tracklets[c].has_proto && tr_cannot_link[c][cand]) continue;
            if (tracklets[c].has_proto && tracklets[cand].has_proto) {
              const float sim = DotN(tracklets[c].proto.data(),
                                     tracklets[cand].proto.data(), emb_dim);
              if (sim < 0.32f) continue;
              if (HasOneSidedEnrolledDropoff(
                      tracklets[cand].proto.data(), tracklets[c].proto.data(),
                      emb_dim, sim, enrolled_embeddings, enrolled_person_ids,
                      enrolled_count)) {
                continue;
              }
            }
            const int gap =
                dir < 0 ? std::max(0, micro.start - nb_turn.end)
                        : std::max(0, nb_turn.start - micro.end);
            if (gap <= 48000 && gap < best_gap) {
              best_gap = gap;
              best_target = static_cast<int>(cand);
            }
          }
        }
        if (best_target >= 0) {
          const size_t kt = static_cast<size_t>(best_target);
          for (size_t idx : tracklets[c].turn_indices) {
            raw_turns[idx].clean_seconds = 0.0f;
          }
          for (size_t t = 0; t < num_tr; ++t) {
            if (tr_cluster[t] == static_cast<int>(c)) {
              tr_cluster[t] = best_target;
            }
          }
          tracklets[kt].turn_indices.insert(tracklets[kt].turn_indices.end(),
                                            tracklets[c].turn_indices.begin(),
                                            tracklets[c].turn_indices.end());
          cluster_samples[kt] += cluster_samples[c];
          tr_alive[c] = false;
        }
      }
    }

    std::vector<int> cluster_to_speaker(num_tr, 0);
    std::vector<std::vector<size_t>> clique_buckets;
    for (size_t i = 0; i < raw_turns.size(); ++i) {
      if (raw_turns[i].orig_track < 1) {
        raw_turns[i].local_speaker = -1;
        continue;
      }
      const int t = turn_to_tracklet[i];
      const size_t root = static_cast<size_t>(tr_cluster[static_cast<size_t>(t)]);
      if (cluster_to_speaker[root] == 0) {
        int placed_bucket = -1;
        for (size_t b = 0; b < clique_buckets.size(); ++b) {
          if (clique_buckets[b].size() >= 4) continue;
          bool mutually_incompatible = true;
          for (size_t member : clique_buckets[b]) {
            if (!tr_cannot_link[root][member]) {
              mutually_incompatible = false;
              break;
            }
          }
          if (mutually_incompatible) {
            placed_bucket = static_cast<int>(b);
            break;
          }
        }
        if (placed_bucket >= 0) {
          auto &bucket = clique_buckets[static_cast<size_t>(placed_bucket)];
          bucket.push_back(root);
          cluster_to_speaker[root] =
              placed_bucket * 4 + static_cast<int>(bucket.size());
        } else {
          clique_buckets.push_back({root});
          cluster_to_speaker[root] =
              (static_cast<int>(clique_buckets.size()) - 1) * 4 + 1;
        }
      }
      raw_turns[i].local_speaker = cluster_to_speaker[root];
    }

    if (static_cast<int32_t>(raw_turns.size()) > capacity) {
      throw std::runtime_error("Speaker output capacity exceeded");
    }
    const int written = static_cast<int>(raw_turns.size());
    for (int i = 0; i < written; ++i) {
      auto &dst = turns[i];
      const auto &src = raw_turns[static_cast<size_t>(i)];
      dst = {};
      dst.start_sample = src.start;
      dst.end_sample = src.end;
      dst.local_speaker = src.local_speaker;
      dst.embedding_dim = emb_dim;
      dst.clean_seconds = src.clean_seconds;
      std::copy(src.embedding.begin(), src.embedding.end(), dst.embedding);
    }

    return written;
  } catch (const SpeakerCancelled &) {
    return -2;
  } catch (const Ort::Exception &e) {
    if ((cancel_token && cancel_token->IsCancelled()) ||
        (is_cancelled && is_cancelled(cancel_context) != 0)) {
      return -2;
    }
    if (error && error_capacity) {
      std::snprintf(error, error_capacity, "%s", e.what());
    }
  } catch (const std::exception &e) {
    if (error && error_capacity) {
      std::snprintf(error, error_capacity, "%s", e.what());
    }
  } catch (...) {
    if (error && error_capacity) {
      std::snprintf(error, error_capacity, "Speaker inference failed");
    }
  }
  return -1;
}

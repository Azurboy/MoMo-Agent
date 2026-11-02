#include "MoMoSherpaBridge.h"
#include <onnxruntime/onnxruntime_cxx_api.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <fstream>
#include <limits>
#include <memory>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace {

struct CancelledError : public std::exception {
  const char *what() const noexcept override { return "cancelled"; }
};

inline void CheckCancel(MoMoCancelCallback cb, const void *ctx) {
  if (cb && cb(ctx) != 0) {
    throw CancelledError();
  }
}

inline void SaveError(char *buffer, size_t capacity, const char *text) {
  if (buffer && capacity > 0) {
    std::snprintf(buffer, capacity, "%s", text ? text : "Unknown error");
  }
}

inline char *DupCString(const std::string &s) {
  char *out = static_cast<char *>(std::malloc(s.size() + 1));
  if (!out) throw std::bad_alloc();
  std::memcpy(out, s.data(), s.size());
  out[s.size()] = '\0';
  return out;
}

inline float HalfBitsToFloat(uint16_t h) {
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

inline void ConvertHalfToFloatRaw(const uint16_t *src, float *dst, size_t n) {
#if defined(__ARM_NEON) || defined(__aarch64__)
  const __fp16 *h = reinterpret_cast<const __fp16 *>(src);
  for (size_t i = 0; i < n; ++i) {
    dst[i] = static_cast<float>(h[i]);
  }
#else
  for (size_t i = 0; i < n; ++i) {
    dst[i] = HalfBitsToFloat(src[i]);
  }
#endif
}

inline uint16_t FloatToHalfBits(float f) {
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
}

std::string ReadWholeFile(const std::string &path) {
  std::ifstream ifs(path, std::ios::binary | std::ios::ate);
  if (!ifs) {
    throw std::runtime_error("Cannot open file: " + path);
  }
  std::streamsize sz = ifs.tellg();
  if (sz < 0) {
    throw std::runtime_error("Failed to stat file: " + path);
  }
  std::string out(static_cast<size_t>(sz), '\0');
  ifs.seekg(0, std::ios::beg);
  if (sz > 0 && !ifs.read(&out[0], sz)) {
    throw std::runtime_error("Failed to read file: " + path);
  }
  return out;
}

inline void TrimString(std::string *s) {
  if (!s) return;
  size_t b = s->find_first_not_of(" \t\r\n");
  if (b == std::string::npos) {
    s->clear();
    return;
  }
  size_t e = s->find_last_not_of(" \t\r\n");
  *s = s->substr(b, e - b + 1);
}

inline void AppendUtf8(uint32_t cp, std::string *out) {
  if (cp <= 0x7Fu) {
    out->push_back(static_cast<char>(cp));
  } else if (cp <= 0x7FFu) {
    out->push_back(static_cast<char>(0xC0u | ((cp >> 6) & 0x1Fu)));
    out->push_back(static_cast<char>(0x80u | (cp & 0x3Fu)));
  } else if (cp <= 0xFFFFu) {
    out->push_back(static_cast<char>(0xE0u | ((cp >> 12) & 0x0Fu)));
    out->push_back(static_cast<char>(0x80u | ((cp >> 6) & 0x3Fu)));
    out->push_back(static_cast<char>(0x80u | (cp & 0x3Fu)));
  } else {
    out->push_back(static_cast<char>(0xF0u | ((cp >> 18) & 0x07u)));
    out->push_back(static_cast<char>(0x80u | ((cp >> 12) & 0x3Fu)));
    out->push_back(static_cast<char>(0x80u | ((cp >> 6) & 0x3Fu)));
    out->push_back(static_cast<char>(0x80u | (cp & 0x3Fu)));
  }
}

inline bool Utf8Next(const std::string &s, size_t *i, uint32_t *cp,
                     size_t *nbytes) {
  if (*i >= s.size()) return false;
  const unsigned char c = static_cast<unsigned char>(s[*i]);
  if (c < 0x80) {
    *cp = c;
    *nbytes = 1;
    return true;
  }
  if ((c >> 5) == 0x6) {
    if (*i + 1 >= s.size()) return false;
    const unsigned char c1 = static_cast<unsigned char>(s[*i + 1]);
    if ((c1 >> 6) != 0x2) return false;
    *cp = ((c & 0x1Fu) << 6) | (c1 & 0x3Fu);
    *nbytes = 2;
    return true;
  }
  if ((c >> 4) == 0xE) {
    if (*i + 2 >= s.size()) return false;
    const unsigned char c1 = static_cast<unsigned char>(s[*i + 1]);
    const unsigned char c2 = static_cast<unsigned char>(s[*i + 2]);
    if ((c1 >> 6) != 0x2 || (c2 >> 6) != 0x2) return false;
    *cp = ((c & 0x0Fu) << 12) | ((c1 & 0x3Fu) << 6) | (c2 & 0x3Fu);
    *nbytes = 3;
    return true;
  }
  if ((c >> 3) == 0x1E) {
    if (*i + 3 >= s.size()) return false;
    const unsigned char c1 = static_cast<unsigned char>(s[*i + 1]);
    const unsigned char c2 = static_cast<unsigned char>(s[*i + 2]);
    const unsigned char c3 = static_cast<unsigned char>(s[*i + 3]);
    if ((c1 >> 6) != 0x2 || (c2 >> 6) != 0x2 || (c3 >> 6) != 0x2) return false;
    *cp = ((c & 0x07u) << 18) | ((c1 & 0x3Fu) << 12) | ((c2 & 0x3Fu) << 6) |
          (c3 & 0x3Fu);
    *nbytes = 4;
    return true;
  }
  return false;
}

inline bool IsNewline(uint32_t cp) { return cp == '\n' || cp == '\r'; }
inline bool IsWhitespace(uint32_t cp) {
  return cp == ' ' || cp == '\t' || cp == '\n' || cp == '\r' || cp == '\v' ||
         cp == '\f';
}
inline bool IsLetter(uint32_t cp) {
  if ((cp >= 'a' && cp <= 'z') || (cp >= 'A' && cp <= 'Z')) return true;
  if (cp >= 0x4E00 && cp <= 0x9FFF) return true;
  if (cp >= 0x3400 && cp <= 0x4DBF) return true;
  if (cp >= 0x3040 && cp <= 0x30FF) return true;
  if (cp >= 0xAC00 && cp <= 0xD7AF) return true;
  if (cp >= 0x1100 && cp <= 0x11FF) return true;
  if (cp >= 0x00C0 && cp <= 0x02AF) return true;
  return false;
}
inline bool IsNumber(uint32_t cp) {
  return (cp >= '0' && cp <= '9') || (cp >= 0xFF10 && cp <= 0xFF19);
}
inline bool IsWordChar(uint32_t cp) {
  return IsLetter(cp) || IsNumber(cp) || cp == '_';
}

class JsonReader {
 public:
  explicit JsonReader(const std::string &s) : s_(s), p_(0) {}

  bool SeekToKey(const std::string &key) {
    std::string needle = "\"" + key + "\"";
    size_t pos = s_.find(needle);
    if (pos == std::string::npos) return false;
    p_ = pos + needle.size();
    return true;
  }

  void SkipWs() {
    while (p_ < s_.size()) {
      char c = s_[p_];
      if (c == ' ' || c == '\t' || c == '\r' || c == '\n') ++p_;
      else break;
    }
  }

  bool Consume(char c) {
    SkipWs();
    if (p_ < s_.size() && s_[p_] == c) {
      ++p_;
      return true;
    }
    return false;
  }

  bool ParseString(std::string *out) {
    SkipWs();
    if (p_ >= s_.size() || s_[p_] != '"') return false;
    ++p_;
    std::string r;
    while (p_ < s_.size()) {
      char c = s_[p_++];
      if (c == '"') {
        *out = std::move(r);
        return true;
      }
      if (c != '\\') {
        r.push_back(c);
        continue;
      }
      if (p_ >= s_.size()) return false;
      char esc = s_[p_++];
      switch (esc) {
        case '"': r.push_back('"'); break;
        case '\\': r.push_back('\\'); break;
        case '/': r.push_back('/'); break;
        case 'b': r.push_back('\b'); break;
        case 'f': r.push_back('\f'); break;
        case 'n': r.push_back('\n'); break;
        case 'r': r.push_back('\r'); break;
        case 't': r.push_back('\t'); break;
        case 'u': {
          if (p_ + 4 > s_.size()) return false;
          uint32_t u = 0;
          for (int i = 0; i < 4; ++i) {
            char h = s_[p_++];
            u <<= 4;
            if (h >= '0' && h <= '9') u |= static_cast<uint32_t>(h - '0');
            else if (h >= 'a' && h <= 'f') u |= static_cast<uint32_t>(h - 'a' + 10);
            else if (h >= 'A' && h <= 'F') u |= static_cast<uint32_t>(h - 'A' + 10);
            else return false;
          }
          if (u >= 0xD800 && u <= 0xDBFF && p_ + 6 <= s_.size() &&
              s_[p_] == '\\' && s_[p_ + 1] == 'u') {
            size_t save = p_;
            p_ += 2;
            uint32_t v = 0;
            bool ok = true;
            for (int i = 0; i < 4; ++i) {
              char h = s_[p_++];
              v <<= 4;
              if (h >= '0' && h <= '9') v |= static_cast<uint32_t>(h - '0');
              else if (h >= 'a' && h <= 'f') v |= static_cast<uint32_t>(h - 'a' + 10);
              else if (h >= 'A' && h <= 'F') v |= static_cast<uint32_t>(h - 'A' + 10);
              else { ok = false; break; }
            }
            if (ok && v >= 0xDC00 && v <= 0xDFFF) {
              uint32_t cp = 0x10000u + (((u - 0xD800u) << 10) | (v - 0xDC00u));
              AppendUtf8(cp, &r);
              break;
            }
            p_ = save;
          }
          AppendUtf8(u, &r);
          break;
        }
        default:
          return false;
      }
    }
    return false;
  }

  bool ParseBool(bool *out) {
    SkipWs();
    if (p_ + 4 <= s_.size() && s_.compare(p_, 4, "true") == 0) {
      p_ += 4;
      *out = true;
      return true;
    }
    if (p_ + 5 <= s_.size() && s_.compare(p_, 5, "false") == 0) {
      p_ += 5;
      *out = false;
      return true;
    }
    return false;
  }

  bool ParseInt64(int64_t *out) {
    SkipWs();
    if (p_ >= s_.size()) return false;
    bool neg = false;
    if (s_[p_] == '-') {
      neg = true;
      ++p_;
    }
    if (p_ >= s_.size() || !std::isdigit(static_cast<unsigned char>(s_[p_]))) {
      return false;
    }
    int64_t v = 0;
    while (p_ < s_.size() && std::isdigit(static_cast<unsigned char>(s_[p_]))) {
      int d = s_[p_] - '0';
      if (v > (std::numeric_limits<int64_t>::max() - d) / 10) return false;
      v = v * 10 + d;
      ++p_;
    }
    *out = neg ? -v : v;
    return true;
  }

  bool SkipValue() {
    SkipWs();
    if (p_ >= s_.size()) return false;
    char c = s_[p_];
    if (c == '"') {
      std::string tmp;
      return ParseString(&tmp);
    }
    if (c == '{') return SkipObject();
    if (c == '[') return SkipArray();
    if (c == 't' || c == 'f') {
      bool b = false;
      return ParseBool(&b);
    }
    if (c == 'n') {
      if (p_ + 4 <= s_.size() && s_.compare(p_, 4, "null") == 0) {
        p_ += 4;
        return true;
      }
      return false;
    }
    int64_t v = 0;
    return ParseInt64(&v);
  }

 private:
  bool SkipObject() {
    if (!Consume('{')) return false;
    if (Consume('}')) return true;
    while (true) {
      std::string k;
      if (!ParseString(&k) || !Consume(':') || !SkipValue()) return false;
      if (Consume('}')) return true;
      if (!Consume(',')) return false;
    }
  }

  bool SkipArray() {
    if (!Consume('[')) return false;
    if (Consume(']')) return true;
    while (true) {
      if (!SkipValue()) return false;
      if (Consume(']')) return true;
      if (!Consume(',')) return false;
    }
  }

  const std::string &s_;
  size_t p_;
};

std::vector<std::string> SplitByQwen3Pattern(const std::string &text) {
  std::vector<std::string> out;
  out.reserve(text.size() / 2 + 1);
  size_t i = 0;
  while (i < text.size()) {
    if (text[i] == '\'') {
      auto lower = [](char c) -> char {
        return static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
      };
      if (i + 1 < text.size()) {
        char c1 = lower(text[i + 1]);
        if (c1 == 's' || c1 == 't' || c1 == 'm' || c1 == 'd') {
          out.push_back(text.substr(i, 2));
          i += 2;
          continue;
        }
        if (i + 2 < text.size()) {
          char c2 = lower(text[i + 2]);
          if ((c1 == 'r' && c2 == 'e') || (c1 == 'v' && c2 == 'e') ||
              (c1 == 'l' && c2 == 'l')) {
            out.push_back(text.substr(i, 3));
            i += 3;
            continue;
          }
        }
      }
    }

    size_t cur = i;
    uint32_t cp = 0;
    size_t n = 0;
    if (!Utf8Next(text, &cur, &cp, &n) || n == 0) {
      out.push_back(text.substr(i, 1));
      i += 1;
      continue;
    }

    auto peek_next_cp = [&](size_t pos, uint32_t *cp2, size_t *n2) -> bool {
      size_t t = pos;
      uint32_t x = 0;
      size_t nn = 0;
      if (!Utf8Next(text, &t, &x, &nn)) return false;
      *cp2 = x;
      *n2 = nn;
      return true;
    };

    {
      uint32_t next_cp = 0;
      size_t next_n = 0;
      bool has_next = peek_next_cp(i + n, &next_cp, &next_n);
      bool cur_ok_prefix = (!IsNewline(cp) && !IsLetter(cp) && !IsNumber(cp));
      bool cur_is_letter = IsLetter(cp);
      if (cur_is_letter || (cur_ok_prefix && has_next && IsLetter(next_cp))) {
        size_t start = i;
        size_t j = cur_is_letter ? i : (i + n);
        while (j < text.size()) {
          size_t t = j;
          uint32_t cpl = 0;
          size_t nl = 0;
          if (!Utf8Next(text, &t, &cpl, &nl) || !IsLetter(cpl)) break;
          j += nl;
        }
        out.push_back(text.substr(start, j - start));
        i = j;
        continue;
      }
    }

    if (IsNumber(cp)) {
      out.push_back(text.substr(i, n));
      i += n;
      continue;
    }

    {
      auto is_punct_like = [](uint32_t x) -> bool {
        return !IsWhitespace(x) && !IsLetter(x) && !IsNumber(x);
      };
      size_t start = i;
      size_t j = i;
      if (cp == ' ') {
        uint32_t next_cp = 0;
        size_t next_n = 0;
        if (peek_next_cp(i + n, &next_cp, &next_n) && is_punct_like(next_cp)) {
          j += n;
          while (j < text.size()) {
            size_t t = j;
            uint32_t cx = 0;
            size_t nx = 0;
            if (!Utf8Next(text, &t, &cx, &nx) || !is_punct_like(cx)) break;
            j += nx;
          }
          while (j < text.size()) {
            size_t t = j;
            uint32_t cx = 0;
            size_t nx = 0;
            if (!Utf8Next(text, &t, &cx, &nx) || !IsNewline(cx)) break;
            j += nx;
          }
          out.push_back(text.substr(start, j - start));
          i = j;
          continue;
        }
      } else if (is_punct_like(cp)) {
        while (j < text.size()) {
          size_t t = j;
          uint32_t cx = 0;
          size_t nx = 0;
          if (!Utf8Next(text, &t, &cx, &nx) || !is_punct_like(cx)) break;
          j += nx;
        }
        while (j < text.size()) {
          size_t t = j;
          uint32_t cx = 0;
          size_t nx = 0;
          if (!Utf8Next(text, &t, &cx, &nx) || !IsNewline(cx)) break;
          j += nx;
        }
        out.push_back(text.substr(start, j - start));
        i = j;
        continue;
      }
    }

    if (IsWhitespace(cp)) {
      size_t start = i;
      size_t j = i;
      bool saw_newline = false;
      while (j < text.size()) {
        size_t t = j;
        uint32_t cx = 0;
        size_t nx = 0;
        if (!Utf8Next(text, &t, &cx, &nx)) break;
        if (IsNewline(cx)) {
          saw_newline = true;
          break;
        }
        if (!IsWhitespace(cx)) break;
        j += nx;
      }
      if (saw_newline) {
        while (j < text.size()) {
          size_t t = j;
          uint32_t cx = 0;
          size_t nx = 0;
          if (!Utf8Next(text, &t, &cx, &nx) || !IsNewline(cx)) break;
          j += nx;
        }
        out.push_back(text.substr(start, j - start));
        i = j;
        continue;
      }
      bool only_ws_to_end = true;
      size_t k = i;
      while (k < text.size()) {
        size_t t = k;
        uint32_t cx = 0;
        size_t nx = 0;
        if (!Utf8Next(text, &t, &cx, &nx)) break;
        if (!IsWhitespace(cx)) {
          only_ws_to_end = false;
          break;
        }
        k += nx;
      }
      if (only_ws_to_end) {
        out.push_back(text.substr(i));
        break;
      }
      j = i;
      while (j < text.size()) {
        size_t t = j;
        uint32_t cx = 0;
        size_t nx = 0;
        if (!Utf8Next(text, &t, &cx, &nx) || !IsWhitespace(cx)) break;
        j += nx;
      }
      out.push_back(text.substr(start, j - start));
      i = j;
      continue;
    }

    out.push_back(text.substr(i, n));
    i += n;
  }
  return out;
}

class Qwen3Tokenizer {
 public:
  struct AddedToken {
    int32_t id = -1;
    std::string content;
    bool single_word = false;
    bool special = false;
  };
  struct TrieNode {
    std::unordered_map<uint8_t, int32_t> next;
    int32_t token_index = -1;
  };

  explicit Qwen3Tokenizer(const std::string &dir) {
    const std::string tok_blob = ReadWholeFile(dir + "/tokenizer.json");
    const std::string vocab_blob = ReadWholeFile(dir + "/vocab.json");
    const std::string merges_blob = ReadWholeFile(dir + "/merges.txt");

    token2id_.reserve(155000);
    merges_rank_.reserve(155000);
    BuildBytesToUnicode();
    ParseVocab(vocab_blob);
    ParseMerges(merges_blob);
    ParseAddedTokens(tok_blob);

    std::unordered_set<std::string> added_contents;
    for (const auto &t : added_tokens_) {
      if (t.id < 0 || t.content.empty()) continue;
      added_contents.insert(t.content);
      token2id_[t.content] = t.id;
    }

    int32_t max_id = -1;
    for (const auto &kv : token2id_) max_id = std::max(max_id, kv.second);
    if (max_id < 0) throw std::runtime_error("Empty Qwen3 vocabulary");
    id2token_.assign(static_cast<size_t>(max_id) + 1, std::string{});
    for (const auto &kv : token2id_) {
      if (kv.second < 0) continue;
      std::string &slot = id2token_[static_cast<size_t>(kv.second)];
      if (slot.empty() ||
          (!added_contents.count(slot) && added_contents.count(kv.first))) {
        slot = kv.first;
      }
    }

    trie_.push_back(TrieNode{});
    for (int32_t idx = 0; idx < static_cast<int32_t>(added_tokens_.size());
         ++idx) {
      int32_t node = 0;
      for (unsigned char b : added_tokens_[static_cast<size_t>(idx)].content) {
        auto it = trie_[static_cast<size_t>(node)].next.find(b);
        if (it == trie_[static_cast<size_t>(node)].next.end()) {
          int32_t next_node = static_cast<int32_t>(trie_.size());
          trie_.push_back(TrieNode{});
          trie_[static_cast<size_t>(node)].next.emplace(b, next_node);
          node = next_node;
        } else {
          node = it->second;
        }
      }
      trie_[static_cast<size_t>(node)].token_index = idx;
    }

    im_end_id_ = LookupId("<|im_end|>", 151645);
    eos_id_ = LookupId("<|endoftext|>", im_end_id_);
    pad_id_ = LookupId("<|pad|>", eos_id_);
    special_ids_.insert(static_cast<int32_t>(im_end_id_));
    special_ids_.insert(static_cast<int32_t>(eos_id_));
    special_ids_.insert(static_cast<int32_t>(pad_id_));
    int64_t im_start = LookupId("<|im_start|>", -1);
    if (im_start >= 0) special_ids_.insert(static_cast<int32_t>(im_start));

    // Precompute tokens exempt from repetition penalty: digits and clause punctuation.
    penalty_exempt_.assign(id2token_.size(), 0);
    for (size_t id = 0; id < id2token_.size(); ++id) {
      if (special_ids_.count(static_cast<int32_t>(id))) {
        penalty_exempt_[id] = 1;
        continue;
      }
      std::string piece = DecodeRawBytes(id2token_[id]);
      if (piece.empty()) continue;
      bool all_digits = true;
      for (unsigned char c : piece) {
        if (c < '0' || c > '9') {
          all_digits = false;
          break;
        }
      }
      if (all_digits || piece == "，" || piece == "。" || piece == "、" ||
          piece == "," || piece == "." || piece == " ") {
        penalty_exempt_[id] = 1;
      }
    }
  }

  int64_t eos_id() const { return eos_id_; }
  int64_t im_end_id() const { return im_end_id_; }
  int64_t pad_id() const { return pad_id_; }

  bool IsPenaltyExempt(int64_t token_id) const {
    if (token_id < 0 || static_cast<size_t>(token_id) >= penalty_exempt_.size())
      return true;
    return penalty_exempt_[static_cast<size_t>(token_id)] != 0;
  }

  std::vector<int64_t> Encode(const std::string &text) {
    std::vector<int64_t> out;
    if (text.empty()) return out;
    size_t pos = 0, last = 0;
    while (pos < text.size()) {
      auto [mlen, tidx] = MatchAdded(text, pos);
      if (mlen > 0 && tidx >= 0 &&
          added_tokens_[static_cast<size_t>(tidx)].single_word &&
          !SingleWordBoundary(text, pos, pos + static_cast<size_t>(mlen))) {
        mlen = 0;
        tidx = -1;
      }
      if (mlen > 0 && tidx >= 0) {
        if (pos > last) EncodeSegment(text.substr(last, pos - last), &out);
        out.push_back(added_tokens_[static_cast<size_t>(tidx)].id);
        pos += static_cast<size_t>(mlen);
        last = pos;
        continue;
      }
      ++pos;
    }
    if (last < text.size()) EncodeSegment(text.substr(last), &out);
    return out;
  }

  std::string Decode(const std::vector<int64_t> &ids) const {
    if (ids.empty()) return "";
    std::string merged;
    for (int64_t v : ids) {
      if (v < 0 || static_cast<size_t>(v) >= id2token_.size()) continue;
      if (special_ids_.count(static_cast<int32_t>(v))) continue;
      merged.append(id2token_[static_cast<size_t>(v)]);
    }
    return DecodeRawBytes(merged);
  }

 private:
  int64_t LookupId(const std::string &tok, int64_t fallback) const {
    auto it = token2id_.find(tok);
    return it == token2id_.end() ? fallback : static_cast<int64_t>(it->second);
  }

  void BuildBytesToUnicode() {
    std::fill(std::begin(cp_to_byte_), std::end(cp_to_byte_), int16_t(-1));
    std::vector<uint32_t> bs;
    bs.reserve(256);
    for (uint32_t c = 33; c <= 126; ++c) bs.push_back(c);
    for (uint32_t c = 161; c <= 172; ++c) bs.push_back(c);
    for (uint32_t c = 174; c <= 255; ++c) bs.push_back(c);
    std::vector<uint32_t> cs = bs;
    uint32_t n = 0;
    for (uint32_t b = 0; b <= 255; ++b) {
      if (std::find(bs.begin(), bs.end(), b) == bs.end()) {
        bs.push_back(b);
        cs.push_back(256 + n++);
      }
    }
    for (size_t i = 0; i < bs.size(); ++i) {
      std::string u;
      AppendUtf8(cs[i], &u);
      byte_to_unicode_[bs[i]] = u;
      if (cs[i] < 512) {
        cp_to_byte_[cs[i]] = static_cast<int16_t>(bs[i]);
      }
    }
  }

  void ParseVocab(const std::string &blob) {
    JsonReader r(blob);
    if (!r.Consume('{')) throw std::runtime_error("Invalid vocab.json");
    if (r.Consume('}')) return;
    while (true) {
      std::string k;
      int64_t id = 0;
      if (!r.ParseString(&k) || !r.Consume(':') || !r.ParseInt64(&id))
        throw std::runtime_error("Malformed vocab.json");
      token2id_[k] = static_cast<int32_t>(id);
      if (r.Consume('}')) break;
      if (!r.Consume(',')) throw std::runtime_error("Malformed vocab.json");
    }
  }

  void ParseMerges(const std::string &blob) {
    int32_t rank = 0;
    size_t pos = 0;
    const size_t n = blob.size();
    while (pos < n) {
      const size_t nl = blob.find('\n', pos);
      size_t end = (nl == std::string::npos) ? n : nl;
      size_t start = pos;
      pos = (nl == std::string::npos) ? n : nl + 1;
      while (start < end && (blob[start] == ' ' || blob[start] == '\t' ||
                             blob[start] == '\r')) {
        ++start;
      }
      while (end > start && (blob[end - 1] == ' ' || blob[end - 1] == '\t' ||
                             blob[end - 1] == '\r')) {
        --end;
      }
      if (start >= end) continue;
      if (end - start >= 8 && blob.compare(start, 8, "#version") == 0) continue;
      const size_t sp = blob.find(' ', start);
      if (sp == std::string::npos || sp <= start || sp >= end) continue;
      size_t b_start = sp + 1;
      while (b_start < end && blob[b_start] == ' ') ++b_start;
      if (b_start >= end) continue;
      size_t b_end = b_start;
      while (b_end < end && blob[b_end] != ' ' && blob[b_end] != '\t' &&
             blob[b_end] != '\r') {
        ++b_end;
      }
      std::string key;
      key.reserve((sp - start) + 1 + (b_end - b_start));
      key.append(blob, start, sp - start);
      key.push_back('\t');
      key.append(blob, b_start, b_end - b_start);
      merges_rank_.emplace(std::move(key), rank++);
    }
  }

  void ParseAddedTokens(const std::string &blob) {
    JsonReader r(blob);
    if (!r.SeekToKey("added_tokens")) return;
    if (!r.Consume(':') || !r.Consume('['))
      throw std::runtime_error("Malformed added_tokens in tokenizer.json");
    if (r.Consume(']')) return;
    while (true) {
      if (!r.Consume('{'))
        throw std::runtime_error("Malformed added_token entry");
      AddedToken t;
      if (!r.Consume('}')) {
        while (true) {
          std::string k;
          if (!r.ParseString(&k) || !r.Consume(':'))
            throw std::runtime_error("Malformed added_token field");
          if (k == "id") {
            int64_t v = 0;
            if (!r.ParseInt64(&v)) throw std::runtime_error("Bad token id");
            t.id = static_cast<int32_t>(v);
          } else if (k == "content") {
            if (!r.ParseString(&t.content))
              throw std::runtime_error("Bad token content");
          } else if (k == "single_word") {
            if (!r.ParseBool(&t.single_word))
              throw std::runtime_error("Bad single_word");
          } else if (k == "special") {
            if (!r.ParseBool(&t.special))
              throw std::runtime_error("Bad special");
          } else {
            if (!r.SkipValue()) throw std::runtime_error("Bad token value");
          }
          if (r.Consume('}')) break;
          if (!r.Consume(',')) throw std::runtime_error("Bad token comma");
        }
      }
      if (t.id >= 0 && !t.content.empty()) added_tokens_.push_back(std::move(t));
      if (r.Consume(']')) break;
      if (!r.Consume(',')) throw std::runtime_error("Bad added_tokens array");
    }
  }

  std::pair<int32_t, int32_t> MatchAdded(const std::string &text,
                                         size_t pos) const {
    int32_t node = 0, best_idx = -1, best_len = 0;
    for (size_t i = pos; i < text.size(); ++i) {
      auto it = trie_[static_cast<size_t>(node)].next.find(
          static_cast<uint8_t>(text[i]));
      if (it == trie_[static_cast<size_t>(node)].next.end()) break;
      node = it->second;
      if (trie_[static_cast<size_t>(node)].token_index >= 0) {
        best_idx = trie_[static_cast<size_t>(node)].token_index;
        best_len = static_cast<int32_t>(i + 1 - pos);
      }
    }
    return {best_len, best_idx};
  }

  static bool SingleWordBoundary(const std::string &text, size_t pos,
                                 size_t end) {
    if (pos > 0) {
      size_t t = pos - 1;
      while (t > 0 && (static_cast<unsigned char>(text[t]) & 0xC0) == 0x80) --t;
      uint32_t cp = 0;
      size_t nb = 0;
      if (Utf8Next(text, &t, &cp, &nb) && IsWordChar(cp)) return false;
    }
    if (end < text.size()) {
      size_t t = end;
      uint32_t cp = 0;
      size_t nb = 0;
      if (Utf8Next(text, &t, &cp, &nb) && IsWordChar(cp)) return false;
    }
    return true;
  }

  void EncodeSegment(const std::string &seg, std::vector<int64_t> *out) {
    for (const auto &piece : SplitByQwen3Pattern(seg)) {
      std::string bl;
      bl.reserve(piece.size() * 2);
      for (unsigned char b : piece) bl.append(byte_to_unicode_[b]);
      for (const auto &bt : Bpe(bl)) {
        auto it = token2id_.find(bt);
        if (it != token2id_.end()) out->push_back(it->second);
      }
    }
  }

  std::vector<std::string> Bpe(const std::string &word) {
    auto cached = bpe_cache_.find(word);
    if (cached != bpe_cache_.end()) return cached->second;
    std::vector<std::string> syms;
    for (size_t i = 0; i < word.size();) {
      size_t t = i;
      uint32_t cp = 0;
      size_t n = 0;
      if (!Utf8Next(word, &t, &cp, &n) || n == 0) {
        syms.push_back(word.substr(i, 1));
        ++i;
      } else {
        syms.push_back(word.substr(i, n));
        i += n;
      }
    }
    while (syms.size() > 1) {
      int32_t best_rank = std::numeric_limits<int32_t>::max();
      int32_t best_pos = -1;
      for (int32_t i = 0; i + 1 < static_cast<int32_t>(syms.size()); ++i) {
        auto it = merges_rank_.find(syms[static_cast<size_t>(i)] + "\t" +
                                    syms[static_cast<size_t>(i + 1)]);
        if (it != merges_rank_.end() && it->second < best_rank) {
          best_rank = it->second;
          best_pos = i;
        }
      }
      if (best_pos < 0) break;
      syms[static_cast<size_t>(best_pos)].append(
          syms[static_cast<size_t>(best_pos + 1)]);
      syms.erase(syms.begin() + best_pos + 1);
    }
    bpe_cache_[word] = syms;
    return syms;
  }

  std::string DecodeRawBytes(const std::string &merged) const {
    std::string out;
    out.reserve(merged.size());
    for (size_t i = 0; i < merged.size();) {
      size_t t = i;
      uint32_t cp = 0;
      size_t n = 0;
      if (!Utf8Next(merged, &t, &cp, &n) || n == 0) {
        out.push_back(merged[i]);
        ++i;
        continue;
      }
      if (cp < 512 && cp_to_byte_[cp] >= 0) {
        out.push_back(
            static_cast<char>(static_cast<uint8_t>(cp_to_byte_[cp])));
      } else {
        out.append(merged, i, n);
      }
      i += n;
    }
    return out;
  }

  std::string byte_to_unicode_[256];
  int16_t cp_to_byte_[512];
  std::unordered_map<std::string, int32_t> token2id_;
  std::unordered_map<std::string, int32_t> merges_rank_;
  std::unordered_map<std::string, std::vector<std::string>> bpe_cache_;
  std::vector<AddedToken> added_tokens_;
  std::vector<TrieNode> trie_;
  std::vector<std::string> id2token_;
  std::unordered_set<int32_t> special_ids_;
  std::vector<uint8_t> penalty_exempt_;
  int64_t eos_id_ = 151645;
  int64_t im_end_id_ = 151645;
  int64_t pad_id_ = 151645;
};

// Safe FunAudioLLM/Fun-ASR artifact cleanup: strips special tags, endofbreak,
// standalone /sil (without corrupting /silicon, /silver, etc.), and >= 8 'F'
// hallucination runs (while keeping 0xFFFF and #FFFFFF intact).
std::string CleanFunASRText(std::string s) {
  for (const char *tag :
       {"<|im_end|>", "<|im_start|>", "<|endoftext|>", "endofbreak"}) {
    const std::string needle(tag);
    size_t pos = 0;
    while ((pos = s.find(needle, pos)) != std::string::npos) {
      s.erase(pos, needle.size());
    }
  }
  {
    size_t pos = 0;
    while ((pos = s.find("/sil", pos)) != std::string::npos) {
      const size_t after = pos + 4;
      if (after < s.size()) {
        const unsigned char c = static_cast<unsigned char>(s[after]);
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
            (c >= '0' && c <= '9')) {
          pos = after;
          continue;
        }
      }
      s.erase(pos, 4);
    }
  }
  for (size_t i = 0; i < s.size();) {
    if (s[i] != 'F') {
      ++i;
      continue;
    }
    size_t j = i + 1;
    while (j < s.size() && s[j] == 'F') ++j;
    if (j - i >= 8) {
      s.erase(i, j - i);
    } else {
      i = j;
    }
  }
  TrimString(&s);
  return s;
}

std::string EscapeJsonString(const std::string &s) {
  std::string out;
  out.reserve(s.size() + 16);
  for (unsigned char c : s) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\b': out += "\\b"; break;
      case '\f': out += "\\f"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (c < 0x20) {
          char hex[8];
          std::snprintf(hex, sizeof(hex), "\\u%04x", static_cast<unsigned>(c));
          out += hex;
        } else {
          out.push_back(static_cast<char>(c));
        }
    }
  }
  return out;
}

class KaldiFbankFrontend {
 public:
  static constexpr int32_t kSampleRate = 16000;
  static constexpr int32_t kWinLen = 400;
  static constexpr int32_t kShift = 160;
  static constexpr int32_t kNfft = 512;
  static constexpr int32_t kNumBins = kNfft / 2 + 1;
  static constexpr int32_t kNumMels = 80;
  static constexpr float kPreemph = 0.97f;

  KaldiFbankFrontend() {
    hamming_.resize(kWinLen);
    const double two_pi = 6.28318530717958647692;
    for (int32_t i = 0; i < kWinLen; ++i) {
      hamming_[static_cast<size_t>(i)] = static_cast<float>(
          0.54 - 0.46 * std::cos(two_pi * i / (kWinLen - 1)));
    }

    bitrev_.resize(kNfft, 0);
    for (int32_t i = 1, j = 0; i < kNfft; ++i) {
      int32_t bit = kNfft >> 1;
      for (; j & bit; bit >>= 1) j ^= bit;
      j ^= bit;
      bitrev_[static_cast<size_t>(i)] = j;
    }

    auto mel = [](float f) -> float {
      return 1127.0f * std::log(1.0f + f / 700.0f);
    };
    const float ml = mel(20.0f);
    const float mh = mel(8000.0f);
    const float dm = (mh - ml) / static_cast<float>(kNumMels + 1);
    const float bin_width = static_cast<float>(kSampleRate) / kNfft;

    mel_bins_.resize(kNumMels);
    for (int32_t m = 0; m < kNumMels; ++m) {
      const float L = ml + m * dm;
      const float C = ml + (m + 1) * dm;
      const float R = ml + (m + 2) * dm;
      MelFilter flt;
      flt.start_bin = kNumBins;
      for (int32_t k = 0; k < kNumBins; ++k) {
        const float mf = mel(bin_width * k);
        if (mf > L && mf < R) {
          float w = (mf <= C) ? ((mf - L) / (C - L)) : ((R - mf) / (R - C));
          if (w > 0.0f) {
            if (flt.weights.empty()) flt.start_bin = k;
            flt.weights.push_back(w);
          }
        }
      }
      mel_bins_[static_cast<size_t>(m)] = std::move(flt);
    }
  }

  // Computes Kaldi 80-d fbank (snip_edges=false) + centered LFR (m, n).
  std::vector<float> ComputeCenteredLfr(const float *samples, int32_t count,
                                        int32_t lfr_m, int32_t lfr_n,
                                        int32_t *out_lfr_frames) const {
    *out_lfr_frames = 0;
    if (count <= 0) return {};
    const int32_t num_frames = (count + kShift / 2) / kShift;
    if (num_frames <= 0) return {};

    std::vector<float> fbank(static_cast<size_t>(num_frames) * kNumMels);
    std::array<float, kWinLen> frame{};
    std::array<float, kNfft> re{};
    std::array<float, kNfft> im{};
    std::array<float, kNumBins> power{};

    auto reflect_index = [count](int32_t idx) -> int32_t {
      if (count == 1) return 0;
      while (idx < 0 || idx >= count) {
        if (idx < 0) idx = -1 - idx;
        if (idx >= count) idx = 2 * count - 1 - idx;
      }
      return idx;
    };

    const double two_pi = 6.28318530717958647692;
    constexpr float kEnergyFloor = 1.1920929e-7f;

    for (int32_t t = 0; t < num_frames; ++t) {
      const int32_t center = t * kShift + kShift / 2;
      const int32_t start = center - kWinLen / 2;
      double mean = 0.0;
      for (int32_t i = 0; i < kWinLen; ++i) {
        int32_t sidx = (start >= 0 && start + kWinLen <= count)
                           ? (start + i)
                           : reflect_index(start + i);
        float v = samples[sidx] * 32768.0f;
        frame[static_cast<size_t>(i)] = v;
        mean += v;
      }
      const float dc = static_cast<float>(mean / kWinLen);
      for (int32_t i = 0; i < kWinLen; ++i) {
        frame[static_cast<size_t>(i)] -= dc;
      }
      for (int32_t i = kWinLen - 1; i > 0; --i) {
        frame[static_cast<size_t>(i)] -=
            kPreemph * frame[static_cast<size_t>(i - 1)];
      }
      frame[0] *= (1.0f - kPreemph);

      re.fill(0.0f);
      im.fill(0.0f);
      for (int32_t i = 0; i < kWinLen; ++i) {
        re[static_cast<size_t>(bitrev_[static_cast<size_t>(i)])] =
            frame[static_cast<size_t>(i)] * hamming_[static_cast<size_t>(i)];
      }

      for (int32_t len = 2; len <= kNfft; len <<= 1) {
        const double ang = -two_pi / len;
        const float wr = static_cast<float>(std::cos(ang));
        const float wi = static_cast<float>(std::sin(ang));
        const int32_t half = len >> 1;
        for (int32_t i = 0; i < kNfft; i += len) {
          float cr = 1.0f, ci = 0.0f;
          for (int32_t k = 0; k < half; ++k) {
            const size_t u_idx = static_cast<size_t>(i + k);
            const size_t v_idx = static_cast<size_t>(i + k + half);
            const float ur = re[u_idx], ui = im[u_idx];
            const float vr = re[v_idx] * cr - im[v_idx] * ci;
            const float vi = re[v_idx] * ci + im[v_idx] * cr;
            re[u_idx] = ur + vr;
            im[u_idx] = ui + vi;
            re[v_idx] = ur - vr;
            im[v_idx] = ui - vi;
            const float next_cr = cr * wr - ci * wi;
            ci = cr * wi + ci * wr;
            cr = next_cr;
          }
        }
      }

      for (int32_t k = 0; k < kNumBins; ++k) {
        const float r = re[static_cast<size_t>(k)];
        const float m = im[static_cast<size_t>(k)];
        power[static_cast<size_t>(k)] = r * r + m * m;
      }

      float *dst = fbank.data() + static_cast<size_t>(t) * kNumMels;
      for (int32_t m = 0; m < kNumMels; ++m) {
        const auto &flt = mel_bins_[static_cast<size_t>(m)];
        float e = 0.0f;
        for (size_t j = 0; j < flt.weights.size(); ++j) {
          e += flt.weights[j] *
               power[static_cast<size_t>(flt.start_bin) + j];
        }
        dst[m] = std::log(std::max(e, kEnergyFloor));
      }
    }

    const int32_t pad_left = (lfr_m - 1) / 2;
    const int32_t t_lfr = (num_frames + lfr_n - 1) / lfr_n;
    if (t_lfr <= 0) return {};

    const int32_t out_dim = lfr_m * kNumMels;
    std::vector<float> lfr(static_cast<size_t>(t_lfr) * out_dim);
    for (int32_t i = 0; i < t_lfr; ++i) {
      float *row = lfr.data() + static_cast<size_t>(i) * out_dim;
      for (int32_t j = 0; j < lfr_m; ++j) {
        int32_t src_t = std::clamp<int32_t>(i * lfr_n + j - pad_left, 0,
                                            num_frames - 1);
        std::memcpy(row + static_cast<size_t>(j) * kNumMels,
                    fbank.data() + static_cast<size_t>(src_t) * kNumMels,
                    kNumMels * sizeof(float));
      }
    }
    *out_lfr_frames = t_lfr;
    return lfr;
  }

 private:
  struct MelFilter {
    int32_t start_bin = 0;
    std::vector<float> weights;
  };
  std::vector<float> hamming_;
  std::vector<int32_t> bitrev_;
  std::vector<MelFilter> mel_bins_;
};

std::string LookupMetaString(const Ort::ModelMetadata &meta, const char *key,
                             OrtAllocator *alloc) {
  auto val = meta.LookupCustomMetadataMapAllocated(key, alloc);
  return val ? std::string(val.get()) : std::string{};
}

int32_t LookupMetaInt(const Ort::ModelMetadata &meta, const char *key,
                      int32_t fallback, OrtAllocator *alloc) {
  std::string s = LookupMetaString(meta, key, alloc);
  if (s.empty()) return fallback;
  return std::atoi(s.c_str());
}

void ReadSessionNames(Ort::Session *sess, std::vector<std::string> *storage,
                      std::vector<const char *> *ptrs, bool inputs) {
  Ort::AllocatorWithDefaultOptions alloc;
  const size_t n = inputs ? sess->GetInputCount() : sess->GetOutputCount();
  storage->resize(n);
  ptrs->resize(n);
  for (size_t i = 0; i < n; ++i) {
    auto name = inputs ? sess->GetInputNameAllocated(i, alloc)
                       : sess->GetOutputNameAllocated(i, alloc);
    (*storage)[i] = name ? name.get() : "";
    (*ptrs)[i] = (*storage)[i].c_str();
  }
}

}  // namespace

struct MoMoFunASRNanoRuntime {
  std::mutex mutex;
  Ort::Env env{ORT_LOGGING_LEVEL_ERROR, "MoMoFunASRNano"};
  Ort::MemoryInfo cpu_mem{
      Ort::MemoryInfo::CreateCpu(OrtDeviceAllocator, OrtMemTypeDefault)};
  Ort::AllocatorWithDefaultOptions allocator;

  std::unique_ptr<Ort::Session> encoder_sess;
  std::unique_ptr<Ort::Session> embedding_sess;
  std::unique_ptr<Ort::Session> llm_sess;

  std::vector<std::string> enc_in_names, enc_out_names;
  std::vector<const char *> enc_in_ptrs, enc_out_ptrs;
  std::vector<std::string> emb_in_names, emb_out_names;
  std::vector<const char *> emb_in_ptrs, emb_out_ptrs;
  std::vector<std::string> llm_in_names, llm_out_names;
  std::vector<const char *> llm_in_ptrs, llm_out_ptrs;

  ONNXTensorElementDataType enc_in_type = ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT;
  ONNXTensorElementDataType kv_type = ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT;
  size_t kv_elem_bytes = 4;

  int32_t lfr_window_size = 7;
  int32_t lfr_window_shift = 6;
  int32_t hidden_size = 1024;
  int32_t vocab_size = 151936;
  int32_t num_layers = 28;
  int32_t max_total_len = 512;
  int64_t kv_heads = 8;
  int64_t head_dim = 128;

  // Pre-allocated KV cache and single-step decode buffers (zero heap churn per step).
  std::vector<std::vector<uint8_t>> cache_k_bytes;
  std::vector<std::vector<uint8_t>> cache_v_bytes;
  std::vector<std::vector<uint8_t>> delta_k_bytes;
  std::vector<std::vector<uint8_t>> delta_v_bytes;
  std::vector<float> decode_logits;
  size_t dirty_kv_len = 0;

  KaldiFbankFrontend frontend;
  std::unique_ptr<Qwen3Tokenizer> tokenizer;
};

MoMoFunASRNanoRuntime *MoMoCreateFunASRNanoRuntime(
    const char *encoder_adaptor_path, const char *llm_path,
    const char *embedding_path, const char *tokenizer_dir,
    int32_t num_threads, char *error, size_t error_capacity) {
  try {
    if (!encoder_adaptor_path || !llm_path || !embedding_path ||
        !tokenizer_dir) {
      throw std::runtime_error("Missing FunASR-Nano model paths");
    }

    auto rt = std::make_unique<MoMoFunASRNanoRuntime>();
    const int32_t threads = std::clamp<int32_t>(num_threads, 1, 4);

    // FunASR-Nano uses DynamicQuantizeLinear + MatMulInteger in both encoder_adaptor
    // and llm. Running directly on ORT CPUExecutionProvider avoids CoreML EP's 362-node
    // graph partitioning, ANE E5RT shape exceptions, and FP16 adaptor overflow.
    auto make_cpu_options = [threads]() {
      Ort::SessionOptions opts;
      opts.SetIntraOpNumThreads(threads);
      opts.SetInterOpNumThreads(1);
      opts.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
      opts.AddConfigEntry("session.intra_op.allow_spinning", "0");
      opts.AddConfigEntry("session.inter_op.allow_spinning", "0");
      return opts;
    };

    auto enc_opts = make_cpu_options();
    auto emb_opts = make_cpu_options();
    auto llm_opts = make_cpu_options();

    rt->encoder_sess = std::make_unique<Ort::Session>(
        rt->env, encoder_adaptor_path, enc_opts);
    rt->embedding_sess =
        std::make_unique<Ort::Session>(rt->env, embedding_path, emb_opts);
    rt->llm_sess = std::make_unique<Ort::Session>(rt->env, llm_path, llm_opts);

    ReadSessionNames(rt->encoder_sess.get(), &rt->enc_in_names,
                     &rt->enc_in_ptrs, true);
    ReadSessionNames(rt->encoder_sess.get(), &rt->enc_out_names,
                     &rt->enc_out_ptrs, false);
    ReadSessionNames(rt->embedding_sess.get(), &rt->emb_in_names,
                     &rt->emb_in_ptrs, true);
    ReadSessionNames(rt->embedding_sess.get(), &rt->emb_out_names,
                     &rt->emb_out_ptrs, false);
    ReadSessionNames(rt->llm_sess.get(), &rt->llm_in_names, &rt->llm_in_ptrs,
                     true);
    ReadSessionNames(rt->llm_sess.get(), &rt->llm_out_names, &rt->llm_out_ptrs,
                     false);

    if (rt->enc_in_ptrs.empty() || rt->enc_out_ptrs.empty() ||
        rt->emb_in_ptrs.empty() || rt->emb_out_ptrs.empty()) {
      throw std::runtime_error("Invalid FunASR-Nano encoder/embedding signature");
    }

    Ort::TypeInfo enc_in_ti = rt->encoder_sess->GetInputTypeInfo(0);
    rt->enc_in_type = enc_in_ti.GetTensorTypeAndShapeInfo().GetElementType();

    Ort::ModelMetadata enc_meta = rt->encoder_sess->GetModelMetadata();
    rt->lfr_window_size =
        LookupMetaInt(enc_meta, "lfr_window_size", 7, rt->allocator);
    rt->lfr_window_shift =
        LookupMetaInt(enc_meta, "lfr_window_shift", 6, rt->allocator);
    rt->hidden_size = LookupMetaInt(enc_meta, "llm_dim", 0, rt->allocator);

    Ort::ModelMetadata llm_meta = rt->llm_sess->GetModelMetadata();
    rt->vocab_size = LookupMetaInt(llm_meta, "vocab_size", 151936, rt->allocator);
    if (rt->hidden_size <= 0) {
      rt->hidden_size =
          LookupMetaInt(llm_meta, "hidden_size", 1024, rt->allocator);
    }

    const int32_t num_llm_outputs =
        static_cast<int32_t>(rt->llm_out_ptrs.size());
    if (num_llm_outputs < 3 || (num_llm_outputs - 1) % 2 != 0) {
      throw std::runtime_error("Unsupported FunASR-Nano LLM output layout");
    }
    rt->num_layers = (num_llm_outputs - 1) / 2;
    if (static_cast<int32_t>(rt->llm_in_ptrs.size()) !=
        3 + 2 * rt->num_layers) {
      throw std::runtime_error("Unsupported FunASR-Nano LLM input layout");
    }

    rt->max_total_len =
        LookupMetaInt(llm_meta, "max_total_len", 0, rt->allocator);
    if (rt->max_total_len <= 0) {
      rt->max_total_len =
          LookupMetaInt(llm_meta, "attention_mask_len", 512, rt->allocator);
    }

    Ort::TypeInfo kv_type_info = rt->llm_sess->GetInputTypeInfo(3);
    auto kv_ti = kv_type_info.GetTensorTypeAndShapeInfo();
    auto kv_shape = kv_ti.GetShape();
    if (kv_shape.size() != 4) {
      throw std::runtime_error("Invalid FunASR-Nano KV cache shape");
    }
    rt->kv_heads = kv_shape[2] > 0
                       ? kv_shape[2]
                       : LookupMetaInt(llm_meta, "num_kv_heads", 8, rt->allocator);
    rt->head_dim = kv_shape[3] > 0
                       ? kv_shape[3]
                       : LookupMetaInt(llm_meta, "head_dim", 128, rt->allocator);
    if (rt->kv_heads <= 0 || rt->head_dim <= 0) {
      throw std::runtime_error("Invalid FunASR-Nano KV cache dimensions");
    }
    rt->kv_type = kv_ti.GetElementType();
    if (rt->kv_type == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
      rt->kv_elem_bytes = 4;
    } else if (rt->kv_type == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16 ||
               rt->kv_type == ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT16) {
      rt->kv_elem_bytes = 2;
    } else {
      throw std::runtime_error("Unsupported FunASR-Nano KV element type");
    }

    const size_t kv_cache_bytes = static_cast<size_t>(rt->max_total_len) *
                                  static_cast<size_t>(rt->kv_heads) *
                                  static_cast<size_t>(rt->head_dim) *
                                  rt->kv_elem_bytes;
    const size_t kv_delta_bytes = static_cast<size_t>(rt->kv_heads) *
                                  static_cast<size_t>(rt->head_dim) *
                                  rt->kv_elem_bytes;

    rt->cache_k_bytes.assign(static_cast<size_t>(rt->num_layers),
                             std::vector<uint8_t>(kv_cache_bytes, 0));
    rt->cache_v_bytes.assign(static_cast<size_t>(rt->num_layers),
                             std::vector<uint8_t>(kv_cache_bytes, 0));
    rt->delta_k_bytes.assign(static_cast<size_t>(rt->num_layers),
                             std::vector<uint8_t>(kv_delta_bytes, 0));
    rt->delta_v_bytes.assign(static_cast<size_t>(rt->num_layers),
                             std::vector<uint8_t>(kv_delta_bytes, 0));
    rt->decode_logits.assign(static_cast<size_t>(rt->vocab_size), 0.0f);

    rt->tokenizer = std::make_unique<Qwen3Tokenizer>(tokenizer_dir);
    return rt.release();
  } catch (const std::exception &e) {
    SaveError(error, error_capacity, e.what());
  } catch (...) {
    SaveError(error, error_capacity, "FunASR-Nano initialization failed");
  }
  return nullptr;
}

void MoMoDestroyFunASRNanoRuntime(MoMoFunASRNanoRuntime *runtime) {
  delete runtime;
}

void MoMoDestroyFunASRNanoResult(MoMoFunASRNanoResult *result) {
  if (!result) return;
  std::free(result->text);
  std::free(result->raw_json);
  delete result;
}

char *MoMoCleanFunASRText(const char *raw_text) {
  try {
    return DupCString(CleanFunASRText(raw_text ? raw_text : ""));
  } catch (...) {
    return nullptr;
  }
}

void MoMoFreeCString(char *str) { std::free(str); }

int MoMoTranscribeFunASRNano(
    MoMoFunASRNanoRuntime *runtime, const float *samples, int32_t sample_count,
    const char *language, int32_t use_itn,
    MoMoCancelCallback is_cancelled, const void *cancel_context,
    MoMoFunASRNanoResult **out_result, char *error, size_t error_capacity) {
  try {
    if (!runtime || !samples || sample_count <= 0 || !out_result) {
      throw std::runtime_error("Invalid FunASR-Nano transcription input");
    }
    *out_result = nullptr;
    CheckCancel(is_cancelled, cancel_context);

    for (int32_t i = 0; i < sample_count; ++i) {
      if (!std::isfinite(samples[i])) {
        throw std::runtime_error("Nonfinite audio sample");
      }
    }

    auto make_empty_result = [&]() {
      auto res = std::make_unique<MoMoFunASRNanoResult>();
      res->text = DupCString("");
      res->raw_json = DupCString(
          "{\"lang\":\"\",\"emotion\":\"\",\"event\":\"\",\"text\":\"\","
          "\"timestamps\":[],\"tokens\":[]}");
      *out_result = res.release();
      return 1;
    };

    // Constant/digital-silence short-circuit (matches sherpa-onnx FunASRNanoAudioIsSilent).
    bool is_constant = true;
    const float s0 = samples[0];
    for (int32_t i = 1; i < sample_count; ++i) {
      if (samples[i] != s0) {
        is_constant = false;
        break;
      }
    }
    if (is_constant) return make_empty_result();

    std::lock_guard<std::mutex> lock(runtime->mutex);
    CheckCancel(is_cancelled, cancel_context);

    int32_t t_lfr = 0;
    std::vector<float> lfr = runtime->frontend.ComputeCenteredLfr(
        samples, sample_count, runtime->lfr_window_size,
        runtime->lfr_window_shift, &t_lfr);
    if (t_lfr <= 0 || lfr.empty()) return make_empty_result();

    CheckCancel(is_cancelled, cancel_context);

    // 1. Run SAN-M Encoder + 2-layer Bidirectional Transformer Adaptor on ORT CPU.
    const int64_t feat_dim =
        static_cast<int64_t>(runtime->lfr_window_size) * 80;
    std::array<int64_t, 3> enc_in_shape{1, static_cast<int64_t>(t_lfr),
                                        feat_dim};
    std::vector<uint16_t> lfr_fp16;
    Ort::Value enc_input{nullptr};
    if (runtime->enc_in_type == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16) {
      lfr_fp16.resize(lfr.size());
      for (size_t i = 0; i < lfr.size(); ++i) {
        lfr_fp16[i] = FloatToHalfBits(lfr[i]);
      }
      enc_input = Ort::Value::CreateTensor(
          runtime->cpu_mem, lfr_fp16.data(),
          lfr_fp16.size() * sizeof(uint16_t), enc_in_shape.data(),
          enc_in_shape.size(), ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16);
    } else {
      enc_input = Ort::Value::CreateTensor<float>(
          runtime->cpu_mem, lfr.data(), lfr.size(), enc_in_shape.data(),
          enc_in_shape.size());
    }

    auto enc_outputs = runtime->encoder_sess->Run(
        Ort::RunOptions{nullptr}, runtime->enc_in_ptrs.data(), &enc_input, 1,
        runtime->enc_out_ptrs.data(), runtime->enc_out_ptrs.size());
    if (enc_outputs.empty() || !enc_outputs[0].IsTensor()) {
      throw std::runtime_error("Empty encoder_adaptor output");
    }

    CheckCancel(is_cancelled, cancel_context);

    auto enc_info = enc_outputs[0].GetTensorTypeAndShapeInfo();
    auto enc_shape = enc_info.GetShape();
    if (enc_shape.size() != 3 || enc_shape[1] <= 0 ||
        enc_shape[2] != runtime->hidden_size) {
      throw std::runtime_error("Unexpected encoder_adaptor output shape");
    }

    const int32_t t_enc = static_cast<int32_t>(enc_shape[1]);
    // Official FunAudioLLM/Fun-ASR-Nano-2512 low-frame-rate pooling query count:
    // Only the first n_aud adaptor positions received training supervision (~2.1 tok/s).
    int32_t ol = 1 + (t_enc - 3 + 2) / 2;
    ol = 1 + (ol - 3 + 2) / 2;
    int32_t n_aud = std::clamp<int32_t>((ol - 1) / 2 + 1, 1, t_enc);

    // 2. Build Qwen3 ChatML prompt + audio placeholder sequence.
    const std::string lang = language ? language : "";
    std::string user_task =
        lang.empty() ? "语音转写" : ("语音转写成" + lang);
    if (use_itn == 0) {
      user_task += "，不进行文本规整";
    }
    user_task += "：";

    const std::string prefix_text =
        "<|im_start|>system\nYou are a helpful assistant.<|im_end|>\n"
        "<|im_start|>user\n" +
        user_task;
    const std::string suffix_text = "<|im_end|>\n<|im_start|>assistant\n";

    const std::vector<int64_t> ids_before =
        runtime->tokenizer->Encode(prefix_text);
    const std::vector<int64_t> ids_after =
        runtime->tokenizer->Encode(suffix_text);

    const int32_t max_audio_slots =
        runtime->max_total_len - static_cast<int32_t>(ids_before.size()) -
        static_cast<int32_t>(ids_after.size()) - 16;
    if (max_audio_slots <= 0) {
      throw std::runtime_error("Prompt exceeds LLM KV capacity");
    }
    const int32_t audio_len = std::min<int32_t>(n_aud, max_audio_slots);

    std::vector<int64_t> source_ids;
    source_ids.reserve(ids_before.size() + static_cast<size_t>(audio_len) +
                       ids_after.size());
    source_ids.insert(source_ids.end(), ids_before.begin(), ids_before.end());
    source_ids.insert(source_ids.end(), static_cast<size_t>(audio_len),
                      runtime->tokenizer->pad_id());
    source_ids.insert(source_ids.end(), ids_after.begin(), ids_after.end());

    const int32_t context_len = static_cast<int32_t>(source_ids.size());
    const int32_t fbank_beg = static_cast<int32_t>(ids_before.size());
    const size_t hidden_u = static_cast<size_t>(runtime->hidden_size);

    std::array<int64_t, 2> src_shape{1, static_cast<int64_t>(context_len)};
    Ort::Value src_ids_tensor = Ort::Value::CreateTensor<int64_t>(
        runtime->cpu_mem, source_ids.data(), source_ids.size(),
        src_shape.data(), src_shape.size());
    auto emb_outputs = runtime->embedding_sess->Run(
        Ort::RunOptions{nullptr}, runtime->emb_in_ptrs.data(), &src_ids_tensor,
        1, runtime->emb_out_ptrs.data(), runtime->emb_out_ptrs.size());
    if (emb_outputs.empty() || !emb_outputs[0].IsTensor()) {
      throw std::runtime_error("Empty embedding output");
    }

    std::vector<float> prefill_embeds(static_cast<size_t>(context_len) *
                                      hidden_u);
    const auto emb_et =
        emb_outputs[0].GetTensorTypeAndShapeInfo().GetElementType();
    if (emb_et == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16) {
      const uint16_t *src = emb_outputs[0].GetTensorData<uint16_t>();
      for (size_t i = 0; i < prefill_embeds.size(); ++i) {
        float v = HalfBitsToFloat(src[i]);
        prefill_embeds[i] = std::isfinite(v) ? v : 0.0f;
      }
    } else {
      const float *src = emb_outputs[0].GetTensorData<float>();
      for (size_t i = 0; i < prefill_embeds.size(); ++i) {
        prefill_embeds[i] = std::isfinite(src[i]) ? src[i] : 0.0f;
      }
    }

    // Splice first audio_len (= n_aud) projected audio queries into prefill_embeds.
    const auto enc_et = enc_info.GetElementType();
    if (enc_et == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16) {
      const uint16_t *enc_ptr = enc_outputs[0].GetTensorData<uint16_t>();
      for (int32_t t = 0; t < audio_len; ++t) {
        const uint16_t *src = enc_ptr + static_cast<size_t>(t) * hidden_u;
        float *dst = prefill_embeds.data() +
                     static_cast<size_t>(fbank_beg + t) * hidden_u;
        for (size_t d = 0; d < hidden_u; ++d) {
          float v = HalfBitsToFloat(src[d]);
          dst[d] = std::isfinite(v) ? v : 0.0f;
        }
      }
    } else {
      const float *enc_ptr = enc_outputs[0].GetTensorData<float>();
      for (int32_t t = 0; t < audio_len; ++t) {
        const float *src = enc_ptr + static_cast<size_t>(t) * hidden_u;
        float *dst = prefill_embeds.data() +
                     static_cast<size_t>(fbank_beg + t) * hidden_u;
        for (size_t d = 0; d < hidden_u; ++d) {
          dst[d] = std::isfinite(src[d]) ? src[d] : 0.0f;
        }
      }
    }

    // 3. Reset pre-allocated KV cache buffers and bind reusable Ort::Value views.
    const std::array<int64_t, 4> kv_cache_shape{
        1, static_cast<int64_t>(runtime->max_total_len), runtime->kv_heads,
        runtime->head_dim};
    const std::array<int64_t, 4> kv_delta_shape{1, 1, runtime->kv_heads,
                                                runtime->head_dim};
    const size_t bytes_per_pos = static_cast<size_t>(runtime->kv_heads) *
                                 static_cast<size_t>(runtime->head_dim) *
                                 runtime->kv_elem_bytes;

    std::vector<Ort::Value> kv_cache_tensors;
    kv_cache_tensors.reserve(static_cast<size_t>(runtime->num_layers) * 2);
    std::vector<Ort::Value> kv_delta_tensors;
    kv_delta_tensors.reserve(static_cast<size_t>(runtime->num_layers) * 2);

    for (size_t l = 0; l < static_cast<size_t>(runtime->num_layers); ++l) {
      const size_t zero_bytes =
          std::min(runtime->cache_k_bytes[l].size(),
                   runtime->dirty_kv_len * bytes_per_pos);
      if (zero_bytes > 0) {
        std::memset(runtime->cache_k_bytes[l].data(), 0, zero_bytes);
        std::memset(runtime->cache_v_bytes[l].data(), 0, zero_bytes);
      }
      kv_cache_tensors.push_back(Ort::Value::CreateTensor(
          runtime->cpu_mem, runtime->cache_k_bytes[l].data(),
          runtime->cache_k_bytes[l].size(), kv_cache_shape.data(),
          kv_cache_shape.size(), runtime->kv_type));
      kv_cache_tensors.push_back(Ort::Value::CreateTensor(
          runtime->cpu_mem, runtime->cache_v_bytes[l].data(),
          runtime->cache_v_bytes[l].size(), kv_cache_shape.data(),
          kv_cache_shape.size(), runtime->kv_type));
      kv_delta_tensors.push_back(Ort::Value::CreateTensor(
          runtime->cpu_mem, runtime->delta_k_bytes[l].data(),
          runtime->delta_k_bytes[l].size(), kv_delta_shape.data(),
          kv_delta_shape.size(), runtime->kv_type));
      kv_delta_tensors.push_back(Ort::Value::CreateTensor(
          runtime->cpu_mem, runtime->delta_v_bytes[l].data(),
          runtime->delta_v_bytes[l].size(), kv_delta_shape.data(),
          kv_delta_shape.size(), runtime->kv_type));
    }
    runtime->dirty_kv_len = static_cast<size_t>(runtime->max_total_len);

    std::array<int64_t, 3> decode_logits_shape{
        1, 1, static_cast<int64_t>(runtime->vocab_size)};
    Ort::Value decode_logits_tensor = Ort::Value::CreateTensor<float>(
        runtime->cpu_mem, runtime->decode_logits.data(),
        runtime->decode_logits.size(), decode_logits_shape.data(),
        decode_logits_shape.size());

    std::vector<int64_t> attention_mask(
        static_cast<size_t>(runtime->max_total_len), 0);
    std::fill(attention_mask.begin(), attention_mask.begin() + context_len, 1);

    std::vector<int64_t> prefill_pos(static_cast<size_t>(context_len));
    for (int32_t i = 0; i < context_len; ++i) {
      prefill_pos[static_cast<size_t>(i)] = i;
    }

    // 4. Autoregressive KV-Delta LLM Generation with Windowed Repetition Penalty + N-gram Guard.
    const float duration_sec = static_cast<float>(sample_count) / 16000.0f;
    const int32_t max_new_tokens = std::clamp<int32_t>(
        static_cast<int32_t>(std::ceil(duration_sec * 9.0f)) + 24, 32, 192);
    constexpr float kRepeatPenalty = 1.12f;
    constexpr size_t kPenaltyWindow = 128;
    constexpr size_t kNoRepeatNgram = 5;

    const int64_t eos_id = runtime->tokenizer->eos_id();
    const int64_t im_end_id = runtime->tokenizer->im_end_id();

    std::vector<int64_t> generated_ids;
    generated_ids.reserve(static_cast<size_t>(max_new_tokens));
    std::vector<float> step_logits(static_cast<size_t>(runtime->vocab_size));
    std::vector<float> next_embed(hidden_u);
    int32_t valid_len = context_len;

    for (int32_t step = 0; step < max_new_tokens; ++step) {
      if (valid_len >= runtime->max_total_len) break;
      CheckCancel(is_cancelled, cancel_context);

      if (step == 0) {
        std::array<int64_t, 3> emb_shape{1, static_cast<int64_t>(context_len),
                                         static_cast<int64_t>(runtime->hidden_size)};
        std::array<int64_t, 2> mask_shape{1, static_cast<int64_t>(context_len)};
        std::array<int64_t, 1> pos_shape{static_cast<int64_t>(context_len)};

        Ort::Value in_emb = Ort::Value::CreateTensor<float>(
            runtime->cpu_mem, prefill_embeds.data(), prefill_embeds.size(),
            emb_shape.data(), emb_shape.size());
        Ort::Value in_mask = Ort::Value::CreateTensor<int64_t>(
            runtime->cpu_mem, attention_mask.data(),
            static_cast<size_t>(context_len), mask_shape.data(),
            mask_shape.size());
        Ort::Value in_pos = Ort::Value::CreateTensor<int64_t>(
            runtime->cpu_mem, prefill_pos.data(), prefill_pos.size(),
            pos_shape.data(), pos_shape.size());

        Ort::IoBinding binding(*runtime->llm_sess);
        binding.BindInput(runtime->llm_in_ptrs[0], in_emb);
        binding.BindInput(runtime->llm_in_ptrs[1], in_mask);
        binding.BindInput(runtime->llm_in_ptrs[2], in_pos);
        for (size_t i = 0; i < kv_cache_tensors.size(); ++i) {
          binding.BindInput(runtime->llm_in_ptrs[3 + i], kv_cache_tensors[i]);
        }
        for (size_t i = 0; i < runtime->llm_out_ptrs.size(); ++i) {
          binding.BindOutput(runtime->llm_out_ptrs[i], runtime->cpu_mem);
        }
        runtime->llm_sess->Run(Ort::RunOptions{nullptr}, binding);
        auto outs = binding.GetOutputValues();
        if (outs.size() != runtime->llm_out_ptrs.size()) {
          throw std::runtime_error("Incomplete LLM prefill outputs");
        }

        const auto log_info = outs[0].GetTensorTypeAndShapeInfo();
        const auto log_shape = log_info.GetShape();
        const int64_t seq_out = log_shape.size() >= 3 ? log_shape[1] : 0;
        const int64_t vocab_out = log_shape.size() >= 3 ? log_shape[2] : 0;
        if (seq_out <= 0 || vocab_out != runtime->vocab_size) {
          throw std::runtime_error("Unexpected LLM prefill logits shape");
        }
        const size_t last_off =
            static_cast<size_t>(seq_out - 1) * static_cast<size_t>(vocab_out);
        if (log_info.GetElementType() == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16) {
          const uint16_t *p = outs[0].GetTensorData<uint16_t>() + last_off;
          ConvertHalfToFloatRaw(p, step_logits.data(), step_logits.size());
        } else {
          const float *p = outs[0].GetTensorData<float>() + last_off;
          std::memcpy(step_logits.data(), p,
                      step_logits.size() * sizeof(float));
        }

        const size_t copy_bytes =
            static_cast<size_t>(context_len) * bytes_per_pos;
        for (size_t l = 0; l < static_cast<size_t>(runtime->num_layers); ++l) {
          std::memcpy(runtime->cache_k_bytes[l].data(),
                      outs[1 + 2 * l].GetTensorData<void>(), copy_bytes);
          std::memcpy(runtime->cache_v_bytes[l].data(),
                      outs[2 + 2 * l].GetTensorData<void>(), copy_bytes);
        }
      } else {
        int64_t last_id = generated_ids.back();
        std::array<int64_t, 2> one_shape{1, 1};
        Ort::Value one_id = Ort::Value::CreateTensor<int64_t>(
            runtime->cpu_mem, &last_id, 1, one_shape.data(), one_shape.size());
        auto next_emb_out = runtime->embedding_sess->Run(
            Ort::RunOptions{nullptr}, runtime->emb_in_ptrs.data(), &one_id, 1,
            runtime->emb_out_ptrs.data(), runtime->emb_out_ptrs.size());
        if (next_emb_out.empty() || !next_emb_out[0].IsTensor()) {
          throw std::runtime_error("Empty decode embedding output");
        }
        if (next_emb_out[0].GetTensorTypeAndShapeInfo().GetElementType() ==
            ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16) {
          const uint16_t *src = next_emb_out[0].GetTensorData<uint16_t>();
          for (size_t d = 0; d < hidden_u; ++d) {
            float v = HalfBitsToFloat(src[d]);
            next_embed[d] = std::isfinite(v) ? v : 0.0f;
          }
        } else {
          const float *src = next_emb_out[0].GetTensorData<float>();
          for (size_t d = 0; d < hidden_u; ++d) {
            next_embed[d] = std::isfinite(src[d]) ? src[d] : 0.0f;
          }
        }

        const int32_t mask_len = valid_len + 1;
        attention_mask[static_cast<size_t>(valid_len)] = 1;
        int64_t cache_pos_val = valid_len;

        std::array<int64_t, 3> emb_shape{
            1, 1, static_cast<int64_t>(runtime->hidden_size)};
        std::array<int64_t, 2> mask_shape{1, static_cast<int64_t>(mask_len)};
        std::array<int64_t, 1> pos_shape{1};

        Ort::Value in_emb = Ort::Value::CreateTensor<float>(
            runtime->cpu_mem, next_embed.data(), next_embed.size(),
            emb_shape.data(), emb_shape.size());
        Ort::Value in_mask = Ort::Value::CreateTensor<int64_t>(
            runtime->cpu_mem, attention_mask.data(),
            static_cast<size_t>(mask_len), mask_shape.data(),
            mask_shape.size());
        Ort::Value in_pos = Ort::Value::CreateTensor<int64_t>(
            runtime->cpu_mem, &cache_pos_val, 1, pos_shape.data(),
            pos_shape.size());

        Ort::IoBinding binding(*runtime->llm_sess);
        binding.BindInput(runtime->llm_in_ptrs[0], in_emb);
        binding.BindInput(runtime->llm_in_ptrs[1], in_mask);
        binding.BindInput(runtime->llm_in_ptrs[2], in_pos);
        for (size_t i = 0; i < kv_cache_tensors.size(); ++i) {
          binding.BindInput(runtime->llm_in_ptrs[3 + i], kv_cache_tensors[i]);
        }
        binding.BindOutput(runtime->llm_out_ptrs[0], decode_logits_tensor);
        for (size_t i = 0; i < kv_delta_tensors.size(); ++i) {
          binding.BindOutput(runtime->llm_out_ptrs[1 + i], kv_delta_tensors[i]);
        }
        runtime->llm_sess->Run(Ort::RunOptions{nullptr}, binding);

        std::memcpy(step_logits.data(), runtime->decode_logits.data(),
                    step_logits.size() * sizeof(float));

        const size_t dst_off = static_cast<size_t>(valid_len) * bytes_per_pos;
        for (size_t l = 0; l < static_cast<size_t>(runtime->num_layers); ++l) {
          std::memcpy(runtime->cache_k_bytes[l].data() + dst_off,
                      runtime->delta_k_bytes[l].data(), bytes_per_pos);
          std::memcpy(runtime->cache_v_bytes[l].data() + dst_off,
                      runtime->delta_v_bytes[l].data(), bytes_per_pos);
        }
        valid_len += 1;
      }

      // Apply llama.cpp-style windowed repetition penalty on non-exempt tokens.
      if (!generated_ids.empty()) {
        const size_t win_start = generated_ids.size() > kPenaltyWindow
                                     ? (generated_ids.size() - kPenaltyWindow)
                                     : 0;
        std::vector<int64_t> recent(generated_ids.begin() + win_start,
                                    generated_ids.end());
        std::sort(recent.begin(), recent.end());
        recent.erase(std::unique(recent.begin(), recent.end()), recent.end());
        for (int64_t tid : recent) {
          if (tid < 0 || tid >= runtime->vocab_size) continue;
          if (runtime->tokenizer->IsPenaltyExempt(tid)) continue;
          float &lv = step_logits[static_cast<size_t>(tid)];
          if (!std::isfinite(lv)) continue;
          lv = (lv > 0.0f) ? (lv / kRepeatPenalty) : (lv * kRepeatPenalty);
        }
      }

      // Apply no_repeat_ngram = 5 in token space (skipping pure digit runs).
      if (generated_ids.size() >= kNoRepeatNgram - 1) {
        const size_t prefix_len = kNoRepeatNgram - 1;
        const int64_t *suffix =
            generated_ids.data() + (generated_ids.size() - prefix_len);
        bool all_exempt = true;
        for (size_t k = 0; k < prefix_len; ++k) {
          if (!runtime->tokenizer->IsPenaltyExempt(suffix[k])) {
            all_exempt = false;
            break;
          }
        }
        if (!all_exempt) {
          for (size_t idx = 0; idx + prefix_len < generated_ids.size(); ++idx) {
            if (std::memcmp(generated_ids.data() + idx, suffix,
                            prefix_len * sizeof(int64_t)) == 0) {
              const int64_t banned = generated_ids[idx + prefix_len];
              if (banned >= 0 && banned < runtime->vocab_size &&
                  banned != eos_id && banned != im_end_id) {
                step_logits[static_cast<size_t>(banned)] = -1e30f;
              }
            }
          }
        }
      }

      int64_t best_id = eos_id;
      float best_val = -1e30f;
      bool found = false;
      for (int32_t v = 0; v < runtime->vocab_size; ++v) {
        const float lv = step_logits[static_cast<size_t>(v)];
        if (std::isfinite(lv) && (!found || lv > best_val)) {
          best_val = lv;
          best_id = v;
          found = true;
        }
      }
      if (!found || best_id == eos_id || best_id == im_end_id) break;
      generated_ids.push_back(best_id);
    }
    runtime->dirty_kv_len =
        std::min<size_t>(static_cast<size_t>(runtime->max_total_len),
                         static_cast<size_t>(valid_len) + 1);

    CheckCancel(is_cancelled, cancel_context);

    const std::string text =
        CleanFunASRText(runtime->tokenizer->Decode(generated_ids));
    const std::string escaped = EscapeJsonString(text);
    const std::string json =
        "{\"lang\":\"\",\"emotion\":\"\",\"event\":\"\",\"text\":\"" + escaped +
        "\",\"timestamps\":[],\"tokens\":[]}";

    auto res = std::make_unique<MoMoFunASRNanoResult>();
    res->text = DupCString(text);
    res->raw_json = DupCString(json);
    *out_result = res.release();
    return 1;
  } catch (const CancelledError &) {
    return -2;
  } catch (const std::exception &e) {
    SaveError(error, error_capacity, e.what());
  } catch (...) {
    SaveError(error, error_capacity, "FunASR-Nano transcription failed");
  }
  return 0;
}

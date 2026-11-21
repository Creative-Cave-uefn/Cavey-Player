// Анализ трека для DJ-режима (ТЗ, раздел 3): доли и даунбиты (нейросеть Beat This!), сетка темпа,
// громкость по EBU R128, истинный пик, тональность, тишина в начале и конце, энергия по тактам,
// границы фраз и точки входа/выхода микса. Результат — JSON профиля v2.
//
// Beat This! (JKU Linz, ISMIR 2024, MIT) работает через ONNX Runtime. Библиотека ONNX Runtime
// подгружается во время работы (LoadLibrary / dlopen) по пути, который передаёт приложение, —
// поэтому для сборки Cavey она не нужна. Конвейер повторяет эталон beat_this (Python) и его порт
// beat-this-rs: моно 22 050 Гц → лог-мел 128 полос, 50 кадров/с (отдельная ONNX-модель, окнами) →
// нейросеть кусками по 1500 кадров с краями по 6 → пики логитов > 0 в окне ±3 кадра → слияние соседних →
// даунбиты притягиваются к ближайшей доле.

#include <algorithm>
#include <chrono>
#include <cmath>
#include <complex>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <numeric>
#include <string>
#include <thread>
#include <vector>

#include "cave_mix.h"
#include "readers.h"
// MinGW (кросс-проверка Windows-сборки): в его specstrings.h нет части аннотаций SAL из MSVC
#if defined(_WIN32) && !defined(_MSC_VER)
#include <specstrings.h>
#ifndef _Frees_ptr_opt_
#define _Frees_ptr_opt_
#endif
#ifndef _Outptr_result_maybenull_
#define _Outptr_result_maybenull_
#endif
#ifndef _Outptr_result_buffer_maybenull_
#define _Outptr_result_buffer_maybenull_(X)
#endif
#ifndef _Inout_updates_all_
#define _Inout_updates_all_(X)
#endif
#ifndef _Out_writes_bytes_all_
#define _Out_writes_bytes_all_(X)
#endif
#ifndef _Out_writes_all_
#define _Out_writes_all_(X)
#endif
#ifndef _Ret_maybenull_
#define _Ret_maybenull_
#endif
#ifndef _Ret_notnull_
#define _Ret_notnull_
#endif
#ifndef _Check_return_
#define _Check_return_
#endif
#ifndef _Success_
#define _Success_(X)
#endif
#ifndef _In_opt_z_
#define _In_opt_z_
#endif
#ifndef _Return_type_success_
#define _Return_type_success_(X)
#endif
#endif
#include "third_party/onnxruntime/onnxruntime_c_api.h"
#include "third_party/rubberband/src/common/Resampler.h"

#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace cm {
namespace an {

constexpr double kPi = 3.14159265358979323846;
constexpr int kModelRate = 22050;
constexpr int kHop = 441;          // 50 кадров в секунду
constexpr int kMels = 128;
constexpr int kMelStride = 1536;   // кадров на окно мел-модели
constexpr int kMelHalo = 64;
constexpr int kChunk = 1500;       // кадров на кусок нейросети
constexpr int kBorder = 6;
constexpr double kFps = 50.0;

// ================================================================ ONNX Runtime

#ifdef _WIN32
static std::wstring widen(const std::string &s) {
  const int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
  std::wstring w((size_t)n, L'\0');
  if (n > 0) MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), &w[0], n);
  return w;
}
#endif

class Ort {
 public:
  ~Ort() {
    if (api_ && env_) api_->ReleaseEnv(env_);
    // библиотеку не выгружаем: ONNX Runtime плохо переносит повторную загрузку в одном процессе
  }

  bool load(const std::string &libPath, std::string &err) {
    using GetBase = const OrtApiBase *(ORT_API_CALL *)();
    GetBase getBase = nullptr;
#ifdef _WIN32
    HMODULE h = LoadLibraryExW(widen(libPath).c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!h) { err = "не удалось загрузить ONNX Runtime: " + libPath; return false; }
    getBase = reinterpret_cast<GetBase>(GetProcAddress(h, "OrtGetApiBase"));
#else
    void *h = dlopen(libPath.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!h) { err = std::string("не удалось загрузить ONNX Runtime: ") + dlerror(); return false; }
    getBase = reinterpret_cast<GetBase>(dlsym(h, "OrtGetApiBase"));
#endif
    if (!getBase) { err = "в библиотеке нет OrtGetApiBase: " + libPath; return false; }
    const OrtApiBase *base = getBase();
    api_ = base ? base->GetApi(ORT_API_VERSION) : nullptr;
    if (!api_) {
      err = std::string("версия ONNX Runtime старее нужной (нужна ≥ 1.") + std::to_string(ORT_API_VERSION) +
            "), есть " + (base ? base->GetVersionString() : "?");
      return false;
    }
    if (!check(api_->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "cave_mix", &env_), err)) return false;
    return true;
  }

  const OrtApi *api() const { return api_; }
  OrtEnv *env() const { return env_; }

  // Статус, который нам не важен (только освободить)
  void eat(OrtStatus *st) const {
    if (st) api_->ReleaseStatus(st);
  }

  bool check(OrtStatus *st, std::string &err) const {
    if (!st) return true;
    err = std::string("ONNX Runtime: ") + api_->GetErrorMessage(st);
    api_->ReleaseStatus(st);
    return false;
  }

 private:
  const OrtApi *api_ = nullptr;
  OrtEnv *env_ = nullptr;
};

struct Tensor {
  std::vector<int64_t> shape;
  std::vector<float> data;
};

class Session {
 public:
  Session(Ort &ort) : ort_(ort) {}
  ~Session() {
    const OrtApi *a = ort_.api();
    if (!a) return;
    if (s_) a->ReleaseSession(s_);
    if (mem_) a->ReleaseMemoryInfo(mem_);
  }

  bool open(const std::string &path, int threads, std::string &err) {
    const OrtApi *a = ort_.api();
    OrtSessionOptions *o = nullptr;
    if (!ort_.check(a->CreateSessionOptions(&o), err)) return false;
    ort_.eat(a->SetIntraOpNumThreads(o, threads));
    ort_.eat(a->SetSessionGraphOptimizationLevel(o, ORT_ENABLE_ALL));
#ifdef _WIN32
    const std::wstring p = widen(path);
    OrtStatus *st = a->CreateSession(ort_.env(), p.c_str(), o, &s_);
#else
    OrtStatus *st = a->CreateSession(ort_.env(), path.c_str(), o, &s_);
#endif
    a->ReleaseSessionOptions(o);
    if (!ort_.check(st, err)) { err += " (" + path + ")"; return false; }
    if (!ort_.check(a->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &mem_), err)) return false;
    // имена входов и выходов берём из модели: разные выгрузки Beat This! называют их по-разному
    OrtAllocator *al = nullptr;
    ort_.eat(a->GetAllocatorWithDefaultOptions(&al));
    size_t n = 0;
    ort_.eat(a->SessionGetInputCount(s_, &n));
    for (size_t i = 0; i < n; ++i) {
      char *nm = nullptr;
      ort_.eat(a->SessionGetInputName(s_, i, al, &nm));
      inputs_.push_back(nm);
      ort_.eat(a->AllocatorFree(al, nm));
    }
    ort_.eat(a->SessionGetOutputCount(s_, &n));
    for (size_t i = 0; i < n; ++i) {
      char *nm = nullptr;
      ort_.eat(a->SessionGetOutputName(s_, i, al, &nm));
      outputs_.push_back(nm);
      ort_.eat(a->AllocatorFree(al, nm));
    }
    if (inputs_.empty() || outputs_.empty()) { err = "у модели нет входа или выхода: " + path; return false; }
    return true;
  }

  const std::vector<std::string> &outputs() const { return outputs_; }

  // Один вход (первый), все выходы
  bool run(const Tensor &in, std::vector<Tensor> &out, std::string &err) {
    const OrtApi *a = ort_.api();
    OrtValue *v = nullptr;
    if (!ort_.check(a->CreateTensorWithDataAsOrtValue(mem_, const_cast<float *>(in.data.data()), in.data.size() * sizeof(float),
                                                      in.shape.data(), in.shape.size(),
                                                      ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &v),
                    err))
      return false;
    const char *inName = inputs_[0].c_str();
    std::vector<const char *> outNames;
    for (auto &s : outputs_) outNames.push_back(s.c_str());
    std::vector<OrtValue *> outs(outputs_.size(), nullptr);
    OrtStatus *st = a->Run(s_, nullptr, &inName, &v, 1, outNames.data(), outNames.size(), outs.data());
    a->ReleaseValue(v);
    if (!ort_.check(st, err)) return false;
    out.clear();
    for (OrtValue *o : outs) {
      Tensor t;
      OrtTensorTypeAndShapeInfo *info = nullptr;
      ort_.eat(a->GetTensorTypeAndShape(o, &info));
      size_t dims = 0;
      ort_.eat(a->GetDimensionsCount(info, &dims));
      t.shape.resize(dims);
      ort_.eat(a->GetDimensions(info, t.shape.data(), dims));
      size_t count = 0;
      ort_.eat(a->GetTensorShapeElementCount(info, &count));
      a->ReleaseTensorTypeAndShapeInfo(info);
      float *p = nullptr;
      ort_.eat(a->GetTensorMutableData(o, reinterpret_cast<void **>(&p)));
      t.data.assign(p, p + count);
      a->ReleaseValue(o);
      out.push_back(std::move(t));
    }
    return true;
  }

 private:
  Ort &ort_;
  OrtSession *s_ = nullptr;
  OrtMemoryInfo *mem_ = nullptr;
  std::vector<std::string> inputs_, outputs_;
};


static void fft(std::vector<std::complex<double>> &a);

// ================================================================ Вокал (Spleeter 2stems, модель «vocals»)
//
// Модель Deezer Spleeter (MIT) в выгрузке sherpa-onnx: на входе модули STFT обоих каналов (44,1 кГц, окно Ханна
// 4096, шаг 1024, без центрирования, первые 1024 полосы) кусками по 512 кадров, на выходе — оценка модулей голоса.
// Нам не нужен сам голос, только где он есть: энергия голоса и всего сигнала по кадрам (~23 мс).
// Звук идёт потоком прямо из декодера — весь трек в памяти на 44,1 кГц не держим.
class VocalTracker {
 public:
  static constexpr int kRate = 44100, kN = 4096, kHop = 1024, kBins = 1024, kPatch = 512;

  bool start(Session *s, int fs) {
    s_ = s;
    if (!s_) return false;
    if (fs != kRate) {
      RubberBand::Resampler::Parameters prm;
      prm.quality = RubberBand::Resampler::FastestTolerable;
      prm.dynamism = RubberBand::Resampler::RatioMostlyFixed;
      prm.initialSampleRate = fs;
      prm.maxBufferSize = 4096;
      rs_ = std::make_unique<RubberBand::Resampler>(prm, 2);
      ratio_ = (double)kRate / fs;
    }
    win_.resize(kN);
    for (int i = 0; i < kN; ++i) win_[(size_t)i] = 0.5 - 0.5 * std::cos(2 * kPi * i / kN);
    patch_.assign((size_t)2 * kPatch * kBins, 0.0f);
    return true;
  }
  bool active() const { return s_ && ok_; }
  const std::string &error() const { return err_; }

  // n стерео-кадров на частоте декодера; end — последний кусок
  void add(const float *st, int n, bool end) {
    if (!active()) return;
    if (!rs_) {
      for (int i = 0; i < n; ++i) { L_.push_back(st[i * 2]); R_.push_back(st[i * 2 + 1]); }
    } else {
      inL_.resize((size_t)std::max(n, 1)); inR_.resize((size_t)std::max(n, 1));
      for (int i = 0; i < n; ++i) { inL_[(size_t)i] = st[i * 2]; inR_[(size_t)i] = st[i * 2 + 1]; }
      const size_t cap = (size_t)(n * ratio_) + 64;
      outL_.resize(cap); outR_.resize(cap);
      const float *in[2] = {inL_.data(), inR_.data()};
      float *out[2] = {outL_.data(), outR_.data()};
      const int got = rs_->resample(out, (int)cap, in, std::max(n, 0), ratio_, end);
      L_.insert(L_.end(), outL_.begin(), outL_.begin() + std::max(got, 0));
      R_.insert(R_.end(), outR_.begin(), outR_.begin() + std::max(got, 0));
    }
    while (L_.size() - pos_ >= (size_t)kN) {
      frame();
      pos_ += kHop;
      if (pos_ > (size_t)kRate * 4) {  // отработанное начало буфера — выбросить
        L_.erase(L_.begin(), L_.begin() + (long)pos_);
        R_.erase(R_.begin(), R_.begin() + (long)pos_);
        pos_ = 0;
      }
    }
    if (end && inPatch_ > 0) runPatch();
  }

  // энергия голоса и всего сигнала по кадрам; время центра кадра i — (i·1024 + 2048) / 44 100
  const std::vector<double> &voice() const { return ve_; }
  const std::vector<double> &total() const { return te_; }

 private:
  void frame() {
    std::vector<std::complex<double>> z((size_t)kN);
    for (int i = 0; i < kN; ++i)
      z[(size_t)i] = {L_[pos_ + (size_t)i] * win_[(size_t)i], R_[pos_ + (size_t)i] * win_[(size_t)i]};
    fft(z);  // два вещественных канала одним БПФ: z = L + iR
    for (int k = 0; k < kBins; ++k) {
      const auto a = z[(size_t)k], b = std::conj(z[(size_t)((kN - k) % kN)]);
      const auto l = (a + b) * 0.5, r = (a - b) * std::complex<double>(0, -0.5);
      patch_[(size_t)inPatch_ * kBins + (size_t)k] = (float)std::abs(l);
      patch_[(size_t)kPatch * kBins + (size_t)inPatch_ * kBins + (size_t)k] = (float)std::abs(r);
    }
    if (++inPatch_ == kPatch) runPatch();
  }

  void runPatch() {
    Tensor in;
    in.shape = {2, 1, kPatch, kBins};
    in.data = patch_;
    std::vector<Tensor> out;
    if (!s_->run(in, out, err_) || out.empty() || out[0].data.size() != patch_.size()) {
      if (err_.empty()) err_ = "модель вокала вернула не то";
      ok_ = false;
      return;
    }
    const float *v = out[0].data.data();
    for (int f = 0; f < inPatch_; ++f) {
      double ve = 0, te = 0;
      for (int c = 0; c < 2; ++c) {
        const size_t o = (size_t)c * kPatch * kBins + (size_t)f * kBins;
        for (int k = 0; k < kBins; ++k) {
          const double m = patch_[o + (size_t)k], vv = std::min<double>(v[o + (size_t)k], m);
          ve += vv * vv;
          te += m * m;
        }
      }
      ve_.push_back(ve);
      te_.push_back(te);
    }
    std::fill(patch_.begin(), patch_.end(), 0.0f);
    inPatch_ = 0;
  }

  Session *s_ = nullptr;
  bool ok_ = true;
  std::string err_;
  std::unique_ptr<RubberBand::Resampler> rs_;
  double ratio_ = 1;
  std::vector<double> win_;
  std::vector<float> L_, R_, inL_, inR_, outL_, outR_, patch_;
  size_t pos_ = 0;
  int inPatch_ = 0;
  std::vector<double> ve_, te_;
};

// Доля голоса в каждом такте: кадр «с голосом», если голос — больше 40 % энергии кадра и не тише 12 дБ
// от громких мест трека (так тихая подтечка инструментов в «голос» не считается)
static std::vector<double> vocalsPerBar(const VocalTracker &vt, double t0, double barLen, size_t nBars) {
  const auto &ve = vt.voice(), &te = vt.total();
  std::vector<double> out(nBars, 0.0);
  if (ve.empty() || nBars == 0) return out;
  std::vector<double> db;
  for (double t : te) if (t > 0) db.push_back(10 * std::log10(t));
  if (db.empty()) return out;
  std::nth_element(db.begin(), db.begin() + (long)(db.size() * 9 / 10), db.end());
  const double ref = db[db.size() * 9 / 10];
  std::vector<int> on(nBars, 0), all(nBars, 0);
  for (size_t i = 0; i < ve.size(); ++i) {
    const double tc = ((double)i * VocalTracker::kHop + VocalTracker::kN / 2) / VocalTracker::kRate;
    const double bt = (tc - t0) / barLen;
    if (bt < 0) continue;
    const size_t bi = (size_t)bt;
    if (bi >= nBars) break;
    ++all[bi];
    if (te[i] > 0 && ve[i] / te[i] > 0.4 && 10 * std::log10(ve[i] + 1e-30) > ref - 12) ++on[bi];
  }
  for (size_t b = 0; b < nBars; ++b) out[b] = all[b] ? (double)on[b] / all[b] : 0.0;
  return out;
}

// ================================================================ Beat This!

// Лог-мел спектрограмма окнами (как mel.rs в beat-this-rs): каждое окно с «ореолом» в 64 кадра,
// поэтому склейка окон совпадает с расчётом по всему треку сразу
static bool melSpectrogram(Session &mel, const std::vector<float> &x, std::vector<float> &frames, std::string &err) {
  const size_t n = x.size();
  const size_t total = 1 + n / kHop;
  frames.clear();
  frames.reserve(total * kMels);
  for (size_t k = 0;; ++k) {
    const size_t o = k * kMelStride >= (size_t)kMelHalo ? k * kMelStride - kMelHalo : 0;
    const size_t interiorEnd = (size_t)kHop * ((k + 1) * kMelStride + kMelHalo - 1);
    const bool interior = interiorEnd <= n;
    const size_t start = (size_t)kHop * o, end = interior ? interiorEnd : n;
    const size_t expect = interior ? (k + 1) * kMelStride + kMelHalo - o : total - o;
    const size_t keepA = k * kMelStride - o, keepB = interior ? (k + 1) * kMelStride - o : total - o;
    Tensor in;
    in.shape = {1, (int64_t)(end - start)};
    in.data.assign(x.begin() + (long)start, x.begin() + (long)end);
    std::vector<Tensor> out;
    if (!mel.run(in, out, err)) return false;
    const Tensor &m = out[0];
    if (m.shape.size() != 3 || m.shape[2] != kMels || (size_t)m.shape[1] != expect) {
      err = "мел-модель вернула неожиданную форму";
      return false;
    }
    frames.insert(frames.end(), m.data.begin() + (long)(keepA * kMels), m.data.begin() + (long)(keepB * kMels));
    if (!interior) break;
  }
  return true;
}

// Нейросеть кусками по 1500 кадров с краями по 6 (как inference.rs)
static bool beatLogits(Session &net, const std::vector<float> &mel, std::vector<float> &beat, std::vector<float> &down,
                       std::string &err) {
  const int T = (int)(mel.size() / kMels);
  const int stride = kChunk - 2 * kBorder;
  std::vector<int> starts;
  for (int pos = -kBorder; pos < T - kBorder; pos += stride) starts.push_back(pos);
  if (T > stride && !starts.empty()) starts.back() = T - (kChunk - kBorder);
  beat.assign((size_t)T, -1000.0f);
  down.assign((size_t)T, -1000.0f);
  // какие выходы — доли, какие — даунбиты
  int bi = 0, di = 1;
  const auto &names = net.outputs();
  for (int i = 0; i < (int)names.size(); ++i) {
    std::string n = names[(size_t)i];
    std::transform(n.begin(), n.end(), n.begin(), ::tolower);
    if (n.find("down") != std::string::npos) di = i; else bi = i;
  }
  if (names.size() < 2 || bi == di) { err = "у модели Beat This! должно быть два выхода: доли и даунбиты"; return false; }

  for (auto it = starts.rbegin(); it != starts.rend(); ++it) {
    const int start = *it;
    const int a = std::max(start, 0), b = std::min(start + kChunk, T);
    const int padL = std::max(-start, 0);
    const int padR = std::max(0, std::min(start + kChunk - T, kBorder));
    const int len = padL + (b - a) + padR;
    Tensor in;
    in.shape = {1, len, kMels};
    in.data.assign((size_t)len * kMels, 0.0f);
    for (int t = a; t < b; ++t)
      std::memcpy(&in.data[(size_t)(padL + t - a) * kMels], &mel[(size_t)t * kMels], sizeof(float) * kMels);
    std::vector<Tensor> out;
    if (!net.run(in, out, err)) return false;
    const auto &ob = out[(size_t)bi].data, &od = out[(size_t)di].data;
    if ((int)ob.size() != len || (int)od.size() != len) { err = "нейросеть вернула неожиданную длину"; return false; }
    for (int i = kBorder; i < len - kBorder; ++i) {
      const int dest = start + i;
      if (dest >= 0 && dest < T) { beat[(size_t)dest] = ob[(size_t)i]; down[(size_t)dest] = od[(size_t)i]; }
    }
  }
  return true;
}

// Пики логитов > 0, максимум в окне ±3 кадра, слияние соседних (как postprocessing.rs)
static std::vector<double> peaks(const std::vector<float> &l) {
  std::vector<size_t> p;
  const size_t n = l.size();
  for (size_t i = 0; i < n; ++i) {
    if (l[i] <= 0) continue;
    const size_t a = i >= 3 ? i - 3 : 0, b = std::min(i + 4, n);
    bool mx = true;
    for (size_t j = a; j < b; ++j)
      if (l[j] > l[i]) { mx = false; break; }
    if (mx) p.push_back(i);
  }
  std::vector<double> r;
  if (p.empty()) return r;
  double cur = (double)p[0], c = 1;
  for (size_t k = 1; k < p.size(); ++k) {
    const double q = (double)p[k];
    if (q - cur <= 1.0) { c += 1; cur += (q - cur) / c; }
    else { r.push_back(cur); cur = q; c = 1; }
  }
  r.push_back(cur);
  for (auto &x : r) x /= kFps;
  return r;
}

static void snapDownbeats(const std::vector<double> &beats, std::vector<double> &down) {
  if (beats.empty() || down.empty()) return;
  for (auto &d : down) {
    const auto it = std::lower_bound(beats.begin(), beats.end(), d);
    if (it == beats.begin()) d = *it;
    else if (it == beats.end()) d = beats.back();
    else d = (std::abs(d - *(it - 1)) <= std::abs(*it - d)) ? *(it - 1) : *it;
  }
  std::sort(down.begin(), down.end());
  down.erase(std::unique(down.begin(), down.end()), down.end());
}

// ================================================================ сетка темпа

struct Grid {
  bool ok = false;
  double period = 0;     // секунд на долю
  double firstBeat = 0;  // время первой доли сетки (≥ 0)
  double residualMs = 0; // СКО отклонения долей от сетки
  bool variable = false;
  double maxLocalDevPct = 0;  // самое сильное отклонение местного темпа от общего, %
};

// Ровная сетка по долям, устойчивая к лишним ударам (нейросеть иногда отмечает восьмые) и пропускам:
// 1) период — кластер интервалов, покрывающий больше всего времени; 2) фаза — круговое среднее;
// 3) МНК t = t0 + p·k в окне, которое удваивается (10, 20, 40… с): номер доли каждый раз считается заново от t0,
//    поэтому ошибка не копится; удары дальше четверти доли от сетки (восьмые, сбои) в подгонку не идут.
static Grid fitGrid(const std::vector<double> &b) {
  Grid g;
  if (b.size() < 8) return g;
  std::vector<double> ibi;
  for (size_t i = 1; i < b.size(); ++i) ibi.push_back(b[i] - b[i - 1]);
  // 1. период
  double bestSupport = 0, p = 0;
  for (double c = 0.25; c <= 1.5; c += 0.005) {
    double sup = 0;
    for (double x : ibi) if (std::abs(x - c) <= 0.08 * c) sup += x;
    if (sup > bestSupport) { bestSupport = sup; p = c; }
  }
  if (p <= 0) return g;
  {
    std::vector<double> close_;
    for (double x : ibi) if (std::abs(x - p) <= 0.08 * p) close_.push_back(x);
    std::nth_element(close_.begin(), close_.begin() + (long)close_.size() / 2, close_.end());
    p = close_[close_.size() / 2];
  }
  // 2. затравка: самая длинная по времени цепочка ударов с шагом ≈ p. Восьмые/сбои идут кусками,
  //    а настоящие доли тянутся через весь трек — по цепочке и берём фазу и уточняем период.
  const size_t B = b.size();
  std::vector<int> nxt(B, -1);
  std::vector<double> span(B, 0);
  for (size_t i = 0; i < B; ++i) {
    double best = 0.08 * p;
    for (size_t j = i + 1; j < B && b[j] - b[i] < 1.1 * p; ++j) {
      const double d = std::abs(b[j] - b[i] - p);
      if (d < best) { best = d; nxt[i] = (int)j; }
    }
  }
  for (size_t ii = B; ii-- > 0;) span[ii] = nxt[ii] < 0 ? 0 : (b[nxt[ii]] - b[ii]) + span[nxt[ii]];
  size_t s0 = 0;
  for (size_t i = 1; i < B; ++i) if (span[i] > span[s0]) s0 = i;
  double t0 = b[s0];
  {
    double N = 0, sk = 0, st = 0, skk = 0, skt = 0, k = 0;
    for (int i = (int)s0; i >= 0; i = nxt[i]) {
      N += 1; sk += k; st += b[i]; skk += k * k; skt += k * b[i];
      k += 1;  // шаг цепочки — ровно одна доля
    }
    const double den = N * skk - sk * sk;
    if (N >= 8 && std::abs(den) > 1e-9) { p = (N * skt - sk * st) / den; t0 = (st - p * sk) / N; }
  }
  // 3. по всему треку: номер доли от t0, МНК по ударам у сетки, допуск сужается
  std::vector<char> use(B, 0);
  auto refine = [&](int from) -> bool {
    for (int iter = from; iter < 8; ++iter) {
      const double tol = iter < 3 ? 0.25 * p : (iter < 5 ? std::min(0.07, 0.2 * p) : std::min(0.04, 0.15 * p));
      double N = 0, sk = 0, st = 0, skk = 0, skt = 0;
      for (size_t i = 0; i < B; ++i) {
        const double k = std::round((b[i] - t0) / p);
        use[i] = std::abs(b[i] - (t0 + p * k)) < tol;
        if (!use[i]) continue;
        N += 1; sk += k; st += b[i]; skk += k * k; skt += k * b[i];
      }
      const double den = N * skk - sk * sk;
      if (N < 8 || std::abs(den) < 1e-9) return false;
      const double np = (N * skt - sk * st) / den;
      if (np <= 0.2 || np > 1.6) return false;
      t0 = (st - np * sk) / N; p = np;
    }
    return true;
  };
  if (!refine(0)) return g;
  // 4. На долях или на слабых долях? Где хэт стоит между бочками, нейросеть кусками отмечает и восьмые, и цепочка
  //    могла пройти по ним. Настоящие доли отмечены по всему треку, восьмые — местами: побеждает сетка, на которую
  //    ложится больше ударов. Сдвиг на полдоли — и подгонка заново.
  {
    auto onGridAt = [&](double off) {
      int c = 0;
      for (double t : b) {
        const double r = t - (t0 + off) - p * std::round((t - t0 - off) / p);
        if (std::abs(r) < 0.12 * p) ++c;
      }
      return c;
    };
    const int on = onGridAt(0), half = onGridAt(0.5 * p);
    if (half > on * 1.15) {
      t0 += 0.5 * p;
      if (!refine(3)) return g;
    }
  }
  // итог
  double ss = 0, cnt = 0, onGrid = 0;
  for (size_t i = 0; i < b.size(); ++i) {
    const double r = b[i] - (t0 + p * std::round((b[i] - t0) / p));
    if (std::abs(r) < 0.25 * p) onGrid += 1;
    if (use[i]) { ss += r * r; cnt += 1; }
  }
  if (cnt < 8) return g;
  g.residualMs = std::sqrt(ss / cnt) * 1000;
  g.period = p;
  g.firstBeat = t0 - std::floor(t0 / p) * p;
  // плавающий темп: доли заметно расходятся с ровной сеткой или многие удары у сетки в неё не легли
  g.variable = g.residualMs > 20.0 || cnt < 0.8 * onGrid;
  // Смена темпа по ходу трека (живой барабанщик, запись сета, замедление в конце): сетка одна на весь трек,
  // и там, где темп другой, удары просто «выпадают» из подгонки — по остаткам этого не видно. Поэтому
  // смотрим местный темп окнами по 16 долей: шаг цепочки соседних ударов, каждый интервал округлён до целых долей.
  g.maxLocalDevPct = 0;
  for (size_t i = 0; i + 1 < b.size(); i += 8) {
    double K = 0;
    size_t last = i;
    int kept = 0, skipped = 0;
    for (size_t j = i + 1; j < b.size() && K < 16; ++j) {
      const double r = (b[j] - b[last]) / p;
      const double k = std::round(r);
      if (k > 2.5) break;                                            // пропуск — окно кончилось
      if (k < 1 || std::abs(r - k) > 0.2) { ++skipped; continue; }  // восьмая или сбой — мимо
      K += k; last = j; ++kept;
    }
    if (K < 12 || skipped > kept) continue;
    const double local = (b[last] - b[i]) / K;
    g.maxLocalDevPct = std::max(g.maxLocalDevPct, std::abs(local / p - 1) * 100);
  }
  if (g.maxLocalDevPct > 1.5) g.variable = true;
  g.ok = true;
  return g;
}

// Уточнение фазы сетки по атакам. Beat This! даёт доли с шагом кадра 20 мс, и его сдвиг относительно настоящих
// ударов от трека к треку разный (на тестах от −17 до +10 мс): у двух треков в переходе это и есть «доли не совпадают».
// Поэтому фаза берётся по самим ударам: у каждой доли сетки — самая резкая атака в окне ±40 мс (подъём огибающей
// за 2 мс, в децибелах), и сетка сдвигается на медиану этих отклонений. Порога «стоит ли сдвигать» нет: одинаковое
// правило для всех треков важнее, чем точность любого из них. Мало атак (тихая, без ударных музыка) — сдвиг 0.
// Уточнение сетки по атакам звука: g сдвигается (и, если атак много и они ровные, чуть меняется период). Возвращает
// сдвиг в середине участка, с.
static double refinePhase(const std::vector<float> &x, int fs, Grid &g, double duration, double *gainOut,
                          double from = 0, double to = 1e18) {
  const size_t n = x.size();
  if (n < (size_t)fs) { *gainOut = 0; return 0; }
  // огибающая: |x| в окне 1 мс (скользящая сумма), в log10
  const int w = std::max(1, fs / 1000);
  std::vector<float> le(n);
  double acc = 0;
  for (size_t i = 0; i < n; ++i) {
    acc += std::abs(x[i]);
    if (i >= (size_t)w) acc -= std::abs(x[i - (size_t)w]);
    le[i] = (float)std::log10(acc / w + 1e-6);
  }
  // подъём за 2 мс вокруг точки; окно огибающей запаздывает на полмиллисекунды — учтено в позиции
  const int h = std::max(1, fs / 1000);
  auto rise = [&](size_t i) { return (double)le[std::min(n - 1, i + (size_t)h)] - le[i >= (size_t)h ? i - (size_t)h : 0]; };
  const int span = (int)(0.040 * fs);
  std::vector<double> offs, times;
  int beats = 0;
  for (double t = g.firstBeat; t < std::min(duration, to) - 0.05; t += g.period) {
    if (t < from) continue;
    const long c = std::lround(t * fs);
    if (c - span < 0 || c + span >= (long)n) continue;
    ++beats;
    double best = 0;
    long at = -1;
    for (long i = c - span; i <= c + span; ++i) {
      const double r = rise((size_t)i);
      if (r > best) { best = r; at = i; }
    }
    if (best >= 0.5 && at >= 0) {  // 0,5 — подъём в 10 дБ за 2 мс
      offs.push_back((double)(at - w / 2) / fs - t);
      times.push_back(t);
    }
  }
  *gainOut = beats ? (double)offs.size() / beats : 0;
  if (offs.size() < 16 || offs.size() < 0.3 * beats) return 0;
  std::vector<double> tmp = offs;
  std::nth_element(tmp.begin(), tmp.begin() + (long)tmp.size() / 2, tmp.end());
  double a = std::clamp(tmp[tmp.size() / 2], -0.040, 0.040), b = 0;
  // Наклон: атаки, отстающие от сетки всё больше к концу трека, — период чуть неточен (на 0,02 % — это уже 20 мс
  // за 100 с). Прямая по атакам рядом с прямой (±6 мс), несколько проходов.
  double tc = 0;
  for (double t : times) tc += t;
  tc /= (double)times.size();
  const double spanT = times.back() - times.front();
  if (offs.size() >= 32 && spanT >= 30) {
    for (int it = 0; it < 4; ++it) {
      double n = 0, sx = 0, sy = 0, sxx = 0, sxy = 0;
      for (size_t i = 0; i < offs.size(); ++i) {
        const double xx = times[i] - tc, yy = offs[i];
        if (std::abs(yy - (a + b * xx)) > (it == 0 ? 0.015 : 0.006)) continue;
        n += 1; sx += xx; sy += yy; sxx += xx * xx; sxy += xx * yy;
      }
      if (n < 24 || n < 0.4 * (double)offs.size()) { b = 0; break; }
      const double den = n * sxx - sx * sx;
      if (den <= 0) { b = 0; break; }
      b = (n * sxy - sx * sy) / den;
      a = (sy - b * sx) / n;
    }
    if (std::getenv("CM_ANALYSIS_PROFILE")) std::fprintf(stderr, "  refine: %zu attacks, shift %.2f ms, slope %.5f%%\n", offs.size(), a * 1000, b * 100);
    if (std::abs(b) > 0.002) b = 0;  // больше 0,2 % — это уже не уточнение, сетка не та
    a = std::clamp(a, -0.040, 0.040);
  }
  // новая сетка: в точке t сдвиг a + b·(t − tc)
  g.firstBeat += a - b * tc + b * g.firstBeat;
  g.period *= 1 + b;
  return a;
}

// ================================================================ громкость EBU R128

struct KWeight {
  double b[2][3], a[2][3];
  double z[2][2][2] = {};  // [ступень][канал][2]
  void setup(double fs) {
    // формулы как в libebur128 (ITU-R BS.1770-4 для любой частоты)
    double f0 = 1681.974450955533, G = 3.999843853973347, Q = 0.7071752369554196;
    double K = std::tan(kPi * f0 / fs), Vh = std::pow(10.0, G / 20.0), Vb = std::pow(Vh, 0.4996667741545416);
    double a0 = 1.0 + K / Q + K * K;
    b[0][0] = (Vh + Vb * K / Q + K * K) / a0; b[0][1] = 2.0 * (K * K - Vh) / a0; b[0][2] = (Vh - Vb * K / Q + K * K) / a0;
    a[0][0] = 1; a[0][1] = 2.0 * (K * K - 1.0) / a0; a[0][2] = (1.0 - K / Q + K * K) / a0;
    f0 = 38.13547087602444; Q = 0.5003270373238773; K = std::tan(kPi * f0 / fs);
    b[1][0] = 1; b[1][1] = -2; b[1][2] = 1;
    a[1][0] = 1; a[1][1] = 2.0 * (K * K - 1.0) / (1.0 + K / Q + K * K); a[1][2] = (1.0 - K / Q + K * K) / (1.0 + K / Q + K * K);
  }
  inline double tick(int ch, double x) {
    for (int s = 0; s < 2; ++s) {
      const double y = b[s][0] * x + z[s][ch][0];
      z[s][ch][0] = b[s][1] * x - a[s][1] * y + z[s][ch][1];
      z[s][ch][1] = b[s][2] * x - a[s][2] * y;
      x = y;
    }
    return x;
  }
};

// Интегральная громкость: блоки 400 мс с шагом 100 мс, абсолютный порог −70, относительный −10 LU
class Loudness {
 public:
  void setup(int fs) {
    fs_ = fs;
    kw_.setup(fs);
    step_ = fs / 10;
    sub_.clear();
    acc_ = 0;
    accN_ = 0;
  }
  void add(const float *st, int frames) {
    for (int i = 0; i < frames; ++i) {
      const double l = kw_.tick(0, st[i * 2]), r = kw_.tick(1, st[i * 2 + 1]);
      acc_ += l * l + r * r;
      if (++accN_ == step_) { sub_.push_back(acc_ / step_); acc_ = 0; accN_ = 0; }
    }
  }
  double integrated() const {
    std::vector<double> blocks;
    for (size_t i = 3; i < sub_.size(); ++i) blocks.push_back((sub_[i] + sub_[i - 1] + sub_[i - 2] + sub_[i - 3]) / 4);
    auto lufs = [](double ms) { return -0.691 + 10.0 * std::log10(std::max(ms, 1e-20)); };
    double s = 0; int n = 0;
    for (double m : blocks) if (lufs(m) > -70.0) { s += m; ++n; }
    if (n == 0) return -70.0;
    const double rel = lufs(s / n) - 10.0;
    s = 0; n = 0;
    for (double m : blocks) if (lufs(m) > -70.0 && lufs(m) > rel) { s += m; ++n; }
    return n ? lufs(s / n) : -70.0;
  }

 private:
  int fs_ = 48000, step_ = 4800, accN_ = 0;
  KWeight kw_;
  std::vector<double> sub_;
  double acc_ = 0;
};

// Истинный пик: 4-кратная передискретизация оконным sinc (48 отводов)
class TruePeak {
 public:
  TruePeak() {
    const int taps = 48, phases = 4;
    h_.assign((size_t)taps * phases, 0.0);
    const int L = taps * phases;
    for (int n = 0; n < L; ++n) {
      const double t = (n - (L - 1) / 2.0) / phases;
      const double sinc = std::abs(t) < 1e-9 ? 1.0 : std::sin(kPi * t) / (kPi * t);
      const double w = 0.5 - 0.5 * std::cos(2 * kPi * (n + 0.5) / L);  // Ханн
      h_[(size_t)n] = sinc * w;
    }
    hist_[0].assign(taps, 0.0);
    hist_[1].assign(taps, 0.0);
  }
  void add(const float *st, int frames) {
    const int taps = 48, phases = 4;
    for (int i = 0; i < frames; ++i) {
      for (int ch = 0; ch < 2; ++ch) {
        auto &hh = hist_[ch];
        hh[(size_t)pos_] = st[i * 2 + ch];
        peak_ = std::max(peak_, (double)std::abs(st[i * 2 + ch]));
        for (int ph = 0; ph < phases; ++ph) {
          double y = 0;
          for (int k = 0; k < taps; ++k) y += h_[(size_t)(k * phases + ph)] * hh[(size_t)((pos_ - k + taps) % taps)];
          peak_ = std::max(peak_, std::abs(y));
        }
      }
      pos_ = (pos_ + 1) % taps;
    }
  }
  double dbtp() const { return 20.0 * std::log10(std::max(peak_, 1e-12)); }

 private:
  std::vector<double> h_;
  std::vector<double> hist_[2];
  int pos_ = 0;
  double peak_ = 0;
};

// ================================================================ БПФ и тональность

static void fft(std::vector<std::complex<double>> &a) {
  const size_t n = a.size();
  for (size_t i = 1, j = 0; i < n; ++i) {
    size_t bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) std::swap(a[i], a[j]);
  }
  for (size_t len = 2; len <= n; len <<= 1) {
    const double ang = -2 * kPi / (double)len;
    const std::complex<double> wl(std::cos(ang), std::sin(ang));
    for (size_t i = 0; i < n; i += len) {
      std::complex<double> w(1);
      for (size_t j = 0; j < len / 2; ++j) {
        const auto u = a[i + j], v = a[i + j + len / 2] * w;
        a[i + j] = u + v;
        a[i + j + len / 2] = u - v;
        w *= wl;
      }
    }
  }
}

// Хромаграмма по «высотной значимости» (моно 22 050 Гц, БПФ 8192, шаг 4096): для каждой ноты MIDI 36…95
// складываются амплитуды её первых 4 гармоник с весами 1, 0,8, 0,64, 0,51. Так энергия обертонов
// (в первую очередь третьей гармоники — квинты) приписывается основному тону, а не тянет тональность в доминанту.
static std::vector<double> chroma(const std::vector<float> &x, int fs, std::vector<std::vector<double>> *perFrame = nullptr,
                                  int hop = 4096) {
  const int N = 8192;
  std::vector<double> win((size_t)N);
  for (int i = 0; i < N; ++i) win[(size_t)i] = 0.5 - 0.5 * std::cos(2 * kPi * i / N);
  // для каждой ноты и гармоники — диапазон бинов ±1/3 полутона
  struct Band { int a, b; double w; };
  std::vector<std::vector<Band>> bands(60);
  for (int p = 0; p < 60; ++p) {
    const double f = 440.0 * std::pow(2.0, (p + 36 - 69) / 12.0);
    for (int h = 1; h <= 4; ++h) {
      const double fh = f * h;
      if (fh > fs * 0.45) break;
      const double lo = fh * std::pow(2.0, -1.0 / 36), hi = fh * std::pow(2.0, 1.0 / 36);
      int a = (int)std::ceil(lo * N / fs), b = (int)std::floor(hi * N / fs);
      if (b < a) a = b = (int)std::lround(fh * N / fs);
      bands[(size_t)p].push_back({a, b, std::pow(0.8, h - 1)});
    }
  }
  std::vector<double> total(12, 0.0), mag((size_t)N / 2);
  std::vector<std::complex<double>> buf((size_t)N);
  for (size_t start = 0; start + N <= x.size(); start += (size_t)hop) {
    double e = 0;
    for (int i = 0; i < N; ++i) {
      const double v = x[start + (size_t)i] * win[(size_t)i];
      buf[(size_t)i] = v;
      e += v * v;
    }
    std::vector<double> c(12, 0.0);
    if (e > 1e-6) {
      fft(buf);
      for (int k = 0; k < N / 2; ++k) mag[(size_t)k] = std::abs(buf[(size_t)k]) * (2.0 / N);
      for (int p = 0; p < 60; ++p) {
        double sal = 0;
        for (const Band &bd : bands[(size_t)p]) {
          double m = 0;
          for (int k = bd.a; k <= bd.b; ++k) m = std::max(m, mag[(size_t)k]);
          sal += bd.w * m;
        }
        c[(size_t)((p + 36) % 12)] += sal;
      }
      for (int i = 0; i < 12; ++i) total[(size_t)i] += c[(size_t)i];
    }
    if (perFrame) perFrame->push_back(c);
  }
  return total;
}

struct Key {
  std::string camelot;
  std::string name;
  double confidence = 0;
};

static Key detectKey(const std::vector<double> &c) {
  // профили Крумхансла — Кесслера
  static const double maj[12] = {6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88};
  static const double minr[12] = {6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17};
  static const char *names[12] = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"};
  // Camelot: мажор C=8B, G=9B…; минор Am=8A, Em=9A…
  auto camelot = [](int tonic, bool minor) {
    const int majorTonic = minor ? (tonic + 3) % 12 : tonic;  // параллельный мажор для минора
    const int num = ((majorTonic * 7) % 12 + 7) % 12 + 1;    // C→8, G→9, …
    return std::to_string(num) + (minor ? "A" : "B");
  };
  auto corr = [&](const double *prof, int shift) {
    double mx = 0, my = 0;
    for (int i = 0; i < 12; ++i) { mx += c[(size_t)((i + shift) % 12)]; my += prof[i]; }
    mx /= 12; my /= 12;
    double sxy = 0, sxx = 0, syy = 0;
    for (int i = 0; i < 12; ++i) {
      const double dx = c[(size_t)((i + shift) % 12)] - mx, dy = prof[i] - my;
      sxy += dx * dy; sxx += dx * dx; syy += dy * dy;
    }
    return sxx > 0 && syy > 0 ? sxy / std::sqrt(sxx * syy) : 0.0;
  };
  // Уверенность — насколько лучшая тональность обгоняет лучшую из НЕсовместимых с ней. Параллельный мажор/минор
  // (тот же номер Camelot) и соседи по кругу для сведения равноценны — их близость сомнений не добавляет (раньше
  // из-за параллельной тональности почти любой трек выходил «неуверенным»)
  double r[2][12];
  double best = -2;
  int bt = 0;
  bool bm = false;
  for (int t = 0; t < 12; ++t)
    for (int m = 0; m < 2; ++m) {
      r[m][t] = corr(m ? minr : maj, t);
      if (r[m][t] > best) { best = r[m][t]; bt = t; bm = m; }
    }
  auto num = [&](int t, bool m) { return std::stoi(camelot(t, m)); };
  const int bn = num(bt, bm);
  double second = -2;
  for (int t = 0; t < 12; ++t)
    for (int m = 0; m < 2; ++m) {
      const int d = std::abs(num(t, m) - bn) % 12, dist = std::min(d, 12 - d);
      const bool compatible = dist == 0 || ((bool)m == bm && dist <= 1);
      if (!compatible) second = std::max(second, r[m][t]);
    }
  Key k;
  k.camelot = camelot(bt, bm);
  k.name = std::string(names[bt]) + (bm ? "m" : "");
  k.confidence = std::clamp((best - second) * 5.0, 0.0, 1.0) * std::clamp(best * 1.5, 0.0, 1.0);
  return k;
}

// ================================================================ JSON

class Json {
 public:
  void raw(const std::string &v) { sep(); s_ += v; }  // готовое значение (например, null)
  void key(const char *k) { comma(); s_ += '"'; s_ += k; s_ += "\":"; first_ = true; pendingValue_ = true; }
  void num(double v, int prec = 3) {
    sep();
    if (!std::isfinite(v)) { s_ += "null"; return; }
    char b[64];
    std::snprintf(b, sizeof(b), "%.*f", prec, v);
    s_ += b;
  }
  void integer(long long v) { sep(); s_ += std::to_string(v); }
  void boolean(bool v) { sep(); s_ += v ? "true" : "false"; }
  void str(const std::string &v) {
    sep();
    s_ += '"';
    for (char c : v) {
      if (c == '"' || c == '\\') { s_ += '\\'; s_ += c; }
      else if ((unsigned char)c < 0x20) { char b[8]; std::snprintf(b, sizeof(b), "\\u%04x", c); s_ += b; }
      else s_ += c;
    }
    s_ += '"';
  }
  void open(char c) { sep(); s_ += c; first_ = true; }
  void close(char c) { s_ += c; first_ = false; }
  std::string take() { return std::move(s_); }

 private:
  void comma() { if (!first_) s_ += ','; }
  void sep() {
    if (pendingValue_) { pendingValue_ = false; first_ = false; return; }
    comma();
    first_ = false;
  }
  std::string s_;
  bool first_ = true, pendingValue_ = false;
};

// ================================================================ анализатор

class Analyzer {
 public:
  bool init(const std::string &ortLib, const std::string &melModel, const std::string &beatModel, int threads,
            std::string &err) {
    if (!ort_.load(ortLib, err)) return false;
    mel_ = std::make_unique<Session>(ort_);
    net_ = std::make_unique<Session>(ort_);
    if (!mel_->open(melModel, threads, err)) return false;
    if (!net_->open(beatModel, threads, err)) return false;
    threads_ = threads;
    return true;
  }

  // Модель вокала (Spleeter vocals); без неё анализ идёт как раньше, «vocals» в профиле — null
  bool setVocals(const std::string &model, std::string &err) {
    auto s = std::make_unique<Session>(ort_);
    if (!s->open(model, threads_, err)) return false;
    voc_ = std::move(s);
    return true;
  }

  bool analyze(const std::string &path, const std::string &ffmpeg, std::string &json, std::string &err) {
    // CM_ANALYSIS_PROFILE=1 — печатать время этапов в stderr
    const bool prof = std::getenv("CM_ANALYSIS_PROFILE") != nullptr;
    auto tick = std::chrono::steady_clock::now();
    auto lap = [&](const char *what) {
      if (!prof) return;
      const auto now = std::chrono::steady_clock::now();
      std::fprintf(stderr, "  [%s] %.0f ms\n", what, std::chrono::duration<double, std::milli>(now - tick).count());
      tick = now;
    };
    // 1. Декодирование: моно 22 050 Гц для нейросети и тональности, стерео на родной частоте — для громкости
    std::unique_ptr<Reader> rd = openMiniaudio(path);
    if (!rd) rd = openFfmpeg(ffmpeg, path, err);
    if (!rd) { if (err.empty()) err = "файл не открылся: " + path; return false; }
    const int fs = rd->rate();
    Loudness lu;
    lu.setup(fs);
    TruePeak tp;
    RubberBand::Resampler::Parameters prm;
    prm.quality = RubberBand::Resampler::Best;
    prm.dynamism = RubberBand::Resampler::RatioMostlyFixed;
    prm.initialSampleRate = fs;
    prm.maxBufferSize = 4096;
    RubberBand::Resampler rs(prm, 1);
    const double ratio = (double)kModelRate / fs;
    std::vector<float> mono;
    if (rd->durationSec() > 0) mono.reserve((size_t)(rd->durationSec() * kModelRate) + 4096);
    std::vector<float> st(4096 * 2), m(4096), out((size_t)(4096 * ratio) + 64);
    long long frames = 0;
    VocalTracker vt;
    const bool vocals = voc_ && vt.start(voc_.get(), fs);
    while (true) {
      const int got = rd->read(st.data(), 4096);
      if (got > 0) {
        lu.add(st.data(), got);
        tp.add(st.data(), got);
        for (int i = 0; i < got; ++i) m[(size_t)i] = 0.5f * (st[(size_t)i * 2] + st[(size_t)i * 2 + 1]);
      }
      const bool end = got < 4096;
      if (vocals) vt.add(st.data(), std::max(got, 0), end);
      if (fs == kModelRate) mono.insert(mono.end(), m.begin(), m.begin() + got);
      else {
        const float *in = m.data();
        float *o = out.data();
        const int n = rs.resample(&o, (int)out.size(), &in, std::max(got, 0), ratio, end);
        mono.insert(mono.end(), out.begin(), out.begin() + std::max(n, 0));
      }
      frames += std::max(got, 0);
      if (end) break;
    }
    const double duration = (double)frames / fs;
    lap(vocals ? "decode + resample + loudness + true peak + vocals" : "decode + resample + loudness + true peak");
    if (mono.size() < (size_t)kModelRate) { err = "трек короче секунды"; return false; }

    // 2. Beat This!
    std::vector<float> melFrames, bl, dl;
    if (!melSpectrogram(*mel_, mono, melFrames, err)) return false;
    lap("mel");
    if (!beatLogits(*net_, melFrames, bl, dl, err)) return false;
    lap("beat this");
    std::vector<double> beats = peaks(bl), downs = peaks(dl);
    snapDownbeats(beats, downs);

    // 3. Сетка, размер, первая сильная доля
    Grid g = fitGrid(beats);
    double phaseShift = 0, phaseGain = 0;
    if (g.ok && !g.variable) {
      phaseShift = refinePhase(mono, kModelRate, g, duration, &phaseGain);
      while (g.firstBeat < 0) g.firstBeat += g.period;
      while (g.firstBeat >= g.period) g.firstBeat -= g.period;
      if (g.firstBeat < 0) g.firstBeat += g.period;
      if (g.firstBeat >= g.period) g.firstBeat -= g.period;
    }
    // Темп плавает по треку (живые барабаны, запись концерта), но для перехода нужна сетка только там, где он
    // идёт: в начале (вход B) и в конце (выход A). Если на этих участках темп ровный — своя сетка для участка.
    struct Edge { bool ok = false; Grid g; double from = 0, to = 0; };
    Edge edges[2];  // 0 — начало, 1 — конец
    if (g.ok && g.variable && duration > 40) {
      for (int e = 0; e < 2; ++e) {
        Edge &E = edges[e];
        // участок подлиннее, если он ровный; иначе короче — до 30 с (8 тактов при 64 BPM)
        for (double span : {90.0, 60.0, 45.0, 30.0}) {
          span = std::min(span, duration * 0.45);
          E.from = e == 0 ? 0 : duration - span;
          E.to = e == 0 ? span : duration;
          std::vector<double> sub;
          for (double t : beats) if (t >= E.from && t < E.to) sub.push_back(t);
          if (sub.size() < 24) continue;
          E.g = fitGrid(sub);
          if (E.g.ok && !E.g.variable) break;
        }
        if (!E.g.ok || E.g.variable) continue;
        double gain = 0;
        refinePhase(mono, kModelRate, E.g, duration, &gain, E.from, E.to);
        while (E.g.firstBeat < 0) E.g.firstBeat += E.g.period;
        while (E.g.firstBeat >= E.g.period) E.g.firstBeat -= E.g.period;
        if (E.g.firstBeat < 0) E.g.firstBeat += E.g.period;
        if (E.g.firstBeat >= E.g.period) E.g.firstBeat -= E.g.period;
        E.ok = true;
      }
    }
    int beatsPerBar = 4;
    {
      int hist[9] = {};
      for (size_t i = 1; i < downs.size(); ++i) {
        const auto a = std::lower_bound(beats.begin(), beats.end(), downs[i - 1]);
        const auto b = std::lower_bound(beats.begin(), beats.end(), downs[i]);
        const long d = b - a;
        if (d >= 2 && d <= 8) hist[d]++;
      }
      int bestN = 0;
      for (int d = 2; d <= 8; ++d) if (hist[d] > bestN) { bestN = hist[d]; beatsPerBar = d; }
    }
    // Фаза такта: на какой номер доли сетки приходится сильная доля. Голосуют не только найденные даунбиты,
    // а вероятность даунбита нейросети на каждой доле сетки (максимум в ±40 мс): так учитываются и слабые
    // даунбиты ниже порога, а одиночные ложные значат меньше. Уверенность — доля голосов победителя.
    auto softVotes = [&](const Grid &q, double from, double to) {
      std::vector<double> v((size_t)beatsPerBar, 0.0);
      const double fps = 50.0;
      long k = (long)std::ceil((from - q.firstBeat) / q.period);
      for (double t = q.firstBeat + k * q.period; t < to; t += q.period, ++k) {
        const long c = std::lround(t * fps);
        float mx = -1e9f;
        for (long f = c - 2; f <= c + 2; ++f)
          if (f >= 0 && f < (long)dl.size()) mx = std::max(mx, dl[(size_t)f]);
        if (mx < -1e8f) continue;
        v[(size_t)(((k % beatsPerBar) + beatsPerBar) % beatsPerBar)] += 1.0 / (1.0 + std::exp(-(double)mx));
      }
      return v;
    };
    int firstDownbeatIndex = 0;
    double downConf = 0;
    double firstDownbeat = downs.empty() ? (g.ok ? g.firstBeat : 0) : downs[0];
    if (g.ok) {
      const auto votes = softVotes(g, 0, duration);
      double tot = 0;
      for (double v : votes) tot += v;
      firstDownbeatIndex = (int)(std::max_element(votes.begin(), votes.end()) - votes.begin());
      downConf = tot > 0 ? votes[(size_t)firstDownbeatIndex] / tot : 0;
      // Нейросеть колеблется между «1» и «3» (сильная доля на полтакта раньше или позже) — частая ошибка в
      // поп- и рок-музыке. Тогда решают аккорды: они чаще сменяются на начале такта. Для каждой доли — насколько
      // отличается гармония такта до неё и такта после; у какой из двух фаз смены сильнее, та и сильная доля.
      if (beatsPerBar == 4 && downConf < 0.7) {
        const int alt = (firstDownbeatIndex + 2) % 4;
        if (votes[(size_t)alt] > 0.5 * votes[(size_t)firstDownbeatIndex]) {
          std::vector<std::vector<double>> fc;
          const int hop = 1024;
          chroma(mono, kModelRate, &fc, hop);
          const double fps = (double)kModelRate / hop, barLen = 4 * g.period;
          auto mean = [&](double a, double b, double *o) {
            for (int i = 0; i < 12; ++i) o[i] = 0;
            const long fa = std::max(0L, std::lround(a * fps)), fb = std::min((long)fc.size(), std::lround(b * fps));
            for (long f = fa; f < fb; ++f)
              for (int i = 0; i < 12; ++i) o[i] += fc[(size_t)f][(size_t)i];
          };
          double nov[4] = {0, 0, 0, 0};
          long k = (long)std::ceil((barLen - g.firstBeat) / g.period);
          for (double t = g.firstBeat + k * g.period; t + barLen < duration; t += g.period, ++k) {
            double x[12], y[12];
            mean(t - barLen, t, x);
            mean(t, t + barLen, y);
            double xy = 0, xx = 0, yy = 0;
            for (int i = 0; i < 12; ++i) { xy += x[i] * y[i]; xx += x[i] * x[i]; yy += y[i] * y[i]; }
            if (xx <= 0 || yy <= 0) continue;
            nov[((k % 4) + 4) % 4] += 1.0 - xy / std::sqrt(xx * yy);
          }
          if (prof) std::fprintf(stderr, "  downbeat chords: %.2f %.2f %.2f %.2f (votes for %d)\n", nov[0], nov[1], nov[2], nov[3], firstDownbeatIndex);
          if (nov[alt] > 1.2 * nov[firstDownbeatIndex]) {
            if (prof) std::fprintf(stderr, "  downbeat: votes %.2f vs %.2f, chords %.2f vs %.2f -> phase %d\n",
                                   votes[(size_t)firstDownbeatIndex], votes[(size_t)alt], nov[firstDownbeatIndex], nov[alt], alt);
            firstDownbeatIndex = alt;
            downConf = tot > 0 ? votes[(size_t)alt] / tot : 0;
          }
        }
      }
      firstDownbeat = g.firstBeat + firstDownbeatIndex * g.period;
    }
    // сильная доля участка: первая доля сетки участка с тем номером, на который чаще попадают даунбиты участка
    double edgeDown[2] = {-1, -1};
    for (int e = 0; e < 2; ++e) {
      const Edge &E = edges[e];
      if (!E.ok) continue;
      const Grid &q = E.g;
      const auto votes = softVotes(q, E.from, E.to);
      double tot = 0;
      for (double v : votes) tot += v;
      if (tot < 1.0) continue;
      const int idx = (int)(std::max_element(votes.begin(), votes.end()) - votes.begin());
      long k0 = (long)std::ceil((E.from - q.firstBeat) / q.period);
      while (((k0 % beatsPerBar) + beatsPerBar) % beatsPerBar != idx) ++k0;
      edgeDown[e] = q.firstBeat + k0 * q.period;
    }

    // 4. Тишина в начале и конце (порог −60 дБFS по окнам 50 мс)
    const int w = kModelRate / 20;
    auto rmsDb = [&](size_t a, size_t n) {
      double s = 0;
      for (size_t i = a; i < a + n && i < mono.size(); ++i) s += (double)mono[i] * mono[i];
      return 10 * std::log10(std::max(s / (double)n, 1e-20));
    };
    size_t intro = 0, endS = mono.size();
    while (intro + (size_t)w < mono.size() && rmsDb(intro, (size_t)w) < -60) intro += (size_t)w;
    while (endS > intro + (size_t)w && rmsDb(endS - (size_t)w, (size_t)w) < -60) endS -= (size_t)w;

    // 5. Тональность
    std::vector<std::vector<double>> frameChroma;
    const auto ch = chroma(mono, kModelRate, &frameChroma);
    const Key key = detectKey(ch);
    lap("key");

    // 6. Такты: громкость (K-взвешенная, моно), энергия 1…10, хрома для поиска границ
    struct Bar { double t, lufs; int energy; std::vector<double> chroma; double vocal = 0; };
    std::vector<Bar> bars;
    // модель вокала отработала: массив по тактам (пустой, если тактов нет — плавающий темп), иначе null
    const bool haveVocals = vocals && vt.active() && !vt.voice().empty();
    if (vocals && !vt.active() && prof) std::fprintf(stderr, "  vocals failed: %s\n", vt.error().c_str());
    if (g.ok) {
      const double barLen = g.period * beatsPerBar;
      double t = firstDownbeat;
      while (t - barLen > 0) t -= barLen;  // такты от начала трека, выровненные по сильной доле
      // громкость тактов за один проход: K-взвешенный квадрат каждого сэмпла — в корзину своего такта
      const double t0 = t;
      const size_t nBars = (size_t)std::max(0.0, std::floor((duration + 1e-6 - t0) / barLen));
      std::vector<double> barSum(nBars, 0.0);
      std::vector<size_t> barN(nBars, 0);
      {
        KWeight kw;
        kw.setup(kModelRate);
        for (size_t i = 0; i < mono.size(); ++i) {
          const double y = kw.tick(0, mono[i]);
          const double bt = ((double)i / kModelRate - t0) / barLen;
          if (bt < 0) continue;
          const size_t bi = (size_t)bt;
          if (bi >= nBars) break;
          barSum[bi] += y * y;
          ++barN[bi];
        }
      }
      std::vector<double> vpb;
      if (vocals && vt.active() && !vt.voice().empty()) vpb = vocalsPerBar(vt, t0, barLen, nBars);
      for (size_t bi = 0; bi < nBars; ++bi, t += barLen) {
        const size_t a = (size_t)std::max(0.0, t * kModelRate), b = std::min(mono.size(), (size_t)((t + barLen) * kModelRate));
        if (b <= a || barN[bi] == 0) break;
        // моно: +3 дБ, чтобы шкала совпадала со стерео LUFS для одинаковых каналов
        const double l = -0.691 + 10 * std::log10(std::max(barSum[bi] / (double)barN[bi], 1e-20)) + 3.01;
        Bar bar;
        bar.t = t;
        bar.lufs = l;
        bar.vocal = bi < vpb.size() ? vpb[bi] : 0.0;
        bar.energy = (int)std::clamp(std::lround(1 + 9 * (l + 30.0) / 24.0), 1L, 10L);  // −30 LUFS → 1, −6 → 10
        bar.chroma.assign(12, 0.0);
        const size_t fa = a / 4096, fb = std::min(frameChroma.size(), b / 4096 + 1);
        for (size_t f = fa; f < fb; ++f)
          for (int i = 0; i < 12; ++i) bar.chroma[(size_t)i] += frameChroma[f][(size_t)i];
        double nrm = 0;
        for (double v : bar.chroma) nrm += v * v;
        nrm = std::sqrt(nrm);
        if (nrm > 0) for (auto &v : bar.chroma) v /= nrm;
        bars.push_back(std::move(bar));
      }
    }

    // 7. Границы фраз: каждые 8 тактов от первой сильной доли; сила границы — насколько меняются
    // громкость и гармония между 4 тактами до и 4 после
    int firstBar = 0;
    for (size_t i = 0; i < bars.size(); ++i)
      if (std::abs(bars[i].t - firstDownbeat) < 1e-3 || bars[i].t > firstDownbeat - 1e-3) { firstBar = (int)i; break; }
    struct Cut { int bar; double novelty; };
    std::vector<Cut> cuts;
    for (int b = firstBar; b < (int)bars.size(); b += 8) {
      if (b < 4 || b + 4 > (int)bars.size()) continue;
      double le = 0, ri = 0;
      std::vector<double> cl(12, 0.0), cr(12, 0.0);
      for (int k = 0; k < 4; ++k) {
        le += bars[(size_t)(b - 1 - k)].lufs; ri += bars[(size_t)(b + k)].lufs;
        for (int i = 0; i < 12; ++i) { cl[(size_t)i] += bars[(size_t)(b - 1 - k)].chroma[(size_t)i]; cr[(size_t)i] += bars[(size_t)(b + k)].chroma[(size_t)i]; }
      }
      double dot = 0, nl = 0, nr = 0;
      for (int i = 0; i < 12; ++i) { dot += cl[(size_t)i] * cr[(size_t)i]; nl += cl[(size_t)i] * cl[(size_t)i]; nr += cr[(size_t)i] * cr[(size_t)i]; }
      const double harm = nl > 0 && nr > 0 ? 1.0 - dot / std::sqrt(nl * nr) : 0;
      const double loud = std::abs(ri - le) / 4.0;
      cuts.push_back({b, std::min(1.0, loud / 6.0 + harm * 4.0)});
    }

    // 8. Секции и точки микса
    double meanEnergy = 0;
    for (auto &b : bars) meanEnergy += b.energy;
    meanEnergy = bars.empty() ? 0 : meanEnergy / (double)bars.size();
    auto avgEnergy = [&](int a, int n) {
      double s = 0; int c = 0;
      for (int i = a; i < a + n && i < (int)bars.size(); ++i) if (i >= 0) { s += bars[(size_t)i].energy; ++c; }
      return c ? s / c : 0.0;
    };
    struct Point { int bar; double score; };
    std::vector<Point> mixIn, mixOut;
    struct Section { int bar; std::string type; };
    std::vector<Section> sections;
    if (!bars.empty()) {
      sections.push_back({0, "intro"});
      for (const Cut &c : cuts) {
        if (c.novelty < 0.25) continue;
        const double before = avgEnergy(c.bar - 4, 4), after = avgEnergy(c.bar, 4);
        std::string type = after - before >= 2 ? "drop" : before - after >= 2 ? "break" : "section";
        sections.push_back({c.bar, type});
      }
      // вход: начало трека (если вступление спокойнее остального) и первые границы фраз
      const double introE = avgEnergy(firstBar, 8);
      mixIn.push_back({firstBar, introE <= meanEnergy + 0.5 ? 0.9 : 0.6});
      for (const Cut &c : cuts) {
        if (c.bar <= firstBar || c.bar > firstBar + 32) continue;
        mixIn.push_back({c.bar, 0.4 + 0.4 * c.novelty});
      }
      // выход: границы фраз в последней трети, лучше там, где дальше становится тише (аутро)
      const int nb = (int)bars.size();
      for (const Cut &c : cuts) {
        if (c.bar < nb * 2 / 3 || c.bar + 8 > nb) continue;
        const double after = avgEnergy(c.bar, 8), before = avgEnergy(c.bar - 8, 8);
        const double s = 0.5 + std::clamp((before - after) / 6.0, -0.3, 0.4) + 0.1 * c.novelty;
        mixOut.push_back({c.bar, std::clamp(s, 0.0, 1.0)});
      }
      if (mixOut.empty()) {
        // нет явных фраз: за 16 тактов до конца (или сколько есть), выровнено по фразе
        int b = std::max(firstBar, nb - 16);
        b = firstBar + (b - firstBar) / 8 * 8;
        mixOut.push_back({b, 0.4});
      }
      auto byScore = [](const Point &a, const Point &b) { return a.score > b.score; };
      std::sort(mixIn.begin(), mixIn.end(), byScore);
      std::sort(mixOut.begin(), mixOut.end(), byScore);
      if (mixIn.size() > 3) mixIn.resize(3);
      if (mixOut.size() > 3) mixOut.resize(3);
    }

    // 9. JSON профиля v2 (ТЗ, раздел 3.3)
    Json j;
    j.open('{');
    j.key("v"); j.integer(2);
    j.key("algo"); j.integer(5);  // версия алгоритма сетки: старые профили пересчитываются
    j.key("level"); j.str("quick");
    j.key("analyzer"); j.str("cave_mix/beat_this");
    j.key("durationMs"); j.integer(std::llround(duration * 1000));
    j.key("bpm"); if (g.ok) j.num(60.0 / g.period, 4); else j.raw("null");  // 4 знака: 0,01 BPM — 7 мс за 100 с
    j.key("bpmSource"); j.str("analysis");
    j.key("variableTempo"); j.boolean(g.ok ? g.variable : true);
    j.key("gridResidualMs"); j.num(g.residualMs, 1);
    j.key("tempoDriftPct"); j.num(g.maxLocalDevPct, 2);
    j.key("phaseShiftMs"); j.num(phaseShift * 1000, 1);
    j.key("downbeatConfidence"); j.num(downConf, 2);
    // ровные участки в начале и конце трека с плавающим темпом (для перехода хватает их)
    for (int e = 0; e < 2; ++e) {
      j.key(e == 0 ? "inGrid" : "outGrid");
      if (edgeDown[e] < 0) { j.raw("null"); continue; }
      j.open('{');
      j.key("bpm"); j.num(60.0 / edges[e].g.period, 4);
      j.key("downbeatMs"); j.integer(std::llround(edgeDown[e] * 1000));
      j.key("fromMs"); j.integer(std::llround(edges[e].from * 1000));
      j.key("toMs"); j.integer(std::llround(edges[e].to * 1000));
      j.close('}');
    }
    j.key("firstBeatMs"); if (g.ok) j.integer(std::llround(g.firstBeat * 1000)); else j.raw("null");
    j.key("beatsPerBar"); j.integer(beatsPerBar);
    j.key("firstDownbeatIndex"); j.integer(firstDownbeatIndex);
    j.key("firstDownbeatMs"); j.integer(std::llround(firstDownbeat * 1000));
    j.key("beats"); j.open('['); for (double b : beats) j.num(b, 3); j.close(']');
    j.key("downbeats"); j.open('['); for (double d : downs) j.num(d, 3); j.close(']');
    j.key("key"); j.str(key.camelot);
    j.key("keyName"); j.str(key.name);
    j.key("keyConfidence"); j.num(key.confidence, 2);
    j.key("lufs"); j.num(lu.integrated(), 1);
    j.key("truePeakDb"); j.num(tp.dbtp(), 1);
    j.key("introMs"); j.integer(std::llround(intro * 1000.0 / kModelRate));
    j.key("endMs"); j.integer(std::llround(endS * 1000.0 / kModelRate));
    j.key("barMs"); j.num(g.ok ? g.period * beatsPerBar * 1000 : 0, 1);
    j.key("energy"); j.open('['); for (auto &b : bars) j.integer(b.energy); j.close(']');
    j.key("sections"); j.open('[');
    for (auto &s : sections) { j.open('{'); j.key("startBar"); j.integer(s.bar); j.key("type"); j.str(s.type); j.close('}'); }
    j.close(']');
    // доля голоса по тактам (0…1, как energy); null — модели вокала нет
    j.key("vocals");
    if (haveVocals) {
      j.open('[');
      for (auto &b : bars) j.num(b.vocal, 2);
      j.close(']');
    } else {
      j.raw("null");
    }
    j.key("mixIn"); j.open('[');
    for (auto &p : mixIn) { j.open('{'); j.key("bar"); j.integer(p.bar); j.key("score"); j.num(p.score, 2); j.close('}'); }
    j.close(']');
    j.key("mixOut"); j.open('[');
    for (auto &p : mixOut) { j.open('{'); j.key("bar"); j.integer(p.bar); j.key("score"); j.num(p.score, 2); j.close('}'); }
    j.close(']');
    j.close('}');
    json = j.take();
    return true;
  }

 private:
  Ort ort_;
  std::unique_ptr<Session> mel_, net_, voc_;
  int threads_ = 1;
};

}  // namespace an
}  // namespace cm

// ================================================================ C API

struct cm_analyzer {
  cm::an::Analyzer a;
  std::string error;
};

static char *dupString(const std::string &s) {
  char *p = static_cast<char *>(std::malloc(s.size() + 1));
  if (p) std::memcpy(p, s.c_str(), s.size() + 1);
  return p;
}

extern "C" {

CM_API cm_analyzer *cm_analyzer_create(const char *ort_lib, const char *mel_model, const char *beat_model, int32_t threads,
                                       char **error_out) {
  auto *z = new (std::nothrow) cm_analyzer();
  if (!z) return nullptr;
  std::string err;
  if (!ort_lib || !mel_model || !beat_model ||
      !z->a.init(ort_lib, mel_model, beat_model, threads > 0 ? threads : std::max(1, (int)std::thread::hardware_concurrency()), err)) {
    if (error_out) *error_out = dupString(err.empty() ? "не заданы пути" : err);
    delete z;
    return nullptr;
  }
  return z;
}

CM_API void cm_analyzer_destroy(cm_analyzer *z) { delete z; }

CM_API int32_t cm_analyzer_set_vocals(cm_analyzer *z, const char *vocals_model, char **error_out) {
  if (!z || !vocals_model) return 0;
  std::string err;
  if (!z->a.setVocals(vocals_model, err)) {
    if (error_out) *error_out = dupString(err);
    return 0;
  }
  return 1;
}

CM_API char *cm_analyze_file(cm_analyzer *z, const char *path_utf8, const char *ffmpeg_utf8, char **error_out) {
  if (!z || !path_utf8) return nullptr;
  std::string json, err;
  if (!z->a.analyze(path_utf8, ffmpeg_utf8 ? ffmpeg_utf8 : "", json, err)) {
    if (error_out) *error_out = dupString(err);
    return nullptr;
  }
  return dupString(json);
}

CM_API void cm_free(void *p) { std::free(p); }

}  // extern "C"

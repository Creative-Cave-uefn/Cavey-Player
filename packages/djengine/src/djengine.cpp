// Движок DJ-пульта: две деки, микшер, эквалайзер, фильтры, эффекты, петли.
// Вывод звука — miniaudio (общественное достояние / MIT-0); вся обработка своя (dsp.hpp).
#include "djengine.h"

#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <mutex>
#include <vector>

#include "dsp.hpp"

#ifndef DJ_NO_DEVICE
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
#endif

using namespace dj;

namespace {

constexpr int kBlock = 512;

struct Track {
  std::vector<float> pcm; // стерео, чередуется
  int64_t frames = 0;
};

struct Deck {
  // Данные трека. Аудиопоток берёт замок только try_lock: если идёт загрузка, блок остаётся тихим
  std::mutex mu;
  std::shared_ptr<Track> track;

  // Управление (пишется из интерфейса, читается в аудиопотоке)
  std::atomic<bool> playing{false};
  std::atomic<double> tempo{1.0};
  std::atomic<bool> keylock{true};
  std::atomic<float> pitchSemi{0.f};
  std::atomic<float> trimDb{0.f};
  std::atomic<float> fader{1.f};
  std::atomic<float> eqLo{0.f}, eqMid{0.f}, eqHi{0.f}; // дБ
  std::atomic<float> filter{0.f};
  std::atomic<double> seekTo{-1.0};
  std::atomic<bool> loopOn{false};
  std::atomic<double> loopIn{0.0}, loopOut{0.0};
  std::atomic<bool> reverse{false};

  // Состояние (читается из интерфейса)
  std::atomic<double> pos{0.0}; // кадров
  std::atomic<float> peak{0.f};

  // Внутренности аудиопотока
  std::shared_ptr<Track> cur;
  Stretcher st;
  std::vector<float> fifo; // растянутые кадры (стерео), ждут ресемплинга
  size_t fifoRead = 0; // индекс кадра
  double fifoFrac = 0;
  bool stMode = false; // true — сейчас работает растяжение времени
  double dpos = 0; // позиция в прямом режиме
  float fadeIn = 1.f;
  float curFader = 1.f, curTrim = 1.f, curRate = 1.f;
  Eq3 eq;
  DjFilter filt;
  std::vector<float> buf;

  void init(double sr) {
    eq.init(sr);
    filt.fs = sr;
    buf.assign(kBlock * 2, 0.f);
    fifo.reserve(8192);
  }
};

} // namespace

struct DjEngine {
  double sr = 44100;
  Deck deck[2];
  FxUnit fx[2];
  std::atomic<float> xfade{0.f}; // -1 (дека A) … 1 (дека B)
  std::atomic<int> xcurve{0}; // 0 — постоянная мощность, 1 — сумма (резкий)
  std::atomic<float> master{0.85f};
  std::atomic<float> masterPeak{0.f};
  std::atomic<int> fxType[2] = {{0}, {0}}, fxTarget[2] = {{0}, {0}};
  std::atomic<float> fxMix[2] = {{0.f}, {0.f}}, fxP1[2] = {{0.f}, {0.f}}, fxP2[2] = {{0.f}, {0.f}};
  std::vector<float> mixBuf, tmp;
#ifndef DJ_NO_DEVICE
  ma_device device;
  bool deviceOn = false;
#endif

  void renderDeck(Deck& d, float* out, int frames);
  void render(float* out, int frames);
};

// ---------- дека ----------

namespace {

// Куда на кадре позиция i попадает в stretched-fifo
inline float fifoAt(const std::vector<float>& f, int64_t i, int ch) {
  if (i < 0) i = 0;
  const int64_t n = static_cast<int64_t>(f.size() / 2);
  if (i >= n) i = n - 1;
  if (i < 0) return 0.f;
  return f[static_cast<size_t>(2 * i + ch)];
}

inline float srcAt(const Track& t, int64_t i, int ch) {
  if (i < 0 || i >= t.frames) return 0.f;
  return t.pcm[static_cast<size_t>(2 * i + ch)];
}

} // namespace

void DjEngine::renderDeck(Deck& d, float* out, int frames) {
  std::memset(out, 0, sizeof(float) * 2 * frames);
  // Новый трек
  if (d.mu.try_lock()) {
    if (d.cur != d.track) {
      d.cur = d.track;
      d.pos = 0;
      d.dpos = 0;
      d.stMode = false;
      d.fifo.clear();
      d.fifoRead = 0;
      d.eq.reset();
    }
    d.mu.unlock();
  }
  Track* t = d.cur.get();
  if (!t || t->frames == 0) {
    d.peak = 0;
    return;
  }

  // Перемотка
  const double sk = d.seekTo.exchange(-1.0);
  if (sk >= 0) {
    d.dpos = std::min(sk, static_cast<double>(t->frames));
    d.stMode = false; // режим выберется заново ниже
    d.fifo.clear();
    d.fifoRead = 0;
    d.fifoFrac = 0;
    d.fadeIn = 0.f;
    d.pos = d.dpos;
  }
  if (!d.playing.load()) {
    d.peak = 0;
    return;
  }

  const double tempo = std::max(0.25, std::min(4.0, d.tempo.load()));
  const bool keylock = d.keylock.load();
  const float semi = d.pitchSemi.load();
  const bool needStretch = keylock && (std::fabs(tempo - 1.0) > 1e-4 || std::fabs(semi) > 1e-3);

  // Переключение режимов без скачка позиции
  if (needStretch && !d.stMode) {
    d.st.reset(t->pcm.data(), t->frames, d.dpos);
    d.fifo.clear();
    d.fifoRead = 0;
    d.fifoFrac = 0;
    d.stMode = true;
  } else if (!needStretch && d.stMode) {
    const double est = d.st.nominal - static_cast<double>((d.fifo.size() / 2) - d.fifoRead) * (tempo / std::pow(2.0, semi / 12.0));
    d.dpos = std::max(0.0, est);
    d.stMode = false;
  }

  const bool loopOn = d.loopOn.load();
  const double lin = d.loopIn.load(), lout = d.loopOut.load();
  const bool loop = loopOn && lout > lin + 64;
  bool ended = false;

  if (d.stMode) {
    const double pitchRatio = std::pow(2.0, semi / 12.0);
    const double stretchRatio = tempo / pitchRatio; // кадров исходника на кадр растянутого звука
    const double step = pitchRatio; // растянутых кадров на кадр выхода
    for (int i = 0; i < frames; i++) {
      const int64_t need = static_cast<int64_t>(d.fifoRead) + 4;
      // Подкачиваем растянутый звук
      while (static_cast<int64_t>(d.fifo.size() / 2) < need + 2) {
        if (d.st.nominal > t->frames + Stretcher::N) {
          ended = true;
          break;
        }
        const size_t at = d.fifo.size();
        d.fifo.resize(at + 2 * Stretcher::HO);
        d.st.step(stretchRatio, d.fifo.data() + at);
        if (loop && d.st.nominal >= lout) d.st.nominal -= (lout - lin);
      }
      if (ended && static_cast<int64_t>(d.fifo.size() / 2) < need + 2) break;
      const int64_t i0 = static_cast<int64_t>(d.fifoRead);
      const float tt = static_cast<float>(d.fifoFrac);
      for (int c = 0; c < 2; c++)
        out[2 * i + c] = cubic(fifoAt(d.fifo, i0 - 1, c), fifoAt(d.fifo, i0, c), fifoAt(d.fifo, i0 + 1, c), fifoAt(d.fifo, i0 + 2, c), tt);
      d.fifoFrac += step;
      const int64_t whole = static_cast<int64_t>(d.fifoFrac);
      d.fifoFrac -= static_cast<double>(whole);
      d.fifoRead += static_cast<size_t>(whole);
    }
    // Освобождаем прочитанное, чтобы fifo не росла
    if (d.fifoRead > 16384) {
      const size_t drop = d.fifoRead - 8;
      d.fifo.erase(d.fifo.begin(), d.fifo.begin() + static_cast<std::ptrdiff_t>(2 * drop));
      d.fifoRead -= drop;
    }
    d.pos = std::max(0.0, d.st.nominal - static_cast<double>((d.fifo.size() / 2) - d.fifoRead) * stretchRatio);
    d.dpos = d.pos;
  } else {
    // Прямой режим: темп и высота меняются вместе (как пластинка)
    const double rate = tempo;
    for (int i = 0; i < frames; i++) {
      if (loop && d.dpos >= lout) d.dpos -= (lout - lin);
      if (d.dpos >= t->frames) {
        ended = true;
        break;
      }
      const int64_t i0 = static_cast<int64_t>(d.dpos);
      const float tt = static_cast<float>(d.dpos - static_cast<double>(i0));
      for (int c = 0; c < 2; c++) out[2 * i + c] = cubic(srcAt(*t, i0 - 1, c), srcAt(*t, i0, c), srcAt(*t, i0 + 1, c), srcAt(*t, i0 + 2, c), tt);
      d.dpos += rate;
    }
    d.pos = d.dpos;
  }
  if (ended) {
    d.playing = false;
    if (d.pos.load() > static_cast<double>(t->frames)) d.pos = static_cast<double>(t->frames);
  }

  // Плавное включение после перемотки: без щелчка
  if (d.fadeIn < 1.f) {
    for (int i = 0; i < frames && d.fadeIn < 1.f; i++) {
      d.fadeIn = std::min(1.f, d.fadeIn + 1.f / 128.f);
      out[2 * i] *= d.fadeIn;
      out[2 * i + 1] *= d.fadeIn;
    }
  }
}

void DjEngine::render(float* out, int frames) {
  int done = 0;
  while (done < frames) {
    const int n = std::min(kBlock, frames - done);
    float* o = out + 2 * done;
    std::memset(mixBuf.data(), 0, sizeof(float) * 2 * n);

    // Параметры эффектов
    for (int u = 0; u < 2; u++) {
      fx[u].type = fxType[u].load();
      fx[u].target = fxTarget[u].load();
      fx[u].mix = fxMix[u].load();
      fx[u].p1 = fxP1[u].load();
      fx[u].p2 = fxP2[u].load();
    }

    const float x = std::max(-1.f, std::min(1.f, xfade.load()));
    // Кроссфейдер: на дальнем краю одна дека уходит в ноль
    float cf[2];
    if (xcurve.load() == 0) {
      const float a = (x + 1.f) * 0.25f * static_cast<float>(kPi); // 0…π/2
      cf[0] = std::cos(a);
      cf[1] = std::sin(a);
    } else {
      cf[0] = std::min(1.f, 1.f - x);
      cf[1] = std::min(1.f, 1.f + x);
    }

    for (int k = 0; k < 2; k++) {
      Deck& d = deck[k];
      renderDeck(d, d.buf.data(), n);
      d.eq.lo = dbToGain(d.eqLo.load());
      d.eq.mid = dbToGain(d.eqMid.load());
      d.eq.hi = dbToGain(d.eqHi.load());
      d.eq.process(d.buf.data(), n);
      d.filt.amount = d.filter.load();
      d.filt.process(d.buf.data(), n);
      for (int u = 0; u < 2; u++)
        if (fx[u].target == k + 1) fx[u].process(d.buf.data(), n);
      // Громкость: подрезка, фейдер, кроссфейдер; меняются плавно
      const float trim = dbToGain(d.trimDb.load(), -60.f);
      const float gain = d.fader.load() * cf[k];
      float pk = 0;
      for (int i = 0; i < n; i++) {
        d.curTrim += (trim - d.curTrim) * 0.01f;
        d.curFader += (gain - d.curFader) * 0.01f;
        const float g = d.curTrim * d.curFader;
        const float l = d.buf[2 * i], r = d.buf[2 * i + 1];
        pk = std::max(pk, std::max(std::fabs(l), std::fabs(r)) * g);
        mixBuf[2 * i] += l * g;
        mixBuf[2 * i + 1] += r * g;
      }
      d.peak = pk;
    }
    // Эффекты на выходе
    for (int u = 0; u < 2; u++)
      if (fx[u].target == 3) fx[u].process(mixBuf.data(), n);
    // Выход: общая громкость и мягкий ограничитель, чтобы сумма двух дек не резала звук
    const float mg = master.load();
    float mp = 0;
    for (int i = 0; i < 2 * n; i++) {
      float v = mixBuf[static_cast<size_t>(i)] * mg;
      const float a = std::fabs(v);
      if (a > 0.9f) v = (v > 0 ? 1.f : -1.f) * (0.9f + 0.1f * std::tanh((a - 0.9f) / 0.1f));
      mp = std::max(mp, std::fabs(v));
      o[i] = v;
    }
    masterPeak = mp;
    done += n;
  }
}

// ---------- устройство вывода ----------

#ifndef DJ_NO_DEVICE
static void audioCallback(ma_device* dev, void* out, const void*, ma_uint32 frames) {
  auto* e = static_cast<DjEngine*>(dev->pUserData);
  e->render(static_cast<float*>(out), static_cast<int>(frames));
}
#endif

// ---------- C-интерфейс ----------

extern "C" {

DJ_API void* dj_create(int sampleRate, int openDevice) {
  auto* e = new DjEngine();
  e->sr = sampleRate > 8000 ? sampleRate : 44100;
  for (auto& d : e->deck) d.init(e->sr);
  for (auto& f : e->fx) f.init(e->sr);
  e->mixBuf.assign(kBlock * 2, 0.f);
#ifndef DJ_NO_DEVICE
  if (openDevice) {
    ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
    cfg.playback.format = ma_format_f32;
    cfg.playback.channels = 2;
    cfg.sampleRate = static_cast<ma_uint32>(e->sr);
    cfg.dataCallback = audioCallback;
    cfg.pUserData = e;
    cfg.periodSizeInFrames = 512;
    if (ma_device_init(nullptr, &cfg, &e->device) != MA_SUCCESS) {
      delete e;
      return nullptr;
    }
    e->deviceOn = true;
  }
#else
  (void)openDevice;
#endif
  return e;
}

DJ_API int dj_device_start(void* h) {
#ifndef DJ_NO_DEVICE
  auto* e = static_cast<DjEngine*>(h);
  if (!e || !e->deviceOn) return -1;
  return ma_device_start(&e->device) == MA_SUCCESS ? 0 : -2;
#else
  (void)h;
  return -1;
#endif
}

DJ_API void dj_device_stop(void* h) {
#ifndef DJ_NO_DEVICE
  auto* e = static_cast<DjEngine*>(h);
  if (e && e->deviceOn) ma_device_stop(&e->device);
#else
  (void)h;
#endif
}

DJ_API void dj_destroy(void* h) {
  auto* e = static_cast<DjEngine*>(h);
  if (!e) return;
#ifndef DJ_NO_DEVICE
  if (e->deviceOn) ma_device_uninit(&e->device);
#endif
  delete e;
}

DJ_API int64_t dj_load(void* h, int deck, const char* utf8path) {
  auto* e = static_cast<DjEngine*>(h);
  if (!e || deck < 0 || deck > 1 || !utf8path) return -1;
  std::ifstream f(std::filesystem::u8path(utf8path), std::ios::binary | std::ios::ate);
  if (!f) return -2;
  const std::streamoff bytes = f.tellg();
  if (bytes < 8) return -3;
  auto t = std::make_shared<Track>();
  t->frames = bytes / 8; // float32 × 2 канала
  t->pcm.resize(static_cast<size_t>(t->frames) * 2);
  f.seekg(0);
  f.read(reinterpret_cast<char*>(t->pcm.data()), static_cast<std::streamsize>(t->frames) * 8);
  if (!f) return -4;
  Deck& d = e->deck[deck];
  d.playing = false;
  {
    std::lock_guard<std::mutex> lock(d.mu);
    d.track = t;
  }
  d.seekTo = 0.0;
  d.loopOn = false;
  return t->frames;
}

DJ_API void dj_unload(void* h, int deck) {
  auto* e = static_cast<DjEngine*>(h);
  if (!e || deck < 0 || deck > 1) return;
  Deck& d = e->deck[deck];
  d.playing = false;
  std::lock_guard<std::mutex> lock(d.mu);
  d.track.reset();
}

DJ_API void dj_play(void* h, int deck, int play) { static_cast<DjEngine*>(h)->deck[deck].playing = play != 0; }
DJ_API int dj_is_playing(void* h, int deck) { return static_cast<DjEngine*>(h)->deck[deck].playing.load() ? 1 : 0; }
DJ_API void dj_seek(void* h, int deck, double frames) { static_cast<DjEngine*>(h)->deck[deck].seekTo = std::max(0.0, frames); }
DJ_API double dj_pos(void* h, int deck) { return static_cast<DjEngine*>(h)->deck[deck].pos.load(); }
DJ_API int64_t dj_length(void* h, int deck) {
  auto* e = static_cast<DjEngine*>(h);
  Deck& d = e->deck[deck];
  std::lock_guard<std::mutex> lock(d.mu);
  return d.track ? d.track->frames : 0;
}
DJ_API void dj_set_tempo(void* h, int deck, double ratio) { static_cast<DjEngine*>(h)->deck[deck].tempo = ratio; }
DJ_API void dj_set_keylock(void* h, int deck, int on) { static_cast<DjEngine*>(h)->deck[deck].keylock = on != 0; }
DJ_API void dj_set_pitch(void* h, int deck, float semitones) { static_cast<DjEngine*>(h)->deck[deck].pitchSemi = semitones; }
DJ_API void dj_set_trim(void* h, int deck, float db) { static_cast<DjEngine*>(h)->deck[deck].trimDb = db; }
DJ_API void dj_set_fader(void* h, int deck, float v) { static_cast<DjEngine*>(h)->deck[deck].fader = v; }
DJ_API void dj_set_eq(void* h, int deck, float lowDb, float midDb, float highDb) {
  Deck& d = static_cast<DjEngine*>(h)->deck[deck];
  d.eqLo = lowDb;
  d.eqMid = midDb;
  d.eqHi = highDb;
}
DJ_API void dj_set_filter(void* h, int deck, float v) { static_cast<DjEngine*>(h)->deck[deck].filter = v; }
DJ_API void dj_set_loop(void* h, int deck, double inFrames, double outFrames, int active) {
  Deck& d = static_cast<DjEngine*>(h)->deck[deck];
  d.loopIn = inFrames;
  d.loopOut = outFrames;
  d.loopOn = active != 0;
}
DJ_API void dj_set_crossfader(void* h, float x, int curve) {
  auto* e = static_cast<DjEngine*>(h);
  e->xfade = x;
  e->xcurve = curve;
}
DJ_API void dj_set_master(void* h, float gain) { static_cast<DjEngine*>(h)->master = gain; }
DJ_API void dj_set_fx(void* h, int unit, int type, int target, float mix, float p1, float p2) {
  auto* e = static_cast<DjEngine*>(h);
  if (unit < 0 || unit > 1) return;
  e->fxType[unit] = type;
  e->fxTarget[unit] = target;
  e->fxMix[unit] = mix;
  e->fxP1[unit] = p1;
  e->fxP2[unit] = p2;
}
DJ_API void dj_meters(void* h, float* out3) {
  auto* e = static_cast<DjEngine*>(h);
  out3[0] = e->deck[0].peak.load();
  out3[1] = e->deck[1].peak.load();
  out3[2] = e->masterPeak.load();
}

// Обзор формы волны: пик по каждому из buckets участков, 0…255
DJ_API int dj_overview(void* h, int deck, int buckets, uint8_t* out) {
  auto* e = static_cast<DjEngine*>(h);
  Deck& d = e->deck[deck];
  std::shared_ptr<Track> t;
  {
    std::lock_guard<std::mutex> lock(d.mu);
    t = d.track;
  }
  if (!t || t->frames == 0 || buckets <= 0) return 0;
  float top = 1e-6f;
  std::vector<float> pk(static_cast<size_t>(buckets), 0.f);
  for (int b = 0; b < buckets; b++) {
    const int64_t a = t->frames * b / buckets, z = t->frames * (b + 1) / buckets;
    float m = 0;
    for (int64_t i = a; i < z; i += 8) m = std::max(m, std::fabs(t->pcm[static_cast<size_t>(2 * i)]));
    pk[static_cast<size_t>(b)] = m;
    top = std::max(top, m);
  }
  for (int b = 0; b < buckets; b++) out[b] = static_cast<uint8_t>(std::min(255.f, 255.f * pk[static_cast<size_t>(b)] / top));
  return buckets;
}

// Для проверок без звуковой карты
DJ_API void dj_render(void* h, float* out, int frames) { static_cast<DjEngine*>(h)->render(out, frames); }

} // extern "C"

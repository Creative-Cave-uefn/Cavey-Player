// Звуковая обработка для DJ-пульта: растяжение времени без смены высоты (WSOLA), ресемплинг, трёхполосный
// эквалайзер, DJ-фильтр, эффекты (эхо, реверберация, флэнджер). Всё написано с нуля; сторонних кодов здесь нет.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

namespace dj {

constexpr double kPi = 3.14159265358979323846;

inline float dbToGain(float db, float killBelow = -24.f) { return db <= killBelow ? 0.f : std::pow(10.f, db / 20.f); }

// ---------- биквадратный фильтр (стерео) ----------

struct Biquad {
  double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
  double z1[2] = {0, 0}, z2[2] = {0, 0};

  void reset() { z1[0] = z1[1] = z2[0] = z2[1] = 0; }

  // Формулы из Audio EQ Cookbook (Роберт Бристоу-Джонсон)
  void lowpass(double fs, double f, double q) {
    const double w = 2 * kPi * std::min(f, fs * 0.45) / fs, c = std::cos(w), a = std::sin(w) / (2 * q);
    const double a0 = 1 + a;
    b0 = (1 - c) / 2 / a0;
    b1 = (1 - c) / a0;
    b2 = b0;
    a1 = -2 * c / a0;
    a2 = (1 - a) / a0;
  }
  void highpass(double fs, double f, double q) {
    const double w = 2 * kPi * std::min(f, fs * 0.45) / fs, c = std::cos(w), a = std::sin(w) / (2 * q);
    const double a0 = 1 + a;
    b0 = (1 + c) / 2 / a0;
    b1 = -(1 + c) / a0;
    b2 = b0;
    a1 = -2 * c / a0;
    a2 = (1 - a) / a0;
  }
  inline float process(int ch, float x) {
    const double y = b0 * x + z1[ch];
    z1[ch] = b1 * x - a1 * y + z2[ch];
    z2[ch] = b2 * x - a2 * y;
    return static_cast<float>(y);
  }
};

// Кроссовер Линквица—Райли 4-го порядка: два одинаковых фильтра Баттерворта подряд
struct LR4 {
  Biquad lp1, lp2, hp1, hp2;
  void set(double fs, double f) {
    const double q = 0.70710678;
    lp1.lowpass(fs, f, q);
    lp2.lowpass(fs, f, q);
    hp1.highpass(fs, f, q);
    hp2.highpass(fs, f, q);
  }
  void reset() {
    lp1.reset();
    lp2.reset();
    hp1.reset();
    hp2.reset();
  }
  inline void split(int ch, float x, float& low, float& high) {
    low = lp2.process(ch, lp1.process(ch, x));
    high = hp2.process(ch, hp1.process(ch, x));
  }
};

// ---------- трёхполосный эквалайзер ----------

struct Eq3 {
  LR4 x1, x2; // граница низов и середины, середины и верхов
  float lo = 1, mid = 1, hi = 1;
  float sl = 1, sm = 1, sh = 1; // сглаженные значения
  void init(double fs) {
    x1.set(fs, 250.0);
    x2.set(fs, 2500.0);
  }
  void reset() {
    x1.reset();
    x2.reset();
    sl = lo;
    sm = mid;
    sh = hi;
  }
  // buf — стерео, frames кадров
  void process(float* buf, int frames) {
    const float k = 0.01f; // сглаживание на кадр: без щелчков при вращении ручки
    for (int i = 0; i < frames; i++) {
      sl += (lo - sl) * k;
      sm += (mid - sm) * k;
      sh += (hi - sh) * k;
      for (int c = 0; c < 2; c++) {
        float low, rest, mi, hig;
        x1.split(c, buf[2 * i + c], low, rest);
        // Верхняя часть делится по второй границе; в одном канале используем одно звено на поток
        x2.split(c, rest, mi, hig);
        buf[2 * i + c] = low * sl + mi * sm + hig * sh;
      }
    }
  }
};

// ---------- DJ-фильтр: влево — срез верхов, вправо — срез низов ----------

struct DjFilter {
  Biquad f;
  float amount = 0, cur = 0; // -1 … 1
  double fs = 44100;
  int counter = 0;
  void process(float* buf, int frames) {
    if (std::fabs(amount) < 0.01f && std::fabs(cur) < 0.01f) {
      cur = 0;
      return;
    }
    for (int i = 0; i < frames; i++) {
      if (counter++ % 32 == 0) {
        cur += (amount - cur) * 0.08f;
        const double t = std::fabs(cur);
        // Экспоненциальное движение частоты среза: 20 кГц → 150 Гц влево, 20 Гц → 8 кГц вправо
        if (cur < 0) f.lowpass(fs, 20000.0 * std::pow(150.0 / 20000.0, t), 1.1);
        else f.highpass(fs, 20.0 * std::pow(8000.0 / 20.0, t), 1.1);
      }
      for (int c = 0; c < 2; c++) buf[2 * i + c] = f.process(c, buf[2 * i + c]);
    }
  }
};

// ---------- эффекты ----------

enum FxType { kFxNone = 0, kFxEcho = 1, kFxReverb = 2, kFxFlanger = 3 };

struct Delay {
  std::vector<float> b;
  int w = 0;
  void init(int n) {
    b.assign(static_cast<size_t>(std::max(n, 1)), 0.f);
    w = 0;
  }
  void clear() { std::fill(b.begin(), b.end(), 0.f); }
  inline float read(double d) const { // d — задержка в кадрах (дробная)
    const int n = static_cast<int>(b.size());
    double p = w - d;
    while (p < 0) p += n;
    const int i0 = static_cast<int>(p), i1 = (i0 + 1) % n;
    const float fr = static_cast<float>(p - i0);
    return b[static_cast<size_t>(i0 % n)] * (1 - fr) + b[static_cast<size_t>(i1)] * fr;
  }
  inline void write(float x) {
    b[static_cast<size_t>(w)] = x;
    if (++w >= static_cast<int>(b.size())) w = 0;
  }
};

// Эхо: задержка в миллисекундах, обратная связь с мягким срезом верхов
struct Echo {
  Delay d[2];
  float lpState[2] = {0, 0};
  double fs = 44100;
  float curDelay = 0;
  void init(double sr) {
    fs = sr;
    d[0].init(static_cast<int>(sr * 2.5));
    d[1].init(static_cast<int>(sr * 2.5));
    curDelay = 0;
  }
  void clear() {
    d[0].clear();
    d[1].clear();
    lpState[0] = lpState[1] = 0;
  }
  void process(float* buf, int frames, float mix, float delayMs, float feedback) {
    const float target = std::max(20.f, std::min(delayMs, 2000.f)) * static_cast<float>(fs) / 1000.f;
    if (curDelay == 0) curDelay = target;
    const float fb = std::min(0.92f, std::max(0.f, feedback));
    for (int i = 0; i < frames; i++) {
      curDelay += (target - curDelay) * 0.0005f; // плавная смена времени: без скрипа
      for (int c = 0; c < 2; c++) {
        const float dry = buf[2 * i + c];
        // «Пинг-понг»: правый канал слушает левую линию наоборот
        const float wet = d[c].read(curDelay);
        lpState[c] += (wet - lpState[c]) * 0.35f;
        d[c].write(dry + lpState[c] * fb);
        buf[2 * i + c] = dry + wet * mix;
      }
    }
  }
};

// Реверберация по схеме Schroeder/Moorer: 8 гребенчатых и 4 всепропускающих фильтра на канал
struct Reverb {
  struct Comb {
    std::vector<float> b;
    int i = 0;
    float store = 0;
    void init(int n) {
      b.assign(static_cast<size_t>(n), 0.f);
      i = 0;
      store = 0;
    }
    inline float process(float x, float fb, float damp) {
      const float out = b[static_cast<size_t>(i)];
      store = out * (1 - damp) + store * damp;
      b[static_cast<size_t>(i)] = x + store * fb;
      if (++i >= static_cast<int>(b.size())) i = 0;
      return out;
    }
  };
  struct Allpass {
    std::vector<float> b;
    int i = 0;
    void init(int n) {
      b.assign(static_cast<size_t>(n), 0.f);
      i = 0;
    }
    inline float process(float x) {
      const float bo = b[static_cast<size_t>(i)];
      const float out = -x + bo;
      b[static_cast<size_t>(i)] = x + bo * 0.5f;
      if (++i >= static_cast<int>(b.size())) i = 0;
      return out;
    }
  };
  Comb comb[2][8];
  Allpass ap[2][4];
  void init(double sr) {
    static const int ct[8] = {1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617};
    static const int at[4] = {556, 441, 341, 225};
    const double k = sr / 44100.0;
    for (int c = 0; c < 2; c++) {
      const int spread = c * 23;
      for (int j = 0; j < 8; j++) comb[c][j].init(static_cast<int>((ct[j] + spread) * k));
      for (int j = 0; j < 4; j++) ap[c][j].init(static_cast<int>((at[j] + spread) * k));
    }
  }
  void clear() {
    for (int c = 0; c < 2; c++) {
      for (auto& x : comb[c]) std::fill(x.b.begin(), x.b.end(), 0.f), x.store = 0;
      for (auto& x : ap[c]) std::fill(x.b.begin(), x.b.end(), 0.f);
    }
  }
  void process(float* buf, int frames, float mix, float room, float damp) {
    const float fb = 0.7f + 0.28f * std::min(1.f, std::max(0.f, room));
    const float dp = 0.05f + 0.6f * std::min(1.f, std::max(0.f, damp));
    for (int i = 0; i < frames; i++) {
      const float in = (buf[2 * i] + buf[2 * i + 1]) * 0.015f;
      for (int c = 0; c < 2; c++) {
        float o = 0;
        for (auto& cb : comb[c]) o += cb.process(in, fb, dp);
        for (auto& a : ap[c]) o = a.process(o);
        buf[2 * i + c] = buf[2 * i + c] * (1 - 0.5f * mix) + o * mix * 3.0f;
      }
    }
  }
};

// Флэнджер: короткая задержка, которой управляет медленный генератор
struct Flanger {
  Delay d[2];
  double fs = 44100, phase = 0;
  void init(double sr) {
    fs = sr;
    d[0].init(static_cast<int>(sr * 0.02));
    d[1].init(static_cast<int>(sr * 0.02));
    phase = 0;
  }
  void clear() {
    d[0].clear();
    d[1].clear();
  }
  void process(float* buf, int frames, float mix, float rateHz, float depth) {
    const double inc = 2 * kPi * std::max(0.02f, std::min(rateHz, 5.f)) / fs;
    const float dep = std::min(1.f, std::max(0.f, depth));
    for (int i = 0; i < frames; i++) {
      phase += inc;
      if (phase > 2 * kPi) phase -= 2 * kPi;
      for (int c = 0; c < 2; c++) {
        const double lfo = 0.5 + 0.5 * std::sin(phase + c * 1.5707963);
        const double ms = 0.3 + (1.0 + 5.0 * dep) * lfo; // 0,3…6,3 мс
        const float wet = d[c].read(ms * fs / 1000.0);
        const float dry = buf[2 * i + c];
        d[c].write(dry + wet * 0.55f);
        buf[2 * i + c] = dry + wet * mix;
      }
    }
  }
};

struct FxUnit {
  int type = kFxNone;
  int target = 0; // 0 — выключен, 1 — дека A, 2 — дека B, 3 — выход целиком
  float mix = 0, p1 = 0, p2 = 0;
  float smoothMix = 0;
  Echo echo;
  Reverb reverb;
  Flanger flanger;
  void init(double sr) {
    echo.init(sr);
    reverb.init(sr);
    flanger.init(sr);
  }
  void clearAll() {
    echo.clear();
    reverb.clear();
    flanger.clear();
  }
  void process(float* buf, int frames) {
    // Громкость эффекта меняется плавно; если он выключен и «хвост» затих — не считаем
    const float tgt = (target != 0 && type != kFxNone) ? mix : 0.f;
    if (tgt == 0.f && smoothMix < 0.002f) {
      smoothMix = 0;
      return;
    }
    smoothMix += (tgt - smoothMix) * std::min(1.f, 0.02f * (frames / 64.f + 1));
    switch (type) {
      case kFxEcho: echo.process(buf, frames, smoothMix, p1, p2); break;
      case kFxReverb: reverb.process(buf, frames, smoothMix, p1, p2); break;
      case kFxFlanger: flanger.process(buf, frames, smoothMix, p1, p2); break;
      default: break;
    }
  }
};

// ---------- растяжение времени (WSOLA) ----------

// Берёт кусочки исходника с шагом, зависящим от темпа, и склеивает их внахлёст так, чтобы волна совпала по фазе:
// темп меняется, высота — нет
struct Stretcher {
  static constexpr int HO = 512; // шаг выхода
  static constexpr int N = 2 * HO; // длина окна
  static constexpr int TOL = 192; // насколько искать совпадение вокруг ожидаемой позиции

  const float* src = nullptr; // стерео, чередуется
  int64_t frames = 0;
  double nominal = 0;
  int64_t prev = -1;
  float acc[N * 2];
  float win[N];
  bool init_ = false;

  Stretcher() {
    for (int i = 0; i < N; i++) win[i] = 0.5f * (1.f - std::cos(2.0 * kPi * i / N)); // периодическое окно Ханна: при шаге N/2 сумма = 1
    std::memset(acc, 0, sizeof acc);
  }

  void reset(const float* s, int64_t n, double pos) {
    src = s;
    frames = n;
    nominal = pos;
    prev = -1;
    std::memset(acc, 0, sizeof acc);
  }

  inline float mono(int64_t i) const { return (i < 0 || i >= frames) ? 0.f : 0.5f * (src[2 * i] + src[2 * i + 1]); }

  // Выдаёт HO кадров (стерео) в out; ratio — сколько кадров исходника на один кадр выхода
  void step(double ratio, float* out) {
    int64_t c = static_cast<int64_t>(nominal);
    if (prev >= 0) {
      const int64_t ref = prev + HO; // естественное продолжение предыдущего куска
      float best = -1e30f;
      int64_t bestC = c;
      for (int d = -TOL; d <= TOL; d += 2) {
        const int64_t cand = static_cast<int64_t>(nominal) + d;
        if (cand < 0) continue;
        float num = 0, en = 1e-9f;
        for (int i = 0; i < HO; i += 2) {
          const float a = mono(ref + i), b = mono(cand + i);
          num += a * b;
          en += b * b;
        }
        const float score = num / std::sqrt(en);
        if (score > best) {
          best = score;
          bestC = cand;
        }
      }
      c = bestC;
    }
    for (int i = 0; i < N; i++) {
      const int64_t p = c + i;
      if (p >= 0 && p < frames) {
        acc[2 * i] += win[i] * src[2 * p];
        acc[2 * i + 1] += win[i] * src[2 * p + 1];
      }
    }
    std::memcpy(out, acc, sizeof(float) * 2 * HO);
    std::memmove(acc, acc + 2 * HO, sizeof(float) * 2 * (N - HO));
    std::memset(acc + 2 * (N - HO), 0, sizeof(float) * 2 * HO);
    prev = c;
    nominal += HO * ratio;
  }
};

// Кубическая (Catmull-Rom) интерполяция
inline float cubic(float y0, float y1, float y2, float y3, float t) {
  const float a = -0.5f * y0 + 1.5f * y1 - 1.5f * y2 + 0.5f * y3;
  const float b = y0 - 2.5f * y1 + 2.f * y2 - 0.5f * y3;
  const float c = -0.5f * y0 + 0.5f * y2;
  return ((a * t + b) * t + c) * t + y1;
}

} // namespace dj

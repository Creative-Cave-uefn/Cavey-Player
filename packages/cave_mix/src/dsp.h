// DSP-блоки движка: фильтры, EQ-изолятор, лимитер. Всё работает в аудиопотоке без выделения памяти.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

namespace cm {

constexpr double kPi = 3.14159265358979323846;

inline double dbToGain(double db) { return std::pow(10.0, db / 20.0); }
inline double gainToDb(double g) { return g <= 1e-12 ? -240.0 : 20.0 * std::log10(g); }

// Биквад, транспонированная прямая форма II, стерео
struct Biquad {
  double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
  double z1[2] = {0, 0}, z2[2] = {0, 0};

  void reset() { z1[0] = z1[1] = z2[0] = z2[1] = 0; }

  // Формулы RBJ Audio EQ Cookbook
  void lowpass(double fs, double f, double q) {
    const double w = 2 * kPi * f / fs, c = std::cos(w), a = std::sin(w) / (2 * q), n = 1 + a;
    b0 = (1 - c) / 2 / n; b1 = (1 - c) / n; b2 = b0; a1 = -2 * c / n; a2 = (1 - a) / n;
  }
  void highpass(double fs, double f, double q) {
    const double w = 2 * kPi * f / fs, c = std::cos(w), a = std::sin(w) / (2 * q), n = 1 + a;
    b0 = (1 + c) / 2 / n; b1 = -(1 + c) / n; b2 = b0; a1 = -2 * c / n; a2 = (1 - a) / n;
  }

  inline double tick(int ch, double x) {
    const double y = b0 * x + z1[ch];
    z1[ch] = b1 * x - a1 * y + z2[ch];
    z2[ch] = b2 * x - a2 * y;
    return y;
  }
};

// Линквиц — Райли 4-го порядка = два Баттерворта 2-го порядка подряд
struct LR4 {
  Biquad s1, s2;
  void lowpass(double fs, double f) { s1.lowpass(fs, f, std::sqrt(0.5)); s2.lowpass(fs, f, std::sqrt(0.5)); }
  void highpass(double fs, double f) { s1.highpass(fs, f, std::sqrt(0.5)); s2.highpass(fs, f, std::sqrt(0.5)); }
  void reset() { s1.reset(); s2.reset(); }
  inline double tick(int ch, double x) { return s2.tick(ch, s1.tick(ch, x)); }
};

// Значение ручки EQ (−1…+1) → множитель полосы. −1 — полоса выключена полностью.
inline double eqKnobToGain(double v) {
  if (v <= -0.999) return 0.0;
  if (v >= 0) return dbToGain(6.0 * std::min(v, 1.0));
  return dbToGain(40.0 * v); // −0,5 → −20 дБ, −0,9 → −36 дБ
}

// 3-полосный изолятор на кроссоверах Линквица — Райли 4-го порядка (24 дБ/окт).
// Низ = LP(f1); остаток HP(f1) делится на середину LP(f2) и верх HP(f2); низ дополнительно
// проходит через фазовый корректор f2 (= LP(f2)+HP(f2)), поэтому у всех полос одинаковая фаза:
// при нейтральных ручках сумма — всепропускающий фильтр (амплитуда ровная), а выключенная полоса
// гасится по-настоящему (60 Гц при срезе 200 Гц — около −40 дБ).
struct Isolator {
  LR4 lo1, hi1, lo2, hi2, apLo, apHi;
  double fs = 48000;
  void setup(double sampleRate) {
    fs = sampleRate;
    lo1.lowpass(fs, 200.0);  hi1.highpass(fs, 200.0);
    lo2.lowpass(fs, 2500.0); hi2.highpass(fs, 2500.0);
    apLo.lowpass(fs, 2500.0); apHi.highpass(fs, 2500.0);
    reset();
  }
  void reset() { lo1.reset(); hi1.reset(); lo2.reset(); hi2.reset(); apLo.reset(); apHi.reset(); }
  inline double tick(int ch, double x, double gl, double gm, double gh) {
    const double l0 = lo1.tick(ch, x);
    const double h0 = hi1.tick(ch, x);
    const double l = apLo.tick(ch, l0) + apHi.tick(ch, l0);
    const double m = lo2.tick(ch, h0);
    const double h = hi2.tick(ch, h0);
    return gl * l + gm * m + gh * h;
  }
};

// Фильтр на одной ручке: −1…0 — низких частот, 0…+1 — высоких. Около нуля — без обработки.
struct OneKnobFilter {
  Biquad lp, hp;
  double fs = 48000;
  double lastKnob = 0, lastRes = -1;
  void setup(double sampleRate) { fs = sampleRate; lp.reset(); hp.reset(); lastKnob = 0; lastRes = -1; }

  // Пересчёт коэффициентов (вызывается раз в 32 сэмпла)
  void update(double knob, double res) {
    if (knob == lastKnob && res == lastRes) return;
    lastKnob = knob; lastRes = res;
    const double q = 0.707 + 3.3 * std::clamp(res, 0.0, 1.0);
    const double a = std::abs(knob);
    // Экспоненциальная шкала частот — так ручка звучит равномерно
    const double fLp = 20000.0 * std::pow(80.0 / 20000.0, a);
    const double fHp = 20.0 * std::pow(8000.0 / 20.0, a);
    lp.lowpass(fs, std::min(fLp, fs * 0.45), q);
    hp.highpass(fs, fHp, q);
  }

  // Сухой/мокрый сигнал плавно смешиваются в зоне |knob| < 0.05, чтобы 0 был точно прозрачным
  inline double tick(int ch, double x) {
    const double a = std::abs(lastKnob);
    const double yl = lp.tick(ch, x), yh = hp.tick(ch, x); // оба фильтра работают всегда — без щелчков при смене знака
    if (a < 1e-6) return x;
    const double wet = std::min(1.0, a / 0.05);
    const double y = lastKnob < 0 ? yl : yh;
    return x + (y - x) * wet;
  }
};

// Сглаживание параметра: линейно к цели за заданное число сэмплов
struct Smoothed {
  double cur = 0, target = 0, step = 0;
  int left = 0;
  void jump(double v) { cur = target = v; left = 0; step = 0; }
  void set(double v, int samples) {
    if (v == target) return;
    target = v;
    if (samples <= 0) { cur = v; left = 0; return; }
    left = samples;
    step = (target - cur) / samples;
  }
  inline double next() {
    if (left > 0) { cur += step; if (--left == 0) cur = target; }
    return cur;
  }
};

// Лимитер мастера с упреждением: ослабление начинается заранее и плавно,
// поэтому пик не проходит выше потолка, а усиление не скачет.
// Схема: требуемое усиление → минимум за окно L → сглаживание окном L → медленное восстановление.
class Limiter {
 public:
  void setup(double fs, double ceilingDb = -1.0, double lookaheadMs = 5.0, double releaseMs = 80.0) {
    ceiling_ = dbToGain(ceilingDb);
    L_ = std::max(1, (int)std::lround(fs * lookaheadMs / 1000.0));
    delay_.assign((size_t)L_ * 2, 0.0f);
    box_.assign((size_t)L_, 1.0);
    boxSum_ = L_;
    rel_ = 1.0;
    relCoef_ = 1.0 - std::exp(-1.0 / (fs * releaseMs / 1000.0));
    // монотонная очередь для скользящего минимума
    dqIdx_.assign((size_t)L_ + 3, 0);
    dqVal_.assign((size_t)L_ + 3, 1.0);
    dqHead_ = dqTail_ = 0;
    n_ = 0;
    gain_ = 1.0;
  }
  int latency() const { return L_; }
  double gain() const { return gain_; }

  // Обработать стерео-кадр на месте
  inline void tick(float &l, float &r) {
    const double peak = std::max(std::abs((double)l), std::abs((double)r));
    const double need = peak > ceiling_ ? ceiling_ / peak : 1.0;

    // скользящий минимум need за последние L+1 сэмплов
    while (dqTail_ != dqHead_ && dqVal_[prev(dqTail_)] >= need) dqTail_ = prev(dqTail_);
    dqIdx_[dqTail_] = n_;
    dqVal_[dqTail_] = need;
    dqTail_ = nextI(dqTail_);
    // окно L+1 сэмплов: тогда сглаженное усиление гарантированно не выше нужного для сэмпла, выходящего из задержки
    while (dqIdx_[dqHead_] < n_ - L_) dqHead_ = nextI(dqHead_);
    const double held = dqVal_[dqHead_];

    // сглаживание окном L: результат не выше held в момент пика
    const size_t bi = (size_t)(n_ % L_);
    boxSum_ += held - box_[bi];
    box_[bi] = held;
    double g = boxSum_ / L_;
    if (g > 1.0) g = 1.0;

    // медленное восстановление
    if (g < rel_) rel_ = g; else rel_ += (g - rel_) * relCoef_;
    gain_ = rel_;

    // задержка сигнала на L
    const size_t di = (size_t)(n_ % L_) * 2;
    const float dl = delay_[di], dr = delay_[di + 1];
    delay_[di] = l; delay_[di + 1] = r;
    l = (float)(dl * gain_);
    r = (float)(dr * gain_);
    // страховка: из-за округлений пик не должен превысить потолок
    if (std::abs(l) > ceiling_) l = (float)std::copysign(ceiling_, l);
    if (std::abs(r) > ceiling_) r = (float)std::copysign(ceiling_, r);
    ++n_;
  }

 private:
  size_t prev(size_t i) const { return i == 0 ? dqIdx_.size() - 1 : i - 1; }
  size_t nextI(size_t i) const { return i + 1 == dqIdx_.size() ? 0 : i + 1; }

  double ceiling_ = 0.89;
  int L_ = 240;
  std::vector<float> delay_;
  std::vector<double> box_;
  double boxSum_ = 0;
  double rel_ = 1, relCoef_ = 0.001, gain_ = 1;
  std::vector<long long> dqIdx_;
  std::vector<double> dqVal_;
  size_t dqHead_ = 0, dqTail_ = 0;
  long long n_ = 0;
};

// Эхо деки: задержка до 2 с с обратной связью; в петле срезаны низ (300 Гц) и верх (5 кГц), чтобы повторы
// не гудели и мягко темнели. Работает всегда, поэтому хвост доигрывает и после остановки деки.
class Echo {
 public:
  void setup(double fs) {
    fs_ = fs;
    buf_.assign((size_t)(fs * 2.05) * 2, 0.0f);
    w_ = 0;
    hp_.highpass(fs, 300.0, 0.707);
    lp_.lowpass(fs, 5000.0, 0.707);
    time_.jump(0.375 * fs);
  }
  // send — посыл деки (стерео), out — куда прибавить выход эха
  void process(const float *send, float *out, int n, double timeSec, double feedback) {
    const size_t len = buf_.size() / 2;
    time_.set(std::clamp(timeSec, 0.02, 2.0) * fs_, (int)(fs_ / 20));  // смена времени — плавно, за 50 мс
    const double fb = std::clamp(feedback, 0.0, 0.95);
    bool silentIn = true;
    for (int i = 0; i < n * 2; ++i) if (send[i] != 0.0f) { silentIn = false; break; }
    // пока в задержке может что-то звучать, считаем; после долгой тишины на входе и в выходе — нет
    if (!silentIn) quiet_ = 0;
    const long long len2 = (long long)(buf_.size() / 2);
    if (silentIn && quiet_ > len2 && sinceLoud_ > len2) return;
    for (int i = 0; i < n; ++i) {
      const double d = time_.next();
      double rp = (double)w_ - d;
      while (rp < 0) rp += (double)len;
      const size_t i0 = (size_t)rp % len, i1 = (i0 + 1) % len;
      const double fr = rp - std::floor(rp);
      double y[2];
      for (int ch = 0; ch < 2; ++ch) {
        y[ch] = buf_[i0 * 2 + ch] * (1 - fr) + buf_[i1 * 2 + ch] * fr;
        const double fbk = lp_.tick(ch, hp_.tick(ch, y[ch])) * fb;
        buf_[w_ * 2 + ch] = (float)(send[i * 2 + ch] + fbk);
        out[i * 2 + ch] += (float)y[ch];
        if (std::abs(y[ch]) > 1e-5) sinceLoud_ = 0;
      }
      ++sinceLoud_;
      w_ = (w_ + 1) % len;
    }
    if (silentIn) quiet_ += n;
  }

 private:
  double fs_ = 48000;
  std::vector<float> buf_;
  size_t w_ = 0;
  Biquad hp_, lp_;
  Smoothed time_;
  long long quiet_ = 1LL << 40;      // сколько сэмплов подряд вход молчит
  long long sinceLoud_ = 1LL << 40;  // сколько сэмплов подряд выход эха тише −100 дБ
};

// Реверберация Freeverb (Jezar, общественное достояние): 8 гребенчатых фильтров с демпфированием и 4 всепропускающих
// на канал, правый канал разнесён на 23 сэмпла. Посыл до фейдера, как у эха: хвост звучит и после остановки деки.
// На входе срез ниже 250 Гц — бас в ревербе превращается в гул.
class Reverb {
 public:
  void setup(double fs) {
    fs_ = fs;
    static const int combT[8] = {1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617};
    static const int apT[4] = {556, 441, 341, 225};
    const double k = fs / 44100.0;
    for (int ch = 0; ch < 2; ++ch) {
      const int spread = ch ? 23 : 0;
      for (int i = 0; i < 8; ++i) { comb_[ch][i].buf.assign((size_t)std::max(1.0, (combT[i] + spread) * k), 0.0f); comb_[ch][i].i = 0; comb_[ch][i].store = 0; }
      for (int i = 0; i < 4; ++i) { ap_[ch][i].buf.assign((size_t)std::max(1.0, (apT[i] + spread) * k), 0.0f); ap_[ch][i].i = 0; }
    }
    hp_.highpass(fs, 250.0, 0.707);
    sinceLoud_ = quiet_ = 1LL << 40;
  }
  // room 0…1 — длина хвоста, damp 0…1 — глушение верхов
  void process(const float *send, float *out, int n, double room = 0.88, double damp = 0.35) {
    bool silentIn = true;
    for (int i = 0; i < n * 2; ++i) if (send[i] != 0.0f) { silentIn = false; break; }
    if (!silentIn) quiet_ = 0;
    const long long tail = (long long)(fs_ * 12);  // хвост не дольше ~12 с
    if (silentIn && quiet_ > tail && sinceLoud_ > (long long)fs_) return;
    const double fb = 0.7 + 0.28 * std::clamp(room, 0.0, 1.0);
    const double d1 = 0.4 * std::clamp(damp, 0.0, 1.0), d2 = 1 - d1;
    for (int i = 0; i < n; ++i) {
      const double in = (hp_.tick(0, send[i * 2]) + hp_.tick(1, send[i * 2 + 1])) * 0.015;
      double y[2];
      for (int ch = 0; ch < 2; ++ch) {
        double acc = 0;
        for (auto &c : comb_[ch]) {
          const double o = c.buf[c.i];
          c.store = o * d2 + c.store * d1;
          c.buf[c.i] = (float)(in + c.store * fb);
          if (++c.i >= c.buf.size()) c.i = 0;
          acc += o;
        }
        for (auto &a : ap_[ch]) {
          const double b = a.buf[a.i];
          a.buf[a.i] = (float)(acc + b * 0.5);
          acc = b - acc;
          if (++a.i >= a.buf.size()) a.i = 0;
        }
        y[ch] = acc;
      }
      out[i * 2] += (float)(y[0] * kWet);
      out[i * 2 + 1] += (float)(y[1] * kWet);
      if (std::abs(y[0]) > 1e-5 || std::abs(y[1]) > 1e-5) sinceLoud_ = 0; else ++sinceLoud_;
    }
    if (silentIn) quiet_ += n;
  }

 private:
  static constexpr double kWet = 3.0;
  struct Comb { std::vector<float> buf; size_t i = 0; double store = 0; };
  struct Ap { std::vector<float> buf; size_t i = 0; };
  double fs_ = 48000;
  Comb comb_[2][8];
  Ap ap_[2][4];
  Biquad hp_;
  long long quiet_ = 1LL << 40, sinceLoud_ = 1LL << 40;
};

// «Торможение пластинки»: звук деки замедляется до остановки, высота падает вместе со скоростью.
// Вход идёт с обычной скоростью и копится в буфере, выход читает его всё медленнее (кубическая интерполяция).
class TapeStop {
 public:
  void setup(double fs) { fs_ = fs; buf_.assign((size_t)(fs * 8) * 2, 0.0f); active_ = false; }
  void start(double durSec) {
    active_ = true; done_ = false;
    len_ = std::max(0.05, durSec) * fs_;
    t_ = 0; w_ = 0; rp_ = 0;
  }
  void stop() { active_ = false; done_ = false; }
  bool active() const { return active_; }
  bool done() const { return done_; }
  // в L/R — n кадров деки; на выходе — замедленный звук
  void process(float *L, float *R, int n) {
    if (!active_) return;
    const size_t cap = buf_.size() / 2;
    for (int i = 0; i < n; ++i) {
      if (w_ < cap) { buf_[w_ * 2] = L[i]; buf_[w_ * 2 + 1] = R[i]; ++w_; }
      if (done_) { L[i] = R[i] = 0; continue; }
      const double x = t_ / len_;
      if (x >= 1) { done_ = true; L[i] = R[i] = 0; continue; }
      // скорость падает быстрее к концу, как у остановленного диска; громкость гаснет в последней четверти
      const double speed = std::pow(1 - x, 1.4);
      const double amp = x < 0.75 ? 1.0 : std::cos((x - 0.75) / 0.25 * 1.5707963267948966);
      const size_t i1 = (size_t)rp_;
      const double fr = rp_ - (double)i1;
      for (int ch = 0; ch < 2; ++ch) {
        auto at = [&](size_t k) { return k < w_ ? (double)buf_[k * 2 + ch] : 0.0; };
        const double y0 = at(i1 > 0 ? i1 - 1 : 0), y1 = at(i1), y2 = at(i1 + 1), y3 = at(i1 + 2);
        // Катмулл — Ром
        const double v = y1 + 0.5 * fr * (y2 - y0 + fr * (2 * y0 - 5 * y1 + 4 * y2 - y3 + fr * (3 * (y1 - y2) + y3 - y0)));
        (ch ? R : L)[i] = (float)(v * amp);
      }
      rp_ += speed;
      t_ += 1;
    }
  }

 private:
  double fs_ = 48000;
  std::vector<float> buf_;
  bool active_ = false, done_ = false;
  double len_ = 1, t_ = 0, rp_ = 0;
  size_t w_ = 0;
};

// Спинбэк: диджей рукой рвёт пластинку назад. Скорость за 60 мс уходит с +1 до −2,5 (рывок), затем назад всё
// медленнее до остановки; звук — то, что только что играло, задом наперёд (высота растёт и падает со скоростью).
// Громкость гаснет в последних 40 %.
class Backspin {
 public:
  void setup(double fs) { fs_ = fs; buf_.assign((size_t)(fs * 3.5) * 2, 0.0f); active_ = done_ = false; }
  // hist — недавний звук деки (старые кадры раньше), frames — сколько его
  void start(const float *hist, size_t frames, double durSec) {
    const size_t cap = buf_.size() / 2;
    n_ = std::min(frames, cap);
    std::copy(hist + (frames - n_) * 2, hist + frames * 2, buf_.begin());
    rp_ = (double)n_ - 1;
    len_ = std::max(0.2, durSec) * fs_;
    t_ = 0;
    active_ = true; done_ = false;
  }
  void stop() { active_ = done_ = false; }
  bool active() const { return active_; }
  bool done() const { return done_; }
  void process(float *L, float *R, int n) {
    if (!active_) return;
    const double grab = 0.06 * fs_;
    for (int i = 0; i < n; ++i) {
      if (done_) { L[i] = R[i] = 0; continue; }
      const double x = t_ / len_;
      if (x >= 1 || rp_ < 2) { done_ = true; L[i] = R[i] = 0; continue; }
      double speed;
      if (t_ < grab) {
        const double y = t_ / grab;
        speed = 1.0 - 3.5 * y * y * (3 - 2 * y);
      } else {
        const double y = (t_ - grab) / std::max(1.0, len_ - grab);
        speed = -2.5 * std::pow(1 - y, 1.6);
      }
      const double amp = x < 0.6 ? 1.0 : std::cos((x - 0.6) / 0.4 * 1.5707963267948966);
      const size_t i1 = (size_t)rp_;
      const double fr = rp_ - (double)i1;
      for (int ch = 0; ch < 2; ++ch) {
        auto at = [&](size_t k) { return k < n_ ? (double)buf_[k * 2 + ch] : 0.0; };
        const double y0 = at(i1 > 0 ? i1 - 1 : 0), y1 = at(i1), y2 = at(i1 + 1), y3 = at(i1 + 2);
        const double v = y1 + 0.5 * fr * (y2 - y0 + fr * (2 * y0 - 5 * y1 + 4 * y2 - y3 + fr * (3 * (y1 - y2) + y3 - y0)));
        (ch ? R : L)[i] = (float)(v * amp);
      }
      rp_ = std::min(rp_ + speed, (double)n_ - 2);
      t_ += 1;
    }
  }

 private:
  double fs_ = 48000;
  std::vector<float> buf_;
  size_t n_ = 0;
  bool active_ = false, done_ = false;
  double len_ = 1, t_ = 0, rp_ = 0;
};

// Луп-ролл: с момента старта звук деки повторяется кусками, которые укорачиваются вдвое: половину ролла — по доле,
// четверть — по полдоли, восьмую — по четверти, последнюю восьмую — по восьмой. Каждый повтор начинается на сетке
// (с того же места, где начался ролл); края повторов сглажены (1,3 мс), чтобы не щёлкали.
class BeatRoll {
 public:
  void setup(double fs) { fs_ = fs; buf_.assign((size_t)(fs * 4) * 2, 0.0f); active_ = done_ = false; }
  void start(double beatFrames, double beats) {
    beat_ = std::max(1000.0, beatFrames);
    total_ = std::max(1.0, beats) * beat_;
    t_ = 0; w_ = 0;
    active_ = true; done_ = false;
  }
  void stop() { active_ = done_ = false; }
  bool active() const { return active_; }
  bool done() const { return done_; }
  void process(float *L, float *R, int n) {
    if (!active_) return;
    const size_t cap = buf_.size() / 2;
    const double edge = 0.0013 * fs_;
    for (int i = 0; i < n; ++i) {
      if (w_ < cap) { buf_[w_ * 2] = L[i]; buf_[w_ * 2 + 1] = R[i]; ++w_; }
      if (done_) { L[i] = R[i] = 0; continue; }
      if (t_ >= total_) { done_ = true; L[i] = R[i] = 0; continue; }
      const double x = t_ / total_;
      const double slice = x < 0.5 ? beat_ : x < 0.75 ? beat_ / 2 : x < 0.875 ? beat_ / 4 : beat_ / 8;
      const double r = std::fmod(t_, slice);
      const size_t k = std::min((size_t)r, w_ ? w_ - 1 : 0);
      const double g = std::min({1.0, (r + 1) / edge, (slice - r) / edge});
      L[i] = (float)(buf_[k * 2] * g);
      R[i] = (float)(buf_[k * 2 + 1] * g);
      t_ += 1;
    }
  }

 private:
  double fs_ = 48000, beat_ = 24000, total_ = 0, t_ = 0;
  std::vector<float> buf_;
  size_t w_ = 0;
  bool active_ = false, done_ = false;
};

// Удары бочки в звуке деки: полоса 40…160 Гц, огибающая энергии (сглаживание 5 мс — длиннее полупериода баса,
// иначе огибающая «дрожит» с частотой самого баса), «атака» — подъём огибающей за 10 мс больше чем на 4 дБ;
// на атаку — одна точка (самый резкий подъём серии), следующая — не раньше чем через 60 мс.
class KickOnsets {
 public:
  void setup(int sr) {
    hop_ = std::max(16, sr / 1000);
    a_ = 1.0 - std::exp(-1.0 / (0.005 * sr));
    lp_.lowpass(sr, 160, std::sqrt(0.5));
    hp_.highpass(sr, 40, std::sqrt(0.5));
    reset();
  }
  void reset() {
    lp_.reset(); hp_.reset();
    env_ = 0; cnt_ = 0;
    for (double &h : hist_) h = -10;
    hi_ = 0;
    best_ = 0;
    quietUntil_ = INT64_MIN;
  }
  // x — моно, кадры [clock, clock+n); onset(кадр, сила) — на каждую атаку
  template <class F> void feed(const float *x, int n, int64_t clock, F &&onset) {
    for (int i = 0; i < n; ++i) {
      const double y = hp_.tick(0, lp_.tick(0, x[i]));
      env_ += a_ * (y * y - env_);
      if (++cnt_ < hop_) continue;
      cnt_ = 0;
      const double e = std::log10(env_ + 1e-10);
      const double prev = hist_[(hi_ + kH - 10) % kH];  // 10 окон (мс) назад
      hist_[hi_] = e;
      hi_ = (hi_ + 1) % kH;
      const double rise = e - prev;  // в десятках дБ
      const int64_t t = clock + i - hop_ * 5;  // середина окна подъёма
      if (rise > 0.4 && e > -5 && t >= quietUntil_) {
        if (rise > best_) { best_ = rise; bestAt_ = t; }
      } else if (best_ > 0) {
        onset(bestAt_, best_);
        quietUntil_ = bestAt_ + hop_ * 60;
        best_ = 0;
      }
    }
  }

 private:
  static constexpr int kH = 16;
  Biquad lp_, hp_;
  int hop_ = 48, cnt_ = 0, hi_ = 0;
  double a_ = 0.004, env_ = 0, best_ = 0;
  int64_t bestAt_ = 0, quietUntil_ = 0;
  double hist_[kH];
};

// Подстройка фазы ведомой деки к ведущей по ударам. Атаки обеих дек раскладываются по положению внутри доли
// (гистограмма по 1 мс, период — доля в кадрах выхода); раз в 8 долей (первый раз — через 4) гистограммы
// сравниваются круговой взаимной корреляцией: её максимум — на сколько удары ведомой отстают. Если у обеих
// удары собраны в одном месте доли и расхождение больше 3–4 мс — ведомой деке заказывается сдвиг: она чуть
// ускоряется или замедляется, пока его не выберет; затем окно копится заново.
class BeatSync {
 public:
  struct Shift { double frames = 0; double rate = 0; };  // сдвиг ведомой (кадры выхода, + — раньше) и скорость

  void setup(int sr) {
    sr_ = sr;
    ref_.setup(sr); fol_.setup(sr);
    msF_ = sr / 1000.0;
    const size_t cap = (size_t)(3.2 * 1000) + 8;  // доля до 3 с
    hR_.assign(cap, 0.0); hF_.assign(cap, 0.0); sR_.assign(cap, 0.0); sF_.assign(cap, 0.0);
  }
  void start(int64_t from, int64_t to, double beatFrames) {
    from_ = from; to_ = to; beat_ = beatFrames;
    nb_ = (int)std::min<double>((double)hR_.size(), std::ceil(beatFrames / msF_));
    active_ = beatFrames > 0 && to > from && nb_ >= 100;
    ref_.reset(); fol_.reset();
    clearAcc();
    nextDecision_ = from + (int64_t)(4 * beatFrames);
    busyUntil_ = -1;
    corrections = measured = 0;
    firstMs = lastMs = shiftMs = conf = 0;
  }
  void stop() { active_ = false; }
  bool active() const { return active_; }
  bool covers(int64_t clock, int n) const { return active_ && clock + n > from_ && clock < to_; }

  // Куски звука обеих дек (моно, до EQ и громкости) за кадры [clock, clock+n). Возвращает заказанный сдвиг.
  Shift feed(const float *ref, const float *fol, int n, int64_t clock) {
    Shift out;
    if (!active_) return out;
    if (clock >= to_) { active_ = false; return out; }
    const bool settle = clock < busyUntil_;
    ref_.feed(ref, n, clock, [&](int64_t t, double w) { if (!settle) add(hR_, nR_, t, w); });
    fol_.feed(fol, n, clock, [&](int64_t t, double w) { if (!settle) add(hF_, nF_, t, w); });
    if (clock + n < nextDecision_) return out;
    nextDecision_ = clock + n + (int64_t)(8 * beat_);
    smooth(hR_, sR_);
    smooth(hF_, sF_);
    const double cR = focus(sR_), cF = focus(sF_);
    const bool ok = nR_ >= 3 && nF_ >= 3 && cR > 0.35 && cF > 0.35;
    double ms = 0;
    if (ok) {
      // круговая взаимная корреляция, сдвиги в пределах ±полдоли
      int best = 0;
      double bestV = -1, vm = 0, vp = 0;
      std::vector<double> &cc = hR_;  // гистограмма уже сглажена — её место свободно под корреляцию
      for (int lag = -nb_ / 2; lag < nb_ / 2; ++lag) {
        double v = 0;
        for (int i = 0; i < nb_; ++i) v += sR_[(size_t)i] * sF_[(size_t)(((i + lag) % nb_ + nb_) % nb_)];
        cc[(size_t)(lag + nb_ / 2)] = v;
        if (v > bestV) { bestV = v; best = lag; }
      }
      const int bi = best + nb_ / 2;
      if (bi > 0 && bi + 1 < nb_) { vm = cc[(size_t)bi - 1]; vp = cc[(size_t)bi + 1]; }
      double frac = 0;
      const double den = vm - 2 * bestV + vp;
      if (den < 0) frac = std::clamp(0.5 * (vm - vp) / den, -0.5, 0.5);
      ms = best + frac;  // бины — по 1 мс; + — ведомая опаздывает
      if (measured == 0) firstMs = ms;
      lastMs = ms;
      conf = std::min(cR, cF);
      ++measured;
      if (std::abs(ms) > (measured == 1 ? 3.0 : 4.0)) {
        // не быстрее 3 % (на больших ошибках — до 6 %); уточнения — не целиком, без раскачки
        const double rate = std::abs(ms) > 30 ? 0.06 : 0.03;
        const double dFrames = ms * msF_;
        out.frames = measured == 1 ? dFrames : 0.8 * dFrames;
        out.rate = rate;
        ++corrections;
        shiftMs += out.frames / msF_;
        const double dur = std::abs(out.frames) / rate;
        busyUntil_ = clock + n + (int64_t)(dur + beat_);  // пока сдвиг идёт и ещё доля — не копим
        nextDecision_ = busyUntil_ + (int64_t)(8 * beat_);
      }
    }
    clearAcc();
    return out;
  }

  // итоги (для журнала)
  int corrections = 0, measured = 0;
  double firstMs = 0, lastMs = 0, shiftMs = 0, conf = 0;

 private:
  void clearAcc() {
    std::fill(hR_.begin(), hR_.end(), 0.0);
    std::fill(hF_.begin(), hF_.end(), 0.0);
    nR_ = nF_ = 0;
  }
  void add(std::vector<double> &h, int &cnt, int64_t t, double weight) {
    double ph = std::fmod((double)(t - from_), beat_);
    if (ph < 0) ph += beat_;
    const int b = std::min(nb_ - 1, (int)(ph / msF_));
    h[(size_t)b] += weight * weight;  // резкие атаки (бочка) весомее
    ++cnt;
  }
  // круговое сглаживание гауссом σ = 2 мс
  void smooth(const std::vector<double> &h, std::vector<double> &o) const {
    static const double k[7] = {0.105, 0.198, 0.288, 0.326, 0.288, 0.198, 0.105};
    for (int i = 0; i < nb_; ++i) {
      double v = 0;
      for (int j = -3; j <= 3; ++j) v += k[j + 3] * h[(size_t)(((i + j * 2 / 2) % nb_ + nb_) % nb_)];
      o[(size_t)i] = v;
    }
  }
  // доля веса в ±10 мс от пика (насколько удары собраны в одном месте доли)
  double focus(const std::vector<double> &o) const {
    int pk = 0;
    double tot = 0;
    for (int i = 0; i < nb_; ++i) { tot += o[(size_t)i]; if (o[(size_t)i] > o[(size_t)pk]) pk = i; }
    if (tot <= 0) return 0;
    double near = 0;
    for (int j = -10; j <= 10; ++j) near += o[(size_t)(((pk + j) % nb_ + nb_) % nb_)];
    return near / tot;
  }

  int sr_ = 48000;
  KickOnsets ref_, fol_;
  bool active_ = false;
  int64_t from_ = 0, to_ = 0, nextDecision_ = 0, busyUntil_ = -1;
  double beat_ = 0, msF_ = 48;
  int nb_ = 0;
  std::vector<double> hR_, hF_, sR_, sF_;
  int nR_ = 0, nF_ = 0;
};

}  // namespace cm

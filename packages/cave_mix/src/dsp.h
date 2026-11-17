// DSP-блоки движка: фильтры, EQ-изолятор, лимитер. Всё работает в аудиопотоке без выделения памяти.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>

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

}  // namespace cm

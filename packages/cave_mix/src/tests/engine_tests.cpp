// Нативные тесты Cavey Mix: движок работает офлайн, звук сверяется с ожиданием численно.
// Запуск: cave_mix_tests [папка_для_wav]. Код возврата 0 — все тесты прошли.

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <string>
#include <thread>
#include <vector>

#include "../cave_mix.h"

static std::string g_dir = ".";
static int g_failed = 0;

#define CHECK(cond, ...)                         \
  do {                                           \
    if (!(cond)) {                               \
      std::printf("    FAIL: " __VA_ARGS__);     \
      std::printf("\n");                         \
      ++g_failed;                                \
      return;                                    \
    }                                            \
  } while (0)

// ------------------------------------------------------------------ WAV (float 32)

static void writeWav(const std::string &path, const std::vector<float> &st, int rate) {
  FILE *f = std::fopen(path.c_str(), "wb");
  const uint32_t frames = (uint32_t)(st.size() / 2), data = frames * 8;
  auto w32 = [&](uint32_t v) { std::fwrite(&v, 4, 1, f); };
  auto w16 = [&](uint16_t v) { std::fwrite(&v, 2, 1, f); };
  std::fwrite("RIFF", 1, 4, f); w32(36 + data); std::fwrite("WAVE", 1, 4, f);
  std::fwrite("fmt ", 1, 4, f); w32(16); w16(3); w16(2); w32(rate); w32(rate * 8); w16(8); w16(32);
  std::fwrite("data", 1, 4, f); w32(data);
  std::fwrite(st.data(), 4, st.size(), f);
  std::fclose(f);
}

static std::string path(const char *name) { return g_dir + "/" + name; }

// ------------------------------------------------------------------ помощники

struct Rig {
  cm_engine *e = nullptr;
  std::vector<float> out;  // весь отрендеренный звук
  explicit Rig(int rate = 48000) { e = cm_create(rate, 1); }
  ~Rig() { cm_destroy(e); }
  cm_state state() { cm_state s; cm_get_state(e, &s); return s; }
  void render(int frames) {
    std::vector<float> buf((size_t)frames * 2);
    int done = 0;
    while (done < frames) {
      const int n = std::min(512, frames - done);
      cm_render(e, buf.data() + (size_t)done * 2, n);
      done += n;
      // даём декодеру время: офлайн-рендер быстрее реального времени
      std::this_thread::sleep_for(std::chrono::microseconds(300));
    }
    out.insert(out.end(), buf.begin(), buf.end());
  }
  // ждать, пока дека загрузится и наберёт буфер
  bool waitReady(int deck, int minMs = 1500) {
    for (int i = 0; i < 2000; ++i) {
      render(256);
      cm_state s = state();
      if (s.deck[deck].status == CM_ERROR) return false;
      if (s.deck[deck].status == CM_READY && s.deck[deck].buffered_ms >= minMs) return true;
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return false;
  }
  int64_t clock() { return state().clock; }
};

static const int kLim = 240;  // задержка лимитера при 48 кГц (5 мс)

static std::vector<float> noise(int frames, float amp, unsigned seed) {
  std::vector<float> v((size_t)frames * 2);
  unsigned x = seed;
  for (auto &s : v) { x = x * 1664525u + 1013904223u; s = amp * ((x >> 8) / 8388608.0f - 1.0f); }
  return v;
}

static std::vector<float> sine(int frames, int rate, double hz, float amp) {
  std::vector<float> v((size_t)frames * 2);
  for (int i = 0; i < frames; ++i) v[i * 2] = v[i * 2 + 1] = (float)(amp * std::sin(2 * M_PI * hz * i / rate));
  return v;
}

// клики: короткая пачка 2 кГц длиной 4 мс; channel: 0 — только левый, 1 — только правый, 2 — оба
static std::vector<float> clicks(int frames, int rate, double firstSec, double bpm, int channel) {
  std::vector<float> v((size_t)frames * 2, 0.0f);
  const double period = 60.0 / bpm;
  for (double t = firstSec; t * rate < frames - rate * 0.01; t += period) {
    const int s = (int)std::llround(t * rate);
    for (int i = 0; i < rate * 4 / 1000; ++i) {
      const float x = (float)(0.8 * std::sin(2 * M_PI * 2000.0 * i / rate));
      if (channel != 1) v[(size_t)(s + i) * 2] = x;
      if (channel != 0) v[(size_t)(s + i) * 2 + 1] = x;
    }
  }
  return v;
}

// начала кликов в канале ch: первый сэмпл выше порога после тишины ≥ 50 мс
static std::vector<double> onsets(const std::vector<float> &st, int ch, int rate, double thr = 0.2) {
  std::vector<double> r;
  long long quietSince = -100000;
  bool inClick = false;
  const long long n = (long long)st.size() / 2;
  for (long long i = 0; i < n; ++i) {
    const float a = std::abs(st[(size_t)i * 2 + ch]);
    if (a > thr) {
      if (!inClick && i - quietSince > rate / 20) r.push_back((double)i / rate);
      inClick = true;
      quietSince = i;
    } else if (inClick && i - quietSince > rate / 100) {
      inClick = false;
    }
  }
  return r;
}

static double rms(const std::vector<float> &st, size_t fromFrame, size_t toFrame) {
  double s = 0;
  for (size_t i = fromFrame; i < toFrame; ++i) s += st[i * 2] * (double)st[i * 2];
  return std::sqrt(s / std::max<size_t>(1, toFrame - fromFrame));
}

// ------------------------------------------------------------------ тесты

// Темп 1.0: звук проходит бит-в-бит и стартует точно в заданном кадре
static void testTransparentAndExactStart() {
  const int sr = 48000;
  auto src = noise(sr * 3, 0.3f, 7);
  writeWav(path("noise48.wav"), src, sr);
  Rig r;
  CHECK(cm_load(r.e, 0, path("noise48.wav").c_str(), 0.0) > 0, "load");
  CHECK(r.waitReady(0), "deck not ready: %s", cm_last_error(r.e));
  const int64_t S = r.clock() + 1000;
  cm_play_at(r.e, 0, S);
  r.render(sr * 2 + 4000);
  const size_t base = (size_t)(S + kLim);
  double maxErr = 0;
  for (size_t i = 64; i < (size_t)sr * 2; ++i) {
    maxErr = std::max(maxErr, (double)std::abs(r.out[(base + i) * 2] - src[i * 2]));
    maxErr = std::max(maxErr, (double)std::abs(r.out[(base + i) * 2 + 1] - src[i * 2 + 1]));
  }
  // до старта — тишина
  double pre = 0;
  for (size_t i = (size_t)S - 200; i < base; ++i) pre = std::max(pre, (double)std::abs(r.out[i * 2]));
  std::printf("    max error %.2e, before start %.2e\n", maxErr, pre);
  CHECK(maxErr < 1e-6, "not transparent: %g", maxErr);
  CHECK(pre == 0.0, "sound before start");
}

// 44,1 кГц → 48 кГц: позиции событий сохраняются
static void testResampleTiming() {
  const int fr = 44100, sr = 48000;
  std::vector<float> src((size_t)fr * 4 * 2, 0.0f);
  for (double t : {1.0, 2.0, 3.0}) {
    const size_t i = (size_t)std::llround(t * fr);
    src[i * 2] = src[i * 2 + 1] = 0.9f;
  }
  writeWav(path("imp441.wav"), src, fr);
  Rig r;
  cm_load(r.e, 0, path("imp441.wav").c_str(), 0.0);
  CHECK(r.waitReady(0), "deck not ready: %s", cm_last_error(r.e));
  const int64_t S = r.clock() + 500;
  cm_play_at(r.e, 0, S);
  r.render(sr * 4);
  for (double t : {1.0, 2.0, 3.0}) {
    const long long expect = S + kLim + std::llround(t * sr);
    long long best = -1; float bv = 0;
    for (long long i = expect - 200; i < expect + 200; ++i)
      if (std::abs(r.out[(size_t)i * 2]) > bv) { bv = std::abs(r.out[(size_t)i * 2]); best = i; }
    std::printf("    impulse at %.0f s: offset %lld samples, peak %.3f\n", t, best - expect, bv);
    CHECK(std::llabs(best - expect) <= 2, "impulse moved by %lld samples", best - expect);
  }
}

// EQ: выключенный низ гасит 60 Гц не меньше чем на 30 дБ и почти не трогает 5 кГц
static void testEqKill() {
  const int sr = 48000;
  auto lo = sine(sr * 3, sr, 60.0, 0.5f), hi = sine(sr * 3, sr, 5000.0, 0.5f);
  writeWav(path("sine60.wav"), lo, sr);
  writeWav(path("sine5k.wav"), hi, sr);
  for (int which = 0; which < 2; ++which) {
    Rig r;
    cm_load(r.e, 0, path(which == 0 ? "sine60.wav" : "sine5k.wav").c_str(), 0.0);
    CHECK(r.waitReady(0), "deck not ready");
    cm_set(r.e, 0, CM_EQ_LOW, -1.0);
    const int64_t S = r.clock();
    cm_play_at(r.e, 0, S);
    r.render(sr * 2);
    const double out = rms(r.out, (size_t)S + sr / 2, (size_t)S + sr * 3 / 2);
    const double att = 20 * std::log10(out / (0.5 / std::sqrt(2.0)));
    std::printf("    %s with low kill: %.1f dB\n", which == 0 ? "60 Hz" : "5 kHz", att);
    if (which == 0) CHECK(att < -30, "low not killed: %.1f dB", att);
    else CHECK(att > -0.5, "high affected: %.1f dB", att);
  }
}

// Лимитер: две громкие деки не дают пика выше −1 дБFS
static void testLimiter() {
  const int sr = 48000;
  auto a = sine(sr * 3, sr, 100.0, 0.9f);
  writeWav(path("loud.wav"), a, sr);
  Rig r;
  cm_load(r.e, 0, path("loud.wav").c_str(), 0.0);
  cm_load(r.e, 1, path("loud.wav").c_str(), 0.0);
  CHECK(r.waitReady(0) && r.waitReady(1), "decks not ready");
  const int64_t S = r.clock();
  cm_play_at(r.e, 0, S);
  cm_play_at(r.e, 1, S);
  r.render(sr * 2);
  float peak = 0;
  for (size_t i = (size_t)S * 2; i < r.out.size(); ++i) peak = std::max(peak, std::abs(r.out[i]));
  std::printf("    peak %.4f (ceiling %.4f)\n", peak, std::pow(10.0, -1.0 / 20));
  CHECK(peak <= std::pow(10.0, -1.0 / 20) + 1e-6, "peak over ceiling");
  CHECK(peak > 0.85, "limiter too aggressive");
}

// Тайм-стретч: темп 1.0 → 1.05 → 1.0. Клики выходят там, где их ждёт модель позиции,
// а после возврата к 1.0 звук снова бит-в-бит.
static void testTempoRamp() {
  const int sr = 48000;
  auto src = clicks(sr * 30, sr, 0.25, 120.0, 2);
  // под клики подмешиваем тихий шум — чтобы проверить точное совпадение после возврата к 1.0
  auto nz = noise(sr * 30, 0.02f, 3);
  for (size_t i = 0; i < src.size(); ++i) src[i] += nz[i];
  writeWav(path("clicks120.wav"), src, sr);
  Rig r;
  cm_load(r.e, 0, path("clicks120.wav").c_str(), 0.0);
  CHECK(r.waitReady(0), "deck not ready");
  const int64_t S = r.clock() + 100;
  cm_play_at(r.e, 0, S);
  // 2 с на 1.0, 2 с разгон до 1.05, 4 с держим, 2 с назад к 1.0, дальше 1.0
  const int64_t a = S + 2 * sr, b = a + 2 * sr, c = b + 4 * sr, d = c + 2 * sr;
  cm_ramp(r.e, 0, CM_TEMPO, a, b, 1.0, 1.05, CM_LINEAR);
  cm_ramp(r.e, 0, CM_TEMPO, c, d, 1.05, 1.0, CM_LINEAR);
  r.render(sr * 16);

  // модель позиции: интеграл темпа
  auto tempoAt = [&](int64_t t) {
    if (t < a) return 1.0;
    if (t < b) return 1.0 + 0.05 * double(t - a) / double(b - a);
    if (t < c) return 1.05;
    if (t < d) return 1.05 - 0.05 * double(t - c) / double(d - c);
    return 1.0;
  };
  // выходной кадр, на котором звучит позиция трека p (секунды)
  std::vector<double> srcPos;  // позиция трека для каждого выходного кадра начиная с S
  double pos = 0;
  for (int64_t t = S; t < (int64_t)(r.out.size() / 2); ++t) { srcPos.push_back(pos); pos += tempoAt(t) / sr; }
  auto outTimeOf = [&](double p) {
    auto it = std::lower_bound(srcPos.begin(), srcPos.end(), p);
    return (double)(S + (it - srcPos.begin()) + kLim) / sr;
  };

  auto got = onsets(r.out, 0, sr, 0.3);
  double worst = 0;
  int matched = 0;
  for (double t = 0.25; t < 14.0; t += 0.5) {
    const double expect = outTimeOf(t);
    if (expect > (double)(r.out.size() / 2) / sr - 0.1) break;
    double best = 1e9;
    for (double g : got) best = std::min(best, std::abs(g - expect));
    worst = std::max(worst, best);
    ++matched;
  }
  std::printf("    %d clicks checked, worst timing error %.2f ms\n", matched, worst * 1000);
  CHECK(worst < 0.005, "clicks drift %.2f ms", worst * 1000);

  // после возврата к 1.0 (через 1 с после d) звук совпадает с исходником
  cm_state s = r.state();
  const size_t outStart = (size_t)(d + sr + kLim);
  // позиция трека, которая звучит на выходе в outStart
  const double p = srcPos[(size_t)(d + sr - S)];
  long long srcIdx = std::llround(p * sr);
  // ищем точное совпадение в окрестности ±64 сэмплов (на случай округления позиции при выходе из стретча)
  double bestErr = 1e9; int bestOff = 0;
  for (int off = -64; off <= 64; ++off) {
    double e = 0;
    for (int i = 0; i < 2000; ++i) e = std::max(e, (double)std::abs(r.out[(outStart + i) * 2] - src[(size_t)(srcIdx + off + i) * 2]));
    if (e < bestErr) { bestErr = e; bestOff = off; }
  }
  std::printf("    after returning to 1.0: max error %.2e at offset %d samples, stretching=%d, underruns=%lld\n",
              bestErr, bestOff, s.deck[0].stretching, (long long)s.underruns);
  CHECK(s.deck[0].stretching == 0, "stretcher still engaged");
  CHECK(bestErr < 1e-6, "not bit-exact after returning to direct playback");
  CHECK(std::abs(bestOff) <= 2, "position drift %d samples", bestOff);
  CHECK(s.underruns == 0, "underruns");
}

// Битматч: A — 120 BPM в левом канале, B — 125 BPM в правом, B замедлен до 120.
// Клики двух дек совпадают на протяжении 20 с.
static void testBeatmatch() {
  const int sr = 48000;
  writeWav(path("a120.wav"), clicks(sr * 40, sr, 0.5, 120.0, 0), sr);
  writeWav(path("b125.wav"), clicks(sr * 40, sr, 0.3, 125.0, 1), sr);
  Rig r;
  cm_load(r.e, 0, path("a120.wav").c_str(), 0.0);
  cm_load(r.e, 1, path("b125.wav").c_str(), 0.0);
  CHECK(r.waitReady(0) && r.waitReady(1), "decks not ready");
  const double ratio = 120.0 / 125.0;
  cm_set(r.e, 1, CM_TEMPO, ratio);
  r.render(256);
  const int64_t SA = r.clock() + 100;
  // первый клик B (0,3 с трека) звучит через 0,3/ratio с; клик A — через 0,5 с
  const int64_t SB = SA + std::llround((0.5 - 0.3 / ratio) * sr);
  cm_play_at(r.e, 0, SA);
  cm_play_at(r.e, 1, SB);
  r.render(sr * 22);
  auto oa = onsets(r.out, 0, sr), ob = onsets(r.out, 1, sr);
  double worst = 0;
  int n = 0;
  for (double t : oa) {
    if (t < (SA / (double)sr) + 1.0) continue;
    double best = 1e9;
    for (double u : ob) best = std::min(best, std::abs(u - t));
    worst = std::max(worst, best);
    ++n;
  }
  std::printf("    %d beats compared, worst A–B offset %.2f ms, underruns=%lld\n", n, worst * 1000,
              (long long)r.state().underruns);
  CHECK(n > 30, "too few beats");
  CHECK(worst < 0.005, "beats drift %.2f ms", worst * 1000);
}

// Автоматизация громкости с равной мощностью: кроссфейд двух дек без провала громкости
static void testEqualPowerCrossfade() {
  const int sr = 48000;
  writeWav(path("na.wav"), noise(sr * 8, 0.2f, 11), sr);
  writeWav(path("nb.wav"), noise(sr * 8, 0.2f, 99), sr);
  Rig r;
  cm_load(r.e, 0, path("na.wav").c_str(), 0.0);
  cm_load(r.e, 1, path("nb.wav").c_str(), 0.0);
  CHECK(r.waitReady(0) && r.waitReady(1), "decks not ready");
  const int64_t S = r.clock() + 100, X = S + sr, Y = X + 4 * sr;
  cm_set(r.e, 1, CM_GAIN, 0.0);
  cm_play_at(r.e, 0, S);
  cm_play_at(r.e, 1, X);
  cm_ramp(r.e, 0, CM_GAIN, X, Y, 1.0, 0.0, CM_EQUAL_POWER_OUT);
  cm_ramp(r.e, 1, CM_GAIN, X, Y, 0.0, 1.0, CM_EQUAL_POWER_IN);
  r.render(sr * 6);
  const double ref = rms(r.out, (size_t)S + sr / 4, (size_t)X);
  double lo = 1e9, hi = 0;
  for (int k = 0; k < 16; ++k) {
    const size_t a = (size_t)X + kLim + (size_t)k * sr / 4;
    const double v = rms(r.out, a, a + sr / 8);
    lo = std::min(lo, v); hi = std::max(hi, v);
  }
  const double dLo = 20 * std::log10(lo / ref), dHi = 20 * std::log10(hi / ref);
  std::printf("    level during crossfade: %.2f…%.2f dB\n", dLo, dHi);
  CHECK(dLo > -1.0 && dHi < 1.0, "level dips or bumps");
}

// Пауза, перемотка, конец трека и загрузка несуществующего файла не ломают движок
static void testControlFlow() {
  const int sr = 48000;
  writeWav(path("short.wav"), noise(sr * 2, 0.2f, 5), sr);
  Rig r;
  CHECK(cm_load(r.e, 0, path("nope.flac").c_str(), 0.0) > 0, "load call");
  for (int i = 0; i < 400 && r.state().deck[0].status != CM_ERROR; ++i) {
    r.render(256);
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  CHECK(r.state().deck[0].status == CM_ERROR, "missing file not reported (status %d)", r.state().deck[0].status);
  cm_load(r.e, 0, path("short.wav").c_str(), 0.0);
  CHECK(r.waitReady(0, 500), "deck not ready");
  cm_play_at(r.e, 0, -1);
  r.render(sr / 2);
  CHECK(r.state().deck[0].status == CM_PLAYING, "not playing");
  cm_pause(r.e, 0);
  r.render(sr / 10);
  cm_state s = r.state();
  CHECK(s.deck[0].status == CM_READY, "not paused (%d)", s.deck[0].status);
  const double paused = s.deck[0].position_sec;
  r.render(sr / 10);
  CHECK(std::abs(r.state().deck[0].position_sec - paused) < 1e-9, "position moves while paused");
  cm_seek(r.e, 0, 1.5);
  r.render(sr / 10);
  CHECK(std::abs(r.state().deck[0].position_sec - 1.5) < 0.01, "seek position %.3f", r.state().deck[0].position_sec);
  // декодер перематывается в своём потоке: ждём звук с новой позиции в реальном времени
  for (int i = 0; i < 400 && r.state().deck[0].buffered_ms < 400; ++i) {
    r.render(256);
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  cm_play_at(r.e, 0, -1);
  r.render(sr);
  s = r.state();
  std::printf("    end of track: status %d, position %.3f / %.3f\n", s.deck[0].status, s.deck[0].position_sec, s.deck[0].duration_sec);
  CHECK(s.deck[0].status == CM_ENDED, "end of track not reported (status %d, position %.3f, buffered %d ms)", s.deck[0].status, s.deck[0].position_sec, s.deck[0].buffered_ms);
  CHECK(std::abs(s.deck[0].duration_sec - 2.0) < 0.01, "duration");
}


// M4A/AAC, Opus, Ogg через ffmpeg: клики на своих местах (задержка кодера убрана),
// перемотка точна, длительность известна
static void testFfmpegFormats() {
  const int sr = 48000;
  writeWav(path("clk.wav"), clicks(sr * 12, sr, 0.5, 120.0, 2), sr);
  struct F { const char *ext; const char *args; } fmts[] = {
      {"m4a", "-c:a aac -b:a 192k -ar 44100"},
      {"opus", "-c:a libopus -b:a 160k"},
      {"ogg", "-c:a libvorbis -q:a 6 -ar 44100"},
  };
  for (auto &f : fmts) {
    const std::string out = path((std::string("clk.") + f.ext).c_str());
    const std::string cmd = "ffmpeg -y -v error -i " + path("clk.wav") + " " + f.args + " " + out;
    if (std::system(cmd.c_str()) != 0) {
      std::printf("    skipped: no ffmpeg in PATH to encode test files\n");
      return;
    }
    Rig r;
    cm_set_ffmpeg(r.e, "ffmpeg");
    cm_load(r.e, 0, out.c_str(), 0.0);
    CHECK(r.waitReady(0, 1000), "%s not ready: %s", f.ext, cm_last_error(r.e));
    const int64_t S = r.clock() + 100;
    cm_play_at(r.e, 0, S);
    r.render(sr * 4);
    auto got = onsets(r.out, 0, sr, 0.2);
    double worst = 0; int n = 0;
    for (double t = 0.5; t < 3.6; t += 0.5) {
      const double expect = (double)(S + kLim) / sr + t;
      double best = 1e9;
      for (double g : got) best = std::min(best, std::abs(g - expect));
      worst = std::max(worst, best); ++n;
    }
    // перемотка на 7,25 с: следующий клик (7,5 с) должен прозвучать через 0,25 с
    cm_seek(r.e, 0, 7.25);
    cm_pause(r.e, 0);
    r.render(512);  // движок принимает команды только в рендере
    // ffmpeg перезапускается с новой позиции: ждём буфер в реальном времени, как плеер
    for (int i = 0; i < 400 && r.state().deck[0].buffered_ms < 800; ++i) {
      r.render(256);
      std::this_thread::sleep_for(std::chrono::milliseconds(3));
    }
    const size_t mark = r.out.size() / 2;
    const int64_t S2 = r.clock() + 100;
    cm_play_at(r.e, 0, S2);
    r.render(sr);
    std::vector<float> tail(r.out.begin() + (long)mark * 2, r.out.end());
    auto g2 = onsets(tail, 0, sr, 0.2);
    const double expect2 = (double)(S2 - (int64_t)mark + kLim) / sr + 0.25;
    const double seekErr = g2.empty() ? 1e9 : std::abs(g2[0] - expect2);
    const double dur = r.state().deck[0].duration_sec;
    std::printf("    %-4s: %d clicks, worst %.2f ms; after seek %.2f ms; duration %.3f s\n", f.ext, n, worst * 1000,
                seekErr * 1000, dur);
    CHECK(worst < 0.002, "%s clicks off by %.2f ms", f.ext, worst * 1000);
    CHECK(seekErr < 0.002, "%s seek off by %.2f ms", f.ext, seekErr * 1000);
    CHECK(std::abs(dur - 12.0) < 0.1, "%s duration %.3f", f.ext, dur);
  }
}

int main(int argc, char **argv) {
  if (argc > 1) g_dir = argv[1];
  struct T { const char *name; void (*fn)(); } tests[] = {
      {"transparent playback and exact start", testTransparentAndExactStart},
      {"resample 44.1 -> 48 kHz keeps timing", testResampleTiming},
      {"EQ low kill", testEqKill},
      {"master limiter", testLimiter},
      {"tempo ramp with Rubber Band R3", testTempoRamp},
      {"beatmatch 125 -> 120 BPM", testBeatmatch},
      {"equal-power crossfade", testEqualPowerCrossfade},
      {"pause, seek, end, errors", testControlFlow},
      {"M4A / Opus / Ogg via ffmpeg", testFfmpegFormats},
  };
  for (auto &t : tests) {
    const int before = g_failed;
    std::printf("• %s\n", t.name);
    const auto t0 = std::chrono::steady_clock::now();
    t.fn();
    const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    std::printf("  %s (%.0f ms)\n", g_failed == before ? "ok" : "FAILED", ms);
  }
  std::printf(g_failed ? "\n%d test(s) failed\n" : "\nall tests passed\n", g_failed);
  return g_failed ? 1 : 0;
}

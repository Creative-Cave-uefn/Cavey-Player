// Тесты анализа треков. Запуск:
//   cave_mix_analysis_tests <onnxruntime.so|dll> <mel_spectrogram.onnx> <beat_this_small.onnx>
//                           <эталонный mp3> <golden_small.json> <папка_для_wav>
// Эталон — доли и даунбиты исходной Python-реализации Beat This! (JKU) на том же mp3 и той же модели.

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "../cave_mix.h"
#include "../readers.h"

static int g_failed = 0;
#define CHECK(cond, ...)                     \
  do {                                       \
    if (!(cond)) {                           \
      std::printf("    FAIL: " __VA_ARGS__); \
      std::printf("\n");                     \
      ++g_failed;                            \
      return;                                \
    }                                        \
  } while (0)

static std::string g_dir;
static cm_analyzer *g_an = nullptr;

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

// --- крошечный разбор JSON: массив чисел, число, строка по ключу
static std::vector<double> jsonArray(const std::string &j, const char *key) {
  std::vector<double> r;
  const std::string k = std::string("\"") + key + "\"";
  size_t p = j.find(k);
  if (p == std::string::npos) return r;
  p = j.find('[', p);
  const size_t e = j.find(']', p);
  std::string body = j.substr(p + 1, e - p - 1);
  std::replace(body.begin(), body.end(), ',', ' ');
  std::istringstream is(body);
  double v;
  while (is >> v) r.push_back(v);
  return r;
}
static double jsonNum(const std::string &j, const char *key) {
  const std::string k = std::string("\"") + key + "\":";
  const size_t p = j.find(k);
  if (p == std::string::npos) return NAN;
  return std::atof(j.c_str() + p + k.size());
}
static std::string jsonStr(const std::string &j, const char *key) {
  const std::string k = std::string("\"") + key + "\":\"";
  const size_t p = j.find(k);
  if (p == std::string::npos) return "";
  const size_t e = j.find('"', p + k.size());
  return j.substr(p + k.size(), e - p - k.size());
}

static std::string analyze(const std::string &path, double *ms = nullptr) {
  char *err = nullptr;
  const auto t0 = std::chrono::steady_clock::now();
  char *js = cm_analyze_file(g_an, path.c_str(), "ffmpeg", &err);
  if (ms) *ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
  if (!js) {
    std::printf("    analyze error: %s\n", err ? err : "?");
    cm_free(err);
    return "";
  }
  std::string s(js);
  cm_free(js);
  return s;
}

// F-мера при окне ±70 мс (стандарт MIR)
static double fMeasure(const std::vector<double> &est, const std::vector<double> &ref, double *maxDiff) {
  std::vector<char> used(ref.size(), 0);
  int hit = 0;
  *maxDiff = 0;
  for (double e : est) {
    int best = -1; double bd = 0.07;
    for (size_t i = 0; i < ref.size(); ++i)
      if (!used[i] && std::abs(ref[i] - e) <= bd) { bd = std::abs(ref[i] - e); best = (int)i; }
    if (best >= 0) { used[(size_t)best] = 1; ++hit; *maxDiff = std::max(*maxDiff, bd); }
  }
  if (est.empty() || ref.empty()) return 0;
  const double p = (double)hit / est.size(), r = (double)hit / ref.size();
  return p + r > 0 ? 2 * p * r / (p + r) : 0;
}

static std::string g_mp3, g_golden;

// Доли и даунбиты совпадают с эталоном JKU
static void testBeatThisParity() {
  double ms = 0;
  const std::string js = analyze(g_mp3, &ms);
  CHECK(!js.empty(), "no result");
  std::ifstream f(g_golden);
  std::stringstream ss;
  ss << f.rdbuf();
  const std::string gold = ss.str();
  const auto gb = jsonArray(gold, "beats"), gd = jsonArray(gold, "downbeats");
  const auto eb = jsonArray(js, "beats"), ed = jsonArray(js, "downbeats");
  double mb = 0, md = 0;
  const double fb = fMeasure(eb, gb, &mb), fd = fMeasure(ed, gd, &md);
  std::printf("    %.0f ms for %.0f s of audio; beats %zu (ref %zu) F=%.4f max diff %.1f ms; downbeats %zu (ref %zu) F=%.4f max diff %.1f ms\n",
              ms, jsonNum(js, "durationMs") / 1000, eb.size(), gb.size(), fb, mb * 1000, ed.size(), gd.size(), fd, md * 1000);
  std::printf("    bpm %.2f, grid residual %.1f ms, variable %s, %d/4, key %s (%s, %.2f), %.1f LUFS, %.1f dBTP\n",
              jsonNum(js, "bpm"), jsonNum(js, "gridResidualMs"), js.find("\"variableTempo\":true") != std::string::npos ? "yes" : "no",
              (int)jsonNum(js, "beatsPerBar"), jsonStr(js, "key").c_str(), jsonStr(js, "keyName").c_str(), jsonNum(js, "keyConfidence"),
              jsonNum(js, "lufs"), jsonNum(js, "truePeakDb"));
  CHECK(fb >= 0.99, "beat F-measure %.4f", fb);
  CHECK(fd >= 0.99, "downbeat F-measure %.4f", fd);
}

// EBU Tech 3341, случай 1: стерео синус 1 кГц, −23 дБFS в каждом канале → −23,0 LUFS
static void testLoudnessEbu() {
  const int sr = 48000;
  for (double level : {-23.0, -33.0}) {
    const double a = std::pow(10.0, level / 20.0);
    std::vector<float> v((size_t)sr * 20 * 2);
    for (int i = 0; i < sr * 20; ++i) v[(size_t)i * 2] = v[(size_t)i * 2 + 1] = (float)(a * std::sin(2 * M_PI * 1000.0 * i / sr));
    const std::string p = g_dir + "/ebu.wav";
    writeWav(p, v, sr);
    const std::string js = analyze(p);
    CHECK(!js.empty(), "no result");
    const double l = jsonNum(js, "lufs"), t = jsonNum(js, "truePeakDb");
    std::printf("    sine at %.0f dBFS: %.2f LUFS, true peak %.2f dBTP\n", level, l, t);
    CHECK(std::abs(l - level) <= 0.1, "loudness %.2f, expected %.1f", l, level);
    CHECK(std::abs(t - level) <= 0.2, "true peak %.2f", t);
  }
}

// Тональность: каденции из аккордов с обертонами
static void addChord(std::vector<float> &v, int sr, double t0, double len, std::initializer_list<int> midi) {
  for (int m : midi) {
    const double f = 440.0 * std::pow(2.0, (m - 69) / 12.0);
    for (int i = (int)(t0 * sr); i < (int)((t0 + len) * sr) && (size_t)i * 2 < v.size(); ++i) {
      const double t = (i - t0 * sr) / sr;
      const double env = std::min(1.0, t * 50) * std::exp(-t * 0.8);
      double s = 0;
      for (int h = 1; h <= 5; ++h) s += std::sin(2 * M_PI * f * h * i / sr) / (h * h);
      v[(size_t)i * 2] += (float)(0.08 * env * s);
      v[(size_t)i * 2 + 1] = v[(size_t)i * 2];
    }
  }
}

static void testKey() {
  const int sr = 44100;
  struct Case { const char *expect; std::vector<std::vector<int>> chords; } cases[] = {
      // A-минор: Am Dm E Am (гармонический минор), бас + трезвучие
      {"8A", {{45, 57, 60, 64}, {50, 62, 65, 69}, {40, 56, 59, 64}, {45, 57, 60, 64}}},
      // C-мажор: C F G C
      {"8B", {{36, 48, 52, 55}, {41, 53, 57, 60}, {43, 55, 59, 62}, {36, 48, 52, 55}}},
      // E-мажор: E A B E
      {"12B", {{40, 52, 56, 59}, {45, 57, 61, 64}, {47, 59, 63, 66}, {40, 52, 56, 59}}},
      // F#-минор: F#m Bm C#7 F#m
      {"11A", {{42, 54, 57, 61}, {47, 59, 62, 66}, {49, 61, 65, 68, 71}, {42, 54, 57, 61}}},
  };
  for (auto &c : cases) {
    std::vector<float> v((size_t)sr * 32 * 2, 0.0f);
    for (int rep = 0; rep < 4; ++rep)
      for (size_t k = 0; k < c.chords.size(); ++k) {
        const auto &ch = c.chords[k];
        for (int m : ch) addChord(v, sr, rep * 8.0 + k * 2.0, 2.0, {m});
      }
    const std::string p = g_dir + "/key.wav";
    writeWav(p, v, sr);
    const std::string js = analyze(p);
    CHECK(!js.empty(), "no result");
    std::printf("    expected %-3s → %s (%s), confidence %.2f\n", c.expect, jsonStr(js, "key").c_str(),
                jsonStr(js, "keyName").c_str(), jsonNum(js, "keyConfidence"));
    CHECK(jsonStr(js, "key") == c.expect, "wrong key");
  }
}

// Сетка: синтетический бит 4/4, 124 BPM, первая сильная доля на 0,8 с; аккорд меняется каждый такт
static void testGrid() {
  const int sr = 44100;
  const double bpm = 124.0, p = 60.0 / bpm, first = 0.8;
  std::vector<float> v((size_t)sr * 60 * 2, 0.0f);
  auto add = [&](double t, double len, auto fn) {
    for (int i = (int)(t * sr); i < (int)((t + len) * sr) && (size_t)i * 2 + 1 < v.size(); ++i) {
      const double x = fn((i - t * sr) / sr);
      v[(size_t)i * 2] += (float)x;
      v[(size_t)i * 2 + 1] += (float)x;
    }
  };
  unsigned rnd = 1;
  int k = 0;
  for (double t = first; t < 59; t += p, ++k) {
    const bool down = k % 4 == 0;
    // бочка на каждую долю (на сильной громче), малый барабан на 2 и 4, хай-хэт на слабые восьмые
    add(t, 0.25, [&](double x) { return (down ? 0.9 : 0.6) * std::sin(2 * M_PI * (50 + 100 * std::exp(-x * 30)) * x) * std::exp(-x * 12); });
    if (k % 2 == 1) add(t, 0.15, [&](double x) { rnd = rnd * 1664525u + 1013904223u; return 0.35 * ((rnd >> 8) / 8388608.0 - 1) * std::exp(-x * 25); });
    add(t + p / 2, 0.05, [&](double x) { rnd = rnd * 1664525u + 1013904223u; return 0.12 * ((rnd >> 8) / 8388608.0 - 1) * std::exp(-x * 80); });
    if (down) {
      static const int roots[4] = {45, 41, 48, 43};  // Am F C G
      const int r = roots[(k / 4) % 4];
      add(t, p * 4, [&](double x) { return 0.18 * std::sin(2 * M_PI * 440.0 * std::pow(2.0, (r - 69) / 12.0) * x) * std::exp(-x * 1.2); });
    }
  }
  const std::string path = g_dir + "/grid.wav";
  writeWav(path, v, sr);
  const std::string js = analyze(path);
  CHECK(!js.empty(), "no result");
  const double b = jsonNum(js, "bpm"), fb = jsonNum(js, "firstBeatMs") / 1000, fd = jsonNum(js, "firstDownbeatMs") / 1000;
  const double res = jsonNum(js, "gridResidualMs");
  // первая доля сетки должна совпасть с какой-то долей бита (сетка продолжена к началу трека)
  const double phaseErr = std::abs(std::remainder(fb - first, p));
  const double downErr = std::abs(std::remainder(fd - first, p * 4));
  std::printf("    bpm %.3f (expect %.1f), beat phase error %.1f ms, downbeat error %.1f ms, residual %.1f ms, %d/4\n", b, bpm,
              phaseErr * 1000, downErr * 1000, res, (int)jsonNum(js, "beatsPerBar"));
  CHECK(std::abs(b - bpm) < 0.05, "bpm");
  CHECK(phaseErr < 0.015, "beat phase");
  CHECK(downErr < 0.015, "downbeat phase");
  CHECK((int)jsonNum(js, "beatsPerBar") == 4, "meter");
  const auto mixOut = js.find("\"mixOut\":[{");
  CHECK(mixOut != std::string::npos, "no mix-out point");
}

// Вокал: ударные без голоса + песня с голосом с 20-й секунды. Голос должен найтись в тактах песни и только там
static std::string g_vocalModel, g_vocalSong;
static void testVocals() {
  if (g_vocalModel.empty()) { std::printf("    skipped: no vocal model given\n"); return; }
  char *err = nullptr;
  CHECK(cm_analyzer_set_vocals(g_an, g_vocalModel.c_str(), &err), "vocal model: %s", err ? err : "?");
  auto song = cm::openMiniaudio(g_vocalSong);
  CHECK(song && song->rate() == 44100, "song not opened (need 44.1 kHz WAV)");
  std::vector<float> sv, buf(4096 * 2);
  for (;;) { const int n = song->read(buf.data(), 4096); sv.insert(sv.end(), buf.begin(), buf.begin() + n * 2); if (n < 4096) break; }
  const int sr = 44100;
  const double bpm = 124.0, p = 60.0 / bpm, first = 0.8, songAt = 20.0;
  std::vector<float> v((size_t)sr * 60 * 2, 0.0f);
  int k = 0;
  for (double t = first; t < 59; t += p, ++k)
    for (int i = (int)(t * sr); i < (int)((t + 0.25) * sr) && (size_t)i * 2 + 1 < v.size(); ++i) {
      const double x = (i - t * sr) / sr;
      const float y = (float)((k % 4 == 0 ? 0.9 : 0.6) * std::sin(2 * M_PI * (50 + 100 * std::exp(-x * 30)) * x) * std::exp(-x * 12));
      v[(size_t)i * 2] += y; v[(size_t)i * 2 + 1] += y;
    }
  const size_t o = (size_t)(songAt * sr) * 2;
  for (size_t i = 0; i < sv.size() && o + i < v.size(); ++i) v[o + i] += 0.8f * sv[i];
  const double songEnd = songAt + sv.size() / 2.0 / sr;
  const std::string path = g_dir + "/vocal_mix.wav";
  writeWav(path, v, sr);
  double ms = 0;
  const std::string js = analyze(path, &ms);
  CHECK(!js.empty(), "no result");
  const auto voc = jsonArray(js, "vocals");
  CHECK(!voc.empty(), "no vocals in profile");
  const double fd = jsonNum(js, "firstDownbeatMs") / 1000, bar = jsonNum(js, "barMs") / 1000;
  double t0 = fd;
  while (t0 - bar > 0) t0 -= bar;
  int inside = 0, insideOn = 0, outside = 0, outsideOn = 0;
  for (size_t i = 0; i < voc.size(); ++i) {
    const double a = t0 + i * bar, b = a + bar;
    if (a >= songAt + 0.5 && b <= songEnd - 0.5) { ++inside; insideOn += voc[i] > 0.15; }
    else if (b <= songAt || a >= songEnd) { ++outside; outsideOn += voc[i] > 0.05; }
  }
  std::printf("    voice found in %d/%d bars of the song, in %d/%d bars without it (analysis %.1f s)\n", insideOn, inside, outsideOn,
              outside, ms / 1000);
  CHECK(insideOn >= inside * 0.7, "voice missed");
  CHECK(outsideOn == 0, "voice where there is none");
}

int main(int argc, char **argv) {
  if (argc < 7) {
    std::printf("usage: %s ort_lib mel.onnx beat.onnx ref.mp3 golden.json workdir\n", argv[0]);
    return 2;
  }
  g_mp3 = argv[4];
  g_golden = argv[5];
  g_dir = argv[6];
  if (argc > 8) { g_vocalModel = argv[7]; g_vocalSong = argv[8]; }
  char *err = nullptr;
  const auto t0 = std::chrono::steady_clock::now();
  g_an = cm_analyzer_create(argv[1], argv[2], argv[3], 0, &err);
  if (!g_an) {
    std::printf("analyzer: %s\n", err ? err : "?");
    return 1;
  }
  std::printf("analyzer loaded in %.0f ms\n", std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count());
  struct T { const char *name; void (*fn)(); } tests[] = {
      {"Beat This! parity with the JKU reference", testBeatThisParity},
      {"EBU R128 loudness", testLoudnessEbu},
      {"key detection", testKey},
      {"tempo grid and downbeats", testGrid},
      {"vocals per bar (Spleeter)", testVocals},
  };
  for (auto &t : tests) {
    const int before = g_failed;
    std::printf("• %s\n", t.name);
    t.fn();
    std::printf("  %s\n", g_failed == before ? "ok" : "FAILED");
  }
  cm_analyzer_destroy(g_an);
  std::printf(g_failed ? "\n%d test(s) failed\n" : "\nall tests passed\n", g_failed);
  return g_failed ? 1 : 0;
}

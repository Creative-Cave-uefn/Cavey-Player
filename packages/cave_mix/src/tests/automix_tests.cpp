// Сквозные тесты автомикса: два синтетических трека → анализ (Beat This!) → движок играет A →
// cm_automix планирует переход → офлайн-рендер → проверки на выходе.
// Трек A звучит только в левом канале, B — только в правом: так по каналам видно, совпадают ли их доли.
// Заодно рендерятся демо-переходы (оба трека по центру) для прослушивания: demo_T*.wav.
//
// Запуск: cave_mix_automix_tests <onnxruntime> <mel.onnx> <beat.onnx> <папка>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include "../cave_mix.h"

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
static const int kSr = 48000;
static const int kLim = 240;

static void writeWav(const std::string &path, const float *st, size_t frames, int rate) {
  FILE *f = std::fopen(path.c_str(), "wb");
  const uint32_t data = (uint32_t)(frames * 4);  // 16 бит стерео — чтобы демо были компактнее
  auto w32 = [&](uint32_t v) { std::fwrite(&v, 4, 1, f); };
  auto w16 = [&](uint16_t v) { std::fwrite(&v, 2, 1, f); };
  std::fwrite("RIFF", 1, 4, f); w32(36 + data); std::fwrite("WAVE", 1, 4, f);
  std::fwrite("fmt ", 1, 4, f); w32(16); w16(1); w16(2); w32(rate); w32(rate * 4); w16(4); w16(16);
  std::fwrite("data", 1, 4, f); w32(data);
  for (size_t i = 0; i < frames * 2; ++i) {
    const int16_t v = (int16_t)std::lround(std::clamp(st[i], -1.0f, 1.0f) * 32767);
    std::fwrite(&v, 2, 1, f);
  }
  std::fclose(f);
}
static void writeWavF(const std::string &path, const std::vector<float> &st, int rate) {
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

// ------------------------------------------------------------------ синтетический трек

struct TrackSpec {
  double bpm;
  double first;        // первая сильная доля, с
  int roots[4];        // басовые ноты аккордов по тактам (MIDI)
  bool minor;
  int pan;             // 0 — только левый, 1 — только правый, 2 — центр
  unsigned seed;
  double kickPitch;
  bool clicks = false; // только щелчки на долях — для точных замеров времени
};

// 64 такта: интро 16 (бочка + хэт), тело 32 (бочка, хлопок, хэты, бас, пэд), аутро 16 (бочка, хэт, пэд затихает)
static std::vector<float> makeTrack(const TrackSpec &s, int sr) {
  const double beat = 60.0 / s.bpm, bar = beat * 4;
  const int bars = 64;
  const size_t n = (size_t)((s.first + bars * bar + 1.0) * sr);
  std::vector<double> m(n, 0.0);
  unsigned rnd = s.seed;
  auto noise = [&]() { rnd = rnd * 1664525u + 1013904223u; return (rnd >> 8) / 8388608.0 - 1.0; };
  auto add = [&](double t, double len, auto fn) {
    const size_t a = (size_t)std::max(0.0, t * sr), b = std::min(n, (size_t)((t + len) * sr));
    for (size_t i = a; i < b; ++i) m[i] += fn((double)(i - a) / sr);
  };
  auto hz = [](int midi) { return 440.0 * std::pow(2.0, (midi - 69) / 12.0); };
  for (int b = 0; s.clicks && b < bars; ++b)
    for (int k = 0; k < 4; ++k)
      add(s.first + b * bar + k * beat, 0.004, [&](double x) { return 0.8 * noise() * std::exp(-x * 1500); });
  for (int b = 0; !s.clicks && b < bars; ++b) {
    const bool intro = b < 16, outro = b >= 48;
    const int root = s.roots[b % 4];
    const double t0 = s.first + b * bar;
    for (int k = 0; k < 4; ++k) {
      const double t = t0 + k * beat;
      const double kp = s.kickPitch;
      add(t, 0.3, [&](double x) { return (k == 0 ? 0.75 : 0.6) * std::sin(2 * M_PI * (kp + 110 * std::exp(-x * 35)) * x) * std::exp(-x * 9); });
      add(t + beat / 2, 0.06, [&](double x) { return 0.10 * noise() * std::exp(-x * 70); });
      if (!intro && !outro && (k == 1 || k == 3)) add(t, 0.2, [&](double x) { return 0.28 * noise() * std::exp(-x * 22); });
      if (!intro && !outro) {
        const double f = hz(root - 12);
        add(t + beat / 2, beat / 2, [&](double x) { return 0.22 * std::sin(2 * M_PI * f * x) * std::exp(-x * 4); });
      }
    }
    if (!intro) {
      const double fade = outro ? std::max(0.0, 1.0 - (b - 48) / 16.0) : 1.0;
      const int third = s.minor ? 3 : 4;
      for (int iv : {12, 12 + third, 19}) {
        const double f = hz(root + iv);
        add(t0, bar, [&](double x) { return fade * 0.05 * (std::sin(2 * M_PI * f * x) + 0.3 * std::sin(4 * M_PI * f * x)) * std::min(1.0, x * 8); });
      }
    }
  }
  std::vector<float> st(n * 2, 0.0f);
  for (size_t i = 0; i < n; ++i) {
    const float v = (float)m[i];
    if (s.pan != 1) st[i * 2] = v;
    if (s.pan != 0) st[i * 2 + 1] = v;
  }
  return st;
}

// ------------------------------------------------------------------ помощники

struct Rig {
  cm_engine *e = cm_create(kSr, 1);
  std::vector<float> out;
  ~Rig() { cm_destroy(e); }
  cm_state state() { cm_state s; cm_get_state(e, &s); return s; }
  void render(int frames) {
    std::vector<float> buf(1024);
    for (int done = 0; done < frames;) {
      const int n = std::min(512, frames - done);
      // офлайн-рендер быстрее реального времени: ждём, пока поток чтения накопит звук (иначе на медленных
      // машинах и под Wine тест ловит недогрузки, которых в живом воспроизведении нет)
      for (int w = 0; w < 2000; ++w) {
        cm_state s = state();
        bool starving = false;
        for (auto &d : s.deck)
          if ((d.status == CM_PLAYING || d.start_clock >= 0) && d.buffered_ms < 400 &&
              (d.duration_sec <= 0 || d.duration_sec - d.position_sec > 1.0))
            starving = true;
        if (!starving) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
      }
      cm_render(e, buf.data(), n);
      out.insert(out.end(), buf.begin(), buf.begin() + n * 2);
      done += n;
      std::this_thread::sleep_for(std::chrono::microseconds(250));
    }
  }
  bool waitReady(int deck) {
    for (int i = 0; i < 3000; ++i) {
      render(256);
      cm_state s = state();
      if (s.deck[deck].status == CM_READY && s.deck[deck].buffered_ms >= 1500) return true;
      if (s.deck[deck].status == CM_ERROR) return false;
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return false;
  }
};

static std::vector<double> onsets(const std::vector<float> &st, int ch, size_t from, size_t to, double thr) {
  std::vector<double> r;
  long long quietSince = -100000;
  bool in = false;
  for (size_t i = from; i < to && i * 2 + 1 < st.size(); ++i) {
    const float a = std::abs(st[i * 2 + (size_t)ch]);
    if (a > thr) {
      if (!in && (long long)i - quietSince > kSr / 12) r.push_back((double)i / kSr);
      in = true;
      quietSince = (long long)i;
    } else if (in && (long long)i - quietSince > kSr / 50) {
      in = false;
    }
  }
  return r;
}

// Время щелчков, не зависящее от громкости: грубый поиск по низкому порогу, затем центр энергии щелчка.
// Для дорожек из щелчков.
static std::vector<double> clickOnsets(const std::vector<float> &st, int ch, size_t from, size_t to) {
  std::vector<double> r;
  const size_t N = st.size() / 2;
  to = std::min(to, N);
  for (size_t i = from; i < to; ++i) {
    if (std::abs(st[i * 2 + (size_t)ch]) < 2e-4f) continue;
    float pk = 0;
    for (size_t j = i; j < std::min(N, i + kSr / 100); ++j) pk = std::max(pk, std::abs(st[j * 2 + (size_t)ch]));
    // центр энергии щелчка: устойчив к размазыванию атаки тайм-стретчем
    (void)pk;
    const size_t a = i > (size_t)kSr / 100 ? i - kSr / 100 : 0, b = std::min(N, i + kSr / 25);
    double se = 0, st_ = 0;
    for (size_t j = a; j < b; ++j) { const double e = (double)st[j * 2 + (size_t)ch] * st[j * 2 + (size_t)ch]; se += e; st_ += e * (double)j; }
    r.push_back(st_ / se / kSr - 1.0 / 3000);  // минус собственный центр щелчка (exp(−1500 t) → 1/3000 с)
    i += kSr / 8;  // доли не чаще 8 в секунду; хвост щелчка пропускаем
  }
  return r;
}

static double rmsDb(const std::vector<float> &st, size_t a, size_t b) {
  double s = 0;
  for (size_t i = a; i < b && i * 2 + 1 < st.size(); ++i) s += st[i * 2] * (double)st[i * 2] + st[i * 2 + 1] * (double)st[i * 2 + 1];
  return 10 * std::log10(s / std::max<size_t>(1, b - a) + 1e-12);
}

static double jsonNum(const std::string &j, const char *key) {
  const std::string k = std::string("\"") + key + "\":";
  const size_t p = j.find(k);
  return p == std::string::npos ? NAN : std::atof(j.c_str() + p + k.size());
}
static std::string jsonStr(const std::string &j, const char *key) {
  const std::string k = std::string("\"") + key + "\":\"";
  const size_t p = j.find(k);
  if (p == std::string::npos) return "";
  return j.substr(p + k.size(), j.find('"', p + k.size()) - p - k.size());
}

static std::string g_profA, g_profB;
static const TrackSpec kA{124.0, 0.40, {57, 53, 48, 55}, true, 0, 7, 48};   // Am F C G, 124 BPM, левый канал
static const TrackSpec kB{128.0, 0.25, {48, 53, 55, 48}, false, 1, 99, 56}; // C F G C, 128 BPM, правый канал

// ------------------------------------------------------------------ тест одной техники

// mode: 0 — замеры времени на дорожках из щелчков, 1 — уровни на настоящих дорожках, 2 — демо
static void runTechnique(int tech, int mode) {
  Rig r;
  const bool demo = mode == 2;
  const char *sa[] = {"/a_k.wav", "/a.wav", "/a_c.wav"}, *sb[] = {"/b_k.wav", "/b.wav", "/b_c.wav"};
  const std::string pa = g_dir + sa[mode], pb = g_dir + sb[mode];
  cm_load(r.e, 0, pa.c_str(), 70.0);
  CHECK(r.waitReady(0), "A not ready: %s", cm_last_error(r.e));
  cm_play_at(r.e, 0, -1);
  r.render(kSr / 2);
  cm_load(r.e, 1, pb.c_str(), 0.0);
  CHECK(r.waitReady(1), "B not ready");
  char opts[256];
  std::snprintf(opts, sizeof(opts), "{\"force\":%d,\"gainA\":0.8,\"gainB\":0.8,\"seed\":5}", tech);
  char *err = nullptr;
  char *planC = cm_automix(r.e, 0, 1, g_profA.c_str(), g_profB.c_str(), opts, &err);
  CHECK(planC, "automix: %s", err ? err : "?");
  const std::string plan(planC);
  cm_free(planC);
  const int64_t c0 = (int64_t)jsonNum(plan, "startClock"), cEnd = (int64_t)jsonNum(plan, "endClock");
  const double ratio = jsonNum(plan, "tempoRatio"), bars = jsonNum(plan, "bars");
  const double beatA = 60.0 / kA.bpm;
  // рендер до конца перехода + 10 тактов A (темп B возвращается за 8)
  const int64_t until = cEnd + (int64_t)(10 * 4 * beatA * kSr);
  while (r.state().clock < until) r.render(kSr / 4);
  cm_state s = r.state();

  if (demo) {
    const size_t a = (size_t)std::max<int64_t>(0, c0 - 8 * kSr), b = std::min(r.out.size() / 2, (size_t)(cEnd + 10 * kSr));
    writeWav(g_dir + "/demo_T" + std::to_string(tech) + ".wav", r.out.data() + a * 2, b - a, kSr);
    std::printf("    demo: %s, %s, %.0f bars, %.1f s\n", jsonStr(plan, "name").c_str(), jsonStr(plan, "technique").c_str(), bars,
                (double)(b - a) / kSr);
    return;
  }

  std::printf("    plan: %s (%s), %.0f bars, A out %.2f s, B in %.2f s, tempo ×%.4f, starts in %.1f s\n",
              jsonStr(plan, "name").c_str(), jsonStr(plan, "technique").c_str(), bars, jsonNum(plan, "aOutSec"),
              jsonNum(plan, "bInSec"), ratio, jsonNum(plan, "startClock") / kSr);

  const double cT = (double)(c0 + kLim) / kSr;  // c0 на выходе (с задержкой лимитера)
  if (mode == 0) {
    // 1. B начинается точно на c0
    const auto ob = clickOnsets(r.out, 1, (size_t)(c0 - kSr / 2), (size_t)(c0 + 2 * kSr));
    CHECK(!ob.empty(), "B did not start");
    // B может входить с нуля громкости, поэтому первые щелчки бывают не слышны: берём ближайшую долю B от c0
    const double beatEff = 60.0 / (kB.bpm * ratio);
    // реверб-аут: хвост реверберации A звучит и в правом канале, поэтому долю B берём через такт, когда B уже в полную силу
    double first = ob[0];
    if (tech == 8) for (double t : ob) if (t > cT + 4 * beatEff) { first = t; break; }
    const double startErr = first - (cT + beatEff * std::round((first - cT) / beatEff));
    // 2. В перекрытии доли A (левый) и B (правый) совпадают
    double worst = 0;
    int pairs = 0;
    const auto oa = clickOnsets(r.out, 0, (size_t)(c0 - 20 * beatA * kSr), (size_t)cEnd + kSr);
    const auto obb = clickOnsets(r.out, 1, (size_t)c0, (size_t)cEnd);
    double sum = 0;
    if (tech == 1 || tech == 2 || tech == 5 || tech == 11) {
      for (double t : oa) {
        if (t < cT) continue;
        double best = 1e9;
        for (double u : obb) best = std::min(best, std::abs(u - t));
        if (best < 0.1) { worst = std::max(worst, best); ++pairs; }
        { double sg = 1e9; for (double u : obb) if (std::abs(u - t) < std::abs(sg)) sg = u - t; if (std::abs(sg) < 0.1) sum += sg; }
        if (getenv("CM_DEBUG")) { double sg = 1e9; for (double u : obb) if (std::abs(u - t) < std::abs(sg)) sg = u - t; std::printf("      A %.3f  B-A %+.2f ms\n", t - cT, sg * 1000); }
      }
    }
    // 3. Первая доля B продолжает сетку A (по ударам A до c0)
    double gridErr = 0;
    {
      std::vector<double> pre;
      for (double t : oa) {
        if (t >= cT - 0.01) continue;
        if (!pre.empty()) {  // повторы эха и прочее не на долях — мимо
          const double k = (t - pre[0]) / beatA;
          if (std::abs(k - std::round(k)) > 0.1) continue;
        }
        pre.push_back(t);
      }
      CHECK(pre.size() >= 8, "too few A beats before c0");
      double sk = 0, st = 0, skk = 0, skt = 0, N = 0;
      for (double t : pre) {
        const double k = std::round((t - pre[0]) / beatA);
        N += 1; sk += k; st += t; skk += k * k; skt += k * t;
      }
      double p = (N * skt - sk * st) / (N * skk - sk * sk), t0 = (st - p * sk) / N;
      for (int it = 0; it < 3; ++it) {  // без выбросов (повторы эха, хвосты)
        sk = st = skk = skt = N = 0;
        for (double t : pre) {
          const double k = std::round((t - t0) / p);
          if (std::abs(t - (t0 + k * p)) > 0.004) continue;
          N += 1; sk += k; st += t; skk += k * k; skt += k * t;
        }
        if (N < 8) break;
        p = (N * skt - sk * st) / (N * skk - sk * sk); t0 = (st - p * sk) / N;
      }
      if (getenv("CM_DEBUG2")) { for (double t : pre) std::printf("      pre %.4f (k %.3f)\n", t - cT, (t - t0) / p); for (size_t q = 0; q < ob.size() && q < 4; ++q) std::printf("      ob %.4f\n", ob[q] - cT); std::printf("      p %.5f\n", p); }
      // первая доля B, отнесённая к началу перехода (у T3/T8 темп не подогнан — дальше доли расходятся по замыслу)
      const double b0 = first - beatEff * std::round((first - cT) / beatEff);
      gridErr = std::abs(b0 - (t0 + p * std::round((b0 - t0) / p)));
    }
    const double mean = pairs ? sum / pairs : 0;
    std::printf("    timing: B starts %+.2f ms; %d beat pairs, mean %+.2f ms, worst %.2f ms; B on A's grid %.2f ms\n", startErr * 1000,
                pairs, mean * 1000, worst * 1000, gridErr * 1000);
    CHECK(std::abs(startErr) < 0.010, "B start off");  // абсолютная точность анализа (сетка по нейросети)
    CHECK(gridErr < 0.005, "B off A's grid %.2f ms", gridErr * 1000);
    if (tech == 1 || tech == 2 || tech == 5 || tech == 11) {
      CHECK(pairs >= std::max(4.0, bars * 4.0) * 0.9, "too few overlapping beats (%d)", pairs);
      CHECK(std::abs(mean) < 0.002, "beats offset %+.2f ms", mean * 1000);
      CHECK(worst < 0.008, "beats drift %.2f ms", worst * 1000);
    }
    return;
  }
  // 4. Уровень во время перехода не проваливается (окна по 0,5 с) и пик не выше −1 дБFS
  const double before = rmsDb(r.out, (size_t)(c0 - 4 * kSr), (size_t)c0);
  double minRel = 0, maxRel = -100;
  for (int64_t t = c0; t + kSr / 2 < cEnd + 2 * kSr; t += kSr / 2) {
    const double v = rmsDb(r.out, (size_t)t, (size_t)(t + kSr / 2)) - before;
    if (getenv("CM_LEVELS")) std::printf("      %.1f s: %+.1f dB\n", (double)(t - c0) / kSr, v);
    minRel = std::min(minRel, v);
    maxRel = std::max(maxRel, v);
  }
  float peak = 0;
  for (size_t i = (size_t)c0 * 2; i < r.out.size(); ++i) peak = std::max(peak, std::abs(r.out[i]));
  std::printf("    levels: %+.1f…%+.1f dB; peak %.3f\n", minRel, maxRel, peak);
  std::printf("    after: A status %d, B tempo %.4f, stretching %d, underruns %lld\n", s.deck[0].status, s.deck[1].tempo,
              s.deck[1].stretching, (long long)s.underruns);
  const bool cutType = tech == 3 || tech == 7 || tech == 8;
  if (!cutType) CHECK(minRel > -6.0, "level dips %.1f dB", minRel);
  if (tech == 7) {
    // после торможения уходящий (левый канал) молчит
    double l = 0;
    for (int64_t i = c0 + kLim + kSr / 20; i < c0 + kSr; ++i) l = std::max(l, (double)std::abs(r.out[(size_t)i * 2]));
    std::printf("    after brake: A peak %.1e\n", l);
    if (getenv("CM_DEBUG3")) for (int64_t w = c0 - kSr; w < c0 + kSr / 2; w += kSr / 20) { double m = 0; for (int64_t i = w; i < w + kSr / 20; ++i) m = std::max(m, (double)std::abs(r.out[(size_t)(i + kLim) * 2])); std::printf("      %+.2f s: %.1e\n", (double)(w - c0) / kSr, m); }
    CHECK(l < 1e-2, "A not silent after brake");  // −40 дБ: дальше — лишь просачивание B из стерео-тайм-стретча
  }
  if (tech == 8) {
    // хвост реверберации A (левый канал до B — только хвост) после обрыва
    const double tail = 20 * std::log10(std::sqrt([&] { double q = 0; for (int64_t i = c0 + kLim + kSr / 10; i < c0 + kSr / 2; ++i) q += r.out[(size_t)i * 2] * (double)r.out[(size_t)i * 2]; return q / (kSr * 0.4); }()) + 1e-12);
    std::printf("    reverb tail of A after cut: %.1f dBFS\n", tail);
    CHECK(tail > -45, "no reverb tail");
  }
  CHECK(maxRel < 4.0, "level bumps %+.1f dB", maxRel);
  CHECK(peak <= std::pow(10.0, -1.0 / 20) + 1e-6, "peak over ceiling");
  CHECK(s.deck[0].status != CM_PLAYING, "A still playing");
  CHECK(std::abs(s.deck[1].tempo - 1.0) < 1e-9 && s.deck[1].stretching == 0, "B tempo did not return to 1.0");
  CHECK(s.underruns == 0, "underruns");
}

// Порядок треков: подходящий по темпу и тональности впереди; тот же исполнитель, что только что играл, — ниже
static std::string withField(std::string js, const char *key, const std::string &value) {
  const std::string k = std::string("\"") + key + "\":";
  const size_t at = js.find(k);
  if (at == std::string::npos) return js;
  size_t end = at + k.size();
  if (js[end] == '"') end = js.find('"', end + 1) + 1;
  else while (end < js.size() && js[end] != ',' && js[end] != '}') ++end;
  return js.substr(0, at + k.size()) + value + js.substr(end);
}

static void testRank() {
  const std::string good = g_profB;                                                 // 128 BPM, 8B
  const std::string slow = withField(withField(g_profB, "bpm", "92"), "key", "\"3A\"");  // не сводится, тональность спорит
  const std::string clash = withField(g_profB, "key", "\"2A\"");                     // темп тот же, тональность спорит
  auto run = [&](const std::string &cands, const char *opts) {
    char *err = nullptr;
    char *r = cm_rank_next(g_profA.c_str(), cands.c_str(), opts, &err);
    std::string out = r ? r : (err ? err : "?");
    cm_free(r); cm_free(err);
    return out;
  };
  const std::string c1 = "[{\"id\":\"slow\",\"artist\":\"x\",\"profile\":" + slow + "},{\"id\":\"clash\",\"artist\":\"y\",\"profile\":" +
                         clash + "},{\"id\":\"good\",\"artist\":\"z\",\"profile\":" + good + "}]";
  const std::string r1 = run(c1, "{\"intent\":\"balanced\"}");
  std::printf("    %s\n", r1.substr(0, 160).c_str());
  CHECK(r1.find("\"best\":\"good\"") != std::string::npos, "best is not the matching track");
  CHECK(r1.find("\"path\":[\"good\"") != std::string::npos, "path does not start with it");
  // два одинаковых по звуку; у одного исполнитель тот же, что только что играл
  const std::string c2 = "[{\"id\":\"same\",\"artist\":\"band\",\"profile\":" + good + "},{\"id\":\"other\",\"artist\":\"else\",\"profile\":" +
                         good + "}]";
  const std::string r2 = run(c2, "{\"history\":[{\"id\":\"prev\",\"artist\":\"band\",\"energy\":6}]}");
  std::printf("    %s\n", r2.substr(0, 120).c_str());
  CHECK(r2.find("\"best\":\"other\"") != std::string::npos, "artist repeat not penalised");
}

int main(int argc, char **argv) {
  if (argc < 5) {
    std::printf("usage: %s ort_lib mel.onnx beat.onnx workdir\n", argv[0]);
    return 2;
  }
  g_dir = argv[4];
  // треки: для проверок — разведённые по каналам, для демо — по центру
  for (int v = 0; v < 3; ++v) {
    TrackSpec a = kA, b = kB;
    if (v == 1) a.pan = b.pan = 2;
    if (v == 2) a.clicks = b.clicks = true;
    const char *sfx = v == 0 ? "" : (v == 1 ? "_c" : "_k");
    writeWavF(g_dir + "/a" + sfx + ".wav", makeTrack(a, 44100), 44100);
    writeWavF(g_dir + "/b" + sfx + ".wav", makeTrack(b, 44100), 44100);
  }
  char *err = nullptr;
  cm_analyzer *an = cm_analyzer_create(argv[1], argv[2], argv[3], 0, &err);
  if (!an) { std::printf("analyzer: %s\n", err ? err : "?"); return 1; }
  for (int k = 0; k < 2; ++k) {
    char *js = cm_analyze_file(an, (g_dir + (k ? "/b_c.wav" : "/a_c.wav")).c_str(), "", &err);
    if (!js) { std::printf("analyze: %s\n", err ? err : "?"); return 1; }
    (k ? g_profB : g_profA) = js;
    std::printf("profile %c: %.2f BPM, %d/4, key %s, first downbeat %.0f ms, mixOut %s\n", k ? 'B' : 'A', jsonNum(js, "bpm"),
                (int)jsonNum(js, "beatsPerBar"), jsonStr(js, "key").c_str(), jsonNum(js, "firstDownbeatMs"),
                std::string(js).substr(std::string(js).find("\"mixOut\"")).c_str());
    cm_free(js);
  }
  cm_analyzer_destroy(an);

  struct T { int tech; const char *name; } techs[] = {
      {1, "T1 bass swap"}, {2, "T2 filter sweep"}, {3, "T3 echo out"}, {4, "T4 cut"},
      {5, "T5 loop out"}, {7, "T7 brake"}, {8, "T8 reverb out"}, {11, "T11 smooth fade"}};
  for (auto &t : techs) {
    const int before = g_failed;
    std::printf("• %s\n", t.name);
    runTechnique(t.tech, 0);
    if (g_failed == before) runTechnique(t.tech, 1);
    std::printf("  %s\n", g_failed == before ? "ok" : "FAILED");
  }
  {
    const int before = g_failed;
    std::printf("• next-track ranking\n");
    testRank();
    std::printf("  %s\n", g_failed == before ? "ok" : "FAILED");
  }
  std::printf("• demos\n");
  for (auto &t : techs) runTechnique(t.tech, 2);
  std::printf(g_failed ? "\n%d test(s) failed\n" : "\nall tests passed\n", g_failed);
  return g_failed ? 1 : 0;
}

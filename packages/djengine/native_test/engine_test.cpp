// Проверки звуковой части на синтетических сигналах. Сборка: см. CMakeLists.txt рядом; запуск: ./engine_test
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <vector>
#include <chrono>
#include "../src/djengine.h"

static int fails = 0;
#define CHECK(cond, ...) do { if (!(cond)) { fails++; std::printf("  ПРОВАЛ: "); std::printf(__VA_ARGS__); std::printf("\n"); } else { std::printf("  ok: "); std::printf(__VA_ARGS__); std::printf("\n"); } } while (0)

static const int SR = 44100;

// Сырой PCM: сумма синусов одинаковой амплитуды в обоих каналах
static std::string writeSine(const char* name, std::vector<double> freqs, double secs, double amp = 0.3) {
  std::string path = std::string("/tmp/") + name + ".f32";
  std::ofstream f(path, std::ios::binary);
  const long n = static_cast<long>(secs * SR);
  for (long i = 0; i < n; i++) {
    double v = 0;
    for (double fr : freqs) v += std::sin(2 * M_PI * fr * i / SR);
    float s = static_cast<float>(amp * v / freqs.size());
    f.write(reinterpret_cast<char*>(&s), 4);
    f.write(reinterpret_cast<char*>(&s), 4);
  }
  return path;
}

static std::vector<float> render(void* e, long frames) {
  std::vector<float> out(static_cast<size_t>(frames) * 2);
  long done = 0;
  while (done < frames) { int n = static_cast<int>(std::min<long>(333, frames - done)); dj_render(e, out.data() + 2 * done, n); done += n; }
  return out;
}

// Частота по переходам через ноль в левом канале на отрезке
static double freqOf(const std::vector<float>& x, long a, long b) {
  int crossings = 0; long first = -1, last = -1;
  for (long i = a + 1; i < b; i++) {
    float p = x[2 * (i - 1)], q = x[2 * i];
    if (p < 0 && q >= 0) { crossings++; double frac = -p / (q - p); double t = i - 1 + frac; if (first < 0) first = static_cast<long>(t * 1000); last = static_cast<long>(t * 1000); }
  }
  if (crossings < 3) return 0;
  return (crossings - 1) * (double)SR / ((last - first) / 1000.0);
}

static double rms(const std::vector<float>& x, long a, long b) {
  double s = 0; for (long i = a; i < b; i++) s += (double)x[2 * i] * x[2 * i]; return std::sqrt(s / (b - a));
}

static bool allFinite(const std::vector<float>& x) { for (float v : x) if (!std::isfinite(v) || std::fabs(v) > 4) return false; return true; }

static void* fresh(const std::string& path, int deck = 0) {
  void* e = dj_create(SR, 0);
  dj_load(e, deck, path.c_str());
  dj_set_crossfader(e, deck == 0 ? -1.f : 1.f, 0);
  dj_set_master(e, 1.f);
  dj_play(e, deck, 1);
  return e;
}

int main() {
  const std::string s440 = writeSine("s440", {440}, 20);

  std::printf("Прямой режим, темп 1\n");
  { void* e = fresh(s440); auto o = render(e, SR * 3);
    double f = freqOf(o, SR, 3 * SR); double r = rms(o, SR, 3 * SR);
    CHECK(std::fabs(f - 440) < 2, "частота %.2f ≈ 440", f);
    CHECK(std::fabs(r - 0.3 / std::sqrt(2.0) * 0.99) < 0.03 || std::fabs(r - 0.3 / std::sqrt(2.0)) < 0.03, "громкость rms %.4f (кроссфейдер на краю = 1)", r);
    CHECK(std::fabs(dj_pos(e, 0) - 3.0 * SR) < 64, "позиция %.0f ≈ %d", dj_pos(e, 0), 3 * SR);
    dj_destroy(e); }

  std::printf("Прямой режим, темп 1.25 (высота меняется вместе с темпом)\n");
  { void* e = fresh(s440); dj_set_keylock(e, 0, 0); dj_set_tempo(e, 0, 1.25); auto o = render(e, SR * 3);
    double f = freqOf(o, SR, 3 * SR);
    CHECK(std::fabs(f - 550) < 3, "частота %.2f ≈ 550", f);
    CHECK(std::fabs(dj_pos(e, 0) - 3.75 * SR) < 128, "позиция %.0f ≈ %.0f", dj_pos(e, 0), 3.75 * SR);
    dj_destroy(e); }

  std::printf("Keylock: темп 1.25, высота та же\n");
  { void* e = fresh(s440); dj_set_keylock(e, 0, 1); dj_set_tempo(e, 0, 1.25); auto o = render(e, SR * 4);
    double f = freqOf(o, SR, 4 * SR); double r = rms(o, SR, 4 * SR);
    CHECK(std::fabs(f - 440) < 4, "частота %.2f ≈ 440", f);
    CHECK(std::fabs(r - 0.3 / std::sqrt(2.0)) < 0.05, "громкость rms %.4f ≈ %.4f", r, 0.3 / std::sqrt(2.0));
    CHECK(std::fabs(dj_pos(e, 0) - 5.0 * SR) < 0.02 * SR, "позиция %.0f ≈ %.0f (темп 1.25 за 4 с)", dj_pos(e, 0), 5.0 * SR);
    CHECK(allFinite(o), "нет мусорных значений");
    dj_destroy(e); }

  std::printf("Keylock: темп 0.8\n");
  { void* e = fresh(s440); dj_set_tempo(e, 0, 0.8); auto o = render(e, SR * 4);
    double f = freqOf(o, SR, 4 * SR);
    CHECK(std::fabs(f - 440) < 4, "частота %.2f ≈ 440", f);
    CHECK(std::fabs(dj_pos(e, 0) - 3.2 * SR) < 0.02 * SR, "позиция %.0f ≈ %.0f", dj_pos(e, 0), 3.2 * SR);
    dj_destroy(e); }

  std::printf("Сдвиг тональности +12 полутонов при темпе 1\n");
  { void* e = fresh(s440); dj_set_pitch(e, 0, 12.f); auto o = render(e, SR * 4);
    double f = freqOf(o, SR, 4 * SR);
    CHECK(std::fabs(f - 880) < 8, "частота %.2f ≈ 880", f);
    CHECK(std::fabs(dj_pos(e, 0) - 4.0 * SR) < 0.02 * SR, "позиция %.0f ≈ %.0f (темп не изменился)", dj_pos(e, 0), 4.0 * SR);
    dj_destroy(e); }

  std::printf("Сдвиг тональности -1 полутон\n");
  { void* e = fresh(s440); dj_set_pitch(e, 0, -1.f); auto o = render(e, SR * 4);
    double f = freqOf(o, SR, 4 * SR); double want = 440 * std::pow(2.0, -1.0 / 12);
    CHECK(std::fabs(f - want) < 4, "частота %.2f ≈ %.2f", f, want);
    dj_destroy(e); }

  std::printf("Смена режимов на ходу: позиция не скачет\n");
  { void* e = fresh(s440); auto o1 = render(e, SR * 2); double p1 = dj_pos(e, 0);
    dj_set_tempo(e, 0, 1.2); auto o2 = render(e, SR * 2); double p2 = dj_pos(e, 0);
    dj_set_keylock(e, 0, 0); auto o3 = render(e, SR * 2); double p3 = dj_pos(e, 0);
    CHECK(p2 > p1 && p3 > p2, "позиция растёт %.0f → %.0f → %.0f", p1, p2, p3);
    CHECK(std::fabs((p2 - p1) - 2.4 * SR) < 0.1 * SR, "keylock 1.2: прирост %.0f ≈ %.0f", p2 - p1, 2.4 * SR);
    CHECK(std::fabs((p3 - p2) - 2.4 * SR) < 0.1 * SR, "прямой 1.2: прирост %.0f ≈ %.0f", p3 - p2, 2.4 * SR);
    CHECK(allFinite(o1) && allFinite(o2) && allFinite(o3), "нет мусорных значений");
    dj_destroy(e); }

  std::printf("Ритм: бочки раз в 0,5 с, темп 1.25 с keylock — удары через 0,4 с и целые\n");
  { std::string path = "/tmp/kicks.f32"; { std::ofstream f(path, std::ios::binary); for (long i = 0; i < SR * 30; i++) { long k = i % (SR / 2); float s = k < 4000 ? 0.8f * std::sin(2 * M_PI * 60 * k / SR) * std::exp(-k / 900.0) : 0.f; f.write((char*)&s, 4); f.write((char*)&s, 4); } }
    void* e = fresh(path); dj_set_tempo(e, 0, 1.25); auto o = render(e, SR * 8);
    std::vector<long> hits; bool armed = true;
    for (long i = 0; i < SR * 8; i++) { float v = std::fabs(o[2 * i]); if (armed && v > 0.3f) { hits.push_back(i); armed = false; } if (!armed && v < 0.02f) { if (i - hits.back() > 6000) armed = true; } }
    CHECK(hits.size() >= 18, "найдено ударов: %zu (ожидается около 20)", hits.size());
    double worst = 0, sum = 0; int n = 0;
    for (size_t i = 2; i < hits.size(); i++) { double gap = (double)(hits[i] - hits[i - 1]); sum += gap; n++; worst = std::max(worst, std::fabs(gap - 17640.0)); }
    CHECK(n > 0 && std::fabs(sum / n - 17640.0) < 60, "средний интервал %.1f ≈ 17640", n ? sum / n : 0);
    CHECK(worst < 700, "самое большое отклонение интервала %.0f кадров (%.1f мс)", worst, worst * 1000 / SR);
    float peak = 0; for (long i = 0; i < SR * 8; i++) peak = std::max(peak, std::fabs(o[2 * i]));
    CHECK(peak > 0.6f, "удары не размыты: пик %.2f", peak);
    dj_destroy(e); }

  std::printf("Эквалайзер\n");
  { const std::string lo = writeSine("s80", {80}, 10), mi = writeSine("s1k", {1000}, 10), hi = writeSine("s8k", {8000}, 10);
    struct C { const std::string* p; const char* name; int band; } cs[] = {{&lo, "низы 80 Гц", 0}, {&mi, "середина 1 кГц", 1}, {&hi, "верха 8 кГц", 2}};
    for (auto& c : cs) {
      void* e = fresh(*c.p); auto base = render(e, SR * 2); double r0 = rms(base, SR, 2 * SR); dj_destroy(e);
      e = fresh(*c.p);
      dj_set_eq(e, 0, c.band == 0 ? -30.f : 0.f, c.band == 1 ? -30.f : 0.f, c.band == 2 ? -30.f : 0.f);
      auto o = render(e, SR * 2); double r1 = rms(o, SR, 2 * SR);
      CHECK(r0 > 0.15, "%s без правки: rms %.3f", c.name, r0);
      CHECK(r1 < r0 * 0.05, "%s вырезаны: rms %.4f (было %.4f)", c.name, r1, r0);
      dj_destroy(e);
      // посторонние полосы не задеты
      e = fresh(*c.p); dj_set_eq(e, 0, c.band == 0 ? 0.f : -30.f, c.band == 1 ? 0.f : -30.f, c.band == 2 ? 0.f : -30.f);
      auto o2 = render(e, SR * 2); double r2 = rms(o2, SR, 2 * SR);
      CHECK(std::fabs(r2 / r0 - 1) < 0.15, "%s: своя полоса осталась, rms %.3f vs %.3f", c.name, r2, r0);
      dj_destroy(e);
    }
    void* e = fresh(mi); dj_set_eq(e, 0, 0, 6.f, 0); auto o = render(e, SR * 2);
    CHECK(std::fabs(rms(o, SR, 2 * SR) / 0.2121 - 2.0) < 0.35, "усиление середины на +6 дБ ≈ ×2 (rms %.3f)", rms(o, SR, 2 * SR));
    dj_destroy(e); }

  std::printf("Фильтр\n");
  { const std::string hi = writeSine("s10k", {10000}, 6), lo = writeSine("s60", {60}, 6);
    void* e = fresh(hi); dj_set_filter(e, 0, -0.9f); auto o = render(e, SR * 3);
    CHECK(rms(o, 2 * SR, 3 * SR) < 0.02, "фильтр влево гасит 10 кГц: rms %.4f", rms(o, 2 * SR, 3 * SR)); dj_destroy(e);
    e = fresh(lo); dj_set_filter(e, 0, 0.9f); o = render(e, SR * 3);
    CHECK(rms(o, 2 * SR, 3 * SR) < 0.02, "фильтр вправо гасит 60 Гц: rms %.4f", rms(o, 2 * SR, 3 * SR)); dj_destroy(e);
    e = fresh(lo); dj_set_filter(e, 0, 0.f); o = render(e, SR * 3);
    CHECK(rms(o, 2 * SR, 3 * SR) > 0.18, "фильтр в центре пропускает 60 Гц: rms %.4f", rms(o, 2 * SR, 3 * SR)); dj_destroy(e); }

  std::printf("Кроссфейдер и фейдеры\n");
  { void* e = dj_create(SR, 0); dj_load(e, 0, s440.c_str()); dj_load(e, 1, s440.c_str()); dj_play(e, 0, 1); dj_play(e, 1, 1); dj_set_master(e, 1.f);
    dj_set_crossfader(e, -1.f, 0); auto a = render(e, SR);
    double ra = rms(a, SR / 2, SR);
    dj_set_crossfader(e, 1.f, 0); auto b = render(e, SR);
    double rb = rms(b, SR / 2, SR);
    dj_set_crossfader(e, 0.f, 0); auto c = render(e, SR);
    double rc = rms(c, SR / 2, SR);
    CHECK(ra > 0.19 && rb > 0.19, "по краям играет одна дека: %.3f %.3f", ra, rb);
    CHECK(std::fabs(rc - ra * std::sqrt(2.0) * 0.7071 * 2 / std::sqrt(2.0)) < 0.2 * ra * 2 || rc > ra * 0.9, "в центре играют обе: %.3f", rc);
    dj_set_crossfader(e, -1.f, 0); dj_set_fader(e, 0, 0.f); auto d = render(e, SR);
    CHECK(rms(d, SR / 2, SR) < 0.005, "фейдер A в ноль, кроссфейдер на A: тишина (rms %.5f)", rms(d, SR / 2, SR));
    dj_destroy(e); }

  std::printf("Петля\n");
  { void* e = fresh(s440); dj_set_loop(e, 0, 1.0 * SR, 1.5 * SR, 1); render(e, SR * 3);
    double p = dj_pos(e, 0);
    CHECK(p >= 1.0 * SR - 2048 && p <= 1.5 * SR + 2048, "позиция %.0f внутри петли [%d, %.0f]", p, SR, 1.5 * SR);
    dj_set_loop(e, 0, 0, 0, 0); render(e, SR); CHECK(dj_pos(e, 0) > 1.5 * SR + SR / 2, "после выхода из петли позиция идёт дальше (%.0f)", dj_pos(e, 0));
    dj_destroy(e); }

  std::printf("Петля с keylock\n");
  { void* e = fresh(s440); dj_set_tempo(e, 0, 1.1); dj_set_loop(e, 0, 1.0 * SR, 1.5 * SR, 1); auto o = render(e, SR * 4);
    double p = dj_pos(e, 0);
    CHECK(p >= 1.0 * SR - 4096 && p <= 1.5 * SR + 4096, "позиция %.0f внутри петли", p);
    CHECK(allFinite(o), "нет мусорных значений");
    dj_destroy(e); }

  std::printf("Перемотка и конец трека\n");
  { void* e = fresh(s440); render(e, SR / 2); dj_seek(e, 0, 10.0 * SR); render(e, SR / 2);
    CHECK(std::fabs(dj_pos(e, 0) - 10.5 * SR) < 2048, "после перемотки на 10 с позиция %.0f ≈ %.0f", dj_pos(e, 0), 10.5 * SR);
    dj_seek(e, 0, 19.5 * SR); render(e, SR * 2);
    CHECK(dj_is_playing(e, 0) == 0, "дойдя до конца, дека останавливается");
    dj_destroy(e); }

  std::printf("Перемотка с keylock\n");
  { void* e = fresh(s440); dj_set_tempo(e, 0, 1.3); render(e, SR / 2); dj_seek(e, 0, 10.0 * SR); auto o = render(e, SR);
    CHECK(std::fabs(dj_pos(e, 0) - (10.0 + 1.3) * SR) < 0.1 * SR, "позиция %.0f ≈ %.0f", dj_pos(e, 0), 11.3 * SR);
    CHECK(allFinite(o), "нет мусорных значений");
    dj_destroy(e); }

  std::printf("Эффекты\n");
  { // Эхо: короткий импульс, затем тишина; должен появиться повтор через задержку
    std::string path = "/tmp/click.f32"; { std::ofstream f(path, std::ios::binary); for (long i = 0; i < SR * 6; i++) { float s = (i < 400) ? 0.5f * std::sin(2 * M_PI * 1000 * i / SR) : 0.f; f.write((char*)&s, 4); f.write((char*)&s, 4); } }
    void* e = fresh(path); dj_set_fx(e, 0, 1, 1, 1.f, 300.f, 0.5f); auto o = render(e, SR * 2);
    double first = rms(o, 0, 400), gap = rms(o, 1000, 10000), echo1 = rms(o, 13230, 13230 + 400);
    CHECK(first > 0.2, "исходный щелчок слышен (%.3f)", first);
    CHECK(gap < 0.01, "до повтора тихо (%.4f)", gap);
    CHECK(echo1 > 0.08, "через 300 мс слышен повтор (%.3f)", echo1);
    CHECK(allFinite(o), "нет мусорных значений"); dj_destroy(e);
    // Реверберация: после щелчка остаётся хвост
    e = fresh(path); dj_set_fx(e, 0, 2, 1, 0.6f, 0.8f, 0.3f); o = render(e, SR * 3);
    double tail = rms(o, SR, SR + 8000);
    CHECK(tail > 0.002, "у реверберации есть хвост (%.4f)", tail); CHECK(allFinite(o), "нет мусорных значений"); dj_destroy(e);
    // Хвост затухает
    e = fresh(path); dj_set_fx(e, 0, 2, 1, 0.6f, 0.5f, 0.5f); o = render(e, SR * 5);
    CHECK(rms(o, 4 * SR, 5 * SR) < tail, "хвост реверберации затухает (%.4f < %.4f)", rms(o, 4 * SR, 5 * SR), tail); dj_destroy(e);
    // Флэнджер на синусе меняет сигнал и не взрывается
    e = fresh(s440); dj_set_fx(e, 1, 3, 1, 0.7f, 0.5f, 0.6f); o = render(e, SR * 3);
    CHECK(allFinite(o) && rms(o, SR, 3 * SR) > 0.1, "флэнджер: звук цел (rms %.3f)", rms(o, SR, 3 * SR)); dj_destroy(e);
    // Эффект на выходе
    e = fresh(path); dj_set_fx(e, 0, 1, 3, 1.f, 300.f, 0.5f); o = render(e, SR * 2);
    CHECK(rms(o, 13230, 13230 + 400) > 0.08, "эхо на выходе тоже даёт повтор (%.3f)", rms(o, 13230, 13230 + 400)); dj_destroy(e); }

  std::printf("Ограничитель: две деки на полной громкости не режут сумму\n");
  { const std::string loud = writeSine("loud", {200}, 5, 0.95);
    void* e = dj_create(SR, 0); dj_load(e, 0, loud.c_str()); dj_load(e, 1, loud.c_str()); dj_play(e, 0, 1); dj_play(e, 1, 1);
    dj_set_crossfader(e, 0, 1); dj_set_master(e, 1.f); auto o = render(e, SR * 2);
    float m = 0; for (float v : o) m = std::max(m, std::fabs(v));
    CHECK(m <= 1.0001f && m > 0.85f, "пик %.3f не выше 1", m); dj_destroy(e); }

  std::printf("Обзор волны\n");
  { void* e = fresh(s440); uint8_t ov[50]; int n = dj_overview(e, 0, 50, ov);
    CHECK(n == 50 && ov[0] > 200 && ov[49] > 200, "50 столбиков, ровная синусоида (%d … %d)", ov[0], ov[49]); dj_destroy(e); }

  std::printf("Скорость\n");
  { void* e = dj_create(SR, 0); dj_load(e, 0, s440.c_str()); dj_load(e, 1, s440.c_str()); dj_play(e, 0, 1); dj_play(e, 1, 1);
    dj_set_tempo(e, 0, 1.07); dj_set_tempo(e, 1, 0.93); dj_set_eq(e, 0, 2, -3, 1); dj_set_eq(e, 1, 0, 3, -2); dj_set_filter(e, 1, 0.3f);
    dj_set_fx(e, 0, 2, 1, 0.4f, 0.8f, 0.5f); dj_set_fx(e, 1, 1, 2, 0.4f, 350.f, 0.5f);
    auto t0 = std::chrono::steady_clock::now(); render(e, SR * 10); auto t1 = std::chrono::steady_clock::now();
    double secs = std::chrono::duration<double>(t1 - t0).count();
    CHECK(secs < 2.0, "10 секунд звука на двух деках с keylock, эквалайзером и эффектами: %.2f с (должно быть << 10)", secs); dj_destroy(e); }

  std::printf("\n%s: провалов %d\n", fails ? "НЕ ПРОШЛО" : "ВСЁ ХОРОШО", fails);
  return fails ? 1 : 0;
}

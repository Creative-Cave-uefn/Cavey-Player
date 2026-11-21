// Автомикшер (ТЗ, разделы 5 и 6): по профилям двух треков выбирает точки выхода и входа на границах фраз,
// подгоняет темп, выбирает технику перехода и заранее раскладывает её автоматизации по часам движка.
//
// Техники этого этапа: T1 бас-свап (EQ-микс), T2 фильтр-свип, T3 эхо-аут, T4 жёсткая склейка, T11 плавный
// переход (без сетки). Всё — через публичный C API движка (cm_set / cm_ramp / cm_play_at / cm_stop_at),
// поэтому то же самое можно сделать и снаружи; здесь это собрано в одном месте и покрыто тестами.

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "cave_mix.h"

namespace cm {
namespace mix {

// ================================================================ мини-JSON (только чтение)

struct J {
  enum T { NUL, NUM, STR, BOOL, ARR, OBJ } t = NUL;
  double n = 0;
  bool b = false;
  std::string s;
  std::vector<J> a;
  std::vector<std::pair<std::string, J>> o;

  const J *get(const char *k) const {
    for (auto &p : o) if (p.first == k) return &p.second;
    return nullptr;
  }
  double num(const char *k, double def = NAN) const {
    const J *v = get(k);
    return v && v->t == NUM ? v->n : def;
  }
  bool flag(const char *k, bool def = false) const {
    const J *v = get(k);
    return v && v->t == BOOL ? v->b : def;
  }
  std::string str(const char *k, const std::string &def = "") const {
    const J *v = get(k);
    return v && v->t == STR ? v->s : def;
  }
};

class Parser {
 public:
  explicit Parser(const char *p) : p_(p) {}
  bool parse(J &out) {
    ws();
    if (!value(out)) return false;
    ws();
    return *p_ == 0;
  }

 private:
  void ws() { while (*p_ == ' ' || *p_ == '\n' || *p_ == '\r' || *p_ == '\t') ++p_; }
  bool lit(const char *w) {
    const size_t n = std::strlen(w);
    if (std::strncmp(p_, w, n) != 0) return false;
    p_ += n;
    return true;
  }
  bool str(std::string &s) {
    if (*p_ != '"') return false;
    ++p_;
    while (*p_ && *p_ != '"') {
      if (*p_ == '\\') {
        ++p_;
        switch (*p_) {
          case 'n': s += '\n'; break;
          case 't': s += '\t'; break;
          case 'r': s += '\r'; break;
          case 'b': s += '\b'; break;
          case 'f': s += '\f'; break;
          case 'u': {  // \uXXXX → UTF-8 (без суррогатных пар — в профилях их нет)
            unsigned cp = 0;
            for (int i = 1; i <= 4; ++i) {
              const char c = p_[i];
              cp = cp * 16 + (unsigned)(c >= '0' && c <= '9' ? c - '0' : (c | 32) - 'a' + 10);
            }
            p_ += 4;
            if (cp < 0x80) s += (char)cp;
            else if (cp < 0x800) { s += (char)(0xC0 | (cp >> 6)); s += (char)(0x80 | (cp & 63)); }
            else { s += (char)(0xE0 | (cp >> 12)); s += (char)(0x80 | ((cp >> 6) & 63)); s += (char)(0x80 | (cp & 63)); }
            break;
          }
          default: s += *p_;
        }
        ++p_;
      } else {
        s += *p_++;
      }
    }
    if (*p_ != '"') return false;
    ++p_;
    return true;
  }
  bool value(J &v) {
    ws();
    if (*p_ == '{') {
      v.t = J::OBJ;
      ++p_;
      ws();
      if (*p_ == '}') { ++p_; return true; }
      while (true) {
        ws();
        std::string k;
        if (!str(k)) return false;
        ws();
        if (*p_++ != ':') return false;
        J x;
        if (!value(x)) return false;
        v.o.emplace_back(std::move(k), std::move(x));
        ws();
        if (*p_ == ',') { ++p_; continue; }
        if (*p_ == '}') { ++p_; return true; }
        return false;
      }
    }
    if (*p_ == '[') {
      v.t = J::ARR;
      ++p_;
      ws();
      if (*p_ == ']') { ++p_; return true; }
      while (true) {
        J x;
        if (!value(x)) return false;
        v.a.push_back(std::move(x));
        ws();
        if (*p_ == ',') { ++p_; continue; }
        if (*p_ == ']') { ++p_; return true; }
        return false;
      }
    }
    if (*p_ == '"') { v.t = J::STR; return str(v.s); }
    if (lit("true")) { v.t = J::BOOL; v.b = true; return true; }
    if (lit("false")) { v.t = J::BOOL; v.b = false; return true; }
    if (lit("null")) { v.t = J::NUL; return true; }
    char *end = nullptr;
    v.n = std::strtod(p_, &end);
    if (end == p_) return false;
    v.t = J::NUM;
    p_ = end;
    return true;
  }
  const char *p_;
};

// ================================================================ профиль трека

struct Point { int bar; double score; };
struct Section { int bar; std::string type; };

struct Profile {
  bool ok = false;      // разобран
  bool grid = false;    // есть ровная сетка (можно сводить по долям)
  double bpm = 0, barLen = 0, firstBar = 0, firstDownbeat = 0, duration = 0, endSec = 0, introSec = 0;
  int bpb = 4, nBars = 0, firstDownbeatBar = 0;
  int camelotNum = 0;   // 1…12, 0 — неизвестно
  char camelotLetter = 0;
  double keyConf = 0;
  double lufs = -14;
  std::vector<int> energy;
  std::vector<double> vocal;   // доля голоса по тактам 0…1; пусто — неизвестно
  std::vector<Point> mixIn, mixOut;
  std::vector<Section> sections;

  // ровные участки трека с плавающим темпом: начало (для входа) и конец (для выхода); bpm 0 — нет
  struct Edge { double bpm = 0, downbeat = 0, from = 0, to = 0; } inGrid, outGrid;
  // где сетка годится для сведения (у ровного трека — весь трек)
  double gridFrom = 0, gridTo = 1e18;

  double barStart(int i) const { return firstBar + i * barLen; }
  double vocalAt(int i) const { return i >= 0 && i < (int)vocal.size() ? vocal[(size_t)i] : 0.0; }
  double avgVocal(int a, int n) const {
    double s = 0; int c = 0;
    for (int i = a; i < a + n; ++i) if (i >= 0 && i < (int)vocal.size()) { s += vocal[(size_t)i]; ++c; }
    return c ? s / c : 0.0;
  }
  double avgEnergy(int a, int n) const {
    double s = 0; int c = 0;
    for (int i = a; i < a + n; ++i) if (i >= 0 && i < (int)energy.size()) { s += energy[(size_t)i]; ++c; }
    return c ? s / c : 5.0;
  }
};

static bool parseProfileJ(const J &j, Profile &p, std::string &err);
static bool parseProfile(const char *json, Profile &p, std::string &err) {
  J j;
  if (!json || !Parser(json).parse(j) || j.t != J::OBJ) { err = "профиль трека не разобрался"; return false; }
  return parseProfileJ(j, p, err);
}
static bool parseProfileJ(const J &j, Profile &p, std::string &err) {
  if (j.t != J::OBJ) { err = "профиль трека не разобрался"; return false; }
  p.lufs = j.num("lufs", -14);
  if (const J *v = j.get("vocals"); v && v->t == J::ARR)
    for (auto &x : v->a) p.vocal.push_back(x.t == J::NUM ? std::clamp(x.n, 0.0, 1.0) : 0.0);
  p.duration = j.num("durationMs", 0) / 1000;
  p.endSec = j.num("endMs", p.duration * 1000) / 1000;
  p.introSec = j.num("introMs", 0) / 1000;
  p.bpm = j.num("bpm", 0);
  p.bpb = (int)j.num("beatsPerBar", 4);
  if (p.bpb < 2 || p.bpb > 8) p.bpb = 4;
  p.firstDownbeat = j.num("firstDownbeatMs", 0) / 1000;
  const bool variable = j.flag("variableTempo", true);
  if (p.bpm > 40 && p.bpm < 300) {
    p.barLen = 60.0 / p.bpm * p.bpb;
    double t = p.firstDownbeat;
    while (t - p.barLen > 0) t -= p.barLen;  // такты от начала трека — так же, как в анализе
    p.firstBar = t;
    p.firstDownbeatBar = (int)std::lround((p.firstDownbeat - p.firstBar) / p.barLen);
    p.grid = !variable;
  }
  const std::string key = j.str("key");
  if (key.size() >= 2) {
    p.camelotNum = std::atoi(key.c_str());
    p.camelotLetter = key.back();
  }
  p.keyConf = j.num("keyConfidence", 0);
  if (const J *e = j.get("energy"); e && e->t == J::ARR)
    for (auto &x : e->a) p.energy.push_back((int)x.n);
  p.nBars = (int)p.energy.size();
  auto points = [&](const char *k, std::vector<Point> &out) {
    if (const J *v = j.get(k); v && v->t == J::ARR)
      for (auto &x : v->a) out.push_back({(int)x.num("bar", 0), x.num("score", 0)});
  };
  auto edge = [&](const char *k, Profile::Edge &e) {
    if (const J *v = j.get(k); v && v->t == J::OBJ && v->num("bpm", 0) > 40) {
      e.bpm = v->num("bpm", 0);
      e.downbeat = v->num("downbeatMs", 0) / 1000;
      e.from = v->num("fromMs", 0) / 1000;
      e.to = v->num("toMs", 0) / 1000;
    }
  };
  edge("inGrid", p.inGrid);
  edge("outGrid", p.outGrid);
  points("mixIn", p.mixIn);
  points("mixOut", p.mixOut);
  if (const J *v = j.get("sections"); v && v->t == J::ARR)
    for (auto &x : v->a) p.sections.push_back({(int)x.num("startBar", 0), x.str("type")});
  if (p.duration <= 0) { err = "в профиле нет длительности"; return false; }
  p.ok = true;
  return true;
}

// Трек с плавающим темпом, у которого ровный нужный участок (конец — для уходящего, начало — для входящего):
// профиль с сеткой этого участка. Всё, что размечено по тактам общей сетки (энергия, голос, точки, части),
// переносится на такты новой сетки по времени, а сводить можно только внутри участка.
static Profile edgeView(const Profile &p, bool outgoing) {
  const Profile::Edge &e = outgoing ? p.outGrid : p.inGrid;
  if (p.grid || e.bpm <= 0 || p.barLen <= 0) return p;
  Profile q = p;
  q.bpm = e.bpm;
  q.barLen = 60.0 / e.bpm * p.bpb;
  q.firstDownbeat = e.downbeat;
  double t = e.downbeat;
  while (t - q.barLen > 0) t -= q.barLen;
  q.firstBar = t;
  q.firstDownbeatBar = (int)std::lround((e.downbeat - q.firstBar) / q.barLen);
  q.grid = true;
  q.gridFrom = e.from;
  q.gridTo = e.to;
  // такт новой сетки → такт старой (по середине такта)
  auto oldBar = [&](int k) { return (int)std::floor((q.barStart(k) + 0.5 * q.barLen - p.firstBar) / p.barLen); };
  auto newBar = [&](int k) { return (int)std::lround((p.barStart(k) - q.firstBar) / q.barLen); };
  const int n = std::max(0, (int)std::ceil((p.duration - q.firstBar) / q.barLen));
  q.energy.assign((size_t)n, 5);
  for (int k = 0; k < n; ++k) {
    const int o = oldBar(k);
    if (o >= 0 && o < (int)p.energy.size()) q.energy[(size_t)k] = p.energy[(size_t)o];
  }
  q.nBars = p.energy.empty() ? 0 : n;
  if (!p.vocal.empty()) {
    q.vocal.assign((size_t)n, 0.0);
    for (int k = 0; k < n; ++k) q.vocal[(size_t)k] = p.vocalAt(oldBar(k));
  }
  for (auto &m : q.mixIn) m.bar = newBar(m.bar);
  for (auto &m : q.mixOut) m.bar = newBar(m.bar);
  for (auto &x : q.sections) x.bar = newBar(x.bar);
  return q;
}

// ================================================================ планирование

enum Tech { T1 = 1, T2 = 2, T3 = 3, T4 = 4, T5 = 5, T6 = 6, T7 = 7, T8 = 8, T9 = 9, T11 = 11 };

static const char *techName(int t) {
  switch (t) {
    case T1: return "Бас-свап";
    case T2: return "Фильтр";
    case T3: return "Эхо-аут";
    case T4: return "Склейка";
    case T5: return "Петля";
    case T6: return "Спинбэк";
    case T7: return "Торможение";
    case T9: return "Луп-ролл";
    case T8: return "Реверб-аут";
    default: return "Плавный переход";
  }
}

struct Options {
  int style = 1;            // 0 — плавный, 1 — сбалансированный, 2 — энергичный
  int maxBars = 32;
  bool matchTempo = true;
  double maxTempoPct = 8;
  bool keyAware = true;
  bool keyShift = true;     // тональности спорят — сдвинуть B на полутон, если так они сходятся
  bool allowEcho = true, allowCut = true;
  uint64_t seed = 1;
  int prev = 0;             // прошлая техника (для разнообразия)
  int force = 0;            // принудительная техника (для проверки и редактора)
  double gainA = 1, gainB = 1;  // амплитуды дек «как сейчас» (громкость × выравнивание)
  double minLead = 1.5;     // секунд до начала перехода как минимум
  double fadeSec = 8;       // длина плавного перехода T11
};

static Options parseOptions(const char *json) {
  Options o;
  J j;
  if (!json || !Parser(json).parse(j) || j.t != J::OBJ) return o;
  const std::string st = j.str("style", "balanced");
  o.style = st == "smooth" ? 0 : st == "energetic" ? 2 : 1;
  o.maxBars = std::clamp((int)j.num("maxBars", 32), 4, 64);
  o.matchTempo = j.flag("matchTempo", true);
  o.maxTempoPct = std::clamp(j.num("maxTempoPct", 8), 0.0, 16.0);
  o.keyAware = j.flag("keyAware", true);
  o.keyShift = j.flag("keyShift", true);
  o.allowEcho = j.flag("allowEcho", true);
  o.allowCut = j.flag("allowCut", true);
  o.seed = (uint64_t)j.num("seed", 1);
  o.prev = (int)j.num("prev", 0);
  o.force = (int)j.num("force", 0);
  o.gainA = std::max(0.0, j.num("gainA", 1));
  o.gainB = std::max(0.0, j.num("gainB", 1));
  o.minLead = std::clamp(j.num("minLeadSec", 1.5), 0.2, 30.0);
  o.fadeSec = std::clamp(j.num("fadeSec", 8), 1.0, 30.0);
  return o;
}

// Совместимость тональностей по кругу Camelot: та же, соседняя (±1) или параллельная (A↔B того же номера)
static int keyRelation(const Profile &a, const Profile &b) {
  if (a.camelotNum == 0 || b.camelotNum == 0 || a.keyConf < 0.5 || b.keyConf < 0.5) return 0;  // неизвестно
  const int d = std::abs(a.camelotNum - b.camelotNum) % 12;
  const int dist = std::min(d, 12 - d);
  if (a.camelotLetter == b.camelotLetter && dist <= 1) return 1;
  if (dist == 0) return 1;
  return -1;
}

static uint64_t splitmix(uint64_t &x) {
  uint64_t z = (x += 0x9E3779B97F4A7C15ull);
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
  return z ^ (z >> 31);
}

struct Plan {
  int tech = T11;
  bool matched = false;  // темп B подогнан, доли совпадают
  int bars = 0;               // длина в тактах уходящего трека (0 — склейка)
  int outBar = -1, inBar = -1;
  double aOut = 0, bIn = 0;   // секунды трека: где A начинает уходить (или обрывается), с какого места входит B
  double ratio = 1;           // темп B на время перехода
  int64_t c0 = 0, cEnd = 0;   // часы движка: начало и конец
  double loopA = 0, loopB = 0;  // T5: участок A, который крутится петлёй (секунды трека)
  double brakeSec = 0;          // T7: длина торможения, T6: длина спинбэка
  double rollBeats = 0;         // T9: длина луп-ролла в долях
  int pitch = 0;                // сдвиг B в полутонах на время перехода (затем плавно к родной тональности)
  std::string reason;
};

class Automix {
 public:
  Automix(cm_engine *e, int from, int to) : e_(e), A_(from), B_(to) {}

  bool run(const Profile &a, const Profile &b, const Options &o, Plan &plan, std::string &err) {
    cm_state st;
    cm_get_state(e_, &st);
    sr_ = st.sample_rate;
    const cm_deck_state &da = st.deck[A_], &db = st.deck[B_];
    if (da.status != CM_PLAYING) { err = "уходящая дека не играет"; return false; }
    if (db.status != CM_READY) { err = "следующий трек ещё не загружен в деку"; return false; }
    now_ = st.clock;
    posA_ = da.position_sec;
    tempoA_ = da.tempo > 0 ? da.tempo : 1.0;

    // темп: B подгоняется к нынешнему темпу A (с учётом двойного/половинного счёта)
    double ratio = 1;
    bool canMatch = false;
    if (a.grid && b.grid && o.matchTempo) {
      double best = 1e9;
      for (double k : {0.5, 1.0, 2.0}) {
        const double r = tempoA_ * a.bpm / (b.bpm * k);
        if (std::abs(std::log(r)) < best) { best = std::abs(std::log(r)); ratio = r; }
      }
      canMatch = std::abs(ratio - 1) * 100 <= o.maxTempoPct;
      // Разница больше допуска, но не больше двух допусков: темпы сходятся навстречу. За 8 тактов до перехода
      // A плавно меняет темп на полпути, B входит с другой половиной подгонки, после перехода B возвращается к
      // своему темпу. Каждый трек меняется не больше чем на допуск.
      if (!canMatch && std::abs(std::log(ratio)) <= std::log(1 + 2 * o.maxTempoPct / 100.0)) {
        const double half = std::sqrt(ratio);
        tempoT_ = tempoA_ / half;
        ratio = half;
        canMatch = true;
        split_ = true;
      }
      if (!canMatch) ratio = 1;
    }
    int key = o.keyAware ? keyRelation(a, b) : 0;
    // Тональности спорят: если B на полутон выше или ниже сходится с A (по кругу Camelot это ±7 шагов) — на время
    // наложения B сдвигается на этот полутон, после перехода за 32 такта плавно возвращается к своей
    int shift = 0;
    if (key < 0 && o.keyShift) {
      for (int sg : {1, -1}) {
        Profile bs = b;
        bs.camelotNum = ((b.camelotNum - 1 + 7 * sg) % 12 + 12) % 12 + 1;
        if (keyRelation(a, bs) > 0) { shift = sg; key = 1; break; }
      }
    }

    // кандидаты техник с весами (ТЗ, раздел 6.2) и стилем
    std::vector<std::pair<int, double>> cand;
    if (o.force) cand.push_back({o.force, 1});
    else if (!a.grid || b.bpm <= 0) cand = {{T11, 1}};
    else if (!b.grid || !canMatch)
      // темпы не свести (или у B темп плавает): приёмы, которым подгонка не нужна, — обрывы с хвостом (эхо,
      // реверберация), торможение, спинбэк, ролл; плавный — реже: при разных темпах это две ритмики вразнобой
      cand = {{T3, o.allowEcho ? 0.45 : 0}, {T8, o.allowEcho ? 0.35 : 0}, {T11, 0.12},
              {T7, o.allowCut && o.style > 0 ? 0.25 : 0}, {T4, o.allowCut && o.style == 2 ? 0.2 : 0},
              {T6, o.allowCut && o.style > 0 ? 0.25 : 0}, {T9, o.style > 0 ? 0.25 : 0.1}};
    else if (key >= 0)
      cand = {{T1, o.style == 2 ? 0.45 : 0.6}, {T2, 0.25}, {T5, 0.08}, {T4, o.allowCut && o.style > 0 ? 0.15 : 0},
              {T3, o.allowEcho && o.style == 2 ? 0.15 : 0}, {T7, o.allowCut && o.style == 2 ? 0.1 : 0},
              {T8, o.allowEcho ? (o.style == 0 ? 0.1 : 0.05) : 0},
              {T9, o.style == 2 ? 0.25 : o.style == 1 ? 0.15 : 0.04}, {T6, o.allowCut && o.style > 0 ? 0.12 : 0}};
    else
      cand = {{T2, 0.5}, {T1, 0.3}, {T3, o.allowEcho ? 0.2 : 0}, {T8, o.allowEcho ? 0.15 : 0},
              {T7, o.allowCut && o.style > 0 ? 0.1 : 0}, {T9, o.style > 0 ? 0.15 : 0.04},
              {T6, o.allowCut && o.style > 0 ? 0.1 : 0}};
    if (!o.force) {
      // энергичная концовка и энергичный вход — повод для склейки
      const double eA = a.avgEnergy(a.nBars - 16, 16), eB = b.avgEnergy(0, 32);
      if (canMatch && o.allowCut && o.style > 0 && eA >= 7 && eB >= 7)
        for (auto &c : cand) if (c.first == T4) c.second += 0.3;
      // разнообразие: та же техника, что в прошлый раз, — реже
      for (auto &c : cand) if (c.first == o.prev) c.second *= 0.5;
    }
    // порядок: сначала выбранная случайно (по весам), дальше остальные по убыванию веса — на случай, если не влезет
    uint64_t rnd = o.seed * 2654435761ull + 12345;
    double total = 0;
    for (auto &c : cand) total += c.second;
    double pick = (double)(splitmix(rnd) >> 11) / 9007199254740992.0 * total;
    std::vector<int> order;
    for (auto &c : cand) {
      if (c.second <= 0) continue;
      if (pick < c.second && order.empty()) order.push_back(c.first);
      pick -= c.second;
    }
    std::vector<std::pair<int, double>> rest = cand;
    std::sort(rest.begin(), rest.end(), [](auto &x, auto &y) { return x.second > y.second; });
    for (auto &c : rest) if (c.second > 0 && std::find(order.begin(), order.end(), c.first) == order.end()) order.push_back(c.first);
    // короткое аутро не даёт места длинному сведению — тогда петля: A крутит последние такты, пока входит B
    if (canMatch && a.grid && b.grid && std::find(order.begin(), order.end(), (int)T5) == order.end()) order.push_back(T5);
    if (std::find(order.begin(), order.end(), (int)T11) == order.end()) order.push_back(T11);  // запасной — всегда

    for (int t : order) {
      Plan p;
      p.tech = t;
      // плавный переход тоже подгоняет темп, если может: иначе в наложении доли разъезжаются («галоп»)
      p.matched = canMatch && a.grid && b.grid &&
                  (t == T1 || t == T2 || t == T4 || t == T5 || t == T6 || t == T7 || t == T9 || t == T11);
      p.ratio = p.matched ? ratio : 1.0;
      // встречная подгонка темпа: A меняет темп заранее (только когда B подгоняется — иначе A не трогаем)
      rampOn_ = split_ && p.matched;
      // сдвиг тональности — только когда треки звучат вместе (в обрывах и склейке гармонии не накладываются)
      p.pitch = (t == T1 || t == T2 || t == T5 || (t == T11 && p.matched)) ? shift : 0;
      tempoX_ = rampOn_ ? tempoT_ : tempoA_;
      rampS_ = rampOn_ ? 8 * a.barLen : 0;
      if ((t == T1 || t == T2 || t == T4 || t == T5) && !canMatch && !o.force) continue;
      // приёмы-обрывы: B вступает после A, ему сетка нужна только для сильной доли входа (есть и у плавающего)
      const bool cutTech = t == T3 || t == T6 || t == T7 || t == T8 || t == T9;
      if (t != T11 && (!a.grid || (!b.grid && !(cutTech && b.bpm > 0)))) continue;
      if (!fit(a, b, o, p)) continue;
      char why[768];
      char meet[160] = "";
      if (rampOn_) std::snprintf(meet, sizeof(meet), ", навстречу: A ×%.3f за 8 тактов до перехода", tempoX_ / tempoA_);
      char keyTxt[96];
      std::snprintf(keyTxt, sizeof(keyTxt), "%s", key > 0 ? "совместимы" : key < 0 ? "не совместимы" : "неизвестны");
      if (p.pitch) std::snprintf(keyTxt, sizeof(keyTxt), "сведены сдвигом B на %+d полутон", p.pitch);
      else if (shift) std::snprintf(keyTxt, sizeof(keyTxt), "не совместимы (без наложения — не сдвигаем)");
      std::snprintf(why, sizeof(why), "темп %.2f→%.2f BPM (×%.3f%s), тональности %s, техника из %zu кандидатов%s",
                    a.bpm * tempoA_, b.bpm, p.ratio, meet, keyTxt,
                    order.size(),
                    a.vocal.empty() || b.vocal.empty() ? ", вокал не размечен"
                    : vocalAvoided_ > 0 ? ", голоса не накладываются (варианты с наложением отброшены)"
                                        : ", голоса не накладываются");
      p.reason = why;
      schedule(a, b, o, p);
      plan = p;
      return true;
    }
    err = "переход не помещается: трек почти закончился";
    return false;
  }

 private:
  // Часы движка, когда A дойдёт до позиции трека t (A играет с темпом tempoA_)
  // Со встречной подгонкой t — начало перехода: до t − rampS_ A идёт в своём темпе, затем за rampS_ секунд
  // трека плавно (кривая симметрична — в среднем полусумма темпов) приходит к темпу перехода tempoX_.
  int64_t clockAtA(double t) const {
    if (!rampOn_) return now_ + (int64_t)std::llround((t - posA_) / tempoA_ * sr_);
    return now_ + (int64_t)std::llround(((t - rampS_ - posA_) / tempoA_ + rampOut()) * sr_);
  }
  // длительность встречной подгонки темпа A в секундах выхода
  double rampOut() const { return rampS_ * 2 / (tempoA_ + tempoX_); }

  // Подобрать точки и длину для техники; false — не помещается
  // Насколько голоса наложатся: по тактам перехода — меньшая из долей голоса A и B, в среднем. A с петлёй крутит
  // свои loopBars тактов. Порог: больше 0,15 — заметно поют оба сразу
  static constexpr double kClash = 0.15;
  static double clash(const Profile &a, int outBar, const Profile &b, int inBar, int L, int loopBars = 0) {
    if (a.vocal.empty() || b.vocal.empty() || L <= 0) return 0;
    double s = 0;
    for (int k = 0; k < L; ++k) {
      const int ab = loopBars > 0 ? outBar + k % loopBars : outBar + k;
      s += std::min(a.vocalAt(ab), b.vocalAt(inBar + k));
    }
    return s / L;
  }
  bool vocalsKnown_ = false;
  int vocalAvoided_ = 0;  // сколько вариантов отброшено из-за наложения голосов

  bool fit(const Profile &a, const Profile &b, const Options &o, Plan &p) {
    const double lead = posA_ + o.minLead * tempoA_ + rampS_;  // со встречной подгонкой — ещё и место под неё
    const double end = std::min(a.endSec, a.duration) + 0.05;
    if (p.tech == T11) {
      const bool beats = a.grid && b.grid;
      double F = o.fadeSec;
      // обе дорожки ровные, но темп не подогнать — наложение короткое, иначе бочки идут вразнобой
      if (beats && !p.matched) F = std::min(F, 4 * a.barLen / a.bpb);
      // у обоих есть удары, но сетки нет: долгое наложение — две ритмики вразнобой; коротко, как смена трека
      if (!beats && a.bpm > 0 && b.bpm > 0) F = std::min(F, 2.5);
      // с подгонкой — целое число тактов
      if (p.matched) F = std::max(1.0, std::round(F / a.barLen)) * a.barLen;
      double start = end - F;
      // лучше начать с точки выхода, если она в конце трека и до неё не слишком далеко
      for (auto &m : a.mixOut) {
        if (!a.grid) break;
        const double t = a.barStart(m.bar);
        if (t >= lead && t + F <= end && t >= end - 60) { start = t; break; }
      }
      if (start < lead) start = lead;
      // начало — на сильную долю A (если сетка есть): тогда и вход B с его сильной доли совпадёт по фазе
      if (a.grid) {
        const double k = std::ceil((start - a.barStart(0)) / a.barLen - 1e-6);
        const double snapped = a.barStart((int)k);
        if (snapped + 1.0 <= end) start = snapped;
      }
      if (start + 1.0 > end) return false;
      p.aOut = start;
      p.bIn = b.grid ? std::max(0.0, b.barStart(b.firstDownbeatBar)) : std::min(b.introSec, 8.0);
      // голоса накладываются — наложение в один такт (или 2 с без сетки)
      if (a.grid && b.grid) {
        const int ob = (int)std::floor((start - a.firstBar) / a.barLen + 1e-6);
        const int L = std::max(1, (int)std::lround(F / a.barLen));
        if (clash(a, ob, b, b.firstDownbeatBar, L) > kClash) { ++vocalAvoided_; F = std::min(F, a.barLen); }
      } else if (!a.vocal.empty() && !b.vocal.empty() && a.avgVocal(a.nBars - 4, 4) > kClash && b.avgVocal(0, 4) > kClash) {
        F = std::min(F, 2.0);
      }
      p.bars = p.matched ? (int)std::lround(std::min(F, end - start) / a.barLen) : 0;
      p.c0 = clockAtA(start);
      p.cEnd = p.c0 + (int64_t)std::llround(std::min(F, end - start) / tempoX_ * sr_);
      return true;
    }

    if (p.tech == T5) return fitLoop(a, b, o, p, lead, end);

    // точки выхода A: из анализа (по убыванию оценки) и запасные — границы фраз от первой сильной доли
    std::vector<Point> outs = a.mixOut;
    std::sort(outs.begin(), outs.end(), [](auto &x, auto &y) { return x.score > y.score; });
    for (int bar = a.firstDownbeatBar; bar < a.nBars; bar += 8) outs.push_back({bar, 0.1});
    // точки входа B: лучшая из анализа, остальные из анализа, начало; для склейки и торможения — дроп
    std::vector<int> ins;
    // склейка, торможение, спинбэк и ролл — лучше сразу на дроп или энергичную часть
    if (p.tech == T4 || p.tech == T6 || p.tech == T7 || p.tech == T9) {
      for (auto &s : b.sections)
        if ((s.type == "drop" || s.type == "section") && s.bar > 0 && s.bar <= 48 && b.avgEnergy(s.bar, 4) >= 6) { ins.push_back(s.bar); break; }
    }
    for (auto &m : b.mixIn) if (std::find(ins.begin(), ins.end(), m.bar) == ins.end()) ins.push_back(m.bar);
    if (std::find(ins.begin(), ins.end(), b.firstDownbeatBar) == ins.end()) ins.push_back(b.firstDownbeatBar);
    if (ins.size() > 4) ins.resize(4);

    std::vector<int> lengths;
    if (p.tech == T1) {
      for (int L : {32, 16, 8}) if (L <= o.maxBars && !(o.style == 2 && L == 32)) lengths.push_back(L);
    } else if (p.tech == T2) {
      for (int L : {16, 8}) if (L <= o.maxBars && !(o.style == 0 && L == 8 && o.maxBars >= 16)) lengths.push_back(L);
    } else {
      lengths.push_back(0);
    }
    for (int L : lengths) {
      for (const Point &m : outs) {
       for (int inBar : ins) {
        int bar = m.bar;
        if (p.tech == T3 || p.tech == T8) bar += 8;  // эхо- и реверб-аут — в конце фразы аутро: A доигрывает её
        const double t = a.barStart(bar);
        // торможение занимает две доли перед сильной долей, на которой входит B
        const double brake = std::clamp(2 * a.barLen / a.bpb / tempoX_, 0.6, 1.6);
        // спинбэк — две доли (но не короче 0,6 с и не длиннее 1,4 с); ролл — такт (в энергичном стиле — два)
        const double spin = std::clamp(2 * a.barLen / a.bpb / tempoX_, 0.6, 1.4);
        const double rollBeats = o.style == 2 ? 2.0 * a.bpb : (double)a.bpb;
        const double pre = p.tech == T7 ? brake : p.tech == T6 ? spin : p.tech == T9 ? rollBeats * a.barLen / a.bpb / tempoX_ : 0;
        if (t - pre * tempoX_ < lead || t + L * a.barLen > end) continue;
        // у трека с плавающим темпом сетка верна только на ровном участке: сведение — внутри него
        if (t < a.gridFrom || b.barStart(inBar + std::max(L, 1)) > b.gridTo) continue;
        if ((p.tech == T3 || p.tech == T8) && t > end) continue;
        // наложение голосов: в сведении (T1, T2) — по всей длине; в обрывах голос A кончается на точке, но B
        // с первых тактов не должен перебивать хвост эха и реверберации
        if (L > 0 && clash(a, bar, b, inBar, L) > kClash) { ++vocalAvoided_; continue; }
        if ((p.tech == T3 || p.tech == T8) && clash(a, bar - 1, b, inBar, 1) > 0.3) { ++vocalAvoided_; continue; }
        p.inBar = inBar;
        p.bIn = std::max(0.0, b.barStart(inBar));
        p.brakeSec = p.tech == T7 ? brake : p.tech == T6 ? spin : 0;
        p.rollBeats = p.tech == T9 ? rollBeats : 0;
        p.outBar = bar;
        p.aOut = t;
        p.bars = L;
        p.c0 = clockAtA(t);
        const double barOut = a.barLen / tempoX_;
        const double len = p.tech == T3 ? 2 * barOut : p.tech == T8 ? 4 * barOut : (p.tech == T4 || p.tech == T6 || p.tech == T7 || p.tech == T9) ? 0.05 : L * barOut;
        p.cEnd = p.c0 + (int64_t)std::llround(len * sr_);
        return true;
       }
      }
    }
    return false;
  }

  // T5: последние 4 такта A (живые, не затухание) крутятся петлёй; B входит, когда A входит в этот участок,
  // и сводится бас-свапом на 16 тактов (энергичный стиль — 8)
  bool fitLoop(const Profile &a, const Profile &b, const Options &o, Plan &p, double lead, double end) {
    const int L = (o.style == 2 || o.maxBars < 16) ? 8 : 16;
    const double body = a.avgEnergy(a.firstDownbeatBar, std::max(1, a.nBars - a.firstDownbeatBar));
    int last = (int)std::floor((end - a.firstBar) / a.barLen);
    for (int lb = last; lb >= a.firstDownbeatBar + 8; --lb) {
      if ((lb - a.firstDownbeatBar) % 4 != 0) continue;           // петля кончается на границе фразы
      const double t0 = a.barStart(lb - 4), t1 = a.barStart(lb);
      if (t1 > end - 0.05) continue;
      if (t0 < lead + 0.5 || t0 < a.gridFrom) return false;        // участок должен быть впереди и на сетке
      if (a.avgEnergy(lb - 4, 4) < std::max(3.0, 0.6 * body)) continue;  // не затухание и не тишина
      p.outBar = lb - 4;
      p.aOut = t0;
      p.loopA = t0;
      p.loopB = t1;
      p.inBar = b.mixIn.empty() ? b.firstDownbeatBar : b.mixIn[0].bar;
      if (b.barStart(p.inBar + L) > b.gridTo) p.inBar = b.firstDownbeatBar;
      if (b.barStart(p.inBar + L) > b.gridTo) return false;
      if (clash(a, lb - 4, b, p.inBar, L, 4) > kClash) { ++vocalAvoided_; continue; }
      p.bIn = std::max(0.0, b.barStart(p.inBar));
      p.bars = L;
      p.c0 = clockAtA(t0);
      p.cEnd = p.c0 + (int64_t)std::llround(L * a.barLen / tempoX_ * sr_);
      return true;
    }
    return false;
  }

  // Время перехода (секунды от c0) → часы
  int64_t at(const Plan &p, double sec) const { return p.c0 + (int64_t)std::llround(sec * sr_); }

  void ramp(int deck, int param, const Plan &p, double t0, double t1, double v0, double v1, int curve = CM_LINEAR) {
    cm_ramp(e_, deck, param, at(p, t0), at(p, t1), v0, v1, curve);
  }

  void schedule(const Profile &a, const Profile &b, const Options &o, Plan &p) {
    const double bar = a.barLen / tempoX_;  // такт A в секундах выхода (в темпе перехода)
    const double beat = bar / a.bpb;
    const double gA = o.gainA, gB = o.gainB;

    // B: всё к исходному, позиция — точка входа, темп — подогнанный
    cm_clear_automation(e_, B_);
    for (int prm : {CM_EQ_LOW, CM_EQ_MID, CM_EQ_HIGH, CM_FILTER, CM_FILTER_RES, CM_ECHO_SEND, CM_REVERB_SEND}) cm_set(e_, B_, prm, 0.0);
    cm_seek(e_, B_, p.bIn);
    cm_set(e_, B_, CM_TEMPO, p.ratio);
    cm_set(e_, B_, CM_PITCH, (double)p.pitch);
    // встречная подгонка: A плавно приходит к темпу перехода и дальше идёт в нём
    if (rampOn_) {
      cm_clear_automation(e_, A_);
      ramp(A_, CM_TEMPO, p, -rampOut(), 0, tempoA_, tempoX_, CM_SMOOTH);
    }
    // A: на всякий случай нейтральные EQ и фильтр (громкость не трогаем — она «как сейчас»)
    for (int prm : {CM_EQ_LOW, CM_EQ_MID, CM_EQ_HIGH, CM_FILTER, CM_ECHO_SEND, CM_REVERB_SEND}) cm_set(e_, A_, prm, 0.0);

    const double L = p.bars * bar;
    switch (p.tech) {
      case T5:
        cm_loop(e_, A_, p.loopA, p.loopB);
        [[fallthrough]];
      case T1: {
        // B входит без низа, середина и верх поднимаются к свапу; на сильной доле середины перехода
        // низ за одну долю переходит от A к B; затем A уходит
        const double swap = std::floor(p.bars / 2.0) * bar;
        cm_set(e_, B_, CM_GAIN, 0.0);
        cm_set(e_, B_, CM_EQ_LOW, -1.0);
        cm_set(e_, B_, CM_EQ_MID, -0.6);
        cm_set(e_, B_, CM_EQ_HIGH, -0.3);
        ramp(B_, CM_GAIN, p, 0, std::min(4.0, p.bars / 4.0) * bar, 0, gB, CM_EQUAL_POWER_IN);
        ramp(B_, CM_EQ_MID, p, 0, swap, -0.6, 0, CM_SMOOTH);
        ramp(B_, CM_EQ_HIGH, p, 0, swap, -0.3, 0, CM_SMOOTH);
        ramp(B_, CM_EQ_LOW, p, swap, swap + beat, -1, 0, CM_SMOOTH);
        ramp(A_, CM_EQ_LOW, p, swap, swap + beat, 0, -1, CM_SMOOTH);
        ramp(A_, CM_EQ_HIGH, p, swap, L, 0, -0.3, CM_SMOOTH);
        ramp(A_, CM_GAIN, p, swap, L, gA, 0, CM_EQUAL_POWER_OUT);
        break;
      }
      case T2: {
        // A уходит в фильтр высоких частот, B выходит из фильтра низких; низ меняется посередине
        const double half = std::floor(p.bars / 2.0) * bar;
        cm_set(e_, B_, CM_GAIN, 0.0);
        cm_set(e_, B_, CM_FILTER, -0.85);
        cm_set(e_, B_, CM_EQ_LOW, -1.0);
        // до обмена низа фильтры мягкие: иначе низа нет ни у кого и середина проваливается
        ramp(B_, CM_FILTER, p, 0, half, -0.85, -0.35, CM_SMOOTH);
        ramp(B_, CM_FILTER, p, half, L, -0.35, 0, CM_SMOOTH);
        ramp(B_, CM_GAIN, p, 0, L / 4, 0, gB, CM_EQUAL_POWER_IN);
        ramp(B_, CM_EQ_LOW, p, half, half + beat, -1, 0, CM_SMOOTH);
        ramp(A_, CM_FILTER_RES, p, 0, L, 0.15, 0.35, CM_LINEAR);
        ramp(A_, CM_FILTER, p, 0, half, 0, 0.3, CM_SMOOTH);
        ramp(A_, CM_FILTER, p, half, L, 0.3, 0.8, CM_SMOOTH);
        ramp(A_, CM_EQ_LOW, p, half, half + beat, 0, -1, CM_SMOOTH);
        ramp(A_, CM_GAIN, p, L * 0.75, L, gA, 0, CM_EQUAL_POWER_OUT);
        break;
      }
      case T3: {
        // последняя доля фразы A уходит в эхо (3/4 доли, обратная связь 0,55), сухой A обрывается на сильной доле,
        // B стартует с неё же
        cm_set(e_, A_, CM_ECHO_TIME, beat * 0.75);
        cm_set(e_, A_, CM_ECHO_FEEDBACK, 0.55);
        ramp(A_, CM_ECHO_SEND, p, -beat, -beat + 0.002, 0, 1, CM_LINEAR);
        ramp(A_, CM_ECHO_SEND, p, 0, 0.005, 1, 0, CM_LINEAR);
        ramp(A_, CM_GAIN, p, -0.005, 0, gA, 0, CM_LINEAR);
        cm_set(e_, B_, CM_GAIN, gB);
        break;
      }
      case T4: {
        // склейка: A обрывается на сильной доле (микрозатухание 5 мс), B — с той же доли
        ramp(A_, CM_GAIN, p, -0.005, 0, gA, 0, CM_LINEAR);
        cm_set(e_, B_, CM_GAIN, gB);
        break;
      }
      case T7: {
        // торможение: за две доли до сильной доли A «останавливается пластинкой», B входит точно на неё
        cm_brake_at(e_, A_, at(p, -p.brakeSec), p.brakeSec);
        cm_set(e_, B_, CM_GAIN, gB);
        break;
      }
      case T6: {
        // спинбэк: на последние две доли A рвётся назад рукой и останавливается, B входит точно на сильную долю
        cm_backspin_at(e_, A_, at(p, -p.brakeSec), p.brakeSec);
        cm_set(e_, B_, CM_GAIN, gB);
        break;
      }
      case T9: {
        // луп-ролл: последний такт (или два) A повторяется всё короче — доля, полдоли, четверть, восьмая — и уходит
        // вверх фильтром; на сильной доле ролл обрывается, B входит
        const double len = p.rollBeats * beat;
        cm_roll_at(e_, A_, at(p, -len), beat, p.rollBeats);
        ramp(A_, CM_FILTER, p, -len, 0, 0, 0.55, CM_SMOOTH);
        cm_set(e_, B_, CM_GAIN, gB);
        break;
      }
      case T8: {
        // реверб-аут: последний такт A уходит в реверберацию (и чуть в фильтр высоких), сухой A обрывается на сильной
        // доле, хвост реверберации тянется поверх входа B; B поднимается за один такт
        ramp(A_, CM_REVERB_SEND, p, -bar, 0, 0, 1, CM_SMOOTH);
        ramp(A_, CM_FILTER, p, -bar, 0, 0, 0.35, CM_SMOOTH);
        ramp(A_, CM_REVERB_SEND, p, 0, 0.005, 1, 0, CM_LINEAR);
        ramp(A_, CM_GAIN, p, -0.005, 0, gA, 0, CM_LINEAR);
        cm_set(e_, B_, CM_GAIN, 0.0);
        ramp(B_, CM_GAIN, p, 0, bar, 0, gB, CM_EQUAL_POWER_IN);
        break;
      }
      default: {  // T11: кривые равной мощности, без сетки
        const double F = (double)(p.cEnd - p.c0) / sr_;
        cm_set(e_, B_, CM_GAIN, 0.0);
        ramp(A_, CM_GAIN, p, 0, F, gA, 0, CM_EQUAL_POWER_OUT);
        ramp(B_, CM_GAIN, p, 0, F, 0, gB, CM_EQUAL_POWER_IN);
        break;
      }
    }
    // старт B и остановка A — точно по часам
    cm_play_at(e_, B_, p.c0);
    // пока оба играют с подогнанным темпом — B подстраивается к ударам A по живому звуку
    const bool overlap = p.tech == T1 || p.tech == T2 || p.tech == T5 || p.tech == T11;
    // (пустое окно — подстройки нет, итоги прошлого перехода сбрасываются)
    const bool sync = p.matched && overlap && p.cEnd > p.c0;
    cm_sync(e_, B_, A_, p.c0, sync ? p.cEnd : p.c0, std::clamp(beat, 0.2, 2.0));
    // A: после обрыва (эхо-аут, склейка) — сразу, иначе — в конце перехода
    const bool cut = p.tech == T3 || p.tech == T4 || p.tech == T6 || p.tech == T7 || p.tech == T8 || p.tech == T9;
    cm_stop_at(e_, A_, (cut ? p.c0 : p.cEnd) + (int64_t)(0.03 * sr_));
    // после перехода темп B плавно возвращается к родному (за 8 тактов)
    if (std::abs(p.ratio - 1.0) > 1e-6) {
      const double from = (double)(p.cEnd - p.c0) / sr_;
      ramp(B_, CM_TEMPO, p, from, from + 8 * bar, p.ratio, 1.0, CM_SMOOTH);
    }
    // сдвиг тональности уходит медленно (полутон за 32 такта — на слух почти незаметно), A уже не звучит
    if (p.pitch != 0) {
      const double from = (double)(p.cEnd - p.c0) / sr_;
      ramp(B_, CM_PITCH, p, from, from + 32 * bar, (double)p.pitch, 0.0, CM_SMOOTH);
    }
  }

  cm_engine *e_;
  int A_, B_;
  int sr_ = 48000;
  int64_t now_ = 0;
  double posA_ = 0, tempoA_ = 1;
  // встречная подгонка темпа: возможна для этой пары (split_), включена для техники (rampOn_), темп A в переходе
  // (tempoT_ — для подгонки навстречу, tempoX_ — для текущей техники) и длина подгонки в секундах трека A
  bool split_ = false, rampOn_ = false;
  double tempoT_ = 1, tempoX_ = 1, rampS_ = 0;
};

}  // namespace mix
}  // namespace cm

static char *dupStr(const std::string &s) {
  char *p = static_cast<char *>(std::malloc(s.size() + 1));
  if (p) std::memcpy(p, s.c_str(), s.size() + 1);
  return p;
}

extern "C" {

CM_API char *cm_automix(cm_engine *e, int32_t from, int32_t to, const char *profile_from, const char *profile_to,
                        const char *options, char **error_out) {
  using namespace cm::mix;
  std::string err;
  if (!e || from < 0 || from >= CM_DECKS || to < 0 || to >= CM_DECKS || from == to) err = "неверные деки";
  Profile a, b;
  if (err.empty()) parseProfile(profile_from, a, err);
  if (err.empty()) parseProfile(profile_to, b, err);
  Plan p;
  if (err.empty()) {
    const Options o = parseOptions(options);
    Automix m(e, from, to);
    m.run(edgeView(a, true), edgeView(b, false), o, p, err);
  }
  if (!err.empty()) {
    if (error_out) *error_out = dupStr(err);
    return nullptr;
  }
  char buf[2048];
  std::string reason;
  for (char c : p.reason) { if (c == '"' || c == '\\') reason += '\\'; reason += c; }
  std::snprintf(buf, sizeof(buf),
                "{\"technique\":\"T%d\",\"name\":\"%s\",\"bars\":%d,\"outBar\":%d,\"inBar\":%d,\"aOutSec\":%.3f,\"bInSec\":%.3f,"
                "\"tempoRatio\":%.5f,\"startClock\":%lld,\"endClock\":%lld,\"loopSec\":[%.3f,%.3f],\"brakeSec\":%.3f,"
                "\"pitchShift\":%d,\"rollBeats\":%.0f,\"reason\":\"%s\"}",
                p.tech, techName(p.tech), p.bars, p.outBar, p.inBar, p.aOut, p.bIn, p.ratio, (long long)p.c0,
                (long long)p.cEnd, p.loopA, p.loopB, p.brakeSec, p.pitch, p.rollBeats, reason.c_str());
  return dupStr(buf);
}

CM_API void cm_automix_cancel(cm_engine *e, int32_t from, int32_t to, double gain_from, double gain_to) {
  if (!e) return;
  for (int d : {from, to}) {
    if (d < 0 || d >= CM_DECKS) continue;
    cm_clear_automation(e, d);
    cm_cancel_schedule(e, d);
    for (int prm : {CM_EQ_LOW, CM_EQ_MID, CM_EQ_HIGH, CM_FILTER, CM_FILTER_RES, CM_ECHO_SEND, CM_REVERB_SEND, CM_PITCH})
      cm_set(e, d, prm, 0.0);
    cm_set(e, d, CM_TEMPO, 1.0);
  }
  if (from >= 0 && from < CM_DECKS) cm_set(e, from, CM_GAIN, gain_from);
  if (to >= 0 && to < CM_DECKS) cm_set(e, to, CM_GAIN, gain_to);
}

}  // extern "C"

// ================================================================ порядок треков
//
// Какой из следующих в очереди треков поставить дальше. Идея — из «Adaptive AutoDJ» (ветка dj-v2-review-fixes):
// оценка каждой пары «текущий → кандидат» и характер сета (повторы исполнителей, ход энергии), поиск лучшего
// пути на несколько треков вперёд. Оценки — по нашему же анализу (темп, сетка, тональность, энергия, громкость).

namespace cm {
namespace mix {

struct Cand { std::string id, artist; Profile p; };
struct Hist { std::string id, artist; double energy = 5; };

enum Intent { BALANCED, RISE, RELAX };

struct PairScore { double total = 0, tempo = 0, key = 0, energy = 0, mix = 0, loud = 0, vocal = 0.5; std::string why; };

static double bodyEnergy(const Profile &p) { return p.avgEnergy(p.firstDownbeatBar, std::max(1, p.nBars - p.firstDownbeatBar)); }

static PairScore pairScore(const Profile &a0, const Profile &b0, double maxTempoPct) {
  const Profile a = edgeView(a0, true), b = edgeView(b0, false);
  PairScore s;
  std::string why;
  if (a.grid && b.grid) {
    double best = 1e9;
    for (double k : {0.5, 1.0, 2.0}) best = std::min(best, std::abs(std::log(a.bpm / (b.bpm * k))));
    const double pct = (std::exp(best) - 1) * 100;
    // до двух допусков сводится встречной подгонкой (оба трека меняют темп) — хуже, но не «не сводится»
    s.tempo = pct <= maxTempoPct ? std::exp(-pct / 4) : pct <= 2 * maxTempoPct ? 0.5 * std::exp(-pct / 4) + 0.1 : 0.1;
    char buf[64]; std::snprintf(buf, sizeof buf, "темп %.0f→%.0f (%.1f%%)", a.bpm, b.bpm, pct); why += buf;
  } else {
    s.tempo = 0.4;
    why += "темп не сводится по долям";
  }
  const int kr = keyRelation(a, b);
  // спорят, но сходятся сдвигом B на полутон (автомикс так и сделает на время наложения)
  bool shiftable = false;
  if (kr < 0)
    for (int sg : {1, -1}) {
      Profile bs = b;
      bs.camelotNum = ((b.camelotNum - 1 + 7 * sg) % 12 + 12) % 12 + 1;
      if (keyRelation(a, bs) > 0) shiftable = true;
    }
  s.key = kr > 0 ? 1.0 : kr == 0 ? 0.5 : shiftable ? 0.6 : 0.15;
  why += kr > 0 ? ", тональности совместимы" : shiftable ? ", тональности сходятся сдвигом на полутон" : kr < 0 ? ", тональности спорят" : "";
  // энергия: конец A против начала B
  const double eA = a.avgEnergy(a.nBars - 16, 16), eB = b.avgEnergy(0, 32);
  s.energy = std::exp(-std::abs(eA - eB) / 3.0);
  s.loud = std::exp(-std::abs(a.lufs - b.lufs) / 6.0);
  double mo = 0, mi = 0;
  for (auto &m : a.mixOut) mo = std::max(mo, m.score);
  for (auto &m : b.mixIn) mi = std::max(mi, m.score);
  s.mix = (a.mixOut.empty() ? 0.3 : mo) * 0.5 + (b.mixIn.empty() ? 0.3 : mi) * 0.5;
  // голоса: конец A и начало B, где идёт сведение; известно только при разметке вокала у обоих
  if (!a.vocal.empty() && !b.vocal.empty()) {
    const double c = std::min(a.avgVocal(a.nBars - 16, 16), b.avgVocal(0, 16));
    s.vocal = 1.0 - std::min(1.0, c / 0.3);
    if (c > 0.15) why += ", поют оба на стыке";
  }
  s.total = 0.31 * s.tempo + 0.22 * s.key + 0.18 * s.energy + 0.09 * s.mix + 0.08 * s.loud + 0.12 * s.vocal;
  s.why = why;
  return s;
}

// характер сета: не повторять трек и исполнителя, энергия — по замыслу (ровно, вверх, вниз)
static double setScore(const std::vector<Hist> &h, const Cand &c, Intent intent) {
  double sc = 0;
  const int n = (int)h.size();
  for (int i = 0; i < std::min(n, 8); ++i) {
    const Hist &x = h[(size_t)(n - 1 - i)];
    const double w = 1.0 / (i + 1);
    if (x.id == c.id) sc -= 0.3 * w;
    if (!c.artist.empty() && x.artist == c.artist) sc -= 0.1 * w;
  }
  if (n == 0) return sc;
  const double last = h.back().energy, e = bodyEnergy(c.p);
  const double target = intent == RISE ? std::min(10.0, last + 0.7) : intent == RELAX ? std::max(1.0, last - 0.7) : last;
  sc += 0.12 * std::exp(-std::abs(e - target) / 2.0);
  return sc;
}

struct Path { std::vector<int> ids; double score = 0; };

}  // namespace mix
}  // namespace cm

extern "C" {

CM_API char *cm_rank_next(const char *current_profile, const char *candidates, const char *options, char **error_out) {
  using namespace cm::mix;
  std::string err;
  Profile cur;
  std::vector<Cand> cands;
  std::vector<Hist> hist;
  Intent intent = BALANCED;
  double maxTempoPct = 8;
  int horizon = 3;
  if (!parseProfile(current_profile, cur, err)) err = "профиль текущего трека: " + err;
  J cj, oj;
  if (err.empty() && (!candidates || !Parser(candidates).parse(cj) || cj.t != J::ARR)) err = "список кандидатов не разобрался";
  if (err.empty()) {
    for (auto &x : cj.a) {
      Cand c;
      c.id = x.str("id");
      c.artist = x.str("artist");
      const J *pj = x.get("profile");
      std::string e2;
      if (c.id.empty() || !pj || !parseProfileJ(*pj, c.p, e2)) continue;  // без профиля — не участвует
      cands.push_back(std::move(c));
      if (cands.size() >= 8) break;
    }
    if (cands.empty()) err = "нет кандидатов с разбором";
  }
  if (err.empty() && options && Parser(options).parse(oj) && oj.t == J::OBJ) {
    const std::string in = oj.str("intent", "balanced");
    intent = in == "rise" ? RISE : in == "relax" ? RELAX : BALANCED;
    maxTempoPct = std::clamp(oj.num("maxTempoPct", 8), 0.0, 16.0);
    horizon = std::clamp((int)oj.num("horizon", 3), 1, 4);
    if (const J *h = oj.get("history"); h && h->t == J::ARR)
      for (auto &x : h->a) hist.push_back({x.str("id"), x.str("artist"), x.num("energy", 5)});
  }
  if (!err.empty()) {
    if (error_out) *error_out = dupStr(err);
    return nullptr;
  }
  if (hist.empty() || hist.back().id.empty()) hist.push_back({"", "", bodyEnergy(cur)});
  // поиск лучшего пути (лучом) на horizon треков вперёд; дальние шаги весят меньше
  const int N = (int)cands.size();
  std::vector<std::vector<PairScore>> pair((size_t)N, std::vector<PairScore>((size_t)N));
  std::vector<PairScore> first((size_t)N);
  for (int i = 0; i < N; ++i) {
    first[(size_t)i] = pairScore(cur, cands[(size_t)i].p, maxTempoPct);
    for (int j = 0; j < N; ++j) if (i != j) pair[(size_t)i][(size_t)j] = pairScore(cands[(size_t)i].p, cands[(size_t)j].p, maxTempoPct);
  }
  std::vector<Path> beam{Path{}};
  for (int depth = 0; depth < std::min(horizon, N); ++depth) {
    std::vector<Path> next;
    for (auto &path : beam) {
      std::vector<Hist> h = hist;
      for (int id : path.ids) h.push_back({cands[(size_t)id].id, cands[(size_t)id].artist, bodyEnergy(cands[(size_t)id].p)});
      for (int j = 0; j < N; ++j) {
        if (std::find(path.ids.begin(), path.ids.end(), j) != path.ids.end()) continue;
        const double ps = path.ids.empty() ? first[(size_t)j].total : pair[(size_t)path.ids.back()][(size_t)j].total;
        Path q = path;
        q.ids.push_back(j);
        q.score += std::pow(0.7, depth) * (ps + setScore(h, cands[(size_t)j], intent));
        next.push_back(std::move(q));
      }
    }
    std::sort(next.begin(), next.end(), [](const Path &x, const Path &y) { return x.score > y.score; });
    if (next.size() > 6) next.resize(6);
    beam = std::move(next);
  }
  std::string out = "{\"best\":\"";
  auto esc = [](const std::string &v) { std::string r; for (char c : v) { if (c == '"' || c == '\\') r += '\\'; r += c; } return r; };
  out += esc(cands[(size_t)beam[0].ids[0]].id) + "\",\"path\":[";
  for (size_t i = 0; i < beam[0].ids.size(); ++i) out += (i ? ",\"" : "\"") + esc(cands[(size_t)beam[0].ids[i]].id) + "\"";
  out += "],\"candidates\":[";
  for (int i = 0; i < N; ++i) {
    const PairScore &p = first[(size_t)i];
    char buf[512];
    std::snprintf(buf, sizeof buf,
                  "%s{\"id\":\"%s\",\"score\":%.3f,\"set\":%.3f,\"tempo\":%.2f,\"key\":%.2f,\"energy\":%.2f,\"mix\":%.2f,\"loud\":%.2f,"
                  "\"vocal\":%.2f,\"why\":\"%s\"}",
                  i ? "," : "", esc(cands[(size_t)i].id).c_str(), p.total, setScore(hist, cands[(size_t)i], intent), p.tempo, p.key,
                  p.energy, p.mix, p.loud, p.vocal, esc(p.why).c_str());
    out += buf;
  }
  out += "]}";
  return dupStr(out);
}

}  // extern "C"

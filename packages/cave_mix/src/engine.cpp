// Cavey Mix: реализация движка. Описание API — в cave_mix.h.
//
// Устройство:
//  • У каждой деки свой поток декодера: он читает файл, приводит частоту к частоте движка
//    качественным ресемплером Rubber Band и складывает блоки по 1024 кадра в очередь.
//  • Аудиопоток забирает блоки в кольцевой буфер деки (кадры адресуются абсолютной позицией в треке),
//    читает из него звук, прогоняет через тайм-стретч (только когда темп ≠ 1), EQ, фильтр, громкость,
//    складывает деки, пропускает через лимитер.
//  • Пока темп деки 1.0, звук идёт напрямую, бит-в-бит. Тайм-стретч Rubber Band R3 включается
//    заранее, до начала изменения темпа, и подменяет прямой звук плавной сшивкой; после возврата к 1.0
//    так же плавно отключается.
//  • Команды из API идут в аудиопоток через очередь без блокировок, состояние обратно — через seqlock.

#include "cave_mix.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "dsp.h"
#include "readers.h"
#include "spsc.h"
#include "third_party/miniaudio/miniaudio.h"
#include "third_party/rubberband/rubberband/RubberBandStretcher.h"
#include "third_party/rubberband/src/common/Resampler.h"


namespace cm {

constexpr int kBlock = 1024;          // кадров в блоке декодера
constexpr int kPool = 192;            // блоков на деку (~4 с при 48 кГц)
constexpr int kRing = 1 << 16;        // кадров в кольце деки (~1,4 с)
constexpr int kSub = 32;              // шаг пересчёта фильтров и темпа, кадров
constexpr int kXfade = 256;           // сшивка прямого звука и тайм-стретча, кадров
constexpr int kDeclick = 128;         // микрозатухание при паузе/перемотке, кадров
constexpr int kMaxSegs = 32;          // отрезков автоматизации на параметр
constexpr int kStretchMax = 1024;     // наибольший кусок, который отдаём тайм-стретчу

// ---------------------------------------------------------------- Блоки декодера

struct Block {
  uint32_t gen = 0;
  int64_t frame = 0;  // абсолютная позиция первого кадра блока (в кадрах движка)
  int32_t n = 0;
  bool eof = false;
  float data[kBlock * 2];
};

// ---------------------------------------------------------------- Команды

enum CmdType : int32_t {
  C_SET, C_RAMP, C_CLEAR_AUTO, C_PLAY_AT, C_PAUSE, C_STOP_AT, C_SEEK, C_LOAD, C_UNLOAD, C_MASTER_VOL, C_PAUSED,
  C_CANCEL_SCHEDULE, C_LOOP, C_BRAKE, C_SYNC
};

struct Cmd {
  CmdType type;
  int32_t deck = 0;
  int32_t param = 0;
  int32_t curve = 0;
  int64_t a = 0, b = 0;
  double x = 0, y = 0;
  uint32_t gen = 0;
  int32_t loadId = 0;
};

// ---------------------------------------------------------------- Автоматизация

struct Seg {
  int64_t a, b;
  double from, to;
  int32_t curve;
};

inline double curveShape(int curve, double t, double from, double to) {
  t = std::clamp(t, 0.0, 1.0);
  switch (curve) {
    case CM_EQUAL_POWER_IN: return from + (to - from) * std::sin(t * kPi / 2);
    case CM_EQUAL_POWER_OUT: return to + (from - to) * std::cos(t * kPi / 2);
    case CM_SMOOTH: return from + (to - from) * (t * t * (3 - 2 * t));
    case CM_STEP: return t >= 1.0 ? to : from;
    default: return from + (to - from) * t;
  }
}

struct Lane {
  Seg segs[kMaxSegs];
  int count = 0;
  double base = 0;  // значение вне отрезков

  void add(const Seg &s) {
    if (s.b <= s.a) {  // нулевая длина — мгновенная установка в момент a
      Seg z = s; z.b = s.a + 1; z.curve = CM_STEP; z.from = s.to;
      add(z);
      return;
    }
    if (count >= kMaxSegs) return;
    // вставка по возрастанию начала
    int i = count;
    while (i > 0 && segs[i - 1].a > s.a) { segs[i] = segs[i - 1]; --i; }
    segs[i] = s;
    ++count;
  }
  void clear() { count = 0; }

  // значение в момент clock; прошедшие отрезки выбрасываются, их конечное значение становится базой
  double at(int64_t clock) {
    while (count > 0 && segs[0].b <= clock) {
      base = segs[0].to;
      for (int i = 1; i < count; ++i) segs[i - 1] = segs[i];
      --count;
    }
    if (count > 0 && segs[0].a <= clock) {
      const Seg &s = segs[0];
      return curveShape(s.curve, double(clock - s.a) / double(s.b - s.a), s.from, s.to);
    }
    return base;
  }
  // значение в момент clock без выбрасывания прошедших отрезков (можно спрашивать и о будущем)
  double peek(int64_t clock) const {
    double v = base;
    for (int i = 0; i < count; ++i) {
      const Seg &s = segs[i];
      if (s.b <= clock) { v = s.to; continue; }
      if (s.a <= clock) return curveShape(s.curve, double(clock - s.a) / double(s.b - s.a), s.from, s.to);
      break;
    }
    return v;
  }
  // есть ли отрезок, который идёт сейчас или начнётся в пределах horizon кадров
  bool activeWithin(int64_t clock, int64_t horizon) const {
    for (int i = 0; i < count; ++i)
      if (segs[i].a <= clock + horizon && segs[i].b > clock) return true;
    return false;
  }
};

// ---------------------------------------------------------------- Источник (поток декодера)

class Source {
 public:
  Source() {
    for (int i = 0; i < kPool; ++i) {
      blocks_[i] = std::make_unique<Block>();
      free_.push(blocks_[i].get());
    }
  }
  ~Source() { stop(); }

  void start(int sampleRate) {
    rate_ = sampleRate;
    thread_ = std::thread([this] { run(); });
  }
  void stop() {
    {
      std::lock_guard<std::mutex> g(m_);
      quit_ = true;
    }
    cv_.notify_all();
    if (thread_.joinable()) thread_.join();
    closeDecoder();
  }

  // Запросы из потока API
  void requestLoad(const std::string &path, double startSec, uint32_t gen, int32_t loadId) {
    {
      std::lock_guard<std::mutex> g(m_);
      req_ = Req{Req::LOAD, path, startSec, gen, loadId};
      hasReq_ = true;
    }
    cv_.notify_all();
  }
  void requestSeek(double sec, uint32_t gen) {
    {
      std::lock_guard<std::mutex> g(m_);
      // перемотка во время загрузки: загрузка остаётся, меняется только стартовая позиция
      if (hasReq_ && req_.kind == Req::LOAD) { req_.sec = sec; req_.gen = gen; }
      else { req_ = Req{Req::SEEK, "", sec, gen, 0}; hasReq_ = true; }
    }
    cv_.notify_all();
  }
  void requestUnload(uint32_t gen) {
    {
      std::lock_guard<std::mutex> g(m_);
      req_ = Req{Req::UNLOAD, "", 0, gen, 0};
      hasReq_ = true;
    }
    cv_.notify_all();
  }

  // Для аудиопотока
  Spsc<Block *, 256> filled;
  void recycle(Block *b) { free_.push(b); }

  // Опубликованное состояние
  std::atomic<int32_t> status{CM_EMPTY};
  std::atomic<int32_t> loadedId{0};
  std::atomic<double> duration{0.0};
  std::atomic<int64_t> lengthFrames{-1};  // длина в кадрах движка, −1 — неизвестна

  std::string error() {
    std::lock_guard<std::mutex> g(m_);
    return err_;
  }
  void setFfmpeg(const std::string &path) {
    std::lock_guard<std::mutex> g(m_);
    ffmpeg_ = path;
  }
  // Каким декодером открыт текущий файл (для журнала)
  std::atomic<const char *> decoderKind{""};

 private:
  struct Req {
    enum Kind { LOAD, SEEK, UNLOAD } kind = LOAD;
    std::string path;
    double sec = 0;
    uint32_t gen = 0;
    int32_t loadId = 0;
  };

  void run() {
    std::vector<float> native((size_t)kBlock * 2), conv;
    while (true) {
      Req r;
      bool have = false;
      {
        std::unique_lock<std::mutex> lk(m_);
        // ждём запроса; если есть что декодировать — просыпаемся каждые 3 мс проверить место в очереди
        cv_.wait_for(lk, std::chrono::milliseconds(open_ && !eof_ ? 3 : 50), [this] { return quit_ || hasReq_; });
        if (quit_) return;
        if (hasReq_) { r = req_; hasReq_ = false; have = true; }
      }
      if (have) handle(r);
      // декодируем, пока есть свободные блоки
      while (open_ && !eof_) {
        {
          std::lock_guard<std::mutex> g(m_);
          if (hasReq_ || quit_) break;
        }
        if (!produceBlock(native, conv)) break;
      }
    }
  }

  void handle(const Req &r) {
    if (r.kind == Req::LOAD) {
      closeDecoder();
      status.store(CM_LOADING);
      duration.store(0.0);
      lengthFrames.store(-1);
      if (!openDecoder(r.path)) {
        status.store(CM_ERROR);
        loadedId.store(r.loadId);
        return;
      }
      gen_ = r.gen;
      seekTo(r.sec);
      decoderKind.store(reader_->kind());
      status.store(CM_READY);
      loadedId.store(r.loadId);  // последним: аудиопоток считает загрузку законченной по совпадению id
    } else if (r.kind == Req::SEEK) {
      gen_ = r.gen;
      if (open_) seekTo(r.sec);
    } else {
      gen_ = r.gen;
      closeDecoder();
      status.store(CM_EMPTY);
    }
  }

  bool openDecoder(const std::string &path) {
    reader_ = openMiniaudio(path);
    if (!reader_) {
      std::string ff, err;
      {
        std::lock_guard<std::mutex> g(m_);
        ff = ffmpeg_;
      }
      reader_ = openFfmpeg(ff, path, err);
      if (!reader_) {
        std::lock_guard<std::mutex> g(m_);
        err_ = err;
        return false;
      }
    }
    open_ = true;
    nativeRate_ = reader_->rate();
    const double dur = reader_->durationSec();
    if (dur > 0) {
      duration.store(dur);
      lengthFrames.store((int64_t)std::llround(dur * rate_));
    }
    if (nativeRate_ != rate_) {
      RubberBand::Resampler::Parameters p;
      p.quality = RubberBand::Resampler::Best;
      p.dynamism = RubberBand::Resampler::RatioMostlyFixed;
      p.ratioChange = RubberBand::Resampler::SuddenRatioChange;
      p.initialSampleRate = nativeRate_;
      p.maxBufferSize = kBlock;
      resampler_ = std::make_unique<RubberBand::Resampler>(p, 2);
    }
    return true;
  }

  void closeDecoder() {
    reader_.reset();
    open_ = false;
    eof_ = eofPending_ = eofSent_ = false;
    resampler_.reset();
    stage_.clear();
  }

  void seekTo(double sec) {
    sec = std::max(0.0, sec);
    reader_->seek(sec);
    nextFrame_ = (int64_t)std::llround(sec * rate_);
    eof_ = false;
    stage_.clear();
    eofPending_ = eofSent_ = false;
    if (resampler_) resampler_->reset();
  }

  // Прочитать кусок файла, привести частоту, выложить полные блоки. false — места нет.
  bool produceBlock(std::vector<float> &native, std::vector<float> &conv) {
    // выкладываем то, что уже накоплено
    while ((int)stage_.size() >= kBlock * 2 || (eofPending_ && !stage_.empty())) {
      if (!emit()) return false;
    }
    if (eofPending_) {
      if (!eofSent_) {  // файл кончился ровно на границе блока: отдельный пустой блок с меткой конца
        Block *b = nullptr;
        if (!free_.pop(b)) return false;
        b->gen = gen_; b->frame = nextFrame_; b->n = 0; b->eof = true;
        filled.push(b);  // ёмкость очереди больше пула — место есть всегда
      }
      eofPending_ = false;
      eofSent_ = false;
      eof_ = true;
      return true;
    }
    if (free_.size() == 0) return false;

    const int got = reader_->read(native.data(), kBlock);
    const bool end = got < kBlock;
    if (resampler_) {
      const double ratio = (double)rate_ / nativeRate_;
      const int space = (int)std::ceil(kBlock * ratio) + 64;
      conv.resize((size_t)space * 2);
      int out = resampler_->resampleInterleaved(conv.data(), space, native.data(), (int)got, ratio, end);
      if (out > 0) appendStage(conv.data(), out);
    } else if (got > 0) {
      appendStage(native.data(), (int)got);
    }
    if (end) eofPending_ = true;
    return true;
  }

  void appendStage(const float *p, int frames) { stage_.insert(stage_.end(), p, p + (size_t)frames * 2); }

  bool emit() {
    Block *b = nullptr;
    if (!free_.pop(b)) return false;
    const int n = std::min<int>(kBlock, (int)stage_.size() / 2);
    b->gen = gen_;
    b->frame = nextFrame_;
    b->n = n;
    std::memcpy(b->data, stage_.data(), (size_t)n * 2 * sizeof(float));
    stage_.erase(stage_.begin(), stage_.begin() + (size_t)n * 2);
    nextFrame_ += n;
    b->eof = eofPending_ && stage_.empty();
    if (b->eof) eofSent_ = true;
    filled.push(b);  // ёмкость очереди больше пула — место есть всегда
    return true;
  }

  int rate_ = 48000;
  int nativeRate_ = 48000;
  std::unique_ptr<Reader> reader_;
  std::string ffmpeg_;  // путь к ffmpeg для форматов, которые miniaudio не читает
  bool open_ = false, eof_ = false, eofPending_ = false, eofSent_ = false;
  std::unique_ptr<RubberBand::Resampler> resampler_;
  std::vector<float> stage_;
  int64_t nextFrame_ = 0;
  uint32_t gen_ = 0;

  std::unique_ptr<Block> blocks_[kPool];
  Spsc<Block *, 256> free_;

  std::thread thread_;
  std::mutex m_;
  std::condition_variable cv_;
  bool quit_ = false;
  bool hasReq_ = false;
  Req req_;
  std::string err_;
};

// ---------------------------------------------------------------- Дека (аудиопоток)

class Deck {
 public:
  void setup(int sampleRate) {
    sr_ = sampleRate;
    ring_.assign((size_t)kRing * 2, 0.0f);
    iso_.setup(sr_);
    flt_.setup(sr_);
    using RB = RubberBand::RubberBandStretcher;
    rb_ = std::make_unique<RB>((size_t)sr_, 2,
                               RB::OptionProcessRealTime | RB::OptionEngineFiner | RB::OptionPitchHighConsistency |
                                   RB::OptionChannelsTogether,
                               1.0, 1.0);
    rb_->setMaxProcessSize(kStretchMax);
    inL_.assign(kStretchMax, 0.0f); inR_.assign(kStretchMax, 0.0f);
    outL_.assign(4096, 0.0f); outR_.assign(4096, 0.0f);
    lane_[CM_GAIN].base = 1.0;
    lane_[CM_TEMPO].base = 1.0;
    lane_[CM_ECHO_TIME].base = 0.375;
    lane_[CM_ECHO_FEEDBACK].base = 0.5;
    for (int p = 0; p < CM_PARAM_COUNT; ++p) sm_[p].jump(lane_[p].base);
    tape_.setup(sr_);
    tap_.assign(4096, 0.0f);
    source.start(sr_);
  }

  Source source;

  // --- команды
  // Все параметры деки — к исходным (новый трек не наследует EQ, фильтр, эхо и темп прошлого перехода)
  void resetParams() {
    for (int p = 0; p < CM_PARAM_COUNT; ++p) {
      lane_[p].clear();
      lane_[p].base = p == CM_GAIN ? 1.0 : p == CM_TEMPO ? 1.0 : p == CM_ECHO_TIME ? 0.375 : p == CM_ECHO_FEEDBACK ? 0.5 : 0.0;
      sm_[p].jump(lane_[p].base);
    }
    flt_.setup(sr_);
    isoMix_.jump(0.0);
    loopOff();
    tape_.stop();
    brakeClock_ = -1;
  }

  void cmdLoad(uint32_t gen, int32_t loadId, double startSec) {
    resetParams();
    playing_ = false;
    startClock_ = -1;
    stopClock_ = -1;
    ended_ = false;
    resetPosition(gen, (int64_t)std::llround(startSec * sr_));
    loadId_ = loadId;
    loaded_ = true;
  }
  void cmdUnload(uint32_t gen) {
    playing_ = false;
    startClock_ = -1;
    stopClock_ = -1;
    loaded_ = false;
    resetPosition(gen, 0);
  }
  void cmdSeek(uint32_t gen, double sec) {
    const int64_t f = (int64_t)std::llround(std::max(0.0, sec) * sr_);
    if (playing_) {
      // сначала короткое затухание, потом перемотка; если уже затухали перед паузой — пауза сохраняется
      if (fadeOutAction_ == FO_PAUSE) pauseAfterSeek_ = true;
      pendingSeekGen_ = gen;
      pendingSeekFrame_ = f;
      if (fadeOutAction_ == FO_NONE) fadeOut_ = kDeclick;
      fadeOutAction_ = FO_SEEK;
    } else {
      resetPosition(gen, f);
    }
    ended_ = false;
  }
  void cmdPlayAt(int64_t clock) {
    if (!loaded_) return;
    pauseAfterSeek_ = false;
    if (playing_ && fadeOutAction_ != FO_PAUSE) return;
    if (fadeOutAction_ == FO_PAUSE) { fadeOut_ = 0; fadeOutAction_ = FO_NONE; fadeIn_ = kDeclick; return; }  // передумали ставить на паузу
    startClock_ = clock < 0 ? -2 : clock;  // −2 — «как только будет звук»
    ended_ = false;
  }
  void cmdPause() {
    startClock_ = -1;
    if (!playing_) return;
    if (fadeOutAction_ == FO_SEEK) { pauseAfterSeek_ = true; return; }  // перемотка не теряется
    if (fadeOutAction_ == FO_NONE) fadeOut_ = kDeclick;
    fadeOutAction_ = FO_PAUSE;
  }
  void cmdStopAt(int64_t clock) {
    if (clock < 0) { cmdPause(); return; }
    stopClock_ = clock;
  }
  void cmdSet(int p, double v) {
    if (p < 0 || p >= CM_PARAM_COUNT) return;
    if (p == CM_TEMPO) v = std::clamp(v, 0.5, 2.0);
    lane_[p].base = v;
  }
  void cmdRamp(int p, int64_t a, int64_t b, double from, double to, int curve) {
    if (p < 0 || p >= CM_PARAM_COUNT) return;
    if (p == CM_TEMPO) { from = std::clamp(from, 0.5, 2.0); to = std::clamp(to, 0.5, 2.0); }
    lane_[p].add(Seg{a, b, from, to, curve});
  }
  // Снять запланированные старт и остановку (если переход отменили)
  void cmdCancelSchedule() {
    startClock_ = -1;
    stopClock_ = -1;
    brakeClock_ = -1;
    tape_.stop();
    loopOff();
  }

  // Петля [a, b) в секундах трека. Звук участка запоминается, пока дека его проигрывает (и пока он
  // приходит от декодера), поэтому участок должен быть впереди: то, что уже ушло из кольца, не вернуть.
  void cmdLoop(double aSec, double bSec) {
    if (bSec <= aSec) { loopArmed_ = false; return; }  // доиграет проход и пойдёт дальше (кольцо держит звук за петлёй)
    const int64_t a = (int64_t)std::llround(aSec * sr_), b = (int64_t)std::llround(bSec * sr_);
    if (b - a < sr_ / 20 || b - a > kLoopMax) return;
    if (a < ringStart_ || (int64_t)ph_ > a) return;  // начало уже позади — честную петлю не собрать
    loopA_ = a; loopB_ = b;
    loopBuf_.assign((size_t)(b - a) * 2, 0.0f);
    loopHave_ = 0;
    // что из участка уже лежит в кольце — сразу в петлю
    for (int64_t f = a; f < std::min(b, ringEnd_); ++f) {
      float l, r;
      frameAt(f, l, r);
      loopBuf_[(size_t)(f - a) * 2] = l; loopBuf_[(size_t)(f - a) * 2 + 1] = r;
    }
    loopHave_ = std::max<int64_t>(0, std::min(b, ringEnd_) - a);
    loopArmed_ = true;
  }

  void cmdBrake(int64_t clock, double durSec) {
    brakeClock_ = clock < 0 ? 0 : clock;
    brakeDur_ = std::clamp(durSec, 0.1, 6.0);
  }

  void cmdClearAuto() {
    for (int p = 0; p < CM_PARAM_COUNT; ++p) {
      lane_[p].base = sm_[p].cur;
      lane_[p].clear();
    }
  }

  // --- события, которые делят буфер: момент старта и остановки
  int64_t nextEvent(int64_t clock) const {
    int64_t e = INT64_MAX;
    if (startClock_ >= 0 && startClock_ > clock) e = std::min(e, startClock_);
    if (stopClock_ >= 0 && stopClock_ > clock) e = std::min(e, stopClock_);
    return e;
  }

  /// Текущее (сглаженное) значение параметра
  double param(int p) const { return sm_[p].cur; }

  // Вывести n кадров деки (уже после EQ/фильтра/громкости) с добавлением в mix; посыл в эхо — в send.
  void render(float *mix, float *send, float *rsend, int n, int64_t clock, int64_t &underruns) {
    pullBlocks();
    tapBase_ = clock;
    std::fill(tap_.begin(), tap_.begin() + std::min<size_t>((size_t)n, tap_.size()), 0.0f);

    // старт и остановка по часам
    if (startClock_ == -2 && loaded_ && ringEnd_ > playhead()) { beginPlay(); startClock_ = -1; }
    if (startClock_ >= 0 && clock >= startClock_) { beginPlay(); startClock_ = -1; }
    if (stopClock_ >= 0 && clock >= stopClock_) { stopClock_ = -1; if (playing_) { fadeOut_ = kDeclick; fadeOutAction_ = FO_PAUSE; } }

    if (!playing_) {
      // параметры всё равно идут по своим автоматизациям, чтобы старт был с нужных значений
      for (int i = 0; i < n; ++i) advanceParams(clock + i, true);
      return;
    }

    int done = 0;
    while (done < n) {
      const int len = std::min(kSub, n - done);
      const int64_t c = clock + done;
      // торможение начинается точно на своём кадре: кусок до него и после — отдельно
      int len2 = len;
      if (brakeClock_ >= 0 && brakeClock_ > c && brakeClock_ < c + len) len2 = (int)(brakeClock_ - c);
      if (brakeClock_ >= 0 && c >= brakeClock_) { tape_.start(brakeDur_); brakeClock_ = -1; }
      renderSub(mix + (size_t)done * 2, send + (size_t)done * 2, rsend + (size_t)done * 2, len2, c, underruns);
      done += len2;
      if (!playing_) break;
    }
  }

  const float *tap() const { return tap_.data(); }
  bool isPlaying() const { return playing_; }
  void addShift(double frames, double rate) { shiftLeft_ = frames; shiftRate_ = rate; }
  void clearShift() { shiftLeft_ = 0; }

  void publish(cm_deck_state &s) const {
    s.load_id = loadId_;
    const bool sourceDone = source.loadedId.load() == loadId_;
    int32_t st;
    if (!loaded_) st = CM_EMPTY;
    else if (!sourceDone) st = CM_LOADING;
    else if (source.status.load() == CM_ERROR) st = CM_ERROR;
    else st = playing_ ? CM_PLAYING : (ended_ ? CM_ENDED : CM_READY);
    s.status = st;
    s.position_sec = ph_ / sr_;
    s.duration_sec = source.duration.load();
    s.tempo = sm_[CM_TEMPO].cur;
    s.peak = peak_;
    s.start_clock = startClock_ >= 0 ? startClock_ : -1;
    s.stretching = mode_ != M_DIRECT ? 1 : 0;
    // пока в кольце нет звука новой позиции, блоки в очереди могут быть старыми (до перемотки) — их не считаем
    const bool fresh = ringEnd_ > ringStart_;
    s.buffered_ms = fresh ? (int32_t)std::max<int64_t>(0, (ringEnd_ - (int64_t)ph_) * 1000 / sr_ +
                                                          (int64_t)source.filled.size() * kBlock * 1000 / sr_)
                          : 0;
  }

  void decayPeak(int frames) { peak_ *= std::pow(0.1, frames / (double)sr_); }

 private:
  enum Mode { M_DIRECT, M_TO_STRETCH, M_STRETCH, M_TO_DIRECT };
  enum FadeAction { FO_NONE, FO_PAUSE, FO_SEEK };

  double playhead() const { return ph_; }

  void resetPosition(uint32_t gen, int64_t frame) {
    loopOff();
    gen_ = gen;
    ringStart_ = ringEnd_ = frame;
    eofFrame_ = -1;
    ph_ = (double)frame;
    mode_ = M_DIRECT;
    xf_ = 0;
    fadeIn_ = kDeclick;
    fadeOut_ = 0;
    fadeOutAction_ = FO_NONE;
    iso_.reset();
    prebuf_ = true;
  }

  void beginPlay() {
    playing_ = true;
    ended_ = false;
    fadeIn_ = 32;  // против щелчка, если старт посреди звука
  }

  // забрать готовые блоки декодера в кольцо
  void pullBlocks() {
    Block *b = nullptr;
    while (source.filled.peek(b)) {
      // блоки новой позиции, пока дека ещё затухает перед перемоткой, не выбрасываем — ждут своей очереди.
      // Иначе первые блоки пропадали, кольцо начиналось позже позиции, и звук после перемотки шёл с опозданием
      // и без плавного входа (щелчок)
      if (b->gen != gen_ && fadeOutAction_ == FO_SEEK && b->gen == pendingSeekGen_) break;
      if (b->gen != gen_) { source.filled.pop(b); source.recycle(b); continue; }
      if (ringEnd_ - ringStart_ + b->n > kRing) {
        // кольцо полно: освобождаем то, что далеко позади позиции
        // позади позиции держим 16384 кадра: из них берётся «предзаполнение» тайм-стретча и звук для сшивки
        const int64_t keepFrom = (int64_t)ph_ - 16384;
        if (keepFrom > ringStart_) ringStart_ = std::min(keepFrom, ringEnd_);
        if (ringEnd_ - ringStart_ + b->n > kRing) break;  // всё ещё нет места — заберём позже
      }
      source.filled.pop(b);
      if (b->frame != ringEnd_) {  // первый блок после перемотки
        ringStart_ = ringEnd_ = b->frame;
        // декодер начал не с того кадра (не должно быть, но на всякий случай): позиция — туда, где есть звук,
        // и вход снова плавный
        if (mode_ == M_DIRECT && (int64_t)ph_ < b->frame) { ph_ = (double)b->frame; fadeIn_ = kDeclick; prebuf_ = true; }
      }
      for (int i = 0; i < b->n; ++i) {
        const size_t k = (size_t)((ringEnd_ + i) & (kRing - 1)) * 2;
        ring_[k] = b->data[i * 2];
        ring_[k + 1] = b->data[i * 2 + 1];
        const int64_t f = ringEnd_ + i;
        if (loopArmed_ && f >= loopA_ && f < loopB_) {
          loopBuf_[(size_t)(f - loopA_) * 2] = b->data[i * 2];
          loopBuf_[(size_t)(f - loopA_) * 2 + 1] = b->data[i * 2 + 1];
          loopHave_ = std::max(loopHave_, f - loopA_ + 1);
        }
      }
      ringEnd_ += b->n;
      if (b->eof) eofFrame_ = ringEnd_;
      source.recycle(b);
    }
  }

  inline bool has(int64_t f) const { return f >= ringStart_ && f < ringEnd_; }

  // --- петля
  static constexpr int64_t kLoopMax = 48000LL * 40;  // не длиннее ~40 с
  bool loopArmed_ = false;
  int64_t loopA_ = 0, loopB_ = 0, loopHave_ = 0;
  std::vector<float> loopBuf_;
  void loopOff() { loopArmed_ = false; loopBuf_.clear(); loopHave_ = 0; }
  // петля целиком запомнена и кусок [f, f+n) в ней — значит, звук есть, ждать декодер не нужно
  bool looping(int64_t f, int n) const {
    return loopArmed_ && loopHave_ >= loopB_ - loopA_ && f >= loopA_ && f + n <= loopB_ + (loopB_ - loopA_);
  }
  int64_t wrap(int64_t f) const {
    if (!loopArmed_ || loopHave_ < loopB_ - loopA_) return f;
    while (f >= loopB_) f -= loopB_ - loopA_;
    return f;
  }
  // кадр трека с учётом петли: внутри и за концом петли — из её запомненного звука
  inline void srcFrame(int64_t f, float &l, float &r) const {
    if (loopArmed_ && f >= loopA_) {
      const int64_t len = loopB_ - loopA_;
      if (loopHave_ >= len) {
        if (f >= loopB_) f = loopA_ + (f - loopA_) % len;
        const size_t k = (size_t)(f - loopA_) * 2;
        l = loopBuf_[k]; r = loopBuf_[k + 1];
        return;
      }
      if (f < loopA_ + loopHave_) {
        const size_t k = (size_t)(f - loopA_) * 2;
        l = loopBuf_[k]; r = loopBuf_[k + 1];
        return;
      }
    }
    frameAt(f, l, r);
  }
  inline void frameAt(int64_t f, float &l, float &r) const {
    if (!has(f)) { l = r = 0; return; }
    const size_t k = (size_t)(f & (kRing - 1)) * 2;
    l = ring_[k]; r = ring_[k + 1];
  }
  bool ended(int64_t f) const { return eofFrame_ >= 0 && f >= eofFrame_; }

  // значения параметров в момент clock (с микросглаживанием ступенек)
  inline void advanceParams(int64_t clock, bool) {
    for (int p = 0; p < CM_PARAM_COUNT; ++p) {
      const double v = lane_[p].at(clock);
      if (p == CM_TEMPO || p == CM_PITCH) { sm_[p].jump(v); continue; }
      if (v != sm_[p].target) sm_[p].set(v, p == CM_FILTER || p == CM_FILTER_RES ? 64 : 48);
      sm_[p].next();
    }
  }

  // Нужен ли тайм-стретч: темп не 1 или скоро начнётся изменение темпа (включаемся заранее, на 1.0)
  bool wantStretch(int64_t clock) const {
    if (std::abs(sm_[CM_TEMPO].cur - 1.0) > 1e-9) return true;
    if (std::abs(lane_[CM_TEMPO].base - 1.0) > 1e-9) return true;
    if (std::abs(sm_[CM_PITCH].cur) > 1e-6 || std::abs(lane_[CM_PITCH].base) > 1e-6) return true;
    return lane_[CM_TEMPO].activeWithin(clock, sr_ / 2) || lane_[CM_PITCH].activeWithin(clock, sr_ / 2);
  }

  void engageStretch(double tempo) {
    rb_->reset();
    rb_->setTimeRatio(1.0 / tempo);
    rb_->setPitchScale(std::pow(2.0, sm_[CM_PITCH].cur / 12.0));
    const int64_t P = (int64_t)std::llround(ph_);
    // «предзаполнение»: реальный звук перед текущей позицией, а не нули
    const int pad = (int)rb_->getPreferredStartPad();
    int64_t from = P - pad;
    int left = pad;
    while (left > 0) {
      const int chunk = std::min(left, kStretchMax);
      for (int i = 0; i < chunk; ++i) {
        float l, r;
        srcFrame(from + i, l, r);
        inL_[i] = l; inR_[i] = r;
      }
      const float *in[2] = {inL_.data(), inR_.data()};
      rb_->process(in, (size_t)chunk, false);
      from += chunk;
      left -= chunk;
    }
    feedPos_ = P;
    discard_ = (int)rb_->getStartDelay();
    rbDelay_ = discard_;
    ph_ = (double)P;
    mode_ = M_TO_STRETCH;
    xf_ = 0;
  }

  // Получить n кадров из тайм-стретча. false — не хватило звука (недобор буфера).
  bool pullStretched(int n, float *outL, float *outR) {
    int got = 0;
    int guard = 0;
    while (got < n) {
      int avail = rb_->available();
      if (avail > 0) {
        if (discard_ > 0) {
          const int d = std::min(discard_, std::min(avail, (int)outL_.size()));
          float *o[2] = {outL_.data(), outR_.data()};
          rb_->retrieve(o, (size_t)d);
          discard_ -= d;
          continue;
        }
        const int take = std::min(avail, n - got);
        float *o[2] = {outL + got, outR + got};
        rb_->retrieve(o, (size_t)take);
        got += take;
        continue;
      }
      // кормим
      size_t need = rb_->getSamplesRequired();
      if (need == 0) need = 256;
      const int chunk = (int)std::min<size_t>(need, kStretchMax);
      if (!looping(feedPos_, chunk) && eofFrame_ < 0 && feedPos_ + chunk > ringEnd_) return false;  // ждём декодер
      for (int i = 0; i < chunk; ++i) {
        float l, r;
        srcFrame(feedPos_ + i, l, r);  // за концом трека — тишина, в петле — её начало
        inL_[i] = l; inR_[i] = r;
      }
      const float *in[2] = {inL_.data(), inR_.data()};
      rb_->process(in, (size_t)chunk, false);
      feedPos_ = wrap(feedPos_ + chunk);
      if (++guard > 64) return false;
    }
    return true;
  }

  void renderSub(float *mix, float *send, float *rsend, int n, int64_t clock, int64_t &underruns) {
    // темп на этот кусок
    advanceTempoOnly(clock);
    // подстройка фазы: заказанный сдвиг выбирается чуть изменённой скоростью (в тайм-стретче — темпом,
    // без него — как пластинка, с едва заметной высотой)
    double bend = 1.0;
    if (shiftLeft_ != 0) {
      const double step = std::min(std::abs(shiftLeft_), shiftRate_ * n);
      const double sg = shiftLeft_ > 0 ? 1.0 : -1.0;
      bend = 1.0 + sg * step / n;
      shiftLeft_ -= sg * step;
      if (std::abs(shiftLeft_) < 1e-6) shiftLeft_ = 0;
    }
    const double tempo = sm_[CM_TEMPO].cur * bend;

    // После перемотки (и после опустевшего кольца) звук не идёт, пока декодер не накопит запас: иначе он
    // начинается и обрывается кусками по блоку — на быстрых перемотках это и слышно как «скретч»
    bool waiting = false;
    if (prebuf_) {
      const int64_t P = (int64_t)ph_;
      if (eofFrame_ >= 0 || ringEnd_ - P >= kPrebuf || looping(P, n)) prebuf_ = false;
      else waiting = true;
    }
    if (!waiting) {
      if (mode_ == M_DIRECT && wantStretch(clock)) engageStretch(tempo);
      if (mode_ == M_STRETCH && !wantStretch(clock)) { mode_ = M_TO_DIRECT; xf_ = 0; directFrom_ = (int64_t)std::llround(ph_); }
      // Тайм-стретч отдаёт звук с задержкой rbDelay_ кадров выхода: темп, который ему задан сейчас, слышен через
      // rbDelay_. Поэтому ему задаётся темп автоматизации на rbDelay_ вперёд — тогда слышимая позиция идёт ровно
      // по автоматизации (иначе после смены темпа на 5 % звук сдвигается на ~2,5 мс относительно расчёта)
      if (mode_ != M_DIRECT) {
        rb_->setTimeRatio(1.0 / (lane_[CM_TEMPO].peek(clock + rbDelay_) * bend));
        rb_->setPitchScale(std::pow(2.0, sm_[CM_PITCH].cur / 12.0));
      }
    }

    float bufL[kSub], bufR[kSub];
    bool ok = true, rearmFadeIn = false;
    // для подстройки по ударам под тайм-стретчем берём сам трек в тех местах, что сейчас звучат: низ после
    // тайм-стретча «размазан» по времени на десятки мс, а где удар должен прозвучать — известно точно
    float srcTap[kSub];
    bool tapFromSrc = false;

    if (waiting) {
      ok = false;
    } else if (mode_ == M_DIRECT) {
      const int64_t P = (int64_t)ph_;
      if (bend == 1.0) {
        for (int i = 0; i < n; ++i) srcFrame(P + i, bufL[i], bufR[i]);
      } else {
        // кубическая интерполяция (Катмулл — Ром) между кадрами
        const double f0 = ph_ - (double)P;
        for (int i = 0; i < n; ++i) {
          const double x = f0 + i * bend;
          const int64_t k = (int64_t)std::floor(x);
          const float t = (float)(x - (double)k);
          float l[4], r[4];
          for (int j = 0; j < 4; ++j) srcFrame(P + k - 1 + j, l[j], r[j]);
          auto cr = [t](const float *v) {
            return v[1] + 0.5f * t * (v[2] - v[0] + t * (2 * v[0] - 5 * v[1] + 4 * v[2] - v[3] + t * (3 * (v[1] - v[2]) + v[3] - v[0])));
          };
          bufL[i] = cr(l); bufR[i] = cr(r);
        }
      }
      const int adv = (int)std::ceil(n * bend) + 2;
      if (!looping(P, adv) && !ended(P) && P + adv + kStarve > ringEnd_ && eofFrame_ < 0) {
        // декодер не успевает: запас почти кончился — доигрываем, что есть, с затуханием (не обрываем: затухание
        // начинается, пока в кольце ещё есть kStarve кадров, поэтому оно не короче куска), дальше тишина и новый запас
        const int avail = (int)std::clamp<int64_t>(ringEnd_ - P, 0, n);
        for (int i = 0; i < n; ++i) {
          const float g = i < avail ? (float)(1.0 - (double)i / avail) : 0.0f;
          bufL[i] *= g; bufR[i] *= g;
        }
        ph_ = (double)(P + avail);
        if (ringEnd_ > ringStart_) ++underruns;
        prebuf_ = true;
        rearmFadeIn = true;
      } else if (bend == 1.0) {
        ph_ = (double)wrap(P + n);
      } else {
        const double np = ph_ + n * bend;
        const int64_t ip = (int64_t)std::floor(np);
        ph_ = (double)wrap(ip) + (np - (double)ip);
      }
    } else {
      float wl[kSub], wr[kSub];
      ok = pullStretched(n, wl, wr);
      if (ok && mode_ != M_TO_DIRECT) {
        for (int i = 0; i < n; ++i) {
          float l, r;
          srcFrame(wrap((int64_t)std::llround(ph_ + i * tempo)), l, r);
          srcTap[i] = 0.5f * (l + r);
        }
        tapFromSrc = true;
      }
      if (ok) {
        for (int i = 0; i < n; ++i) {
          float dl = 0, dr = 0;
          if (mode_ == M_TO_STRETCH) srcFrame((int64_t)std::llround(ph_ + i * tempo), dl, dr);
          if (mode_ == M_TO_DIRECT) srcFrame(directFrom_ + xf_ + i, dl, dr);
          double w = 1.0;
          if (mode_ == M_TO_STRETCH) w = std::min(1.0, (xf_ + i) / (double)kXfade);
          if (mode_ == M_TO_DIRECT) w = 1.0 - std::min(1.0, (xf_ + i) / (double)kXfade);
          // равная мощность для некоррелированных хвостов не нужна: сигналы почти одинаковы, линейная сшивка
          bufL[i] = (float)(dl + (wl[i] - dl) * w);
          bufR[i] = (float)(dr + (wr[i] - dr) * w);
        }
        if (mode_ == M_TO_DIRECT) {
          xf_ += n;
          if (xf_ >= kXfade) {
            mode_ = M_DIRECT;
            ph_ = (double)wrap(directFrom_ + xf_);
            xf_ = 0;
          } else {
            ph_ = (double)(directFrom_ + xf_);
          }
        } else {
          ph_ += n * tempo;
          if (loopArmed_ && ph_ >= (double)loopB_) ph_ -= (double)(loopB_ - loopA_);
          if (mode_ == M_TO_STRETCH) { xf_ += n; if (xf_ >= kXfade) { mode_ = M_STRETCH; xf_ = 0; } }
        }
      } else {
        for (int i = 0; i < n; ++i) bufL[i] = bufR[i] = 0;
      }
    }

    if (!ok) {
      if (!waiting && ringEnd_ > ringStart_) ++underruns;  // ожидание запаса после перемотки — не сбой
      if (!waiting) prebuf_ = true;                        // тайм-стретч не успел — тоже копим запас
      for (int i = 0; i < n; ++i) bufL[i] = bufR[i] = 0;
      // звук пойдёт, когда декодер догонит: вход снова плавный. Иначе плавный вход «сгорает» на тишине ожидания,
      // и звук после перемотки начинается щелчком (на быстрых перемотках — «скретч»)
      rearmFadeIn = true;
    }
    if (tape_.active()) tape_.process(bufL, bufR, n);
    // плавный вход — на сам звук деки (до фильтров и посылов, чтобы и эхо не щёлкало). Пока звука нет, вход
    // не расходуется: он нужен в момент, когда звук пойдёт
    if (rearmFadeIn) fadeIn_ = kDeclick;
    else
      for (int i = 0; i < n && fadeIn_ > 0; ++i, --fadeIn_) {
        const float f = (float)(1.0 - fadeIn_ / (double)kDeclick);
        bufL[i] *= f; bufR[i] *= f;
      }
    // звук деки до EQ и громкости — для подстройки фазы по ударам
    {
      const int64_t off = clock - tapBase_;
      if (off >= 0 && off + n <= (int64_t)tap_.size())
        for (int i = 0; i < n; ++i) tap_[(size_t)(off + i)] = tapFromSrc ? srcTap[i] : 0.5f * (bufL[i] + bufR[i]);
    }

    // цепочка деки
    double peak = peak_;
    for (int i = 0; i < n; ++i) {
      advanceParams(clock + i, false);
      if (i == 0) flt_.update(sm_[CM_FILTER].cur, sm_[CM_FILTER_RES].cur);
      const double gl = eqKnobToGain(sm_[CM_EQ_LOW].cur);
      const double gm = eqKnobToGain(sm_[CM_EQ_MID].cur);
      const double gh = eqKnobToGain(sm_[CM_EQ_HIGH].cur);
      double g = std::max(0.0, sm_[CM_GAIN].cur) * dbToGain(sm_[CM_TRIM_DB].cur);
      if (fadeOut_ > 0) { g *= fadeOut_ / (double)kDeclick; }
      else if (fadeOutAction_ != FO_NONE) g = 0;
      double l = bufL[i], r = bufR[i];
      // изолятор слегка сдвигает фазу, поэтому подмешивается плавно и только пока EQ нужен;
      // фильтры работают всегда, чтобы при подключении не было переходного процесса
      const double pl = iso_.tick(0, l, gl, gm, gh), pr = iso_.tick(1, r, gl, gm, gh);
      if (i == 0) isoMix_.set(wantIso(clock) ? 1.0 : 0.0, kXfade);
      const double w = isoMix_.next();
      if (w > 0) { l += (pl - l) * w; r += (pr - r) * w; }
      l = flt_.tick(0, l);
      r = flt_.tick(1, r);
      const double es = sm_[CM_ECHO_SEND].cur, rs = sm_[CM_REVERB_SEND].cur;
      const double declick = fadeOut_ > 0 ? fadeOut_ / (double)kDeclick : 1.0;
      if (es > 0) {
        send[i * 2] += (float)(l * es * declick);
        send[i * 2 + 1] += (float)(r * es * declick);
      }
      if (rs > 0) {
        rsend[i * 2] += (float)(l * rs * declick);
        rsend[i * 2 + 1] += (float)(r * rs * declick);
      }
      l *= g; r *= g;
      mix[i * 2] += (float)l;
      mix[i * 2 + 1] += (float)r;
      peak = std::max(peak, std::max(std::abs(l), std::abs(r)));
      if (fadeOut_ > 0 && --fadeOut_ == 0) { finishFadeOut(); break; }  // остаток куска — тишина
    }
    peak_ = peak;

    // торможение кончилось — дека встаёт (звук уже затих, без микрозатухания)
    if (tape_.done()) {
      tape_.stop();
      playing_ = false;
      if (mode_ != M_DIRECT) { ph_ = std::round(ph_); mode_ = M_DIRECT; }
      return;
    }
    // конец трека
    const int64_t P = (int64_t)ph_;
    if (ended(P)) {
      playing_ = false;
      ended_ = true;
      mode_ = M_DIRECT;
    }
  }

  // EQ нужен, если хоть одна ручка не в нуле или скоро начнётся автоматизация EQ
  bool wantIso(int64_t clock) const {
    for (int p = CM_EQ_LOW; p <= CM_EQ_HIGH; ++p) {
      if (sm_[p].cur != 0.0 || sm_[p].target != 0.0 || lane_[p].base != 0.0) return true;
      if (lane_[p].activeWithin(clock, sr_ / 2)) return true;
    }
    return false;
  }

  void advanceTempoOnly(int64_t clock) {
    sm_[CM_TEMPO].jump(lane_[CM_TEMPO].at(clock));
    sm_[CM_PITCH].jump(std::clamp(lane_[CM_PITCH].at(clock), -3.0, 3.0));
  }

  void finishFadeOut() {
    if (fadeOutAction_ == FO_PAUSE) {
      playing_ = false;
      if (mode_ != M_DIRECT) { ph_ = std::round(ph_); mode_ = M_DIRECT; }
    } else if (fadeOutAction_ == FO_SEEK) {
      resetPosition(pendingSeekGen_, pendingSeekFrame_);  // сбрасывает и действия затухания
      if (pauseAfterSeek_) { playing_ = false; pauseAfterSeek_ = false; }
      return;
    }
    fadeOutAction_ = FO_NONE;
  }

  int sr_ = 48000;
  std::vector<float> ring_;
  int64_t ringStart_ = 0, ringEnd_ = 0, eofFrame_ = -1;
  uint32_t gen_ = 0;
  double ph_ = 0;            // позиция в треке (кадры движка)
  bool loaded_ = false, playing_ = false, ended_ = false;
  int32_t loadId_ = 0;
  int64_t startClock_ = -1, stopClock_ = -1;
  int fadeIn_ = 0, fadeOut_ = 0;
  FadeAction fadeOutAction_ = FO_NONE;
  uint32_t pendingSeekGen_ = 0;
  bool pauseAfterSeek_ = false;
  bool prebuf_ = false;                     // ждём запас звука (после перемотки или опустевшего кольца)
  static constexpr int64_t kPrebuf = 4096;  // ~85 мс
  static constexpr int64_t kStarve = 256;   // запас, при котором уже пора плавно замолкать
  int64_t pendingSeekFrame_ = 0;

  Lane lane_[CM_PARAM_COUNT];
  Smoothed sm_[CM_PARAM_COUNT];
  Isolator iso_;
  Smoothed isoMix_;
  OneKnobFilter flt_;
  double peak_ = 0;

  Mode mode_ = M_DIRECT;
  int xf_ = 0;
  int64_t directFrom_ = 0;
  std::unique_ptr<RubberBand::RubberBandStretcher> rb_;
  int64_t feedPos_ = 0;
  int discard_ = 0;
  int rbDelay_ = 0;  // задержка тайм-стретча, кадры выхода
  std::vector<float> inL_, inR_, outL_, outR_;
  TapeStop tape_;
  int64_t brakeClock_ = -1;
  double brakeDur_ = 1.0;
  std::vector<float> tap_;
  int64_t tapBase_ = 0;
  double shiftLeft_ = 0, shiftRate_ = 0;
};

// ---------------------------------------------------------------- Движок

class Engine {
 public:
  ~Engine() {
    if (deviceStarted_) ma_device_uninit(&device_);
    for (auto &d : decks_) d.source.stop();
  }

  bool init(int sampleRate, bool offline) {
    offline_ = offline;
    if (!offline) {
      ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
      cfg.playback.format = ma_format_f32;
      cfg.playback.channels = 2;
      cfg.sampleRate = (ma_uint32)sampleRate;  // 0 — частота устройства
      cfg.periodSizeInMilliseconds = 10;
      cfg.performanceProfile = ma_performance_profile_low_latency;
      cfg.noPreSilencedOutputBuffer = MA_TRUE;
      cfg.dataCallback = [](ma_device *dev, void *out, const void *, ma_uint32 frames) {
        static_cast<Engine *>(dev->pUserData)->process(static_cast<float *>(out), (int)frames);
      };
      cfg.pUserData = this;
      if (ma_device_init(nullptr, &cfg, &device_) != MA_SUCCESS) {
        setError("не удалось открыть аудиоустройство");
        return false;
      }
      sr_ = (int)device_.sampleRate;
      deviceStarted_ = true;
    } else {
      sr_ = sampleRate > 0 ? sampleRate : 48000;
    }
    for (auto &d : decks_) d.setup(sr_);
    sync_.setup(sr_);
    for (auto &x : echo_) x.setup(sr_);
    for (auto &x : reverb_) x.setup(sr_);
    for (auto &b : sendBuf_) b.assign(4096 * 2, 0.0f);
    for (auto &b : revBuf_) b.assign(4096 * 2, 0.0f);
    limiter_.setup(sr_, -1.0, 5.0, 80.0);
    masterVol_.jump(1.0);
    pauseGain_.jump(1.0);
    mixBuf_.assign(4096 * 2, 0.0f);
    if (!offline && ma_device_start(&device_) != MA_SUCCESS) {
      setError("не удалось запустить аудиоустройство");
      return false;
    }
    return true;
  }

  int sampleRate() const { return sr_; }
  bool offline() const { return offline_; }

  void push(const Cmd &c) {
    std::lock_guard<std::mutex> g(apiMutex_);
    // очередь большая; если переполнена (аудио стоит), ждём немного
    for (int i = 0; i < 200 && !cmds_.push(c); ++i) std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }

  uint32_t nextGen() { return ++gen_; }

  void load(int deck, const std::string &path, double sec, int32_t loadId) {
    std::lock_guard<std::mutex> g(loadMutex_);
    const uint32_t gen = nextGen();
    Cmd c{C_LOAD}; c.deck = deck; c.gen = gen; c.loadId = loadId; c.x = sec;
    push(c);
    decks_[deck].source.requestLoad(path, sec, gen, loadId);
  }
  void seek(int deck, double sec) {
    std::lock_guard<std::mutex> g(loadMutex_);
    const uint32_t gen = nextGen();
    Cmd c{C_SEEK}; c.deck = deck; c.gen = gen; c.x = sec;
    push(c);
    decks_[deck].source.requestSeek(sec, gen);
  }
  void unload(int deck) {
    std::lock_guard<std::mutex> g(loadMutex_);
    const uint32_t gen = nextGen();
    Cmd c{C_UNLOAD}; c.deck = deck; c.gen = gen;
    push(c);
    decks_[deck].source.requestUnload(gen);
  }

  void process(float *out, int frames) {
    // команды
    Cmd c;
    while (cmds_.pop(c)) apply(c);

    int done = 0;
    while (done < frames) {
      int n = std::min(frames - done, 4096);
      // делим буфер на моментах старта/остановки дек, чтобы они были точны до кадра
      if (!paused_ || pauseGain_.cur > 0) {
        for (auto &d : decks_) {
          const int64_t e = d.nextEvent(clock_);
          if (e != INT64_MAX && e - clock_ < n) n = (int)std::max<int64_t>(1, e - clock_);
        }
      }
      renderChunk(out + (size_t)done * 2, n);
      done += n;
    }
    publish(frames);
  }

  void syncInfo(cm_sync_info *o) const { getSync(o); }

  void getState(cm_state *s) {
    uint32_t a, b;
    do {
      a = seq_.load(std::memory_order_acquire);
      if (a & 1) { std::this_thread::yield(); continue; }
      *s = state_;
      std::atomic_thread_fence(std::memory_order_acquire);
      b = seq_.load(std::memory_order_relaxed);
    } while ((a & 1) || a != b);
    // до первого блока звука состояние ещё не опубликовано — частота всё равно известна
    if (s->sample_rate == 0) s->sample_rate = sr_;
  }

  void setError(const std::string &e) {
    std::lock_guard<std::mutex> g(errMutex_);
    error_ = e;
  }
  std::string error() {
    std::string e;
    {
      std::lock_guard<std::mutex> g(errMutex_);
      e = error_;
    }
    if (e.empty()) {
      for (auto &d : decks_) {
        const std::string de = d.source.error();
        if (!de.empty()) e = de;
      }
    }
    return e;
  }

  int32_t nextLoadId() { return ++loadId_; }
  void setFfmpeg(const std::string &path) {
    for (auto &d : decks_) d.source.setFfmpeg(path);
  }

 private:
  void apply(const Cmd &c) {
    if (c.type == C_MASTER_VOL) { masterVol_.set(std::pow(std::clamp(c.x, 0.0, 1.0), 3.0), sr_ / 50); return; }
    if (c.type == C_PAUSED) { paused_ = c.a != 0; pauseGain_.set(paused_ ? 0.0 : 1.0, kDeclick * 2); return; }
    if (c.deck < 0 || c.deck >= CM_DECKS) return;
    if (c.type == C_SYNC) {
      if (c.param < 0 || c.param >= CM_DECKS || c.param == c.deck) return;
      syncFol_ = c.deck; syncRef_ = c.param;
      decks_[syncFol_].clearShift();
      sync_.start(c.a, c.b, c.x * sr_);
      syncToClock_ = c.b;
      syncStats();
      return;
    }
    // перемотка, новый трек или отмена расписания на любой из двух дек — подстройка больше не к месту
    if (sync_.active() && (c.deck == syncFol_ || c.deck == syncRef_) &&
        (c.type == C_SEEK || c.type == C_LOAD || c.type == C_UNLOAD || c.type == C_CANCEL_SCHEDULE)) {
      sync_.stop();
      decks_[syncFol_].clearShift();
      syncStats();
    }
    Deck &d = decks_[c.deck];
    switch (c.type) {
      case C_SET: d.cmdSet(c.param, c.x); break;
      case C_RAMP: d.cmdRamp(c.param, c.a, c.b, c.x, c.y, c.curve); break;
      case C_CLEAR_AUTO: d.cmdClearAuto(); break;
      case C_CANCEL_SCHEDULE: d.cmdCancelSchedule(); break;
      case C_PLAY_AT: d.cmdPlayAt(c.a); break;
      case C_PAUSE: d.cmdPause(); break;
      case C_STOP_AT: d.cmdStopAt(c.a); break;
      case C_SEEK: d.cmdSeek(c.gen, c.x); break;
      case C_LOAD: d.cmdLoad(c.gen, c.loadId, c.x); break;
      case C_UNLOAD: d.cmdUnload(c.gen); break;
      case C_LOOP: d.cmdLoop(c.x, c.y); break;
      case C_BRAKE: d.cmdBrake(c.a, c.x); break;
      default: break;
    }
  }

  void renderChunk(float *out, int n) {
    if (paused_ && pauseGain_.cur <= 0.0) {
      std::memset(out, 0, sizeof(float) * (size_t)n * 2);
      return;  // часы стоят
    }
    float *mix = mixBuf_.data();
    std::memset(mix, 0, sizeof(float) * (size_t)n * 2);
    for (int k = 0; k < CM_DECKS; ++k) {
      float *send = sendBuf_[k].data(), *rsend = revBuf_[k].data();
      std::memset(send, 0, sizeof(float) * (size_t)n * 2);
      std::memset(rsend, 0, sizeof(float) * (size_t)n * 2);
      decks_[k].render(mix, send, rsend, n, clock_, underruns_);
      echo_[k].process(send, mix, n, decks_[k].param(CM_ECHO_TIME), decks_[k].param(CM_ECHO_FEEDBACK));
      reverb_[k].process(rsend, mix, n);
    }
    if (sync_.active()) {
      if (sync_.covers(clock_, n) && decks_[syncRef_].isPlaying() && decks_[syncFol_].isPlaying()) {
        const BeatSync::Shift sh = sync_.feed(decks_[syncRef_].tap(), decks_[syncFol_].tap(), n, clock_);
        if (sh.rate > 0) decks_[syncFol_].addShift(sh.frames, sh.rate);
        syncStats();
      } else if (clock_ >= syncTo()) {
        sync_.stop();
        syncStats();
      }
    }
    double mp = masterPeak_;
    for (int i = 0; i < n; ++i) {
      const double g = masterVol_.next() * pauseGain_.next();
      float l = (float)(mix[i * 2] * g), r = (float)(mix[i * 2 + 1] * g);
      limiter_.tick(l, r);
      out[i * 2] = l;
      out[i * 2 + 1] = r;
      mp = std::max(mp, (double)std::max(std::abs(l), std::abs(r)));
    }
    masterPeak_ = mp;
    clock_ += n;
  }

  int64_t syncTo() const { return syncToClock_; }
  void syncStats() {
    syncActive_.store(sync_.active() ? 1 : 0);
    syncMeasured_.store(sync_.measured);
    syncCorr_.store(sync_.corrections);
    syncFirst_.store(sync_.firstMs);
    syncLast_.store(sync_.lastMs);
    syncShift_.store(sync_.shiftMs);
    syncConf_.store(sync_.conf);
  }
  void getSync(cm_sync_info *o) const {
    o->active = syncActive_.load();
    o->measured = syncMeasured_.load();
    o->corrections = syncCorr_.load();
    o->reserved = 0;
    o->first_offset_ms = syncFirst_.load();
    o->last_offset_ms = syncLast_.load();
    o->total_shift_ms = syncShift_.load();
    o->confidence = syncConf_.load();
  }

  void publish(int frames) {
    seq_.fetch_add(1, std::memory_order_acq_rel);
    state_.api_version = CM_API_VERSION;
    state_.sample_rate = sr_;
    state_.clock = clock_;
    state_.underruns = underruns_;
    state_.master_peak = masterPeak_;
    state_.limiter_gain_db = gainToDb(limiter_.gain());
    for (int i = 0; i < CM_DECKS; ++i) decks_[i].publish(state_.deck[i]);
    seq_.fetch_add(1, std::memory_order_release);
    masterPeak_ *= std::pow(0.1, frames / (double)sr_);
    for (auto &d : decks_) d.decayPeak(frames);
  }

  int sr_ = 48000;
  bool offline_ = false;
  ma_device device_{};
  bool deviceStarted_ = false;
  Deck decks_[CM_DECKS];
  Echo echo_[CM_DECKS];
  Reverb reverb_[CM_DECKS];
  std::vector<float> sendBuf_[CM_DECKS], revBuf_[CM_DECKS];
  Limiter limiter_;
  BeatSync sync_;
  int syncRef_ = 0, syncFol_ = 1;
  int64_t syncToClock_ = 0;
  std::atomic<int32_t> syncActive_{0}, syncMeasured_{0}, syncCorr_{0};
  std::atomic<double> syncFirst_{0}, syncLast_{0}, syncShift_{0}, syncConf_{0};
  Smoothed masterVol_, pauseGain_;
  bool paused_ = false;
  std::vector<float> mixBuf_;
  int64_t clock_ = 0;
  int64_t underruns_ = 0;
  double masterPeak_ = 0;

  Spsc<Cmd, 1024> cmds_;
  std::mutex apiMutex_, loadMutex_, errMutex_;
  std::atomic<uint32_t> gen_{0};
  std::atomic<int32_t> loadId_{0};
  std::string error_;

  std::atomic<uint32_t> seq_{0};
  cm_state state_{};
};

}  // namespace cm

// ---------------------------------------------------------------- C API

struct cm_engine {
  cm::Engine engine;
  std::string lastError;
};

static bool validDeck(int32_t d) { return d >= 0 && d < CM_DECKS; }

// Раскладка структур должна совпадать с Dart (packages/cave_mix/lib/cave_mix.dart)
static_assert(sizeof(cm_deck_state) == 56, "cm_deck_state layout changed: update Dart bindings");
static_assert(sizeof(cm_state) == 40 + 2 * 56, "cm_state layout changed: update Dart bindings");

extern "C" {

CM_API cm_engine *cm_create(int32_t sample_rate, int32_t offline) {
  auto *e = new (std::nothrow) cm_engine();
  if (!e) return nullptr;
  if (!e->engine.init(sample_rate, offline != 0)) {
    delete e;
    return nullptr;
  }
  return e;
}

CM_API void cm_destroy(cm_engine *e) { delete e; }

CM_API const char *cm_last_error(cm_engine *e) {
  if (!e) return "движок не создан";
  e->lastError = e->engine.error();
  return e->lastError.c_str();
}

CM_API int32_t cm_load(cm_engine *e, int32_t deck, const char *path_utf8, double start_sec) {
  if (!e || !validDeck(deck) || !path_utf8) return -1;
  const int32_t id = e->engine.nextLoadId();
  e->engine.load(deck, path_utf8, start_sec, id);
  return id;
}

CM_API void cm_set_ffmpeg(cm_engine *e, const char *path_utf8) {
  if (e) e->engine.setFfmpeg(path_utf8 ? path_utf8 : "");
}

CM_API void cm_unload(cm_engine *e, int32_t deck) {
  if (e && validDeck(deck)) e->engine.unload(deck);
}

CM_API void cm_play_at(cm_engine *e, int32_t deck, int64_t at_clock) {
  if (!e || !validDeck(deck)) return;
  cm::Cmd c{cm::C_PLAY_AT}; c.deck = deck; c.a = at_clock;
  e->engine.push(c);
}

CM_API void cm_pause(cm_engine *e, int32_t deck) {
  if (!e || !validDeck(deck)) return;
  cm::Cmd c{cm::C_PAUSE}; c.deck = deck;
  e->engine.push(c);
}

CM_API void cm_seek(cm_engine *e, int32_t deck, double sec) {
  if (e && validDeck(deck)) e->engine.seek(deck, sec);
}

CM_API void cm_stop_at(cm_engine *e, int32_t deck, int64_t at_clock) {
  if (!e || !validDeck(deck)) return;
  cm::Cmd c{cm::C_STOP_AT}; c.deck = deck; c.a = at_clock;
  e->engine.push(c);
}

CM_API void cm_set(cm_engine *e, int32_t deck, int32_t param, double value) {
  if (!e || !validDeck(deck)) return;
  cm::Cmd c{cm::C_SET}; c.deck = deck; c.param = param; c.x = value;
  e->engine.push(c);
}

CM_API void cm_ramp(cm_engine *e, int32_t deck, int32_t param, int64_t from_clock, int64_t to_clock, double from,
                    double to, int32_t curve) {
  if (!e || !validDeck(deck)) return;
  cm::Cmd c{cm::C_RAMP}; c.deck = deck; c.param = param; c.a = from_clock; c.b = to_clock; c.x = from; c.y = to; c.curve = curve;
  e->engine.push(c);
}

CM_API void cm_clear_automation(cm_engine *e, int32_t deck) {
  if (!e || !validDeck(deck)) return;
  cm::Cmd c{cm::C_CLEAR_AUTO}; c.deck = deck;
  e->engine.push(c);
}

CM_API void cm_cancel_schedule(cm_engine *e, int32_t deck) {
  if (!e || !validDeck(deck)) return;
  cm::Cmd c{cm::C_CANCEL_SCHEDULE}; c.deck = deck;
  e->engine.push(c);
}

CM_API void cm_set_master_volume(cm_engine *e, double volume) {
  if (!e) return;
  cm::Cmd c{cm::C_MASTER_VOL}; c.x = volume;
  e->engine.push(c);
}

CM_API void cm_set_paused(cm_engine *e, int32_t paused) {
  if (!e) return;
  cm::Cmd c{cm::C_PAUSED}; c.a = paused;
  e->engine.push(c);
}

CM_API void cm_loop(cm_engine *e, int32_t deck, double start_sec, double end_sec) {
  if (!e || !validDeck(deck)) return;
  cm::Cmd c{cm::C_LOOP};
  c.deck = deck; c.x = start_sec; c.y = end_sec;
  e->engine.push(c);
}

CM_API void cm_brake_at(cm_engine *e, int32_t deck, int64_t at_clock, double duration_sec) {
  if (!e || !validDeck(deck)) return;
  cm::Cmd c{cm::C_BRAKE};
  c.deck = deck; c.a = at_clock; c.x = duration_sec;
  e->engine.push(c);
}

CM_API void cm_sync(cm_engine *e, int32_t follow, int32_t ref, int64_t from_clock, int64_t to_clock, double beat_sec) {
  if (!e || !validDeck(follow) || !validDeck(ref) || follow == ref || beat_sec <= 0.1 || beat_sec > 3) return;
  cm::Cmd c{cm::C_SYNC};
  c.deck = follow; c.param = ref; c.a = from_clock; c.b = to_clock; c.x = beat_sec;
  e->engine.push(c);
}

CM_API void cm_get_sync(cm_engine *e, cm_sync_info *out) {
  if (!e || !out) return;
  e->engine.syncInfo(out);
}

CM_API void cm_get_state(cm_engine *e, cm_state *out) {
  if (!e || !out) return;
  e->engine.getState(out);
}

CM_API int32_t cm_render(cm_engine *e, float *out, int32_t frames) {
  if (!e || !out || frames <= 0 || !e->engine.offline()) return 0;
  e->engine.process(out, frames);
  return frames;
}

}  // extern "C"

// Cavey Mix — аудиодвижок DJ-режима.
//
// Две деки сводятся в одном аудиопотоке, поэтому всё, что происходит с ними
// (старт, автоматизации громкости, EQ, фильтра и темпа), точно до сэмпла.
// Время в движке — «часы» `clock`: число кадров, выведенных с момента старта.
// Dart планирует переход в этих кадрах и отдаёт его движку заранее.
//
// Все функции, кроме cm_render, можно вызывать из любого потока; движок сам
// передаёт команды в аудиопоток без блокировок.

#ifndef CAVE_MIX_H
#define CAVE_MIX_H

#include <stdint.h>

#ifdef _WIN32
#define CM_API __declspec(dllexport)
#else
#define CM_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define CM_DECKS 2
#define CM_API_VERSION 1

typedef struct cm_engine cm_engine;

// Параметры деки
enum cm_param {
  CM_GAIN = 0,    // фейдер 0…1 (линейно)
  CM_TRIM_DB = 1, // выравнивание громкости, дБ (−24…+12)
  CM_EQ_LOW = 2,  // −1 = полоса выключена, 0 = нейтрально, +1 = +6 дБ
  CM_EQ_MID = 3,
  CM_EQ_HIGH = 4,
  CM_FILTER = 5,  // −1…0 фильтр низких частот (срез вниз до 80 Гц), 0…+1 фильтр высоких (вверх до 8 кГц)
  CM_FILTER_RES = 6, // резонанс фильтра 0…1
  CM_TEMPO = 7,   // скорость относительно родного темпа: 1.0 — как записано, 1.06 — на 6 % быстрее
  CM_ECHO_SEND = 8,     // сколько звука деки (после EQ и фильтра, до фейдера) уходит в эхо, 0…1
  CM_ECHO_TIME = 9,     // задержка эха, секунды (0,02…2)
  CM_ECHO_FEEDBACK = 10, // обратная связь эха 0…0,95; хвост звучит и после остановки деки
  CM_PARAM_COUNT = 11
};

// Форма кривой автоматизации
enum cm_curve {
  CM_LINEAR = 0,
  CM_EQUAL_POWER_IN = 1,  // sin: для нарастающей громкости
  CM_EQUAL_POWER_OUT = 2, // cos: для затухающей
  CM_SMOOTH = 3,          // плавный S-образный переход
  CM_STEP = 4             // мгновенно в конце отрезка
};

// Состояние деки
enum cm_deck_status {
  CM_EMPTY = 0,
  CM_LOADING = 1,
  CM_READY = 2,   // загружена, стоит
  CM_PLAYING = 3,
  CM_ENDED = 4,   // доиграла до конца файла
  CM_ERROR = 5
};

typedef struct cm_deck_state {
  int32_t status;           // cm_deck_status
  int32_t load_id;          // id последней загрузки (из cm_load)
  double position_sec;      // позиция в треке, секунды (с учётом тайм-стретча)
  double duration_sec;      // длительность; 0 — пока неизвестна
  double tempo;             // текущий темп деки
  double peak;              // пик выхода деки за последний опрос, 0…1
  int64_t start_clock;      // кадр часов, когда дека начнёт играть; −1 — не запланировано
  int32_t stretching;       // 1 — сейчас работает тайм-стретч
  int32_t buffered_ms;      // сколько звука готово в буфере декодера
} cm_deck_state;

typedef struct cm_state {
  int32_t api_version;
  int32_t sample_rate;
  int64_t clock;            // кадров выведено с запуска
  int64_t underruns;        // сколько раз деке не хватило звука
  double master_peak;       // пик мастера за последний опрос
  double limiter_gain_db;   // текущее ослабление лимитером (≤ 0)
  cm_deck_state deck[CM_DECKS];
} cm_state;

// sample_rate: 0 — частота устройства по умолчанию (для офлайна — 48000).
// offline: 1 — без аудиоустройства, звук забирается через cm_render (тесты, рендер переходов).
CM_API cm_engine *cm_create(int32_t sample_rate, int32_t offline);
CM_API void cm_destroy(cm_engine *e);
// Последняя ошибка (UTF-8), пустая строка — ошибок не было. Действительна до следующего вызова из того же потока.
CM_API const char *cm_last_error(cm_engine *e);

// Загрузить файл в деку (асинхронно). Позиция — start_sec. Возвращает load_id (>0) или −1.
// Если дека играла, она останавливается и переходит на новый файл.
CM_API int32_t cm_load(cm_engine *e, int32_t deck, const char *path_utf8, double start_sec);
CM_API void cm_unload(cm_engine *e, int32_t deck);

// Путь к ffmpeg (UTF-8). Им движок читает форматы, которых нет во встроенных декодерах
// (M4A/AAC, Opus, Ogg и др.): ffmpeg запускается отдельным процессом и отдаёт сырой звук.
// Пустая строка — не использовать.
CM_API void cm_set_ffmpeg(cm_engine *e, const char *path_utf8);

// Запустить деку на кадре часов at_clock (−1 — сразу). Если звук ещё не готов, дека
// стартует, как только будет готов (при at_clock = −1), либо с пропуском (при точном старте).
CM_API void cm_play_at(cm_engine *e, int32_t deck, int64_t at_clock);
CM_API void cm_pause(cm_engine *e, int32_t deck);
CM_API void cm_seek(cm_engine *e, int32_t deck, double sec);
// Остановить деку на кадре часов at_clock (−1 — сразу); микрозатухание 5 мс против щелчка.
CM_API void cm_stop_at(cm_engine *e, int32_t deck, int64_t at_clock);

// Сразу задать параметр (сглаживается за ~5 мс).
CM_API void cm_set(cm_engine *e, int32_t deck, int32_t param, double value);
// Автоматизация: на отрезке [from_clock, to_clock) параметр идёт от from к to по кривой.
// Отрезки одного параметра не должны пересекаться; до 32 отрезков на параметр.
CM_API void cm_ramp(cm_engine *e, int32_t deck, int32_t param, int64_t from_clock, int64_t to_clock,
                    double from, double to, int32_t curve);
// Убрать все будущие и текущие автоматизации деки (параметры остаются на текущих значениях).
CM_API void cm_clear_automation(cm_engine *e, int32_t deck);
// Снять запланированные старт (cm_play_at) и остановку (cm_stop_at) деки.
CM_API void cm_cancel_schedule(cm_engine *e, int32_t deck);

CM_API void cm_set_master_volume(cm_engine *e, double volume); // 0…1, кубическая кривая как у mpv
CM_API void cm_set_paused(cm_engine *e, int32_t paused);      // пауза всего движка (часы стоят)

CM_API void cm_get_state(cm_engine *e, cm_state *out);

// Только для offline: вывести frames кадров стерео float в out. Возвращает число кадров.
CM_API int32_t cm_render(cm_engine *e, float *out, int32_t frames);

// ---------------------------------------------------------------- автомикс

// Запланировать DJ-переход с играющей деки `from` на загруженную (CM_READY) деку `to`.
// profile_from / profile_to — профили треков v2 (JSON из cm_analyze_file).
// options — JSON: {"style":"smooth|balanced|energetic","maxBars":32,"matchTempo":true,"maxTempoPct":8,
//   "keyAware":true,"allowEcho":true,"allowCut":true,"seed":N,"prev":<номер прошлой техники>,
//   "gainA":<амплитуда уходящей>,"gainB":<амплитуда приходящей>,"minLeadSec":1.5,"fadeSec":8,"force":<номер техники>}.
// Движок сам выбирает точки на границах фраз, подгоняет темп B к A, выбирает технику (T1 бас-свап, T2 фильтр,
// T3 эхо-аут, T4 склейка, T11 плавный переход) и раскладывает автоматизации, старт B и остановку A по часам.
// Возвращает JSON плана {"technique","name","bars","aOutSec","bInSec","tempoRatio","startClock","endClock","reason"}
// (освободить cm_free) или NULL с текстом в *error_out.
CM_API char *cm_automix(cm_engine *e, int32_t from, int32_t to, const char *profile_from, const char *profile_to,
                        const char *options, char **error_out);
// Отменить запланированный (или идущий) переход: снять автоматизации и расписание обеих дек, вернуть EQ, фильтр,
// эхо и темп к исходным, громкости — gain_from и gain_to.
CM_API void cm_automix_cancel(cm_engine *e, int32_t from, int32_t to, double gain_from, double gain_to);

// ---------------------------------------------------------------- анализ треков

// Анализатор: доли и даунбиты (нейросеть Beat This! через ONNX Runtime), сетка темпа, громкость EBU R128,
// истинный пик, тональность (Camelot), тишина, энергия по тактам, фразы, точки входа/выхода микса.
// ONNX Runtime подгружается из ort_lib во время работы. mel_model — ONNX лог-мел спектрограммы
// (mel_spectrogram.onnx из beat-this-rs), beat_model — Beat This! в ONNX (малая или полная модель).
// Создание дорогое (загрузка моделей): один анализатор на много треков. Не потокобезопасен —
// вызывать из одного потока. При ошибке возвращает NULL и пишет текст в *error_out (освободить cm_free).
typedef struct cm_analyzer cm_analyzer;
CM_API cm_analyzer *cm_analyzer_create(const char *ort_lib, const char *mel_model, const char *beat_model,
                                       int32_t threads, char **error_out);
CM_API void cm_analyzer_destroy(cm_analyzer *a);
// Проанализировать файл. ffmpeg — для форматов, которых нет во встроенных декодерах (может быть пустым).
// Возвращает JSON профиля v2 (освободить cm_free) или NULL с текстом ошибки в *error_out.
CM_API char *cm_analyze_file(cm_analyzer *a, const char *path_utf8, const char *ffmpeg_utf8, char **error_out);
CM_API void cm_free(void *p);

#ifdef __cplusplus
}
#endif

#endif

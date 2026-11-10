// C-интерфейс движка DJ-пульта (вызывается из Dart через FFI)
#pragma once
#include <stdint.h>

#if defined(_WIN32)
#define DJ_API __declspec(dllexport)
#else
#define DJ_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// sampleRate — частота движка (44100); openDevice — открыть ли звуковое устройство (0 — только для проверок)
DJ_API void* dj_create(int sampleRate, int openDevice);
DJ_API int dj_device_start(void* h);
DJ_API void dj_device_stop(void* h);
DJ_API void dj_destroy(void* h);

// Загрузка трека: сырой PCM float32, стерео, чередуется, на частоте движка. Возвращает число кадров или < 0
DJ_API int64_t dj_load(void* h, int deck, const char* utf8path);
DJ_API void dj_unload(void* h, int deck);

DJ_API void dj_play(void* h, int deck, int play);
DJ_API int dj_is_playing(void* h, int deck);
DJ_API void dj_seek(void* h, int deck, double frames);
DJ_API double dj_pos(void* h, int deck);
DJ_API int64_t dj_length(void* h, int deck);

// Темп (1.0 — родной), сохранение высоты (keylock), сдвиг тональности в полутонах (только с keylock)
DJ_API void dj_set_tempo(void* h, int deck, double ratio);
DJ_API void dj_set_keylock(void* h, int deck, int on);
DJ_API void dj_set_pitch(void* h, int deck, float semitones);

// Микшер: подрезка (дБ), фейдер 0…1, эквалайзер (дБ, ≤ -24 — полное вырезание), фильтр -1…1
DJ_API void dj_set_trim(void* h, int deck, float db);
DJ_API void dj_set_fader(void* h, int deck, float v);
DJ_API void dj_set_eq(void* h, int deck, float lowDb, float midDb, float highDb);
DJ_API void dj_set_filter(void* h, int deck, float v);
DJ_API void dj_set_loop(void* h, int deck, double inFrames, double outFrames, int active);

// Кроссфейдер -1 (дека A) … 1 (дека B); curve: 0 — постоянная мощность, 1 — сумма
DJ_API void dj_set_crossfader(void* h, float x, int curve);
DJ_API void dj_set_master(void* h, float gain);

// Эффект: unit 0/1; type 0 нет, 1 эхо (p1 — задержка мс, p2 — обратная связь), 2 реверберация (p1 — комната, p2 — демпфирование),
// 3 флэнджер (p1 — частота Гц, p2 — глубина). target: 0 выкл, 1 дека A, 2 дека B, 3 выход. mix 0…1
DJ_API void dj_set_fx(void* h, int unit, int type, int target, float mix, float p1, float p2);

// Пики: дека A, дека B, выход
DJ_API void dj_meters(void* h, float* out3);
DJ_API int dj_overview(void* h, int deck, int buckets, uint8_t* out);

// Прорисовка звука без устройства (проверки)
DJ_API void dj_render(void* h, float* out, int frames);

#ifdef __cplusplus
}
#endif

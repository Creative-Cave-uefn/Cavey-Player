// Источники звука для потока декодера деки.
//  • MaReader — встроенные декодеры miniaudio: MP3, FLAC, WAV. Быстрая точная перемотка.
//  • FfmpegReader — внешний ffmpeg (тот, что приложение уже скачивает для анализа): M4A/AAC, Opus, Ogg и всё
//    остальное. ffmpeg отдаёт сырой float-стерео на родной частоте файла в канал, перемотка — перезапуском с -ss
//    (ffmpeg перематывает с точностью до сэмпла). Задержку кодеров (AAC priming, Opus pre-skip) ffmpeg убирает сам.
#pragma once

#include <cstdint>
#include <memory>
#include <string>

namespace cm {

class Reader {
 public:
  virtual ~Reader() = default;
  virtual int rate() const = 0;                 // родная частота файла
  virtual double durationSec() const = 0;       // 0 — неизвестна
  virtual bool seek(double sec) = 0;
  virtual int read(float *outStereo, int frames) = 0;  // < frames — конец файла (или ошибка)
  virtual const char *kind() const = 0;
};

// Открыть файл встроенным декодером; nullptr — формат не поддерживается
std::unique_ptr<Reader> openMiniaudio(const std::string &pathUtf8);

// Открыть файл через ffmpeg; nullptr — ffmpeg не нашёлся или не распознал файл (причина — в err)
std::unique_ptr<Reader> openFfmpeg(const std::string &ffmpegUtf8, const std::string &pathUtf8, std::string &err);

}  // namespace cm

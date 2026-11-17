#include "readers.h"

#include <cctype>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "third_party/miniaudio/miniaudio.h"

#ifdef _WIN32
#include <windows.h>
#else
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
extern char **environ;
#endif

namespace cm {

// ================================================================ miniaudio

class MaReader : public Reader {
 public:
  ~MaReader() override {
    if (open_) ma_decoder_uninit(&dec_);
  }
  bool open(const std::string &path) {
    ma_decoder_config cfg = ma_decoder_config_init(ma_format_f32, 2, 0);
    ma_result res;
#ifdef _WIN32
    const int wn = MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, nullptr, 0);
    std::wstring w(wn > 0 ? (size_t)wn : 1, L'\0');
    if (wn > 0) MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, &w[0], wn);
    res = ma_decoder_init_file_w(w.c_str(), &cfg, &dec_);
#else
    res = ma_decoder_init_file(path.c_str(), &cfg, &dec_);
#endif
    if (res != MA_SUCCESS) return false;
    open_ = true;
    rate_ = (int)dec_.outputSampleRate;
    ma_uint64 len = 0;
    if (ma_decoder_get_length_in_pcm_frames(&dec_, &len) == MA_SUCCESS && len > 0) dur_ = (double)len / rate_;
    return true;
  }
  int rate() const override { return rate_; }
  double durationSec() const override { return dur_; }
  bool seek(double sec) override {
    return ma_decoder_seek_to_pcm_frame(&dec_, (ma_uint64)llround(sec * rate_)) == MA_SUCCESS;
  }
  int read(float *out, int frames) override {
    ma_uint64 got = 0;
    ma_decoder_read_pcm_frames(&dec_, out, (ma_uint64)frames, &got);
    return (int)got;
  }
  const char *kind() const override { return "miniaudio"; }

 private:
  ma_decoder dec_{};
  bool open_ = false;
  int rate_ = 48000;
  double dur_ = 0;
};

std::unique_ptr<Reader> openMiniaudio(const std::string &path) {
  auto r = std::make_unique<MaReader>();
  if (!r->open(path)) return nullptr;
  return r;
}

// ================================================================ процесс ffmpeg

// Запущенный процесс, из которого читаем stdout (или stderr — для разбора сведений о файле)
class Proc {
 public:
  ~Proc() { kill(); }

  // captureStderr: читать stderr вместо stdout
  bool start(const std::string &exe, const std::vector<std::string> &args, bool captureStderr) {
    kill();
#ifdef _WIN32
    std::wstring cmd = quote(widen(exe));
    for (const auto &a : args) cmd += L" " + quote(widen(a));
    SECURITY_ATTRIBUTES sa{sizeof(sa), nullptr, TRUE};
    HANDLE rd = nullptr, wr = nullptr;
    if (!CreatePipe(&rd, &wr, &sa, 1 << 16)) return false;
    SetHandleInformation(rd, HANDLE_FLAG_INHERIT, 0);
    HANDLE nul = CreateFileW(L"NUL", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa,
                             OPEN_EXISTING, 0, nullptr);
    STARTUPINFOW si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = nul;
    si.hStdOutput = captureStderr ? nul : wr;
    si.hStdError = captureStderr ? wr : nul;
    PROCESS_INFORMATION pi{};
    std::vector<wchar_t> buf(cmd.begin(), cmd.end());
    buf.push_back(0);
    const BOOL ok = CreateProcessW(nullptr, buf.data(), nullptr, nullptr, TRUE, CREATE_NO_WINDOW | BELOW_NORMAL_PRIORITY_CLASS,
                                   nullptr, nullptr, &si, &pi);
    CloseHandle(wr);
    if (nul != INVALID_HANDLE_VALUE) CloseHandle(nul);
    if (!ok) {
      CloseHandle(rd);
      return false;
    }
    CloseHandle(pi.hThread);
    proc_ = pi.hProcess;
    rd_ = rd;
    return true;
#else
    int fd[2];
    if (pipe(fd) != 0) return false;
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
    if (captureStderr) {
      posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0);
      posix_spawn_file_actions_adddup2(&fa, fd[1], 2);
    } else {
      posix_spawn_file_actions_adddup2(&fa, fd[1], 1);
      posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);
    }
    posix_spawn_file_actions_addclose(&fa, fd[0]);
    posix_spawn_file_actions_addclose(&fa, fd[1]);
    std::vector<char *> argv;
    argv.push_back(const_cast<char *>(exe.c_str()));
    for (const auto &a : args) argv.push_back(const_cast<char *>(a.c_str()));
    argv.push_back(nullptr);
    pid_t pid = 0;
    const int rc = posix_spawnp(&pid, exe.c_str(), &fa, nullptr, argv.data(), environ);
    posix_spawn_file_actions_destroy(&fa);
    close(fd[1]);
    if (rc != 0) {
      close(fd[0]);
      return false;
    }
    pid_ = pid;
    rd_ = fd[0];
    return true;
#endif
  }

  // Прочитать до n байт; 0 — конец потока
  size_t read(void *dst, size_t n) {
#ifdef _WIN32
    if (!rd_) return 0;
    DWORD got = 0;
    if (!ReadFile(rd_, dst, (DWORD)n, &got, nullptr)) return 0;
    return got;
#else
    if (rd_ < 0) return 0;
    while (true) {
      const ssize_t r = ::read(rd_, dst, n);
      if (r < 0 && errno == EINTR) continue;
      return r > 0 ? (size_t)r : 0;
    }
#endif
  }

  void kill() {
#ifdef _WIN32
    if (rd_) { CloseHandle(rd_); rd_ = nullptr; }
    if (proc_) {
      TerminateProcess(proc_, 0);
      WaitForSingleObject(proc_, 2000);
      CloseHandle(proc_);
      proc_ = nullptr;
    }
#else
    if (rd_ >= 0) { close(rd_); rd_ = -1; }
    if (pid_ > 0) {
      ::kill(pid_, SIGKILL);
      int st = 0;
      waitpid(pid_, &st, 0);
      pid_ = -1;
    }
#endif
  }

  // Дождаться выхода (для короткой команды-разведки)
  void wait() {
#ifdef _WIN32
    if (proc_) WaitForSingleObject(proc_, 10000);
#else
    if (pid_ > 0) {
      int st = 0;
      waitpid(pid_, &st, 0);
      pid_ = -1;
    }
#endif
  }

 private:
#ifdef _WIN32
  static std::wstring widen(const std::string &s) {
    const int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
    std::wstring w((size_t)n, L'\0');
    if (n > 0) MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), &w[0], n);
    return w;
  }
  // Кавычки по правилам разбора командной строки MSVC CRT
  static std::wstring quote(const std::wstring &a) {
    if (!a.empty() && a.find_first_of(L" \t\n\v\"") == std::wstring::npos) return a;
    std::wstring r = L"\"";
    for (size_t i = 0;; ++i) {
      size_t bs = 0;
      while (i < a.size() && a[i] == L'\\') { ++i; ++bs; }
      if (i == a.size()) { r.append(bs * 2, L'\\'); break; }
      if (a[i] == L'"') { r.append(bs * 2 + 1, L'\\'); r.push_back(L'"'); }
      else { r.append(bs, L'\\'); r.push_back(a[i]); }
    }
    r.push_back(L'"');
    return r;
  }
  HANDLE proc_ = nullptr;
  HANDLE rd_ = nullptr;
#else
  pid_t pid_ = -1;
  int rd_ = -1;
#endif
};

// ================================================================ ffmpeg

class FfmpegReader : public Reader {
 public:
  FfmpegReader(std::string ffmpeg, std::string path) : ffmpeg_(std::move(ffmpeg)), path_(std::move(path)) {}

  // Разведка: ffmpeg -i <файл> печатает в stderr длительность и частоту
  bool probe(std::string &err) {
    Proc p;
    if (!p.start(ffmpeg_, {"-hide_banner", "-nostdin", "-i", path_}, true)) {
      err = "не удалось запустить ffmpeg: " + ffmpeg_;
      return false;
    }
    std::string text;
    char buf[4096];
    size_t n;
    while ((n = p.read(buf, sizeof(buf))) > 0 && text.size() < (1u << 20)) text.append(buf, n);
    p.wait();
    // «Duration: 00:03:21.44,»
    const size_t d = text.find("Duration: ");
    if (d != std::string::npos) {
      int h = 0, m = 0;
      double s = 0;
      if (std::sscanf(text.c_str() + d + 10, "%d:%d:%lf", &h, &m, &s) == 3) dur_ = h * 3600.0 + m * 60.0 + s;
    }
    // «Stream #0:0(und): Audio: aac (LC) (mp4a / 0x6134706D), 44100 Hz, stereo, fltp»
    const size_t a = text.find("Audio: ");
    if (a == std::string::npos) {
      err = "ffmpeg не нашёл звука в файле: " + path_;
      return false;
    }
    const size_t eol = text.find('\n', a);
    const std::string line = text.substr(a, eol == std::string::npos ? std::string::npos : eol - a);
    const size_t hz = line.find(" Hz");
    if (hz == std::string::npos) {
      err = "ffmpeg не сообщил частоту: " + path_;
      return false;
    }
    size_t b = hz;
    while (b > 0 && (std::isdigit((unsigned char)line[b - 1]))) --b;
    rate_ = std::atoi(line.substr(b, hz - b).c_str());
    if (rate_ < 8000 || rate_ > 768000) {
      err = "странная частота файла: " + path_;
      return false;
    }
    return true;
  }

  int rate() const override { return rate_; }
  double durationSec() const override { return dur_; }
  bool seek(double sec) override {
    proc_.kill();
    started_ = false;
    pos_ = sec < 0 ? 0 : sec;
    tailBytes_ = 0;
    return true;
  }
  int read(float *out, int frames) override {
    if (!started_) {
      started_ = true;
      char ss[64];
      std::snprintf(ss, sizeof(ss), "%.6f", pos_);
      std::vector<std::string> args = {"-nostdin", "-hide_banner", "-loglevel", "error"};
      if (pos_ > 0) { args.push_back("-ss"); args.push_back(ss); }
      args.push_back("-i");
      args.push_back(path_);
      for (const char *a : {"-map", "0:a:0", "-vn", "-sn", "-dn", "-f", "f32le", "-ac", "2", "-"}) args.push_back(a);
      if (!proc_.start(ffmpeg_, args, false)) return 0;
    }
    // читаем ровно frames кадров (по 8 байт), докручивая неполные чтения
    auto *dst = reinterpret_cast<unsigned char *>(out);
    const size_t want = (size_t)frames * 8;
    size_t have = 0;
    if (tailBytes_ > 0) {
      std::memcpy(dst, tail_, tailBytes_);
      have = tailBytes_;
      tailBytes_ = 0;
    }
    while (have < want) {
      const size_t n = proc_.read(dst + have, want - have);
      if (n == 0) break;
      have += n;
    }
    const size_t whole = have / 8 * 8;
    tailBytes_ = have - whole;  // при конце потока огрызок кадра просто отбрасывается
    if (tailBytes_) std::memcpy(tail_, dst + whole, tailBytes_);
    return (int)(whole / 8);
  }
  const char *kind() const override { return "ffmpeg"; }

 private:
  std::string ffmpeg_, path_;
  Proc proc_;
  bool started_ = false;
  double pos_ = 0;
  int rate_ = 0;
  double dur_ = 0;
  unsigned char tail_[8];
  size_t tailBytes_ = 0;
};

std::unique_ptr<Reader> openFfmpeg(const std::string &ffmpeg, const std::string &path, std::string &err) {
  if (ffmpeg.empty()) {
    err = "движок не читает этот формат сам, а путь к ffmpeg не задан";
    return nullptr;
  }
  auto r = std::make_unique<FfmpegReader>(ffmpeg, path);
  if (!r->probe(err)) return nullptr;
  return r;
}

}  // namespace cm

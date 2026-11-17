// Очередь «один писатель — один читатель» без блокировок. Аудиопоток никогда не ждёт.
#pragma once

#include <atomic>
#include <cstddef>

namespace cm {

template <typename T, size_t N>
class Spsc {
  static_assert((N & (N - 1)) == 0, "N must be a power of two");

 public:
  bool push(const T &v) {
    const size_t h = head_.load(std::memory_order_relaxed);
    if (h - tail_.load(std::memory_order_acquire) >= N) return false;
    buf_[h & (N - 1)] = v;
    head_.store(h + 1, std::memory_order_release);
    return true;
  }
  bool peek(T &out) const {
    const size_t t = tail_.load(std::memory_order_relaxed);
    if (t == head_.load(std::memory_order_acquire)) return false;
    out = buf_[t & (N - 1)];
    return true;
  }
  bool pop(T &out) {
    const size_t t = tail_.load(std::memory_order_relaxed);
    if (t == head_.load(std::memory_order_acquire)) return false;
    out = buf_[t & (N - 1)];
    tail_.store(t + 1, std::memory_order_release);
    return true;
  }
  size_t size() const { return head_.load(std::memory_order_acquire) - tail_.load(std::memory_order_acquire); }

 private:
  T buf_[N];
  alignas(64) std::atomic<size_t> head_{0};
  alignas(64) std::atomic<size_t> tail_{0};
};

}  // namespace cm

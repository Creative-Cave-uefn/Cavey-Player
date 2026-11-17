# Cavey DJ: AutoDJ and live manual mixing

DJ functionality lives alongside the normal player. It does not modify the original playlist order unless you explicitly save a new AutoDJ playlist.

## AutoDJ (playlist / album / queue)

1. From any playlist or album use **АвтоDJ**. The menu can play an infinite feed, order a finite queue, save that order, or analyze tracks.
2. **Разобрать темп и тональность** caches BPM, a beat grid, a Camelot key and a small waveform. The analyzer uses ffmpeg and can require local cache download. Results are stored locally.
3. In player settings, select the **DJ** transition style and its bar count. The planner prefers beat/bar-aligned transitions and adjusts speed within the configured range. When BPM or beat positions cannot be trusted, it falls back to the normal smart crossfade.
4. Enable **Микс** on a track list to show beat/key columns and transition chips. Open a chip to set transition start, the next track's entry, bars, tempo sync, bass handoff and beat offset. You can preview or save each transition separately.
5. The ordinary player bar also has a **Свести сейчас** action.

## Manual DJ console (Windows desktop)

Click the **tune** icon on the player bar to open two independent decks.

- **Load** any track from the connected library onto A or B. Current track and the next queued track are preloaded when available.
- Each deck has independent **Play/Pause**, seekable waveform, **Set CUE / Go CUE**, tempo ±15%, **SYNC**, ±20 ms beat nudge, and **Bass cut**.
- Both decks stay open and can play simultaneously. The crossfader follows an equal-power curve, and the master defaults to 70% for headroom. Volume writes are coalesced and serialized to avoid stale command races.
- **SYNC** adjusts the target deck to the other's BPM (including half/double-time matches) within a safe ±16% envelope. If a beat grid exists it also does an initial phase adjustment. This is an approximate seek-based sync, not a sample-accurate phase lock.
- The ordinary player is paused while the DJ console is open; the main queue is left unchanged. **Вернуться к плееру** stops the decks and resumes the ordinary player.

## Limitations and testing

- The independent DJ console uses the player's existing authenticated streaming proxy/cache, not a separate Spotify or Deezer playback API. Cloud streams can still buffer if the connection is slow.
- The mpv audio-filter backend may not support Bass cut on all builds; the UI reports the limitation.
- SYNC and cue/seek accuracy depend on the media decoder and source. Manual phase nudging and listening are still useful; do not assume zero-latency sample-accurate mixing.
- There is no separate headphone output routing, recording, jog wheel, MIDI or dedicated audio limiter in this version. Keep the master below clipping.
- New pure-math tests: test/dj_live_math_test.dart. Imported DJ tests: test/beats_test.dart, test/dj_test.dart, test/mixbook_test.dart.
- **Validation note:** this repository's Windows GitHub Action currently marks its \`checks\` job failed in a few seconds with no job steps/log attached, even for a no-change branch pointing at main. Consequently, this branch has not yet been compiled or verified by Flutter's analyzer on a runner. Run \`flutter analyze\` and \`flutter test\` in a working Flutter 3.27.4 environment before merging.

## Audio Intelligence (признаки звука для сведения)

Данные для DJ — сетка долей по всему треку, границы фраз, громкость (LUFS), кривые энергии и «присутствия вокала» по секундам,
признаки вступления и концовки — считаются фоновым разбором и лежат в общем индексе. Подробности и формат: [AUDIO_INTELLIGENCE.md](AUDIO_INTELLIGENCE.md).
Адаптивный планировщик использует эти данные для совместного выбора точек входа, выхода и длины перехода.

### Выбор музыкального перехода

- При включённой гармонической совместимости надёжные тональности учитываются вместе с локальной хромой. Конфликт Camelot ограничивает наложение двумя тактами. Неизвестная или слабая оценка тональности не является запретом.
- Для длинного beat blend найденные с достаточной уверенностью фразы задают вход следующего трека и завершение наложения уходящего. Поиск рассматривает также точки за 4 и 8 тактов до конца фразы. Без уверенного определения фраз планировщик не выдумывает их сетку.
- При прочих равных 4- и 8-тактовые переходы получают небольшое преимущество. Ограничения по голосам, локальному ритму, темпу и доступной длине аудио остаются обязательными.
- Резкий стык требует разрешения `allowCut` и попадания на такт обоих треков, если начало такта известно; при наличии только локального пульса требуется попадание на наблюдаемую долю. Без ритмической опоры выбирается плавный переход.
- В диагностике перехода доступны `keyCompatibility`, `phrasing` и `durationFit`. Автоматические тесты проверяют выбор плана; качество реального звучания нужно оценить прослушиванием.

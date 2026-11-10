import 'dart:math' as math;

import 'package:djengine/djengine.dart';
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';

import '../app.dart';
import '../core/djdecks.dart';
import '../core/djsync.dart' show eqKnobToDb;
import '../core/models.dart';
import 'glass_popup.dart';
import 'mix_view.dart' show KeyBadge;
import 'theme.dart';

// Страница «DJ-пульт»: две деки, микшер, эффекты и автоматический режим.
// Звук делает собственный движок (packages/djengine), здесь только управление и картинка.

const _deckColors = [Color(0xFFF2C14E), Color(0xFF6EC8FF)];

class DjPage extends StatefulWidget {
  final bool compact;
  const DjPage({super.key, required this.compact});

  @override
  State<DjPage> createState() => _DjPageState();
}

class _DjPageState extends State<DjPage> {
  bool _started = false;
  bool _showAuto = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final djd = Services.of(context).djDecks;
    Future<void>.microtask(djd.ensureEngine);
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final djd = app.djDecks;
    final pad = widget.compact ? 16.0 : 32.0;
    return ListenableBuilder(
      listenable: Listenable.merge([djd, djd.tick]),
      builder: (context, _) {
        return LayoutBuilder(builder: (context, box) {
          final wide = box.maxWidth >= 1120;
          final decks = [_deck(context, app, 0), _deck(context, app, 1)];
          final mixer = _mixer(djd);
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(pad, 20, pad, 32),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _header(djd),
              if (_showAuto) _autoSettings(djd),
              if (djd.error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(djd.error!, style: const TextStyle(color: C.danger)),
                ),
              const SizedBox(height: 12),
              if (wide)
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: decks[0]),
                  const SizedBox(width: 14),
                  SizedBox(width: 330, child: mixer),
                  const SizedBox(width: 14),
                  Expanded(child: decks[1]),
                ])
              else ...[
                decks[0],
                const SizedBox(height: 14),
                mixer,
                const SizedBox(height: 14),
                decks[1],
              ],
            ]),
          );
        });
      },
    );
  }

  // ---------- шапка и АвтоDJ ----------

  Widget _header(DjDecks djd) {
    return Row(children: [
      Text('DJ-пульт', style: display(widget.compact ? 24 : 30)),
      const SizedBox(width: 20),
      _Btn(
        icon: Icons.auto_mode_rounded,
        label: djd.auto ? 'АвтоDJ включён' : 'АвтоDJ',
        on: djd.auto,
        onTap: () => djd.setAuto(!djd.auto),
        tooltip: 'Сам выбирает следующий трек, подгоняет темп и тональность и сводит',
      ),
      const SizedBox(width: 8),
      _Btn(icon: Icons.tune_rounded, label: 'Настройки', on: _showAuto, onTap: () => setState(() => _showAuto = !_showAuto)),
      const SizedBox(width: 14),
      Expanded(
        child: Text(
          djd.auto ? djd.autoStatus : '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: C.muted, fontSize: 13),
        ),
      ),
    ]);
  }

  Widget _autoSettings(DjDecks djd) {
    Widget chips(String key, String def, Map<String, String> options) {
      final cur = djd.settings.viewOf(key, def);
      return Wrap(spacing: 6, runSpacing: 6, children: [
        for (final e in options.entries) _Btn(label: e.value, on: cur == e.key, onTap: () => djd.putSetting(key, e.key)),
      ]);
    }

    Widget row(String title, Widget child) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            SizedBox(width: 190, child: Text(title, style: const TextStyle(color: C.muted, fontSize: 13))),
            Expanded(child: child),
          ]),
        );
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        row(
            'Приём перехода',
            chips('dj.auto.style', 'random', const {
              'random': 'Случайный',
              'fade': 'Наложение',
              'bass': 'Смена басов',
              'filter': 'Фильтр',
              'echo': 'Эхо',
            })),
        row(
            'Длина, тактов',
            chips('dj.auto.bars', '8', const {'4': '4', '8': '8', '16': '16', '32': '32', 'rnd': 'Случайно'})),
        row(
          'Подгонять тональность',
          Align(
            alignment: Alignment.centerLeft,
            child: Switch(value: djd.autoKeyMatch, onChanged: (v) => djd.putSetting('dj.auto.key', v ? '1' : '0')),
          ),
        ),
        row(
          'Возвращать темп трека',
          Align(
            alignment: Alignment.centerLeft,
            child: Switch(value: djd.autoRestoreTempo, onChanged: (v) => djd.putSetting('dj.auto.restore', v ? '1' : '0')),
          ),
        ),
        row(
          'Разница темпа до ${djd.autoMaxBpm.round()} %',
          _slider(djd.autoMaxBpm, 2, 25, (v) => djd.putSetting('dj.auto.maxbpm', v.round().toString()), color: C.accent),
        ),
        const Text(
          'Точка входа — главная метка трека (CUE), выхода — четвёртая быстрая метка. Если их нет, берётся начало и конец по анализу звука.',
          style: TextStyle(color: C.faint, fontSize: 12),
        ),
      ])),
    );
  }

  // ---------- дека ----------

  Widget _deck(BuildContext context, AppServices app, int d) {
    final djd = app.djDecks;
    final dk = djd.decks[d];
    final col = _deckColors[d];
    final loaded = dk.frames > 0;
    final pos = loaded ? djd.posMs(d) : 0.0;
    final other = djd.decks[1 - d];
    final canSync = dk.grid != null && other.grid != null;
    final tempoPct = (dk.tempo - 1) * 100;

    String fmt(double ms) {
      final s = (ms / 1000).floor().clamp(0, 359999);
      return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
    }

    final t = dk.track;
    return _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Заголовок
      Row(children: [
        Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: col, borderRadius: BorderRadius.circular(8)),
          child: Text(d == 0 ? 'A' : 'B', style: const TextStyle(color: Color(0xFF15151C), fontWeight: FontWeight.w800)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              t == null ? 'Деке нужен трек' : t.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: C.text, fontSize: 15, fontWeight: FontWeight.w600),
            ),
            Text(
              dk.status.isNotEmpty ? dk.status : (t == null ? '' : t.displayArtist),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: dk.status.startsWith('Ошибка') ? C.danger : C.muted, fontSize: 12),
            ),
          ]),
        ),
        if (loaded) ...[
          const SizedBox(width: 8),
          Text(dk.effectiveBpm == null ? '— уд/мин' : '${dk.effectiveBpm!.toStringAsFixed(1)} уд/мин', style: const TextStyle(color: C.muted, fontSize: 12)),
          const SizedBox(width: 8),
          KeyBadge(dk.key?.toString()),
        ],
      ]),
      const SizedBox(height: 10),
      Row(children: [
        _Btn(icon: Icons.folder_open_rounded, label: 'Выбрать трек', onTap: () => _pick(context, app, d)),
        const SizedBox(width: 8),
        _Btn(
          icon: Icons.music_note_rounded,
          label: 'Играющий',
          onTap: app.player.current == null ? null : () => djd.load(d, app.player.current!),
          tooltip: 'Загрузить трек, который сейчас выбран в плеере',
        ),
        const SizedBox(width: 8),
        _Btn(icon: Icons.eject_rounded, label: 'Достать', onTap: dk.track == null ? null : () => djd.eject(d)),
      ]),
      const SizedBox(height: 12),
      // Волна
      SizedBox(
        height: 92,
        child: LayoutBuilder(builder: (context, box) {
          void seekTo(double x) => djd.seekFraction(d, x / box.maxWidth);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: loaded ? (e) => seekTo(e.localPosition.dx) : null,
            onHorizontalDragUpdate: loaded ? (e) => seekTo(e.localPosition.dx) : null,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: CustomPaint(painter: _WavePainter(djd, d, col), size: Size.infinite),
            ),
          );
        }),
      ),
      const SizedBox(height: 6),
      Row(children: [
        Text(fmt(pos), style: const TextStyle(color: C.text, fontSize: 13, fontFeatures: [FontFeature.tabularFigures()])),
        const Spacer(),
        Text('−${fmt(math.max(0, dk.lengthMs - pos))}', style: const TextStyle(color: C.muted, fontSize: 13, fontFeatures: [FontFeature.tabularFigures()])),
      ]),
      const SizedBox(height: 10),
      // Транспорт
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        _Btn(
          icon: Icons.play_arrow_rounded,
          pauseIcon: Icons.pause_rounded,
          label: dk.playing ? 'Пауза' : 'Играть',
          on: dk.playing,
          color: col,
          onTap: loaded ? () => djd.playPause(d) : null,
        ),
        _Btn(
          label: 'CUE',
          color: col,
          onTap: null,
          onDown: loaded ? () => djd.cuePreview(d, true) : null,
          onUp: loaded ? () => djd.cuePreview(d, false) : null,
          tooltip: 'На ходу — вернуться к метке. На паузе — поставить метку; зажать — послушать от метки',
        ),
        _Btn(
          icon: Icons.sync_rounded,
          label: 'SYNC',
          on: dk.synced,
          color: col,
          onTap: loaded && canSync ? () => dk.synced ? djd.unsync(d) : djd.sync(d) : null,
          tooltip: canSync ? 'Подогнать темп и доли под вторую деку и держать' : 'Нужны темп и сетка долей у обоих треков',
        ),
        _Btn(
          icon: Icons.lock_outline_rounded,
          label: 'Тон',
          on: dk.keylock,
          color: col,
          onTap: loaded ? () => djd.setKeylock(d, !dk.keylock) : null,
          tooltip: 'Сохранять тональность при смене темпа',
        ),
        _Btn(label: '−', onTap: null, onDown: loaded ? () => djd.bend(d, -1) : null, onUp: loaded ? () => djd.bend(d, 0) : null, tooltip: 'Подтолкнуть назад'),
        _Btn(label: '+', onTap: null, onDown: loaded ? () => djd.bend(d, 1) : null, onUp: loaded ? () => djd.bend(d, 0) : null, tooltip: 'Подтолкнуть вперёд'),
        _Btn(label: '−4', onTap: loaded ? () => djd.jump(d, -4) : null, tooltip: 'Назад на 4 доли'),
        _Btn(label: '+4', onTap: loaded ? () => djd.jump(d, 4) : null, tooltip: 'Вперёд на 4 доли'),
      ]),
      const SizedBox(height: 12),
      // Быстрые метки
      Row(children: [
        for (var i = 0; i < 4; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: _Btn(
              label: dk.hot[i] == null ? '${i + 1}' : '${i + 1} · ${fmt(dk.hot[i]!.toDouble())}',
              on: dk.hot[i] != null,
              color: [const Color(0xFFFF7A7A), const Color(0xFFFFB86B), const Color(0xFF7BE0A1), const Color(0xFFB48CFF)][i],
              wide: true,
              onTap: loaded ? () => djd.hotcue(d, i) : null,
              onSecondary: loaded ? () => djd.clearHotcue(d, i) : null,
              tooltip: i == 3
                  ? 'Быстрая метка. Правая кнопка — стереть. Четвёртая — точка выхода для АвтоDJ'
                  : 'Быстрая метка. Правая кнопка — стереть',
            ),
          ),
        ],
      ]),
      const SizedBox(height: 12),
      // Петли
      Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        const Text('Петля', style: TextStyle(color: C.muted, fontSize: 12)),
        for (final b in const [0.5, 1.0, 2.0, 4.0, 8.0, 16.0])
          _Btn(
            label: b < 1 ? '1/2' : b.round().toString(),
            on: dk.loopOn && dk.loopBeats == b,
            color: col,
            onTap: loaded ? () => djd.loop(d, b) : null,
          ),
        _Btn(label: '÷2', onTap: dk.loopOn ? () => djd.loopScale(d, 0.5) : null),
        _Btn(label: '×2', onTap: dk.loopOn ? () => djd.loopScale(d, 2) : null),
        _Btn(label: 'Вход', onTap: loaded ? () => djd.loopIn(d) : null),
        _Btn(label: 'Выход', onTap: loaded ? () => djd.loopOut(d) : null),
        _Btn(label: 'Снять', onTap: dk.loopOn ? () => djd.loopOff(d) : null),
      ]),
      const SizedBox(height: 12),
      // Темп
      Row(children: [
        SizedBox(width: 74, child: Text('Темп ${tempoPct >= 0 ? '+' : '−'}${tempoPct.abs().toStringAsFixed(1)}%', style: const TextStyle(color: C.muted, fontSize: 12))),
        Expanded(child: _slider(djd.tempoSlider(d), -1, 1, (v) => djd.setTempoSlider(d, v), color: col)),
        _Btn(label: '±${dk.range.round()}%', onTap: () => djd.setRange(d, const [6.0, 8.0, 16.0, 50.0][(const [6.0, 8.0, 16.0, 50.0].indexOf(dk.range) + 1) % 4])),
        const SizedBox(width: 6),
        _Btn(label: '0', onTap: loaded ? () => djd.setTempo(d, 1) : null, tooltip: 'Вернуть темп трека'),
      ]),
      Row(children: [
        SizedBox(width: 74, child: Text('Тон ${dk.pitch >= 0 ? '+' : '−'}${dk.pitch.abs().toStringAsFixed(1)}', style: const TextStyle(color: C.muted, fontSize: 12))),
        Expanded(child: _slider(dk.pitch, -6, 6, (v) => djd.setPitch(d, (v * 2).round() / 2), color: col)),
        _Btn(label: '0', onTap: loaded ? () => djd.setPitch(d, 0) : null, tooltip: 'Без сдвига тональности'),
        const SizedBox(width: 6),
        _Btn(
          icon: Icons.music_note_rounded,
          label: 'Подогнать',
          onTap: loaded && other.key != null && dk.profile?.key != null ? () => djd.keyMatchNow(d) : null,
          tooltip: 'Сдвинуть тональность так, чтобы она подходила второй деке',
        ),
      ]),
    ]));
  }

  Future<void> _pick(BuildContext context, AppServices app, int d) async {
    final all = app.lib.allTracks;
    final q = TextEditingController();
    final picked = await showGlassDialog<Track>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        final s = q.text.trim().toLowerCase();
        final list = <Track>[];
        for (final t in all) {
          if (s.isEmpty || t.title.toLowerCase().contains(s) || t.artist.toLowerCase().contains(s) || t.album.toLowerCase().contains(s)) {
            list.add(t);
            if (list.length >= 80) break;
          }
        }
        return AlertDialog(
          title: Text('Трек для деки ${d == 0 ? 'A' : 'B'}', style: display(18)),
          content: SizedBox(
            width: 480,
            height: 460,
            child: Column(children: [
              TextField(
                controller: q,
                autofocus: true,
                decoration: const InputDecoration(hintText: 'Название или исполнитель', prefixIcon: Icon(Icons.search_rounded)),
                onChanged: (_) => setS(() {}),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (_, i) {
                    final t = list[i];
                    final pr = app.player.mixer?.profileCached(t.id);
                    return ListTile(
                      dense: true,
                      title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(t.displayArtist, maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: pr?.bpm == null ? null : Text('${pr!.bpm!.round()}', style: const TextStyle(color: C.muted)),
                      onTap: () => Navigator.of(ctx).pop(t),
                    );
                  },
                ),
              ),
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Отмена'))],
        );
      }),
    );
    if (picked != null) await app.djDecks.load(d, picked);
  }

  // ---------- микшер ----------

  Widget _mixer(DjDecks djd) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _card(Column(children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [_strip(djd, 0), _strip(djd, 1)]),
        const SizedBox(height: 10),
        Row(children: [
          const Text('A', style: TextStyle(color: C.muted, fontWeight: FontWeight.w700)),
          Expanded(child: _slider(djd.crossfader, -1, 1, djd.setCrossfader, color: C.accent)),
          const Text('B', style: TextStyle(color: C.muted, fontWeight: FontWeight.w700)),
        ]),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('Кроссфейдер', style: TextStyle(color: C.faint, fontSize: 12)),
          Row(children: [
            _Btn(label: 'Мягкий', on: !djd.sharpCurve, onTap: () => djd.setSharpCurve(false)),
            const SizedBox(width: 6),
            _Btn(label: 'Резкий', on: djd.sharpCurve, onTap: () => djd.setSharpCurve(true)),
          ]),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          _Knob(label: 'Общая', value: djd.master, min: 0, max: 1.5, reset: 0.9, color: C.accent, fmt: (v) => '${(v * 100).round()}%', onChanged: djd.setMaster),
          const SizedBox(width: 14),
          Expanded(child: _Meter(level: djd.levels[2], horizontal: true)),
        ]),
      ])),
      const SizedBox(height: 14),
      _card(Column(children: [_fxUnit(djd, 0), const Divider(height: 22, color: C.divider), _fxUnit(djd, 1)])),
    ]);
  }

  Widget _strip(DjDecks djd, int d) {
    final dk = djd.decks[d];
    final col = _deckColors[d];
    String db(double v) => '${eqKnobToDb(v).round()} дБ';
    return Expanded(
      child: Column(children: [
        Text(d == 0 ? 'A' : 'B', style: TextStyle(color: col, fontWeight: FontWeight.w800, fontSize: 15)),
        const SizedBox(height: 4),
        _Knob(label: 'Подрезка', value: dk.trim, min: -12, max: 12, reset: 0, color: col, fmt: (v) => '${v.toStringAsFixed(1)} дБ', onChanged: (v) => djd.setTrim(d, v)),
        _Knob(label: 'Высокие', value: dk.eqHigh, min: -1, max: 1, reset: 0, color: col, fmt: db, onChanged: (v) => djd.setEq(d, high: v)),
        _Knob(label: 'Средние', value: dk.eqMid, min: -1, max: 1, reset: 0, color: col, fmt: db, onChanged: (v) => djd.setEq(d, mid: v)),
        _Knob(label: 'Низкие', value: dk.eqLow, min: -1, max: 1, reset: 0, color: col, fmt: db, onChanged: (v) => djd.setEq(d, low: v)),
        _Knob(
          label: 'Фильтр',
          value: dk.filter,
          min: -1,
          max: 1,
          reset: 0,
          color: col,
          fmt: (v) => v.abs() < 0.02 ? 'выкл' : (v < 0 ? 'НЧ' : 'ВЧ'),
          onChanged: (v) => djd.setFilter(d, v),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 150,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            SizedBox(
              width: 34,
              height: 150,
              child: RotatedBox(quarterTurns: 3, child: _slider(dk.fader, 0, 1, (v) => djd.setFader(d, v), color: col)),
            ),
            const SizedBox(width: 6),
            _Meter(level: djd.levels[d], horizontal: false),
          ]),
        ),
      ]),
    );
  }

  Widget _fxUnit(DjDecks djd, int u) {
    final f = djd.fx[u];
    const names = {DjFx.none: 'Выкл', DjFx.echo: 'Эхо', DjFx.reverb: 'Реверберация', DjFx.flanger: 'Флэнджер'};
    final (l1, min1, max1, l2) = switch (f.type) {
      DjFx.echo => ('Задержка, мс', 60.0, 1000.0, 'Повторы'),
      DjFx.reverb => ('Комната', 0.0, 1.0, 'Демпфирование'),
      DjFx.flanger => ('Частота, Гц', 0.05, 3.0, 'Глубина'),
      DjFx.none => ('', 0.0, 1.0, ''),
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Эффект ${u + 1}', style: const TextStyle(color: C.muted, fontSize: 12, fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final e in names.entries) _Btn(label: e.value, on: f.type == e.key, onTap: () => djd.setFx(u, type: e.key)),
      ]),
      if (f.type != DjFx.none) ...[
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          _Btn(label: 'Дека A', on: f.target == DjFxTarget.deckA, color: _deckColors[0], onTap: () => djd.setFx(u, target: DjFxTarget.deckA)),
          _Btn(label: 'Дека B', on: f.target == DjFxTarget.deckB, color: _deckColors[1], onTap: () => djd.setFx(u, target: DjFxTarget.deckB)),
          _Btn(label: 'Всё', on: f.target == DjFxTarget.master, onTap: () => djd.setFx(u, target: DjFxTarget.master)),
        ]),
        _labeled('Сила', _slider(f.mix, 0, 1, (v) => djd.setFx(u, mix: v), color: C.accent)),
        _labeled(l1, _slider(f.p1.clamp(min1, max1).toDouble(), min1, max1, (v) => djd.setFx(u, p1: v), color: C.accent)),
        _labeled(l2, _slider(f.p2.clamp(0.0, 1.0).toDouble(), 0, 1, (v) => djd.setFx(u, p2: v), color: C.accent)),
      ],
    ]);
  }

  Widget _labeled(String label, Widget child) => Row(children: [
        SizedBox(width: 104, child: Text(label, style: const TextStyle(color: C.faint, fontSize: 12))),
        Expanded(child: child),
      ]);
}

Widget _card(Widget child) => Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: C.line)),
      child: child,
    );

Widget _slider(double value, double min, double max, ValueChanged<double> onChanged, {required Color color}) {
  return SliderTheme(
    data: SliderThemeData(
      trackHeight: 3,
      activeTrackColor: color,
      inactiveTrackColor: C.line,
      thumbColor: color,
      overlayShape: SliderComponentShape.noOverlay,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
    ),
    child: Slider(value: value.clamp(min, max).toDouble(), min: min, max: max, onChanged: onChanged),
  );
}

// ---------- мелкие детали ----------

/// Кнопка пульта. [onDown]/[onUp] — для зажимаемых (CUE, подталкивание), [onSecondary] — правая кнопка мыши
class _Btn extends StatelessWidget {
  final IconData? icon;
  final IconData? pauseIcon;
  final String label;
  final bool on;
  final Color? color;
  final bool wide;
  final VoidCallback? onTap;
  final VoidCallback? onDown;
  final VoidCallback? onUp;
  final VoidCallback? onSecondary;
  final String? tooltip;

  const _Btn({
    this.icon,
    this.pauseIcon,
    required this.label,
    this.on = false,
    this.color,
    this.wide = false,
    this.onTap,
    this.onDown,
    this.onUp,
    this.onSecondary,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null || onDown != null;
    final accent = color ?? C.accent;
    final ink = accent.computeLuminance() > 0.42 ? const Color(0xFF15151C) : Colors.white;
    final fg = on ? ink : (enabled ? C.text : C.faint);
    Widget body = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      alignment: wide ? Alignment.center : null,
      decoration: BoxDecoration(
        color: on ? accent : C.raised,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: on ? accent : C.line),
      ),
      child: Row(mainAxisSize: wide ? MainAxisSize.max : MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
        if (icon != null) ...[Icon(on && pauseIcon != null ? pauseIcon : icon, size: 17, color: fg), if (label.isNotEmpty) const SizedBox(width: 6)],
        Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: fg, fontSize: 12.5, fontWeight: FontWeight.w600))),
      ]),
    );
    if (onDown != null || onUp != null) {
      body = Listener(
        onPointerDown: (_) => onDown?.call(),
        onPointerUp: (_) => onUp?.call(),
        onPointerCancel: (_) => onUp?.call(),
        child: body,
      );
    } else {
      body = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onSecondaryTap: onSecondary,
        onLongPress: onSecondary,
        child: body,
      );
    }
    final w = MouseRegion(cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer, child: body);
    return tooltip == null ? w : Tooltip(message: tooltip!, waitDuration: const Duration(milliseconds: 500), child: w);
  }
}

/// Круглый регулятор: тянуть вверх/вниз или крутить колесом, двойной щелчок — сброс
class _Knob extends StatelessWidget {
  final String label;
  final double value, min, max, reset;
  final Color color;
  final String Function(double) fmt;
  final ValueChanged<double> onChanged;

  const _Knob({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.reset,
    required this.color,
    required this.fmt,
    required this.onChanged,
  });

  void _by(double delta) => onChanged((value + delta * (max - min)).clamp(min, max).toDouble());

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: (e) {
        if (e is PointerScrollEvent) _by(-e.scrollDelta.dy / 1500);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (d) => _by(-d.delta.dy / 140),
        onDoubleTap: () => onChanged(reset),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(width: 38, height: 38, child: CustomPaint(painter: _KnobPainter((value - min) / (max - min), (reset - min) / (max - min), color))),
            const SizedBox(width: 8),
            SizedBox(
              width: 62,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 11.5)),
                Text(fmt(value), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.faint, fontSize: 11)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _KnobPainter extends CustomPainter {
  final double t, home;
  final Color color;
  _KnobPainter(this.t, this.home, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 3;
    const start = 0.75 * math.pi, sweep = 1.5 * math.pi;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = C.line;
    canvas.drawArc(Rect.fromCircle(center: c, radius: r), start, sweep, false, track);
    final a0 = start + sweep * home.clamp(0, 1);
    final a1 = start + sweep * t.clamp(0, 1);
    canvas.drawArc(Rect.fromCircle(center: c, radius: r), math.min(a0, a1), (a1 - a0).abs(), false, track..color = color);
    final tip = c + Offset(math.cos(a1), math.sin(a1)) * (r - 6);
    canvas.drawLine(c + Offset(math.cos(a1), math.sin(a1)) * 3, tip, Paint()
      ..color = C.text
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(_KnobPainter o) => o.t != t || o.color != color || o.home != home;
}

/// Индикатор уровня (пик, шкала в децибелах от −48 до +3)
class _Meter extends StatelessWidget {
  final double level;
  final bool horizontal;
  const _Meter({required this.level, required this.horizontal});

  @override
  Widget build(BuildContext context) {
    final db = level <= 0.0004 ? -48.0 : 20 * math.log(level) / math.ln10;
    final f = ((db + 48) / 51).clamp(0.0, 1.0).toDouble();
    final hot = db > -3;
    final fill = hot ? C.danger : (db > -12 ? const Color(0xFFFFD166) : const Color(0xFF7BE0A1));
    return Container(
      width: horizontal ? null : 10,
      height: horizontal ? 10 : 150,
      decoration: BoxDecoration(color: C.raised, borderRadius: BorderRadius.circular(5)),
      child: FractionallySizedBox(
        alignment: horizontal ? Alignment.centerLeft : Alignment.bottomCenter,
        widthFactor: horizontal ? f : 1,
        heightFactor: horizontal ? 1 : f,
        child: Container(decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(5))),
      ),
    );
  }
}

/// Волна трека с бегунком, метками и петлёй. Перерисовывается по тику движка
class _WavePainter extends CustomPainter {
  final DjDecks djd;
  final int d;
  final Color color;
  _WavePainter(this.djd, this.d, this.color) : super(repaint: djd.tick);

  @override
  void paint(Canvas canvas, Size size) {
    final dk = djd.decks[d];
    canvas.drawRect(Offset.zero & size, Paint()..color = C.raised);
    if (dk.frames == 0) return;
    final len = dk.lengthMs;
    final pos = djd.posMs(d);
    final wave = dk.wave;
    final playedX = size.width * (pos / len).clamp(0.0, 1.0);
    final mid = size.height / 2;

    if (dk.loopIn != null && dk.loopOut != null) {
      final a = size.width * dk.loopIn! / len, b = size.width * dk.loopOut! / len;
      canvas.drawRect(Rect.fromLTRB(a, 0, b, size.height), Paint()..color = (dk.loopOn ? color : C.faint).withValues(alpha: 0.22));
    }

    if (wave.isNotEmpty) {
      final dim = Paint()
        ..color = color.withValues(alpha: 0.38)
        ..strokeWidth = 1;
      final lit = Paint()
        ..color = color
        ..strokeWidth = 1;
      final n = wave.length;
      for (var x = 0.0; x < size.width; x += 1.5) {
        final i = math.min(n - 1, (x / size.width * n).floor());
        final h = wave[i] / 255.0 * (size.height / 2 - 2) + 1;
        canvas.drawLine(Offset(x, mid - h), Offset(x, mid + h), x <= playedX ? lit : dim);
      }
    }

    // Доли трека (если сетка известна и она не слишком частая)
    final g = dk.grid;
    if (g != null && size.width / (len / g.periodMs) > 3) {
      final p = Paint()
        ..color = const Color(0x33FFFFFF)
        ..strokeWidth = 1;
      for (var b = (g.beatAt(0)).ceil(); g.timeOf(b.toDouble()) < len; b++) {
        final x = size.width * g.timeOf(b.toDouble()) / len;
        canvas.drawLine(Offset(x, size.height - (b % 4 == 0 ? 10 : 5)), Offset(x, size.height), p);
      }
    }

    void marker(int? ms, Color c, String label) {
      if (ms == null) return;
      final x = size.width * ms / len;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), Paint()
        ..color = c
        ..strokeWidth = 2);
      final tp = TextPainter(text: TextSpan(text: label, style: TextStyle(color: c, fontSize: 10, fontWeight: FontWeight.w700)), textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, Offset(math.min(x + 3, size.width - tp.width), 1));
    }

    marker(dk.cueMs, const Color(0xFFFFFFFF), 'C');
    const hc = [Color(0xFFFF7A7A), Color(0xFFFFB86B), Color(0xFF7BE0A1), Color(0xFFB48CFF)];
    for (var i = 0; i < 4; i++) {
      marker(dk.hot[i], hc[i], '${i + 1}');
    }
    canvas.drawLine(Offset(playedX, 0), Offset(playedX, size.height), Paint()
      ..color = C.text
      ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_WavePainter o) => o.d != d || o.color != color || !identical(o.djd, djd);
}

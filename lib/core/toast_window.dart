import 'dart:async';
import 'dart:io';
import 'dart:ui' show Color;

import 'desktop_notify.dart';
import 'log.dart';

// Собственное окошко уведомления в правом нижнем углу экрана, как у Telegram: тёмная карточка, круглая аватарка,
// жирный ник, текст цветом акцента, крестик. Плавно проявляется и так же гаснет. Системные уведомления Windows оформляет
// сама система, и изменить их вид нельзя, поэтому рисуем своё окно через WPF в PowerShell. Окно не забирает фокус
// (игре и другим программам не мешает), сверху поверх остальных окон; клик по карточке открывает Cavey, крестик закрывает.

/// Что показать в карточке
class ToastSpec {
  /// Ник человека
  final String title;

  /// Что он сделал
  final String text;

  /// Файл с аватаркой; null — кружок с буквой
  final String? avatarPath;
  final String letter;

  /// Цвета: фон карточки, рамка, акцент (текст), основной текст, приглушённый (крестик), фон и буква кружка без аватарки
  final Color bg, line, accent, fg, muted, letterBg, letterInk;
  final int seconds;

  /// Кнопки «Принять» и «Отклонить» (приглашение в джем и запрос на вход)
  final bool buttons;
  const ToastSpec({
    required this.title,
    required this.text,
    required this.letter,
    required this.bg,
    required this.line,
    required this.accent,
    required this.fg,
    required this.muted,
    required this.letterBg,
    required this.letterInk,
    this.avatarPath,
    this.seconds = 8,
    this.buttons = false,
  });
}

/// Чем закончилось окошко уведомления
enum ToastResult {
  /// Окно не получилось показать
  failed,

  /// Само погасло или закрыто крестиком
  closed,

  /// Нажали на карточку: окно Cavey уже запрошено
  opened,

  /// «Принять»
  accepted,

  /// «Отклонить»
  declined,
}

String _hex(Color c) {
  int ch(double v) => (v * 255).round().clamp(0, 255).toInt();
  String two(int v) => v.toRadixString(16).padLeft(2, '0');
  return '#${two(ch(c.r))}${two(ch(c.g))}${two(ch(c.b))}';
}

/// Цвет без прозрачности: у карточки Windows все цвета сплошные. Раньше полупрозрачная светлая рамка теряла прозрачность
/// и превращалась в белую обводку, поэтому каждый цвет накладываем на фон карточки
String _solid(Color c, Color under) => _hex(Color.alphaBlend(c, under));

/// Строка в одинарных кавычках PowerShell
String _ps(String s) => "'${s.replaceAll("'", "''")}'";

/// Высота окна одного уведомления вместе с тенью: столько места занимает каждое в стопке
const toastSlotHeight = 132;

/// Скрипт PowerShell (WPF), который рисует карточку в стопке на месте [slot] (0 — самая нижняя)
String toastWindowScript(ToastSpec t, {required int slot, required String exe}) {
  // Фон карточки может быть полупрозрачным стеклом: кладём его на тёмную основу и дальше считаем все цвета по нему
  const under = Color(0xFF101014);
  final base = Color.alphaBlend(t.bg, under);
  final bg = _hex(base);
  final head = '''
\$title = ${_ps(t.title)}
\$text = ${_ps(t.text)}
\$letter = ${_ps(t.letter)}
\$avatar = ${_ps(t.avatarPath ?? '')}
\$exe = ${_ps(exe)}
\$bg = ${_ps(bg)}
\$line = ${_ps(_solid(t.line, base))}
\$accent = ${_ps(_solid(t.accent, base))}
\$fg = ${_ps(_solid(t.fg, base))}
\$muted = ${_ps(_solid(t.muted, base))}
\$avBg = ${_ps(_solid(t.letterBg, base))}
\$avInk = ${_ps(_solid(t.letterInk, base))}
\$btnBg = ${_ps(_solid(const Color(0x1FFFFFFF), base))}
\$buttons = ${t.buttons ? '\$true' : '\$false'}
\$slot = $slot
\$secs = ${t.seconds}
\$slotH = $toastSlotHeight
''';
  return head + _toastBody;
}

const _toastBody = r'''
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False" ResizeMode="NoResize"
        Width="384" Height="$slotH" UseLayoutRounding="True">
  <Border x:Name="Card" Margin="12" VerticalAlignment="Bottom" CornerRadius="10" Background="$bg" BorderBrush="$line" BorderThickness="1" Padding="14,12,8,12" Cursor="Hand">
    <Border.Effect>
      <DropShadowEffect BlurRadius="16" ShadowDepth="3" Opacity="0.55" Color="Black"/>
    </Border.Effect>
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="48"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="24"/>
      </Grid.ColumnDefinitions>
      <Grid Grid.Column="0" Width="48" Height="48" VerticalAlignment="Top">
        <Ellipse Fill="$avBg"/>
        <TextBlock x:Name="Letter" HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="20" FontWeight="Bold" Foreground="$avInk"/>
        <Ellipse x:Name="AvImg"/>
      </Grid>
      <StackPanel Grid.Column="1" Margin="14,0,4,0">
        <TextBlock x:Name="T" FontSize="15" FontWeight="Bold" Foreground="$fg" TextTrimming="CharacterEllipsis"/>
        <TextBlock x:Name="B" FontSize="14" Foreground="$accent" TextWrapping="Wrap" TextTrimming="CharacterEllipsis" MaxHeight="58" Margin="0,3,0,0"/>
        <StackPanel x:Name="Btns" Orientation="Horizontal" Margin="0,8,0,0" Visibility="Collapsed">
          <Border x:Name="Yes" CornerRadius="6" Background="$accent" Padding="14,5" Margin="0,0,8,0" Cursor="Hand">
            <TextBlock Text="&#x41F;&#x440;&#x438;&#x43D;&#x44F;&#x442;&#x44C;" FontSize="13" FontWeight="SemiBold" Foreground="$avInk"/>
          </Border>
          <Border x:Name="No" CornerRadius="6" Background="$btnBg" Padding="14,5" Cursor="Hand">
            <TextBlock Text="&#x41E;&#x442;&#x43A;&#x43B;&#x43E;&#x43D;&#x438;&#x442;&#x44C;" FontSize="13" Foreground="$fg"/>
          </Border>
        </StackPanel>
      </StackPanel>
      <TextBlock x:Name="X" Grid.Column="2" Text="&#x2715;" FontSize="14" Foreground="$muted" VerticalAlignment="Top" HorizontalAlignment="Right" Cursor="Hand"/>
    </Grid>
  </Border>
</Window>
"@
$w = [Windows.Markup.XamlReader]::Parse($xaml)
$w.FindName('T').Text = $title
$w.FindName('B').Text = $text
$w.FindName('Letter').Text = $letter
if ($buttons) { $w.FindName('Btns').Visibility = 'Visible' }
if ($avatar -ne '' -and (Test-Path -LiteralPath $avatar)) {
  try {
    $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
    $bmp.BeginInit()
    $bmp.CacheOption = 'OnLoad'
    $bmp.UriSource = New-Object System.Uri($avatar)
    $bmp.EndInit()
    $brush = New-Object System.Windows.Media.ImageBrush($bmp)
    $brush.Stretch = 'UniformToFill'
    $w.FindName('AvImg').Fill = $brush
  } catch { }
}
$wa = [System.Windows.SystemParameters]::WorkArea
$w.Top = $wa.Bottom - $slotH * ($slot + 1) + 4
$w.Left = $wa.Right - $w.Width + 4
$w.Opacity = 0
$closing = $false
$code = 0

# Плавное проявление и затухание; никакого выезда
function Fade($from, $to, $ms, $done) {
  $a = New-Object System.Windows.Media.Animation.DoubleAnimation($from, $to, [TimeSpan]::FromMilliseconds($ms))
  if ($done) { $a.Add_Completed($done) }
  $w.BeginAnimation([System.Windows.Window]::OpacityProperty, $a)
}

function Dismiss {
  if ($global:closing) { return }
  $global:closing = $true
  $timer.Stop()
  Fade $w.Opacity 0 320 { $w.Close() }
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds($secs)
$timer.Add_Tick({ Dismiss })

$card = $w.FindName('Card')
$card.Add_MouseEnter({ if (-not $global:closing) { $timer.Stop() } })
$card.Add_MouseLeave({ if (-not $global:closing) { $timer.Start() } })
$card.Add_MouseLeftButtonUp({
  try { Start-Process -FilePath $exe } catch { }
  $global:code = 12
  Dismiss
})
$w.FindName('X').Add_MouseLeftButtonUp({
  param($s, $e)
  $e.Handled = $true
  Dismiss
})
$w.FindName('Yes').Add_MouseLeftButtonUp({
  param($s, $e)
  $e.Handled = $true
  $global:code = 10
  Dismiss
})
$w.FindName('No').Add_MouseLeftButtonUp({
  param($s, $e)
  $e.Handled = $true
  $global:code = 11
  Dismiss
})
$w.Add_Closed({ [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() })

$w.Show()
Fade 0 1 260 $null
$timer.Start()
[System.Windows.Threading.Dispatcher]::Run()
exit $code
''';


/// Занятые места в стопке уведомлений (0 — нижнее)
final _slots = <int>{};

/// Показывает карточку. [ToastResult.failed] — окно не получилось (тогда вызывающий покажет обычное уведомление Windows)
Future<ToastResult> showToastWindow(ToastSpec spec) async {
  if (!Platform.isWindows) return ToastResult.failed;
  var slot = 0;
  while (_slots.contains(slot) && slot < 5) {
    slot++;
  }
  if (slot >= 5) slot = 4; // стопка полна — новое ложится поверх самого верхнего
  _slots.add(slot);
  try {
    final script = toastWindowScript(spec, slot: slot, exe: Platform.resolvedExecutable);
    final p = await Process.start('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-STA',
      '-WindowStyle',
      'Hidden',
      '-EncodedCommand',
      encodePowerShell(script),
    ]);
    // Вывод не нужен, но его надо вычитать, иначе процесс может зависнуть на заполненном буфере
    final err = StringBuffer();
    unawaited(p.stdout.drain<void>());
    p.stderr.transform(const SystemEncoding().decoder).listen(err.write);
    final code = await p.exitCode.timeout(Duration(seconds: spec.seconds + 30), onTimeout: () {
      p.kill();
      return -1;
    });
    // Что нажали, окно сообщает кодом выхода
    switch (code) {
      case 0:
        return ToastResult.closed;
      case 10:
        return ToastResult.accepted;
      case 11:
        return ToastResult.declined;
      case 12:
        return ToastResult.opened;
    }
    AppLog.warn('Окно уведомления закрылось с ошибкой ($code): ${err.toString().trim()}');
    return ToastResult.failed;
  } catch (e) {
    AppLog.warn('Окно уведомления не показалось', e);
    return ToastResult.failed;
  } finally {
    _slots.remove(slot);
  }
}

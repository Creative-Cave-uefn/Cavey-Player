import 'dart:async';
import 'dart:io';
import 'dart:ui' show Color;

import 'desktop_notify.dart';
import 'log.dart';

// Собственное окошко уведомления в правом нижнем углу экрана, как у Telegram: тёмная карточка, круглая аватарка,
// жирный ник, текст цветом акцента, крестик. Выезжает справа и уезжает обратно. Системные уведомления Windows оформляет
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
  });
}

String _hex(Color c) {
  int ch(double v) => (v * 255).round().clamp(0, 255).toInt();
  String two(int v) => v.toRadixString(16).padLeft(2, '0');
  return '#${two(ch(c.r))}${two(ch(c.g))}${two(ch(c.b))}';
}

/// Строка в одинарных кавычках PowerShell
String _ps(String s) => "'${s.replaceAll("'", "''")}'";

/// Высота окна одного уведомления вместе с тенью: столько места занимает каждое в стопке
const toastSlotHeight = 124;

/// Скрипт PowerShell (WPF), который рисует карточку в стопке на месте [slot] (0 — самая нижняя)
String toastWindowScript(ToastSpec t, {required int slot, required String exe}) {
  final head = '''
\$title = ${_ps(t.title)}
\$text = ${_ps(t.text)}
\$letter = ${_ps(t.letter)}
\$avatar = ${_ps(t.avatarPath ?? '')}
\$exe = ${_ps(exe)}
\$bg = ${_ps(_hex(t.bg))}
\$line = ${_ps(_hex(t.line))}
\$accent = ${_ps(_hex(t.accent))}
\$fg = ${_ps(_hex(t.fg))}
\$muted = ${_ps(_hex(t.muted))}
\$avBg = ${_ps(_hex(t.letterBg))}
\$avInk = ${_ps(_hex(t.letterInk))}
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
  <Border x:Name="Card" Margin="12" CornerRadius="10" Background="$bg" BorderBrush="$line" BorderThickness="1" Padding="14,12,8,12" Cursor="Hand">
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
$shownLeft = $wa.Right - $w.Width + 4
$hiddenLeft = $wa.Right + 12
$w.Left = $hiddenLeft
$closing = $false

function Slide($from, $to, $ms, $mode, $done) {
  $a = New-Object System.Windows.Media.Animation.DoubleAnimation($from, $to, [TimeSpan]::FromMilliseconds($ms))
  $e = New-Object System.Windows.Media.Animation.CubicEase
  $e.EasingMode = $mode
  $a.EasingFunction = $e
  if ($done) { $a.Add_Completed($done) }
  $w.BeginAnimation([System.Windows.Window]::LeftProperty, $a)
}

function Dismiss {
  if ($global:closing) { return }
  $global:closing = $true
  $timer.Stop()
  Slide $w.Left $hiddenLeft 260 'EaseIn' { $w.Close() }
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds($secs)
$timer.Add_Tick({ Dismiss })

$card = $w.FindName('Card')
$card.Add_MouseEnter({ if (-not $global:closing) { $timer.Stop() } })
$card.Add_MouseLeave({ if (-not $global:closing) { $timer.Start() } })
$card.Add_MouseLeftButtonUp({
  try { Start-Process -FilePath $exe } catch { }
  Dismiss
})
$w.FindName('X').Add_MouseLeftButtonUp({
  param($s, $e)
  $e.Handled = $true
  Dismiss
})
$w.Add_Closed({ [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() })

$w.Show()
Slide $hiddenLeft $shownLeft 320 'EaseOut' $null
$timer.Start()
[System.Windows.Threading.Dispatcher]::Run()
''';

/// Занятые места в стопке уведомлений (0 — нижнее)
final _slots = <int>{};

/// Показывает карточку. false — окно не получилось (тогда вызывающий покажет обычное уведомление Windows)
Future<bool> showToastWindow(ToastSpec spec) async {
  if (!Platform.isWindows) return false;
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
    if (code != 0) {
      AppLog.warn('Окно уведомления закрылось с ошибкой ($code): ${err.toString().trim()}');
      return false;
    }
    return true;
  } catch (e) {
    AppLog.warn('Окно уведомления не показалось', e);
    return false;
  } finally {
    _slots.remove(slot);
  }
}

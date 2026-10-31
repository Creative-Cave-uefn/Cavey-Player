// Ключи приложения Google. Удобнее всего задать их при сборке:
//   flutter build windows --dart-define=GOOGLE_CLIENT_ID=... --dart-define=GOOGLE_CLIENT_SECRET=...
// (сборка в GitHub Actions берёт их из секретов репозитория).
// Если ключи не заданы, приложение попросит ввести их при первом запуске.

const kGoogleClientId = String.fromEnvironment('GOOGLE_CLIENT_ID');
const kGoogleClientSecret = String.fromEnvironment('GOOGLE_CLIENT_SECRET');

// Версия приложения. Задаётся при сборке в GitHub Actions; в сборке для
// разработки её нет, и тогда автообновление выключено.
const kAppVersion = String.fromEnvironment('APP_VERSION');

// Где искать новые версии: отдельный публичный репозиторий для установщиков.
// Приватный репозиторий с кодом убран (В3): он каждые 4 часа заведомо отвечал 404.
const kReleasesRepos = ['Creative-Cave-uefn/cave-player-releases'];
const kReleasesRepo = 'Creative-Cave-uefn/cave-player-releases';

// Модуль скачки (YouTube, Soulseek, Bandcamp) — отдельная программа в приватном репозитории
// cave-downloader. Cavey скачивает её из релизов этого репозитория по ключу доступа,
// который вшивается в сборку плеера (секрет DOWNLOADER_READ_TOKEN в GitHub Actions): токен
// GitHub только на чтение содержимого этого одного репозитория. Без ключа (сборка для
// разработки) модуль берётся из CAVE_DOWNLOADER_EXE.
// Для своей копии репозитория: --dart-define=DOWNLOADER_REPO=владелец/репо
const kDownloaderRepo = String.fromEnvironment('DOWNLOADER_REPO', defaultValue: 'Creative-Cave-uefn/cave-downloader');
const kDownloaderToken = String.fromEnvironment('DOWNLOADER_TOKEN');

// Версия протокола плеер ↔ модуль. Плеер берёт только сборки модуля v<протокол>.x.y.
// Меняется вместе с protocolVersion в lib/src/ipc.dart репозитория cave-downloader.
const kDownloaderProtocol = 1;

// Папка общей библиотеки по умолчанию (необязательно): ID папки «Cave Player»
// на Диске. Если не задана, приложение само ищет доступную библиотеку.
const kDefaultLibraryId = String.fromEnvironment('CAVE_LIBRARY_ID');

// ID приложения в Discord Developer Portal для статуса «Слушает в Cave Player».
// Без него статус в Discord просто не показывается.
const kDiscordClientId = String.fromEnvironment('DISCORD_CLIENT_ID');

// Канал сборки: пусто для обычных версий из main, имя ветки — для тестовых сборок.
// Тестовая сборка обновляется до свежих сборок своей ветки, а когда ветку удалят — до обычных версий.
const kBuildChannel = String.fromEnvironment('BUILD_CHANNEL');

// Бета-сборка из ветки beta. Получать бета-версии или нет, человек выбирает в настройках,
// поэтому канал здесь не вшивается — флаг нужен только чтобы показать, что стоит бета.
const kBuildBeta = bool.fromEnvironment('BUILD_BETA');

// Ключ Last.fm для похожих треков в «Моей волне». Он только читает публичные данные,
// поэтому зашит прямо сюда; при сборке его можно заменить через --dart-define=LASTFM_API_KEY=...
const kLastFmKey = String.fromEnvironment('LASTFM_API_KEY', defaultValue: '0189af77b8463ffc2e477f0ab6211c3f');

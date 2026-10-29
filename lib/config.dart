// Ключи приложения Google. Удобнее всего задать их при сборке:
//   flutter build windows --dart-define=GOOGLE_CLIENT_ID=... --dart-define=GOOGLE_CLIENT_SECRET=...
// (сборка в GitHub Actions берёт их из секретов репозитория).
// Если ключи не заданы, приложение попросит ввести их при первом запуске.

const kGoogleClientId = String.fromEnvironment('GOOGLE_CLIENT_ID');
const kGoogleClientSecret = String.fromEnvironment('GOOGLE_CLIENT_SECRET');

// Версия приложения. Задаётся при сборке в GitHub Actions; в сборке для
// разработки её нет, и тогда автообновление выключено.
const kAppVersion = String.fromEnvironment('APP_VERSION');

// Где искать новые версии: отдельный публичный репозиторий для установщиков
// и сам репозиторий с кодом (если его сделать публичным). Берётся самая свежая.
const kReleasesRepos = ['Creative-Cave-uefn/cave-player-releases', 'Creative-Cave-uefn/Creative-Cave'];
const kReleasesRepo = 'Creative-Cave-uefn/cave-player-releases';

// Папка общей библиотеки по умолчанию (необязательно): ID папки «Cave Player»
// на Диске. Если не задана, приложение само ищет доступную библиотеку.
const kDefaultLibraryId = String.fromEnvironment('CAVE_LIBRARY_ID');

// ID приложения в Discord Developer Portal для статуса «Слушает в Cave Player».
// Без него статус в Discord просто не показывается.
const kDiscordClientId = String.fromEnvironment('DISCORD_CLIENT_ID');

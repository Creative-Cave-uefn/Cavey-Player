// Ключи приложения Google. Удобнее всего задать их при сборке:
//   flutter build windows --dart-define=GOOGLE_CLIENT_ID=... --dart-define=GOOGLE_CLIENT_SECRET=...
// (сборка в GitHub Actions берёт их из секретов репозитория).
// Если ключи не заданы, приложение попросит ввести их при первом запуске.

const kGoogleClientId = String.fromEnvironment('GOOGLE_CLIENT_ID');
const kGoogleClientSecret = String.fromEnvironment('GOOGLE_CLIENT_SECRET');

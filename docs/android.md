# Cavey Player для Android

Тот же плеер и тот же дизайн («стекло», размытая обложка, жёлтый акцент), только для телефона.
Точка входа — `lib/mobile_main.dart`, экраны — `lib/mobile/`. Ядро (библиотека, плеер, обложки, Диск) общее с Windows.

## Секреты репозитория (Settings → Secrets and variables → Actions)

| Секрет | Что это |
| --- | --- |
| `GOOGLE_WEB_CLIENT_ID` | OAuth-клиент типа **Web application** из того же проекта Google Cloud |
| `ANDROID_KEYSTORE_BASE64` | файл ключа подписи `cavey-release.jks` в base64 (одной строкой) |
| `ANDROID_KEYSTORE_PASSWORD` | пароль ключа (он же пароль хранилища) |
| `ANDROID_KEY_ALIAS` | необязательно, по умолчанию `cavey` |
| `RELEASES_TOKEN` | уже есть для Windows; им APK публикуется в `cave-player-releases` |

## Почему SHA-1 больше не меняется

Раньше APK подписывался отладочным ключом, который на каждом запуске CI создавался заново — отсюда новый SHA-1 в каждой сборке.
Теперь release-APK всегда подписывается одним ключом из секретов. SHA-1 этого ключа добавляется в Google Cloud **один раз**:

1. APIs & Services → Credentials → Create credentials → OAuth client ID → **Android**
2. Package name: `app.cavey.cave_player`
3. SHA-1: из лога сборки (шаг «Подпись APK») или из `keytool -list -v -keystore cavey-release.jks`

Ключ нельзя терять: с другим ключом Android не даст поставить обновление поверх. Храните `.jks` отдельно от репозитория.

## Обновления

Каждая сборка публикуется как пререлиз `android-v<версия>` в `cave-player-releases` (Windows-плеер эти теги не читает).
Приложение само проверяет релизы, показывает баннер на главной и во вкладке «Профиль», скачивает APK и открывает системный установщик.
При первом обновлении Android попросит разрешить установку из Cavey.

Старые APK с отладочной подписью нужно один раз удалить вручную — подпись другая.

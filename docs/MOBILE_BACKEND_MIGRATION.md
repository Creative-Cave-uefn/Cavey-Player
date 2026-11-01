# Cavey Mobile: Google Drive остаётся, собственный сервер не нужен

## Приоритет: доступ только друзьям без повторного логина каждую неделю

Отдельные аккаунты Cavey не нужны: Google OAuth остаётся способом получить разрешение на закрытый Google Drive, а Drive ACL — реальным механизмом защиты библиотеки. Одна общая папка с library.json и аудиофайлами доступна только явно приглашённым Google-аккаунтам.

**Причина 7-дневного входа:** Google Cloud OAuth External + статус Testing выдаёт refresh token для Drive с истечением через семь дней. В lib/core/auth.dart уже есть обновление access token через refresh token: пока приложение в Testing, исправить срок жизни программно нельзя. Владелец Google Cloud проекта может проверить Google Auth Platform → Audience → Publish app / In production. После изменения пользователю может понадобиться однократная повторная авторизация. Позже токен всё ещё может быть отозван или истечь по другим причинам.

**Приватность в Production:** список Test users больше не является белым списком входа. У пользователя без доступа к папкам Google Drive может запуститься клиент Cavey, но у него не будет разрешения читать закрытую библиотеку или музыку. Чтобы защитить текущую библиотеку, Google Drive Sharing должен быть Restricted и выдавать доступ строго по адресам друзей. Не включать Anyone with the link, не делиться общими OAuth/refresh-токенами и не помещать их в мобильные сборки.

**Ограничения:** текущий полный https://www.googleapis.com/auth/drive — restricted OAuth scope. Google может потребовать верификацию для публичного приложения, даже если оно используется небольшой группой. Неверифицированное приложение может показать предупреждение и иметь лимит новых пользователей. Статус In production не гарантирует одобрение использования Drive API. Перед релизом проверить policy и необходимость verification; более узкий drive.file с Picker исследовать отдельно, не ломая доступ к текущим общим папкам.

**Порядок работ:** (1) проверить приватность всех hub/source Drive-папок и список участников; (2) проверить Publishing status и возможность Production для текущего OAuth проекта; (3) проверить, что после публикации refresh token автоматически обновляется без недельного входа; (4) делать Android/iOS с платформенными OAuth client IDs из того же Google Cloud проекта; (5) тестировать на двух друзьях и одном неавторизованном аккаунте, что у последнего нет доступа к библиотеке.

Официальные источники:
- https://support.google.com/cloud/answer/15549945
- https://developers.google.com/identity/protocols/oauth2
- https://developers.google.com/workspace/drive/api/guides/api-specific-auth


**Решение (01.11.2026):** музыку, обложки, library.json, плейлисты и лайки оставляем на Google Drive. Отменяем первоначальный план PostgreSQL + S3 + Cavey API и экспериментальный HTTP-клиент для несуществующего сервера. Рабочий main не меняется.

## 1. Принципиальное ограничение

Google Drive API не позволяет приватному файлу открыться только потому, что пользователь вошёл в Cavey. Для приватного Drive нужен OAuth access token с разрешённым Google Drive scope (либо отдельная доверенная серверная интеграция, которой разрешён доступ). Свои логин/пароль Cavey не заменяют это разрешение.

Не путать:
- **Вход в Cavey**: опознать человека, его профиль и настройки. Можно использовать Google, Firebase Auth (email/password, email-link) или иной управляемый identity service.
- **Разрешение на Drive**: подтвердить конкретному Google-аккаунту право читать/записывать закрытые файлы; для прямого доступа с устройства нужен Google OAuth, даже при отдельном логине Cavey.

**Рекомендация для первых версий Android/iOS:** без собственного backend, оставить Google Sign-In с разрешением Drive на каждом устройстве. Не просить пользователя вручную настраивать OAuth Client ID. Свой логин Cavey можно добавить позже без переноса музыки.

Если требуется **совсем без Google OAuth для всех слушателей**, при этом музыка остаётся приватной, без доверенного backend/proxy (например, управляемых Cloud Functions/Cloud Run) это технически не реализуется безопасно. Нельзя встраивать общий service-account private key или чужой refresh token в APK/EXE.

## 2. Фактическая архитектура существующего плеера

- lib/core/auth.dart: Windows OAuth PKCE через loopback 127.0.0.1, несколько Google-аккаунтов. Текущие scopes: openid, email, profile и полный https://www.googleapis.com/auth/drive.
- accounts.json: локально email/name/access token/refresh token/expiry; **никакого сервера пользователей Cavey сейчас нет**.
- settings.json: primaryEmail, hubId, hubEmail, libFileId, sourceAccess, пользовательские настройки. Кроме него есть library_cache.json, pending_ops.json и резервные .bak.
- lib/core/drive.dart: REST Google Drive (в том числе HTTP range, uploads и обновление audio без смены ID).
- lib/core/library.dart + lib/core/models.dart: на Google Drive хранится **общий library.json v1**, поля sources, tracks, playlists, likes, members, edits, hidden, merged, deleted, deletedBy, deletedName. Track ID — Google Drive file ID. Плейлисты/лайки/слияния/ручные изменения ссылаются именно на эти ID.
- Доступ к коллективной библиотеке задают разрешения Google Drive на папки; email в members — это отображение/исторический идентификатор, а не независимая система прав.
- lib/main.dart, single-instance, window_manager, tray и Windows downloader надо отделить от мобильного runtime.

### Схема без сервера

    Windows Cavey       Android Cavey       iOS Cavey
          |                  |                 |
       OAuth client      OAuth client      OAuth client
          |                  |                 |
          +------------------+-----------------+
                             |
                     Google Drive API
                             |
                   Existing library.json
                   Audio, covers, Drive IDs

**Музыка никуда не копируется.** Мобильный клиент пользуется теми же папками и данными, что Windows.

## 3. Как сберечь аккаунты уже существующих пользователей

1. Не удалять и не перезаписывать прежние accounts.json, settings.json, pending_ops.json, library_cache.json; оставить текущий Windows login работающим.
2. Использовать один Google Cloud OAuth consent project для Cavey, создать **отдельные OAuth client IDs** для Desktop, Android и iOS. Под Android нужны правильные package name / signing certificate SHA, под iOS bundle ID и callback; на новых устройствах вход под тем же Google-аккаунтом. Пользователи не должны вводить client secret вручную.
3. Не переносить Google refresh/access tokens между устройствами и не публиковать их в облачной библиотеке. Каждый девайс получает собственное разрешение через Google; предпочтительно OS secure storage (Android Keystore, iOS Keychain; на Windows DPAPI/Credential Manager). Старый Windows accounts.json поддерживать совместимо, пока не сделана безопасная миграция хранения токенов.
4. Сохранять исходные Google Drive ID треков без namespace-замен, а также playlist.items, likes, edits, merged, hidden, deleted*, members. Тот же аккаунт получает те же права к тому же Drive.
5. В мобильном UX сначала предложить «Подключить существующую библиотеку» через ссылку/ID папки. Автообнаружение library.json реализовать отдельно и тестировать на нескольких библиотеках: не выбирать пустую.
6. При нескольких подключённых Google-аккаунтах сохранить сопоставление sourceAccess и доступ к папкам разных владельцев. Нет доступа на телефоне — показать запрос подключения подходящего Google-аккаунта, а не удалять из library.json отсутствующие треки.
7. Существующие приглашения и права «Делиться» остаются стандартными ACL Google Drive. Нельзя выдавать доступ к файлу по одному адресу email из списка members.
8. Создать резервную копию library.json до мобильной беты; отключить на мобильном клиенте удаление недоступных треков как «пропавших» до подтверждённого сканирования и разрешений.
9. Новый OAuth client ID может потребовать повторное разрешение Google на телефоне. **Это не новый аккаунт Cavey** и не миграция данных. Оригиналы Drive не трогать.

## 4. Если хочется именно собственный логин, но без собственного сервера

Можно подключить управляемый Firebase Authentication для email/password либо email-link. Это не наш VPS; аккаунты хранит поставщик. Но здесь **две независимые сессии**:

- Cavey login через Firebase: личность/профиль приложения.
- Google OAuth для Drive: доступ к папкам с музыкой, сохранение и чтение library.json.

В таком режиме можно иметь стабильный Firebase user UID и явно привязать несколько Google-аккаунтов владельцев папок. **Нельзя автоматически привязывать существующие библиотеки по совпадению email** без разрешения владельца.

Если хочется вообще не показывать вход Google для слушателей и при этом читать приватные Drive-папки: потребуется управляемая серверная функция/proxy с отдельной моделью прав и secure credential management. Даже у Firebase это будет backend, хотя сервер самостоятельно арендовать не нужно. Без такого посредника безопасной схемы нет.

## 5. Ограничения Google Drive scope

Сейчас приложение запрашивает полный Drive scope. Согласно Google он classified **restricted** и может требовать OAuth verification для публичного приложения. Более узкий drive.file позволяет работать с выбранными пользователем файлами через Picker, но **нельзя слепо заменить им текущий scope**: Cavey сканирует чужие/старые папки и ищет общий library.json. Точный доступ и UX надо проверить тестовой библиотекой до любых изменений разрешений. Не считать одно только имя папки достаточным доказательством доступа.

Для первой мобильной версии сохранить совместимые scopes и оценить подтверждение приложения в Google Cloud. Проверить ограничения применимости Drive API и пользовательской политики до публичного масштабирования музыкального сервиса.

## 6. План реализации без собственного сервера

| Этап | Задача | Критерий |
| --- | --- | --- |
| M0 | Закрепить Drive-first план, удалить неиспользуемый клиент выдуманного Cavey API | Main без изменений |
| M1 | Разделить auth backend по платформам: Windows PKCE, Android/iOS native Sign-In + запрашивание Drive scopes | Каждое устройство получает разрешённый Drive token |
| M2 | Переход к безопасному локальному хранилищу credentials, миграция без сброса accounts.json | Старый Windows-вход работает, токены не логируются |
| M3 | Общий слой Drive library, Range streaming и pending operations для мобильного клиента | Тот же library.json + IDs на трёх платформах |
| M4 | Mobile entrypoint и адаптивный UI, убрать desktop-only зависимости из мобильной сборки | Android и iOS собираются |
| M5 | Фоновое воспроизведение, lock screen/media controls, offline cache, надёжный sync | Play/pause/seek работают и после сворачивания |
| M6 | Бета на тестовом Drive, многопользовательские права, несколько аккаунтов, конфликтные изменения | Нет потерь плейлистов, лайков, файлов |

## 7. Обязательные проверки

- Старый Windows и Android/iOS открывают один и тот же Drive file ID трека и один library.json.
- Новая установка по тому же Google-аккаунту видит прежние плейлисты/лайки без переноса аудио.
- Изменение на мобильном устройстве появляется на Windows без перезаписи конкурентных правок.
- Нет Drive разрешений — понятная ошибка, но **никаких автоматических удалений из общей библиотеки**.
- Участник с несколькими Google-аккаунтами подключает нужные sourceAccess без перепривязки ID треков.
- Offline pending_ops переживают перезапуск и потом корректно применяются.
- Выход на одном устройстве не удаляет саму библиотеку или токены других устройств.

## 8. Официальная документация

- https://developers.google.com/identity/protocols/oauth2
- https://developers.google.com/workspace/drive/api/guides/api-specific-auth
- https://firebase.google.com/docs/auth/flutter/start
- https://developers.google.com/workspace/workspace-api-user-data-developer-policy

**Статус:** этот документ — пересмотренный план. Мобильная авторизация и Android/iOS приложения ещё не реализованы. Этот коммит не работает с чьими-либо настоящими токенами или Drive-файлами.

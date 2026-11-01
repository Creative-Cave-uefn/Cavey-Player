# Cavey Mobile — миграция с Google Drive на собственный API

**Статус:** архитектурный план + начальный Dart-клиент собственного API. Никаких боевых данных не перенесено. Desktop `main` и существующие пользователи продолжают работать через Google Drive.

## 1. Что реально хранится сейчас

- `lib/core/auth.dart`: Google OAuth (PKCE + loopback localhost), несколько аккаунтов, локальный `accounts.json`; ключи `email`, `name`, `refreshToken`, `accessToken`, `expiry`. OAuth запрашивает `openid`, `email`, `profile`, полный Drive scope. Это **локальные учётные данные**, а не база пользователей Cavey.
- `lib/core/store.dart`: `settings.json` содержит `primaryEmail`, `hubId`, `hubEmail`, `libFileId`, `sourceAccess` и локальные предпочтения. Есть `library_cache.json`, `pending_ops.json` и `.bak`.
- `lib/core/models.dart`: общая библиотека v1 в `library.json`. Ключи `sources`, `tracks`, `playlists`, `likes`, `members`, `edits`, `hidden`, `merged`, `deleted`, `deletedBy`, `deletedName`. Важнейший факт: ID треков сейчас равен Google Drive file ID; элементы плейлистов, лайки, объединения и ручные правки ссылаются именно на него.
- `lib/core/library.dart`: чтение и запись `library.json`, очередь операций, конфликты и сканирование Drive. Доступ к музыке зависит от владельцев Google-папок и разрешений на совместные файлы.
- `lib/core/drive.dart`: Drive API для файлов, списка папок, media range, загрузки, замены, прав и удаления.
- `lib/main.dart`: desktop-специфичные запуск единственного экземпляра, окно и системный трей требуют отдельных мобильных точек входа.

## 2. Целевая архитектура

```
Flutter Windows / Android / iOS
    |
    | HTTPS + Cavey session
    v
Cavey API (свой сервер)
    |-- auth/session (Google OIDC вначале, в будущем passkey/email)
    |-- users + membership + invitations
    |-- libraries + versioned operations
    |-- tracks + metadata + playlists + likes
    |-- media streaming HTTP Range + upload sessions
    |-- migration jobs + audit
    |
    +-- PostgreSQL (пользователи, роли, каталог, операции)
    +-- S3-совместимое object storage (аудио, обложки, копии)
    +-- очередь фоновых задач (импорт/проверка контрольных сумм)
```

Разворачивать сервер отдельно от Flutter. Первый практичный выбор: FastAPI или NestJS + PostgreSQL + S3-compatible storage + HTTPS reverse proxy. Провайдер и стоимость хранилища выбираются отдельно; бесплатно хранить произвольные музыкальные библиотеки нельзя. На старте API должен хранить сам звук, а не выдавать ссылки на Google Drive от имени старого пользователя. Прямые URL Google и Drive file ID не должны быть публичными секретами или правами доступа.

**Разделить Google Login и Google Drive:** на первом этапе Google остаётся способом доказать личность (identity provider), но звук и библиотека переходят в Cavey API. Полностью отказаться от Google Login можно позже, когда пользователи привяжут passkey или альтернативную почту. Удалять Google авторизацию до завершения связки аккаунтов нельзя.

## 3. Как сохранить аккаунты старых пользователей

1. **Не удалять и не обнулять локальные файлы** `accounts.json`, `settings.json`, `library_cache.json`, `pending_ops.json`. Старую авторизацию и Google Drive оставить рабочими на Windows до завершения переноса.
2. В собственном API создать `users(id UUID, created_at)` и `identities(user_id, provider, provider_subject UNIQUE, verified_email, linked_at)`. После Sign in with Google сервер проверяет подпись ID token, `iss`, `aud`, `exp` и использует `sub` как неизменный ключ Google-идентичности. **Email не является безопасным первичным ключом**: он может измениться. Текущий `members`/`likes` по email — только данные старого формата.
3. Для мобильного входа использовать Android/iOS Google Sign-In с ID token для серверного OAuth Client ID. Для Windows — OIDC + PKCE; при первой активации нового сервера может понадобиться повторный вход в Google. Пользователь увидит прежнюю библиотеку благодаря проверенному `sub` и приглашению/подтверждённой привязке, а не переносу старого Google refresh token.
4. **Никогда не пересылать содержимое `accounts.json` и Google refresh/access tokens** на новый сервер и не вставлять их в APK. Новые Cavey session/refresh tokens хранить в OS secure storage (iOS Keychain, Android Keystore, Windows защищённое хранилище). Старый `accounts.json` должен быть исключён из серверных логов/бэкапов.
5. Старое отображаемое имя, email, роли и настройки импортировать как legacy-метаданные. Привязка `legacy_email -> user_id` допустима только после проверенного входа и подтверждения доступа к конкретной библиотеке. Не выдавать доступ к библиотеке по одному введённому email или Drive ID.
6. Для общих библиотек владелец запускает миграцию, остальные участники получают invite/claim. Даже если их `members` уже есть в `library.json`, они должны подтвердить новую идентичность. Старые права Google на чужие папки не означают автоматических прав на новый API без авторизованного переноса.
7. Не требовать создавать нового Google-аккаунта: человек входит тем же Google-аккаунтом; в Cavey на сервере появляется постоянный `user_id`, связанный с Google `sub`. Поддержать несколько старых Google-аккаунтов одного человека и явную привязку дополнительной идентичности без автоматического объединения по email.
8. Если прежний OAuth grant отозван, запрашивать обычный повторный Google Sign-In. Это не должно удалять профиль или прежние плейлисты.

## 4. Безопасная миграция музыки и библиотек

Сохранять идентификаторы из `library.json` **без изменения**: для старых треков оставлять исходный строковый Drive ID как внутренний legacy track ID (при желании хранить отдельно `legacy_drive_file_id`); новые треки получают namespace/UUID. Никаких массовых замен ID в `tracks`, `playlist.items`, `likes`, `edits`, `merged`, `hidden`.

### Этапы переноса одной библиотеки

1. Предварительная проверка: есть ли права у владельца на `library.json`, какие `sources` принадлежат другим людям, сколько файлов и байт, хватит ли места и есть ли несохранённые `pending_ops.json`.
2. Резервная копия raw `library.json` v1 и JSON-export профиля/настроек **без OAuth-токенов**. Бэкап на сервере должен быть с версией, контрольной суммой, временем и владельцем.
3. Создать `libraries(id UUID, legacy_hub_id, legacy_lib_file_id, revision, owner_user_id, migration_state)` и import job. Повторный запуск по `migration_id` должен быть идемпотентным.
4. Клиент с уже разрешённым доступом к Drive или OAuth consent на ограниченное чтение экспортирует файлы через HTTPS в Cavey Storage. Серверу не выдавать бессрочный Google refresh token. Для каждой записи сохранить `legacy_source_id`, `legacy_file_id`, `storage_key`, `size`, `sha256`/`md5`, MIME и upload state.
5. Сверить число треков, контрольные суммы, повторные записи, плейлисты (порядок и ссылки), лайки, edits, hidden, merged, deleted. Не удалять оригиналы Google Drive даже после успешной проверки.
6. При совместных библиотеках импортировать только файлы, доступные и разрешённые конкретным владельцем/участником. Недоступные файлы отмечать как `needs_owner_consent`, не подменять похожими песнями.
7. На время окончательного переключения — краткий режим read-only для конкретной библиотеки: выгрузить оставшиеся `pending_ops`, применить операции в сервере, проверить итоговый hash/revision, после чего **атомарно** переключить `library.backend = cavey`. Не пытаться держать две независимые writable-копии без стратегии конфликтов.
8. Период отката: Drive сохраняется как read-only backup и прежние данные остаются доступными. Если откат требует восстановить изменения, нужен отдельный журнал операций для обратного экспорта; не обещать автоматический безопасный rollback после новых записей только на сервере.

## 5. Минимальный API v1 (контракт начального клиента)

| Метод | Путь | Назначение |
|---|---|---|
| `POST` | `/v1/auth/google` | ID token -> Cavey tokens + user_id; сервер валидирует Google claims |
| `GET` | `/v1/me` | Профиль по Cavey session |
| `GET` | `/v1/libraries/{id}/snapshot` | `{revision, library}`; `library` сохраняет формат v1 |
| `POST` | `/v1/libraries/{id}/operations` | `{base_revision, mutation_id, operations}` -> новый snapshot или HTTP 409 |
| `GET` | `/v1/libraries/{id}/tracks/{id}/stream` | авторизованное аудио, HTTP 206 + Range/ETag |
| `POST` | `/v1/libraries/{id}/uploads` | сессия безопасной загрузки/восстановление передачи |
| `POST` | `/v1/migrations/google-drive` | старт импорта после разрешения владельца и preflight |
| `GET` | `/v1/migrations/{id}` | состояние, байты, ошибки и список недоступных файлов |
| `POST` | `/v1/libraries/{id}/invites` | приглашение с серверной проверкой прав |

Серверные операции атомарные: `revision` и `mutation_id` обязательны, 409 не должен терять локальные правки. Проверять библиотечный ACL при каждом GET/PUT, не принимать самодекларированный email в качестве разрешения. Rate limit, аудит доступа, бэкапы базы, ключи encryption-at-rest, signed upload URLs с коротким TTL, запрет чужих файлов и path traversal.

В этой ветке добавлен `lib/core/backend/cavey_api_client.dart` с первыми четырьмя методами и тестами. Он **пока не подключён** к UI и не вызывает сетевые запросы при обычном запуске. Это сознательно безопасно до развёртывания реального сервера и миграции.

## 6. Порядок реализации (разделить на проверяемые PR/коммиты)

- [x] **M0. Безопасная отдельная ветка, инвентаризация данных, план, типизированный API-клиент и мок-тесты.**
- [ ] **M1. Сервер v1 и инфраструктура:** репозиторий серверной части, schema migrations PostgreSQL, объектное хранилище, OAuth OIDC verification по JWKS, Cavey refresh/session rotation и бэкапы. Деплой staging, мониторинг и публичный домен. Ни один токен из клиента не считать верифицированной личностью без серверной проверки.
- [ ] **M2. Repository-слой Flutter:** отделить `LibraryController` от `DriveApi` через адаптеры `LegacyDriveRepository` и `CaveyRepository`; отдельно сделать `MediaRepository` с HTTP Range; операции `LibraryData.apply` не переписывать. Конфигурация по библиотеке, флаг выключен по умолчанию, тесты legacy режима.
- [ ] **M3. Параллельная авторизация:** Android/iOS Google Sign-In, новая серверная сессия и secure storage, flow привязки нескольких аккаунтов, восстановление профиля на втором устройстве. Desktop Google Drive продолжает работать.
- [ ] **M4. Импорт библиотеки и файлов:** dry-run, согласие владельца, snapshot/import jobs, хеши, прогресс/повтор, ACL и shared libraries, сверка всего `library.json` и ссылок на треки. Никакого удаления с Drive.
- [ ] **M5. Controlled cutover:** финальная синхронизация и read-only freeze, серверная запись операций, media streaming + uploads, rollback plan. Сначала внутренние тестовые аккаунты, затем пилот.
- [ ] **M6. Mobile runtime:** отдельный `main_mobile.dart`, мобильный вход/сессия/восстановление, responsive navigation, проигрывание в фоне, MediaSession/lock screen, offline cache, разрешения, тесты Android и iOS. Desktop-only `window_manager`, `single_instance`, `WinProc` изолировать от mobile.
- [ ] **M7. Постепенный rollout:** гибрид на Windows, ограниченный бета-доступ Android, затем iOS; мониторить падения, импорт, storage и активных пользователей. Только после успешного периода переноса отключать Drive как основной backend. Альтернативный вход (passkey/email) привязать до возможного отказа от Google Sign-In.

## 7. Приёмка (блокирующие критерии)

- Старый установленный Windows-клиент после публикации ветки продолжает открывать прежний Drive без повторного создания библиотеки.
- На тестовом `library.json` v1 сохраняются все ключи, треки, `playlist.items` в прежнем порядке, `likes`, `edits`, `hidden`, `merged`, `deleted*`, имена участников.
- Один и тот же Google `sub` на Windows/Android/iOS получает один Cavey `user_id`, а чужой `sub` никогда не получает доступа без invite.
- Потеря Google access/refresh token не удаляет Cavey профиль; повторный Sign-In привязывает существующую личность.
- Повтор импорта ничего не дублирует; незавершённый импорт безопасно продолжается; недоступные владельческие треки не выдаются за успешно перенесённые.
- Безопасная конкуренция: два устройства не могут незаметно перезаписать операции друг друга; 409 -> refetch + reapply pending ops.
- Audio streaming работает с HTTP 206 Range, seek и кешем на Android/iOS и Windows.
- Есть экспорт и восстановление из бэкапа, аудит миграции и задокументированная политика хранения/удаления.

## 8. Что нужно решить до M1

1. Где будет размещён сервер (свой VPS / managed cloud), домен и бюджет на объём аудио.
2. Сколько людей и треков сейчас, общий объём хранилища, приватные или совместные библиотеки.
3. Нужна ли возможность входа **без Google** сразу или достаточно оставить Google Sign-In только как поставщика личности.
4. Кто является собственником загруженных аудиозаписей и на каких условиях сервер вправе их хранить и отдавать.

**Запрет для rollout:** не удалять файлы Drive, не отзывать существующие scopes/tokens и не заменять Google Drive endpoint на несуществующий server URL до прохождения M1–M5.

/**
 * Cave Player — брокер загрузки (Google Apps Script Web App).
 *
 * Зачем: файл, загруженный в общую папку, принадлежит тому, кто его создал, и занимает ЕГО место на Диске.
 * Брокер открывает сессии загрузки от имени владельца библиотеки (аккаунт с подпиской), поэтому все новые
 * файлы занимают место владельца, а не друзей. Сами байты друг отправляет напрямую в Google по адресу сессии,
 * через брокер они не проходят.
 *
 * Настройка: tools/broker/README.md
 *
 * Свойства скрипта (Project Settings → Script properties):
 *   CLIENT_ID   — OAuth Client ID приложения Cave Player (тот же, что в приложении)
 *   ROOT_ID     — ID папки «Cave Player» (корень библиотеки)
 *   OWNER_EMAIL — (необязательно) почта владельца; если не задана, берётся Session.getEffectiveUser()
 *   MAX_BYTES   — (необязательно) предел размера файла, по умолчанию 500 МБ
 *   LOG_SHEET   — (необязательно) ID таблицы для журнала загрузок
 *
 * Включите в проекте дополнительный сервис «Drive API» (v3): Services → Drive API.
 */

var DEFAULT_MAX_BYTES = 500 * 1024 * 1024;
var MIN_FREE_BYTES = 200 * 1024 * 1024; // запас, который оставляем на диске владельца
var RATE_LIMIT = 300;                   // запросов begin на человека в час (альбом = десятки файлов и обложек)
var ALLOWED_EXT = {
  mp3: 1, flac: 1, m4a: 1, aac: 1, ogg: 1, opus: 1, wav: 1, wma: 1, aiff: 1, aif: 1, alac: 1, ape: 1,
  jpg: 1, jpeg: 1, png: 1, webp: 1, gif: 1, json: 1
};
var API_VERSION = 3;
var ADOPT_BATCH = 20; // файлов за один запрос adopt

function props_() { return PropertiesService.getScriptProperties(); }
function prop_(k, d) { var v = props_().getProperty(k); return v ? v : d; }

function json_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}
function fail_(code, message) { return json_({ ok: false, code: code, error: message }); }

function doGet() {
  return json_({ ok: true, service: 'cave-broker', api: API_VERSION });
}

function doPost(e) {
  var req;
  try {
    req = JSON.parse(e.postData.contents);
  } catch (err) {
    return fail_('bad_request', 'Неверный запрос');
  }
  try {
    var who = authorize_(req.token);
    if (!who.ok) return fail_(who.code, who.error);
    switch (req.action) {
      case 'begin': return begin_(req, who.email);
      case 'delete': return delete_(req, who.email);
      case 'adopt': return adopt_(req, who.email);
      case 'quota': return quota_(who.email);
      case 'ping': return json_({ ok: true, api: API_VERSION, email: who.email, owner: ownerEmail_() });
      default: return fail_('bad_request', 'Неизвестное действие');
    }
  } catch (err) {
    log_('error', '', String(err && err.stack ? err.stack : err));
    return fail_('internal', 'Внутренняя ошибка брокера: ' + err);
  }
}

// ───────────────────────── Проверка человека ─────────────────────────

/** Проверяет access-токен пользователя: он должен быть выдан именно приложению Cave Player. */
function authorize_(token) {
  if (!token) return { ok: false, code: 'no_token', error: 'Нет токена' };
  var cache = CacheService.getScriptCache();
  var key = 'tok_' + Utilities.base64EncodeWebSafe(Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, token));
  var hit = cache.get(key);
  if (hit) {
    var h = JSON.parse(hit);
    return { ok: true, email: h.email };
  }
  var res = UrlFetchApp.fetch('https://oauth2.googleapis.com/tokeninfo?access_token=' + encodeURIComponent(token), {
    muteHttpExceptions: true
  });
  if (res.getResponseCode() !== 200) return { ok: false, code: 'bad_token', error: 'Токен недействителен' };
  var info = JSON.parse(res.getContentText());
  var clientId = prop_('CLIENT_ID', '');
  if (!clientId) return { ok: false, code: 'not_configured', error: 'В брокере не задан CLIENT_ID' };
  if (info.aud !== clientId && info.azp !== clientId) {
    return { ok: false, code: 'bad_client', error: 'Токен выдан не приложению Cave Player' };
  }
  var email = String(info.email || '').toLowerCase();
  if (!email || String(info.email_verified) === 'false') return { ok: false, code: 'bad_token', error: 'Нет подтверждённой почты' };
  if (!isMember_(email)) return { ok: false, code: 'not_member', error: 'Вы не участник библиотеки Cave Player' };
  var ttl = Math.max(30, Math.min(600, parseInt(info.expires_in || '60', 10) - 30));
  cache.put(key, JSON.stringify({ email: email }), ttl);
  return { ok: true, email: email };
}

function ownerEmail_() {
  var o = prop_('OWNER_EMAIL', '');
  return (o || Session.getEffectiveUser().getEmail()).toLowerCase();
}

/** Участник = владелец или тот, кому открыт доступ к корневой папке библиотеки. */
function isMember_(email) {
  if (email === ownerEmail_()) return true;
  var cache = CacheService.getScriptCache();
  var key = 'mem_' + email;
  var c = cache.get(key);
  if (c !== null) return c === '1';
  var ok = false;
  var root = DriveApp.getFolderById(prop_('ROOT_ID', ''));
  var lists = [root.getEditors(), root.getViewers()];
  for (var i = 0; i < lists.length && !ok; i++) {
    for (var j = 0; j < lists[i].length; j++) {
      if (String(lists[i][j].getEmail()).toLowerCase() === email) { ok = true; break; }
    }
  }
  cache.put(key, ok ? '1' : '0', ok ? 600 : 60);
  return ok;
}

function rateLimit_(email) {
  var cache = CacheService.getScriptCache();
  var key = 'rl_' + email;
  var n = parseInt(cache.get(key) || '0', 10);
  if (n >= RATE_LIMIT) return false;
  cache.put(key, String(n + 1), 3600);
  return true;
}

// ───────────────────────── Дерево папок ─────────────────────────

/** Лежит ли папка/файл внутри библиотеки (поднимаемся по родителям до корня). Результат кэшируем. */
function insideRoot_(id) {
  var rootId = prop_('ROOT_ID', '');
  if (!id) return false;
  if (id === rootId) return true;
  var cache = CacheService.getScriptCache();
  var key = 'in_' + id;
  var c = cache.get(key);
  if (c !== null) return c === '1';
  var cur = id, ok = false;
  for (var depth = 0; depth < 12; depth++) {
    var f;
    try {
      f = Drive.Files.get(cur, { fields: 'id,parents', supportsAllDrives: true });
    } catch (err) {
      break;
    }
    var parents = f.parents || [];
    if (!parents.length) break;
    if (parents.indexOf(rootId) >= 0) { ok = true; break; }
    cur = parents[0];
  }
  cache.put(key, ok ? '1' : '0', ok ? 3600 : 120);
  return ok;
}

// ───────────────────────── Действия ─────────────────────────

function freeBytes_() {
  var about = Drive.About.get({ fields: 'storageQuota' });
  var q = about.storageQuota || {};
  if (!q.limit) return null; // безлимит
  return parseInt(q.limit, 10) - parseInt(q.usage || '0', 10);
}

function quota_(email) {
  var q = Drive.About.get({ fields: 'storageQuota' }).storageQuota || {};
  return json_({
    ok: true,
    limit: q.limit ? parseInt(q.limit, 10) : null,
    usage: q.usage ? parseInt(q.usage, 10) : 0,
    free: freeBytes_()
  });
}

/**
 * begin: { token, action:'begin', name, size, mime, parentId, source? }
 * Открывает resumable-сессию создания НОВОГО файла от имени владельца. Замена содержимого уже существующего файла
 * (смена обложки) брокеру не нужна: место за него платит владелец файла, а участники — «Редакторы».
 */
function begin_(req, email) {
  if (!rateLimit_(email)) return fail_('rate_limited', 'Слишком много загрузок подряд, подождите немного');
  var name = String(req.name || '').trim();
  var size = parseInt(req.size, 10);
  var parentId = String(req.parentId || '');
  if (!name || !(size >= 0)) return fail_('bad_request', 'Не указано имя или размер файла');
  if (name.length > 255 || /[\\\/\u0000-\u001f]/.test(name)) return fail_('bad_name', 'Недопустимое имя файла');
  var ext = (name.split('.').pop() || '').toLowerCase();
  if (!ALLOWED_EXT[ext]) return fail_('bad_type', 'Этот тип файлов нельзя загружать в библиотеку');
  var max = parseInt(prop_('MAX_BYTES', String(DEFAULT_MAX_BYTES)), 10);
  if (size > max) return fail_('too_big', 'Файл слишком большой (предел ' + Math.round(max / 1048576) + ' МБ)');
  if (!insideRoot_(parentId)) return fail_('bad_parent', 'Папка вне библиотеки Cave Player');

  var free = freeBytes_();
  if (free !== null && free - size < MIN_FREE_BYTES) {
    log_('owner_full', email, name + ' ' + size);
    return fail_('owner_full', 'На диске владельца библиотеки закончилось место');
  }

  var source = String(req.source || 'manual');
  if (['deezer', 'soulseek', 'youtube', 'bandcamp', 'manual'].indexOf(source) < 0) source = 'manual';
  var uploadId = Utilities.getUuid();
  var meta = {
    name: name,
    parents: [parentId],
    mimeType: String(req.mime || 'application/octet-stream'),
    properties: {
      cave_uploader: email, // проверенная почта из токена, а не со слов клиента
      cave_uploaded_at: new Date().toISOString(),
      cave_source: source,
      cave_upload_id: uploadId
    }
  };
  var res = UrlFetchApp.fetch(
    'https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&supportsAllDrives=true&fields=' +
    encodeURIComponent('id,name,mimeType,size,md5Checksum,modifiedTime,createdTime,owners(emailAddress,displayName),properties'),
    {
      method: 'post',
      contentType: 'application/json; charset=UTF-8',
      headers: {
        Authorization: 'Bearer ' + ScriptApp.getOAuthToken(),
        'X-Upload-Content-Type': meta.mimeType,
        'X-Upload-Content-Length': String(size)
      },
      payload: JSON.stringify(meta),
      muteHttpExceptions: true
    });
  var code = res.getResponseCode();
  if (code !== 200) {
    log_('begin_fail', email, code + ' ' + res.getContentText().slice(0, 300));
    if (/storageQuotaExceeded/.test(res.getContentText())) return fail_('owner_full', 'На диске владельца библиотеки закончилось место');
    return fail_('drive_error', 'Google отклонил загрузку (' + code + ')');
  }
  var headers = res.getAllHeaders();
  var loc = headers['Location'] || headers['location'];
  if (!loc) return fail_('drive_error', 'Google не вернул адрес загрузки');
  log_('begin', email, name + ' ' + size + ' ' + source + ' ' + uploadId);
  return json_({ ok: true, sessionUri: loc, uploadId: uploadId, uploader: email });
}

/**
 * delete: { token, action:'delete', fileId }
 * Удалить (в корзину) может владелец библиотеки или тот, кто загрузил файл (cave_uploader из свойств).
 * Для старых файлов без cave_uploader «загрузившим» считается их владелец на Диске (ему брокер удалить не сможет,
 * если файл чужой — тогда вернётся not_owner, и клиент сам удалит файл со своей стороны).
 */
function delete_(req, email) {
  var id = String(req.fileId || '');
  if (!id) return fail_('bad_request', 'Не указан файл');
  if (!insideRoot_(id)) return fail_('bad_parent', 'Файл вне библиотеки Cave Player');
  var f;
  try {
    f = Drive.Files.get(id, { fields: 'id,name,properties,owners(emailAddress),trashed,capabilities(canTrash)', supportsAllDrives: true });
  } catch (err) {
    return fail_('not_found', 'Файл не найден');
  }
  if (f.trashed) return json_({ ok: true, already: true });
  var uploader = String((f.properties && f.properties.cave_uploader) || '').toLowerCase();
  if (!uploader && f.owners && f.owners.length) uploader = String(f.owners[0].emailAddress || '').toLowerCase();
  var isOwner = email === ownerEmail_();
  if (!isOwner && uploader !== email) return fail_('forbidden', 'Удалить трек может его владелец или тот, кто его загрузил');
  if (f.capabilities && f.capabilities.canTrash === false) {
    return fail_('not_owner', 'Брокер не может удалить этот (старый) файл — он принадлежит другому аккаунту');
  }
  try {
    Drive.Files.update({ trashed: true }, id, null, { supportsAllDrives: true });
  } catch (err) {
    log_('delete_fail', email, id + ' ' + err);
    return fail_('not_owner', 'Не удалось удалить файл: ' + err);
  }
  log_('delete', email, (f.name || '') + ' ' + id);
  return json_({ ok: true });
}

/**
 * adopt: { token, action:'adopt', fileIds:[…] } — не больше ADOPT_BATCH файлов за раз.
 * Перенос СТАРЫХ файлов (загруженных до брокера) на диск владельца библиотеки без копирования: id файла не меняется,
 * поэтому плейлисты, лайки, статистика и офлайн-копии остаются на месте.
 * Google позволяет передать владение только текущему владельцу файла, поэтому порядок такой:
 *   1. Приложение участника (его токеном) назначает владельца библиотеки «ожидающим владельцем» своих файлов
 *      (permissions.create, role=writer, pendingOwner=true).
 *   2. Этот метод (работает от имени владельца библиотеки) принимает владение (permissions.update, role=owner).
 * Проверки: файл внутри библиотеки; сейчас им владеет вызывающий; ожидающий владелец — именно владелец библиотеки.
 * Прежний владелец записывается в cave_uploader, чтобы «кто загрузил» и права на удаление остались прежними.
 * Ответ: { ok:true, results:{ id: 'ok' | 'already' | 'not_yours' | 'not_pending' | 'bad_parent' | 'bad_type' | 'error' } }
 */
function adopt_(req, email) {
  var me = ownerEmail_();
  if (email === me) return fail_('bad_request', 'Вы и есть владелец библиотеки: переносить нечего');
  var ids = (req.fileIds || []).map(String).slice(0, ADOPT_BATCH);
  if (!ids.length) return fail_('bad_request', 'Не указаны файлы');
  // Собственный идентификатор разрешения: чужие адреса в списке прав обычному «редактору» Google не показывает,
  // поэтому искать своё право по почте ненадёжно. Принимаем владение прямо по этому идентификатору
  var myPid = '';
  try { myPid = Drive.About.get({ fields: 'user(permissionId)' }).user.permissionId; } catch (err) { log_('adopt_about', email, String(err)); }
  var results = {};
  var details = {};
  for (var i = 0; i < ids.length; i++) {
    var id = ids[i];
    try {
      if (!insideRoot_(id)) { results[id] = 'bad_parent'; continue; }
      var f = Drive.Files.get(id, {
        fields: 'id,name,mimeType,createdTime,modifiedTime,properties,trashed,owners(emailAddress)',
        supportsAllDrives: true
      });
      if (f.mimeType === 'application/vnd.google-apps.folder') { results[id] = 'bad_type'; continue; }
      var owner = String((f.owners && f.owners.length && f.owners[0].emailAddress) || '').toLowerCase();
      if (owner === me) { results[id] = 'already'; continue; }
      if (owner !== email) { results[id] = 'not_yours'; details[id] = 'владелец файла: ' + owner; continue; }
      var pid = myPid;
      if (!pid) {
        // запасной путь: ищем своё право в списке
        var perms = Drive.Permissions.list(id, { fields: 'permissions(id,emailAddress,role,pendingOwner)', supportsAllDrives: true }).permissions || [];
        for (var j = 0; j < perms.length; j++) {
          if (perms[j].pendingOwner && (!perms[j].emailAddress || String(perms[j].emailAddress).toLowerCase() === me)) { pid = perms[j].id; break; }
        }
      }
      if (!pid) { results[id] = 'not_pending'; details[id] = 'не найдено ожидающее право владельца'; continue; }
      try {
        Drive.Permissions.update({ role: 'owner' }, id, pid, { transferOwnership: true, supportsAllDrives: true });
      } catch (err) {
        results[id] = 'transfer_failed';
        details[id] = String(err).slice(0, 300);
        log_('adopt_fail', email, id + ' ' + details[id]);
        continue;
      }
      // Проверяем, что владелец действительно сменился: иначе не считаем файл перенесённым
      var after = Drive.Files.get(id, { fields: 'owners(emailAddress)', supportsAllDrives: true });
      var nowOwner = String((after.owners && after.owners.length && after.owners[0].emailAddress) || '').toLowerCase();
      if (nowOwner !== me) {
        results[id] = 'not_transferred';
        details[id] = 'владелец после запроса: ' + nowOwner;
        log_('adopt_fail', email, id + ' ' + details[id]);
        continue;
      }
      var props = f.properties || {};
      props.cave_uploader = owner;
      if (!props.cave_uploaded_at) props.cave_uploaded_at = f.createdTime;
      props.cave_adopted_at = new Date().toISOString();
      try {
        // modifiedTime сохраняем, чтобы приложения не перечитывали теги всех перенесённых файлов
        Drive.Files.update({ properties: props, modifiedTime: f.modifiedTime }, id, null, { supportsAllDrives: true });
      } catch (err) {
        // Владение уже передано; без свойств файл останется «старым», но вернётся в перенос как «already»
        log_('adopt_props_fail', email, id + ' ' + err);
        details[id] = 'владелец сменён, свойства не записаны: ' + String(err).slice(0, 200);
      }
      results[id] = 'ok';
    } catch (err) {
      log_('adopt_fail', email, id + ' ' + err);
      results[id] = 'error';
      details[id] = String(err).slice(0, 300);
    }
  }
  log_('adopt', email, JSON.stringify(results).slice(0, 400));
  return json_({ ok: true, api: API_VERSION, results: results, details: details });
}

// ───────────────────────── Журнал ─────────────────────────

function log_(kind, email, text) {
  try {
    var id = prop_('LOG_SHEET', '');
    if (!id) return;
    var sh = SpreadsheetApp.openById(id).getSheets()[0];
    sh.appendRow([new Date(), kind, email, text]);
  } catch (err) { /* журнал не должен ломать загрузку */ }
}

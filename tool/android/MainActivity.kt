package app.cavey.cave_player

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import android.os.Environment
import dev.ffmpegkit_maintained.ytdlp.YtDlp
import dev.ffmpegkit_maintained.ytdlp.YtDlpRequest
import java.util.concurrent.Executors
import java.util.Locale

// Нужен AudioServiceActivity: плеер в уведомлении работает с тем же движком Flutter.
// Установка обновлений: Dart скачивает APK в cache/updates, а системный установщик
// открывается здесь. Подпись должна совпадать с установленной — поэтому ключ в CI один и тот же.
class MainActivity : AudioServiceActivity() {
    // Вход через браузер: Google возвращает код по ссылке com.googleusercontent.apps.…:/oauth2redirect
    private var authChannel: MethodChannel? = null

    private fun forwardAuth(intent: Intent?) {
        val data = intent?.data ?: return
        if (data.scheme?.startsWith("com.googleusercontent.apps.") == true) {
            authChannel?.invokeMethod("redirect", data.toString())
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        forwardAuth(intent)
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        // Android 13+: без разрешения уведомление с кнопками плеера не покажется
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 7)
        }
    }

    private val youtubeExecutor = Executors.newSingleThreadExecutor()
    @Volatile private var youtubeBusy = false

    private fun validYoutubeUrl(url: String): Boolean {
        val uri = Uri.parse(url)
        if (uri.scheme != "https" || uri.userInfo != null) return false
        val host = uri.host?.lowercase(Locale.ROOT) ?: return false
        if (host == "youtu.be" || host == "www.youtu.be") return uri.pathSegments.isNotEmpty()
        if (host !in setOf("youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com")) return false
        if (uri.path == "/watch") return !uri.getQueryParameter("v").isNullOrEmpty()
        val segments = uri.pathSegments
        return segments.size >= 2 && segments[0] in setOf("shorts", "live") && segments[1].isNotEmpty()
    }

    private fun startYoutubeDownload(url: String, channel: MethodChannel, result: MethodChannel.Result) {
        if (!validYoutubeUrl(url)) {
            result.error("invalid_url", "Нужна HTTPS-ссылка на одно видео YouTube", null)
            return
        }
        if (youtubeBusy) {
            result.error("busy", "Другая загрузка уже выполняется", null)
            return
        }
        youtubeBusy = true
        youtubeExecutor.execute {
            try {
                YtDlp.init(applicationContext)
                val music = File(getExternalFilesDir(Environment.DIRECTORY_MUSIC) ?: filesDir, "YouTube")
                check(music.exists() || music.mkdirs()) { "Не удалось открыть папку Music/YouTube" }
                // Keep song names clean: isolate each download in its own directory.
                val taskDir = File(music, "download_${System.currentTimeMillis()}")
                check(taskDir.mkdirs()) { "Не удалось создать папку загрузки" }
                val template = File(taskDir, "%(title).100B.%(ext)s").absolutePath
                val request = YtDlpRequest(url).setOutputTemplate(template)
                    .addOption("--no-playlist")
                    .addOption("--no-mtime")
                    .addOption("--max-filesize", "250M")
                    // The app's Drive library already recognizes M4A.
                    // Do not mislabel WebM/Opus bytes as M4A.
                    .addOption("-f", "bestaudio[ext=m4a]/best[ext=m4a]")
                val response = YtDlp.execute(request) { percent, _, line ->
                    runOnUiThread {
                        channel.invokeMethod("progress", mapOf(
                            "percent" to percent.toDouble(),
                            "message" to if (line.length > 180) line.take(180) else line
                        ))
                    }
                }
                check(response.isSuccess) { "yt-dlp завершился с кодом ${response.exitCode}" }
                val file = taskDir.listFiles()
                    ?.filter { it.isFile && it.extension.lowercase(Locale.ROOT) == "m4a" && it.length() > 0L }
                    ?.maxByOrNull { it.lastModified() }
                    ?: throw IllegalStateException("Загрузчик не создал M4A файл")
                runOnUiThread {
                    result.success(mapOf("path" to file.absolutePath, "size" to file.length()))
                }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error("download_failed", error.message ?: "Не удалось скачать аудио", null)
                }
            } finally {
                youtubeBusy = false
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        authChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cavey/auth")
        val youtubeChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cavey/youtube")
        youtubeChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "download" -> startYoutubeDownload(
                    call.argument<String>("url") ?: "", youtubeChannel, result
                )
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cavey/installer")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canInstall" -> result.success(
                        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                            packageManager.canRequestPackageInstalls()
                    )
                    "openSettings" -> {
                        val intent = Intent(
                            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:$packageName")
                        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        result.success(null)
                    }
                    "install" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("args", "path is null", null)
                        } else {
                            try {
                                val uri = FileProvider.getUriForFile(
                                    this, "$packageName.fileprovider", File(path)
                                )
                                val intent = Intent(Intent.ACTION_VIEW)
                                    .setDataAndType(uri, "application/vnd.android.package-archive")
                                    .addFlags(
                                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                            Intent.FLAG_ACTIVITY_NEW_TASK
                                    )
                                startActivity(intent)
                                result.success(true)
                            } catch (e: Exception) {
                                result.error("install", e.toString(), null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}

package app.cavey.cave_player

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

// Установка обновлений: Dart скачивает APK в cache/updates, а системный установщик
// открывается здесь. Подпись должна совпадать с установленной — поэтому ключ в CI один и тот же.
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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

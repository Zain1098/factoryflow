package com.proflow.factoryflow

import android.content.ContentValues
import android.os.Build
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DOWNLOAD_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "saveApkToDownloads") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }

                val sourcePath = call.argument<String>("sourcePath")
                val displayName = call.argument<String>("displayName")
                if (sourcePath.isNullOrBlank() || displayName.isNullOrBlank()) {
                    result.error("invalid_arguments", "Missing APK source path or file name.", null)
                    return@setMethodCallHandler
                }

                try {
                    result.success(saveApkToDownloads(File(sourcePath), displayName))
                } catch (error: Exception) {
                    result.error("download_save_failed", error.message, null)
                }
            }
    }

    private fun saveApkToDownloads(source: File, displayName: String): String {
        check(source.isFile) { "Downloaded APK is no longer available." }
        check(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            "Saving update APKs to Downloads requires Android 10 or newer."
        }

        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, displayName)
            put(MediaStore.Downloads.MIME_TYPE, APK_MIME_TYPE)
            put(MediaStore.Downloads.RELATIVE_PATH, "Download/FactoryFlow")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val uri = contentResolver.insert(collection, values)
            ?: error("Could not create the APK in Downloads.")
        try {
            contentResolver.openOutputStream(uri)?.use { output ->
                source.inputStream().use { input -> input.copyTo(output) }
            } ?: error("Could not write the APK to Downloads.")
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
            return uri.toString()
        } catch (error: Exception) {
            contentResolver.delete(uri, null, null)
            throw error
        }
    }

    private companion object {
        const val DOWNLOAD_CHANNEL = "com.proflow.factoryflow/app_updates"
        const val APK_MIME_TYPE = "application/vnd.android.package-archive"
    }
}

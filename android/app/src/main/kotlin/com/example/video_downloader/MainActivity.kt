package com.example.video_downloader

import android.content.Intent
import android.net.Uri
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

/**
 * 接收其他 App 分享的视频（ACTION_SEND / ACTION_SEND_MULTIPLE）：
 * 先把 {content:// URI, 文件名} 缓存进队列，Flutter 侧通过
 * video_downloader/share 通道 takePending() 取走、copy() 落盘到 Documents/Share。
 */
class MainActivity : FlutterActivity() {
  private val pending = mutableListOf<Pair<String, String>>()
  private var channel: MethodChannel? = null

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "video_downloader/share")
    channel?.setMethodCallHandler { call, result ->
      when (call.method) {
        "takePending" -> {
          val items = pending.map { mapOf("source" to it.first, "name" to it.second) }
          pending.clear()
          result.success(items)
        }
        "copy" -> {
          val uri = call.argument<String>("uri")
          val dest = call.argument<String>("dest")
          result.success(
            if (uri != null && dest != null) copyUri(Uri.parse(uri), File(dest)) else false
          )
        }
        else -> result.notImplemented()
      }
    }
    // 冷启动：直接由分享 intent 拉起
    enqueueSend(intent)
  }

  override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    setIntent(intent)
    enqueueSend(intent)
  }

  private fun enqueueSend(intent: Intent?) {
    if (intent == null) return
    when (intent.action) {
      Intent.ACTION_SEND -> {
        val uri = streamExtra(intent, Intent.EXTRA_STREAM) ?: return
        val name = intent.getStringExtra(Intent.EXTRA_TITLE) ?: guessName(uri)
        pending.add(uri.toString() to safeName(name))
      }
      Intent.ACTION_SEND_MULTIPLE -> {
        val uris = streamListExtra(intent, Intent.EXTRA_STREAM) ?: return
        for (uri in uris) pending.add(uri.toString() to safeName(guessName(uri)))
      }
    }
  }

  @Suppress("DEPRECATION")
  private fun streamExtra(intent: Intent, key: String): Uri? =
    if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(key, Uri::class.java)
    else intent.getParcelableExtra(key)

  @Suppress("DEPRECATION", "UNCHECKED_CAST")
  private fun streamListExtra(intent: Intent, key: String): List<Uri>? =
    if (Build.VERSION.SDK_INT >= 33) {
      intent.getParcelableArrayListExtra(key, Uri::class.java)
    } else {
      intent.getParcelableArrayListExtra(key) as? List<Uri>
    }

  private fun guessName(uri: Uri): String {
    val seg = uri.lastPathSegment?.substringAfterLast('/')?.substringAfterLast('\\') ?: ""
    return seg.ifBlank { "shared_video.mp4" }
  }

  private fun safeName(name: String): String {
    var s = name.trim()
      .replace(Regex("[\\\\/:*?\"<>|]"), "_")
      .replace(Regex("\\s+"), " ")
    if (s.isBlank()) s = "shared_video.mp4"
    if (s.length > 120) s = s.take(120)
    return s
  }

  private fun copyUri(uri: Uri, dest: File): Boolean {
    return try {
      val input = contentResolver.openInputStream(uri) ?: return false
      dest.parentFile?.mkdirs()
      input.use { ins ->
        FileOutputStream(dest).use { outs -> ins.copyTo(outs) }
      }
      dest.length() > 0
    } catch (e: Exception) {
      false
    }
  }
}

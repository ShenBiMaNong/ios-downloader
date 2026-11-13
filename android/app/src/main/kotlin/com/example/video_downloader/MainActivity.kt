package com.example.video_downloader

import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
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
    if (intent.action != Intent.ACTION_SEND && intent.action != Intent.ACTION_SEND_MULTIPLE) {
      return
    }
    val uris = collectUris(intent)
    if (uris.isEmpty()) return
    val title = intent.getStringExtra(Intent.EXTRA_TITLE)
    // 队列里已有的 URI 不再重复入队：Activity 重建时 configureFlutterEngine
    // 会拿同一个 intent 再跑一遍，不去重会导入重复文件
    val known = pending.mapTo(HashSet<String>()) { it.first }
    var added = 0
    for (uri in uris) {
      val s = uri.toString()
      if (!known.add(s)) continue
      // 只有一个文件时优先用分享方给的标题；批量时按各自的显示名
      val name = if (uris.size == 1 && !title.isNullOrBlank()) title else guessName(uri)
      pending.add(s to safeName(name))
      added++
    }
    if (added > 0) notifyPending()
  }

  /**
   * 收集本次分享的全部 URI。批量分享有两个来源，必须合并：
   * - EXTRA_STREAM：标准位置（ACTION_SEND_MULTIPLE 为列表）；
   * - ClipData：相册 / 微信 / QQ 等批量分享方把**全部**文件放在这里，
   *   EXTRA_STREAM 往往只带第一条 —— 只读 EXTRA_STREAM 就会「批量分享只收到 1 个」。
   *
   * EXTRA_STREAM 的实际类型不统一（单个 Uri / ArrayList<Uri> 都有分享方在用），
   * 两次读取各自 try 一下：泛型擦除下取错类型要到使用时才抛 ClassCastException。
   */
  private fun collectUris(intent: Intent): List<Uri> {
    val out = LinkedHashSet<Uri>()
    try {
      streamListExtra(intent, Intent.EXTRA_STREAM)?.let { out.addAll(it) }
    } catch (e: Exception) {
      // 不是列表 → 下面按单个 Uri 再取一次
    }
    try {
      streamExtra(intent, Intent.EXTRA_STREAM)?.let { out.add(it) }
    } catch (e: Exception) {
      // 实为列表 → 上面已收集
    }
    val clip: ClipData? = intent.clipData
    if (clip != null) {
      for (i in 0 until clip.itemCount) {
        val u = clip.getItemAt(i)?.uri
        if (u != null && u.scheme != null) out.add(u)
      }
    }
    return out.toList()
  }

  /** 有新分享入队 → 立即通知 Dart 侧导入（不必等 onResume） */
  private fun notifyPending() {
    try {
      channel?.invokeMethod("pendingAdded", null)
    } catch (e: Exception) {
      // Flutter 侧尚未挂接 handler（冷启动首帧前）→ 走启动时的 takePending
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
    // 优先取内容提供者声明的显示名（多数分享方的 lastPathSegment 是 opaque id）
    if (uri.scheme == "content") {
      try {
        contentResolver.query(
          uri,
          arrayOf(OpenableColumns.DISPLAY_NAME),
          null, null, null
        )?.use { c ->
          if (c.moveToFirst()) {
            val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (idx >= 0) {
              val n = c.getString(idx)
              if (!n.isNullOrBlank()) return n
            }
          }
        }
      } catch (e: Exception) {
        // 提供者不支持查询显示名 → 退回 lastPathSegment
      }
    }
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

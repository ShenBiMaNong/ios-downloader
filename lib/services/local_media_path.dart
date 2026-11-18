import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'mp4_probe.dart';

/// 沙盒绝对路径的重新定位。
///
/// 资源库元数据（`Downloads/<id>.json`）里的 `localPath` 是**下载那一刻**记下的
/// 绝对路径，形如 `/var/mobile/Containers/Data/Application/<UUID>/Documents/...`。
/// iOS 的数据容器 UUID 不保证跨安装稳定：换签名身份、删除后重装（sideload 常见），
/// 容器就换了 —— 磁盘上的视频文件跟着 Documents 一起搬了家，元数据里那条路径
/// 却还指着老 UUID。表现是「所有历史视频一次性全部打不开」，而播放器只会回一句
/// 分不清成因的 OSStatus（AVFoundation 报「这不是我能认的媒体文件」），
/// 用户看到的就是「视频损坏」——可文件本身在「文件」App 里能正常播。
///
/// 这里负责把记下来的路径按当前容器翻译回去：先原地探测，再改挂当前 Documents，
/// 最后按文件名在已知目录里回查。判定逻辑做成纯函数（[planRelocation]），
/// 便于在单测里覆盖三种命中与全部落空的情形。
const documentsMarker = '/Documents/';

/// 把 [stored] 改挂到当前 [documentsPath] 下（保持 Documents 以内的相对结构）。
/// 路径里不含 `Documents/`、或翻译后与原来相同，返回 null。
String? remapToDocuments(String stored, String documentsPath) {
  if (stored.isEmpty || documentsPath.isEmpty) return null;
  final i = stored.lastIndexOf(documentsMarker);
  if (i < 0) return null;
  final rest = stored.substring(i + documentsMarker.length);
  if (rest.isEmpty) return null;
  final mapped = '$documentsPath/$rest';
  return mapped == stored ? null : mapped;
}

/// 重定位的三种命中方式。
enum Relocation { same, remapped, foundByName }

/// 一条重定位结论：新路径 + 命中方式。
class Relocated {
  final String path;
  final Relocation kind;
  const Relocated(this.path, this.kind);
}

/// 纯判定：按「原路径 → 改挂当前 Documents → 按文件名回查」的顺序给出结论。
///
/// [exists] 由调用方提供（本地是文件系统 stat，单测里是给定集合）；
/// [findByBasename] 只在文件名线索这一步用到。
/// 三条都不中返回 null —— 这种情况是真的找不到文件，不该再猜。
Relocated? planRelocation({
  required String stored,
  required String documentsPath,
  required bool Function(String path) exists,
  String? Function(String basename)? findByBasename,
}) {
  if (stored.isEmpty) return null;
  if (exists(stored)) return Relocated(stored, Relocation.same);
  final mapped = remapToDocuments(stored, documentsPath);
  if (mapped != null && exists(mapped)) return Relocated(mapped, Relocation.remapped);
  final base = p.basename(stored);
  if (base.isEmpty || findByBasename == null) return null;
  final hit = findByBasename(base);
  if (hit != null && hit.isNotEmpty && exists(hit)) {
    return Relocated(hit, Relocation.foundByName);
  }
  return null;
}

/// 当前容器下的 Documents 绝对路径（iOS/Android 均为 posix 形态）。
Future<String> documentsRoot() async =>
    (await getApplicationDocumentsDirectory()).path;

/// 按文件名在 [dir] 的直属条目里找匹配（含子目录，如 m3u8 分片包目录）。
/// 只查一层：更深的目录（分片）没有辨认价值，遍历反而贵。
String? searchBasenameIn(String dir, String base) {
  if (dir.isEmpty || base.isEmpty) return null;
  try {
    for (final e in Directory(dir).listSync(followLinks: false)) {
      if (p.basename(e.path) == base) return e.path;
    }
  } catch (_) {
    // 目录不存在 / 无权限：当作没找到，交给下一步或返回 null
  }
  return null;
}

/// 「按当前容器重定位」执行器：Documents 只取一次，之后每条都是同步判定。
///
/// 之所以做成对象而不是一个函数：[documentsRoot] 走 path_provider 通道，
/// 资源库可能有几百条记录，稳态下（路径本来就是对的）不该为每条都打一次通道
/// —— 调用方先用 [pathExists] 筛掉活路径，只对失效的那几条用这里。
class ContainerRelocator {
  ContainerRelocator._(this._docs);

  final String _docs;

  /// 取当前容器的 Documents。路径通道不可用（没注册插件的执行环境）时抛，
  /// 由调用方决定放弃重定位。
  static Future<ContainerRelocator> current() async =>
      ContainerRelocator._(await documentsRoot());

  /// 对一条记录的绝对路径做「原路径 → 改挂当前 Documents → 按文件名回查」。
  Relocated? relocate(String stored) => planRelocation(
        stored: stored,
        documentsPath: _docs,
        exists: pathExists,
        findByBasename: _byName,
      );

  /// 文件名回查覆盖 `Documents/Downloads`（主目录）与 `Documents/Share`（分享导入）
  String? _byName(String base) =>
      searchBasenameIn(p.join(_docs, 'Downloads'), base) ??
      searchBasenameIn(p.join(_docs, 'Share'), base);
}

/// 文件或目录存在（m3u8 分片包的 localPath 是目录，不是文件）
bool pathExists(String path) =>
    File(path).existsSync() || Directory(path).existsSync();

/// 起播前对本地文件的实测结论。
enum LocalFileIssue {
  /// 没问题（或这类条目本就不该由本地文件预检来判）
  none,

  /// 压根没给路径
  emptyPath,

  /// 路径指不到东西：容器换了、文件被删了
  missing,

  /// 文件在，但 0 字节
  empty,

  /// 文件在且有内容，头部却不是 ISO-BMFF box（错误页 / 半截数据 / 非视频）
  notVideo,
}

/// 本地文件起播预检：存在性 → 非空 → 头部 box 是不是 mp4 系容器。
///
/// 值得单做一次的原因：AVFoundation 打开失败时只给一句不分成因的 OSStatus，
/// 「路径失联」和「字节不是视频」在界面上长得一模一样，一律写成「文件可能损坏」
/// 就会把人引去重下一个其实好好的文件。
/// 判不出来（读不了、目录型产物）时一律回 [LocalFileIssue.none] ——
/// 预检只负责把已经能确定的成因说清楚，不该拦下本来能播的东西。
LocalFileIssue preflightLocalFile(String path) {
  if (path.trim().isEmpty) return LocalFileIssue.emptyPath;
  if (Directory(path).existsSync()) return LocalFileIssue.none;
  final f = File(path);
  if (!f.existsSync()) return LocalFileIssue.missing;
  int size;
  try {
    size = f.lengthSync();
  } catch (_) {
    return LocalFileIssue.none;
  }
  if (size == 0) return LocalFileIssue.empty;
  RandomAccessFile? raf;
  try {
    raf = f.openSync();
    final head = raf.readSync(12);
    if (!looksLikeMp4Head(head)) return LocalFileIssue.notVideo;
  } catch (_) {
    return LocalFileIssue.none;
  } finally {
    try {
      raf?.closeSync();
    } catch (_) {}
  }
  return LocalFileIssue.none;
}

/// 预检结论对应的用户可读说法；[LocalFileIssue.none] 返回 null（用通用文案）。
String? localIssueText(LocalFileIssue issue) => switch (issue) {
      LocalFileIssue.missing => '视频文件已不在原路径（可能被删除，或 App 重装后沙盒路径变了）',
      LocalFileIssue.empty => '视频文件是 0 字节，需要重新下载',
      LocalFileIssue.notVideo => '文件内容不是可播放的视频（可能是错误页或没下完的数据）',
      LocalFileIssue.emptyPath => '没有可播放的文件路径',
      LocalFileIssue.none => null,
    };

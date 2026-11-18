import 'package:material_ui/material_ui.dart';

import '../models/playable_item.dart';
import '../services/app_data.dart';
import '../services/app_log.dart';
import '../services/app_settings.dart';
import '../services/player_settings.dart';
import 'log_page.dart';

/// 设置页：外观（主题、浏览器启动页）+ 播放设置
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListenableBuilder(
        listenable: Listenable.merge(
          [
            AppSettings.instance,
            PlayerSettings.instance,
            AppData.instance,
            AppLog.instance,
          ],
        ),
        builder: (context, _) {
          final app = AppSettings.instance;
          final s = PlayerSettings.instance;
          final data = AppData.instance;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const _GroupHeader('外观'),
              _section(
                context,
                '主题',
                '浅色、深色，或跟随系统自动切换',
                SegmentedButton<AppThemeMode>(
                  segments: const [
                    ButtonSegment(
                      value: AppThemeMode.light,
                      icon: Icon(Icons.light_mode),
                      label: Text('浅色'),
                    ),
                    ButtonSegment(
                      value: AppThemeMode.dark,
                      icon: Icon(Icons.dark_mode),
                      label: Text('深色'),
                    ),
                    ButtonSegment(
                      value: AppThemeMode.system,
                      icon: Icon(Icons.brightness_auto),
                      label: Text('跟随系统'),
                    ),
                  ],
                  selected: {app.themeMode},
                  onSelectionChanged: (v) => app.setThemeMode(v.first),
                ),
              ),
              _section(
                context,
                '浏览器启动页',
                '打开应用时，内置浏览器显示空白页，还是恢复上次打开的页面',
                SegmentedButton<BrowserStartPage>(
                  segments: const [
                    ButtonSegment(
                      value: BrowserStartPage.blank,
                      label: Text('空白页'),
                    ),
                    ButtonSegment(
                      value: BrowserStartPage.lastPage,
                      label: Text('上次打开页'),
                    ),
                  ],
                  selected: {app.browserStartPage},
                  onSelectionChanged: (v) => app.setBrowserStartPage(v.first),
                ),
              ),
              const _GroupHeader('浏览器'),
              _section(
                context,
                '跳转拦截',
                '网站自动跳转时先弹窗询问是否跳转；命中广告域名时按广告过滤开关自动处理（可在浏览器菜单快捷开关）',
                Switch(
                  value: data.redirectGuardEnabled,
                  onChanged: (v) => data.setRedirectGuard(v),
                ),
              ),
              _section(
                context,
                '禁止视频自动播放',
                '页面自己开始播放的音视频一律拦下，需要你点一下播放器才会播，避免打开网页就出声、白跑流量；'
                '个别站点点了播放没反应时，可在这里或浏览器菜单临时关闭',
                Switch(
                  value: data.blockAutoplayEnabled,
                  onChanged: (v) => data.setBlockAutoplay(v),
                ),
              ),
              _section(
                context,
                '点播放即接管',
                '网页里点播放器时，把拿到的视频直链交给 App 播放器播放（可边播边缓存、无页面广告、后台播放）。'
                '只对能拿到 http 直链的播放器生效；blob:/MSE、DRM 加密、DASH 流一律放行给网页自己播，'
                '所以开启后仍然存在「有些站点没变化」的情况，属于预期',
                Switch(
                  value: data.playHijackEnabled,
                  onChanged: (v) => data.setPlayHijack(v),
                ),
              ),
              const _GroupHeader('播放'),
              _section(
                context,
                '快进 / 快退秒数',
                '双击视频左半边快退、右半边快进，或使用进度条旁的按钮',
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 5, label: Text('5 秒')),
                    ButtonSegment(value: 10, label: Text('10 秒')),
                    ButtonSegment(value: 15, label: Text('15 秒')),
                    ButtonSegment(value: 30, label: Text('30 秒')),
                  ],
                  selected: {s.seekSeconds},
                  onSelectionChanged: (v) => s.setSeekSeconds(v.first),
                ),
              ),
              _section(
                context,
                '按住加速倍速',
                '长按视频任意位置以该倍速加速播放，松开恢复',
                SegmentedButton<double>(
                  segments: const [
                    ButtonSegment(value: 1.5, label: Text('1.5×')),
                    ButtonSegment(value: 2.0, label: Text('2×')),
                    ButtonSegment(value: 3.0, label: Text('3×')),
                  ],
                  selected: {s.holdSpeed},
                  onSelectionChanged: (v) => s.setHoldSpeed(v.first),
                ),
              ),
              _section(
                context,
                '播放顺序',
                '决定「上一个 / 下一个」与播完自动连播的取片顺序',
                SegmentedButton<PlaybackOrder>(
                  segments: const [
                    ButtonSegment(
                      value: PlaybackOrder.sequential,
                      label: Text('顺序'),
                    ),
                    ButtonSegment(
                      value: PlaybackOrder.shuffle,
                      label: Text('乱序'),
                    ),
                  ],
                  selected: {s.order},
                  onSelectionChanged: (v) => s.setOrder(v.first),
                ),
              ),
              _section(
                context,
                '播放完成后',
                '单个视频播完后的动作；选择「下一个」时按上面的播放顺序取片',
                SegmentedButton<PlayCompleteAction>(
                  segments: const [
                    ButtonSegment(
                      value: PlayCompleteAction.replay,
                      label: Text('重播当前'),
                    ),
                    ButtonSegment(
                      value: PlayCompleteAction.next,
                      label: Text('播放下一个'),
                    ),
                  ],
                  selected: {s.onComplete},
                  onSelectionChanged: (v) => s.setOnComplete(v.first),
                ),
              ),
              const _GroupHeader('下载'),
              _section(
                context,
                '锁屏 / 灵动岛下载进度',
                'HLS 视频下载时，iOS 会自动在锁屏和灵动岛挂一条「正在下载」的实时活动'
                '（系统行为，不是应用发的通知）。保持关闭即不再出现；'
                '但关闭后下载会改为「酌情下载」，系统可能推迟到网络、电量更合适时才启动。'
                '若发现点了下载迟迟不动，把它打开即可立即开始（代价是锁屏重新出现进度卡片）',
                Switch(
                  value: app.showHlsProgressOnLockScreen,
                  onChanged: (v) => app.setShowHlsProgressOnLockScreen(v),
                ),
              ),
              const _GroupHeader('日志与排查'),
              _logSection(context),
            ],
          );
        },
      ),
    );
  }

  Widget _section(BuildContext context, String title, String caption, Widget control) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            caption,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Theme.of(context).colorScheme.outline),
          ),
          const SizedBox(height: 12),
          control,
        ],
      ),
    );
  }

  /// 系统日志入口：展示统计，点击进入日志页
  Widget _logSection(BuildContext context) {
    final log = AppLog.instance;
    return _section(
      context,
      '系统日志',
      '记录应用启动、下载、转换、播放等关键事件与报错（下载进度等高频数据不入日志），'
      '可复制或导出，便于排查问题',
      Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          leading: const Icon(Icons.receipt_long),
          title: const Text('查看系统日志'),
          subtitle: Text(
            log.count == 0
                ? '暂无日志'
                : '共 ${log.count} 条 · 错误 ${log.errorCount} · 警告 ${log.warnCount}',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => const LogPage()),
          ),
        ),
      ),
    );
  }
}

/// 设置分组标题（外观 / 播放）
class _GroupHeader extends StatelessWidget {
  final String title;

  const _GroupHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 12),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

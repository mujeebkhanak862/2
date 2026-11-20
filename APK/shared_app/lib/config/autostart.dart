/// Item 85 (desktop): login par agent apne aap start ho — Windows (HKCU Run
/// key, `--background` ke saath => tray mein) aur Linux (XDG autostart
/// `.desktop` file, ya optional systemd user service jo crash par restart
/// karti hai). Android ke liye alag
/// foreground service hai (`BackgroundBridge`).
///
/// Sirf current user ke liye (admin/root nahi chahiye), aur user Permission
/// Center se kabhi bhi band kar sakta hai.
library;

import 'dart:io';

const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
const _valueName = 'UniversalDeviceAgent';
const _systemdUnitName = 'universal-device-agent.service';

/// Linux par login-start ke do tareeqe (ek waqt mein sirf ek).
///  * [xdg]: `~/.config/autostart/*.desktop` — simple, crash par restart nahi.
///  * [systemd]: user service — crash/kill par `Restart=on-failure` se
///    auto-restart. Graphical session ke andar chalti hai (screen/input
///    capture ko display chahiye), isliye `graphical-session.target` se
///    bandhi hai — system-wide/boot-time service nahi.
enum LinuxAutostartKind { xdg, systemd }

class AutostartService {
  /// Test ke liye override ho sakta hai.
  final String executablePath;
  final String? homeDir;
  final Future<ProcessResult> Function(String exe, List<String> args) runProcess;

  AutostartService({
    String? executablePath,
    this.homeDir,
    Future<ProcessResult> Function(String, List<String>)? runProcess,
  })  : executablePath = executablePath ?? Platform.resolvedExecutable,
        runProcess = runProcess ?? Process.run;

  bool get isSupported => Platform.isWindows || Platform.isLinux;

  /// systemd user-service option sirf Linux par.
  bool get supportsSystemd => Platform.isLinux;

  File get _systemdFile {
    final home = homeDir ?? Platform.environment['HOME'] ?? '';
    final xdg = Platform.environment['XDG_CONFIG_HOME'];
    final base = (xdg != null && xdg.isNotEmpty) ? xdg : '$home/.config';
    return File('$base/systemd/user/$_systemdUnitName');
  }

  /// systemd `ExecStart` ke liye quote/escape: `\`, `"`, `%` (specifier)
  /// aur `$` (env expansion) escape hote hain.
  static String systemdExecQuote(String path) {
    final escaped = path
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll('%', '%%')
        .replaceAll('\$', '\$\$');
    return '"$escaped"';
  }

  static String linuxSystemdUnit(String exePath) => '[Unit]\n'
      'Description=Universal Device Agent\n'
      'After=graphical-session.target\n'
      'PartOf=graphical-session.target\n'
      '\n'
      '[Service]\n'
      'Type=simple\n'
      'ExecStart=${systemdExecQuote(exePath)}\n'
      'Restart=on-failure\n'
      'RestartSec=5\n'
      '# Screen/input capture ko session ka display chahiye.\n'
      'PassEnvironment=DISPLAY WAYLAND_DISPLAY XAUTHORITY XDG_RUNTIME_DIR '
      'DBUS_SESSION_BUS_ADDRESS\n'
      '\n'
      '[Install]\n'
      'WantedBy=graphical-session.target\n';

  /// Windows Run-key value: login par window chhupi (tray mein) start ho.
  static String windowsRunValue(String exePath) => '"$exePath" --background';

  File get _linuxFile {
    final home = homeDir ?? Platform.environment['HOME'] ?? '';
    final xdg = Platform.environment['XDG_CONFIG_HOME'];
    final base = (xdg != null && xdg.isNotEmpty) ? xdg : '$home/.config';
    return File('$base/autostart/universal-device-agent.desktop');
  }

  /// Linux `.desktop` Exec line ke liye path quote/escape (spaces, quotes).
  static String desktopExecQuote(String path) {
    final escaped = path
        .replaceAll(r'\', r'\\\\')
        .replaceAll('"', r'\"')
        .replaceAll(r'$', r'\$')
        .replaceAll('`', r'\`');
    return '"$escaped"';
  }

  static String linuxDesktopEntry(String exePath) => '[Desktop Entry]\n'
      'Type=Application\n'
      'Name=Universal Device Agent\n'
      'Exec=${desktopExecQuote(exePath)}\n'
      'X-GNOME-Autostart-enabled=true\n'
      'NoDisplay=false\n';

  Future<bool> isEnabled() async {
    if (Platform.isLinux) {
      return await _linuxFile.exists() || await _systemdFile.exists();
    }
    if (Platform.isWindows) {
      final r = await runProcess('reg', ['query', _runKey, '/v', _valueName]);
      return r.exitCode == 0;
    }
    return false;
  }

  /// Sirf systemd user-service enabled hai?
  Future<bool> isSystemdEnabled() async =>
      Platform.isLinux && await _systemdFile.exists();

  Future<bool> enable({LinuxAutostartKind linuxKind = LinuxAutostartKind.xdg}) async {
    if (Platform.isLinux) {
      if (linuxKind == LinuxAutostartKind.systemd) {
        final unit = _systemdFile;
        await unit.parent.create(recursive: true);
        await unit.writeAsString(linuxSystemdUnit(executablePath));
        final reload = await runProcess('systemctl', ['--user', 'daemon-reload']);
        final en = await runProcess('systemctl', ['--user', 'enable', _systemdUnitName]);
        if (reload.exitCode != 0 || en.exitCode != 0) {
          // Adhura setup chhodne ke bajaye wapas saaf karo.
          if (await unit.exists()) await unit.delete();
          return false;
        }
        // Dono ek saath = agent do baar start hoga; XDG entry hata do.
        final xdg = _linuxFile;
        if (await xdg.exists()) await xdg.delete();
        return true;
      }
      final f = _linuxFile;
      await f.parent.create(recursive: true);
      await f.writeAsString(linuxDesktopEntry(executablePath));
      await _disableSystemd();
      return true;
    }
    if (Platform.isWindows) {
      // Args list ke roop mein (shell string nahi) — injection nahi.
      final r = await runProcess('reg', [
        'add', _runKey, '/v', _valueName, '/t', 'REG_SZ',
        '/d', windowsRunValue(executablePath), '/f',
      ]);
      return r.exitCode == 0;
    }
    return false;
  }

  Future<void> _disableSystemd() async {
    final unit = _systemdFile;
    if (!await unit.exists()) return;
    // Best-effort: systemctl na ho/fail ho to bhi unit file hata do.
    try {
      await runProcess('systemctl', ['--user', 'disable', _systemdUnitName]);
    } catch (_) {}
    if (await unit.exists()) await unit.delete();
    try {
      await runProcess('systemctl', ['--user', 'daemon-reload']);
    } catch (_) {}
  }

  Future<bool> disable() async {
    if (Platform.isLinux) {
      final f = _linuxFile;
      if (await f.exists()) await f.delete();
      await _disableSystemd();
      return true;
    }
    if (Platform.isWindows) {
      final r = await runProcess('reg', ['delete', _runKey, '/v', _valueName, '/f']);
      return r.exitCode == 0;
    }
    return false;
  }
}

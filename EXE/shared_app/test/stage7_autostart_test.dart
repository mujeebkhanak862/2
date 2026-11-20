// Stage 7 (item 85, desktop): autostart helpers.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_app/config/autostart.dart';

void main() {
  test('desktopExecQuote escapes quotes, backslashes, dollars and backticks', () {
    expect(AutostartService.desktopExecQuote('/opt/my app/agent'), '"/opt/my app/agent"');
    final q = AutostartService.desktopExecQuote(r'/o"pt/$x`y');
    expect(q.startsWith('"') && q.endsWith('"'), isTrue);
    expect(q.contains(r'\"'), isTrue);
    expect(q.contains(r'\$'), isTrue);
    expect(q.contains(r'\`'), isTrue);
  });

  test('linuxDesktopEntry is a valid autostart entry', () {
    final e = AutostartService.linuxDesktopEntry('/opt/agent');
    expect(e, startsWith('[Desktop Entry]\n'));
    expect(e, contains('Type=Application'));
    expect(e, contains('Exec="/opt/agent"'));
  });

  test('Linux enable/disable round-trips through the autostart file', () async {
    if (!Platform.isLinux) return;
    final home = Directory.systemTemp.createTempSync('uda_home_');
    addTearDown(() => home.deleteSync(recursive: true));
    final env = Platform.environment['XDG_CONFIG_HOME'];
    if (env != null && env.isNotEmpty) return; // XDG override => is test ko skip
    final s = AutostartService(executablePath: '/opt/agent', homeDir: home.path);
    expect(await s.isEnabled(), isFalse);
    expect(await s.enable(), isTrue);
    expect(await s.isEnabled(), isTrue);
    final f = File('${home.path}/.config/autostart/universal-device-agent.desktop');
    expect(f.readAsStringSync(), contains('Exec="/opt/agent"'));
    expect(await s.disable(), isTrue);
    expect(await s.isEnabled(), isFalse);
  });

  group('Item 85: systemd user service + Windows --background', () {
    test('systemdExecQuote escapes backslash, quote, % and \$', () {
      expect(AutostartService.systemdExecQuote('/opt/my app/agent'), '"/opt/my app/agent"');
      final q = AutostartService.systemdExecQuote(r'/o"pt/100%/$x\y');
      expect(q, r'"/o\"pt/100%%/$$x\\y"');
    });

    test('linuxSystemdUnit has restart policy and graphical-session target', () {
      final u = AutostartService.linuxSystemdUnit('/opt/agent');
      expect(u, contains('ExecStart="/opt/agent"'));
      expect(u, contains('Restart=on-failure'));
      expect(u, contains('WantedBy=graphical-session.target'));
      expect(u, contains('PassEnvironment=DISPLAY WAYLAND_DISPLAY'));
    });

    test('windowsRunValue starts hidden in tray', () {
      expect(AutostartService.windowsRunValue(r'C:\Program Files\Agent\agent.exe'),
          r'"C:\Program Files\Agent\agent.exe" --background');
    });

    test('Linux systemd enable: writes unit, runs systemctl, removes XDG entry', () async {
      if (!Platform.isLinux) return;
      if ((Platform.environment['XDG_CONFIG_HOME'] ?? '').isNotEmpty) return;
      final home = Directory.systemTemp.createTempSync('uda_home_');
      addTearDown(() => home.deleteSync(recursive: true));
      final calls = <List<String>>[];
      final s = AutostartService(
        executablePath: '/opt/agent',
        homeDir: home.path,
        runProcess: (exe, args) async {
          calls.add([exe, ...args]);
          return ProcessResult(0, 0, '', '');
        },
      );
      // Pehle XDG enable, phir systemd => XDG hat jaana chahiye.
      expect(await s.enable(), isTrue);
      final xdg = File('${home.path}/.config/autostart/universal-device-agent.desktop');
      expect(xdg.existsSync(), isTrue);

      expect(await s.enable(linuxKind: LinuxAutostartKind.systemd), isTrue);
      final unit = File('${home.path}/.config/systemd/user/universal-device-agent.service');
      expect(unit.existsSync(), isTrue);
      expect(xdg.existsSync(), isFalse);
      expect(await s.isSystemdEnabled(), isTrue);
      expect(await s.isEnabled(), isTrue);
      expect(calls, contains(['systemctl', '--user', 'enable', 'universal-device-agent.service']));

      // XDG par wapas => systemd unit hat jaani chahiye.
      expect(await s.enable(), isTrue);
      expect(unit.existsSync(), isFalse);
      expect(xdg.existsSync(), isTrue);
      expect(calls, contains(['systemctl', '--user', 'disable', 'universal-device-agent.service']));

      // disable() dono saaf karta hai.
      expect(await s.enable(linuxKind: LinuxAutostartKind.systemd), isTrue);
      expect(await s.disable(), isTrue);
      expect(await s.isEnabled(), isFalse);
    });

    test('systemd enable failure leaves no half-installed unit', () async {
      if (!Platform.isLinux) return;
      if ((Platform.environment['XDG_CONFIG_HOME'] ?? '').isNotEmpty) return;
      final home = Directory.systemTemp.createTempSync('uda_home_');
      addTearDown(() => home.deleteSync(recursive: true));
      final s = AutostartService(
        executablePath: '/opt/agent',
        homeDir: home.path,
        runProcess: (exe, args) async => ProcessResult(0, 1, '', 'no systemd'),
      );
      expect(await s.enable(linuxKind: LinuxAutostartKind.systemd), isFalse);
      expect(await s.isEnabled(), isFalse);
    });
  });
}

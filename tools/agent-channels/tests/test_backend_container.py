from pathlib import Path
import os
import shutil
import struct
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).parents[1]


def find_posix_shell():
    found = shutil.which('sh')
    if found:
        return found
    if os.name == 'nt':
        for candidate in (Path(os.environ.get('ProgramFiles', r'C:\Program Files')) / 'Git' / 'bin' / 'sh.exe',
                          Path(os.environ.get('ProgramFiles', r'C:\Program Files')) / 'Git' / 'usr' / 'bin' / 'sh.exe'):
            if candidate.is_file():
                return str(candidate)
    return None


POSIX_SHELL = find_posix_shell()


class ContainerContractTests(unittest.TestCase):
    def test_each_channel_has_stable_private_home_volume(self):
        compose = (ROOT / 'compose.yaml').read_text(encoding='utf-8')
        self.assertIn('channel1-home:/home/channel', compose)
        self.assertIn('channel2-home:/home/channel', compose)
        self.assertIn('name: qicheng-lite-home-1', compose)
        self.assertIn('name: qicheng-lite-home-2', compose)
        self.assertNotIn('/home/channel:rw,size=', compose)

    def test_normal_firefox_is_maximized_without_forcing_new_profile(self):
        script = (ROOT / 'backend' / 'start.sh').read_text(encoding='utf-8')
        self.assertNotIn('--kiosk', script)
        self.assertNotIn('--profile', script)
        self.assertIn('firefox-esr --new-instance', script)
        self.assertIn('maximized_vert,maximized_horz', script)
        self.assertIn('${SCREEN_WIDTH:-1600}x${SCREEN_HEIGHT:-900}x24', script)

    def test_start_script_supervises_firefox_and_server(self):
        script = (ROOT / 'backend' / 'start.sh').read_text(encoding='utf-8')
        self.assertIn("trap 'handle_signal 143' TERM", script)
        self.assertIn("trap 'handle_signal 130' INT", script)
        self.assertIn('signal_process "$browser_pid"', script)
        self.assertIn('signal_process "$server_pid"', script)
        self.assertIn('wait_for_process "$browser_pid"', script)
        self.assertIn('wait_for_process "$server_pid"', script)
        self.assertNotIn('exec python3 /app/server.py', script)

    @unittest.skipUnless(POSIX_SHELL, 'requires a POSIX shell')
    def test_term_is_forwarded_and_children_are_reaped(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake_bin = root / 'bin'
            fake_bin.mkdir()
            log = root / 'signals.log'

            def executable(name, body):
                path = fake_bin / name
                path.write_text('#!/bin/sh\nset -eu\n' + body, encoding='utf-8')
                path.chmod(0o755)

            sleeper = "trap 'exit 0' TERM INT\nwhile :; do sleep 0.1; done\n"
            executable('Xvfb', sleeper)
            executable('openbox', sleeper)
            executable('xdpyinfo', 'exit 0\n')
            executable('xsetroot', 'exit 0\n')
            executable('dbus-daemon', "printf '%s\\n' 'unix:path=/tmp/fake-dbus'\n")
            executable('xdotool', 'exit 1\n')
            executable('wmctrl', 'exit 0\n')
            executable('firefox-esr', "echo firefox-start >> \"$QICHENG_SIGNAL_LOG\"\ntrap 'echo firefox-term >> \"$QICHENG_SIGNAL_LOG\"; exit 0' TERM INT\nwhile :; do sleep 0.1; done\n")
            executable('python3', "echo server-start >> \"$QICHENG_SIGNAL_LOG\"\ntrap 'echo server-term >> \"$QICHENG_SIGNAL_LOG\"; exit 0' TERM INT\nwhile :; do sleep 0.1; done\n")

            env = dict(os.environ)
            env.update(PATH=str(fake_bin) + os.pathsep + env.get('PATH', ''),
                       QICHENG_HOME=str(root / 'home'),
                       QICHENG_SIGNAL_LOG=str(log), QICHENG_STOP_TICKS='20')
            runner = root / 'signal-test.sh'
            status_file = root / 'status.txt'
            runner.write_text('''#!/bin/sh
set -eu
"$1" &
pid=$!
count=0
until [ -f "$QICHENG_SIGNAL_LOG" ] && grep -q firefox-start "$QICHENG_SIGNAL_LOG" && grep -q server-start "$QICHENG_SIGNAL_LOG"; do
  count=$((count + 1))
  if [ "$count" -ge 100 ]; then kill -KILL "$pid" 2>/dev/null || true; exit 2; fi
  sleep 0.05
done
kill -TERM "$pid"
status=0
wait "$pid" || status=$?
printf '%s' "$status" > "$QICHENG_STATUS_FILE"
''', encoding='utf-8')
            runner.chmod(0o755)
            env['QICHENG_STATUS_FILE'] = str(status_file)
            result = subprocess.run([POSIX_SHELL, runner.as_posix(),
                                     (ROOT / 'backend' / 'start.sh').as_posix()],
                                    env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, (result.stdout, result.stderr))
            self.assertEqual(status_file.read_text(encoding='utf-8'), '143')
            content = log.read_text(encoding='utf-8')
            self.assertIn('firefox-term', content)
            self.assertIn('server-term', content)

    def test_theme_is_local_png_and_welcome_is_chinese(self):
        theme = ROOT / 'backend' / 'theme' / 'ai-space.png'
        data = theme.read_bytes()
        self.assertTrue(data.startswith(b'\x89PNG\r\n\x1a\n'))
        self.assertEqual(struct.unpack('>II', data[16:24]), (1672, 941))
        page = (ROOT / 'backend' / 'welcome.html').read_text(encoding='utf-8-sig')
        self.assertIn('lang="zh-CN"', page)
        self.assertIn('theme/ai-space.png', page)
        self.assertIn('浏览器资料自动保留', page)

    def test_image_defaults_match_backend_state(self):
        dockerfile = (ROOT / 'Dockerfile').read_text(encoding='utf-8')
        self.assertIn('SCREEN_WIDTH=1600 SCREEN_HEIGHT=900', dockerfile)
        self.assertIn('wmctrl', dockerfile)


if __name__ == '__main__':
    unittest.main(verbosity=2)

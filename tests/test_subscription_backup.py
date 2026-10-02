"""Run the real updater against local HTTP fixtures and a real Mihomo validator.

Usage: MIHOMO_TEST_BINARY=/path/to/mihomo python3 -m unittest discover -s tests -v
No production subscriptions or remote machines are used.
"""
import functools
import http.server
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest

REPO = Path(__file__).resolve().parents[1]
CURRENT = 'mode: direct\nlog-level: warning\nrules: []\n'
NEW = 'mode: direct\nlog-level: info\nrules: []\n'
THIRD = 'mode: direct\nlog-level: error\nrules: []\n'


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        pass


@unittest.skipUnless(os.environ.get('MIHOMO_TEST_BINARY'), 'set MIHOMO_TEST_BINARY')
class SubscriptionBackupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR'))
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / 'app'
        self.web = self.root / 'web'
        self.app.mkdir()
        self.web.mkdir()
        handler = functools.partial(QuietHandler, directory=str(self.web))
        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.close_server)
        # Only substitute the container's absolute executable path for local tests.
        source = (REPO / 'subscription.sh').read_text()
        source = source.replace('/mihomo -t', '"' + os.environ['MIHOMO_TEST_BINARY'] + '" -t')
        (self.app / 'subscription.sh').write_text(source)
        (self.app / 'config.yaml').write_text(CURRENT)
        (self.web / 'subscription.yaml').write_text(NEW)
        self.write_conf()

    def close_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)

    def write_conf(self, overlay=False, filename='subscription.yaml'):
        (self.app / 'subscription.conf').write_text(
            f'URL=http://127.0.0.1:{self.server.server_port}/{filename}\n'
            f'INTERVAL_HOURS=1\nAPPLY_TEMPLATE={int(overlay)}\nTEMPLATE_MODE=macvlan\n')

    def run_update(self, mode='--internal', **env):
        result = subprocess.run(['sh', str(self.app / 'subscription.sh'), mode],
                                cwd=self.app, capture_output=True, text=True,
                                timeout=20, env=dict(os.environ, **env))
        self.assertFalse((self.app / '.subscription.lock').exists())
        self.assertEqual(list(self.app.glob('.subscription-previous.*')), [])
        return result

    def previous(self):
        return self.app / 'config.previous.yaml'

    def original(self):
        return self.app / 'config.macvlan.backup.yaml'

    def test_update_without_original_backup(self):
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.app / 'config.yaml').read_text(), NEW)
        self.assertEqual(self.previous().read_text(), CURRENT)
        self.assertEqual(self.previous().stat().st_mode & 0o777, 0o600)
        self.assertFalse(self.original().exists())
        self.assertTrue((self.app / '.subscription.reload.request').exists())

    def test_original_preserved_and_previous_rotates(self):
        self.original().write_text(THIRD)
        self.assertEqual(self.run_update().returncode, 0)
        (self.web / 'subscription.yaml').write_text(THIRD)
        self.assertEqual(self.run_update().returncode, 0)
        self.assertEqual(self.previous().read_text(), NEW)
        self.assertEqual(self.original().read_text(), THIRD)
        self.assertEqual((self.app / 'config.yaml').read_text(), THIRD)

    def test_unchanged_does_not_touch_previous_or_reload(self):
        self.previous().write_text(THIRD)
        before = self.previous().stat().st_mtime_ns
        (self.web / 'subscription.yaml').write_text(CURRENT)
        self.assertEqual(self.run_update().returncode, 0)
        self.assertEqual(self.previous().read_text(), THIRD)
        self.assertEqual(self.previous().stat().st_mtime_ns, before)
        self.assertFalse((self.app / '.subscription.reload.request').exists())

    def test_invalid_candidate_preserves_current_and_previous(self):
        self.previous().write_text(THIRD)
        (self.web / 'subscription.yaml').write_text('rules:\n  - NOT-A-RULE,example.test\n')
        self.assertNotEqual(self.run_update().returncode, 0)
        self.assertEqual((self.app / 'config.yaml').read_text(), CURRENT)
        self.assertEqual(self.previous().read_text(), THIRD)
        self.assertIn('Mihomo 校验未通过', (self.app / 'subscription.log').read_text())

    def test_download_failure_does_not_create_previous(self):
        self.write_conf(filename='missing.yaml')
        self.assertNotEqual(self.run_update().returncode, 0)
        self.assertEqual((self.app / 'config.yaml').read_text(), CURRENT)
        self.assertFalse(self.previous().exists())

    def test_empty_download_preserves_current(self):
        (self.web / 'subscription.yaml').write_text('')
        self.assertNotEqual(self.run_update().returncode, 0)
        self.assertEqual((self.app / 'config.yaml').read_text(), CURRENT)
        self.assertFalse(self.previous().exists())

    def test_restore_still_requires_original(self):
        self.previous().write_text(THIRD)
        self.assertNotEqual(self.run_update('--restore').returncode, 0)
        self.assertEqual((self.app / 'config.yaml').read_text(), CURRENT)
        self.assertEqual(self.previous().read_text(), THIRD)

    def test_restore_preserves_original_and_saves_current(self):
        self.original().write_text(THIRD)
        self.assertEqual(self.run_update('--restore').returncode, 0)
        self.assertEqual((self.app / 'config.yaml').read_text(), THIRD)
        self.assertEqual(self.original().read_text(), THIRD)
        self.assertEqual(self.previous().read_text(), CURRENT)

    def test_overlay_mode_without_original(self):
        (self.app / 'subscription.macvlan.yaml').write_text('log-level: error\n')
        self.write_conf(overlay=True)
        self.assertEqual(self.run_update().returncode, 0)
        self.assertIn('log-level: error', (self.app / 'config.yaml').read_text())
        self.assertEqual(self.previous().read_text(), CURRENT)
        self.assertFalse(self.original().exists())

    def test_previous_directory_refuses_update(self):
        self.previous().mkdir()
        self.assertNotEqual(self.run_update().returncode, 0)
        self.assertEqual((self.app / 'config.yaml').read_text(), CURRENT)
        self.assertEqual(list(self.previous().iterdir()), [])

    def test_previous_symlink_refuses_update(self):
        target = self.root / 'target'
        target.write_text(THIRD)
        self.previous().symlink_to(target)
        self.assertNotEqual(self.run_update().returncode, 0)
        self.assertEqual((self.app / 'config.yaml').read_text(), CURRENT)
        self.assertEqual(target.read_text(), THIRD)

    def test_backup_copy_failure_refuses_publish(self):
        # Explicit fault injection: fail only the rolling snapshot copy.
        tools = self.root / 'tools'
        tools.mkdir()
        cp = tools / 'cp'
        real_cp = shutil.which('cp')
        assert real_cp is not None
        cp.write_text('#!/bin/sh\ncase "$2" in *.subscription-previous.*) exit 1;; esac\n'
                      'exec "' + real_cp + '" "$@"\n')
        cp.chmod(0o700)
        self.assertNotEqual(self.run_update(PATH=str(tools) + os.pathsep + os.environ['PATH']).returncode, 0)
        self.assertEqual((self.app / 'config.yaml').read_text(), CURRENT)
        self.assertFalse(self.previous().exists())
        self.assertFalse((self.app / '.subscription.reload.request').exists())


if __name__ == '__main__':
    unittest.main()

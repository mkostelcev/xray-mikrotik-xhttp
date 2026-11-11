import json
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


def generate(enabled=None, servers=('192.0.2.1',)):
    source = (ROOT / 'entrypoint.sh').read_text()
    function = source[source.index('build_outbounds() {'):source.index('# Build selector list')]
    script = '''SERVERS=({servers})
PORTS=(443 3443)
DEFAULT_PORT=443
SOCKOPT_JSON='{{}}'
{function}
build_outbounds
'''.format(servers=' '.join(servers), function=function)
    env = {k: v for k, v in os.environ.items() if k != 'XMUX_ENABLED'}
    env.update(ID='11111111-2222-3333-4444-555555555555', SNI='example.com',
               PBK='KUjM9Cnqi0AKqvSm-v0cygvBbgP1v_ZN8oxcbtBCuQM', SID='be47a3',
               SPX='/test', MUX_CONCURRENCY='-1', XUDP_CONCURRENCY='16')
    if enabled is not None:
        env['XMUX_ENABLED'] = enabled
    return subprocess.run(['bash', '-ec', script], env=env, text=True, capture_output=True)


class XmuxTests(unittest.TestCase):
    def outbounds(self, enabled=None, servers=('192.0.2.1',)):
        result = generate(enabled, servers)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads('[' + result.stdout + ']')

    def test_opt_in_changes_only_extra_for_each_server(self):
        servers = ('192.0.2.1', '2001:db8::1')
        baseline = self.outbounds(servers=servers)
        enabled = self.outbounds('1', servers)
        for before, after in zip(baseline, enabled, strict=True):
            extra = after['streamSettings']['xhttpSettings'].pop('extra')
            self.assertEqual(extra, {
                'xPaddingBytes': '100-1000',
                'xmux': {'maxConcurrency': '16-32', 'maxConnections': 0,
                         'cMaxReuseTimes': 0, 'hMaxRequestTimes': '600-900',
                         'hMaxReusableSecs': '1800-3000', 'hKeepAlivePeriod': 0},
            })
            self.assertEqual(after, before)
        self.assertEqual([o['settings']['vnext'][0]['port'] for o in baseline], [443, 3443])

    def test_disabled_restores_previous_config(self):
        self.assertEqual(self.outbounds('0'), self.outbounds())
        self.assertNotIn('extra', self.outbounds()[0]['streamSettings']['xhttpSettings'])

    def test_invalid_flag_fails_generation(self):
        for invalid in ('true', 'false', '2', '1, "path": "/other"'):
            with self.subTest(invalid=invalid):
                result = generate(invalid)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')
                self.assertIn('XMUX_ENABLED must be 0 or 1', result.stderr)


if __name__ == '__main__':
    unittest.main()

import ipaddress
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'resolve-doh'
QUESTION = b'\x01x\x04test\x00'


def answer(record, data, size=None):
    return b'\xc0\x0c' + struct.pack('!HHIH', record, 1, 60, len(data) if size is None else size) + data


def response(record, answers=(), flags=0x8180):
    return struct.pack('!HHHHHH', 0, flags, 1, len(answers), 0, 0) + QUESTION + struct.pack('!HH', record, 1) + b''.join(answers)


class ResolverTests(unittest.TestCase):
    def query(self, wire, record):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / 'answer').write_bytes(wire)
            curl = path / 'curl'
            curl.write_text('#!/bin/sh\nwhile [ "$#" -gt 0 ]; do\n if [ "$1" = "-o" ]; then cp "$DNS_FIXTURE" "$2"; exit 0; fi\n shift\ndone\nexit 1\n')
            curl.chmod(0o700)
            env = dict(os.environ, PATH=str(path) + ':' + os.environ['PATH'], DNS_FIXTURE=str(path / 'answer'))
            return subprocess.run(['bash', str(HELPER), 'x.test', record, '9.9.9.9'], env=env, text=True, capture_output=True)

    def test_compressed_cname_and_multiple_a(self):
        wire = response(1, [answer(5, b'\x05alias\xc0\x0e'), answer(1, b'\xc0\x00\x02\x01'), answer(1, b'\xc0\x00\x02\x02')])
        result = self.query(wire, 'A')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ['192.0.2.1', '192.0.2.2'])

    def test_aaaa(self):
        address = ipaddress.IPv6Address('2001:db8::1234')
        result = self.query(response(28, [answer(28, address.packed)]), 'AAAA')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(ipaddress.IPv6Address(result.stdout.strip()), address)

    def test_missing_aaaa_is_success_without_addresses(self):
        result = self.query(response(28), 'AAAA')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def test_rejects_dns_errors_and_truncation(self):
        for flags in [0x8183, 0x8380]:
            with self.subTest(flags=flags):
                self.assertNotEqual(self.query(response(1, flags=flags), 'A').returncode, 0)

    def test_rejects_short_and_non_dns(self):
        for wire in [b'', b'<html>error</html>', response(1, [answer(1, b'xx', size=500)])]:
            with self.subTest(wire=wire):
                self.assertNotEqual(self.query(wire, 'A').returncode, 0)


if __name__ == '__main__':
    unittest.main()

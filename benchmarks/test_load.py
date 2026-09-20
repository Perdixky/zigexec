#!/usr/bin/env python3
"""End-to-end gates for the native load generator, including a corrupt server."""
import concurrent.futures
import json
import socket
import subprocess
import time
import unittest
from pathlib import Path

BINARY = Path(__file__).resolve().parents[1] / ".bench-cache/echo-load"


class LoadGeneratorTest(unittest.TestCase):
    def exchange(self, *, corrupt=False, size=64):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            listener.settimeout(5)

            def echo():
                client, _ = listener.accept()
                with client:
                    client.settimeout(5)
                    client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                    while True:
                        # Deliberately unrelated to the request and server buffer sizes.
                        try:
                            data = client.recv(997)
                        except ConnectionResetError:
                            return
                        if not data:
                            return
                        if corrupt:
                            data = bytes([data[0] ^ 1]) + data[1:]
                        try:
                            client.sendall(data[:7])
                            client.sendall(data[7:])
                        except (BrokenPipeError, ConnectionResetError):
                            return

            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
                serving = executor.submit(echo)
                process = subprocess.Popen([str(BINARY), str(listener.getsockname()[1]), "1", str(size)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                try:
                    self.assertEqual(process.stdout.readline(), "ready\n")
                    start = time.monotonic_ns() + 100_000_000
                    stdout, stderr = process.communicate(f"{start} {start + 100_000_000} {start + 600_000_000}\n", timeout=10)
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.communicate()
                serving.result(timeout=5)
                return process.returncode, stdout, stderr

    def test_fragmented_valid_echo_and_histogram(self):
        code, stdout, stderr = self.exchange(size=65536)
        self.assertEqual(code, 0, stderr)
        result = json.loads(stdout)
        self.assertGreater(result["completed"], 0)
        self.assertEqual(result["completed"], sum(count for _, count in result["histogram_us"]))
        self.assertGreater(result["latency_sum_ns"], 0)

    def test_corruption_fails_instead_of_reporting_throughput(self):
        code, _, stderr = self.exchange(corrupt=True)
        self.assertNotEqual(code, 0)
        self.assertIn("echo mismatch", stderr)


if __name__ == "__main__":
    unittest.main()

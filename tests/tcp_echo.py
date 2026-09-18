"""Loopback smoke tests: python3 tests/tcp_echo.py zig-out/bin/zigexec-tcp-echo."""
import concurrent.futures
import re
import select
import socket
import struct
import subprocess
import sys
from contextlib import contextmanager


@contextmanager
def server(binary, once=False):
    process = subprocess.Popen(
        [binary, "0"] + (["--once"] if once else []),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        ready, _, _ = select.select([process.stderr], [], [], 10)
        assert ready, "server did not announce its listening port"
        line = process.stderr.readline()
        match = re.fullmatch(r"listening on 127\.0\.0\.1:(\d+)\n", line)
        assert match, f"unexpected startup output: {line!r}"
        yield process, ("127.0.0.1", int(match[1]))
    finally:
        if process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)
        process.stderr.close()


def receive_all(client):
    result = bytearray()
    while chunk := client.recv(4093):
        result.extend(chunk)
    return result


def main(binary):
    # EOF without any input must close cleanly and let --once release the reactor.
    with server(binary, once=True) as (process, address):
        with socket.create_connection(address, timeout=10) as client:
            client.shutdown(socket.SHUT_WR)
            assert client.recv(1) == b""
        assert process.wait(timeout=10) == 0

    # Binary data, multiple buffer lengths, fragmented input, full-duplex traffic,
    # and half-close: the server must drain every byte before closing its side.
    payload = bytes(range(256)) * 4096 + b"\x00last chunk\xff"
    with server(binary, once=True) as (process, address):
        with socket.create_connection(address, timeout=10) as client:
            def write():
                for start in range(0, len(payload), 7919):
                    client.sendall(payload[start : start + 7919])
                client.shutdown(socket.SHUT_WR)

            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                writer = pool.submit(write)
                echoed = receive_all(client)
                writer.result(timeout=10)
            assert echoed == payload, "echo lost, duplicated, or reordered bytes"
        assert process.wait(timeout=10) == 0

    # A reset peer must not terminate the process (including through SIGPIPE).
    with server(binary) as (process, address):
        with socket.create_connection(address, timeout=10) as client:
            client.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            client.sendall(b"reset this connection" * 1024)
        for payload in (b"next client", b"another\x00client"):
            with socket.create_connection(address, timeout=10) as client:
                client.sendall(payload)
                client.shutdown(socket.SHUT_WR)
                assert receive_all(client) == payload
        assert process.poll() is None, "reset peer terminated the server"

    print("TCP echo passed: empty EOF, 1 MiB binary/fragmented half-close, reset, reconnect")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/zigexec-tcp-echo")

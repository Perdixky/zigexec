"""Loopback smoke tests: python3 tests/tcp_echo.py zig-out/bin/zigexec-tcp-echo."""
import concurrent.futures
import re
import select
import socket
import struct
import subprocess
import sys
import threading
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


def receive_exact(client, count):
    result = bytearray()
    while len(result) < count:
        chunk = client.recv(count - len(result))
        assert chunk, "unexpected EOF"
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

    # One idle client cannot block accepting/serving others. All 32 clients must
    # receive their distinct echoes before ANY closes: a small accept-worker pool
    # or a sequential server deadlocks at this barrier and fails the timeout.
    with server(binary) as (process, address):
        with socket.create_connection(address, timeout=10) as idle:
            barrier = threading.Barrier(32, timeout=10)

            def exchange(index):
                payload = bytes([index]) * (20000 + index * 997) + b"tail\x00"
                with socket.create_connection(address, timeout=10) as client:
                    client.sendall(payload)
                    assert receive_exact(client, len(payload)) == payload
                    barrier.wait()
                    client.shutdown(socket.SHUT_WR)
                    assert client.recv(1) == b""

            with concurrent.futures.ThreadPoolExecutor(max_workers=32) as pool:
                list(pool.map(exchange, range(32)))
            # A reset and a new connection while the first connection is still
            # alive must neither corrupt nor close the first child's state.
            with socket.create_connection(address, timeout=10) as broken:
                broken.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                broken.sendall(b"reset while other clients are active")
            with socket.create_connection(address, timeout=10) as newcomer:
                newcomer.sendall(b"still accepting")
                assert receive_exact(newcomer, 15) == b"still accepting"
            idle.sendall(b"idle client survived")
            assert receive_exact(idle, 20) == b"idle client survived"
        assert process.poll() is None

    # --once drains the manually owned operation, including its retirement.
    with server(binary, once=True) as (process, address):
        with socket.create_connection(address, timeout=10) as client:
            for payload in (b"first round", b"second round"):
                client.sendall(payload)
                assert receive_exact(client, len(payload)) == payload
                assert process.poll() is None, "--once exited before the child finished"
            client.shutdown(socket.SHUT_WR)
            assert client.recv(1) == b""
        assert process.wait(timeout=10) == 0

    # The error completion must also retire a manually owned --once operation.
    with server(binary, once=True) as (process, address):
        with socket.create_connection(address, timeout=10) as client:
            client.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            client.sendall(b"reset once" * 1024)
        assert process.wait(timeout=10) == 0

    print("TCP echo passed: EOF, 1 MiB half-close, reset/reconnect, 32 concurrent clients + idle client, --once drain")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/zigexec-tcp-echo")

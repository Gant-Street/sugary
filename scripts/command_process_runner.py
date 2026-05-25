#!/usr/bin/env python3
import json
import os
import selectors
import subprocess
import sys
import time


def limited_read(process, timeout_ms, stdout_limit, stderr_limit):
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, "stdout")
    selector.register(process.stderr, selectors.EVENT_READ, "stderr")
    stdout = bytearray()
    stderr = bytearray()
    stdout_truncated = False
    stderr_truncated = False
    deadline = time.monotonic() + (timeout_ms / 1000.0)

    while selector.get_map():
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            process.kill()
            process.wait()
            return stdout, stderr, True, stdout_truncated, stderr_truncated

        events = selector.select(min(0.05, remaining))
        if not events and process.poll() is not None:
            for key in list(selector.get_map().values()):
                data = key.fileobj.read()
                if data:
                    if key.data == "stdout":
                        stdout_truncated = append_limited(stdout, data, stdout_limit) or stdout_truncated
                    else:
                        stderr_truncated = append_limited(stderr, data, stderr_limit) or stderr_truncated
                selector.unregister(key.fileobj)
            break

        for key, _mask in events:
            data = os.read(key.fileobj.fileno(), 8192)
            if not data:
                selector.unregister(key.fileobj)
                continue

            if key.data == "stdout":
                stdout_truncated = append_limited(stdout, data, stdout_limit) or stdout_truncated
            else:
                stderr_truncated = append_limited(stderr, data, stderr_limit) or stderr_truncated

    process.wait()
    return stdout, stderr, False, stdout_truncated, stderr_truncated


def append_limited(buffer, data, limit):
    remaining = max(limit - len(buffer), 0)
    if remaining > 0:
        buffer.extend(data[:remaining])
    return len(data) > remaining


def main():
    if len(sys.argv) > 1:
        with open(sys.argv[1], "r", encoding="utf-8") as handle:
            request = json.load(handle)
    else:
        request = json.loads(sys.stdin.read())
    command = request["command"]
    args = request.get("args", [])
    cwd = request.get("cwd") or "."
    env = os.environ.copy()
    env.update(request.get("env", {}))
    input_data = request.get("input", "")
    timeout_ms = int(request.get("timeout_ms", 5000))
    stdout_limit = int(request.get("stdout_limit", 65536))
    stderr_limit = int(request.get("stderr_limit", 65536))
    started = time.monotonic()

    try:
        process = subprocess.Popen(
            [command] + args,
            cwd=cwd,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        process.stdin.write(input_data.encode("utf-8"))
        process.stdin.close()
        stdout, stderr, timed_out, stdout_truncated, stderr_truncated = limited_read(
            process, timeout_ms, stdout_limit, stderr_limit
        )
        exit_status = process.returncode
        error = None
    except FileNotFoundError:
        stdout = b""
        stderr = f"command not found: {command}".encode("utf-8")
        timed_out = False
        stdout_truncated = False
        stderr_truncated = False
        exit_status = 127
        error = "command_not_found"
    except Exception as exc:
        stdout = b""
        stderr = str(exc).encode("utf-8")
        timed_out = False
        stdout_truncated = False
        stderr_truncated = False
        exit_status = 1
        error = "runner_error"

    duration_ms = int((time.monotonic() - started) * 1000)
    response = {
        "stdout": stdout.decode("utf-8", errors="replace"),
        "stderr": stderr.decode("utf-8", errors="replace"),
        "exit_status": exit_status,
        "timed_out": timed_out,
        "duration_ms": duration_ms,
        "stdout_truncated": stdout_truncated,
        "stderr_truncated": stderr_truncated,
        "error": error,
    }
    print(json.dumps(response))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Launch MoMo's DeepSeek Harness runtime and its local Python services."""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import platform
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import time
import urllib.request
import uuid
from collections.abc import Callable

RUNTIME_DIR = Path(__file__).resolve().parent
REPOSITORY = Path(__file__).resolve().parents[3]
SOURCE = REPOSITORY / "Vendor" / "HermesAgent"
UPSTREAM = REPOSITORY / "Vendor" / "HermesAgent.UPSTREAM.json"
DEFAULT_DATA = Path.home() / "Library/Application Support/MoMoAgent/Agent"
# The pinned upstream groups the aiohttp API adapter under messaging.
REQUIRED_EXTRAS = ["mcp", "messaging"]
ACCESS_LOCK = REPOSITORY / "Apps/MacApp/Access/requirements.lock"


def write_private(path: Path, value: str) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        stream.write(value)


def profile_directory(data: Path) -> Path:
    """Existing installations keep their original model settings and credentials."""
    current = data / "profile"
    legacy = data / "hermes"
    return legacy if legacy.is_dir() and not current.exists() else current


def credentials_directory(data: Path) -> Path:
    profile = profile_directory(data)
    default = profile_directory(DEFAULT_DATA)
    if not (profile / "auth.json").is_file() and (default / "auth.json").is_file():
        return default
    return profile


def read_connection(data: Path) -> dict:
    value = json.loads((data / "connection.json").read_text(encoding="utf-8"))
    if value.get("schema_version") != 1 or value.get("application") != "MoMoAgent":
        raise ValueError("Not a supported MoMo Agent runtime directory")
    port = value.get("port")
    if type(port) is not int or not 1 <= port <= 65534:
        raise ValueError("Invalid local API port")
    if value.get("base_url") != f"http://127.0.0.1:{port}":
        raise ValueError("This development runtime must bind to loopback")
    for field in ("workspace_id", "assistant_id", "instance_id"):
        uuid.UUID(value[field])
    token_path = data / "api-key"
    if token_path.is_symlink() or token_path.stat().st_mode & 0o077:
        raise ValueError("api-key must be a private regular file (mode 0600)")
    if len(token_path.read_text(encoding="utf-8").strip()) < 32:
        raise ValueError("Missing or invalid runtime API credential")
    if not (profile_directory(data) / "config.yaml").is_file():
        raise ValueError("Missing runtime config; initialization is incomplete")
    return value


def initialize(data: Path, port: int) -> dict:
    if not 1 <= port <= 65534:
        raise ValueError("Port must be between 1 and 65534")
    if (data / "connection.json").exists():
        connection = read_connection(data)
        if connection["port"] != port:
            raise ValueError("Runtime already uses another port; existing configuration was preserved")
        return connection
    if data.exists() and any(data.iterdir()):
        raise ValueError("Refusing to initialize a nonempty directory without a MoMo identity")
    data.mkdir(parents=True, exist_ok=True, mode=0o700)
    data.chmod(0o700)
    for name in ("profile", "runtime", "workspace"):
        (data / name).mkdir(mode=0o700)
    connection = {
        "schema_version": 1, "application": "MoMoAgent", "assistant_name": "MoMo",
        "workspace_id": str(uuid.uuid4()), "assistant_id": str(uuid.uuid4()),
        "instance_id": str(uuid.uuid4()), "port": port,
        "base_url": f"http://127.0.0.1:{port}", "data_url": f"http://127.0.0.1:{port + 1}",
    }
    config = {"model": {"provider": "custom", "default": "", "base_url": ""}}
    write_private(data / "api-key", secrets.token_urlsafe(36) + "\n")
    write_private(profile_directory(data) / "config.yaml", json.dumps(config, ensure_ascii=False, indent=2) + "\n")
    write_private(profile_directory(data) / ".env", "# Model credentials for this MoMo instance only.\n")
    # This marker is last: a partial initialization must never look usable.
    write_private(data / "connection.json", json.dumps(connection, indent=2) + "\n")
    return read_connection(data)


def system_proxy_environment() -> dict[str, str]:
    """Export macOS's configured HTTP proxy for provider requests."""
    if sys.platform != "darwin": return {}
    from urllib.request import getproxies_macosx_sysconf
    from _scproxy import _get_proxy_settings
    proxies = getproxies_macosx_sysconf()
    result = {key.upper() + "_PROXY": proxies[key] for key in ("http", "https") if proxies.get(key)}
    settings = _get_proxy_settings()
    exceptions = list(settings.get("exceptions", ()))
    if settings.get("exclude_simple"): exceptions.append("<local>")
    if exceptions: result["NO_PROXY"] = ",".join(exceptions)
    return result


def child_environment(data: Path) -> dict[str, str]:
    allowed = (
        "PATH", "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "SHELL", "TMPDIR",
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
        "http_proxy", "https_proxy", "all_proxy", "no_proxy",
        "SSL_CERT_FILE", "SSL_CERT_DIR", "REQUESTS_CA_BUNDLE",
    )
    environment = {key: os.environ[key] for key in allowed if key in os.environ}
    # A Finder-launched app has no shell proxy environment. Keep an explicit
    # operator configuration authoritative; otherwise use the user's system setting.
    if not any(key in environment for key in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy")):
        for key, value in system_proxy_environment().items():
            if key == "NO_PROXY" and ("NO_PROXY" in environment or "no_proxy" in environment): continue
            environment[key] = value
    bypass = ",".join(environment.get(key, "") for key in ("NO_PROXY", "no_proxy"))
    entries = list(dict.fromkeys(part.strip() for part in bypass.split(",") if part.strip()))
    if "*" not in entries: entries += [host for host in ("127.0.0.1", "localhost", "::1") if host not in entries]
    environment["NO_PROXY"] = environment["no_proxy"] = ",".join(entries)
    environment.update({
        "HERMES_HOME": str(profile_directory(data)),
        "HERMES_RUNTIME_DIR": str(data / "runtime/tools"),
        "PYTHONUNBUFFERED": "1",
        "PYTHONPYCACHEPREFIX": str(data / "runtime/bytecode"),
    })
    return environment


def fingerprint() -> dict:
    upstream = json.loads(UPSTREAM.read_text(encoding="utf-8"))
    return {
        "source": str(SOURCE), "upstream_commit": upstream["commit"],
        "lock_sha256": hashlib.sha256((SOURCE / "uv.lock").read_bytes()).hexdigest(),
        "manifest_sha256": hashlib.sha256((SOURCE / "pyproject.toml").read_bytes()).hexdigest(),
        "extras": REQUIRED_EXTRAS,
        "access_lock_sha256": hashlib.sha256(ACCESS_LOCK.read_bytes()).hexdigest(),
    }


def bundled_python() -> Path | None:
    manifest = REPOSITORY / "runtime-manifest.json"
    if not manifest.exists():
        return None
    record = json.loads(manifest.read_text(encoding="utf-8"))
    executable = REPOSITORY / "python/bin/python3.14"
    if (record.get("schema_version") != 1
            or record.get("architecture") != platform.machine()
            or dependency_identity(record.get("dependencies", {})) != dependency_identity(fingerprint())
            or not os.access(executable, os.X_OK)):
        raise ValueError("Bundled runtime is incomplete or incompatible; reinstall this Mac app")
    return executable


def prepared_python(data: Path) -> Path:
    if executable := bundled_python():
        return executable
    record = json.loads((data / "runtime/prepared.json").read_text(encoding="utf-8"))
    executable = data / "runtime/venv/bin/python"
    if dependency_identity(record) != dependency_identity(fingerprint()) or not executable.is_file():
        raise ValueError("Runtime dependencies do not match this source; prepare a new runtime")
    return executable


def dependency_identity(record: dict) -> dict:
    # The vendored provider helpers are loaded from this release, so their
    # location may change without invalidating the pinned environment.
    return {key: value for key, value in record.items() if key != "source"}


def prepare(data: Path, progress: Callable[[str], None] = lambda phase: None) -> None:
    if str(RUNTIME_DIR) not in sys.path:
        sys.path.insert(0, str(RUNTIME_DIR))
    from superagent_runtime import prepare_superagent

    _prepare_base_python(data, lambda phase: progress(phase) if phase != "ready" else None)
    prepare_superagent(data, child_environment(data), progress=progress)


def _prepare_base_python(data: Path, progress: Callable[[str], None] = lambda phase: None) -> None:
    read_connection(data)
    if bundled_python() is not None:
        progress("ready")
        return
    marker = data / "runtime/prepared.json"
    if marker.exists():
        record = json.loads(marker.read_text(encoding="utf-8"))
        expected = fingerprint()
        if dependency_identity(record) == dependency_identity(expected):
            prepared_python(data)
            if record != expected:
                atomic_private(marker, json.dumps(expected, indent=2) + "\n")
            progress("ready")
            print("Runtime dependencies already prepared for this source")
            return
        # Upgrade the network adapter without rebuilding or changing the Agent's pinned environment.
        previous = {k: v for k, v in dependency_identity(record).items() if k != "access_lock_sha256"}
        current = {k: v for k, v in dependency_identity(expected).items() if k != "access_lock_sha256"}
        if previous != current or not (data / "runtime/venv/bin/python").is_file():
            raise ValueError("Agent dependencies changed; prepare a new runtime directory")
        progress("connection")
        prepare_access(data)
        atomic_private(marker, json.dumps(expected, indent=2) + "\n")
        progress("ready")
        print("Updated network adapter dependencies")
        return
    if sys.version_info[:2] != (3, 14):
        raise ValueError("Prepare requires Python 3.14: uv run --no-project --python 3.14 ...")
    environment = child_environment(data)
    os.environ.clear()
    os.environ.update(environment)
    sys.path.insert(0, str(SOURCE))
    import pm

    progress("agent")
    pm.build_environment(
        source=SOURCE, out=data / "runtime/venv", python=Path(sys.executable),
        extras=REQUIRED_EXTRAS, no_install_project=True, frozen=True, explicit=True,
        terminal_progress=True,
    )
    progress("connection")
    prepare_access(data)
    write_private(marker, json.dumps(fingerprint(), indent=2) + "\n")
    progress("ready")
    print("Prepared MoMo Python dependencies")


def prepare_access(data: Path) -> None:
    sys.path.insert(0, str(SOURCE))
    from pm.terminal_progress import run_with_progress
    uv = shutil.which("uv")
    if uv is None:
        raise ValueError("uv is required to prepare the network adapter")
    executable = str(data / "runtime/venv/bin/python")
    result = run_with_progress([uv, "pip", "install", "--python", executable, "--no-deps", "--require-hashes",
                    "-r", str(ACCESS_LOCK)], env=child_environment(data))
    result.check_returncode()
    subprocess.run([uv, "pip", "check", "--python", executable], check=True, env=child_environment(data))


def serve(data: Path) -> None:
    read_connection(data)
    executable = prepared_python(data)
    environment = child_environment(data)
    command = [str(executable), "-I", "-X", f"pycache_prefix={data / 'runtime/bytecode'}",
               str(Path(__file__).resolve()), "_gateway", "--data-dir", str(data)]
    os.chdir(data / "workspace")
    os.execve(str(executable), command, environment)


def gateway(data: Path) -> None:
    # One Mac app owns this runtime, including across a stop/restart race.
    with (data / "runtime/agent.lock").open("w") as lease:
        for attempt in range(50):
            try:
                fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError as error:
                if attempt == 49:
                    raise ValueError("MoMo is still running or stopping; retry after shutdown") from error
                time.sleep(0.1)
        run_gateway(data)


def run_gateway(data: Path) -> None:
    if str(RUNTIME_DIR) not in sys.path:
        sys.path.insert(0, str(RUNTIME_DIR))
    from superagent_gateway import run_superagent_gateway

    run_superagent_gateway(data, read_connection(data), python_executable=Path(sys.executable),
                           base_env=child_environment(data))


def atomic_private(path: Path, text: str) -> None:
    temporary = path.with_name(path.name + ".new")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        stream.write(text)
        stream.flush(); os.fsync(stream.fileno())
    temporary.replace(path)


def status(data: Path) -> None:
    if str(RUNTIME_DIR) not in sys.path:
        sys.path.insert(0, str(RUNTIME_DIR))
    from runtime_engine import read_engine_config

    connection = read_connection(data)
    token = (data / "api-key").read_text(encoding="utf-8").strip()
    request = urllib.request.Request(connection["base_url"] + "/v1/capabilities",
                                     headers={"Authorization": "Bearer " + token})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(request, timeout=5) as response:
        capabilities = json.load(response)
    print(json.dumps({"connection": connection, "engine_config": read_engine_config(data),
                      "capabilities": capabilities}, ensure_ascii=False, indent=2))


def engine_command(data: Path, *, set_engine: str | None = None, proactive: str | None = None) -> None:
    if str(RUNTIME_DIR) not in sys.path:
        sys.path.insert(0, str(RUNTIME_DIR))
    from runtime_engine import read_engine_config, write_engine_config
    from superagent_runtime import prepared_dsh_binary

    read_connection(data)
    cfg = write_engine_config(data, engine=set_engine, proactive_mode=proactive) if (set_engine or proactive) else read_engine_config(data)
    superagent_ok = False
    try:
        prepared_dsh_binary(data)
        superagent_ok = True
    except Exception:
        superagent_ok = False
    print(json.dumps({**cfg, "superagent_prepared": superagent_ok},
                     ensure_ascii=False, indent=2))


def main() -> None:
    parser = argparse.ArgumentParser(description="MoMo Agent embedded Agent runtime")
    parser.add_argument("command", choices=["init", "prepare", "serve", "status", "engine", "_gateway"])
    parser.add_argument("--data-dir", type=Path, default=DEFAULT_DATA)
    parser.add_argument("--port", type=int, default=8765, help="Local API port for init")
    parser.add_argument("--progress", action="store_true", help="Emit preparation phase events for the desktop app")
    parser.add_argument("--engine", choices=["superagent"], default=None, help="Select active agent engine")
    parser.add_argument("--proactive", choices=["auto", "observe", "off"], default=None, help="SuperAgent proactive mode")
    args = parser.parse_args()
    data = args.data_dir.expanduser().resolve()
    try:
        if args.command == "init":
            print(json.dumps(initialize(data, args.port), ensure_ascii=False, indent=2))
            if args.engine or args.proactive:
                if str(RUNTIME_DIR) not in sys.path:
                    sys.path.insert(0, str(RUNTIME_DIR))
                from runtime_engine import write_engine_config
                write_engine_config(data, engine=args.engine, proactive_mode=args.proactive)
        elif args.command == "engine":
            engine_command(data, set_engine=args.engine, proactive=args.proactive)
        else:
            if args.engine or args.proactive:
                if str(RUNTIME_DIR) not in sys.path:
                    sys.path.insert(0, str(RUNTIME_DIR))
                from runtime_engine import write_engine_config
                write_engine_config(data, engine=args.engine, proactive_mode=args.proactive)
            if args.command == "prepare" and args.progress:
                prepare(data, progress=lambda phase: print("MOMO_PREPARE " + phase, flush=True))
            else:
                {"prepare": prepare, "serve": serve, "status": status, "_gateway": gateway}[args.command](data)
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f"MoMo runtime: {error}\n")


if __name__ == "__main__":
    main()

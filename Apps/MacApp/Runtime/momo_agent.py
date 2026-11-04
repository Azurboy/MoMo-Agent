#!/usr/bin/env python3
"""MoMo Agent's source-owned Hermes runtime. No dependency on a global Hermes install."""
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
    if not (data / "hermes/config.yaml").is_file():
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
    for name in ("hermes", "runtime", "workspace"):
        (data / name).mkdir(mode=0o700)
    connection = {
        "schema_version": 1, "application": "MoMoAgent", "assistant_name": "MoMo",
        "workspace_id": str(uuid.uuid4()), "assistant_id": str(uuid.uuid4()),
        "instance_id": str(uuid.uuid4()), "port": port,
        "base_url": f"http://127.0.0.1:{port}", "data_url": f"http://127.0.0.1:{port + 1}",
    }
    config = {
        "model": {"provider": "custom", "default": "", "base_url": ""},
        "memory": {"memory_enabled": True, "user_profile_enabled": True},
        "updates": {"check": False},
        "agent": {"max_turns": 20},
        "platform_toolsets": {"api_server": ["terminal", "file", "memory"]},
        "terminal": {"cwd": str(data / "workspace")},
    }
    write_private(data / "api-key", secrets.token_urlsafe(36) + "\n")
    write_private(data / "hermes/config.yaml", json.dumps(config, ensure_ascii=False, indent=2) + "\n")
    write_private(data / "hermes/.env", "# Model credentials for this MoMo instance only.\n")
    write_private(data / "hermes/SOUL.md", default_soul())
    # This marker is last: a partial initialization must never look usable.
    write_private(data / "connection.json", json.dumps(connection, indent=2) + "\n")
    return read_connection(data)


def system_proxy_environment() -> dict[str, str]:
    """Export macOS's configured HTTP proxy for Hermes' env-only LLM transport."""
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
        "HERMES_HOME": str(data / "hermes"),
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
    # The project is deliberately NOT installed into the venv. Hermes code is
    # loaded from this release's SOURCE, so its location is provenance, not a
    # dependency. Renaming/moving the app or shipping a new release directory
    # must not invalidate an otherwise identical pinned environment.
    return {key: value for key, value in record.items() if key != "source"}


def prepare(data: Path, progress: Callable[[str], None] = lambda phase: None) -> None:
    if str(RUNTIME_DIR) not in sys.path:
        sys.path.insert(0, str(RUNTIME_DIR))
    from runtime_engine import read_engine_config
    from superagent_runtime import prepare_superagent

    engine = read_engine_config(data)["engine"]
    base_progress = progress if engine == "hermes" else (lambda phase: progress(phase) if phase != "ready" else None)
    _prepare_base_python(data, base_progress)
    if engine == "superagent":
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
    print("Prepared dependencies; application code is loaded from Vendor/HermesAgent")


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
    connection = read_connection(data)
    executable = prepared_python(data)
    environment = child_environment(data)
    environment.update({
        "API_SERVER_ENABLED": "true", "API_SERVER_HOST": "127.0.0.1",
        "API_SERVER_PORT": str(connection["port"]),
        "API_SERVER_KEY": (data / "api-key").read_text(encoding="utf-8").strip(),
    })
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
    from runtime_engine import read_engine_config

    if read_engine_config(data)["engine"] == "superagent":
        from superagent_gateway import run_superagent_gateway

        run_superagent_gateway(
            data,
            read_connection(data),
            python_executable=Path(sys.executable),
            base_env=child_environment(data),
        )
        return

    sys.path.insert(0, str(SOURCE))
    import hermes_yaml

    config = hermes_yaml.safe_load((data / "hermes/config.yaml").read_text(encoding="utf-8"))
    model = config.get("model", {}) if isinstance(config, dict) else {}
    if not isinstance(model, dict) or not model.get("default") or not model.get("provider"):
        raise ValueError("Configure an explicit model and provider in hermes/config.yaml before serving")
    if model["provider"] == "custom" and not model.get("base_url"):
        raise ValueError("A custom provider requires model.base_url")
    configure_context(data, config, hermes_yaml)
    sys.path.insert(0, str(REPOSITORY / "Apps/MacApp/Context"))
    from context_server import ContextService
    context = ContextService(data, read_connection(data))
    import gateway.run
    if str(RUNTIME_DIR) not in sys.path:
        sys.path.insert(0, str(RUNTIME_DIR))
    from personal_agent import install
    install(data, read_connection(data))

    actual_source = Path(gateway.run.__file__).resolve()
    if not actual_source.is_relative_to(SOURCE):
        raise RuntimeError("Refusing to run an external Hermes installation")
    print(json.dumps({"application": "MoMoAgent", "runtime_source": str(actual_source),
                      "data_directory": str(data), "upstream_commit": fingerprint()["upstream_commit"]}), flush=True)
    sys.argv = ["momo-agent-gateway"]
    context.start()
    try:
        gateway.run.main()
    finally:
        context.close()


def configure_context(data: Path, config: dict, yaml) -> None:
    """MoMo exposes source transcripts; Hermes owns its native memory and session lifecycle."""
    connection = read_connection(data)
    expected = f"http://127.0.0.1:{connection['port'] + 1}"
    if connection.get("data_url", expected) != expected:
        raise ValueError("Development context service must bind to its loopback port")
    if "data_url" not in connection:
        connection["data_url"] = expected
        atomic_private(data / "connection.json", json.dumps(connection, indent=2) + "\n")
    executable = prepared_python(data)
    server = {
        "command": str(executable),
        "args": [str(REPOSITORY / "Apps/MacApp/Context/context_mcp.py")],
        "env": {"MOMO_CONTEXT_DIRECTORY": str(data / "context"), "PYTHONPYCACHEPREFIX": str(data / "runtime/bytecode")},
    }
    config.setdefault("gateway", {})["multiplex_profiles"] = False
    # Keep Hermes' normal retry loop; chat must not silently spend minutes in its extra recovery ladder.
    config.setdefault("agent", {}).setdefault("auto_recovery_cycles", 0)
    config["momo_transcript_memory"] = True
    config.setdefault("memory", {}).update(memory_enabled=True, user_profile_enabled=True)
    config["memory"].pop("provider", None)  # This product version uses Hermes' built-in store.
    config.setdefault("mcp_servers", {})["momo_context"] = server
    config["mcp_servers"]["momo_recordings"] = {**server, "env": {**server["env"], "MOMO_MEMORY_ONLY": "1"}}
    config["mcp_servers"]["momo_computer"] = {
        "command": str(executable), "args": [str(REPOSITORY / "Apps/MacApp/Runtime/desktop_mcp.py")],
        "env": {"MOMO_AGENT_DIRECTORY": str(data), "PYTHONPYCACHEPREFIX": str(data / "runtime/bytecode")},
    }
    config["mcp_servers"]["momo_pim"] = {
        "command": str(executable), "args": [str(REPOSITORY / "Apps/MacApp/Runtime/pim_mcp.py")],
        "env": {"MOMO_AGENT_DIRECTORY": str(data), "PYTHONPYCACHEPREFIX": str(data / "runtime/bytecode")},
    }
    toolsets = config.setdefault("platform_toolsets", {}).setdefault("api_server", ["terminal", "file"])
    for name in ("momo_context", "momo_recordings", "memory", "session_search", "momo_computer", "momo_pim", "delegation", "momoagent_tasks"):
        if name not in toolsets:
            toolsets.append(name)
    config.setdefault("terminal", {})["cwd"] = str(data / "workspace")
    install_prompt(data, config)
    atomic_private(data / "hermes/config.yaml", json.dumps(config, ensure_ascii=False, indent=2) + "\n")


def default_soul() -> str:
    # Keep upstream's complete behavior spec, changing only the product identity sentence.
    upstream = (SOURCE / "SOUL.md").read_text().strip()
    identity, separator, behavior = upstream.partition(". ")
    if identity != "You are Hermes Agent, built by Nous Research" or not separator:
        raise ValueError("Review the upstream SOUL identity before updating the MoMo persona")
    return "你是 Momo，运行在用户的 Mac 上（执行引擎为 Hermes）。你的名字就是 Momo，不要自称“Momo 的 AI 助手”或“MoMo Agent 的助手”。\n\n" + behavior + "\n"


def install_prompt(data: Path, config: dict) -> None:
    """Install our native Hermes plugin and migrate only MoMo-owned SOUL paragraphs."""
    destination = data / "hermes/plugins/momoagent"
    destination.mkdir(parents=True, exist_ok=True, mode=0o700)
    for name in ("__init__.py", "plugin.yaml", "policy.md", "task_control.py"):
        atomic_private(destination / name, (REPOSITORY / "Apps/MacApp/Runtime/prompt_plugin" / name).read_text())
    enabled = config.setdefault("plugins", {}).setdefault("enabled", [])
    if "momoagent" not in enabled:
        enabled.append("momoagent")
    soul = data / "hermes/SOUL.md"
    text = soul.read_text()
    for name, prefix in (("sources", ""), ("reply before action", "用户交代任务时，"),
                         ("nonblocking conversation", "主会话持续和用户交流。")):
        marker, end_marker = f"<!-- MoMo {name} -->", f"<!-- /MoMo {name} -->"
        if marker not in text:
            continue
        before, _, generated = text.partition(marker)
        if end_marker in generated:
            text = before + generated.partition(end_marker)[2]
        else:
            paragraph, _, remaining = generated.lstrip("\n").partition("\n")
            if not prefix or paragraph.startswith(prefix):
                text = before + remaining
    old_identity = "你是 MoMo，MoMoAgent 的私人助手。用明确的来源和真实执行结果提供帮助；资料或执行状态未知时直接说明。"
    if text.startswith(old_identity):
        text = default_soul() + text[len(old_identity):]
    # Rename only our exact generated openings; keep the user's remaining SOUL unchanged.
    for previous_brand in (
        "你是 MoMo，MoMoAgent 的私人助手，运行在 Hermes 引擎上。",
        "你是 MoMo，MoMo Agent 的私人助手，运行在 Hermes 引擎上。",
    ):
        if text.startswith(previous_brand + "\n"):
            text = default_soul().split("\n", 1)[0] + text[len(previous_brand):]
            break
    # User-authored identities and text outside managed paragraphs are preserved verbatim.
    if soul.read_text() != text:
        atomic_private(soul, text)


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
    hermes_ok = False
    superagent_ok = False
    try:
        prepared_python(data)
        hermes_ok = True
    except Exception:
        hermes_ok = False
    try:
        prepared_dsh_binary(data)
        superagent_ok = True
    except Exception:
        superagent_ok = False
    print(json.dumps({**cfg, "hermes_prepared": hermes_ok, "superagent_prepared": superagent_ok},
                     ensure_ascii=False, indent=2))


def main() -> None:
    parser = argparse.ArgumentParser(description="MoMo Agent embedded Agent runtime")
    parser.add_argument("command", choices=["init", "prepare", "serve", "status", "engine", "_gateway"])
    parser.add_argument("--data-dir", type=Path, default=DEFAULT_DATA)
    parser.add_argument("--port", type=int, default=8765, help="Local API port for init")
    parser.add_argument("--progress", action="store_true", help="Emit preparation phase events for the desktop app")
    parser.add_argument("--engine", choices=["hermes", "superagent"], default=None, help="Select active agent engine")
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

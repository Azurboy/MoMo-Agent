"""Native desktop model setup; Hermes owns subscription credentials and refresh."""
from __future__ import annotations

import argparse
import contextlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import threading
import time
from urllib.parse import urlsplit

# The bundled interpreter runs with -I and omits this signed script directory.
if sys.flags.isolated:
    sys.path.insert(0, str(Path(__file__).resolve().parent))

from antigravity_bridge import (
    find_antigravity_cli,
    is_antigravity_authorization_url,
    list_antigravity_models,
    login_antigravity,
    run_antigravity_completion,
)
from momo_agent import SOURCE, atomic_private, child_environment, read_connection

PROVIDERS = {"codex": "openai-codex", "claude": "anthropic", "antigravity": "antigravity"}


class ModelSetupError(Exception):
    pass


def catalog(provider: str, credentials: dict | None = None) -> list[str]:
    if provider == "codex":
        from hermes_cli.codex_models import get_codex_model_ids
        return list(get_codex_model_ids(
            access_token=(credentials or {}).get("api_key"), base_url=(credentials or {}).get("base_url")))
    if provider == "antigravity":
        return list_antigravity_models()[1]
    from hermes_cli.models import _PROVIDER_MODELS
    return list(_PROVIDER_MODELS["anthropic"])


def account(provider: str) -> dict:
    if provider == "codex":
        from hermes_cli.auth import get_codex_auth_status
        connected = bool(get_codex_auth_status().get("logged_in"))
        available = True
        models = catalog(provider)
    elif provider == "antigravity":
        cli = find_antigravity_cli()
        available = cli is not None
        connected, models = list_antigravity_models(cli)
    else:
        from agent.anthropic_credentials import read_claude_code_credentials, is_claude_code_token_valid
        from agent.anthropic_adapter import find_claude_code_cli
        credentials = read_claude_code_credentials()
        connected = bool(credentials and (is_claude_code_token_valid(credentials) or credentials.get("refreshToken")))
        available = find_claude_code_cli("claude") is not None
        models = catalog(provider)
    return {"provider": provider, "connected": connected, "models": models, "loginAvailable": available}


def authorization_url(value: str, provider: str) -> bool:
    if provider == "antigravity":
        return is_antigravity_authorization_url(value)
    url = urlsplit(value)
    if url.scheme != "https" or url.username or url.password or url.port not in {None, 443}:
        return False
    if provider == "codex":
        return url.hostname == "auth.openai.com" and url.path in {"/codex/device", "/oauth/authorize"}
    return url.hostname in {"claude.ai", "console.anthropic.com", "platform.claude.com"} and url.path == "/oauth/authorize"


def stop_login_child(child) -> None:
    if child.poll() is not None:
        return
    with contextlib.suppress(ProcessLookupError):
        os.killpg(child.pid, signal.SIGTERM)
    try:
        child.wait(timeout=1)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(child.pid, signal.SIGKILL)
        child.wait()


def login(provider: str, authorize=lambda **fields: None, flow: str = "device") -> dict:
    if provider == "codex":
        if flow == "browser":
            from hermes_cli.auth_codex_browser import _codex_browser_login
            from hermes_cli.auth_codex import _save_codex_tokens
            credentials = _codex_browser_login(open_browser=False, timeout_seconds=300,
                on_authorize=lambda url: authorize(url=url, expiresAt=time.time() + 300))
            _save_codex_tokens(credentials["tokens"], last_refresh=credentials.get("last_refresh"))
            return account(provider)
        from hermes_cli.auth_constants import CODEX_OAUTH_CLIENT_ID
        from hermes_cli.auth_codex import (
            _codex_request_device_code, _codex_poll_authorization_code,
            _codex_exchange_authorization_code, _save_codex_tokens,
        )
        issuer = "https://auth.openai.com"
        device = _codex_request_device_code(issuer, CODEX_OAUTH_CLIENT_ID)
        authorize(url=issuer + "/codex/device", code=device["user_code"], expiresAt=time.time() + 300)
        response = _codex_poll_authorization_code(issuer, device_auth_id=device["device_auth_id"],
            user_code=device["user_code"], poll_interval=device["interval"])
        tokens = _codex_exchange_authorization_code(issuer, CODEX_OAUTH_CLIENT_ID, response)
        _save_codex_tokens(tokens)
    elif provider == "antigravity":
        if not find_antigravity_cli():
            raise ModelSetupError("请先安装 Antigravity CLI (agy)，再使用 Antigravity 订阅登录。")
        try:
            connected, _ = login_antigravity(authorize)
        except RuntimeError as err:
            raise ModelSetupError(str(err)) from err
        if not connected:
            raise ModelSetupError("Antigravity 登录没有完成，请先在终端运行 `agy` 完成 Google 账号登录后重试。")
    else:
        from agent.anthropic_adapter import find_claude_code_cli
        cli = find_claude_code_cli("claude")
        if not cli:
            raise ModelSetupError("请先安装 Claude Code，再使用 Claude 订阅登录。")
        # Use Claude Code's own browser login; Hermes reads and refreshes that login.
        child = subprocess.Popen([cli, "auth", "login", "--claudeai"], stdin=subprocess.DEVNULL,
                                 start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 text=True, bufsize=1)
        def report():
            for line in child.stdout:
                # Only the official authorization URL crosses the native UI boundary.
                for url in re.findall(r"https://[^\s\x1b<>\"']+", line):
                    with contextlib.suppress(ValueError):
                        if authorization_url(url, provider):
                            authorize(url=url, expiresAt=time.time() + 300)
        reporter = threading.Thread(target=report, daemon=True)
        reporter.start()
        previous = signal.getsignal(signal.SIGTERM)
        def cancel(signum, frame):
            stop_login_child(child)
            raise SystemExit(130)
        signal.signal(signal.SIGTERM, cancel)
        try:
            if child.wait(timeout=300) != 0:
                raise ModelSetupError("Claude 登录没有完成，请重试。")
        finally:
            signal.signal(signal.SIGTERM, previous)
            stop_login_child(child)
            reporter.join(timeout=1)
    return account(provider)


def resolve_credentials(provider: str, model: str) -> dict:
    if provider == "codex":
        from hermes_cli.auth_codex import resolve_codex_runtime_credentials
        from hermes_cli.auth import get_codex_auth_status
        if not get_codex_auth_status().get("logged_in"):
            raise ModelSetupError("请先登录 Codex。")
        return resolve_codex_runtime_credentials()
    if provider == "antigravity":
        cli = find_antigravity_cli()
        if not cli:
            raise ModelSetupError("请先安装 Antigravity CLI (agy)。")
        connected, _ = list_antigravity_models(cli)
        if not connected:
            raise ModelSetupError("请先使用 Antigravity CLI (agy) 登录 Google 账号。")
        return {"provider": "antigravity", "api_key": "antigravity-cli", "cli_path": cli}
    from hermes_cli.runtime_provider import resolve_runtime_provider
    return resolve_runtime_provider(requested="anthropic", target_model=model)


def probe(provider: str, model: str, credentials: dict) -> None:
    if provider == "antigravity":
        try:
            completion = run_antigravity_completion(
                model=model,
                messages=[{"role": "user", "content": "Connection test. Reply OK."}],
                timeout=45,
            )
        except Exception as err:
            raise ModelSetupError("Antigravity 连接验证失败，请检查订阅登录状态或更换模型。") from err
        choice = (completion.get("choices") or [{}])[0]
        reply_text = str((choice.get("message") or {}).get("content") or "").strip()
        if not reply_text:
            raise ModelSetupError("Antigravity 没有完成连接验证，请重试。")
        return
    if provider == "codex":
        from openai import OpenAI
        from agent.codex_headers import apply_required_codex_headers
        from agent.process_bootstrap import build_keepalive_http_client
        kwargs = dict(api_key=credentials["api_key"], base_url=credentials["base_url"], timeout=30, max_retries=0)
        transport = build_keepalive_http_client(base_url=credentials["base_url"])
        if transport is None: raise ModelSetupError("无法建立模型连接，请重试。")
        kwargs["http_client"] = transport
        apply_required_codex_headers(kwargs, access_token=credentials["api_key"], base_url=credentials["base_url"])
        with OpenAI(**kwargs) as client:
            with client.responses.create(model=model, instructions="Reply only OK.",
                    input=[{"role": "user", "content": "Connection test. Reply OK."}], store=False, stream=True) as stream:
                text, completed = "", False
                for event in stream:
                    if event.type == "response.output_text.delta":
                        text += event.delta
                    elif event.type == "response.completed":
                        completed = event.response.status == "completed"
                    elif event.type in {"response.failed", "error"}:
                        raise ModelSetupError("Codex 连接验证失败，请检查订阅状态或更换模型。")
                if not text.strip() or not completed:
                    raise ModelSetupError("Codex 没有完成连接验证，请重试。")
    else:
        from agent.anthropic_adapter import build_anthropic_client, build_anthropic_kwargs
        from agent.anthropic_credentials import _is_oauth_token
        token = credentials["api_key"]
        # A subscription entry must never silently use an API credential.
        if not _is_oauth_token(token):
            raise ModelSetupError("当前是 Claude API 凭据，请使用 Claude Code 登录订阅账号。")
        kwargs = build_anthropic_kwargs(model=model, messages=[{"role": "user", "content": "Reply only OK."}],
            tools=None, max_tokens=32, reasoning_config={"enabled": False}, is_oauth=True,
            base_url=credentials["base_url"])
        with build_anthropic_client(token, credentials["base_url"], timeout=30) as client:
            response = client.messages.create(**kwargs)
        if not any(getattr(block, "text", "").strip() for block in response.content):
            raise ModelSetupError("Claude 没有完成连接验证，请重试。")


def load_config(data: Path) -> dict:
    file = data / "hermes/config.yaml"
    defaults = {
        "memory": {"memory_enabled": True, "user_profile_enabled": True},
        "updates": {"check": False},
        "agent": {"max_turns": 20},
        "platform_toolsets": {"api_server": ["terminal", "file", "memory"]},
        "terminal": {"cwd": str(data / "workspace")},
    }
    if not file.is_file():
        return defaults
    raw = file.read_text(encoding="utf-8")
    try:
        parsed = json.loads(raw)
        if isinstance(parsed, dict):
            return parsed
    except json.JSONDecodeError:
        for loader in ("yaml", "ruamel.yaml"):
            with contextlib.suppress(Exception):
                if loader == "yaml":
                    import yaml
                    parsed = yaml.safe_load(raw)
                else:
                    from ruamel.yaml import YAML
                    parsed = YAML(typ="safe").load(raw)
                if isinstance(parsed, dict):
                    return dict(parsed)
    return defaults


def verify_and_save(data: Path, provider: str, model: str) -> dict:
    model = model.strip()
    if not model or len(model) > 200 or any(c.isspace() for c in model):
        raise ModelSetupError("请选择模型后继续。")
    credentials = resolve_credentials(provider, model)
    probe(provider, model, credentials)
    file = data / "hermes/config.yaml"
    config = load_config(data)
    # Subscription routing comes from Hermes, never from a previous custom API URL.
    config["model"] = {"provider": PROVIDERS[provider], "default": model}
    atomic_private(file, json.dumps(config, ensure_ascii=False, indent=2) + "\n")
    return {"provider": provider, "connected": True, "models": [model], "loginAvailable": True}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("status", "login", "verify"))
    parser.add_argument("--provider", choices=tuple(PROVIDERS), required=True)
    parser.add_argument("--model", default="")
    parser.add_argument("--flow", choices=("device", "browser"), default="device")
    parser.add_argument("--data-dir", type=Path, required=True)
    args = parser.parse_args()
    data = args.data_dir.expanduser().resolve()
    read_connection(data)
    environment = child_environment(data)
    environment["PATH"] = str(Path.home() / ".local/bin") + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    os.environ.clear(); os.environ.update(environment)
    sys.path.insert(0, str(SOURCE))
    try:
        protocol = sys.stdout
        expires_at = time.time() + 300
        def authorize(**fields):
            fields["expiresAt"] = min(fields["expiresAt"], expires_at)
            print(json.dumps({"event": "authorization", **fields}), file=protocol, flush=True)

        def expired(signum, frame):
            raise ModelSetupError("登录已超时，请重试。")

        if args.command == "login":
            signal.signal(signal.SIGALRM, expired)
            signal.alarm(300)
        # Third-party libraries may print URLs or account metadata. Only the fixed result
        # schema reaches Swift; diagnostic output stays in the private local log.
        with contextlib.redirect_stdout(sys.stderr):
            if args.command == "verify":
                result = verify_and_save(data, args.provider, args.model)
            else:
                result = account(args.provider) if args.command == "status" else login(args.provider, authorize, args.flow)
        print(json.dumps(result))
        return 0
    except Exception as error:
        status = getattr(error, "status_code", None)
        if isinstance(error, (subprocess.TimeoutExpired, TimeoutError)) or getattr(error, "code", "") in {"codex_browser_callback_timeout", "device_code_timeout"}:
            message = "登录已超时，请重试。"
        elif getattr(error, "code", "") == "codex_browser_port_busy":
            message = "登录端口被占用，请改用验证码登录。"
        elif isinstance(error, ModelSetupError):
            message = str(error)
        elif status in {401, 403}:
            message = "登录已失效或订阅不可用，请重新登录。"
        elif status == 429:
            message = "当前订阅额度暂时不可用，请稍后重试。"
        else:
            message = "暂时无法连接模型服务，请检查网络或重新登录。"
        # Do not surface arbitrary SDK error text, headers, tokens or provider responses.
        print(json.dumps({"error": message}, ensure_ascii=False))
        return 1
    finally:
        if args.command == "login":
            signal.alarm(0)


if __name__ == "__main__":
    raise SystemExit(main())

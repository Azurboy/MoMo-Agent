#!/bin/bash
# Use the private runtime shipped with the installed Mac app, or an explicitly selected environment.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
runtime_python="${MOMO_WEB_PYTHON:-/Applications/MoMo Agent.app/Contents/Resources/AgentRuntime/python/bin/python3.14}"
if [[ ! -x "$runtime_python" ]]; then
  echo "找不到 MoMo Agent 的 Python 环境。请安装 Mac 版或指定 MOMO_WEB_PYTHON（需要 aiohttp）。" >&2
  exit 1
fi
if command -v uv >/dev/null 2>&1; then
  exec uv run --no-project --python "$runtime_python" -- "$runtime_python" -B "$repo_dir/Apps/MobileWeb/server.py" "$@"
fi
exec "$runtime_python" -B "$repo_dir/Apps/MobileWeb/server.py" "$@"

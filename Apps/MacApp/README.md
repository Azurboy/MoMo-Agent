# MoMo Agent for Mac — development foundation

This is the runtime foundation for the MoMo Agent Mac application.
It runs DeepSeek Harness with the SuperAgent bundle and MoMo’s local Python services.

## Prepare and run

From the repository root, with `uv`, Python 3.14, Node.js and pnpm available:

```sh
MOMO_DEV_DATA="$PWD/tmp_agent_output/momo-agent"
uv run --no-project --python 3.14 Apps/MacApp/Runtime/momo_agent.py init --data-dir "$MOMO_DEV_DATA"
uv run --no-project --python 3.14 Apps/MacApp/Runtime/momo_agent.py prepare --data-dir "$MOMO_DEV_DATA"
```

`init` creates a private data directory and a stable workspace, assistant and
instance identity. Repeating it does not rotate credentials or overwrite user
configuration. A nonempty directory without a valid MoMo identity is refused.
The default location, when `--data-dir` is omitted, is
`~/Library/Application Support/MoMoAgent/Agent`.

Configure `profile/config.yaml` in that data directory with an explicit model,
provider and (for a custom OpenAI-compatible provider) base URL. Store that
provider's credentials in the same directory's `profile/.env`; the launcher does
not inherit model keys from the launching shell.

```sh
uv run --no-project --python 3.14 Apps/MacApp/Runtime/momo_agent.py serve --data-dir "$MOMO_DEV_DATA"
```

This runs in the foreground and listens only on `127.0.0.1:8765`; choose a different
port at `init` if required. The API requires the private credential in `api-key`.
`connection.json` contains identities and the address, never the credential.
Use `status --data-dir "$MOMO_DEV_DATA"` in another terminal to read capabilities.
Terminate the foreground service explicitly; client exit does not terminate it.

`prepare` verifies the Python dependencies and prepares the Node runtime for DeepSeek Harness. Existing installations keep model settings and credentials in their original profile directory.

## Swift client

`Packages/MoMoAgentAgentClient` is a Foundation-only package for iOS/macOS, with
no Pi dependency. It exposes capabilities, submit, snapshot and explicit stop.
Callers must persist the operation and session IDs before submission. It never
automatically retries an ambiguous submission, nor sends stop when a local task
or view is cancelled. The `unknown` status is not successful completion.

The included developer probe reads the private connection files locally:

```sh
swift build --package-path Packages/MoMoAgentAgentClient
swift run --package-path Packages/MoMoAgentAgentClient momo-agent-probe capabilities "$MOMO_DEV_DATA"
# submit DATA_DIR SESSION_ID OPERATION_UUID INPUT
# status DATA_DIR RUN_ID
# stop DATA_DIR RUN_ID
```

The HTTP client permits HTTPS, or loopback HTTP for local development, and refuses
redirects. Endpoint credentials are supplied out of band; no query-string keys.
SSE, history fallback after run retention expires, approvals, the persistent phone
outbox and the phone composition switch remain later migration work.

## Verification

```sh
uv run --no-project --python 3.14 -m unittest discover -s Tests/AgentRuntime -v
swift test --package-path Packages/MoMoAgentAgentClient
```

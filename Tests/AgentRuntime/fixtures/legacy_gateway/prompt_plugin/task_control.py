"""Conversation-level controls over the existing authenticated local task API."""
import json
from pathlib import Path
import urllib.error
import urllib.parse
import urllib.request
import uuid

DESCRIPTION = "Inspect, update or stop work in this shared conversation when the current user asks. Inspect first; use exact IDs/generation, never infer them. Ask the user if the target is ambiguous. A question about progress is not permission to change or cancel work. This tool cannot approve permissions or answer a pending confirmation."
SCHEMA = {
    "name": "conversation_task", "description": DESCRIPTION,
    "parameters": {"type": "object", "additionalProperties": False,
        "properties": {
            "action": {"type": "string", "enum": ["inspect", "update", "stop"]},
            "after": {"type": "integer", "minimum": 0, "description": "Inspection cursor; follow next_cursor while has_more is true."},
            "work_id": {"type": "string"}, "run_id": {"type": "string"},
            "generation": {"type": "integer", "minimum": 0},
            "message": {"type": "string", "description": "For update: the user's requested adjustment, without invented instructions."}
        }, "required": ["action"]}
}


def control(data, args, session_id):
    if not isinstance(args, dict): raise ValueError("Invalid task control arguments")
    from momo_agent import read_connection
    connection = read_connection(Path(data))
    token = (Path(data) / "api-key").read_text().strip()

    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            return None

    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    def request(path, body=None):
        payload = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(connection["base_url"] + path, data=payload,
            headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
        with opener.open(req, timeout=10) as response:
            return json.load(response)

    if not session_id or set(args) - set(SCHEMA["parameters"]["properties"]):
        raise ValueError("Invalid task control context")
    action = args.get("action")
    if action == "inspect":
        after = args.get("after", 0)
        if type(after) is not int or after < 0: raise ValueError("Invalid cursor")
        return request(f"/momo/v1/conversation/runs?after={after}&limit=50")
    if action not in ("update", "stop"): raise ValueError("Invalid action")
    work, run, generation = args.get("work_id"), args.get("run_id"), args.get("generation")
    if not isinstance(work, str) or not work or not isinstance(run, str) or not run or type(generation) is not int or generation < 0:
        raise ValueError("Inspect work and supply its exact work_id, run_id and generation")
    snapshot = request("/v1/runs/" + urllib.parse.quote(run, safe=""))
    if snapshot.get("work_id") != work or (snapshot.get("execution_generation") or 0) != generation:
        return {"error": "stale_target", "message": "Inspect again; no work was changed."}
    if snapshot.get("execution_session_id") == session_id:
        return {"error": "current_turn", "message": "Target the earlier work, not the reply handling this request."}
    # One user turn has a distinct native session. Retries of the same adjustment
    # in that turn reuse one receipt, including a timeout after server acceptance.
    operation = str(uuid.uuid5(uuid.NAMESPACE_URL, session_id + json.dumps(args, sort_keys=True, ensure_ascii=False)))
    if action == "stop":
        return request("/momo/v1/conversation/work/" + urllib.parse.quote(work, safe="") + "/cancel",
            dict(operation_id=operation, execution_generation=generation, target_run_id=run))
    message = args.get("message")
    if not isinstance(message, str) or not message.strip() or len(message.encode()) > 16_384:
        raise ValueError("Invalid adjustment message")
    return request("/momo/v1/conversation/messages", dict(operation_id=operation, content=message,
        intent="steer", work_id=work, target_run_id=run, execution_generation=generation))


def handle(args, **_kwargs):
    from hermes_constants import get_hermes_home
    from gateway.session_context import get_session_env
    try:
        result = control(get_hermes_home().parent, args, get_session_env("HERMES_SESSION_ID", ""))
    except urllib.error.HTTPError as error:
        result = {"error": "task_control_refused", "status": error.code,
                  "message": "Inspect the current state. Do not retry as a new task or claim the change succeeded."}
    except (OSError, ValueError):
        result = {"error": "task_control_unavailable", "message": "Unable to confirm this operation; inspect before retrying."}
    return json.dumps(result, ensure_ascii=False)


def register(ctx):
    ctx.register_tool(name="conversation_task", toolset="momoagent_tasks", schema=SCHEMA,
                      handler=handle, description=DESCRIPTION)

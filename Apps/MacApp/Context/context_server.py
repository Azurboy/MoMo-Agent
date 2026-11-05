"""Authenticated source sync plus restricted transcript runs in the native Hermes profile."""
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import logging
from pathlib import Path
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from context_store import ContextStore, Conflict
from hermes_memory import HermesMemory
import transcript_ingestion
import memory_review
import recording_summary
from life_illustrations import LifeIllustrations
from health_store import read_health, sync_health
from phone_sources import read_phone_sources, sync_phone_source


class ContextService:
    def __init__(self, data, connection):
        self.data = Path(data)
        self.directory = self.data / "context"
        self.connection = connection
        self.key = (self.data / "api-key").read_text().strip()
        self.memory = HermesMemory(self.data / "hermes")
        self.stopped = threading.Event()
        self.next_dispatch = time.monotonic() + transcript_ingestion.INTERVAL
        store = ContextStore(self.directory); store.close()
        illustrations = LifeIllustrations(self.data); illustrations.recover(); illustrations.close()
        service = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass  # Do not put personal source content or credentials into access logs.

            def respond(self, code, body):
                encoded = json.dumps(body, ensure_ascii=False).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(encoded)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(encoded)

            def handle_request(self):
                supplied = self.headers.get("Authorization", "")
                if not hmac.compare_digest(supplied.encode(), ("Bearer " + service.key).encode()):
                    self.respond(401, {"error": {"code": "unauthorized", "message": "Invalid connection credential"}})
                    return
                store = ContextStore(service.directory)
                illustrations = None
                try:
                    url = urllib.parse.urlsplit(self.path)
                    query = urllib.parse.parse_qs(url.query)
                    after = query.get("after", [""])[0]
                    limit = int(query.get("limit", ["100"])[0])
                    if url.path.startswith('/v1/life-illustrations/'):
                        illustrations = LifeIllustrations(service.data)
                        illustrations.reconcile(store)
                        from life_illustration_generator import CodexIllustrationGenerator
                        availability = CodexIllustrationGenerator(service.data).availability()
                        suffix = url.path.removeprefix('/v1/life-illustrations/')
                        if self.command == 'POST':
                            size = int(self.headers.get('Content-Length', '0'))
                            if not 0 < size <= 4096:
                                self.respond(413, {'error': {'code': 'body_too_large'}}); return
                            body = json.loads(self.rfile.read(size))
                            if suffix == 'settings':
                                result = illustrations.update_settings(body, availability)
                            elif suffix == 'delete':
                                result = illustrations.delete(body['id'])
                            else:
                                self.respond(404, {'error': {'code': 'not_found'}}); return
                        elif suffix == 'settings':
                            result = illustrations.settings(availability)
                        elif suffix == 'manifest':
                            result = illustrations.manifest(query.get('cursor', ['0'])[0], limit)
                            if not availability['supported']:
                                result = dict(items=[], next_cursor=query.get('cursor', ['0'])[0], has_more=False)
                        elif suffix.startswith('assets/'):
                            if not availability['supported']:
                                self.respond(404, {'error': {'code': 'not_found'}}); return
                            raw = illustrations.asset(suffix.removeprefix('assets/'))
                            self.send_response(200)
                            self.send_header('Content-Type', 'image/png')
                            self.send_header('Content-Length', str(len(raw)))
                            self.send_header('Cache-Control', 'private, no-store')
                            self.end_headers(); self.wfile.write(raw); return
                        else:
                            self.respond(404, {'error': {'code': 'not_found'}}); return
                        self.respond(200, result); return
                    if self.command == "POST":
                        size = int(self.headers.get("Content-Length", "0"))
                        if not 0 < size <= 8_000_000:
                            self.respond(413, {"error": {"code": "body_too_large", "message": "Source exceeds 8 MB; nothing was truncated or accepted"}})
                            return
                        body = json.loads(self.rfile.read(size))
                        if url.path == "/v1/sources":
                            result = store.sync_source(body)
                            service.notify_proactive_ingest()
                        elif url.path == "/v1/health":
                            result = sync_health(store, body)
                        elif url.path == "/v1/phone-sources":
                            result = sync_phone_source(store, body)
                        elif url.path == "/v1/summaries":
                            result = recording_summary.enqueue(store, body)
                        elif url.path == "/v1/memories/forget":
                            result = service.memory.forget(body["id"])
                        else:
                            self.respond(404, {"error": {"code": "not_found", "message": "Unknown MoMo route"}}); return
                    elif url.path == "/v1/summaries":
                        result = recording_summary.read(store, query['id'][0])
                    elif url.path == "/v1/health":
                        result = read_health(store, after, limit=min(limit, 50))
                    elif url.path == "/v1/phone-sources":
                        result = read_phone_sources(store, query.get("kind", [""])[0], after, limit=min(limit, 100))
                    elif url.path == "/v1/memories":
                        revision = query.get("revision", [None])[0]
                        result = service.memory.list(after, limit, int(revision) if revision is not None else None)
                    elif url.path == "/v1/sources":
                        summarize = query.get("summarize", ["0"])[0] == "1"
                        result = store.list_sources(after, min(limit, 200), summarize=summarize, include_organization=False)
                        for item in result["items"]:
                            item["summary"] = item.pop("recorded_summary", None); item["organization"] = None
                    elif url.path == "/v1/source":
                        source_limit = min(int(query.get("limit", ["12000"])[0]), 24_000)
                        result = store.read_source(query["source_id"][0], query["revision"][0], int(query.get("offset", ["0"])[0]), source_limit)
                    elif url.path == "/v1/status":
                        engine = service.active_engine()
                        result = {"application": "MoMoAgent", "workspace_id": connection["workspace_id"],
                                  "engine": engine,
                                  "revision": store.revision, "source_sync": True,
                                  "memory_writer": "SuperAgent" if engine == "superagent" else "Hermes",
                                  "memory_pending": store.db.execute("SELECT COUNT(*) FROM jobs WHERE state IN ('pending','running')").fetchone()[0],
                                  "memory_needs_review": store.db.execute("SELECT COUNT(*) FROM jobs WHERE state='needs_review'").fetchone()[0]}
                        result['memory_review'] = memory_review.status(store)
                    else:
                        self.respond(404, {"error": {"code": "not_found", "message": "Unknown MoMo route"}}); return
                    self.respond(200, result)
                except Conflict as error:
                    self.respond(409, {"error": {"code": "revision_conflict", "message": str(error)}})
                except FileNotFoundError:
                    self.respond(404, {'error': {'code': 'not_found', 'message': 'Illustration is unavailable'}})
                except (ValueError, KeyError, TypeError) as error:
                    self.respond(400, {"error": {"code": "invalid_source", "message": str(error)}})
                except Exception as error:
                    logging.error("MoMo context transaction failed: %s", type(error).__name__)
                    self.respond(500, {"error": {"code": "storage_failure", "message": "MoMo context could not be committed"}})
                finally:
                    store.close()
                    if illustrations:
                        illustrations.close()

            do_GET = handle_request
            do_POST = handle_request

        address = urllib.parse.urlsplit(connection["data_url"])
        self.server = ThreadingHTTPServer(("127.0.0.1", address.port), Handler)
        self.server.daemon_threads = True
        self.threads = [threading.Thread(target=self.server.serve_forever, daemon=True, name="momo-sync"),
                        threading.Thread(target=self.dispatch, daemon=True, name="momo-transcript-dispatch"),
                        threading.Thread(target=self.dispatch_summaries, daemon=True, name="momo-summary-dispatch")]
        self.threads.append(threading.Thread(target=self.dispatch_illustrations, daemon=True, name='momo-life-illustrations'))

    def start(self):
        for thread in self.threads:
            thread.start()

    def close(self):
        self.stopped.set()
        self.server.shutdown(); self.server.server_close()
        for thread in self.threads:
            thread.join(timeout=6)

    def request(self, path, body=None, operation=None):
        headers = {"Authorization": "Bearer " + self.key, "Content-Type": "application/json",
                   "X-Hermes-Session-Key": "momo-memory:" + self.connection["assistant_id"]}
        if operation:
            headers["Idempotency-Key"] = operation
        request = urllib.request.Request(self.connection["base_url"] + path,
            data=json.dumps(body, sort_keys=True).encode() if body is not None else None, headers=headers)
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(request, timeout=5) as response:
            return json.load(response)

    def active_engine(self) -> str:
        path = self.data / "runtime/engine.json"
        if not path.is_file():
            return "superagent"
        try:
            value = json.loads(path.read_text(encoding="utf-8")).get("engine")
            return "hermes" if value == "hermes" else "superagent"
        except Exception:
            return "superagent"

    def notify_proactive_ingest(self) -> None:
        if self.active_engine() != "superagent":
            return

        def _ping() -> None:
            try:
                self.request("/momo/v1/proactive/ingest", {"origin": "source_sync"})
            except Exception:
                pass

        threading.Thread(target=_ping, daemon=True).start()

    def dispatch(self):
        # Only durable admission/reconciliation. Active runtime owns model calls, tools and execution.
        while not self.stopped.wait(2):
            store = ContextStore(self.directory)
            try:
                review = store.db.execute("SELECT * FROM memory_reviews WHERE state='running' OR (state='pending' AND first_attempt IS NOT NULL) ORDER BY rowid LIMIT 1").fetchone()
                if review:
                    self.advance_review(store, review)
                    continue
                now = time.time()
                admit = time.monotonic() >= self.next_dispatch and memory_review.chat_idle(self.data, now)
                job = transcript_ingestion.next_job(store, now, False)
                if not job and admit:
                    memory_review.recover_empty_legacy(store, self.data / 'hermes')
                    review = memory_review.next_review(store, self.data, now)
                    # A due Dream gets a turn even with continuous recording arrivals.
                    job = transcript_ingestion.next_job(store, now, True)
                    if review:
                        self.next_dispatch = time.monotonic() + transcript_ingestion.INTERVAL
                        self.advance_review(store, review)
                        continue
                if job:
                    if job["state"] == "pending":
                        self.next_dispatch = time.monotonic() + transcript_ingestion.INTERVAL
                    self.advance_job(store, job)
            except Exception as error:
                logging.error("MoMo memory dispatch transaction failed: %s", type(error).__name__)
            finally:
                store.close()

    def dispatch_summaries(self):
        while not self.stopped.wait(2):
            store = ContextStore(self.directory)
            try:
                job = recording_summary.next_job(store)
                if job:
                    recording_summary.advance(store, job, self.request)
            except Exception as error:
                logging.error('MoMo summary dispatch failed: %s', type(error).__name__)
            finally:
                store.close()

    def dispatch_illustrations(self):
        # A separate worker and idle admission keep image work out of chat and summary queues.
        while not self.stopped.wait(30):
            store = ContextStore(self.directory)
            illustrations = LifeIllustrations(self.data)
            try:
                from life_illustration_generator import CodexIllustrationGenerator
                generator = CodexIllustrationGenerator(self.data)
                if generator.availability()['supported']:
                    illustrations.scan(store)
                    while not self.stopped.is_set() and memory_review.chat_idle(self.data, time.time()):
                        if not illustrations.advance(generator, store):
                            break
                else:
                    illustrations.reconcile(store)
            except Exception as error:
                logging.error('MoMo illustration dispatch failed: %s', type(error).__name__)
            finally:
                illustrations.close(); store.close()

    def advance_job(self, store, job):
        try:
            if job["run_id"]:
                snapshot = self.request("/v1/runs/" + urllib.parse.quote(job["run_id"], safe=""))
            else:
                batch = transcript_ingestion.prepare(store, job)
                if not batch["passages"]:
                    transcript_ingestion.finish(store, job)
                    return
                first, deadline = job["first_attempt"], job["replay_before"]
                if first is None:
                    guarantee = self.request("/v1/capabilities")["features"]["runs_idempotency"]
                    if not guarantee.get("durable") or not guarantee.get("supported") or guarantee.get("retention_seconds", 0) <= 120:
                        raise Conflict("Hermes lacks durable transcript admission")
                    first = time.time(); deadline = first + guarantee["retention_seconds"] - 60
                    claimed = store.db.execute("UPDATE jobs SET first_attempt=?,replay_before=? WHERE id=? AND state='pending'",
                                               (first, deadline, job["id"])).rowcount
                    if not claimed:
                        return  # A source update superseded this unadmitted batch.
                if time.time() >= deadline:
                    raise Conflict("Memory admission receipt expired; inspect the original run")
                prompt = transcript_ingestion.prompt(batch)
                snapshot = self.request("/v1/runs", {"input": prompt, "session_id": "momo-transcript-" + job["id"]}, job["id"])
                store.db.execute("UPDATE jobs SET run_id=?,state='running',error=NULL WHERE id=? AND state='pending'",
                                 (snapshot["run_id"], job["id"]))
                snapshot = self.request("/v1/runs/" + urllib.parse.quote(snapshot["run_id"], safe=""))
            if snapshot.get("session_id") != "momo-transcript-" + job["id"] or not snapshot.get("run_id") or (job["run_id"] and snapshot["run_id"] != job["run_id"]):
                raise Conflict("Memory task identity mismatch")
            status = snapshot["status"]
            if status == "completed":
                try:
                    receipt = memory_review.outcome(self.data / 'hermes', snapshot['session_id'], snapshot.get('output'))
                except Conflict as error:
                    if memory_review.retry_completed(store, 'jobs', job, error): return
                    raise
                transcript_ingestion.finish(store, job, receipt)
            elif status == 'failed' and memory_review.retry_completed(store, 'jobs', job, 'Native review failed'):
                return
            elif status not in {"started", "queued", "running", "stopping"}:
                raise Conflict("Memory execution needs review: " + status)
        except Exception as error:
            review = isinstance(error, Conflict) or isinstance(error, urllib.error.HTTPError) and error.code in {400, 403, 404, 409, 410, 422}
            # Keep the same admission key after a transient failure or lost acknowledgement.
            store.db.execute("UPDATE jobs SET state=CASE WHEN ? THEN 'needs_review' ELSE state END,error=? WHERE id=? AND state IN ('pending','running')",
                             (int(review), str(error)[:500], job["id"]))

    def advance_review(self, store, job):
        session = 'momo-review-' + job['id']
        try:
            if job['run_id']:
                snapshot = self.request('/v1/runs/' + urllib.parse.quote(job['run_id'], safe=''))
            else:
                deadline = job['replay_before']
                if job['first_attempt'] is None:
                    guarantee = self.request('/v1/capabilities')['features']['runs_idempotency']
                    if not guarantee.get('durable') or not guarantee.get('supported') or guarantee.get('retention_seconds', 0) <= 120:
                        raise Conflict('Hermes lacks durable memory admission')
                    first = time.time(); deadline = first + guarantee['retention_seconds'] - 60
                    store.db.execute("UPDATE memory_reviews SET first_attempt=?,replay_before=? WHERE id=?", (first,deadline,job['id']))
                if time.time() >= deadline:
                    raise Conflict('Memory review admission receipt expired; inspect the original run')
                snapshot = self.request('/v1/runs', {'input': memory_review.prompt(job), 'session_id': session}, job['id'])
                store.db.execute("UPDATE memory_reviews SET run_id=?,state='running',error=NULL WHERE id=?", (snapshot['run_id'],job['id']))
                snapshot = self.request('/v1/runs/' + urllib.parse.quote(snapshot['run_id'], safe=''))
            if snapshot.get('session_id') != session or not snapshot.get('run_id') or (job['run_id'] and snapshot['run_id'] != job['run_id']):
                raise Conflict('Memory review identity mismatch')
            if snapshot['status'] == 'completed':
                try:
                    receipt = memory_review.outcome(self.data / 'hermes', session, snapshot.get('output'))
                except Conflict as error:
                    if memory_review.retry_completed(store, 'memory_reviews', job, error): return
                    raise
                memory_review.finish(store, job, receipt, self.data / 'hermes')
            elif snapshot['status'] == 'failed' and memory_review.retry_completed(store, 'memory_reviews', job, 'Native review failed'):
                return
            elif snapshot['status'] not in {'started','queued','running','stopping'}:
                raise Conflict('Memory review execution needs review: ' + snapshot['status'])
        except Exception as error:
            review = isinstance(error, Conflict) or isinstance(error, urllib.error.HTTPError) and error.code in {400,403,404,409,410,422}
            store.db.execute("UPDATE memory_reviews SET state=CASE WHEN ? THEN 'needs_review' ELSE state END,error=? WHERE id=? AND state IN ('pending','running')",
                             (int(review),str(error)[:500],job['id']))

"""Kill real recording/receive workers at durable boundaries, then audit ordinary recovery."""

from __future__ import annotations

import argparse
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import selectors
import signal
import sqlite3
import subprocess
import sys
import time
import uuid
import wave


CASES = ("J08-a", "J08-b", "J08-c", "J08-d", "J08-e", "J08-f")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def save(path: Path, value: object) -> None:
    with path.open("x", encoding="utf-8") as output:
        json.dump(value, output, ensure_ascii=False, indent=2)
        output.write("\n")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for part in iter(lambda: stream.read(65536), b""):
            digest.update(part)
    return digest.hexdigest()


def source_version(repo: Path) -> str:
    paths = [repo / "Packages/MoMoAgentKit/Package.swift"]
    for directory in ("Packages/MoMoAgentKit/Sources/MoMoContracts",
                      "Packages/MoMoAgentKit/Sources/MoMoArchive",
                      "Packages/MoMoAgentKit/Sources/MoMoRecording",
                      "Tools/CrashRecoveryReplay"):
        paths.extend(path for path in (repo / directory).rglob("*")
                     if path.is_file() and ".build" not in path.parts and "__pycache__" not in path.parts)
    digest = hashlib.sha256()
    for path in sorted(paths):
        digest.update(str(path.relative_to(repo)).encode())
        digest.update(b"\0")
        digest.update(bytes.fromhex(sha256(path)))
    return digest.hexdigest()


def run_phase(executable: Path, case: str, root: Path, phase: str) -> dict:
    started = time.monotonic()
    result = subprocess.run([str(executable), phase, str(root), case], stdin=subprocess.DEVNULL,
                            capture_output=True, text=True, timeout=45, check=False)
    (root / f"{phase}.stdout.log").write_text(result.stdout, encoding="utf-8")
    (root / f"{phase}.stderr.log").write_text(result.stderr, encoding="utf-8")
    require(result.returncode == 0, f"{case}/{phase}: worker exit {result.returncode}; see logs")
    report = json.loads(result.stdout.strip())
    require(report.get("phase") == phase, f"{case}/{phase}: missing structured phase report")
    report["parentElapsedSeconds"] = time.monotonic() - started
    save(root / f"{phase}.json", report)
    return report


def kill_at_boundary(executable: Path, case: str, root: Path) -> dict:
    started = time.monotonic()
    with (root / "receive.stderr.log").open("xb") as stderr:
        process = subprocess.Popen([str(executable), "receive", str(root), case],
                                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=stderr)
        require(process.stdout is not None, "Worker stdout is unavailable")
        try:
            line = b""
            event_deadline = time.monotonic() + 30
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                while not line.endswith(b"\n"):
                    remaining = event_deadline - time.monotonic()
                    require(remaining > 0 and bool(selector.select(timeout=remaining)), f"{case}: boundary event timed out")
                    part = os.read(process.stdout.fileno(), 4096)
                    require(bool(part), f"{case}: worker closed stdout before the boundary")
                    line += part
                    require(len(line) <= 16384, f"{case}: oversized boundary event")
            (root / "receive.stdout.log").write_bytes(line)
            event = json.loads(line)
            require(event.get("event") == "boundary" and event.get("boundary") == case,
                    f"{case}: wrong boundary event: {event}")
            require(event.get("processID") == process.pid, f"{case}: boundary came from a different process")
            stop_deadline = time.monotonic() + 5
            while True:
                observed_pid, wait_status = os.waitpid(process.pid, os.WUNTRACED | os.WNOHANG)
                if observed_pid:
                    if not os.WIFSTOPPED(wait_status):
                        process.returncode = os.waitstatus_to_exitcode(wait_status)
                        raise AssertionError(f"{case}: worker exited before SIGSTOP")
                    require(os.WSTOPSIG(wait_status) == signal.SIGSTOP, f"{case}: wrong stop signal")
                    break
                require(time.monotonic() < stop_deadline, f"{case}: worker did not enter SIGSTOP")
                time.sleep(0.01)
            os.kill(process.pid, signal.SIGKILL)
            status = process.wait(timeout=10)
            require(status == -signal.SIGKILL, f"{case}: worker did not die from the parent's SIGKILL")
            result = {"boundary": case, "processID": process.pid, "observedStopSignal": int(signal.SIGSTOP),
                      "sentSignal": int(signal.SIGKILL), "returncode": status,
                      "elapsedSeconds": time.monotonic() - started}
            save(root / "kill.json", result)
            return result
        finally:
            # Only this harness-owned worker can be stopped here. Failure paths must not leave SIGSTOP processes.
            if process.poll() is None:
                process.kill()
                process.wait(timeout=10)
            process.stdout.close()


def read_database(path: Path, queries: dict[str, str]) -> dict:
    require(path.is_file() and not path.is_symlink(), f"Missing regular database: {path}")
    connection = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True)
    try:
        connection.execute("PRAGMA query_only=ON")
        require(connection.execute("PRAGMA integrity_check").fetchall() == [("ok",)], "SQLite integrity failure")
        require(connection.execute("PRAGMA foreign_key_check").fetchall() == [], "SQLite foreign key failure")
        return {name: connection.execute(query).fetchall() for name, query in queries.items()}
    finally:
        connection.close()


def confined_file(root: Path, relative: str) -> Path:
    path = root / relative
    require(not Path(relative).is_absolute() and ".." not in Path(relative).parts, "Fixture path escaped its case")
    for component in (path, *path.parents):
        if component == root:
            break
        require(not component.is_symlink(), f"Unexpected symlink: {component}")
    return path


def check_audio(path: Path, manifest: dict) -> dict:
    require(path.is_file() and not path.is_symlink(), f"Missing regular audio: {path}")
    require(path.stat().st_size == manifest["byteCount"], "Audio length differs from immutable manifest")
    digest = sha256(path)
    require(digest == manifest["audioSHA256"], "Audio SHA-256 differs from immutable manifest")
    with wave.open(str(path), "rb") as audio:
        require(audio.getnframes() == manifest["decodedFrameCount"], "Decoded WAV frame count changed")
        require(audio.getframerate() == manifest["sampleRate"] and audio.getnchannels() == manifest["channels"],
                "Decoded WAV format changed")
        require(audio.getsampwidth() == 2, "Fixture is no longer PCM16")
        decoded_digest = hashlib.sha256(audio.readframes(audio.getnframes())).hexdigest()
    return {"sha256": digest, "decodedPCMSHA256": decoded_digest, "frames": manifest["decodedFrameCount"]}


def snapshot(case: str, root: Path, phase: str, expected_rows: int, acknowledged: bool) -> dict:
    fixture = json.loads((root / "fixture.json").read_bytes())
    envelope = fixture["envelope"]
    manifest_data = base64.b64decode(envelope["manifestData"], validate=True)
    require(hashlib.sha256(manifest_data).hexdigest() == envelope["manifestSHA256"], "Fixture manifest hash mismatch")
    manifest = json.loads(manifest_data)
    chunk_id = manifest["chunkID"]
    local_date = datetime.fromisoformat(manifest["wallClockAnchor"]).astimezone(
        timezone(timedelta(seconds=manifest["timezoneOffset"]))).date().isoformat()
    phone_audio_path = f"phone/Documents/recordings/{local_date}/{manifest['sessionID']}/audio/{chunk_id}.wav"
    phone = read_database(root / "phone/Library/Application Support/MoMoAgent/archive.sqlite", {
        "counts": "SELECT (SELECT COUNT(*) FROM sessions),(SELECT COUNT(*) FROM epochs),(SELECT COUNT(*) FROM chunks),(SELECT COUNT(*) FROM transcription_jobs),(SELECT COUNT(*) FROM receipt_outbox)",
        "library": "SELECT value FROM metadata WHERE key='library_instance_id'",
        "chunks": "SELECT id,session_id,epoch_id,manifest,manifest_hash,audio_hash,relative_path,receipt_applied,retention FROM chunks",
        "jobs": "SELECT id,chunk_id,state FROM transcription_jobs",
        "receipts": "SELECT id,chunk_id,payload,sent FROM receipt_outbox",
    })
    require(phone["counts"] == [(expected_rows,) * 5], f"{case}/{phase}: partial or duplicated receive transaction")
    require(phone["library"] == [(fixture["libraryInstanceID"],)], "Archive library identity changed")
    receipts = []
    for chunk in phone["chunks"]:
        require(chunk[:3] == (chunk_id, manifest["sessionID"], manifest["epochID"]), "Stored source identity changed")
        require(chunk[3] == manifest_data and chunk[4:6] == (envelope["manifestSHA256"], manifest["audioSHA256"]),
                "Stored immutable manifest differs")
        require("phone/" + chunk[6] == phone_audio_path, "Archive path differs from the local-date/source-ID contract")
        require(chunk[7] == int(acknowledged) and chunk[8] == "present", "Archive receipt or retention state differs")
    for job in phone["jobs"]:
        require(job == (chunk_id, chunk_id, "pending"), "Receive created a different or duplicate analysis job")
    for receipt_id, receipt_chunk, payload, sent in phone["receipts"]:
        receipt = json.loads(payload)
        require(receipt_id == receipt["receiptID"] and receipt_chunk == chunk_id == receipt["chunkID"], "Receipt identity differs")
        require(receipt["audioSHA256"] == manifest["audioSHA256"] and receipt["manifestSHA256"] == envelope["manifestSHA256"], "Receipt hashes differ")
        require(receipt["receiverDeviceID"] == fixture["receiverDeviceID"] and receipt["libraryInstanceID"] == fixture["libraryInstanceID"], "Receipt receiver differs")
        require(sent == int(acknowledged), "Receipt outbox changed before ReceiptApplied")
        receipts.append(receipt)

    watch = read_database(root / "watch/recording.sqlite", {
        "chunks": "SELECT id,state,manifest_hash FROM chunks",
        "receipts": "SELECT payload,application FROM receipts",
    })
    require(watch["chunks"] == [(chunk_id, "removed" if acknowledged else "ready", envelope["manifestSHA256"])],
            "Watch source was lost, prematurely removed, or resurrected")
    require(len(watch["receipts"]) == int(acknowledged), "Unexpected sender receipt count")
    applications = []
    for payload, application in watch["receipts"]:
        receipt, applied = json.loads(payload), json.loads(application)
        require(receipts == [receipt] and applied["receipt"] == receipt, "Sender confirmation differs from phone outbox")
        applications.append(applied)

    source = confined_file(root, fixture["watchAudioRelativePath"])
    target = confined_file(root, phone_audio_path)
    original = check_audio(root / "input" / f"{chunk_id}.wav", manifest)
    if acknowledged:
        require(not source.exists(), "Sender audio remains after acknowledged cleanup")
    else:
        require(check_audio(source, manifest) == original, "Unacknowledged source changed")
    target_expected = expected_rows == 1 or (case == "J08-c" and phase == "after-kill")
    if target_expected:
        require(check_audio(target, manifest) == original, "Phone audio differs from original")
        require(Path(str(target) + ".manifest.json").read_bytes() == manifest_data, "Audio sidecar changed")
    else:
        require(not target.exists(), "Phone audio exists before the move boundary")

    inbox = root / "phone/Library/Application Support/MoMoAgent/Inbox"
    entries = [item for item in inbox.iterdir() if item.suffix != ".incomplete"]
    retained = list(inbox.glob("*.incomplete"))
    expected_inbox = 1 if phase == "after-kill" else 0
    require(len(entries) == expected_inbox, f"{case}/{phase}: unexpected inbox entry count")
    require(len(retained) == int(case == "J08-b" and phase != "after-kill"), "Interrupted handoff was not retained separately")
    for item in entries + retained:
        require(not item.is_symlink() and item.is_dir(), "Inbox entry is not a normal directory")
        require((item / "manifest.json").read_bytes() == manifest_data, "Incomplete inbox lost its manifest")
        require((item / "manifest.sha256").read_text() == envelope["manifestSHA256"], "Incomplete inbox lost its hash")
        require(not (item / "audio").exists(), "Unexpected audio location at the selected boundary")
    first_delivery = root / "Delivery/first.wav"
    require(first_delivery.exists() == (case == "J08-b"), "The original temporary handoff moved at the wrong boundary")
    if first_delivery.exists():
        require(check_audio(first_delivery, manifest) == original, "Unmoved transport copy changed")
    return {"phase": phase, "phoneRows": list(phone["counts"][0]), "libraryInstanceID": fixture["libraryInstanceID"],
            "chunkID": chunk_id, "sessionID": manifest["sessionID"], "manifestSHA256": envelope["manifestSHA256"],
            "audio": original, "inboxCount": len(entries), "retainedIncompleteCount": len(retained), "watchState": watch["chunks"][0][1],
            "receipts": receipts, "receiptApplications": applications,
            "sqliteIntegrity": "ok", "foreignKeyErrors": 0}


def run_case(executable: Path, case: str, root: Path) -> dict:
    root.mkdir()
    run_phase(executable, case, root, "prepare")
    killed = kill_at_boundary(executable, case, root)
    if case in ("J08-a", "J08-e", "J08-f"):
        return finish_sender_case(executable, case, root, killed)
    before = snapshot(case, root, "after-kill", int(case == "J08-d"), False)
    save(root / "after-kill.json", before)
    recovered = run_phase(executable, case, root, "recover")
    after = snapshot(case, root, "after-recovery", 1, False)
    save(root / "after-recovery.json", after)
    require(after["receipts"] == [recovered["receipt"]], "API and SQLite recovered receipts differ")
    if case == "J08-d":
        require(before["receipts"] == after["receipts"], "Crash recovery replaced the committed receipt")
    duplicate = run_phase(executable, case, root, "duplicate")
    verified = run_phase(executable, case, root, "verify")
    final = snapshot(case, root, "after-final-restart", 1, True)
    save(root / "after-final-restart.json", final)
    require(after["receipts"] == final["receipts"] == [duplicate["receipt"]], "Another restart changed the receipt")
    require(final["receiptApplications"] == [duplicate["applied"]] == [verified["applied"]], "ReceiptApplied replay changed identity")
    phase_ids = [killed["processID"], recovered["processID"], duplicate["processID"], verified["processID"]]
    require(len(set(phase_ids)) == 4, "Recovery did not use independent process lifetimes")
    return {"case": case, "passed": True, "workerProcessIDs": phase_ids,
            "receiptID": final["receipts"][0]["receiptID"], "receiptAppliedMessageID": verified["applied"]["messageID"],
            "initialRecoveryState": "awaitingRedelivery" if case == "J08-b" else recovered["inbox"][0]["state"],
            "retainedIncompleteCount": final["retainedIncompleteCount"], "finalInboxCount": final["inboxCount"]}


def decode_aac(path: Path, output: Path) -> dict:
    require(not output.exists(), "Decoded evidence output already exists")
    decoded = subprocess.run(["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16", str(path), str(output)],
                             capture_output=True, timeout=15, check=False)
    output.with_suffix(".stderr.log").write_bytes(decoded.stderr)
    if decoded.returncode:
        return {"decodable": False, "decoderExit": decoded.returncode}
    with wave.open(str(output), "rb") as audio:
        require(audio.getframerate() == 16000 and audio.getnchannels() == 1 and audio.getsampwidth() == 2,
                "Independent AAC decode returned an unexpected format")
        return {"decodable": True, "frames": audio.getnframes(),
                "decodedPCMSHA256": hashlib.sha256(audio.readframes(audio.getnframes())).hexdigest()}


def checked_manifest(envelope: dict) -> tuple[bytes, dict]:
    data = base64.b64decode(envelope["manifestData"], validate=True)
    require(hashlib.sha256(data).hexdigest() == envelope["manifestSHA256"], "Manifest envelope hash mismatch")
    return data, json.loads(data)


def capture_snapshot(root: Path, phase: str, before: dict | None) -> dict:
    fixture = json.loads((root / "capture-fixture.json").read_bytes())
    envelope = fixture["envelope"]
    manifest_data, manifest = checked_manifest(envelope)
    database = read_database(root / "watch/recording.sqlite", {
        "chunks": "SELECT id,envelope,manifest_hash,state FROM chunks ORDER BY rowid",
        "receipts": "SELECT COUNT(*) FROM receipts",
        "events": "SELECT id,payload FROM capture_events ORDER BY rowid",
        "epochs": "SELECT id,session_id,device_id,ended FROM capture_epochs",
        "sessions": "SELECT id,intent FROM sessions",
    })
    require(database["receipts"] == [(0,)], "Unacknowledged AAC acquired a receipt")
    expected_intent = "recording" if before is None else "stopped"
    require(database["sessions"] == [(manifest["sessionID"], expected_intent)],
            "The old session must close on recovery without changing the pre-recovery ledger")
    prefix = database["chunks"][0]
    require(prefix[0] == manifest["chunkID"] and json.loads(prefix[1]) == envelope
            and prefix[2:] == (envelope["manifestSHA256"], "ready"), "Sealed prefix identity/state changed")
    original = root / "input/sealed.m4a"
    stored = root / "watch/CaptureReady" / manifest["chunkID"] / "audio"
    require(original.stat().st_size == stored.stat().st_size == manifest["byteCount"], "AAC prefix size changed")
    require(sha256(original) == sha256(stored) == manifest["audioSHA256"], "AAC prefix bytes changed")
    require((stored.parent / "manifest.json").read_bytes() == manifest_data, "Sealed prefix manifest changed")
    prefix_decode = decode_aac(stored, root / f"{phase}-sealed.wav")
    require(prefix_decode["decodable"] and prefix_decode["frames"] == manifest["decodedFrameCount"] == 16000,
            "Sealed AAC prefix did not independently decode to its exact frames")
    active = confined_file(root, fixture["activeAudioRelativePath"])
    draft_path = Path(str(active) + ".draft.json")
    pcm_path = Path(str(active) + ".pcm")
    if before is None:
        require(len(database["chunks"]) == 1, "Active AAC tail was indexed before sealing")
        require(active.is_file() and draft_path.is_file() and not Path(str(active) + ".sealed.json").exists(),
                "Boundary did not leave a real unsealed AAC container and its draft")
        draft_data = draft_path.read_bytes()
        draft = json.loads(draft_data)
        require(draft["startFrame"] == 16000 and draft["sequence"] == 1 and draft.get("closingFrameCount") is None,
                "Active AAC draft was already closing or lost its source position")
        active_hash, draft_hash = sha256(active), hashlib.sha256(draft_data).hexdigest()
        active_decode = decode_aac(active, root / "after-kill-active.wav")
        pcm_frames = pcm_path.stat().st_size // 2 if pcm_path.is_file() else 0
        pcm_hash = sha256(pcm_path) if pcm_path.is_file() else None
        tail_outcome = "still-open-at-SIGKILL"
    else:
        active_hash, draft_hash, active_decode = before["activeSHA256"], before["draftSHA256"], before["activeDecode"]
        pcm_frames, pcm_hash = before.get("pcmFrames", 0), before.get("pcmSHA256")
        draft = before["draft"]
        tail_rows = database["chunks"][1:]
        require(len(tail_rows) <= 1, "Crash tail created duplicate logical chunks")
        if tail_rows:
            _, recovered = checked_manifest(json.loads(tail_rows[0][1]))
            recovered_audio = root / "watch/CaptureReady" / recovered["chunkID"] / "audio"
            recovered_decode = decode_aac(recovered_audio, root / f"{phase}-recovered-tail.wav")
            require(recovered_decode["decodable"], "Recovered AAC tail is not independently decodable")
            if active_decode["decodable"]:
                require(0 < recovered["decodedFrameCount"] <= fixture["submittedFrames"] - 16000,
                        "Recovery claimed tail frames not independently decodable after SIGKILL")
                require(recovered["decodedFrameCount"] == active_decode["frames"] == recovered_decode["frames"]
                        and recovered["frames"] == {"start": 16000, "count": active_decode["frames"]}
                        and recovered["chunkID"] == draft["chunkID"] and recovered["audioSHA256"] == active_hash,
                        "Recovered AAC tail changed its identity/range/hash")
                require(sha256(recovered_audio) == active_hash and tail_rows[0][3] == "ready", "Recovered tail was lost")
                tail_outcome = "independently-proven-decoded-tail"
            else:
                require(0 < pcm_frames <= fixture["submittedFrames"] - 16000,
                        "Recovery claimed tail frames without either decodable AAC or PCM sidecar")
                require(recovered["decodedFrameCount"] == pcm_frames == recovered_decode["frames"]
                        and recovered["frames"] == {"start": 16000, "count": pcm_frames}
                        and recovered["chunkID"] == draft["chunkID"],
                        "PCM-recovered AAC tail changed its identity or frame range")
                require(sha256(recovered_audio) == recovered["audioSHA256"] and tail_rows[0][3] == "ready",
                        "PCM-recovered tail audio hash mismatch or not ready")
                require(not active.exists() and not pcm_path.exists() and not draft_path.exists(),
                        "PCM-recovered tail left stale active spool artifacts")
                tail_outcome = "recovered-from-pcm-sidecar"
        else:
            repair = root / "Encoding/Repair" / manifest["sessionID"] / manifest["epochID"] / active.name
            require(sha256(repair) == active_hash and sha256(Path(str(repair) + ".draft.json")) == draft_hash,
                    "Unprovable active AAC bytes/draft were not preserved unchanged in repair")
            require(not active.exists(), "Quarantined tail still occupies the active spool")
            tail_outcome = "unprovable-tail-preserved-in-repair"
    events = [json.loads(payload) for _, payload in database["events"]]
    require(events[0] == {"captureMark": {"_0": fixture["mark"]}}, "Persisted mark changed")
    recovered_tail_frames = 0
    if before and len(database["chunks"]) == 2:
        _, recovered_manifest = checked_manifest(json.loads(database["chunks"][1][1]))
        recovered_tail_frames = recovered_manifest["decodedFrameCount"]
    expected_end = 16000 + recovered_tail_frames
    require(database["epochs"] == [(manifest["epochID"], manifest["sessionID"], manifest["sourceDeviceID"], int(before is not None))],
            "Interrupted epoch lifecycle changed")
    if before:
        require(len(events) == 2 and "epochInterrupted" in events[1], "Recovery must preserve an interruption, never a proven final end")
        interruption = events[1]["epochInterrupted"]["_0"]
        require(interruption["sealedThroughFrame"] == expected_end and interruption["lastObservedFrame"] == fixture["mark"]["sourceFrame"]
                and interruption["reason"] == "interrupted", "Interruption claimed unproven capture coverage")
    else:
        require(len(events) == 1, "The killed writer emitted a final interruption event")
    return {"phase": phase, "prefixSHA256": manifest["audioSHA256"], "prefixDecode": prefix_decode,
            "activeSHA256": active_hash, "draftSHA256": draft_hash, "draft": draft, "activeDecode": active_decode,
            "pcmFrames": pcm_frames, "pcmSHA256": pcm_hash,
            "tailOutcome": tail_outcome, "sealedThroughFrame": expected_end,
            "events": events, "chunkCount": len(database["chunks"]), "sqliteIntegrity": "ok", "foreignKeyErrors": 0}


def receipt_snapshot(root: Path, case: str, phase: str) -> dict:
    fixture = json.loads((root / "fixture.json").read_bytes())
    manifest_data, manifest = checked_manifest(fixture["envelope"])
    confirmation = json.loads((root / "persisted-confirmation.json").read_bytes())
    receipt, applied = confirmation["receipt"], confirmation["applied"]
    acknowledged = phase != "after-kill"
    expired = phase == "after-final-restart"
    watch_state = "acknowledged" if case == "J08-e" and not acknowledged else "removed"
    watch = read_database(root / "watch/recording.sqlite", {
        "chunks": "SELECT id,state,envelope,manifest_hash FROM chunks",
        "receipts": "SELECT receipt_id,chunk_id,payload,application FROM receipts",
    })
    require(len(watch["chunks"]) == len(watch["receipts"]) == 1, "Sender duplicated or lost source/confirmation")
    chunk, control = watch["chunks"][0], watch["receipts"][0]
    require(chunk[:2] == (manifest["chunkID"], watch_state) and json.loads(chunk[2]) == fixture["envelope"]
            and chunk[3] == fixture["envelope"]["manifestSHA256"], "Sender ledger identity changed")
    require(control[:2] == (receipt["receiptID"], manifest["chunkID"]) and json.loads(control[2]) == receipt
            and json.loads(control[3]) == applied and applied["receipt"] == receipt, "Durable ReceiptApplied changed")
    phone = read_database(root / "phone/Library/Application Support/MoMoAgent/archive.sqlite", {
        "library": "SELECT value FROM metadata WHERE key='library_instance_id'",
        "chunks": "SELECT id,manifest,manifest_hash,audio_hash,relative_path,receipt_applied,retention FROM chunks",
        "jobs": "SELECT id,chunk_id,state,attempt_id FROM transcription_jobs",
        "receipts": "SELECT id,chunk_id,payload,sent FROM receipt_outbox",
        "sessions": "SELECT id,deleted,keep_audio FROM sessions",
    })
    require(phone["library"] == [(fixture["libraryInstanceID"],)] and len(phone["chunks"]) == len(phone["receipts"]) == 1,
            "Receiver identity/count changed")
    phone_chunk = phone["chunks"][0]
    require(phone_chunk[:4] == (manifest["chunkID"], manifest_data, fixture["envelope"]["manifestSHA256"], manifest["audioSHA256"])
            and phone_chunk[5:] == (int(acknowledged), "expired" if expired else "present"), "Phone confirmation or retention state differs")
    require(phone["jobs"] == [(manifest["chunkID"], manifest["chunkID"], "complete", None)]
            and phone["sessions"] == [(manifest["sessionID"], 0, 0)], "Synthetic completed-analysis retention precondition changed")
    outbox = phone["receipts"][0]
    require(outbox[:2] == control[:2] and json.loads(outbox[2]) == receipt and outbox[3] == int(acknowledged),
            "Phone receipt outbox disagrees with sender confirmation")
    original = check_audio(root / "input" / f"{manifest['chunkID']}.wav", manifest)
    sender_audio = confined_file(root, fixture["watchAudioRelativePath"])
    if watch_state == "acknowledged":
        require(check_audio(sender_audio, manifest) == original, "Pre-cleanup acknowledged original changed")
    else:
        require(not sender_audio.exists(), "Cleaned sender original resurrected")
    phone_audio = confined_file(root / "phone", phone_chunk[4])
    require(Path(str(phone_audio) + ".manifest.json").read_bytes() == manifest_data, "Phone immutable sidecar changed")
    if expired:
        require(not phone_audio.exists(), "Eligible phone original did not expire")
    else:
        require(check_audio(phone_audio, manifest) == original, "Phone deleted the only durable original before confirmation")
    return {"phase": phase, "watchState": watch_state, "receipt": receipt, "applied": applied,
            "phoneReceiptApplied": acknowledged, "phoneRetention": phone_chunk[6], "audio": original,
            "syntheticAnalysisCompleted": True, "sqliteIntegrity": "ok", "foreignKeyErrors": 0}


def finish_sender_case(executable: Path, case: str, root: Path, killed: dict) -> dict:
    before = capture_snapshot(root, "after-kill", None) if case == "J08-a" else receipt_snapshot(root, case, "after-kill")
    save(root / "after-kill.json", before)
    recovered = run_phase(executable, case, root, "recover")
    after = capture_snapshot(root, "after-recovery", before) if case == "J08-a" else receipt_snapshot(root, case, "after-recovery")
    save(root / "after-recovery.json", after)
    verified = run_phase(executable, case, root, "verify")
    final = capture_snapshot(root, "after-final-restart", before) if case == "J08-a" else receipt_snapshot(root, case, "after-final-restart")
    save(root / "after-final-restart.json", final)
    if case == "J08-a":
        require(after["events"] == final["events"] == recovered["controls"] == verified["controls"], "Interruption/mark replay changed identity")
        require(after["chunkCount"] == final["chunkCount"] and after["tailOutcome"] == final["tailOutcome"], "Second restart changed recovered capture state")
    else:
        require(before["applied"] == after["applied"] == final["applied"] == recovered["applied"] == verified["applied"],
                "ReceiptApplied changed across independent process lifetimes")
        require(recovered["retentionBlockedBeforeApplication"] is True, "Missing real retention gate check")
    ids = [killed["processID"], recovered["processID"], verified["processID"]]
    require(len(set(ids)) == 3, "Recovery did not use distinct process lifetimes")
    return {"case": case, "passed": True, "workerProcessIDs": ids,
            "tailOutcome": final.get("tailOutcome"), "syntheticAnalysisCompleted": case != "J08-a"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--case", choices=CASES, action="append", help="Run selected cases; default runs all six")
    arguments = parser.parse_args()
    executable = arguments.executable.resolve(strict=True)
    require(executable.is_file() and os.access(executable, os.X_OK), "Worker is not executable")
    output = arguments.output.absolute()
    output.mkdir(parents=True, exist_ok=False)
    started = time.monotonic()
    repo = Path(__file__).resolve().parents[2]
    cases = arguments.case or CASES
    require(len(set(cases)) == len(cases), "Duplicate case selection would overwrite evidence")
    report = {"runID": str(uuid.uuid4()), "scope": "macOS production capture/receive/receipt SIGKILL; synthetic PCM and real AAC; not Watch OS termination",
              "executableSHA256": sha256(executable), "sourceSHA256": source_version(repo),
              "cases": [], "passed": False, "failure": None}
    try:
        for case in cases:
            report["cases"].append(run_case(executable, case, output / case))
            print(f"PASS {case}", flush=True)
        report["passed"] = len(report["cases"]) == len(cases)
    except Exception as error:
        # The parent records unexpected failures and returns nonzero; it does not alter business state.
        report["failure"] = {"type": type(error).__name__, "message": str(error)}
    finally:
        report["elapsedSeconds"] = time.monotonic() - started
        save(output / "summary.json", report)
    print(json.dumps({"passed": report["passed"], "failure": report["failure"], "output": str(output)}, ensure_ascii=False))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())

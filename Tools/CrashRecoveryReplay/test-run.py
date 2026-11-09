"""Negative audit checks on disposable copies of a completed J08 run; never edit its evidence."""
import argparse
import json
from pathlib import Path
import shutil
import sqlite3
import tempfile
import unittest

from run import capture_snapshot, checked_manifest, receipt_snapshot


class AuditChecks(unittest.TestCase):
    evidence: Path

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="momo-crash-audit-selftest-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def copy_case(self, case):
        target = self.root / case
        shutil.copytree(self.evidence / case, target)
        return target

    def test_unchanged_capture_passes(self):
        root = self.copy_case("J08-a")
        before = json.loads((root / "after-kill.json").read_bytes())
        result = capture_snapshot(root, "selftest", before)
        expected = json.loads((root / "after-final-restart.json").read_bytes())
        self.assertEqual(result["events"], expected["events"])
        self.assertEqual(result["tailOutcome"], expected["tailOutcome"])

    def test_changed_sealed_aac_is_rejected(self):
        root = self.copy_case("J08-a")
        before = json.loads((root / "after-kill.json").read_bytes())
        fixture = json.loads((root / "capture-fixture.json").read_bytes())
        _, manifest = checked_manifest(fixture["envelope"])
        audio = root / "watch/CaptureReady" / manifest["chunkID"] / "audio"
        data = bytearray(audio.read_bytes())
        data[-1] ^= 1
        audio.write_bytes(data)
        with self.assertRaisesRegex(AssertionError, "prefix bytes changed"):
            capture_snapshot(root, "selftest", before)

    def test_changed_recovered_tail_aac_is_rejected(self):
        root = self.copy_case("J08-a")
        before = json.loads((root / "after-kill.json").read_bytes())
        after = json.loads((root / "after-final-restart.json").read_bytes())
        if after["tailOutcome"] != "recovered-from-pcm-sidecar":
            self.skipTest("Case did not recover tail from PCM sidecar")
        audio = root / "watch/CaptureReady" / before["draft"]["chunkID"] / "audio"
        data = bytearray(audio.read_bytes())
        data[-1] ^= 1
        audio.write_bytes(data)
        with self.assertRaisesRegex(AssertionError, "PCM-recovered tail audio hash mismatch"):
            capture_snapshot(root, "selftest", before)

    def test_lost_unprovable_tail_is_rejected(self):
        root = self.copy_case("J08-a")
        before = json.loads((root / "after-kill.json").read_bytes())
        after = json.loads((root / "after-final-restart.json").read_bytes())
        if after["tailOutcome"] == "recovered-from-pcm-sidecar":
            recovered_chunk_id = before["draft"]["chunkID"]
            (root / "watch/CaptureReady" / recovered_chunk_id / "audio").unlink()
            with self.assertRaises(AssertionError):
                capture_snapshot(root, "selftest", before)
            return
        if before["activeDecode"]["decodable"]:
            self.skipTest("This observed platform produced a decodable tail; repair branch is not applicable")
        next((root / "Encoding/Repair").rglob("*.m4a")).unlink()
        with self.assertRaises(FileNotFoundError):
            capture_snapshot(root, "selftest", before)

    def test_unproven_interruption_coverage_is_rejected(self):
        root = self.copy_case("J08-a")
        before = json.loads((root / "after-kill.json").read_bytes())
        with sqlite3.connect(root / "watch/recording.sqlite") as database:
            rowid, payload = database.execute("SELECT rowid,payload FROM capture_events ORDER BY rowid DESC LIMIT 1").fetchone()
            event = json.loads(payload)
            event["epochInterrupted"]["_0"]["sealedThroughFrame"] = 999999
            database.execute("UPDATE capture_events SET payload=? WHERE rowid=?", (json.dumps(event).encode(), rowid))
        with self.assertRaisesRegex(AssertionError, "unproven capture coverage"):
            capture_snapshot(root, "selftest", before)

    def test_unchanged_receipt_final_state_passes(self):
        for case in ("J08-e", "J08-f"):
            root = self.copy_case(case)
            result = receipt_snapshot(root, case, "after-final-restart")
            self.assertEqual(result["phoneRetention"], "expired")
            self.assertEqual(result["watchState"], "removed")

    def test_changed_receipt_applied_identity_is_rejected(self):
        root = self.copy_case("J08-f")
        with sqlite3.connect(root / "watch/recording.sqlite") as database:
            payload = database.execute("SELECT application FROM receipts").fetchone()[0]
            applied = json.loads(payload)
            applied["messageID"] = "00000000-0000-0000-0000-000000000000"
            database.execute("UPDATE receipts SET application=?", (json.dumps(applied).encode(),))
        with self.assertRaisesRegex(AssertionError, "ReceiptApplied changed"):
            receipt_snapshot(root, "J08-f", "after-final-restart")

    def test_resurrected_sender_audio_is_rejected(self):
        root = self.copy_case("J08-e")
        fixture = json.loads((root / "fixture.json").read_bytes())
        destination = root / fixture["watchAudioRelativePath"]
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(next((root / "input").glob("*.wav")), destination)
        with self.assertRaisesRegex(AssertionError, "original resurrected"):
            receipt_snapshot(root, "J08-e", "after-final-restart")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", required=True, type=Path)
    args, rest = parser.parse_known_args()
    AuditChecks.evidence = args.evidence.resolve(strict=True)
    unittest.main(argv=[__file__, *rest])

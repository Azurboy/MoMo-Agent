"""Verifier checks using disposable synthetic bundles; no app build, simulator or API."""

from contextlib import redirect_stdout
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("release_verifier", Path(__file__).with_name("verify-release-bundle.py"))
verifier = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verifier)


class GmailConfigurationTests(unittest.TestCase):
    def test_release_explicitly_uses_user_supplied_configuration(self):
        for mode in (None, "", "shared", "$(MOMO_GMAIL_AUTHENTICATION)"):
            with self.subTest(mode=mode):
                self.assertFalse(verifier.gmail_oauth_checks(dict(MoMoGmailAuthentication=mode))["gmail_user_oauth_mode"])
        self.assertTrue(all(verifier.gmail_oauth_checks(dict(MoMoGmailAuthentication="userProvided")).values()))

    def test_shared_client_is_not_shipped_with_user_configuration(self):
        for client in ("", "$(MOMO_GOOGLE_CLIENT_ID)", "123-synthetic.apps.googleusercontent.com"):
            checks = verifier.gmail_oauth_checks(dict(MoMoGmailAuthentication="userProvided", MoMoGoogleClientID=client))
            self.assertTrue(checks["gmail_user_oauth_mode"])
            self.assertFalse(checks["gmail_shared_client_absent"])

class ReleaseVerifierTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="momo-release-verifier-selftest-")
        self.root = Path(self.temporary.name).resolve()
        self.app = self.root / "MoMoAgent.app"
        self.version_config = self.root / "App.xcconfig"
        self.version_config.write_text("MARKETING_VERSION = 1.2.3\nCURRENT_PROJECT_VERSION = 42\n")
        self.watch = self.app / "Watch/MoMoAgentWatch.app"
        self.watch.mkdir(parents=True)
        self.widget = self.watch / "PlugIns/MoMoAgentWatchWidget.appex"
        self.widget.mkdir(parents=True)
        self.phone_binary = self.app / "MoMoAgent"
        self.watch_binary = self.watch / "MoMoAgentWatch"
        self.widget_binary = self.widget / "MoMoAgentWatchWidget"
        # A real host Mach-O lets the baseline exercise xcrun lipo without building or launching anything.
        self.binary = Path("/usr/bin/true").read_bytes()
        self.phone_binary.write_bytes(self.binary)
        self.watch_binary.write_bytes(self.binary)
        self.widget_binary.write_bytes(self.binary)
        self.write_plist(self.app / "Info.plist", dict(
            CFBundleIdentifier="com.momoagent.ios", CFBundleExecutable="MoMoAgent",
            MoMoGmailAuthentication="userProvided",
            CFBundleShortVersionString="1.2.3", CFBundleVersion="42",
            UIBackgroundModes=["audio", "processing"], BGTaskSchedulerPermittedIdentifiers=[
                "com.momoagent.ios.transcription.processing", "com.momoagent.ios.transcription.continued.*"]))
        self.write_plist(self.watch / "Info.plist", dict(
            CFBundleIdentifier="com.momoagent.ios.watchkitapp", CFBundleExecutable="MoMoAgentWatch",
            CFBundleShortVersionString="1.2.3", CFBundleVersion="42",
            UIBackgroundModes=["audio"], NSMicrophoneUsageDescription="Synthetic verifier fixture.",
            WKApplication=True, WKCompanionAppBundleIdentifier="com.momoagent.ios",
            WKRunsIndependentlyOfCompanionApp=True))
        self.write_plist(self.widget / "Info.plist", dict(
            CFBundleIdentifier="com.momoagent.ios.watchkitapp.widget", CFBundleExecutable="MoMoAgentWatchWidget",
            CFBundleShortVersionString="1.2.3", CFBundleVersion="42",
            NSExtension=dict(NSExtensionPointIdentifier="com.apple.widgetkit-extension")))
        self.write_plist(self.app / "PrivacyInfo.xcprivacy", self.privacy(DiskSpace="85F4.1"))
        self.write_plist(self.watch / "PrivacyInfo.xcprivacy", self.privacy(DiskSpace="E174.1", SystemBootTime="35F9.1"))
        speech = self.app / "Speech"
        speech.mkdir()
        pins = dict(schemaVersion=1)
        for name, key in verifier.MODEL_KEYS.items():
            data = ("synthetic model fixture " + name).encode()
            (speech / name).write_bytes(data)
            pins[key] = hashlib.sha256(data).hexdigest()
        self.pins = self.root / "pinned-models.json"
        self.pins.write_text(json.dumps(pins))
        shutil.copyfile(self.pins, speech / "manifest.json")
        (speech / "Speakers").mkdir()
        speaker_pins = {"schemaVersion": 1, "files": {}}
        for name in ["eres2netv2.onnx", "diarizen-wavlm-base-s80-md.onnx", "segmentation-community-1.onnx"]:
            data = ("synthetic " + name).encode()
            (speech / "Speakers" / name).write_bytes(data)
            speaker_pins["files"][name] = hashlib.sha256(data).hexdigest()
        self.speaker_pins = self.root / "speaker-pins.json"
        self.speaker_pins.write_text(json.dumps(speaker_pins))

    def tearDown(self):
        self.temporary.cleanup()

    @staticmethod
    def write_plist(path, value):
        path.write_bytes(plistlib.dumps(value))

    @staticmethod
    def privacy(**entries):
        return dict(NSPrivacyAccessedAPITypes=[dict(
            NSPrivacyAccessedAPIType="NSPrivacyAccessedAPICategory" + category,
            NSPrivacyAccessedAPITypeReasons=[reason]) for category, reason in entries.items()])

    def change_info(self, bundle, **changes):
        path = bundle / "Info.plist"
        value = plistlib.loads(path.read_bytes())
        value.update(changes)
        self.write_plist(path, value)

    def audit(self):
        return verifier.audit(self.app, self.pins, self.version_config, pinned_speakers=self.speaker_pins)

    def assert_rejected(self, check=None, error=None):
        result = self.audit()
        self.assertEqual(result["status"], "failed")
        self.assertTrue(result["failed_assertions"] or result["unchecked_assertions"] or result["errors"])
        if check:
            self.assertIsNot(result["checks"][check], True)
        if error:
            self.assertIn(error, [item["code"] for item in result["errors"]])
        return result

    def test_good_synthetic_bundle_exercises_all_checks_and_real_architecture_tool(self):
        result = self.audit()
        self.assertEqual(result["status"], "passed", result)
        self.assertEqual(set(result["checks"]), set(verifier.CHECKS))
        self.assertTrue(all(value is True for value in result["checks"].values()))
        self.assertEqual(set(result["binaries"]), {"MoMoAgent", "Watch/MoMoAgentWatch.app/MoMoAgentWatch",
            "Watch/MoMoAgentWatch.app/PlugIns/MoMoAgentWatchWidget.appex/MoMoAgentWatchWidget"})
        self.assertTrue(all(binary["architectures"] for binary in result["binaries"].values()))
        self.assertEqual(result["errors"], [])
        self.assertIn("runtime_behavior", result["not_checked"])
        self.assertIn("unknown_secret_detection", result["not_checked"])

    def test_missing_phone_or_embedded_watch_is_never_success(self):
        shutil.rmtree(self.watch)
        self.assert_rejected("watch_app_embedded")
        shutil.rmtree(self.app)
        self.assert_rejected("release_app_exists")

    def test_beta_requires_its_own_identity_background_tasks_and_companion(self):
        beta_id = "com.momoagent.ios.beta"
        self.change_info(self.app, CFBundleIdentifier=beta_id, BGTaskSchedulerPermittedIdentifiers=[
            beta_id + ".transcription.processing", beta_id + ".transcription.continued.*"])
        self.change_info(self.watch, CFBundleIdentifier=beta_id + ".watchkitapp",
                         WKCompanionAppBundleIdentifier=beta_id)
        self.change_info(self.widget, CFBundleIdentifier=beta_id + ".watchkitapp.widget")
        self.assertEqual(verifier.audit(self.app, self.pins, self.version_config, variant="beta", pinned_speakers=self.speaker_pins)["status"], "passed")
        self.assert_rejected("phone_bundle_identity")
        self.change_info(self.watch, WKCompanionAppBundleIdentifier="com.momoagent.ios")
        result = verifier.audit(self.app, self.pins, self.version_config, variant="beta", pinned_speakers=self.speaker_pins)
        self.assertFalse(result["checks"]["watch_companion_declared"])

    def test_local_upgrade_preserves_legacy_identity_without_weakening_release_checks(self):
        legacy = "com.watchmylife.ios"
        self.change_info(self.app, CFBundleIdentifier=legacy, BGTaskSchedulerPermittedIdentifiers=[
            legacy + ".transcription.processing", legacy + ".transcription.continued.*"])
        self.change_info(self.watch, CFBundleIdentifier=legacy + ".watchkitapp", WKCompanionAppBundleIdentifier=legacy)
        self.change_info(self.widget, CFBundleIdentifier=legacy + ".watchkitapp.widget")
        result = verifier.audit(self.app, self.pins, self.version_config, variant="local-upgrade", pinned_speakers=self.speaker_pins)
        self.assertEqual(result["status"], "passed")
        self.assert_rejected("phone_bundle_identity")
        self.change_info(self.watch, WKCompanionAppBundleIdentifier="com.momoagent.ios")
        result = verifier.audit(self.app, self.pins, self.version_config, variant="local-upgrade", pinned_speakers=self.speaker_pins)
        self.assertFalse(result["checks"]["watch_companion_declared"])

    def test_missing_widget_or_wrong_extension_point_cannot_pass(self):
        self.change_info(self.widget, NSExtension=dict(NSExtensionPointIdentifier="other.extension"))
        self.assert_rejected("widget_extension_declared")
        shutil.rmtree(self.widget)
        self.assert_rejected("widget_extension_embedded")

    def test_versions_cannot_be_stale_malformed_or_different_between_devices(self):
        for role, bundle in (("phone", self.app), ("watch", self.watch), ("widget", self.widget)):
            info = bundle / "Info.plist"
            original = info.read_bytes()
            for key, values in {
                "CFBundleShortVersionString": (None, 123, "1.2", "1.2.3 (42)", "1.2.4", "$(MARKETING_VERSION)"),
                "CFBundleVersion": (None, 42, "41", "43", "$(CURRENT_PROJECT_VERSION)"),
            }.items():
                for value in values:
                    with self.subTest(role=role, key=key, value=value):
                        if value is None:
                            contents = plistlib.loads(info.read_bytes())
                            del contents[key]
                            self.write_plist(info, contents)
                        else:
                            self.change_info(bundle, **{key: value})
                        self.assert_rejected(role + "_version_matches_configuration")
                        info.write_bytes(original)
        # Matching each other is insufficient when both apps use stale version settings.
        for bundle in (self.app, self.watch):
            self.change_info(bundle, CFBundleShortVersionString="1.2.2", CFBundleVersion="41")
        self.assert_rejected("phone_version_matches_configuration")
        self.assert_rejected("watch_version_matches_configuration")

    def test_invalid_or_missing_version_configuration_cannot_pass(self):
        for source in ("", "MARKETING_VERSION = 1.2\nCURRENT_PROJECT_VERSION = 42\n",
                       "MARKETING_VERSION = 01.2.3\nCURRENT_PROJECT_VERSION = 42\n",
                       "MARKETING_VERSION = 1.2.3 (42)\nCURRENT_PROJECT_VERSION = 42\n",
                       "MARKETING_VERSION = 1.2.3\nCURRENT_PROJECT_VERSION = 0\n",
                       "MARKETING_VERSION = 1.2.3\nCURRENT_PROJECT_VERSION = 4.2\n",
                       "MARKETING_VERSION = 1.2.3\nMARKETING_VERSION = 1.2.4\nCURRENT_PROJECT_VERSION = 42\n"):
            with self.subTest(source=source):
                self.version_config.write_text(source)
                self.assert_rejected("version_configuration_valid")
        self.version_config.unlink()
        self.assert_rejected("version_configuration_valid")

    def test_wrong_identity_or_invalid_executable_name_is_rejected_on_each_device(self):
        for role, bundle, name in [("phone", self.app, "MoMoAgent"), ("watch", self.watch, "MoMoAgentWatch"),
                                   ("widget", self.widget, "MoMoAgentWatchWidget")]:
            info = bundle / "Info.plist"
            original = info.read_bytes()
            with self.subTest(role=role, fault="identity"):
                self.change_info(bundle, CFBundleIdentifier="other.app")
                self.assert_rejected(role + "_bundle_identity")
                info.write_bytes(original)
            for bad in ("", ".", "..", "../outside", "sub/file", "sub\\file", 42):
                with self.subTest(role=role, executable=bad):
                    self.change_info(bundle, CFBundleExecutable=bad)
                    self.assert_rejected(role + "_executable_checked")
                    info.write_bytes(original)
            self.assertTrue((bundle / name).exists())

    def test_missing_or_non_macho_executable_is_rejected_on_each_device(self):
        for role, binary in [("phone", self.phone_binary), ("watch", self.watch_binary), ("widget", self.widget_binary)]:
            with self.subTest(role=role, fault="missing"):
                binary.unlink()
                self.assert_rejected(role + "_executable_checked", "executable_missing_or_not_regular")
            with self.subTest(role=role, fault="not_macho"):
                binary.write_bytes(b"ordinary file")
                self.assert_rejected(role + "_executable_checked", "executable_not_macho")
            binary.write_bytes(self.binary)

    def test_each_debug_marker_is_detected_across_scan_boundaries(self):
        path = self.root / "scanner-input"
        for marker in verifier.MARKERS:
            with self.subTest(marker=marker):
                # One marker starts across a 64-byte block boundary and exceeds the old block's tail.
                data = b"\xcf\xfa\xed\xfe" + b"x" * 58 + marker.encode() + b"tail"
                path.write_bytes(data)
                result = verifier.inspect_binary(path, block_size=64)
                self.assertFalse(result["debug_marker_absent"][marker])
                self.assertEqual(result["sha256"], hashlib.sha256(data).hexdigest())
                self.assertEqual(result["byteCount"], len(data))

    def test_debug_watch_and_phone_binaries_and_embedded_libraries_cannot_pass(self):
        framework = self.watch / "Frameworks/Hidden.framework/Hidden"
        dylib = self.app / "Frameworks/Hidden.dylib"
        framework.parent.mkdir(parents=True)
        dylib.parent.mkdir(parents=True)
        for target in (self.phone_binary, self.watch_binary, self.widget_binary, framework, dylib):
            with self.subTest(target=str(target.relative_to(self.app))):
                target.write_bytes(self.binary + b"\x00MOMO_WATCH_TEST_RUN_ID\x00")
                result = self.assert_rejected("debug_entry_strings_absent")
                self.assertIn(str(target.relative_to(self.app)), result["binaries"])
                target.write_bytes(self.binary)
        self.assertEqual(self.audit()["status"], "passed")

    def test_fixture_test_bundle_and_debug_dylib_resources_are_rejected(self):
        paths = ("TestFixtures", "test_wavs", "fixture.json", "zh.wav", ".env",
                 "controlled-stream-ledger.json",
                 "live-agent-credentials.json", "live-ui-agent-credentials.json",
                 "__preview.dylib", "Injected.xctest", "MoMoAgent.debug.dylib", "MoMoAgentSimulatorTests")
        for base in (self.app, self.watch):
            for name in paths:
                with self.subTest(base=base.name, name=name):
                    path = base / name
                    path.write_bytes(self.binary if name.endswith(".dylib") else b"synthetic fixture")
                    result = self.assert_rejected("test_fixtures_absent")
                    self.assertIn(str(path.relative_to(self.app)), result["forbidden_resources"])
                    path.unlink()

    def test_symlink_resources_and_bundle_roots_are_rejected_without_following_them(self):
        outside = self.root / "outside"
        outside.mkdir()
        (outside / ".env").write_text("synthetic sentinel, must not be read")
        for name, target in [("linked-directory", outside), ("linked-file", outside / ".env")]:
            path = self.watch / name
            path.symlink_to(target)
            result = self.assert_rejected("bundle_has_only_regular_files")
            self.assertIn(str(path.relative_to(self.app)), result["unsafe_paths"])
            self.assertNotIn("synthetic sentinel", json.dumps(result))
            path.unlink()
        self.watch_binary.unlink()
        self.watch_binary.symlink_to(Path("/usr/bin/true"))
        self.assert_rejected("watch_executable_checked")
        shutil.rmtree(self.watch)
        self.watch.symlink_to(outside)
        self.assert_rejected("watch_app_embedded")

    def test_unreadable_subdirectory_is_not_silently_skipped(self):
        hidden = self.watch / "Unreadable"
        hidden.mkdir()
        (hidden / ".env").write_text("synthetic forbidden resource")
        original_walk = verifier.os.walk
        def denied_walk(_root, *, followlinks, onerror=None):
            if onerror:
                onerror(PermissionError("synthetic unreadable directory"))
            return (entry for entry in original_walk(_root, followlinks=followlinks) if Path(entry[0]) != hidden)
        with patch.object(verifier.os, "walk", side_effect=denied_walk):
            self.assert_rejected("bundle_has_only_regular_files", "input_or_tool_unavailable")

    def test_missing_corrupt_or_changed_model_and_manifest_are_rejected(self):
        for name in (*verifier.MODEL_KEYS, "manifest.json"):
            path = self.app / "Speech" / name
            original = path.read_bytes()
            with self.subTest(name=name, fault="changed"):
                path.write_bytes(original + b"changed")
                self.assert_rejected("all_model_resources_match")
            with self.subTest(name=name, fault="missing"):
                path.unlink()
                self.assert_rejected("all_model_resources_match", "model_resource_missing_or_not_regular")
            path.write_bytes(original)

    def test_model_directory_accepts_only_the_pinned_production_files(self):
        for name in ("extra.bin", ".download-metadata.json", "coreml-manifest.json", "vocab.json", "unlisted-directory"):
            with self.subTest(name=name):
                path = self.app / "Speech" / name
                if name.endswith("directory"):
                    path.mkdir()
                else:
                    path.write_bytes(b"unlisted resource")
                result = self.assert_rejected("all_model_resources_match")
                self.assertIn(name, result["model_resource_names"])
                if path.is_dir():
                    path.rmdir()
                else:
                    path.unlink()
        self.assertEqual(self.audit()["status"], "passed")

    def test_invalid_pin_cannot_validate_matching_arbitrary_models(self):
        original = self.pins.read_bytes()
        for bad in (b"not json", b"[]", b'{"schemaVersion": 2}', b'{"schemaVersion": 1}'):
            with self.subTest(pin=bad):
                self.pins.write_bytes(bad)
                self.assert_rejected("all_model_resources_match")
        self.pins.write_bytes(original)
        self.pins.unlink()
        self.assert_rejected("all_model_resources_match", "model_pin_missing")

    def test_background_and_companion_contracts_are_required(self):
        cases = [(self.app, "background_processing_declared", dict(UIBackgroundModes=["audio"])),
                 (self.app, "background_processing_declared", dict(UIBackgroundModes=["processing"])),
                 (self.app, "background_processing_declared", dict(UIBackgroundModes=["audio", "processing", "location"])),
                 (self.app, "background_identifiers_declared", dict(BGTaskSchedulerPermittedIdentifiers=[])),
                 (self.app, "background_identifiers_declared", dict(BGTaskSchedulerPermittedIdentifiers=[
                     "com.momoagent.ios.transcription.processing"])),
                 (self.app, "background_identifiers_declared", dict(BGTaskSchedulerPermittedIdentifiers=[
                     "com.momoagent.ios.transcription.processing", "com.momoagent.ios.transcription.continued.*",
                     "com.momoagent.ios.insights.processing"])),
                 (self.watch, "watch_audio_background_declared", dict(UIBackgroundModes=[])),
                 (self.watch, "watch_companion_declared", dict(WKApplication=False)),
                 (self.watch, "watch_companion_declared", dict(WKCompanionAppBundleIdentifier="other.app")),
                 (self.watch, "watch_companion_declared", dict(WKRunsIndependentlyOfCompanionApp=False))]
        for bundle, check, changes in cases:
            with self.subTest(check=check, changes=changes):
                path = bundle / "Info.plist"
                original = path.read_bytes()
                self.change_info(bundle, **changes)
                self.assert_rejected(check)
                path.write_bytes(original)

    def test_watch_microphone_description_requires_nonempty_string(self):
        for value in ("", "  ", 42, ["invalid"], {"invalid": True}):
            with self.subTest(description=value):
                self.change_info(self.watch, NSMicrophoneUsageDescription=value)
                self.assert_rejected("watch_microphone_usage_declared")

    def test_each_privacy_reason_is_checked_and_malformed_plists_fail_closed(self):
        for bundle, check in [(self.app, "phone_disk_display_reason"),
                              (self.watch, "watch_disk_write_reason"), (self.watch, "watch_elapsed_time_reason")]:
            path = bundle / "PrivacyInfo.xcprivacy"
            original = path.read_bytes()
            for value in (self.privacy(), [], dict(NSPrivacyAccessedAPITypes=42),
                          dict(NSPrivacyAccessedAPITypes=[dict(NSPrivacyAccessedAPIType="wrong")])):
                with self.subTest(check=check, value=value):
                    self.write_plist(path, value)
                    self.assert_rejected(check)
            path.write_bytes(b"not a plist")
            self.assert_rejected(check, "input_or_tool_unavailable")
            path.write_bytes(original)

    def test_architecture_tool_error_timeout_or_invalid_output_never_passes(self):
        for outcome in (subprocess.CompletedProcess([], 1, b"", b"synthetic error"),
                        subprocess.CompletedProcess([], 0, b"", b""),
                        subprocess.CompletedProcess([], 0, b"arm64;unsafe", b""),
                        subprocess.CompletedProcess([], 0, b"arm64..x1", b""),
                        subprocess.CompletedProcess([], 0, b"\xff", b""),
                        FileNotFoundError("synthetic xcrun missing"), subprocess.TimeoutExpired("xcrun", 30)):
            with self.subTest(outcome=type(outcome).__name__):
                arguments = dict(side_effect=outcome) if isinstance(outcome, Exception) else dict(return_value=outcome)
                with patch.object(verifier.subprocess, "run", **arguments):
                    self.assert_rejected("binary_architectures_read")

    def test_cli_exit_and_json_match_real_decision_and_do_not_overwrite_evidence(self):
        original_audit = verifier.audit
        with patch.object(verifier, "audit", side_effect=lambda app, variant: original_audit(app, self.pins, self.version_config, variant, pinned_speakers=self.speaker_pins)):
            for expected in ("passed", "failed"):
                if expected == "failed":
                    self.watch_binary.write_bytes(self.binary + b"\x00MOMO_WATCH_TEST_RUN_ID\x00")
                output = self.root / (expected + ".json")
                stream = io.StringIO()
                with redirect_stdout(stream):
                    code = verifier.main(["--app", str(self.app), "--output", str(output)])
                report = json.loads(output.read_text())
                self.assertEqual(code, 0 if expected == "passed" else 1)
                self.assertEqual(report["status"], expected)
                self.assertEqual(json.loads(stream.getvalue()), report)
                original = output.read_bytes()
                with redirect_stdout(io.StringIO()):
                    self.assertEqual(verifier.main(["--app", str(self.app), "--output", str(output)]), 2)
                self.assertEqual(output.read_bytes(), original)
            inside = self.watch / "must-not-create.json"
            with redirect_stdout(io.StringIO()):
                self.assertEqual(verifier.main(["--app", str(self.app), "--output", str(inside)]), 2)
            self.assertFalse(inside.exists())


if __name__ == "__main__":
    unittest.main()

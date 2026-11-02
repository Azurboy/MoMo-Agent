"""Read-only Release bundle checks, based on the retained Release08/09 audit."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess

ROOT = Path(__file__).resolve().parents[2]
PINNED_MODELS = ROOT / "Native/SpeechVendor/manifest.json"
VERSION_CONFIG = ROOT / "Config/App.xcconfig"
MODEL_KEYS = {"model.int8.onnx": "asrSHA256", "tokens.txt": "tokensSHA256", "silero_vad.onnx": "vadSHA256"}
MARKERS = (
    "momo-simulator-pairing.json", "connectRemoteFixture", "MOMO_REMOTE_RECORDING_OK",
    "MOMO_UI_TEST_AVATAR_UNAVAILABLE", "MOMO_UI_TEST_RUN_ID", "MOMO_UI_TEST_IMPORT_FIXTURE", "MOMO_UI_TEST_DOCUMENT_CHANGE",
    "MOMO_UI_TEST_TIMELINE_FIXTURE", "MOMO_UI_TEST_WATCH_STATUS", "MOMO_UI_TEST_STATUS_FAILURE",
    "MOMO_UI_TEST_CONTROLLED_STREAM", "MOMO_UI_TEST_CONTROLLED_STREAM_EXPIRE_AUDIO",
    "PhoneControlledStreamServer", "ControlledStreamURLProtocol", "PhoneControlledStreamScenario",
    "configureControlledStream", "isolatedUITestNetwork",
    "controlled-stream.invalid", "momo-controlled-stream-synthetic-only", "controlled-stream-ledger.json",
    "RecordingReadingDiagnostic", "TimelineReadingDiagnostic", "readingPositionObserver",
    "TimelineReadingGeometry", "ReadingSpanGeometry",
    "fixture-change-remove-markdown", "PhoneUITestConfiguration", "PhoneLiveAgentUITestConfiguration",
    "onClaimReturned", "observeClaims", "onStopBoundary", "observeStops", "onAdmissionReturned", "observeAdmissions",
    "live-agent-credentials.json", "LiveAgentContextTests", "CredentialHeaderProbe", "PlaybackSessionProbe",
    "ArchiveReceiveBoundary", "receiveBoundaryObserver", "live-ui-agent-credentials.json", "MOMO_UI_TEST_LIVE_AGENT",
    "configureLiveUITest", "openLiveUITest", "MOMO_HTTP_FIXTURE_BASE_URL", "MOMO_HTTP_FIXTURE_PORT",
    "AgentHTTPFaultIntegrationTests", "momo-j17-synthetic-only",
    "MOMO_WATCH_TEST_RUN_ID", "MoMoAgentSimulatorTests", "makeSimulatorTest", "configureSimulatorTestCapture",
    "audioContentValidationCount",
    "playbackPreviewStampReadCount",
    # Archive no-speech recovery is now used by the production background repair
    # path (2026-10-28); keep rejecting the removed diagnostic settings entry.
    "settings.speech.review",
)
FORBIDDEN_NAMES = {"testfixtures", "test_wavs", "fixture.json", "zh.wav", ".env",
                   "controlled-stream-ledger.json",
                   "live-agent-credentials.json", "live-ui-agent-credentials.json", "__preview.dylib"}
MACHO_MAGICS = {bytes.fromhex(value) for value in
               ("feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}
CHECKS = (
    "release_app_exists", "bundle_has_only_regular_files", "phone_bundle_identity", "watch_app_embedded",
    "watch_bundle_identity", "phone_executable_checked", "watch_executable_checked", "binary_architectures_read",
    "test_fixtures_absent", "debug_entry_strings_absent", "all_model_resources_match",
    "gmail_user_oauth_mode", "gmail_shared_client_absent",
    "background_processing_declared", "background_identifiers_declared", "phone_disk_display_reason",
    "watch_disk_write_reason", "watch_elapsed_time_reason", "watch_audio_background_declared",
    "watch_microphone_usage_declared", "watch_companion_declared",
    "version_configuration_valid", "phone_version_matches_configuration", "watch_version_matches_configuration",
    "widget_extension_embedded", "widget_bundle_identity", "widget_extension_declared",
    "widget_executable_checked", "widget_version_matches_configuration",
)


class AuditError(Exception):
    """Fixed report codes; arbitrary file contents and tool errors are not printed."""


def require(value, code):
    if not value:
        raise AuditError(code)


def configured_version(path):
    source = path.read_text(encoding="utf-8")
    values = {}
    for key in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION"):
        matches = re.findall(r"^\s*" + key + r"\s*=\s*([^\n]+)$", source, re.MULTILINE)
        require(len(matches) == 1, "version_configuration_assignment_required")
        values[key] = matches[0].strip()
    require(re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)",
                         values["MARKETING_VERSION"]) is not None, "marketing_version_requires_three_integers")
    require(re.fullmatch(r"[1-9][0-9]*", values["CURRENT_PROJECT_VERSION"]) is not None,
            "build_version_requires_positive_integer")
    return dict(CFBundleShortVersionString=values["MARKETING_VERSION"],
                CFBundleVersion=values["CURRENT_PROJECT_VERSION"])


def gmail_oauth_checks(info):
    return {"gmail_user_oauth_mode": info.get("MoMoGmailAuthentication") == "userProvided",
            "gmail_shared_client_absent": "MoMoGoogleClientID" not in info}


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def inventory(app):
    require(app.is_dir() and not app.is_symlink(), "app_directory_missing_or_symlink")
    files, unsafe, forbidden = set(), [], []
    def unreadable(error):
        raise error
    for directory, directories, names in os.walk(app, followlinks=False, onerror=unreadable):
        for name in directories + names:
            path = Path(directory) / name
            relative = str(path.relative_to(app))
            mode = path.lstat().st_mode
            if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
                unsafe.append(relative)
            elif stat.S_ISREG(mode):
                files.add(path)
            if (name.lower() in FORBIDDEN_NAMES or name.endswith(".xctest")
                    or name.endswith(".debug.dylib") or name == "MoMoAgentSimulatorTests"):
                forbidden.append(relative)
    return files, sorted(unsafe), sorted(forbidden)


def architectures(path):
    environment = {key: value for key, value in os.environ.items()
                   if key in {"PATH", "HOME", "DEVELOPER_DIR", "TOOLCHAINS"}}
    result = subprocess.run(["xcrun", "lipo", "-archs", str(path)], capture_output=True,
                            env=environment, timeout=30)
    require(result.returncode == 0, "lipo_failed")
    values = result.stdout.decode("ascii").split()
    require(values and all(all(part and set(part) <= set("abcdefghijklmnopqrstuvwxyz0123456789_")
                              for part in value.split(".")) for value in values),
            "lipo_architectures_invalid")
    return values


def inspect_binary(path, block_size=1024 * 1024):
    needles = {marker: marker.encode("utf-8") for marker in MARKERS}
    overlap = max(map(len, needles.values())) - 1
    found, tail, sha, count = set(), b"", hashlib.sha256(), 0
    with path.open("rb") as stream:
        require(stream.read(4) in MACHO_MAGICS, "executable_not_macho")
        stream.seek(0)
        while block := stream.read(block_size):
            sha.update(block)
            count += len(block)
            searchable = tail + block
            found.update(marker for marker, needle in needles.items() if needle in searchable)
            tail = searchable[-overlap:]
    return dict(sha256=sha.hexdigest(), byteCount=count,
                debug_marker_absent={marker: marker not in found for marker in MARKERS})


def reasons(manifest, category):
    return {reason for item in manifest.get("NSPrivacyAccessedAPITypes", [])
            if item["NSPrivacyAccessedAPIType"] == category for reason in item["NSPrivacyAccessedAPITypeReasons"]}


def audit(app, pinned_models=PINNED_MODELS, version_config=VERSION_CONFIG, variant="release",
          pinned_speakers=ROOT / "Native/SpeechVendor/speaker-manifest.json"):
    require(variant in {"release", "beta", "local-upgrade"}, "unknown_app_variant")
    phone_id = "com.watchmylife.ios" if variant == "local-upgrade" else "com.momoagent.ios" + (".beta" if variant == "beta" else "")
    result = dict(schemaVersion=1, scope="release_bundle_static_checks", app_path=str(app),
                  checkedAt=datetime.now(timezone.utc).isoformat(), checks=dict.fromkeys(CHECKS),
                  errors=[], binaries={}, bundles={}, model_resources={},
                  not_checked=["install_and_launch", "runtime_behavior", "code_signature_and_entitlements",
                               "physical_devices", "18_hour_capture", "App_Store_archive_or_submission",
                               "unknown_secret_detection"])
    checks = result["checks"]

    def attempt(assertion, operation):
        try:
            return operation()
        except (AuditError, OSError, ValueError, TypeError, KeyError, UnicodeError,
                plistlib.InvalidFileException, subprocess.TimeoutExpired) as error:
            result["errors"].append(dict(assertion=assertion,
                code=str(error) if isinstance(error, AuditError) else "input_or_tool_unavailable"))
            return None

    expected_version = attempt("version_configuration", lambda: configured_version(version_config))
    checks["version_configuration_valid"] = expected_version is not None
    result["expected_version"] = expected_version
    listing = attempt("bundle_inventory", lambda: inventory(app))
    checks["release_app_exists"] = app.is_dir() and not app.is_symlink()
    if listing is not None:
        files, unsafe, forbidden = listing
        result["unsafe_paths"], result["forbidden_resources"] = unsafe, forbidden
        checks["bundle_has_only_regular_files"] = not unsafe
        checks["test_fixtures_absent"] = not forbidden

        def plist(path):
            require(path in files, "required_plist_missing_or_not_regular")
            value = plistlib.loads(path.read_bytes())
            require(isinstance(value, dict), "plist_dictionary_required")
            return value

        main_paths = {}
        bundle_paths = {"phone": app, "watch": app / "Watch/MoMoAgentWatch.app",
                        "widget": app / "Watch/MoMoAgentWatch.app/PlugIns/MoMoAgentWatchWidget.appex"}
        checks["watch_app_embedded"] = bundle_paths["watch"].is_dir() and not bundle_paths["watch"].is_symlink()
        checks["widget_extension_embedded"] = bundle_paths["widget"].is_dir() and not bundle_paths["widget"].is_symlink()
        for role, bundle in bundle_paths.items():
            info = attempt(role + "_info", lambda: plist(bundle / "Info.plist"))
            if info is not None:
                result["bundles"][role] = {key: info.get(key) for key in
                    ("CFBundleIdentifier", "CFBundleExecutable", "CFBundleShortVersionString", "CFBundleVersion",
                     "MinimumOSVersion", "DTPlatformName", "DTSDKName")}
                if expected_version is not None:
                    checks[role + "_version_matches_configuration"] = all(
                        info.get(key) == value for key, value in expected_version.items())
                expected = {"phone": phone_id, "watch": phone_id + ".watchkitapp",
                            "widget": phone_id + ".watchkitapp.widget"}[role]
                checks[role + "_bundle_identity"] = info.get("CFBundleIdentifier") == expected
                name = info.get("CFBundleExecutable")
                if isinstance(name, str) and name not in {"", ".", ".."} and "/" not in name and "\\" not in name:
                    main_paths[role] = bundle / name
                else:
                    checks[role + "_executable_checked"] = False
                if role == "phone":
                    checks.update(gmail_oauth_checks(info))
                    checks["background_processing_declared"] = info.get("UIBackgroundModes") in (
                        ["audio", "processing"], ["processing", "audio"])
                    identifiers = info.get("BGTaskSchedulerPermittedIdentifiers")
                    checks["background_identifiers_declared"] = (
                        isinstance(identifiers, list) and len(identifiers) == 2
                        and all(isinstance(value, str) for value in identifiers)
                        and set(identifiers) == {
                            phone_id + ".transcription.processing",
                            phone_id + ".transcription.continued.*"})
                elif role == "watch":
                    checks["watch_audio_background_declared"] = info.get("UIBackgroundModes") == ["audio"]
                    description = info.get("NSMicrophoneUsageDescription")
                    checks["watch_microphone_usage_declared"] = isinstance(description, str) and bool(description.strip())
                    checks["watch_companion_declared"] = info.get("WKApplication") is True and info.get(
                        "WKCompanionAppBundleIdentifier") == phone_id and info.get("WKRunsIndependentlyOfCompanionApp") is True
                else:
                    extension = info.get("NSExtension")
                    checks["widget_extension_declared"] = isinstance(extension, dict) and extension.get(
                        "NSExtensionPointIdentifier") == "com.apple.widgetkit-extension"
            if role == "widget":
                continue
            privacy = attempt(role + "_privacy", lambda: plist(bundle / "PrivacyInfo.xcprivacy"))
            requirements = [("phone_disk_display_reason", "DiskSpace", "85F4.1")] if role == "phone" else [
                ("watch_disk_write_reason", "DiskSpace", "E174.1"), ("watch_elapsed_time_reason", "SystemBootTime", "35F9.1")]
            if privacy is not None:
                for key, category, reason in requirements:
                    checks[key] = attempt(key, lambda: reason in reasons(privacy, "NSPrivacyAccessedAPICategory" + category))

        # Scan app executables plus embedded dylib/framework executables, including a stray debug.dylib.
        candidates = set(main_paths.values()) | {path for path in files if path.suffix == ".dylib" or any(
            parent.suffix == ".framework" and path.name == parent.stem for parent in path.relative_to(app).parents)}
        for path in sorted(candidates):
            relative = str(path.relative_to(app))
            def inspect():
                require(path in files, "executable_missing_or_not_regular")
                return inspect_binary(path)
            binary = attempt("binary:" + relative, inspect)
            if binary is not None:
                binary["architectures"] = attempt("architectures:" + relative, lambda: architectures(path))
                result["binaries"][relative] = binary
        for role, path in main_paths.items():
            checks[role + "_executable_checked"] = str(path.relative_to(app)) in result["binaries"]
        complete = all(checks[role + "_executable_checked"] is True for role in bundle_paths) \
            and len(result["binaries"]) == len(candidates)
        if complete:
            checks["binary_architectures_read"] = all(binary["architectures"] for binary in result["binaries"].values())
            checks["debug_entry_strings_absent"] = all(all(binary["debug_marker_absent"].values()) for binary in result["binaries"].values())

        def model_pins():
            require(pinned_models.is_file() and not pinned_models.is_symlink(), "model_pin_missing")
            value = json.loads(pinned_models.read_text())
            require(isinstance(value, dict) and value.get("schemaVersion") == 1, "model_pin_invalid")
            hashes = {name: value[key] for name, key in MODEL_KEYS.items()}
            require(all(isinstance(sha, str) and len(sha) == 64 and set(sha) <= set("0123456789abcdef")
                        for sha in hashes.values()), "model_pin_invalid")
            hashes["manifest.json"] = digest(pinned_models)
            speakers = json.loads(pinned_speakers.read_text())
            require(speakers.get("schemaVersion") == 1 and set(speakers["files"]) == {
                "eres2netv2.onnx", "diarizen-wavlm-base-s80-md.onnx",
                "segmentation-community-1.onnx"}, "speaker_pin_invalid")
            require(all(isinstance(sha, str) and len(sha) == 64 and set(sha) <= set("0123456789abcdef")
                        for sha in speakers["files"].values()), "speaker_pin_invalid")
            hashes.update({"Speakers/" + name: sha for name, sha in speakers["files"].items()})
            return hashes
        pins = attempt("model_pins", model_pins)
        if pins is not None:
            def model_inventory():
                root = app / "Speech"
                expected_directories = {str(parent) for name in pins for parent in Path(name).parents
                                        if parent != Path(".")}
                names = [str(path.relative_to(root)) for path in files if path.is_relative_to(root)]
                names += [str(path.relative_to(root)) for path in root.rglob("*")
                          if path.is_dir() and str(path.relative_to(root)) not in expected_directories]
                return sorted(names)
            names = attempt("model_resource_inventory", model_inventory)
            result["model_resource_names"] = names
            for name, expected in pins.items():
                path = app / "Speech" / name
                def model_hash():
                    require(path in files, "model_resource_missing_or_not_regular")
                    return digest(path)
                actual = attempt("model:" + name, model_hash)
                result["model_resources"][name] = dict(expected_sha256=expected, actual_sha256=actual,
                                                       matches=actual == expected if actual is not None else None)
            checks["all_model_resources_match"] = names == sorted(pins) and all(
                item["matches"] is True for item in result["model_resources"].values())
    result["failed_assertions"] = [key for key, value in checks.items() if value is False]
    result["unchecked_assertions"] = [key for key, value in checks.items() if value is None]
    result["status"] = "passed" if all(value is True for value in checks.values()) and not result["errors"] else "failed"
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--variant", choices=("release", "beta", "local-upgrade"), default="release")
    parser.add_argument("--output", type=Path, required=True, help="A new JSON report path outside the .app")
    args = parser.parse_args(argv)
    app, output = args.app.absolute(), args.output.absolute()
    if output.resolve().is_relative_to(app.resolve()) or os.path.lexists(output):
        print(json.dumps(dict(status="not_executed", error="output_must_be_new_and_outside_app")))
        return 2
    result = audit(app, variant=args.variant)
    with output.open("x") as stream:
        json.dump(result, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())

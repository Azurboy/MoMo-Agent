"""Contracts for MoMo-owned initialization and environment isolation."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("momo_agent", ROOT / "Apps/MacApp/Runtime/momo_agent.py")
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class BundledRuntimeTests(unittest.TestCase):
    def test_offline_bundle_uses_its_interpreter_and_preserves_existing_data(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "Moved App/AgentRuntime"
            executable = root / "python/bin/python3.14"
            executable.parent.mkdir(parents=True)
            executable.write_text("synthetic")
            executable.chmod(0o755)
            fingerprint = runtime.fingerprint()
            manifest = {"schema_version": 1, "architecture": runtime.platform.machine(), "dependencies": fingerprint}
            (root / "runtime-manifest.json").write_text(json.dumps(manifest))
            data = Path(tmp) / "data"
            runtime.initialize(data, 19000)
            (data / "runtime/engine.json").write_text('{"engine":"hermes","proactive_mode":"auto"}\n')
            before = {str(p.relative_to(data)): p.read_bytes() for p in data.rglob("*") if p.is_file()}
            with patch.object(runtime, "REPOSITORY", root), patch.object(runtime, "fingerprint", return_value=fingerprint), \
                    patch.object(runtime, "prepare_access") as install, patch.object(runtime.subprocess, "run") as child:
                runtime._prepare_base_python(data)
                self.assertEqual(runtime.prepared_python(data), executable)
                install.assert_not_called()
                child.assert_not_called()
            self.assertEqual(before, {str(p.relative_to(data)): p.read_bytes() for p in data.rglob("*") if p.is_file()})
            for field, invalid in [("architecture", "wrong"), ("dependencies", {}), ("schema_version", 99)]:
                bad = dict(manifest, **{field: invalid})
                (root / "runtime-manifest.json").write_text(json.dumps(bad))
                with patch.object(runtime, "REPOSITORY", root), self.assertRaises(ValueError):
                    runtime.prepared_python(data)
            (root / "runtime-manifest.json").write_text(json.dumps(manifest))
            executable.unlink()
            with patch.object(runtime, "REPOSITORY", root), self.assertRaises(ValueError):
                runtime.prepared_python(data)


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.data = Path(self.directory.name) / "agent"

    def test_reinitialization_preserves_identity_credential_and_configuration(self):
        first = runtime.initialize(self.data, 8765)
        credential = (self.data / "api-key").read_bytes()
        config = self.data / "profile/config.yaml"
        configured = json.loads(config.read_text())
        configured["model"]["default"] = "chosen-by-user"
        config.write_text(json.dumps(configured))
        self.assertEqual(first, runtime.initialize(self.data, 8765))
        self.assertEqual(credential, (self.data / "api-key").read_bytes())
        self.assertEqual(json.loads(config.read_text())["model"]["default"], "chosen-by-user")
        self.assertEqual((self.data / "api-key").stat().st_mode & 0o777, 0o600)
        with self.assertRaises(ValueError):
            runtime.initialize(self.data, 8766)

    def test_nonempty_unowned_directory_is_preserved(self):
        self.data.mkdir()
        original = self.data / "personal.txt"
        original.write_text("keep this")
        with self.assertRaises(ValueError):
            runtime.initialize(self.data, 8765)
        self.assertEqual(original.read_text(), "keep this")
        self.assertFalse((self.data / "connection.json").exists())

    def test_partial_or_nonprivate_credential_is_not_accepted(self):
        runtime.initialize(self.data, 8765)
        token = self.data / "api-key"
        token.chmod(0o644)
        with self.assertRaises(ValueError):
            runtime.read_connection(self.data)
        token.chmod(0o600)
        (self.data / "profile/config.yaml").unlink()
        with self.assertRaises(ValueError):
            runtime.read_connection(self.data)

    def test_environment_does_not_adopt_another_hermes_or_provider(self):
        with patch.dict(os.environ, {"HERMES_HOME": "/elsewhere", "HERMES_RUNTIME_DIR": "/other-tools",
                                     "OPENAI_API_KEY": "unrelated-secret", "PYTHONPATH": "/unrelated"}):
            child = runtime.child_environment(self.data)
        self.assertEqual(child["HERMES_HOME"], str(self.data / "profile"))
        self.assertEqual(child["HERMES_RUNTIME_DIR"], str(self.data / "runtime/tools"))
        self.assertNotIn("OPENAI_API_KEY", child)
        self.assertNotIn("PYTHONPATH", child)
        self.assertEqual(child["PYTHONPYCACHEPREFIX"], str(self.data / "runtime/bytecode"))

    def test_finder_launch_exports_system_proxy_and_always_bypasses_local_services(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(runtime, 'system_proxy_environment', return_value={
                'HTTP_PROXY': 'http://127.0.0.1:7890', 'HTTPS_PROXY': 'http://127.0.0.1:7890', 'NO_PROXY': '*.local,10.0.0.0/8'}):
            child = runtime.child_environment(self.data)
        self.assertEqual(child['HTTPS_PROXY'], 'http://127.0.0.1:7890')
        self.assertEqual(child['no_proxy'], '*.local,10.0.0.0/8,127.0.0.1,localhost,::1')
        self.assertEqual(child['NO_PROXY'], child['no_proxy'])

    def test_explicit_proxy_and_bypass_policy_win_over_system_settings(self):
        for bypass in ['*', 'internal.example']:
            with patch.dict(os.environ, {'https_proxy': 'http://operator.invalid:8080', 'no_proxy': bypass}, clear=True), \
                    patch.object(runtime, 'system_proxy_environment') as system:
                child = runtime.child_environment(self.data)
            system.assert_not_called()
            self.assertNotIn('HTTPS_PROXY', child)
            self.assertEqual(child['https_proxy'], 'http://operator.invalid:8080')
            self.assertEqual(child['NO_PROXY'], '*' if bypass == '*' else 'internal.example,127.0.0.1,localhost,::1')

    def test_existing_profile_keeps_credentials_model_and_identity(self):
        connection = runtime.initialize(self.data, 8765)
        profile = self.data / "profile"
        profile.rename(self.data / "hermes")
        self.assertEqual(runtime.read_connection(self.data), connection)
        self.assertEqual(runtime.profile_directory(self.data), self.data / "hermes")
        self.assertFalse(profile.exists())

    def test_network_dependency_upgrade_preserves_agent_fingerprint_and_identity(self):
        connection = runtime.initialize(self.data, 8765)
        (self.data / 'runtime/engine.json').write_text('{"engine":"hermes","proactive_mode":"auto"}\n')
        executable = self.data / 'runtime/venv/bin/python'; executable.parent.mkdir(parents=True); executable.touch()
        record = runtime.fingerprint(); record.pop('access_lock_sha256')
        marker = self.data / 'runtime/prepared.json'; marker.write_text(json.dumps(record))
        phases = []
        with patch.object(runtime, 'prepare_access') as install:
            runtime._prepare_base_python(self.data, progress=phases.append)
            install.assert_called_once_with(self.data)
        self.assertEqual(['connection', 'ready'], phases)
        self.assertEqual(runtime.fingerprint(), json.loads(marker.read_text()))
        self.assertEqual(connection, runtime.read_connection(self.data))
        self.assertEqual(executable, runtime.prepared_python(self.data))

    def prepared_fixture(self):
        runtime.initialize(self.data, 8765)
        (self.data / 'runtime/engine.json').write_text('{"engine":"hermes","proactive_mode":"auto"}\n')
        executable = self.data / 'runtime/venv/bin/python'
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b'existing interpreter')
        record = runtime.fingerprint()
        record['source'] = '/removed/MoMoAgent-deliveries/main-1.36.0/runtime-source/Vendor/HermesAgent'
        marker = self.data / 'runtime/prepared.json'
        marker.write_text(json.dumps(record))
        return executable, marker, record

    def test_release_path_change_reuses_environment_and_preserves_user_data(self):
        executable, marker, _ = self.prepared_fixture()
        memory = self.data / 'profile/MEMORY.md'
        memory.write_text('User-owned memory remains unchanged.')
        preserved = {p: p.read_bytes() for p in self.data.rglob('*') if p.is_file() and p != marker}
        # Starting directly after an app update must work even before maintenance.
        self.assertEqual(executable, runtime.prepared_python(self.data))
        phases = []
        with patch.object(runtime, 'prepare_access') as install:
            runtime._prepare_base_python(self.data, progress=phases.append)
            runtime._prepare_base_python(self.data, progress=phases.append)
            install.assert_not_called()
        self.assertEqual(['ready', 'ready'], phases)
        self.assertEqual(runtime.fingerprint(), json.loads(marker.read_text()))
        self.assertEqual(0o600, marker.stat().st_mode & 0o777)
        self.assertEqual(preserved, {p: p.read_bytes() for p in preserved})

    def test_source_move_does_not_hide_actual_agent_dependency_changes(self):
        _, marker, record = self.prepared_fixture()
        for field in ['lock_sha256', 'manifest_sha256', 'upstream_commit', 'extras']:
            with self.subTest(field=field):
                changed = dict(record); changed[field] = 'different'
                marker.write_text(json.dumps(changed))
                with patch.object(runtime, 'prepare_access') as install:
                    with self.assertRaises(ValueError): runtime.prepared_python(self.data)
                    with self.assertRaisesRegex(ValueError, 'Agent dependencies changed'):
                        runtime._prepare_base_python(self.data)
                    install.assert_not_called()
                self.assertEqual(changed, json.loads(marker.read_text()))

    def test_source_move_and_network_upgrade_keep_failure_retryable(self):
        _, marker, record = self.prepared_fixture()
        record['access_lock_sha256'] = 'older-adapter'
        marker.write_text(json.dumps(record))
        with patch.object(runtime, 'prepare_access', side_effect=OSError('offline')):
            with self.assertRaises(OSError): runtime._prepare_base_python(self.data)
        self.assertEqual(record, json.loads(marker.read_text()))
        with self.assertRaises(ValueError): runtime.prepared_python(self.data)
        with patch.object(runtime, 'prepare_access') as install:
            runtime._prepare_base_python(self.data)
            install.assert_called_once_with(self.data)
        self.assertEqual(runtime.fingerprint(), json.loads(marker.read_text()))

    def test_missing_python_is_not_accepted_after_a_source_move(self):
        executable, marker, record = self.prepared_fixture()
        executable.unlink()
        with self.assertRaises(ValueError): runtime.prepared_python(self.data)
        with self.assertRaises(ValueError): runtime._prepare_base_python(self.data)
        self.assertEqual(record, json.loads(marker.read_text()))

    def test_failed_network_upgrade_does_not_mark_environment_prepared(self):
        runtime.initialize(self.data, 8765)
        executable = self.data / 'runtime/venv/bin/python'; executable.parent.mkdir(parents=True); executable.touch()
        record = runtime.fingerprint(); record.pop('access_lock_sha256')
        marker = self.data / 'runtime/prepared.json'; marker.write_text(json.dumps(record))
        phases = []
        with patch.object(runtime, 'prepare_access', side_effect=OSError('offline')):
            with self.assertRaises(OSError): runtime._prepare_base_python(self.data, progress=phases.append)
        self.assertEqual(['connection'], phases)
        self.assertEqual(record, json.loads(marker.read_text()))
        with self.assertRaises(ValueError): runtime.prepared_python(self.data)


if __name__ == "__main__":
    unittest.main()

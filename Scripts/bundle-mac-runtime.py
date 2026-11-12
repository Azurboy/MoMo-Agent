#!/usr/bin/env python3
"""Embed a clean, locked runtime into a built Mac app before its final signing.

Run with uv run --no-project python scripts/bundle-mac-runtime.py --help.
The input interpreter must be a relocatable python-build-standalone distribution.
Never reads an installed MoMo data directory or copies a user's virtualenv.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MAGICS = {bytes.fromhex(x) for x in ('feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}
EXCLUDED = {'tests', 'website', 'apps', 'ui', 'ui-tui', 'docs', 'contributors', '.github', '__pycache__', '.venv', 'node_modules'}


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


# MoMo reuses provider, web-tool and packaging libraries from this upstream.
# Its standalone launchers and agent loop are not part of the Mac runtime.
RETIRED_ENTRY_POINTS = {'cli.py', 'run_agent.py', 'gateway/run.py', 'hermes_cli/main.py'}


def copy_sources(destination):
    paths = run('git', '-C', ROOT, 'ls-files', '-z', 'Apps/MacApp/Runtime', 'Apps/MacApp/Access',
                'Apps/MacApp/Context', 'Vendor/HermesAgent', 'Vendor/HermesAgent.UPSTREAM.json',
                'Vendor/SuperAgent', 'Vendor/SuperAgent.UPSTREAM.json', capture_output=True).stdout
    for raw in paths.split(b'\0'):
        if not raw:
            continue
        relative = Path(os.fsdecode(raw))
        if relative.parts[:2] == ('Vendor', 'HermesAgent'):
            upstream_path = relative.relative_to('Vendor/HermesAgent')
            if upstream_path.as_posix() in RETIRED_ENTRY_POINTS or any(p in EXCLUDED for p in upstream_path.parts):
                continue
        source = ROOT / relative
        if source.name == '.env' or source.is_symlink():
            raise ValueError(f'Unexpected runtime source: {relative}')
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)


def bundle(app, python_home, identity):
    target = app / 'Contents/Resources/AgentRuntime'
    if target.exists():
        raise FileExistsError(target)
    interpreter = python_home / 'bin/python3.14'
    probe = json.loads(run(interpreter, '-I', '-c', 'import sys,platform,json,sqlite3;print(json.dumps([sys.version_info[:2],platform.machine(),sys.base_prefix,sqlite3.sqlite_version_info]))', capture_output=True, text=True).stdout)
    if probe[:2] != [[3, 14], platform.machine()] or Path(probe[2]).resolve() != python_home.resolve():
        raise ValueError('Expected a standalone Python 3.14 for the build host architecture')
    if tuple(probe[3]) < (3, 51, 3):
        raise ValueError('Standalone Python must include SQLite 3.51.3 or newer')
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='momo-runtime-build-', dir=target.parent) as temp:
        stage = Path(temp) / 'AgentRuntime'
        stage.mkdir()
        copy_sources(stage)
        shutil.copytree(python_home, stage / 'python', symlinks=True, ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
        sys.path.insert(0, str(ROOT / 'Vendor/HermesAgent'))
        from pm.operations import build_environment
        venv = Path(temp) / 'venv'
        executable = build_environment(source=ROOT / 'Vendor/HermesAgent', out=venv, python=interpreter,
            extras=['mcp', 'messaging', 'anthropic'], no_install_project=True, frozen=True, sealed=True, explicit=True, terminal_progress=True)
        uv = shutil.which('uv')
        if uv is None:
            raise ValueError('uv is required on the build machine')
        run(uv, 'pip', 'install', '--python', executable, '--no-deps', '--require-hashes', '-r', ROOT / 'Apps/MacApp/Access/requirements.lock')
        run(uv, 'pip', 'check', '--python', executable)
        sites = list((venv / 'lib').glob('python*/site-packages'))
        if len(sites) != 1:
            raise ValueError('Expected one dependency site-packages directory')
        site = stage / 'python/lib/python3.14/site-packages'
        shutil.rmtree(site)
        shutil.copytree(sites[0], site, symlinks=True, ignore=shutil.ignore_patterns('__pycache__', '*.pyc', '_virtualenv.*'))
        # Entry point scripts from the build venv contain absolute paths; the app
        # starts Python modules directly and never ships these build-time wrappers.
        for path in (stage / 'python/bin').iterdir():
            if path.name not in {'python', 'python3', 'python3.14'}:
                path.unlink()
        spec = importlib.util.spec_from_file_location('bundle_runtime', stage / 'Apps/MacApp/Runtime/momo_agent.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        dependencies = module.fingerprint()
        dependencies.pop('source')
        manifest = {'schema_version': 1, 'architecture': platform.machine(), 'dependencies': dependencies,
                    'bundled_extras': ['mcp', 'messaging', 'anthropic'],
                    'sqlite_version': '.'.join(map(str, probe[3])),
                    'python_version': run(interpreter, '--version', capture_output=True, text=True).stdout.strip(),
                    'python_binary_sha256': hashlib.sha256(interpreter.read_bytes()).hexdigest()}
        (stage / 'runtime-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        for path in stage.rglob('*'):
            if path.is_symlink():
                if not path.resolve().is_relative_to(stage.resolve()):
                    raise ValueError(f'External symlink in runtime: {path.relative_to(stage)}')
            elif path.is_file():
                with path.open('rb') as f:
                    macho = f.read(4) in MAGICS
                if macho:
                    # uv gives standalone libpython an absolute install ID.
                    # Rewrite only references into the supplied Python tree.
                    if path.suffix == '.dylib':
                        run('install_name_tool', '-id', '@rpath/' + path.name, path)
                    libraries = [line for line in run('otool', '-L', path, capture_output=True, text=True).stdout.splitlines() if line.startswith('\t')]
                    for line in libraries:
                        lib = line.strip().split(' (')[0]
                        if lib.startswith(str(python_home) + '/'):
                            local = stage / 'python' / Path(lib).relative_to(python_home)
                            run('install_name_tool', '-change', lib, '@loader_path/' + os.path.relpath(local, path.parent), path)
                    libraries = [line for line in run('otool', '-L', path, capture_output=True, text=True).stdout.splitlines() if line.startswith('\t')]
                    for line in libraries:
                        lib = line.strip().split(' (')[0]
                        if lib.startswith('/') and not lib.startswith(('/usr/lib/', '/System/Library/')):
                            raise ValueError(f'External library {lib} in {path.relative_to(stage)}')
                    run('codesign', '--force', '--sign', identity, path, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        stage.rename(target)
    # Verify relocation with no user site, no developer PATH, and no downloads.
    env = {'PATH': '/usr/bin:/bin', 'HOME': '/var/empty', 'PYTHONDONTWRITEBYTECODE': '1', 'UV_OFFLINE': '1'}
    run(target / 'python/bin/python3.14', '-I', '-B', '-c',
        'import ssl,sqlite3,aiohttp,aiortc,cryptography,openai,anthropic,mcp; print("Bundled imports passed")', env=env)
    info = app / 'Contents/Info.plist'
    values = plistlib.loads(info.read_bytes())
    values.pop('MoMoRepositoryRoot', None)
    info.write_bytes(plistlib.dumps(values, fmt=plistlib.FMT_BINARY))
    run('codesign', '--force', '--sign', identity, '--preserve-metadata=entitlements,requirements,flags,identifier', app)
    run('codesign', '--verify', '--deep', '--strict', app)
    print(json.dumps({'app': str(app), 'runtime_bytes': sum(p.stat().st_size for p in target.rglob('*') if p.is_file()), **manifest}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--python-home', required=True, type=Path)
    parser.add_argument('--sign', required=True, help='Apple Development/Developer ID identity; never ad-hoc for delivery')
    args = parser.parse_args()
    if args.sign == '-':
        parser.error('A stable signing identity is required')
    bundle(args.app.resolve(), args.python_home.resolve(), args.sign)

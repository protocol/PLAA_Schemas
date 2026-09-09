#!/usr/bin/env python3
"""Only creates disposable clusters. Never accepts a DSN or ambient PG connection vars."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
VERSION = '16.10'
ENV = {k: v for k, v in os.environ.items() if not k.startswith('PG')}
ENV['TZ'] = 'UTC'


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, env=ENV, text=True, **kw)


def verify_checksum(name, recorded, actual):
    if recorded != actual:
        raise ValueError(f'applied migration modified: {name}')


def suite(psql, temp):
    def sql(text):
        return run(psql + ['-X', '-q', '-v', 'ON_ERROR_STOP=1', '-A', '-t'], input=text, capture_output=True).stdout.strip()
    assert sql('SHOW server_version;').split()[0] == VERSION, 'exact PostgreSQL version pin mismatch'
    sql('CREATE DATABASE plaa_service;')
    psql += ['-d', 'plaa_service']
    sql('CREATE TABLE public.schema_migration(name text PRIMARY KEY, sha256 text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now()); REVOKE ALL ON public.schema_migration FROM PUBLIC;')
    migrations = sorted((ROOT / 'migrations').glob('*.sql'))
    applied = replayed = 0
    for replay in (False, True):
        for path in migrations:
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            recorded = sql(f"SELECT sha256 FROM public.schema_migration WHERE name='{path.name}';")
            if recorded:
                verify_checksum(path.name, recorded, digest)
                replayed += 1
            else:
                sql('BEGIN;\n' + path.read_text() + f"\nINSERT INTO public.schema_migration(name,sha256) VALUES('{path.name}','{digest}'); COMMIT;")
                applied += 1
    # Exercise the same checksum rejection branch without editing project migrations.
    sample = migrations[0]
    try:
        verify_checksum(sample.name, sql(f"SELECT sha256 FROM public.schema_migration WHERE name='{sample.name}';"), hashlib.sha256(sample.read_bytes() + b'-- changed').hexdigest())
    except ValueError:
        pass
    else:
        raise AssertionError('modified applied migration was not rejected')
    print(f'Migrations: {applied} installed, {replayed} checksum replays, changed-content checksum detected', flush=True)
    sql((ROOT / 'examples' / 'synthetic.sql').read_text())
    env = ENV | {'PLAA_TEST_PSQL': json.dumps(psql), 'PLAA_DISPOSABLE_MARKER': str(temp / 'disposable')}
    subprocess.run([sys.executable, str(ROOT / 'tests' / 'test_schema.py')], env=env, cwd=ROOT, check=True)
    counts = sql("SELECT schemaname||'.'||tablename FROM pg_tables WHERE schemaname IN ('plaa','ingest','export') ORDER BY 1;")
    print(f'Introspection: {len(counts.splitlines())} project tables; PostgreSQL {VERSION}; fresh-only upgrade boundary', flush=True)


def main():
    # Unix socket paths have a ~104-byte platform limit; nested macOS TMPDIRs exceed it.
    # mkdtemp creates this unpredictable directory with mode 0700, even under /tmp.
    with tempfile.TemporaryDirectory(prefix='plaa-disposable-', dir='/tmp') as directory:
        temp = Path(directory)
        (temp / 'disposable').write_text('new-private-cluster-only')
        if '--docker' in sys.argv:
            project = 'plaa-test-' + uuid.uuid4().hex[:12]
            compose = ['docker', 'compose', '-f', str(ROOT / 'compose.yaml'), '-p', project]
            try:
                run(compose + ['up', '-d', '--wait'], cwd=ROOT)
                suite(compose + ['exec', '-T', 'db', 'psql', '-U', 'postgres'], temp)
            finally:
                run(compose + ['down', '--volumes', '--remove-orphans'], cwd=ROOT)
        else:
            binary = Path(os.environ.get('PLAA_PG_BIN', '/opt/homebrew/opt/postgresql@16/bin'))
            if not (binary / 'initdb').exists():
                found = shutil.which('initdb')
                if not found:
                    raise SystemExit('PostgreSQL 16.10 native tools required; use make test-docker or PLAA_PG_BIN')
                binary = Path(found).parent
            version = run([str(binary / 'postgres'), '--version'], capture_output=True).stdout
            if f' {VERSION} ' not in version and not version.rstrip().endswith(' ' + VERSION):
                raise SystemExit(f'Requires exact PostgreSQL {VERSION}; found {version.strip()}')
            data = temp / 'data'
            socket = temp / 'socket'
            socket.mkdir(mode=0o700)
            started = False
            try:
                run([str(binary / 'initdb'), '-D', str(data), '-U', 'postgres', '--auth-local=trust', '--auth-host=reject', '--no-locale', '--encoding=UTF8'], capture_output=True)
                run([str(binary / 'pg_ctl'), '-D', str(data), '-l', str(temp / 'postgres.log'), '-o', f"-k {socket} -p 55439 -c listen_addresses='' -c timezone=UTC", '-w', 'start'], capture_output=True)
                started = True
                suite([str(binary / 'psql'), '-h', str(socket), '-p', '55439', '-U', 'postgres'], temp)
            except Exception:
                if (temp / 'postgres.log').exists():
                    print((temp / 'postgres.log').read_text()[-12000:], file=sys.stderr)
                raise
            finally:
                if started:
                    run([str(binary / 'pg_ctl'), '-D', str(data), '-m', 'immediate', '-w', 'stop'], capture_output=True)


if __name__ == '__main__':
    main()

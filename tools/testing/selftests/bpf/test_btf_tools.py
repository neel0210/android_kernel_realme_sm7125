#!/usr/bin/env python3
"""Check BTF build prerequisites fail early and select compatible pahole kinds."""
import os
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[4]
with tempfile.TemporaryDirectory() as tmp:
    path = pathlib.Path(tmp)
    pahole = path / 'pahole'
    resolver = path / 'resolve_btfids'
    resolver.write_text('#!/bin/sh\nexit 0\n')
    resolver.chmod(0o755)
    env = dict(os.environ, PAHOLE=str(pahole), RESOLVE_BTFIDS=str(resolver))

    def run():
        return subprocess.run(['sh', str(root/'scripts/btf-tools.sh')], env=env,
                              capture_output=True, text=True)

    def version(v, help_text=''):
        pahole.write_text(f'#!/bin/sh\ncase "$1" in\n--version) echo {v};;\n'
                          f'--help) echo "{help_text}";;\nesac\n')
        pahole.chmod(0o755)

    assert run().returncode != 0  # Missing tool must not silently omit BTF.
    version('v1.12')
    assert run().returncode != 0
    version('v1.21')
    assert run().returncode == 0 and run().stdout.strip() == ''
    flags = '--skip_encoding_btf_enum64 --skip_encoding_btf_decl_tag --skip_encoding_btf_type_tag'
    version('v1.27', flags)
    result = run()
    assert result.returncode == 0 and set(result.stdout.split()) == set(flags.split())
    resolver.unlink()
    assert run().returncode != 0
print('PASS: missing/old tools rejected; compatible pahole flags selected')

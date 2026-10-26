#!/usr/bin/env python3
"""Link the Mix CPU proof to the debug app objects, then run it outside tests."""
import os
from pathlib import Path
import subprocess
import sys

app = Path(__file__).resolve().parents[1]
proof = Path(sys.argv[1]).resolve()
products = app / '.build/out/Products/Debug'
intermediates = app / '.build/out/Intermediates.noindex/JRBar.build/Debug'
objects = []
for module in ['JRBarLEDS', 'JRBarCore', 'JRBarUI', 'JRBarApp']:
    directory = next(intermediates.glob(module + '--*-testable-t.build')) if module == 'JRBarApp' else intermediates / (module + '-t.build')
    objects.extend(str(path) for path in (directory / 'Objects-normal/arm64').glob('*.o') if path.name != 'main.o')
binary = proof / 'studio-preview-cost'
subprocess.run(['swiftc', '-parse-as-library', '-I', str(products), '-F', str(products),
                str(app / 'scripts/studio-preview-cost.swift'), *objects, '-o', str(binary)], check=True)
environment = dict(os.environ, JRBAR_RENDER_PROOF_DIR=str(proof))
environment.pop('JRBAR_INTERACTIVE_TESTS', None)
subprocess.run([str(binary)], env=environment, check=True)

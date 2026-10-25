"""Synthetic command menu with an append-only record of every input byte."""
import json
import os
import select
import sys
import tty
from pathlib import Path

if '--version' in sys.argv:
    print('2.1.309 (Claude Code)')
    sys.exit(0)

mode = os.environ.get('FAKE_CLAUDE_MODE', 'normal')
log = Path(os.environ['FAKE_CLAUDE_INPUT'])
config = Path(os.environ['CLAUDE_CONFIG_DIR'])
settings = json.loads((config / '.claude.json').read_text())
assert settings['projects'] == {os.getcwd(): {'hasTrustDialogAccepted': True}}
assert settings['hasCompletedOnboarding']
assert Path.home() != config and Path.cwd() != config
assert list(Path.cwd().iterdir()) == []
assert os.pread(int(os.environ['CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR']), 64, 0) == b'synthetic-access'
assert '--allowed-tools' in sys.argv and '--strict-mcp-config' in sys.argv
assert '/usage' not in sys.argv
assert 'ANTHROPIC_AUTH_TOKEN' not in os.environ
assert 'JRBAR_SECRET' not in os.environ

tty.setraw(sys.stdin.fileno())


def draw(text):
    sys.stdout.write('\x1b[2J\x1b[H' + text.replace('\n', '\r\n'))
    sys.stdout.flush()


def read(count):
    received = b''
    while len(received) < count:
        if not select.select([sys.stdin], [], [], 3)[0]:
            sys.exit(0)
        chunk = os.read(sys.stdin.fileno(), count - len(received))
        with log.open('ab') as output:
            output.write(chunk)
        received += chunk
    return received


blockers = {'onboarding': 'Welcome to Claude Code', 'trust': 'Do you trust the files in this folder?',
            'login': 'Select login method:', 'api_key': 'API key:', 'choice': '\u276f 1. Yes'}
if mode in blockers:
    draw(blockers[mode])
    read(1)
    sys.exit(0)
if mode == 'crash':
    sys.exit(1)
draw('\u276f\n? for shortcuts')
assert read(6) == b'/usage'
if mode == 'wrong_menu':
    draw('\u276f /usage-custom Show session cost and plan usage')
    read(1)
    sys.exit(0)
if mode == 'unselected_menu':
    draw('/usage Show session cost and plan usage')
    read(1)
    sys.exit(0)
draw('\u276f /usage Show session cost and plan usage')
assert read(1) == b'\r'
if mode == 'slow':
    draw('Current session\n25% used\nCurrent week (all models)\nLoading usage')
    # Wait for a bounded readiness timeout, rather than a wall-clock sleep.
    if select.select([sys.stdin], [], [], 0.5)[0]:
        raise AssertionError('input before complete draw')
if mode == 'partial':
    draw('Current session\n25% used\nCurrent week (all models)\nLoading usage')
    read(1)
    sys.exit(0)
if mode == 'assistant':
    projects = config / 'projects' / 'synthetic'
    projects.mkdir(parents=True)
    (projects / 'session.jsonl').write_text(json.dumps({'type': 'assistant', 'message': {'model': 'synthetic'}}) + '\n')
draw('Current session\n25% used\nCurrent week (all models)\n40% used\nEscape to close')
assert read(1) == b'\x1b'
draw('\u276f\n? for shortcuts')
assert read(5) == b'/exit'
read(1)

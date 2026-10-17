"""Recovery policy runs without Disk Arbitration sessions or real PID files."""
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

SOURCE = Path(__file__).resolve().parents[1] / "src/jrbar/resources/sd_eject_guard.c"
CLANG = shutil.which("clang")

HARNESS = r'''
#define JRBAR_GUARD_TEST 1
#include "%s"
#include <assert.h>
#include <string.h>
int main(int argc, char **argv) {
    assert(argc == 2);
    const char *path = argv[1];
    assert(read_daemon_pid(path) == 0);
    const char *invalid[] = {"", "0", "-1", "abc", "12 junk", "2147483648", "9999999999999999999999999999999999999999999999999999999999999999999999"};
    for (unsigned i=0; i<sizeof(invalid)/sizeof(invalid[0]); i++) {
        FILE *f=fopen(path,"w"); assert(f); fputs(invalid[i],f); fclose(f);
        assert(read_daemon_pid(path)==0);
    }
    FILE *f=fopen(path,"w"); assert(f); fputs("123\n",f); fclose(f);
    assert(read_daemon_pid(path)==123);
    // A restart between the initial read and callback registration is detected.
    daemon_watch registration={read_daemon_pid(path),false};
    f=fopen(path,"w"); assert(f); fputs("124\n",f); fclose(f);
    assert(daemon_watch_changed(&registration,read_daemon_pid(path)));
    assert(!daemon_watch_changed(&registration,read_daemon_pid(path)));
    // A transient read failure must not replace the original identity.
    daemon_watch gap={124,false};
    assert(remove(path)==0);
    assert(!daemon_watch_changed(&gap,read_daemon_pid(path)));
    assert(gap.initial_pid==124);
    f=fopen(path,"w"); assert(f); fputs("125\n",f); fclose(f);
    assert(daemon_watch_changed(&gap,read_daemon_pid(path)));
    daemon_watch known={123,false};
    assert(!daemon_watch_changed(&known,123));
    assert(!daemon_watch_changed(&known,0));
    assert(daemon_watch_changed(&known,124));
    assert(!daemon_watch_changed(&known,125));
    daemon_watch unknown={0,false};
    assert(!daemon_watch_changed(&unknown,0));
    assert(daemon_watch_changed(&unknown,123));
    assert(!daemon_watch_changed(&unknown,124));
    puts("ok");
}
'''


@pytest.mark.skipif(CLANG is None, reason="needs the system C compiler")
def test_daemon_restart_policy_and_pid_parser(tmp_path: Path) -> None:
    harness = tmp_path / "recovery.c"
    harness.write_text(HARNESS % SOURCE)
    binary = tmp_path / "recovery"
    compiled = subprocess.run(
        [CLANG, "-Wall", "-Wextra", "-Werror", "-Wno-unused-function",
         str(harness), "-o", str(binary)], capture_output=True, text=True, timeout=30)
    assert compiled.returncode == 0, compiled.stderr
    result = subprocess.run([str(binary), str(tmp_path / "synthetic.pid")],
                            capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    assert result.stdout == "ok\n"

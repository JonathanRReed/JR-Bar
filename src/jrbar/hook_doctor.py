"""``jrbar hooks doctor``: which command each provider's hook runs today.

Content-free by construction: config paths, the command shape (shim /
python / legacy / none), whether the daemon's ingress socket answers, and
how many payloads are queued in ``*.pending.jsonl``. Nothing from any
payload is read or printed.
"""

from __future__ import annotations

import os
import re
import shlex
import socket
import time
from pathlib import Path
from typing import Any

from .core_server import default_core_socket_path
from .hook_pending import pending_hook_files
from .install import hook_command_arguments, hook_shim_path
from .providers import HOOK_CLIENT_MODULES, HOOK_SHIM_NAME, PROVIDER_SPECS, _is_jrbar_hook_invocation, detect_log_path
from .state_paths import default_state_dir


def classify_command(arguments: list[str]) -> str:
    if not arguments:
        return "none"
    if Path(arguments[0]).name == HOOK_SHIM_NAME:
        return "shim"
    if any(module in arguments for module in HOOK_CLIENT_MODULES):
        return "python"
    if _is_jrbar_hook_invocation(arguments):
        return "legacy"
    return "foreign"


def registered_commands(config_path: Path, provider: str) -> list[list[str]]:
    """Every JR-Bar hook invocation for ``provider`` found in the config text."""
    try:
        text = config_path.expanduser().read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    found: list[list[str]] = []
    pattern = re.compile(r"[^\"'\n]*--provider[= ]+" + re.escape(provider) + r"[^\"'\n]*")
    for match in pattern.finditer(text):
        candidate = match.group(0).strip()
        try:
            parts = shlex.split(candidate)
        except ValueError:
            continue
        if parts and (_is_jrbar_hook_invocation(parts) or "--provider" in parts):
            if parts not in found:
                found.append(parts)
    return found


def socket_answers(path: Path, timeout: float = 0.3) -> bool:
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    probe.settimeout(timeout)
    try:
        probe.connect(str(path))
        return True
    except OSError:
        return False
    finally:
        probe.close()


def hook_doctor_report(home: Path | None = None) -> dict[str, Any]:
    state_dir = default_state_dir(home)
    shim = hook_shim_path()
    providers: list[dict[str, Any]] = []
    for spec in PROVIDER_SPECS:
        entry: dict[str, Any] = {"provider": spec.provider, "label": spec.label}
        try:
            config = spec.detector(home)
            entry["config_path"] = str(config.config_path)
            entry["installed"] = bool(config.exists and config.hook_events)
            entry["hook_events"] = len(config.hook_events)
            registered = registered_commands(config.config_path, spec.provider)
            entry["registered"] = sorted({classify_command(parts) for parts in registered}) or (["none"])
            entry["registered_commands"] = [" ".join(shlex.quote(p) for p in parts) for parts in registered[:3]]
        except Exception as exc:
            entry["installed"] = False
            entry["error"] = exc.__class__.__name__
            entry["registered"] = ["unknown"]
            entry["registered_commands"] = []
        try:
            arguments = hook_command_arguments(spec.provider, detect_log_path(spec.provider, home))
            entry["would_install"] = classify_command(arguments)
            entry["would_install_command"] = " ".join(shlex.quote(p) for p in arguments)
        except Exception as exc:
            entry["would_install"] = "unknown"
            entry["would_install_command"] = exc.__class__.__name__
        providers.append(entry)
    pending = []
    for path in pending_hook_files(state_dir):
        try:
            lines = sum(1 for line in path.read_text(encoding="utf-8", errors="replace").splitlines() if line.strip())
        except OSError:
            lines = -1
        pending.append({"file": path.name, "lines": lines})
    ingress = state_dir / "hook-ingress.sock"
    core = default_core_socket_path()
    return {
        "checked_at": time.time(),
        "state_dir": str(state_dir),
        "shim": str(shim) if shim is not None else None,
        "shim_env": os.environ.get("JRBAR_HOOK_EXEC"),
        "ingress_socket": {"path": str(ingress), "answers": ingress.exists() and socket_answers(ingress)},
        "core_socket": {"path": str(core), "answers": core.exists() and socket_answers(core)},
        "pending": pending,
        "providers": providers,
    }


def render_hook_doctor(report: dict[str, Any]) -> str:
    lines = [
        f"state dir: {report['state_dir']}",
        f"hook shim: {report['shim'] or 'not built (python -m jrbar.hook_client is used)'}",
        f"ingress socket: {report['ingress_socket']['path']} "
        f"({'answering' if report['ingress_socket']['answers'] else 'not answering'})",
        f"core socket: {report['core_socket']['path']} "
        f"({'answering' if report['core_socket']['answers'] else 'not answering'})",
    ]
    if report["pending"]:
        lines.append("pending hook payloads:")
        for item in report["pending"]:
            lines.append(f"  {item['file']}: {item['lines']} line(s)")
    else:
        lines.append("pending hook payloads: none")
    lines.append("providers:")
    for entry in report["providers"]:
        state = "installed" if entry.get("installed") else "not installed"
        registered = ",".join(entry.get("registered", []))
        lines.append(
            f"  {entry['provider']:<12} {state:<14} runs={registered:<8} "
            f"next install={entry.get('would_install')}"
        )
        for command in entry.get("registered_commands", []):
            lines.append(f"      {command}")
    return "\n".join(lines)


__all__ = ["classify_command", "hook_doctor_report", "registered_commands", "render_hook_doctor"]

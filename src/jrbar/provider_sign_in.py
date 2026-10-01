"""Fix sign-in: the one click that does the best automatic thing.

A provider card that is stale or signed out used to offer "Reconnect" or
"Re-sign in", and both only re-read what the provider's own tooling held and
then told the person to go and run something. The button looked dead. This
module is what the new button asks the daemon to do, in this order:

1. Re-read what the provider's own tooling holds (``reconnect_provider``).
2. Claude only: Claude Code keeps its own sign-in in the Keychain and renews
   it when it makes a call. The owner mostly uses the desktop app, which
   does not renew the CLI's item, so the copy JR-Bar reads goes stale and
   stays stale. When ``claude auth status`` says Claude Code is logged in,
   one tiny real call through the CLI makes Claude Code renew its own item.
   JR-Bar never uses the refresh token itself: it would rotate it and log
   Claude Code out.
3. Otherwise open the owner's own terminal on the provider's sign-in
   command (a browser flow only a person can finish).
4. The caller arms the outcome watch and forces a usage refresh, so the card
   recovers the moment the CLI saves its new sign-in.

Every step ends in a plain sentence the app shows as it is. Nothing here
runs on a timer: it is a click, and only a click.
"""

from __future__ import annotations

import json
import os
import shlex
import shutil
import tempfile
import threading
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Final

from .product_identity import PRODUCT_DISPLAY_NAME
from .provider_cli import (
    PROVIDER_CLIS,
    ProviderCli,
    RunResult,
    resolve_cli,
    run_bounded,
    search_environment,
)
from .provider_reconnect import RepairOutcome, ResignInResult, credential_fingerprint, reconnect_provider

OUTCOMES: Final = ("renewed", "opened_terminal", "already_ok", "staged", "unavailable", "failed")

#: The one tiny real call that makes Claude Code renew its own Keychain item.
#: A fixed argv: nothing in a client's request reaches it.
RENEWAL_PROMPT: Final = "reply with the single word ok"
RENEWAL_TIMEOUT_SECONDS: Final = 90.0
AUTH_STATUS_TIMEOUT_SECONDS: Final = 10.0
#: A second renewal inside this long is refused: it would only repeat a call
#: that has just made one.
RENEWAL_COOLDOWN_SECONDS: Final = 60.0
RENEWAL_OUTPUT_CAP_BYTES: Final = 4096


@dataclass(frozen=True, slots=True)
class SignInResult:
    outcome: str
    #: One plain sentence, safe to show as it is.
    message: str
    #: The command a terminal was opened on, as a person types it.
    command: str | None = None
    sign_in_url: str | None = None


class ProviderSignIn:
    """The daemon's sign-in fixer. One lives for the daemon's life, so the
    60 s renewal limit and the one-at-a-time guard are real. Every outside
    effect is handed in, so a test runs it with fake executables, a fake
    terminal and a clock it winds by hand."""

    def __init__(
        self,
        *,
        locate: Callable[[str], str | None] = resolve_cli,
        run: Callable[..., RunResult] = run_bounded,
        open_terminal: Callable[..., dict[str, Any]] | None = None,
        clock: Callable[[], float] | None = None,
        fingerprint: Callable[[], tuple | None] | None = None,
        reconnect: Callable[..., ResignInResult] = reconnect_provider,
        make_scratch: Callable[[], str] | None = None,
        environ: Callable[[], Mapping[str, str]] | None = None,
        home: Callable[[], Path] = Path.home,
        log: Callable[[str], None] | None = None,
        credential_store: Any = None,
        clipboard_reader: Callable[[], str] | None = None,
        session_importer: Callable[..., str | None] | None = None,
    ) -> None:
        self._locate = locate
        self._run = run
        self._open_terminal = open_terminal
        self._clock = clock
        self._fingerprint = fingerprint
        self._reconnect = reconnect
        self._make_scratch = make_scratch or (lambda: tempfile.mkdtemp(prefix="jrbar-signin-"))
        self._environ = environ
        self._home = home
        self._log = log or (lambda _line: None)
        # What the card's own staged action reads and writes (Devin's rejected
        # token, a clipboard key, the browser session). Defaults are the real
        # ones; a test hands in fakes.
        self._credential_store = credential_store
        self._clipboard_reader = clipboard_reader
        self._session_importer = session_importer
        self._lock = threading.Lock()
        self._active: set[tuple[str, str]] = set()
        self._last_renewal_at: float | None = None

    # -- the click ----------------------------------------------------------

    def sign_in(
        self,
        provider: str,
        instance: str = "default",
        *,
        terminal: object = None,
        reason_code: str | None = None,
        signed_out: bool | None = None,
        action_label: str | None = None,
    ) -> SignInResult:
        """Do the best automatic thing for ``provider``. ``signed_out`` is
        the card's own word (True: it says sign in, False: it does not,
        None: nothing is known); a CLI that has no way to say whether it is
        signed in (Codex, OpenCode) is only opened for a card that does not
        rule it out. ``reason_code`` and ``action_label`` are the daemon's own
        facts about that card, never the client's: a provider with no login
        command of its own (Devin, Cursor, Gemini CLI, Antigravity, the OpenAI
        API) runs the card's staged action for its ``action_label``."""
        key = (provider, instance)
        with self._lock:
            if key in self._active:
                label = self._label(provider)
                return SignInResult("unavailable", f"A sign-in fix for {label} is already running.")
            self._active.add(key)
        try:
            result = self._sign_in(provider, instance, terminal, reason_code, signed_out, action_label)
        finally:
            with self._lock:
                self._active.discard(key)
        self._log(f"core: sign-in {provider} {result.outcome}")
        return result

    @staticmethod
    def _label(provider: str) -> str:
        cli = PROVIDER_CLIS.get(provider)
        return cli.label if cli is not None else provider

    def _sign_in(
        self,
        provider: str,
        instance: str,
        terminal: object,
        reason_code: str | None,
        signed_out: bool | None,
        action_label: str | None,
    ) -> SignInResult:
        cli = PROVIDER_CLIS.get(provider)
        if cli is None or cli.sign_in is None:
            # No login command to open: the card's own staged action is the fix
            # (clear a rejected token and re-import the browser session, open the
            # token page, say where the CLI or app signs in). It is the button the
            # card had before Fix sign-in, so it still works from this one.
            staged = self._staged_action(provider, instance, action_label, reason_code)
            if staged is not None:
                return staged
        # 1. What the provider's own tooling holds.
        try:
            reread = self._reconnect(provider, instance, reason_code=reason_code)
        except Exception:
            reread = ResignInResult(
                provider,
                f"Could not re-read the {self._label(provider)} sign-in.",
                outcome=RepairOutcome.UNAVAILABLE,
            )
        if instance != "default":
            # A second account's sign-in is not the CLI's: only re-read it.
            if reread.changed:
                return SignInResult("renewed", reread.message)
            return SignInResult(
                "unavailable",
                f"{reread.message} This is a second account, so its sign-in is not the "
                f"CLI's: {PRODUCT_DISPLAY_NAME} can only re-read it.",
                sign_in_url=reread.sign_in_url,
            )
        found = reread.outcome
        if found is RepairOutcome.REPAIRED:
            return SignInResult("renewed", reread.message)
        if found is RepairOutcome.ALREADY_HEALTHY:
            return SignInResult("already_ok", reread.message)
        if found is RepairOutcome.BLOCKED:
            return SignInResult("unavailable", reread.message)
        if provider == "claude":
            # 2. Ask Claude Code to renew its own sign-in; else 3.
            renewed = self._renew_claude(reread)
            if renewed is not None:
                return renewed
            return self._open_sign_in_terminal(provider, reread, terminal)
        if provider == "grok":
            return self._open_sign_in_terminal(provider, reread, terminal)
        if reread.changed:
            return SignInResult("renewed", reread.message)
        if signed_out is False:
            # The card does not say sign in, so a sign-in terminal would be
            # the wrong fix: say what the re-read found.
            return SignInResult("unavailable", reread.message, sign_in_url=reread.sign_in_url)
        return self._open_sign_in_terminal(provider, reread, terminal)

    # -- providers with no login command: the card's own staged action ----------

    def _staged_action(
        self,
        provider: str,
        instance: str,
        label: str | None,
        reason_code: str | None,
    ) -> SignInResult | None:
        """Run the staged flow behind the card's current action label
        (``provider_browser_access.handle_provider_usage_action``), or ``None``
        when that label is not part of it. A token page it would open is
        returned as ``sign_in_url`` for the app to open, so a page opens once."""
        if not label:
            return None
        opened: list[str] = []
        try:
            from .provider_browser_access import handle_provider_usage_action

            store = self._credential_store
            if store is None:
                from .provider_credential_store import ProviderCredentialStore

                store = ProviderCredentialStore()
            options: dict[str, Any] = {}
            if self._clipboard_reader is not None:
                options["clipboard_reader"] = self._clipboard_reader
            if self._session_importer is not None:
                options["session_importer"] = self._session_importer
            message = handle_provider_usage_action(
                provider,
                label,
                credential_store=store,
                url_opener=opened.append,
                reason_code=reason_code,
                source_instance_id=instance,
                **options,
            )
        except Exception:
            return None
        if message is None:
            return None
        return SignInResult("staged", message, sign_in_url=opened[0] if opened else None)

    # -- step 2: Claude Code renews its own Keychain item ---------------------

    def _now(self) -> float:
        if self._clock is not None:
            return self._clock()
        import time

        return time.monotonic()

    def _claude_fingerprint(self) -> tuple | None:
        if self._fingerprint is not None:
            return self._fingerprint()
        return credential_fingerprint(self._home(), "claude", fresh=True)

    def _renew_claude(self, reread: ResignInResult) -> SignInResult | None:
        """The quiet renewal. ``None`` means "fall through to the terminal":
        the CLI is missing, says it is not logged in, or the call did not
        renew anything. A result is final."""
        executable = self._locate("claude")
        if executable is None:
            return None
        now = self._now()
        last = self._last_renewal_at
        if last is not None and 0 <= now - last < RENEWAL_COOLDOWN_SECONDS:
            return SignInResult(
                "unavailable",
                "Claude Code was asked to renew its sign-in less than a minute ago. "
                f"Give it a moment: {PRODUCT_DISPLAY_NAME} rechecks on its own.",
            )
        try:
            scratch = self._make_scratch()
        except Exception:
            # No private folder, no call: a failure to report, never a crash.
            return SignInResult(
                "failed",
                f"{PRODUCT_DISPLAY_NAME} could not make a private working folder to ask Claude "
                "Code to renew its sign-in, so nothing was run. Run `claude auth login` in a "
                "terminal instead.",
            )
        try:
            os.chmod(scratch, 0o700)
            work = os.path.join(scratch, "work")
            state = os.path.join(scratch, "state")
            for folder in (work, state):
                os.mkdir(folder, 0o700)
            env = search_environment(self._environ() if self._environ is not None else None)
            # The hook shim honours this, so the call's events spool in the
            # scratch folder and no session reaches the live daemon.
            env["JRBAR_STATE_DIR"] = state
            status = self._run(
                [executable, "auth", "status"],
                cwd=work,
                env=env,
                timeout_seconds=AUTH_STATUS_TIMEOUT_SECONDS,
                output_cap=RENEWAL_OUTPUT_CAP_BYTES,
            )
            if not _logged_in(status):
                return None
            before = self._claude_fingerprint()
            self._last_renewal_at = self._now()
            call = self._run(
                [executable, "-p", RENEWAL_PROMPT, "--max-turns", "1"],
                cwd=work,
                env=env,
                timeout_seconds=RENEWAL_TIMEOUT_SECONDS,
                output_cap=RENEWAL_OUTPUT_CAP_BYTES,
            )
            if call.timed_out:
                return SignInResult(
                    "failed",
                    "Claude Code did not answer within 90 seconds, so its sign-in was not "
                    "renewed. Try again, or run `claude auth login` in a terminal.",
                )
            after = self._claude_fingerprint()
            if not after or after == before:
                return None
        except OSError:
            return None
        finally:
            shutil.rmtree(scratch, ignore_errors=True)
        # Claude Code saved a new sign-in: copy the fresh access token into
        # JR-Bar's own store so the forced refresh reads it at once.
        try:
            self._reconnect("claude", "default")
        except Exception:
            pass
        return SignInResult(
            "renewed",
            "Claude Code renewed its sign-in, so Claude usage is refreshing now.",
        )

    # -- step 3: the owner's terminal -------------------------------------------

    def _open_sign_in_terminal(
        self,
        provider: str,
        reread: ResignInResult,
        terminal: object,
    ) -> SignInResult:
        cli: ProviderCli | None = PROVIDER_CLIS.get(provider)
        display = cli.sign_in_display() if cli is not None else None
        if cli is None or cli.sign_in is None or display is None:
            return SignInResult("unavailable", reread.message, sign_in_url=reread.sign_in_url)
        executable = self._locate(cli.binary)
        if executable is None:
            return SignInResult(
                "unavailable",
                f"{cli.label} is not installed on this Mac (no `{cli.binary}` command was "
                "found), so there is nothing to sign in with.",
            )
        typed = " ".join(shlex.quote(part) for part in (executable, *cli.sign_in))
        opener = self._open_terminal
        if opener is None:
            from .answer_surfaces import run_command_in_terminal

            opener = run_command_in_terminal
        from .core_server import CommandError

        try:
            opened = opener(str(self._home()), typed, terminal=terminal)
        except CommandError as error:
            if error.code == "invalid_args":
                raise
            return self._terminal_failed(cli, display)
        except Exception:
            return self._terminal_failed(cli, display)
        app = str(opened.get("app") or "your terminal")
        follow = (
            f"{PRODUCT_DISPLAY_NAME} notices on its own"
            if cli.watches_sign_in
            else "then refresh this card"
        )
        return SignInResult(
            "opened_terminal",
            f"Opened {app} on `{display}`: finish signing in there, {follow}.",
            command=display,
        )

    @staticmethod
    def _terminal_failed(cli: ProviderCli, display: str) -> SignInResult:
        follow = (
            f"{PRODUCT_DISPLAY_NAME} notices on its own"
            if cli.watches_sign_in
            else "then refresh this card"
        )
        return SignInResult(
            "failed",
            f"{PRODUCT_DISPLAY_NAME} could not open a terminal. Run `{display}` yourself in "
            f"any terminal: {follow}.",
            command=display,
        )


def _logged_in(status: RunResult) -> bool:
    """Whether ``claude auth status``'s JSON says Claude Code is logged in.
    Only that one flag is read: nothing else in it is kept."""
    text = status.output
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end <= start:
        return False
    try:
        document = json.loads(text[start : end + 1])
    except ValueError:
        return False
    return isinstance(document, dict) and document.get("loggedIn") is True


__all__ = [
    "AUTH_STATUS_TIMEOUT_SECONDS",
    "OUTCOMES",
    "RENEWAL_COOLDOWN_SECONDS",
    "RENEWAL_PROMPT",
    "RENEWAL_TIMEOUT_SECONDS",
    "ProviderSignIn",
    "SignInResult",
]

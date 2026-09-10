> **Historical (pre-0.8).** A superpowers plan or spec from the PyObjC-era codebase, kept for provenance. Nothing in the build, the tests or the release gate reads it.

# Control-center completion implementation plan

Goal: finish the source-level Creator Micro control center without changing JR-Bar into an orchestrator.
Architecture: retain the canonical monitor, provider identities, native UI and sole HID owner. Add bounded file transfer, connection-scoped input, stable session assignments and an optional hardware-independent workspace.
Spec: the September 6 completion review approved in the conversation.

The owner explicitly deferred test execution to their Mac. Compilation, diff review and repository-state verification are not substitutes for those tests. No release, signing, firmware flashing, remote commands or credential changes are authorized by this implementation.

- [x] Transport: apply the four reviewed fixes, preserve Python 3.10 imports, classify firmware errors, validate discovery/endpoint identity.
- [x] Configuration: bounded binary transfer, checksum/readback, profile/layer checks, private interrupted-write recovery; preserve existing backups and unknown fields.
- [x] Controls: normalized keys and analog input, connection-generation revocation, ordered bounded handoff, native mapping/preview of supported controls.
- [x] Workspace: stable provider/source/work slots, explicit bank changes, per-slot lighting and a native virtual board with observe-only input checking.
- [x] Integrations: reuse provider navigation and quota authority, add named system Shortcut actions without shell expansion, refresh compatibility/source notes.
- [x] Delivery: regression fixtures for the owner, compile-only gate, prepare PR/merge delivery; list native, hardware and release checks still required.

Source tasks above are implemented. PR and merge receipts are recorded in GitHub,
not inferred from this checklist. Native/hardware/live-provider tests and release
signing/publication remain explicitly unexecuted. Arbitrary firmware macro editing,
unsupported layouts and firmware maintenance are outside the supported source scope.

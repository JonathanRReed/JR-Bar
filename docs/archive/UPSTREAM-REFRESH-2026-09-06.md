> **Historical.** A pre-0.8 source-adaptation closeout; it describes the PyObjC-era codebase. The live cadence is [`docs/UPSTREAM-RESEARCH-CADENCE.md`](../UPSTREAM-RESEARCH-CADENCE.md).

# September 6 source adaptation closeout

This records bounded source work following the approved completion review, not
an exhaustive audit of every fork, a hardware capture, or a release certificate.
The earlier review compared three materially divergent SidePulse forks and found
23 repository-search results. Search coverage is not complete fork-network proof;
no whole upstream/fork controller was merged in this change.

| Reference | Adaptation | Evidence boundary |
| --- | --- | --- |
| Original SidePulse and reviewed forks | Keep shared monitor, hardware writer, session families and explicit navigation; no second scanner or monolithic controller merge | Existing source retained; native/hardware gates still apply |
| `00cyre/creator-micro-kit` at `a563b88c2dc251371dd4c670690a01f8980fc338` | CRLF reports, method-tagged errors, binary offset transfer, checksums, usage-pair discovery and firmware limits | Independently implemented against the referenced wire contract; board behavior is not tested here |
| `00cyre/claude-code-keypad` | Session-per-key feedback and visible remapping tradeoffs | Provider-neutral canonical identities replace Claude-only/ordinal chat assumptions |
| `vinzdg/codenotch` at `60bafc292d087938edee278f6f9b5e491560bbe6` | Along/across placement shared by four edges and hit regions | Existing PyObjC UI retained; no copied SwiftUI implementation or runtime dependency |
| `pingdotgg/t3code` at `ea646c0834a3394ecb0be4a30c5d367e5a9002bd` | Optional native-thread ID, explicit turn outcomes, source identity, fixed SQL and read-only transaction | Inspected ProjectionThreadSessions, ProjectionThreads and ProjectionTurns source; historical tested-version label unchanged |
| CodexBar provider architecture | Keep native source strategies, account isolation, unknown/stale distinctions and separate quota collection | No CodexBar subprocess dependency, cookie-breadth expansion, or new credential ownership |

T3's inspected session projection no longer inserts/selects `provider_thread_id`.
Its turn projection uses pending/running/interrupted/completed/error states. The
adapter now tolerates the absent native ID without inventing one, and no longer
infers completion merely from an idle transport. Exact provider labels replace
substring inference; Gemini and Antigravity are not interchangeable harnesses.
The manifest's source-review date and fingerprint changed, not the historical
maximum-tested-version claim.

The control-center design preserves observation, navigation and execution as
separate permissions. Sessions, screens and optional accessories share canonical
state; a device press cannot manufacture an approval request or executable script.
Named system Shortcuts are an explicit user-configured local automation boundary.

Test suites were deferred at the owner's request. Regression definitions accompany
the source; compilation, portable imports and static checking are the only new
verification categories in this work. `CONTROL-CENTER.md` records supported flows,
known limits, exact owner checks and the installed-release boundary.

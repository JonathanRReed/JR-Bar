# Provider usage payload fixtures

Captured from the real CLIs and endpoints on 2026-09-10, with account
identifiers replaced. Each file records the exact shape a provider answers
with, so the window-applicability rules can be regression-tested against
what providers actually send rather than against what we assumed.

| file | source | what it pins |
| --- | --- | --- |
| `codex-app-server-rate-limits-pro.json` | `codex app-server` `account/rateLimits/read`, codex-cli 0.153.4, ChatGPT **Pro** | a plan whose account limit has **no 5-hour window**: `secondary` is explicitly `null`, `primary` is the weekly ceiling (`windowDurationMins` 10080). Also the model-scoped `codex_bengalfox` family, which reuses the same `primary`/`secondary` key names. |
| `codex-app-server-rate-limits-plus.json` | same RPC, same shape | a plan whose account limit **does** have a 5-hour window: `primary` 300 minutes, `secondary` 10080. Structure is the captured one; the account family's window pair and `planType` are set to a plan that has both, because the capture machine is on Pro. |
| `codex-rollout-rate-limits-spark.json` | a `token_count` line in `~/.codex/sessions/…/rollout-*.jsonl` | the snake_case form the CLI writes to disk, tagged `limit_id: "codex_bengalfox"` / `limit_name: "GPT-5.3-Codex-Spark"`. A rollout carries exactly ONE family, and this is the one whose 300-minute `primary` used to be read as the account's 5-hour ceiling. |
| `claude-usage-max.json` | `GET` Claude's OAuth usage endpoint, Max 20x | how Claude states an absent window: `"seven_day_opus": null` beside a present `five_hour` object. |

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
| `opencode-go-usage.json` | `GET https://opencode.ai/zen/go/v1/usage`, OpenCode Go | the three windows (`rolling`, `weekly`, `monthly`) with `percent` USED and an ISO `resetsAt`. **Shaped, not captured**: no OpenCode Go account was available on 2026-09-24, so the shape follows T3 Code's client (`openCodeUsageLimits.ts`, MIT, @ `cb1a3f34`). Replace it with a capture once one exists. |

The files below are **shaped, not captured**: each follows the payload its parser in
`src/jrbar/provider_usage_parsers.py` documents (and, where one exists, the shape the provider's own
client uses), with made-up numbers and `example.com` identities. `tests/test_provider_usage_fixture_contract.py`
runs one set of invariants over every file in this folder. Replace a file with a redacted capture once one
exists; the contract keeps holding.

Checked again on 2026-09-24 for a read-only capture on the owner's Mac, and none was possible without
something the lane may not do: Grok's saved sign-in had expired on 2026-09-22 (its card read stale), no
Antigravity language server was running, Devin's token lives in the Keychain (reading it would prompt),
Cursor and Gemini had no source on this Mac, and the OpenAI API provider was off. Every file here has a row
in one of these two tables; `tests/test_provider_usage_fixture_contract.py` fails for one that doesn't.

| file | parser | what it pins |
| --- | --- | --- |
| `cursor-usage-summary.json` | `parse_cursor_usage` | three bindable plan lanes (`included-plan`, `auto-composer`, `api-models`) from `used`/`limit` and `usedPercent`, extra usage in cents. |
| `devin-usage.json` | `parse_devin_usage` | the flat `daily_percentage`/`weekly_percentage` shape, with a 0-1 fraction read as a share. |
| `grok-billing.json` | `parse_grok_usage` | one `credits` lane whose label follows the billing period (a month here). |
| `gemini-code-assist-quota.json` | `parse_gemini_usage` | per-model pools, none bindable; a bucket with no fraction keeps its lane with no reading. |
| `antigravity-quota.json` | `parse_antigravity_usage` | the Gemini and Claude-plus-GPT groups' 5-hour and weekly buckets. |
| `openai-api-usage.json` | `parse_openai_api_usage` | token and cost totals only, no lanes. |

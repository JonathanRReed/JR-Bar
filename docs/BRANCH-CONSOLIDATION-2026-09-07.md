# Branch consolidation: September 7, 2026

Starting main: `a581da9cdd0b9628d26b3805b86efe216522ea95`.
The inventory includes every branch returned by the repository branch collection
and fetched by the full-history audit. There were no open pull requests at intake.

The final integration uses a curated merge with the seven divergent branch heads
as additional parents. All other historical heads were already ancestors of main.
The PR must use **Create a merge commit**, not squash, to retain that ancestry.
Historical refs need not be deleted for a complete main checkout.

The merge is not a wholesale preference for every older implementation. Four
branches are proven whole-tree duplicates of earlier squashes; two contain
superseded implementations/temporary workflow behavior; one contains only a plan.
Their history is retained and their dispositions are explicit below. No force
push, public release, firmware write or destructive branch deletion is required.

| Branch | Audited head | Disposition |
| --- | --- | --- |
| `agent/native-provider-platform-complete` | `0a51e153e5b91fd82ee9b2dab54e2a8c98da29e3` | Already an ancestor of the starting main; no changes reapplied. |
| `agent/native-provider-platform-production` | `6818998ccb9acdd7d933e980c9d8b7fad733e5bd` | Already an ancestor of the starting main; no changes reapplied. |
| `agent/sidepulse-deep-audit` | `9174e67e3dc10324ec03098ef13bb751b24cc70a` | Already an ancestor of the starting main; no changes reapplied. |
| `agent/sidepulse-production` | `e4bebb574b26ccf70d3354637b85413c7c198593` | Already an ancestor of the starting main; no changes reapplied. |
| `agent/sidepulse-rescue` | `cd77de1d69b930252a59fc479ba2ddb37c63a6a1` | Already an ancestor of the starting main; no changes reapplied. |
| `codex/jr-bar-production` | `bfe527fb7ef2d434fc4c08ccc08bb628bc737a72` | Already an ancestor of the starting main; no changes reapplied. |
| `feat/consolidated-settings-and-screen-bar` | `83de765bd0f9b532c40229b4a45cb09de12846c4` | Complete tree exactly equals main ancestor `d5d2724b7d87`. History joined; newer source retained. |
| `feat/native-provider-accounting-and-usage-center` | `4d897e328b329bab9d92f056c36be1e59891b895` | Already an ancestor of the starting main; no changes reapplied. |
| `feat/t3-codexbar-compatibility` | `e4ff202ebe02d1e3d9ff9a35a0b92c3713e22e32` | Already an ancestor of the starting main; no changes reapplied. |
| `finish/creator-control-center-2026-09-06` | `948778fcc714396a616a52c80b629f55d67e71c6` | Complete tree exactly equals main ancestor `a581da9cdd0b`. History joined; newer source retained. |
| `fix/final-provider-usage-and-release-pass` | `6e373b9e911c10f749492a35656c976a1729f452` | Only a historical plan. Preserved under `docs/archive/2026-08-17-final-provider-usage-release-pass.md`; history joined. |
| `fix/native-provider-usage-and-usage-center` | `c8b78710df4c8acb345d96e7beb152460158f485` | Earlier parallel provider implementation superseded by current production collectors and stores; history joined without restoring incompatible dead modules. |
| `fix/production-release-blockers` | `0a51e153e5b91fd82ee9b2dab54e2a8c98da29e3` | Already an ancestor of the starting main; no changes reapplied. |
| `fix/runtime-truth-and-process-ownership` | `1f8c4ae7e457dbd9270416898528d13b740ea5c7` | Complete tree exactly equals main ancestor `f9a75f09f937`. History joined; newer source retained. |
| `fix/stable-device-identity-and-compact-menu` | `7914700ba55444aba67dd8e23bf423e94813ddd5` | Complete tree exactly equals main ancestor `8239eb8f5f9f`. History joined; newer source retained. |
| `verify/production-release-blockers-20260816` | `cf5aa4a5be4f85856246be5bd3d9fc5b2b615f04` | Retired branch-specific verification trigger. Current exact-SHA, explicit release workflow retained; history joined. |

## Superseded provider branch

`fix/native-provider-usage-and-usage-center` added an earlier `provider_sources`
package and incompatible parallel usage settings/store definitions. It did not
wire those sources into the production host. The current main implements these
responsibilities in `provider_usage_codex_claude.py`,
`provider_usage_collectors.py`, `provider_credential_store.py`,
`provider_browser_import.py`, and the wired `provider_usage_platform`,
`provider_usage_settings`, `provider_usage_store` and `provider_usage_runtime`
modules, with corresponding regression coverage. Reintroducing that old package
would create a second, unreachable provider model rather than finish integration.
The explicit resolution retains the current wired implementation. The earlier
files remain recoverable from the recorded ancestor.

## Retired verification branch

`verify/production-release-blockers-20260816` changed a workflow to run against
its own old branch. That automatic trigger is not restored. The current
`self-hosted-macos.yml` retains explicit dispatch and exact-SHA release admission;
`make final-test` supplies the owner's local full verification entry point.
The temporary branch-audit workflow and transport payload are removed from the
final tree.

## Verify the result

After fetching the consolidated main, check historical branch reachability:

```sh
git fetch origin
for branch in $(git for-each-ref --format='%(refname)' refs/remotes/origin); do
    git merge-base --is-ancestor "$branch" origin/main || printf 'New work: %s\n' "$branch"
done
```

A later contributor can create new work after this dated inventory. The check
reports that new work rather than assuming all future branches are included.
The final source and physical/release acceptance boundaries are recorded in
[FINAL-TESTING.md](FINAL-TESTING.md).

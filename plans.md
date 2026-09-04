# Operator implementation plan

## Verification checklist

- [x] Operator scope, privacy boundary, and source-of-truth rules recorded.
- [x] Normalized Operator models and durable local metadata store are implemented and migration-safe.
- [x] Codex adapter reads task/session metadata—including available `tokens_used`—without reading or retaining prompts.
- [x] Hermes adapter reads its documented local data defensively and exposes availability/capabilities.
- [x] Adapter fixtures and store tests pass, including denied/malformed data states.
- [x] Mac Operator window exposes Overview, Sessions, Skills, Machine, and Automations with truthful freshness/empty states.
- [x] Skills browser supports filtering, local tags, favourites, use counts, copy/reveal/export/share without mutating source skills.
- [x] Private iCloud summaries reach the iPhone without raw skills, paths, prompts, or detailed events.
- [ ] macOS/iOS builds and final privacy review pass.

## Architecture

`OperatorAdapter` is a read-only boundary over a harness. It emits normalized records into `OperatorStore`: `OperatorSession`, `OperatorMetric`, `OperatorEvent`, `HarnessCapability`, `OperatorSkill`, local `SkillTag`, and `SkillUseEvent`. The store derives lightweight totals and expiry-aware snapshots.

The Mac window reads the store directly. The companion receives a separate `CompanionOperatorSummary` produced from the store and sent through the existing private CloudKit channel. That summary contains only session counts, harness labels, token/duration deltas, machine state, alert state, and existing finish-action state.

## Milestones

### 1. Contract and local store [x]

Scope: define stable normalized models, adapter protocol, privacy redaction boundary, and a durable local store for derived records plus user metadata.

Key files/modules: new `Sources/SleepSwitch/Operator*` models/store, tests, project target configuration.

Acceptance: tags/favourites/use events are stored locally by skill fingerprint; re-indexing a skill never changes its source; unavailable adapters are distinguishable from empty results.

Verify: focused unit tests for encoding, deduplication, expiry, redaction, and migration.

### 2. Codex adapter [x]

Scope: adapt local Codex task/session records to normalized sessions/events/metrics. Read only the fields needed for identity, lifecycle, duration, and token totals.

Acceptance: active and completed tasks are deduplicated across refreshes; `tokens_used` is recorded when present; prompt and tool content is discarded before persistence.

Verify: fixtures for live, complete, aborted, stale, partial, and malformed session logs.

### 3. Hermes adapter [x]

Scope: discover the documented Hermes local session store and capabilities; layer it over the existing active-lease tracker without assuming its schema is always available.

Acceptance: Hermes sessions/metrics are represented when readable; schema or permission problems show a diagnostic availability state and never affect awake-session detection.

Verify: database/JSON fixtures and no-file/no-permission paths.

### 4. Mac Operator window [x]

Scope: add a native window with Overview, Sessions, Skills, Machine, and Automations. Reuse existing power, thermal, history, and finish-action models rather than creating duplicate control paths.

Acceptance: each surface has useful loading, empty, stale, and unavailable states; sessions show current state/duration/tokens where supported; Machine and Automations surface existing truth.

Verify: macOS build, view-model tests, desktop visual review.

### 5. Skills browser and metadata actions [x]

Scope: index readable skills, expose filters/tags/favourites/use counts, and provide copy/reveal/export/share actions.

Acceptance: tags never touch `SKILL.md`; copy/export/share disclose the chosen source only on user action; unavailable folders are explicit; skill use is recorded locally via normalized events.

Verify: store tests, source-integrity tests, UI action tests where possible.

### 6. iPhone summary [x]

Scope: extend shared CloudKit records and companion UI with compact Operator summaries, current alerts, and finish-action visibility.

Acceptance: iPhone refresh states remain accurate; summaries contain no raw prompt, path, skill-body, or event-detail fields; offline/stale Mac state is unambiguous.

Verify: shared protocol tests, iOS build, simulator visual review.

### 7. Hardening and release [ ]

Scope: privacy audit, migration/recovery paths, performance limits, documentation, full validation, and release readiness.

Acceptance: a corrupted external record cannot crash the menu app; indexing is bounded; no Operator database/cache/fixture data is committed accidentally.

Verify: `./test.sh`, `./test-direct.sh`, macOS build, iOS simulator build, clean-repo secret/data scan.

## Risks and mitigations

1. **Harness formats change.** Version adapters independently, parse defensively, keep raw payloads out of the store, and advertise explicit capabilities/failures.
2. **Codex task logs can contain sensitive content.** Extract only whitelisted lifecycle/token fields and never persist original JSON lines.
3. **Hermes database schema is unknown or locked.** Research against its public documentation/source before implementation; fall back to its existing active-lease information only.
4. **iCloud records grow too large.** Publish deltas and bounded summaries, not a history mirror; retain detailed data on the Mac.
5. **Skills can come from arbitrary folders.** Require existing scoped access where needed; fingerprint only metadata/content on demand and never write into source directories.
6. **Operator duplicates existing controls.** Keep all energy/cooling/power execution in their established coordinators; Operator is a read model and presenter.

## Acceptance flow

1. Start a Codex task, open Operator, and see an active session plus truthful token/duration fields when local records provide them.
2. End the task; confirm the session is finished once, duration stops, and no task content is visible in Operator storage.
3. Make a Hermes session available; confirm it appears with its declared capabilities or an explicit unavailable diagnostic.
4. Browse a skill, favourite/tag it, copy or reveal it, then prove the original `SKILL.md` was unchanged.
5. Pair iPhone, observe a compact live summary and a clearly stale/offline state, then exercise an existing finish action through its normal safety mechanism.

## Implementation notes

- 2026-09-04: Added a SQLite-backed local `OperatorStore`. It persists only normalized session counters/lifecycle events and local skill metadata/use events. It contains no raw task JSON, prompt, tool content, skill body, or source-file mutation path.
- 2026-09-04: Added bounded Codex rollout and Hermes SQLite adapters. Hermes selects only fixed session lifecycle/token columns and never reads its `messages`/FTS tables, titles, paths, or prompt fields.
- 2026-09-04: Operator now refreshes on the existing utility queue at most once per minute. Its private-CloudKit extension is a grouped harness summary with active counts, token/duration deltas, static alert codes, and the existing queued finish-action identifier.
- 2026-09-04: Added the native macOS Operator window from the status menu. Overview, Sessions, Skills, Machine, and Automations all read existing truth; none create new power/cooling execution paths.
- 2026-09-04: Added iPhone Operator summary card and simulator review fixture. The card displays grouped harness state, deltas, safe alert state, and queued finish action; the parent Mac status continues to supply machine state.

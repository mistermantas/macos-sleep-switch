# Execution contract — Operator

Continue through the Operator milestones without pausing for routine design approval. `plans.md` is authoritative.

- Build the data contract and deterministic adapters before UI. Use fixtures and tests for every external harness format.
- Keep adapter code read-only and failure-tolerant. A denied directory, unavailable Hermes database, or malformed record must produce an explicit diagnostic state rather than fabricated empty data.
- Maintain a local SQLite-backed Operator store for user metadata and derived activity. It owns tags, favourites, and use counts; it must never modify a source `SKILL.md`.
- Send only compact, purpose-limited summaries to the existing private CloudKit model. Do not add a developer server or transfer prompts, raw event details, skills, or filesystem paths.
- Before editing a user-facing surface, inspect its current visual state and validate revised Mac and iPhone layouts through builds/screenshots as appropriate.
- Validate after every milestone. Add focused tests before fixing adapter/storage bugs when practical.
- Keep `plans.md` and `documentation.md` aligned with implemented behavior. Do not commit secrets, local databases, cached harness data, or product-strategy artifacts.

Completion means Codex and Hermes data can be safely observed; the Mac Operator window and iPhone summaries are usable and truthful; the skills browser operates on local metadata without touching source skills; and all applicable tests/builds pass.

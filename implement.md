# Execution contract — remote AI-agent supervision

Continue through `plans.md` without waiting for routine product approval, but do not blur product boundaries to make a demo appear more complete.

- Treat the Mac as the execution-side authority. Keep all existing power, cooling, lid, battery, and finish-action protections intact.
- Implement state only when an adapter or observer has direct evidence. `unknown` is a valid and safer outcome than a guess.
- Build cross-device operations as explicit, bounded contracts: named record, direction, expiry, size limit, validation, result, cleanup, user feedback.
- Receive phone-originated data into a private Mac inbox only. Do not choose a repository, alter files, run a command, or send an agent a message without a separate user action.
- Keep raw prompts, transcript content, paths, commands, logs, credentials, and source files local unless a future feature has a separately designed, opt-in contract.
- Before changing a user-facing surface, inspect its current state; after a meaningful change, build and visually validate the relevant Mac/iPhone surface.
- Add focused tests for external record parsing, expiry, retry, deduplication, and privacy redaction before or alongside implementation.
- Keep `plans.md` checkboxes and `documentation.md` factual. Do not commit user data, CloudKit assets, local inboxes, credentials, or strategy attachments.

Completion means the tested, releasable milestones in `plans.md` are genuinely complete—not merely represented by UI placeholders.

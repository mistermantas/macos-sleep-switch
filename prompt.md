# Sleep Switch — remote AI-agent supervision

Build the next Sleep Switch layer: a private, trustworthy way to supervise AI-agent work running on a user’s own Mac from iPhone or iPad. The Mac remains the execution-side observer and safety authority; mobile is a concise surface for understanding work, supplying context, reviewing results, and making consequential decisions.

## Product intent

- Show operational work state, not a second chat transcript or remote desktop.
- Keep the Mac available only while useful work needs it, and make the reason legible on mobile.
- Let a user explicitly hand a small piece of context from iPhone/iPad to a Mac without silently placing it into a repository or agent session.
- Let the Mac explicitly offer artifacts, previews, and requests for attention to the user’s own devices.
- Keep iCloud data compact, private, purpose-limited, and honest about freshness.

## Hard boundaries

- Do not build a remote shell, desktop, IDE, generic file browser, or competing agent chat client.
- Never sync raw prompts, messages, commands, paths, tool payloads, logs, credentials, or source trees by default.
- Never infer a stalled, blocked, or review-ready state merely from elapsed time. Each lifecycle state must have evidence.
- Never silently inject phone-originated content into a project or agent. The Mac must receive it into a private inbox and require an explicit next action.
- Preserve existing awake, lid, cooling, battery, and finish-action safeguards.

## Deliverable

Ship the private supervision foundations incrementally across the macOS and companion apps, with evidence-backed state, an explicit context/artifact handoff flow, actionable attention states, and tested/releasable builds. Keep the implementation modular so previews, approvals, and harness-specific signals can follow without weakening the privacy boundary.

## Process

Plan before broad coding. Work milestone by milestone from `plans.md`, validate every layer, update the runbook as reality changes, and continue without routine approval pauses. Start now.

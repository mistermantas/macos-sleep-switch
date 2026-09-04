# Sleep Switch — Operator implementation brief

Act as the product engineer shipping Operator: a calm, private operations layer for people running coding agents on their own Macs. It must turn local harness data into useful, trustworthy sessions, activity, skills, and machine context without becoming a new agent runner or collecting prompts.

## Goals

- Establish a read-only Operator data layer with normalized sessions, metric samples, events, harness capabilities, skills, user-owned tags, favourites, and skill-use events.
- Ship Codex and Hermes adapters first. Codex may read local task `tokens_used`; Hermes may read its documented local session database. Never write to either harness.
- Add a native Mac Operator window with Overview, Sessions, Skills, Machine, and Automations surfaces.
- Extend the private iCloud companion with compact summaries only: live session state, token and duration deltas, machine state, alert state, and finish actions.
- Add a Skills browser that can filter, tag, favourite, count use, copy, reveal, export, and share skills. Tags and use history belong to Operator’s local store only; source `SKILL.md` files remain untouched.

## Hard requirements

- Read-only adapters. No prompt content, tool payloads, credentials, source-file mutation, or developer-operated server.
- Be explicit about freshness and adapter availability. Missing permission or an unknown database schema must present as unavailable, never as zero activity.
- Use stable local identifiers and privacy-preserving CloudKit summaries. iPhone receives no raw skill text, prompts, filesystem paths, or detailed event payloads.
- Preserve the existing Mac-as-executor power/cooling model. Operator can show or schedule existing finish actions but never bypasses their confirmation/safety rules.

## Deliverable

A tested Operator implementation for macOS and its private iPhone summary surfaces, documented well enough for another engineer to add an adapter without reverse-engineering the app.

## Process

Plan before coding. Work milestone by milestone from `plans.md`; validate every layer before exposing it. Start now. Do NOT begin broad UI work until the Operator data contract and adapter boundaries are coherent.

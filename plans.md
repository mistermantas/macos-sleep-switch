# Remote AI-agent supervision plan

## Verification checklist

- [x] Product boundary, privacy model, and evidence-only lifecycle vocabulary are recorded.
- [x] Bounded remote-work projection reaches iPhone through the private CloudKit status channel.
- [x] Codex structured state maps rate limits, errors, stopped, waiting, active, and finished without fabricated stalls.
- [x] Explicit context-transfer record and Mac-side private inbox foundation are implemented.
- [ ] iPhone/iPad can intentionally select and send a bounded context item, with clear pending/received/error feedback.
- [ ] Mac exposes received context safely and offers an explicit user-chosen handoff action—never automatic repository or agent injection.
- [ ] Artifact offers support explicit Mac-to-mobile delivery, Quick Look, save, and share.
- [ ] Attention events and notifications distinguish useful attention from required action.
- [ ] Session/machine relationship and power consequence are understandable on mobile.
- [ ] Local-preview discovery and access design is opt-in, network-safe, and separately reviewed.
- [ ] Approval and follow-up flows have a narrow, evidence-backed command model.
- [ ] Full privacy audit, recovery limits, macOS/iOS builds, and release notes pass.

## Architecture

The Mac is authoritative for local observation and controls. `RemoteWorkProjection` produces a compact, pseudonymous summary for the existing private CloudKit status channel. User-visible titles are a separate opt-in; raw transcript data never crosses this boundary.

Explicit cross-device handoff uses a short-lived `RemoteContextTransfer` record and a bounded private-CloudKit asset. The phone copies a user-picked item before upload. The Mac validates expiry and size, copies it into `Application Support/Sleep Switch/Remote Inbox`, clears the cloud asset, and never selects a project, opens a terminal, or informs an agent automatically. A future Share extension is merely another intake front end for this same transfer contract.

Artifacts, previews, and approvals are separate contracts. They must not piggyback on status snapshots or acquire a generic file-manager/remote-desktop scope.

## Milestones

### 1. Evidence-backed operational state [done]

Scope: private status projection, safe Codex lifecycle mapping, iPhone agent-work view.

Acceptance: unavailable data is `unknown`; no inactivity timer labels work stalled; titles are independently opt-in; no prompt/message/path/log leaves the Mac.

Verify: `RemoteWorkProjectionTests`, protocol tests, macOS and iOS builds.

### 2. Explicit context intake [in progress]

Scope: phone file-picker intake, bounded transfer/upload, Mac private inbox, visible receipt/error state, and Mac-side reveal/review.

Acceptance: a user intentionally chooses a file and a target Mac; transfer size/expiry are enforced; duplicate/replayed/malformed assets cannot escape the inbox; no content is injected into a workspace/agent.

Key modules: `CompanionProtocol`, `CompanionCloudStore`, `CompanionMacBridge`, `RemoteContextInbox`, `CompanionAppModel`, dashboard and Settings UI.

Verify: inbox unit tests, bridge transfer test, private schema documentation, iOS simulator build, macOS build.

### 3. Explicit result handoff [planned]

Scope: Mac-side artifact offer flow, bounded private asset delivery, iOS Quick Look/save/share, expiry and revocation.

Acceptance: only user-selected Mac outputs are sent; iPhone can preview, save, or share; paths and generic browsing are never exposed.

### 4. Attention and review [planned]

Scope: evidence-backed attention events, notification routing, completed-work summary, follow-up/approval contract.

Acceptance: active work does not spam; action-required events name a session/project only when titles are opted in; approval execution remains narrow, explicit, and auditable.

### 5. Preview access [planned]

Scope: opt-in same-network preview registration/discovery and direct secure opening.

Acceptance: no hidden relay, correct local-network permission disclosure, clear unavailable/offline feedback, and no arbitrary localhost tunnelling.

### 6. Hardening and release [planned]

Scope: CloudKit migration/recovery, bounded cleanup, App Store review notes, tests/builds, and hands-on Mac/iPhone review.

Acceptance: malformed/expired records fail safely, data is deleted or expires predictably, release metadata matches actual behavior, and no private test data or credentials enter git.

## Risk register

| Risk | Mitigation |
| --- | --- |
| A status summary implies more certainty than the Mac has | Use explicit source evidence and `unknown`; never infer lifecycle state from silence. |
| CloudKit becomes an opaque file store | Hard size/lifetime limits, explicit direction-specific records, an inbox/offer model, and no recursive browsing. |
| Phone content lands in an agent workspace unexpectedly | Receive only into a private Mac inbox; require a later explicit placement or agent-facing action. |
| iCloud/account/network fails | Preserve local truth, show stale/offline state, and make transfers retryable/expirable rather than pretending delivery. |
| Preview scope expands into remote desktop | Same-network, opt-in, named preview registration only; no arbitrary port relay. |
| Notifications become noisy | Notify only on state transitions that need review or action; let users tune attention policies. |

## Acceptance flow

1. A Codex task runs, reaches a usage limit, stops, or finishes; iPhone shows the supported state with no transcript content.
2. A user selects a small PDF from iPhone and chooses a paired Mac; the Mac receives it in its private inbox after validating it, without altering a project.
3. The user explicitly acts on that inbox item, then can see the local destination and handoff outcome.
4. A user explicitly offers a Mac-generated artifact; iPhone previews it, saves it, or shares it without generic Mac file access.
5. An important state change surfaces one actionable notification; offline and stale states remain distinguishable.

## Implementation notes

- 2026-09-04: Operator remains the read-only local data layer. This plan builds on it but does not turn Operator into an agent runner.
- 2026-09-04: Remote work status is opt-in. Titles are separately opt-in. The first projection includes only evidence-backed active, waiting, rate-limited, failed, stopped, finished, and unknown states.
- 2026-09-04: Context transfer uses an explicit 25 MB, 24-hour private-CloudKit asset handoff. This is a small, deliberate context path—not a bulk artifact transport or file browser.

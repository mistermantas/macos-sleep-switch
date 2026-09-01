# Sleep Switch — overnight completion brief

Act as the product engineer responsible for finishing the companion release, not as a feature sketcher. Ship a coherent iPhone experience that remains truthful when a Mac is offline or data is stale, and preserve the Mac as the sole executor of power and cooling actions.

## Goals

- Make iPhone thermal data—including fan RPM—refresh live enough to be useful while controlling cooling.
- Expand the iOS widget family into focused, configurable widgets: a user can choose a Mac, hide its name, and choose a focused battery, thermal, agent, or overview presentation across supported Home Screen and Lock Screen families.
- Add `Sleep When Agents Finish` and `Shut Down When Agents Finish` on macOS and expose them safely in iOS.
- Push source to GitHub and upload valid iOS and macOS App Store Connect builds.

## Hard requirements

- Never fabricate live telemetry: show freshness and keep stale data visibly stale.
- A shutdown must be clearly dangerous, require confirmation, and be cancellable before it is sent to the Mac.
- Widgets read only the private app-group snapshot; they must not perform remote power actions.
- Preserve the existing private CloudKit model: no new server or pairing code.
- The public repository must not contain credentials or product-strategy notes.

## Deliverable

A tested source release on `main`, an iOS App Store Connect build containing the work, and a macOS App Store Connect build when Apple signing credentials available on this Mac permit it.

## Process

Plan before coding. Work milestone by milestone from `plans.md`; validate each milestone and update the operator runbook as the implementation becomes real. Start now.

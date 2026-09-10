# Sleep Switch Privacy Policy

**Last updated: September 10, 2026**

Sleep Switch does not collect personal data for the developer or sell data. The optional companion uses the user's private iCloud database for status, history, remote commands, and content the user chooses to share between their devices.

## Information used on your Mac

Sleep Switch processes only the local information needed to provide its features:

- App preferences, such as keep-awake settings and timer choices, are stored locally in macOS user defaults.
- The direct-download version checks the local process list and Codex task markers to detect supported agent sessions.
- The Mac App Store version reads Codex task markers only after you select a `.codex` folder. Access is read-only and is stored as an app-scoped macOS security bookmark.
- Version 2.2.0 can save estimated power readings and coarse agent activity intervals in a local SQLite database so Insights can show history after a restart. Saving is enabled by default, can be paused in **Insights** or **Settings**, and can be deleted from either place. The database is bounded and does not contain prompts, output, file names, command lines, usernames, or serial numbers.

Local information is not sent to the developer. The optional companion shares the information described below through Apple’s private iCloud storage.

## Data collection and tracking

Sleep Switch has:

- no analytics or telemetry;
- no advertising or tracking;
- no user accounts;
- no developer-operated server; and
- no bundled third-party SDKs.

When you use the companion, the Mac publishes status (including CPU and memory use, battery, and current agent activity), bounded daily energy and agent-hour summaries, and recent five-minute energy buckets. It reads short-lived, named commands from your private iCloud database. A stable machine identifier distinguishes your Macs and prevents duplicate listings after reinstalling. The developer cannot read your private database.

Live Activities can display your chosen Mac name, usage readings, session timer, and agent counts on the iPhone Lock Screen and Dynamic Island. They contain no prompts or chat content. Configuration is stored locally on the iPhone, and you can stop monitoring from Live Activity in the app.

Operator content sharing is off by default. If you enable it in Operator’s sharing settings on iPhone or Settings on Mac, board titles, project and folder names, skill metadata, and workflow state sync through private iCloud. Opening a chat or skill requests bounded message excerpts or skill text from your Mac. Full filesystem paths and source identifiers are not included in this projection. You can disable sharing on either device; this stops further content requests and clears the companion’s in-memory content when it receives the updated state. Previously sent command records remain subject to the private database’s command retention period.

Files, text, and context you explicitly send between your devices also travel through your private iCloud database. These transfers are separate from Operator content sharing. Content you export, copy, or share using the system share sheet goes to the destination you choose.

When local history saving is disabled, the companion history payload is empty. Local preferences, history, and folder-access bookmarks remain on your Mac until you change them, delete them, reset the app, or remove the app’s data.

## External links

The **Support & Creator** menu can open the Uncascade website, YouTube, the public bug tracker, and Uncascade contact support in your default browser. Sleep Switch does not receive information about your activity on those services. Their own privacy policies apply after you leave the app.

## Children’s privacy

Sleep Switch does not knowingly collect information from anyone, including children.

## Changes to this policy

If Sleep Switch’s privacy practices change, this policy will be updated in the public repository and the revision date above will change.

## Contact

Privacy questions can be submitted through the [Sleep Switch issue tracker](https://github.com/mistermantas/macos-sleep-switch/issues).

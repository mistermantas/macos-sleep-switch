# Sleep Switch Privacy Policy

**Last updated: August 12, 2026**

Sleep Switch does not collect personal data for the developer, sell data, or share it with third parties. The optional companion uses the user's private iCloud database for coarse status and history synchronization.

## Information used on your Mac

Sleep Switch processes only the local information needed to provide its features:

- App preferences, such as keep-awake settings and timer choices, are stored locally in macOS user defaults.
- The direct-download version checks the local process list and Codex task markers to detect supported agent sessions.
- The Mac App Store version reads Codex task markers only after you select a `.codex` folder. Access is read-only and is stored as an app-scoped macOS security bookmark.
- Version 2.2.0 can save estimated power readings and coarse agent activity intervals in a local SQLite database so Insights can show history after a restart. Saving is enabled by default, can be paused in **Insights** or **Settings**, and can be deleted from either place. The database is bounded and does not contain prompts, output, file names, command lines, usernames, or serial numbers.

This local information stays on your Mac. It is not sent to the developer or any third party.

## Data collection and tracking

Sleep Switch has:

- no analytics or telemetry;
- no advertising or tracking;
- no user accounts;
- no developer-operated server; and
- no bundled third-party SDKs.

The app does not upload prompts, output, file names, command lines, or raw local history. Version 2.2 includes an optional private CloudKit transport for the iOS companion. When you use the companion, the Mac publishes a coarse status snapshot, bounded daily kWh/agent-hour summaries, and the last 24 hours of five-minute energy buckets; it reads short-lived, named commands from the user's private iCloud database. The developer does not operate a server and cannot read the user's private database. When local history saving is disabled, the companion history payload is empty. Local preferences, history, and folder-access bookmarks remain on your Mac until you change them, delete them, reset the app, or remove the app’s data.

## External links

The **Support & Creator** menu can open the Uncascade website, YouTube, the public bug tracker, and Uncascade contact support in your default browser. Sleep Switch does not receive information about your activity on those services. Their own privacy policies apply after you leave the app.

## Children’s privacy

Sleep Switch does not knowingly collect information from anyone, including children.

## Changes to this policy

If Sleep Switch’s privacy practices change, this policy will be updated in the public repository and the revision date above will change.

## Contact

Privacy questions can be submitted through the [Sleep Switch issue tracker](https://github.com/mistermantas/macos-sleep-switch/issues).

# Persist preferred audio input independently of the effective route

Status: Accepted for local fork implementation, 2026-11-11. Authorized by Jeff on Kanban task t_7032e4d6; no upstream issue or publication. Product acceptance remains with downstream integration verification and Jeff.

This fork replaces the original System-only/no-picker constraint in CONTEXT.md. Users can retain a particular microphone preference while letting Talkify use System when that device is disconnected. The UI is a separate dependent change.

AppSettings persists only an optional Core Audio device UID. Nil means System. AudioInputSelection resolves that preference against a live device list and OS default; fallback never writes a preference. Runtime AudioDeviceIDs are never persisted. AudioInputController exposes the result directly as an observable model, consistent with ADR-0005's model–view approach.

Core Audio listeners refresh inventory and default-input selection. MicrophoneInput applies the resolved device to its own audio unit before capture or recovery, rereading hardware to avoid stale-device ordering races. It never changes the system-wide input. Engine operations are serialized so stop cannot race a replacement engine into an unowned capture.

The Settings meter reuses MicrophoneInput in level-only mode while idle. A synchronous routing lease releases that engine before Direct Dictation starts; the meter then observes dictation's existing tap. It resumes idle capture afterward only while requested. No second concurrent capture, saved audio, or new third-party dependency is introduced.

Hardware outages can still end a session with an error if recovery cannot open a usable route. They do not erase the preferred UID or require restarting the app. Drivers control UID stability; virtual-device identity changes may require selecting that input again. See ../AudioInput.md for the UI contract and verification boundaries.

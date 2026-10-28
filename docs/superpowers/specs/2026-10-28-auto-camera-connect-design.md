# Automatic camera connection

Fuji Studio should connect to an attached X-T5 without a Connect button. Start
the existing ImageCaptureCore discovery/session flow while the app is active;
its device-added callback handles a camera plugged in during discovery. Retry
failed attempts after three seconds. Keep a single attempt in flight and leave
ready/busy sessions alone. Stop automatic attempts when inactive/backgrounded,
and restart on foreground activation, including when no camera was connected
before backgrounding. Preserve the existing serialized disconnect and export
recovery behavior; reconnecting never resumes a conversion or export.

Missing cameras are normal and should not produce an Action needed error.
Permission denials remain actionable in status and are retried only after
foreground activation, allowing a Settings change. Other connection failures
remain visible. Keep recipe import on the verified ready-session path.

## Approaches

- Discovery callbacks alone react to attachment but do not recover after the
  existing bounded connection timeout or a failed session.
- A timer alone would discard the existing immediate discovery capability.
- Use the existing callback-driven discovery with a three-second retry after
  each completed attempt. This implements the user's requested fallback and
  keeps native session ownership unchanged. No new dependency is needed.

The chosen implementation is a foreground-owned task in AppModel with an
injectable retry wait for deterministic lifecycle tests. Remove the connection
control from both the live workspace and generated UI fixtures. Status continues
to explain connection progress, USB mode and permissions.

Physical plug/unplug timing needs device validation; simulator checks establish
app policy and UI behavior, not USB hardware behavior.

The DEBUG live-acceptance route opts out of automatic connection so its
manifest/receipt checks and authoritative final native close remain valid.
Normal live and UI-fixture launches always enable automatic connection.

Apple documents device addition/removal in
[ICDeviceBrowserDelegate](https://developer.apple.com/documentation/imagecapturecore/icdevicebrowserdelegate).
The existing transport keeps this browser alive across session attempts and
also scans its cached devices, so an already-attached camera can be reopened.

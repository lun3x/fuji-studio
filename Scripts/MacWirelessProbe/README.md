# MacWirelessProbe

Run Fuji Studio's CoreBluetooth discovery, pairing, and saved reconnect on a Mac with macOS 27. The app uses the production Bluetooth driver, gateway, profiles, and Keychain store. First pairing in this probe requires the Device Information model to resolve to an X-T5.

```sh
app="$(Scripts/MacWirelessProbe/build.sh)"
run="$(mktemp -d /tmp/fuji-mac-wireless.XXXXXX)"
chmod 700 "$run"
open -n "$app" --args --run-dir "$run"
ctl=Scripts/MacWirelessProbe/control.sh
"$ctl" "$run" status
```

Each launch takes a fresh owner-only directory. The initial `phase=idle` and `bluetooth=uninitialized` indicate that the app is waiting. Read `status` or `events` to see when a command completes.

1. Send `"$ctl" "$run" discover` while the camera is in Bluetooth pairing mode. Approve the macOS Bluetooth permission dialog if it appears.
2. Run `"$ctl" "$run" list` and identify the intended X-T5. A camera without a known advertised model is listed as `unresolved`. If there are multiple plausible candidates, use only the intended camera in the test.
3. Send `"$ctl" "$run" select N` with its numbered handle, then send `"$ctl" "$run" pair` once selection is visible in status. Confirm the macOS and camera pairing prompts if they appear. Success shows `phase=linked` and `linked_model=X-T5`.
4. Send `"$ctl" "$run" disconnect`, wait for `phase=idle`, and send `"$ctl" "$run" reconnect`. This uses the selected camera saved in the probe's separate Keychain service and defaults suite.
5. Send `"$ctl" "$run" quit` to disconnect and exit. A fresh run directory with the same app bundle can test reconnect across launches.

Status and events omit peripheral identifiers, names, credentials, and raw firmware. An unrecognized Device Information model is recorded only in the separate owner-only `private-bluetooth-model.json` file. The probe exercises Bluetooth through authenticated readiness.

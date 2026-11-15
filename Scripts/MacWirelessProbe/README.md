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

Each launch takes an empty owner-only directory with no ACL entries. The initial `phase=idle` and `bluetooth=uninitialized` indicate that the app is waiting. Read `status` or `events` to see when a command completes. When selecting a candidate, confirm both `result=selected` and the requested `selected` handle before pairing.

1. Send `"$ctl" "$run" discover` while the camera is in Bluetooth pairing mode. Approve the macOS Bluetooth permission dialog if it appears.
2. Run `"$ctl" "$run" list` and identify the intended X-T5. A camera without a known advertised model is listed as `unresolved`. If there are multiple plausible candidates, use only the intended camera in the test.
3. Send `"$ctl" "$run" select N` with its numbered handle, then send `"$ctl" "$run" pair` once selection is visible in status. Confirm the macOS and camera pairing prompts if they appear. Success shows `phase=linked` and `linked_model=X-T5`.
4. Send `"$ctl" "$run" disconnect`, wait for `phase=idle`, and send `"$ctl" "$run" reconnect`. This uses the selected camera saved in the probe's separate Keychain service and defaults suite.
5. While `phase=linked`, send `"$ctl" "$run" wifi` to test camera-side Wi-Fi activation over Bluetooth. The probe checks the saved selection and supported firmware first. `wifi_ready=true` records that the camera reported readiness. The Mac does not join the camera network.
6. Send `"$ctl" "$run" quit` to disconnect and exit. A fresh run directory with the same app bundle can test reconnect across launches.

Status and events omit peripheral identifiers, names, credentials, and raw firmware. An unrecognized Device Information model is recorded only in the separate owner-only `private-bluetooth-model.json` file. The Wi-Fi status reports readiness, the security category, and the camera model.

To check the saved reconnect advertisement, run `"$ctl" "$run" observe-saved` while idle. The probe scans for up to 15 seconds and stops when one connectable report contains the expected service and manufacturer shape for the saved CoreBluetooth identity. The status shows which criteria were observed and whether they occurred together. The camera model comes from the saved record. Send `reconnect` separately after the scan when you want to attempt a link.

On macOS the probe uses the file-based Keychain. It enumerates persistent references within the dedicated probe service before reading the individual records. The iOS app uses its platform Keychain path.

Run `Scripts/MacWirelessProbe/test.sh` to check the command and file permissions without starting Bluetooth.
Run `Scripts/MacWirelessProbe/test-keychain.sh` to exercise enumeration and saved selection using synthetic records in unique temporary Keychain services.
Run `Scripts/MacWirelessProbe/test-wifi.sh` to check the activation boundary with a test gateway.
Run `Scripts/MacWirelessProbe/test-saved-advertisement.sh` to check scan matching with synthetic reports.

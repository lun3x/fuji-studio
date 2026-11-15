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
5. While `phase=linked`, send `"$ctl" "$run" wifi` to test camera-side Wi-Fi activation over Bluetooth. The probe checks the saved selection and supported firmware first. `wifi_ready=true` records that the camera reported readiness. This step only activates the camera access point.
6. Send `"$ctl" "$run" quit` to disconnect and exit. A fresh run directory with the same app bundle can test reconnect across launches.

Status and events omit peripheral identifiers, names, credentials, and raw firmware. An unrecognized Device Information model is recorded only in the separate owner-only `private-bluetooth-model.json` file. The Wi-Fi status reports readiness, the security category, and the camera model.

`ble_firmware` displays the authenticated link's Device Information firmware as a short ASCII version or a fixed diagnostic category. The Wi-Fi command still applies the bundled firmware policy to the original identity value.

To check the saved reconnect advertisement, run `"$ctl" "$run" observe-saved` while idle. The probe scans for up to 15 seconds and stops when one connectable report contains the expected service and manufacturer shape for the saved CoreBluetooth identity. The status shows which criteria were observed and whether they occurred together. The camera model comes from the saved record. Send `reconnect` separately after the scan when you want to attempt a link.

To compare secure status, complete a first pair and then disconnect and reconnect in the same probe process. The probe keeps a valid first-pair baseline in memory after authenticated readiness and compares it only with a verified X-T5 session for the same saved peripheral. When `secure_status_compared=true`, the prefix and whole-value flags report equality. Quit discards the baseline.

For a passive first-pair trace, leave the link open after `phase=linked` until the camera reports an outcome or 90 seconds have elapsed. Watch the camera for Pairing Complete, the white Bluetooth icon, or an entry in Select Pairing Destination. The probe's ready result describes local GATT setup. Its notification trace records known roles, coarse lengths, and timing relative to local readiness. Send `disconnect` when the observation ends. The probe keeps those entries in memory until the link closes, then adds them to the events file at their original timestamps. Time correlation alone cannot establish the meaning of a notification.

The production X-T5 pairing profile subscribes to geotag requests as part of registration. The buffered trace labels any matching callback `geotag-request`. The profile sends no location data.

The standard X-T5 `reconnect` command uses the production configuration and geotag-request subscriptions before the network-name subscription. Follow it with `wifi` to test the production launch value.

To test the launch function, start a fresh standard reconnect and send `wifi-image-viewing` once. It submits `03 00` in place of the normal `04 00` launch for the verified selected X-T5. `image_view_launch_used=true` records submission to the production driver. Both commands require the normal readiness indication. The X-T5 effect is unknown. Fuji Bridge identifies the functions from XApp and reports different PTP behavior on the X100VI. [Fuji Bridge function definitions](https://github.com/Th0rgal/fuji-bridge/blob/38fc4275574c2016a1f13ece13496b0ad1e9b452/FujiBridge/FujiBluetooth.swift#L46-L54)

For a PTP identity trial, first verify the Mac has an independent wired uplink carrying the default route. Use the development-signed probe for stable privacy permissions. Send `wifi-preflight` while idle or linked to request Location access if needed and test whether the worker can read the current remembered Wi-Fi network. If prompted, complete authorization in macOS and repeat the command. After a normal `reconnect`, activate the camera access point with `wifi-image-viewing`. Once `wifi_ready=true` appears, send `ptp-identity` while still linked. The trial consumes that activation, confirms the directed camera scan and wired route, joins the camera Wi-Fi, and opens and closes the production PTP identity session. Approve Local Network access in macOS if prompted. The probe keeps BLE open and cancels the PTP trial if BLE is lost.

`ptp_identity_verified=true` reports an admitted Fujifilm X-T5 PTP identity and firmware. `wifi_restore=previousAssociationObserved` reports that macOS returned to the exact remembered Wi-Fi network. The worker releases the test camera association and observes whether macOS auto-joins. With `restoreUnverified`, use the wired uplink to select the previous network in macOS Wi-Fi Settings. Disconnect and Quit wait for the local restoration attempt before closing the Bluetooth link. The trial stops before gallery inventory or photo operations. [Apple Known Networks](https://support.apple.com/guide/mac-help/mh11935/mac)

For a Wi-Fi-only Mac, send `wifi-only-preflight` to check the remembered association, Wi-Fi default route, and interface-bound HTTPS without switching networks. While idle, send `wifi-restore-rehearsal` when someone is at the Mac and able to reconnect locally if necessary. It briefly releases the current association. Both the gap observation and the restore command require the same Wi-Fi interface to explicitly report link down with no readable SSID. The probe uses Apple's `networksetup` with the previous network name and no password argument. The name appears briefly in local process arguments. Wi-Fi names and passwords are omitted from logs.

`restoreRehearsalVerified` records an observed gap, completion of the guarded restore command, and the return of the same association, default route, and HTTPS access. macOS auto-join can race the command after the link check, so the result verifies the combined procedure. It authorizes one `ptp-identity-wifi-only` trial in the same probe within five minutes, if the prior network, interface, and default route still match. Reconnect the selected X-T5 and activate its access point before sending the PTP command. The app runs the identity trial and recovery locally through the temporary loss of internet. If the previous connection does not return, use **System Settings → Wi-Fi → Known Networks → Connect** at the Mac. [Apple Known Networks](https://support.apple.com/guide/mac-help/mh11935/mac)

If preflight cannot read the current Wi-Fi, send `wifi-inspect` to compare the GUI and worker views. This command reports the GUI's Location authorization and whether each process can see one eligible interface and read its SSID. The status contains only categories and flags. The command uses existing authorization and performs no scan, connection change, or internet check.

Send `wifi-inspect-location` to repeat the comparison with passive Location initialization in the diagnostic worker. A separate `wifi_inspect_worker_location` field reports its authorization callback or timeout. This trial neither requests a new permission nor starts location updates. The baseline `wifi-inspect` still runs the worker without a Location manager. Neither path changes the worker configuration used by regular preflight, restoration, or PTP.

After a standard reconnect fails with `secure_status_compared=true` and `secure_status_prefix_equal=false`, `reconnect-registration` runs one additional hypothesis test. It requires the same selected X-T5 record and a verified status read in the new session. The test submits the in-memory registration value with the acknowledgment bit set. `registration_ack_used=true` records only that the probe submitted the substituted write to the production Bluetooth driver. Standard `reconnect` uses the production acknowledgment.

On macOS the probe uses the file-based Keychain. It enumerates persistent references within the dedicated probe service before reading the individual records. The iOS app uses its platform Keychain path.

Run `Scripts/MacWirelessProbe/test.sh` to check the command and file permissions without starting Bluetooth.
Run `Scripts/MacWirelessProbe/test-keychain.sh` to exercise enumeration and saved selection using synthetic records in unique temporary Keychain services.
Run `Scripts/MacWirelessProbe/test-wifi.sh` to check the activation boundary with a test gateway.
Run `Scripts/MacWirelessProbe/test-saved-advertisement.sh` to check scan matching with synthetic reports.
Run `Scripts/MacWirelessProbe/test-secure-status.sh` to check secure-status comparison with synthetic events.
Run `Scripts/MacWirelessProbe/test-registration-reconnect.sh` to check production pairing, reconnect, and Wi-Fi actions through a test driver, including the diagnostics and buffered notification trace.
Run `Scripts/MacWirelessProbe/test-ptp-identity.sh` to check identity and restoration with substitute network and camera sessions and to exercise the worker deadline using local test processes.

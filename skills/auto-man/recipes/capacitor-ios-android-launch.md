# Capacitor iOS/Android launch

## Applies to
A web app wrapped with Capacitor and launched on iOS/Android simulators or emulators (launch-only and beyond). Matches tasks that mention Capacitor, `npx cap ...`, or "wrap the web app as a native app."

## Verify snippets (adapt before use)
All simulator/emulator daemon calls below should be wrapped in `verify.sh`'s `retry()` helper — `simctl`/`adb` have been observed to return transiently empty/truncated output under load (e.g. an Android emulator + Gradle build running concurrently with iOS `simctl` calls).

**iOS process-alive check:**
```bash
if xcrun simctl spawn booted launchctl list | grep -q "$BUNDLE_ID"; then
  add_criterion "ios_process_alive" 1 "launchctl shows $BUNDLE_ID running"
else
  add_criterion "ios_process_alive" 0 "launchctl does not list $BUNDLE_ID"
fi
```

**iOS no-fatal-log check** — use `log show --last <window>`, never `log stream`: `log stream` does not terminate on its own and will hang the script indefinitely. MUST scope to the app's own process with `--predicate 'process == "App"'` (the Capacitor iOS Xcode target/binary is named `App` by default) — an unscoped dump false-positives on unrelated simulator system-daemon lines that happen to contain "Fatal"/"Crash" (e.g. `rapportd`/`replicatord`/`liveactivitiesd` IDS registration chatter reporting `fatalError YES`, or `UserEventAgent` comparing paths against `.../Logs/CrashReporter/`) — observed 40 false-positive matches on a healthy, correctly-rendering app:
```bash
fatal_count=$(xcrun simctl spawn booted log show --last 2m --predicate 'process == "App"' 2>/dev/null | grep -c "Fatal\|Crash" || true)
```

**Android no-fatal-log check** — MUST scope to the app's own pid. An unscoped `adb logcat -d` dumps the whole buffer since boot and false-positives on unrelated system/Zygote lines that happen to also contain "AndroidRuntime":
```bash
android_pid=$(adb shell pidof "$BUNDLE_ID" 2>/dev/null | tr -d '\r\n ')
fatal_count=$(adb logcat -d --pid="$android_pid" 2>/dev/null | grep -c "FATAL\|AndroidRuntime" || true)
if [ "$fatal_count" -eq 0 ]; then
  add_criterion "android_no_fatal_log" 1 "0 fatal lines for pid $android_pid"
else
  add_criterion "android_no_fatal_log" 0 "$fatal_count fatal lines for pid $android_pid"
fi
```

**Screenshots as artifacts** (for a judge subagent, if the task's success condition needs one) — write them under `$ARTIFACTS_DIR` (`.workflow/artifacts`, see `verify.sh.tmpl`), **never under `$TMP_DIR`**: `TMP_DIR` is `rm -rf`'d by `verify.sh`'s own `trap ... EXIT` the instant the script exits, so a screenshot path passed to `add_artifact` as `$TMP_DIR/...` is already deleted by the time a judge subagent (which runs *after* `verify.sh` exits) tries to read it:
```bash
xcrun simctl io booted screenshot "$ARTIFACTS_DIR/ios.png" && add_artifact "$ARTIFACTS_DIR/ios.png"
adb exec-out screencap -p > "$ARTIFACTS_DIR/android.png" && add_artifact "$ARTIFACTS_DIR/android.png"
```

**Judge subagent prompt should explicitly check for status-bar/notch overlap**: Capacitor apps commonly set `viewport-fit=cover`, which makes web content draw fully edge-to-edge including under the notch/status bar. Any absolutely-positioned top header written without native wrapping in mind will not get `env(safe-area-inset-*)` insets applied by default, and will visually overlap the native status bar/clock/battery icons — a real defect that deterministic process-alive/no-fatal-log checks structurally cannot catch, since it only shows up as a screenshot judged by a human/subagent, not a crash. Instruct the judge to flag this specifically. Fix (frontend-only, launch-only scope): add `paddingTop: env(safe-area-inset-top, 0px)` (and grow the container's height by the same amount) to the offending header's container — this is a no-op on plain web (the env() value is 0 without a real notch), so it's safe to apply unconditionally.

## Known pitfalls

- **Capacitor 8.4.1 + iOS `AppDelegate.swift` binary mismatch**: the CLI-generated `application(_:continue:restorationHandler:)` override calls `ApplicationDelegateProxy.shared`, which doesn't match the signature in that version's precompiled `Capacitor.xcframework` binary release — compile fails with `extra argument 'restorationHandler'`. This is an upstream CLI-template/binary-release sync bug, not a config error. If Universal Links aren't needed (most launch-only scopes don't need them), just delete the override — it's an optional `UIApplicationDelegate` method.
- **`log stream` hangs the verify script** — it never terminates on its own; always use `log show --last <window>` for a bounded log check.
- **Unscoped `adb logcat` false-positives** — always scope by pid (`adb shell pidof` + `--pid=`), never grep the whole buffer.
- **Unscoped iOS `log show` false-positives** — the simulator OS log is full of unrelated daemon lines containing the literal words "Fatal"/"Crash" (IDS registration boilerplate, CrashReporter path-comparison noise). Always scope with `--predicate 'process == "App"'`, never grep the raw dump.
- **`simctl`/`adb` transient empty output under concurrent load** — wrap liveness/log checks in `retry()`.
- **CocoaPods is not guaranteed** — depending on the Capacitor version and installed plugins, `npx cap add ios` may generate a `Package.swift` (Swift Package Manager) instead of a `Podfile`/CocoaPods setup. Don't assume `pod install` is always part of the iOS flow; check whether `ios/App/Podfile` exists before scripting around it.
- **Screenshot/artifact paths must survive past `verify.sh`'s own exit** — write them under `$ARTIFACTS_DIR`, never `$TMP_DIR` (see the Verify snippets section above); this was shipped as a live bug in this recipe for weeks after `verify.sh.tmpl` itself was fixed, because the recipe wasn't updated in the same pass.

## CLAUDE.md conventions to append

- Non-interactive init: `npx cap init <name> <id> --web-dir <dir>` (all required args up front, no interactive fallback).
- Non-interactive license acceptance: `yes | sdkmanager --licenses`.
- Emulator must launch headless and backgrounded: `emulator -avd <name> -no-snapshot -no-audio &`.
- New-session startup check: before redoing install/build/launch, check whether the target simulator/emulator is already booted and the target process already alive (`xcrun simctl list devices booted` / `adb devices` + `pidof`). If already running, skip straight to re-collecting evidence (rerun `verify.sh` + judge subagent) rather than repeating the full setup.
- Known scope exemption worth calling out explicitly in `goal-condition.tmpl`'s `{{SCOPE_EXEMPTIONS}}` for launch-only tasks: CORS/network-request failures are a known, unfixable-without-backend-changes limitation and should not count against `allPass`.

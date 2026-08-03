# Electron desktop wrap

## Applies to
A web app (typically CRA/Vite) packaged as a desktop app via Electron, using `electron-builder` for distribution. Matches tasks that mention Electron, `electron-builder`, `.dmg`/`.exe`/`dist:mac`/`dist:win`, or "wrap the web app as a desktop app." Lessons below were gathered on a CRA + electron-builder project; the `build.extends`/code-signing pitfalls are electron-builder-specific and apply regardless of the underlying web framework.

## Verify snippets (adapt before use)

**Strip `ELECTRON_RUN_AS_NODE` before spawning the real Electron binary.** Some host shells (including Claude Code's own tooling in at least one observed environment) export `ELECTRON_RUN_AS_NODE=1` globally. It leaks into any child process spawned from a shell tool call; when set, launching the local `electron` binary makes it behave as plain Node — no `app`, `BrowserWindow`, etc. — so anything requiring Electron's app API silently gets `undefined` (symptom: `TypeError: Cannot read properties of undefined (reading 'getAppPath')`, and the crash's own stack trace shows a plain Node.js version instead of Electron's). Strip it in every `spawn`/`spawnSync` that launches the real binary — this is a correct defensive habit for a shipped app too, not just a dev workaround, since an end user could have that var set for unrelated reasons:
```js
const { ELECTRON_RUN_AS_NODE, ...cleanEnv } = process.env
spawn(electronBinaryPath, args, { env: cleanEnv })
```

**A self-test that creates/destroys multiple `BrowserWindow`s across sequential assertions MUST register a no-op `window-all-closed` handler first**, or the process can silently exit(0) partway through:
```js
app.on('window-all-closed', () => {}) // must be registered before the first win.destroy()
```
Without it, Electron's default behavior quits the whole app the instant zero `BrowserWindow`s remain open — the first `win.destroy()` between assertion groups (with no other window open at that instant) triggers an automatic, silent `app.quit()`, and everything after that point in the script simply never runs, with exit code 0 — easy to misread as "everything passed" rather than "the run was truncated."

**Verify custom-protocol resource loading via a main-process `net.fetch`, not in-page Resource Timing.** `performance.getEntriesByType('resource')` was observed to never contain an entry for a subresource fetched over a custom (non-http/https) `protocol.handle` scheme in Electron 43.x, even when the resource demonstrably loaded (page rendered, script executed). Assert the same property a different way:
```js
const res = await net.fetch('app://bundle/static/js/<mainFile>')
add_criterion('custom_protocol_resource_loads', res.status === 200 && (await res.text()).length > 0)
```

**Force a synchronous `electron-window-state` save when a test destroys the window quickly after changing its bounds.** The library's own resize/move listener is debounced (~100ms); a script that calls `setBounds()` then `destroy()` in quick succession can race the debounce and lose the write. Call `state.saveState(win)` explicitly right after `setBounds()` instead of waiting it out.

**After any change that requires a fresh package build, regenerate `evidence.json` — don't cite a stale one.** file-mtime check: any file `verify.sh` depends on for its criteria (e.g. `dist/*.dmg`, `build/index.html`) should have an mtime at or after the current session's start; if the goal condition can be satisfied by quoting a pre-existing `evidence.json` without re-running `verify.sh`, a session that skips the rebuild can still "succeed" on stale evidence (see `templates/goal-condition.tmpl`'s freshness requirement).

## Known pitfalls

- **`app.getAppPath()` resolves to the wrong directory when Electron is launched with a bare script path** (e.g. `electron electron/main.js`) rather than a directory containing `package.json` — it resolves to `dirname(mainScriptPath)`, not the repo root. This affects both a normal `electron:preview`-style launch and any self-test invoked the same way. Use `path.join(__dirname, '..', 'build')` (or similar, relative to the source file's own known location) instead of anything derived from `app.getAppPath()`. `__dirname` is stable whether run unpacked or from inside an asar.
- **`build-resources/`-style directories are build-time only, not runtime-accessible.** electron-builder reads them at package time; they are not shipped inside the packaged app. Any asset the running app needs at runtime (tray icons, etc.) must live somewhere bundled by the app's own `files` glob (e.g. `electron/assets/`), not in a directory that only exists in the source tree.
- **electron-builder silently merges a legacy `react-cra` preset if it detects `react-scripts` in `dependencies`.** Unless `build.extends` is explicitly set, this preset assumes an old "copy an `electron.js` into CRA's `build/` output" convention and expects the entry point there — producing an opaque `Application entry file "build/electron.js" ... was not found in this archive` error even when `package.json`'s own `main` field is correct. Fix: add `"extends": null` at the top of `build{}` in `package.json` (must be explicit `null`, not simply omitted — electron-builder's own detection treats `undefined` and `null` differently).
- **electron-builder auto-discovers and silently uses any code-signing identity available in the build machine's keychain**, with no warning distinguishing "we signed with a real identity we found" from "this was intentional." If a project has explicitly decided not to code-sign/notarize yet, this can produce signed builds that contradict that decision without any error. Fix: prefix `dist`/`dist:mac`/`dist:win` scripts with `cross-env CSC_IDENTITY_AUTO_DISCOVERY=false` to force genuinely unsigned builds regardless of what's in the build machine's keychain — this also makes the "no signing" decision reproducible in CI (where no identity exists anyway) and on any contributor's machine (where one might).

## CLAUDE.md conventions to append

- Non-interactive launch: strip `ELECTRON_RUN_AS_NODE` from any child env before spawning the real Electron binary (see Verify snippets above) — do this in every script that launches `electron`, not just the self-test.
- Any self-test/verify script that creates and destroys multiple `BrowserWindow`s across sequential assertions must register a no-op `app.on('window-all-closed', () => {})` before the first `win.destroy()`.
- Resolve app-internal paths via `__dirname`, never `app.getAppPath()`-relative, since the entry point may be launched as a bare script rather than a project directory.
- If the project has decided not to code-sign yet, `dist`/`dist:mac`/`dist:win` scripts must set `CSC_IDENTITY_AUTO_DISCOVERY=false` (via `cross-env` or equivalent) — don't rely on simply not configuring a signing identity, since electron-builder will opportunistically use one from the keychain if present.
- A CRA-based Electron wrap must set `build.extends: null` in `package.json`'s `build{}` block, or fight electron-builder's auto-detected `react-cra` preset.
- New-session startup check: before rebuilding/repackaging, check whether `dist/*` already exists and is current for the present commit (compare mtimes / embedded version info) — skip straight to re-collecting evidence if so, per the general startup-check convention, but always rerun `verify.sh` itself rather than citing the existing `evidence.json` (see the freshness verify snippet above).

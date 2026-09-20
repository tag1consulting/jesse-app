# Working agreements for agent sessions in this repo

## Physical devices are not test infrastructure

Anything that drives real hardware takes over the machine it runs on, and whoever is using
that machine loses it for the duration.

**Never take over a device without asking first.** That covers installing to a physical
iPhone or Apple Watch, XCUITest or any other UI automation run, anything that raises a TCC
or permission prompt, and anything that seizes the screen, keyboard or pointer.

Before the first such step, state plainly what it needs, how long it will take, and how
many runs. Then wait for approval. A task that mentions the app is not approval for a
series of automation runs against hardware.

Default to the simulator and to headless verification. If a physical device is really
required, stop and ask rather than deciding it is in scope.

## Never dispatch iOS CI

`ios-ci.yml` runs on hosted macOS runners, which bill at 10x the Linux rate. It is designed
to run **at most once per day**, on its nightly schedule, gated to days with iOS-relevant
commits. A manual `workflow_dispatch` bypasses that gate and always spends the minutes.

**Do not trigger it.** No `gh workflow run ios-ci.yml`, no re-running it, no dispatching it
to confirm a local result.

The gate for the app half is `scripts/local-ci-macos.sh`, run locally in the simulator: the
same checks, in the same order, with the same flags, at no cost. The nightly is a backstop
that reports up to a day late; it covers what a push made with `--no-verify` would
otherwise leave unchecked. It is not a gate and it is not yours to invoke.

Re-running a failed `ci.yml` job is fine; that workflow is Linux-only and cheap. The
prohibition is on `ios-ci.yml` and anything else that starts a hosted macOS runner.

If you believe hosted macOS CI is genuinely required, stop and ask first.

## The Mac app speaks out loud

`Speaker` is silenced only by the `JESSE_MUTE` environment variable, and that variable is set
only on the **`Jesse` (iOS) scheme's** LaunchAction. The **`Jesse Mac` scheme does not set
it**, so the Mac app speaks its replies aloud on every launch.

If you build or run the Mac app, quit it when you are done. Do not leave it running.

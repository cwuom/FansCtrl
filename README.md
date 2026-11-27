<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="FansCtrl icon">
</p>

<h1 align="center">FansCtrl</h1>

<p align="center">Mac fan control by situation: quiet in the library, early cooling under heavy load.</p>

<p align="center">English | <a href="README.zh-CN.md">简体中文</a></p>

FansCtrl controls the fans on Apple Silicon and Intel Macs. You get a main window (overview, temperature and RPM charts, profiles, settings) and a menu bar panel. The UI is built with stock SwiftUI and uses Liquid Glass on macOS 26 and later; on macOS 15 it falls back to the regular materials.

The app's interface is only available in Simplified Chinese for now.

- Requires macOS 15 or later.
- Tested on a MacBook Pro M5 (Mac17,2). Manual fan control works there, and the Max profile measured 6574 RPM.
- Intel Macs are supported according to the SMC spec and covered by unit tests, but nobody has run it on a real Intel machine yet.

## Profiles

Fan speeds are expressed as a fraction of each fan's min-to-max RPM range, so the same profile works across different Macs.

| Profile | Behavior | Good for |
| --- | --- | --- |
| System | Doesn't touch the fans | Apple's stock behavior |
| Library | Cap at 0.12 (about 2830 RPM on a 14" M5). macOS runs the fans as usual until it wants to go faster than the cap; then FansCtrl takes over and holds them there | Libraries, study rooms, meetings |
| Quiet | Cap at 0.30 | Dorm rooms, offices |
| Balanced | Follows a curve above 60°C and starts cooling earlier than macOS does | Everyday use |
| Performance | Ramps up from 50°C to cut down on throttling | Rendering, compiling, games |
| Max | Full speed | Cooling down quickly |
| Smart | Switches between Library, Quiet, Balanced and Performance based on smoothed CPU load, power source and thermal pressure. It steps up after 8 s and steps down after 45 s | When you don't want to switch by hand |

Smart has a "quiet first" switch. With it on, Smart only moves between Library and Quiet, which is useful when you need to stay quiet for hours.

Why a cap instead of a custom low-speed curve? On the M5 MacBook Pro, macOS only runs the fans at around 2500 RPM with the CPU at 90°C. A hand-tuned "silent curve" can't beat that. A cap means Library and Quiet can't end up louder than the system default.

The trade-off: under sustained heavy load a cap lets the chip run hotter, so it may start throttling a little earlier than it would on System. Once thermal pressure reaches `serious` (heavy throttling is about to start) or the temperature crosses the safety limit, the cap is lifted, so you won't sit in heavy throttling for long.

### Suppress

For when the fans suddenly get loud, say you started a build in the library. Suppress drops the fans to this Mac's minimum RPM right away (they keep spinning) and hands control back after 60 seconds. That gives you time to quit whatever is hogging the CPU.

- Before it starts, the app tells you that noise will drop for 60 seconds and you should close the heavy apps now.
- If the temperature stays at 103°C (95°C on Intel), suppress ends early and returns control to macOS. The emergency full-speed rule always wins.
- Afterwards there is a cooldown of twice the time it ran, up to 120 seconds, so you can't keep the chip hot by chaining suppressions.
- It ends automatically before sleep.

```bash
fanctl suppress        # start
fanctl suppress off    # stop early
```

## Safety

- Only the daemon writes to the SMC. Its local socket accepts three commands: `status`, `setProfile` and `setQuietFirst`. There is no raw SMC read/write. Each connection is checked with `getpeereid`, and only root and the user logged in at the console are allowed.
- Fan speed is always clamped to the fan's [min, max]. Writes with a mismatched type or size are rejected.
- After switching a fan to manual mode, the daemon reads the value back. If the firmware didn't take it, that's an error. If macOS takes the fan back to auto three times in a row, the Mac is treated as unsupported and FansCtrl stops trying.
- Emergency full speed: at 108°C or above (99°C on Intel), or thermal pressure `critical`, fans go to max. They stay there until the temperature drops to 100°C (90°C on Intel).
- Safety limit for the quiet profiles: at 103°C or above (95°C on Intel), or thermal pressure `serious`, the cap is lifted and macOS takes over. There is 6°C of hysteresis.
- If no trustworthy temperature can be read, control goes back to macOS immediately.
- Automatic control is restored before sleep, when the daemon exits (SIGTERM/SIGINT/SIGHUP) and on uninstall. If the daemon crashes, launchd restarts it, and the first thing it does on startup is restore automatic control.
- Fanless Macs (MacBook Air) are detected as unsupported and nothing is written.

## Resource usage

- The daemon uses about 8 MB RSS and close to zero CPU. In testing, a few dozen seconds of runtime added up to 0.02–0.04 s of CPU time.
- On System there is no timer; status is read on demand. Other profiles sample every 2 seconds. Metadata for the temperature keys is cached, so each sample is a single IOKit call.
- The app only polls while the main window or the menu bar panel is visible. Once both are closed it stops waking up.

## Install

Download `FansCtrl-x.y.z.dmg` from Releases, drag FansCtrl into Applications and open it. On first launch it offers to install the background service, which asks for an administrator password.

The app is ad-hoc signed and not notarized by Apple. If Gatekeeper blocks it the first time, go to System Settings → Privacy & Security and click "Open Anyway".

You can also install the background service by hand:

```bash
sudo build/FansCtrl.app/Contents/Resources/install.sh
```

This installs `/Library/PrivilegedHelperTools/com.fansctrl.daemon`, `/Library/LaunchDaemons/com.fansctrl.daemon.plist` and `/usr/local/bin/fanctl`. To uninstall:

```bash
sudo build/FansCtrl.app/Contents/Resources/uninstall.sh
```

Closing the main window leaves FansCtrl in the menu bar and hides the Dock icon. The fans are controlled by the background service, whether the app is open or not.

## Command line

```bash
fanctl status            # current state
fanctl set library       # system | library | quiet | balanced | performance | max | smart
fanctl quiet-first on    # quiet first for Smart
fanctl watch             # refresh every 2 seconds
fanctl probe             # read-only check of this Mac's fans and sensors, no daemon needed
```

To check whether your firmware accepts manual fan speeds, first run `fanctl set system` or uninstall the service so two processes aren't writing to the SMC at once, then:

```bash
sudo fanctl selftest
```

## Building from source

Requires Xcode 26 or later (the Liquid Glass APIs come from the macOS 26 SDK).

```bash
swift test
```

```bash
./scripts/build-app.sh
```

```bash
./scripts/build-dmg.sh
```

Output goes to `build/`. The icon is drawn with CoreGraphics by `scripts/make-icon.swift`. SF Symbols aren't used because their license doesn't allow them in app icons. The generated icon is committed as `Support/AppIcon.icns`; after changing the script, regenerate it with:

```bash
swift scripts/make-icon.swift build/icon && iconutil -c icns build/icon/AppIcon.iconset -o Support/AppIcon.icns
```

To debug without writing to the SMC or running as root (the socket path has to be shorter than 104 bytes):

```bash
.build/debug/fanctld --dry-run --socket .build/dev.sock --config .build/dev-config.json
```

```bash
FANSCTRL_SOCKET=.build/dev.sock .build/debug/fanctl status
```

In dry-run status output, the "下发" column is the RPM the daemon would write, and "SMC目标" is the target the system is actually using.

### Layout

```
Sources/CSMC        AppleSMC user-space client (C, keeps the 80-byte struct layout)
Sources/FanCore     SMC encoding, model detection, profile policies, controller, Smart selector, IPC protocol
Sources/fanctld     root daemon: control loop, socket server, sleep and signal handling
Sources/fanctl      command-line tool
Sources/FansCtrlApp main window and menu bar panel (SwiftUI, Swift Charts, Liquid Glass)
Support/            Info.plist, app icon, install/uninstall scripts
scripts/            build the app and DMG, generate the icon
```

### Hardware notes

- Apple Silicon: mode key `F0md` (or `F0Md`). Temperature is the highest valid reading among `Tp*`/`Te*` (CPU) and `Tg*` (GPU). If an `Ftst` unlock key exists, it is set to 1 first and cleared on restore.
- Intel: newer models use `F0Md`, older ones the `FS! ` bitmask. Temperature comes from `TC0P`/`TC0D`/`TCxC`, `TG0P` and similar keys. RPM values are `fpe2` fixed point.

## Disclaimer

FansCtrl talks to the SMC directly to control the fans. It has several layers of protection (RPM clamping, lifting the cap when hot, emergency full speed, handing control back on errors), but changing how your Mac cools itself is still a risk. Use it at your own judgment.

## License

[MIT](LICENSE)

# Hello Kitty Theme for Windows 10 / 11

The script is a PowerShell tool with no dependencies. It ports the look of the
Linux theme [`quandangv/hello-kitty`](https://github.com/quandangv/hello-kitty)
to Windows. It saves your current theme. Then it can switch between your theme
and the Hello Kitty theme.

The script does not require Administrator rights. Every change is per-user
(`HKCU` / `%LOCALAPPDATA%`).

## What it ports

| Original (Linux)            | Windows equivalent                                                          |
|----------------------------|----------------------------------------------------------------------------|
| `background.png`           | Desktop wallpaper, set to Fill                                              |
| `pink.scheme.ini` accent   | Windows accent color `#FF2E6D` on the taskbar, the Start menu, the title bars |
| white/pink palette         | Light mode (apps and system) with the accent on the taskbar                |
| `picom` blur               | Frosted acrylic on the taskbar and the Start menu                          |
| `Cookie` / `Iosevka` / `Source Code Pro` fonts | Installed per-user, registered under their real family names, used by Windows Terminal |
| `termite` colors           | A "Hello Kitty" color scheme for Windows Terminal, with acrylic terminal   |

## Why the Start menu stayed blue

The Start menu and the taskbar read different registry values.

- The taskbar and the title bars read `ColorizationColor` (`HKCU\...\DWM`) and
  `AccentColorMenu` (`HKCU\...\Explorer\Accent`, AABBGGRR).
- The Start menu reads the 32-byte `AccentPalette` (8 entries of R,G,B,A) in
  `HKCU\...\Explorer\Accent`. When you change `AccentColorMenu`, Windows does
  not regenerate this value. The old script wrote only `AccentColorMenu`. As a
  result, the Start menu kept the default blue palette, but the taskbar turned
  pink.
- If "Transparency effects" is off, the Start menu shows that palette color as
  a solid color, not as frosted glass.

The script writes the pink `AccentPalette` and `StartColorMenu`. It also
forces `EnableTransparency=1`. As a result, the Start menu is pink and frosted,
like the taskbar. The script saves and restores all of these values with your
old theme.

## Usage

Run these commands from a PowerShell prompt in this folder:

```powershell
.\hello-kitty.ps1 toggle     # flip between Hello Kitty and your saved theme
.\hello-kitty.ps1 apply      # turn Hello Kitty ON  (auto-saves your theme first)
.\hello-kitty.ps1 restore    # turn Hello Kitty OFF (back to your saved theme)
.\hello-kitty.ps1 status     # show what is currently active
.\hello-kitty.ps1 install    # only fetch assets + install fonts (no theme change)
```

`toggle` is the main command. It reads the mode from
`%LOCALAPPDATA%\hello-kitty\state.json`. Then it switches to the other side
each time.

### The native Windows theme API

The script talks directly to the theme manager of Windows. That is the
reverse-engineered `IThemeManager2` COM API in `themeui.dll`. The Settings app
uses the same API. Read [RESEARCH.md](RESEARCH.md) for the full map of the
theming system.

```powershell
.\hello-kitty.ps1 themes              # list installed Windows themes (native)
.\hello-kitty.ps1 theme-switch 3      # switch to theme #3 (native apply, like Settings)
.\hello-kitty.ps1 theme-save C:\path  # save the current theme natively
.\hello-kitty.ps1 theme-restore C:\path  # install + apply a saved theme (like the MS Store)
.\hello-kitty.ps1 theme-file          # (re)generate an installable "Hello Kitty.theme"
.\hello-kitty.ps1 theme-file apply    # ... and apply it natively (same as double-clicking)
.\hello-kitty.ps1 taskbar-acrylic 120 # live-tune taskbar frosting (0 = transparent .. 255 = max blur)
.\hello-kitty.ps1 start-acrylic 96    # live-tune Start menu transparency (0 = fully transparent .. 255 = solid pink)
```

- `theme-save` creates the roaming theme blob. This blob has the same format
  family as the Microsoft Store theme packs. It contains the `.theme` file and
  the embedded wallpaper.
- `theme-file` writes a real theme file (`Hello Kitty.theme`) into the user
  themes folder. The format is the same one Windows writes. The theme appears
  in Settings and in the `themes` listing. You can double-click the file or
  share it like any `.theme` file. The `.theme` file carries the wallpaper, its
  position, the accent, the auto-colorization, and the light/dark mode. The
  registry layer (`apply`) adds what the `.theme` file cannot carry: the
  Start-menu accent palette, the transparency, the taskbar acrylic.

> CAUTION: Do not switch to a "High Contrast" theme except for a deliberate
> test. A switch to one of these themes turns on High Contrast mode. Normal
> theme applications do not turn it off. The script marks these themes in
> the `themes` output. If it was off before, it turns High Contrast off after
> `theme-switch` or `theme-restore`. If you are stuck in High Contrast, run
> `hello-kitty.ps1 apply`, or use Settings > Ease of Access > High contrast.

- You do not need Administrator rights for these commands. We verified these
  commands on Windows 10 21H2 (build 19044).

> Tip: You can also use `hello-kitty.bat`. Double-click it to run the same
> commands. For example, run `hello-kitty.bat toggle`.

## How save and restore work

- On the first `apply` or `toggle`, the script saves your current theme. It
  saves the wallpaper, the accent color, the light/dark mode, the taskbar
  settings, and the Windows Terminal settings. The files are
  `%LOCALAPPDATA%\hello-kitty\saved-theme.json` and `terminal-backup.json`.
- `restore` or `toggle` writes those values back exactly. Then it restarts
  Explorer. The change is visible.

## Notes

- Restart Windows Terminal once after the first run. Then it finds the Iosevka
  Nerd Font. Until then, you can get a harmless "font not found" warning.
- The change of the taskbar and title-bar color restarts `explorer.exe`. The
  desktop flickers for a second. This is normal.
- The script changes the Windows Terminal `settings.json`. It adds a
  `Hello Kitty` scheme and points every profile at it. The script backs up your
  original file and restores it fully on `restore`.
- The terminal acrylic uses the current profile settings: `opacity` (0-100) and
  `useAcrylic`. Acrylic renders only while "Transparency effects" is on. The
  theme turns this on. Acrylic does not render during Battery Saver.
- `TaskbarAcrylicOpacity` is a Windows 10 value. The range is 0 to 255. 0 is
  fully transparent. 255 is maximum blur. The default for this theme is 80,
  which gives a visible frosted blur.
- You can tune the taskbar blur live. Run `hello-kitty.ps1 taskbar-acrylic
  <0-255>`. On Windows 11, the taskbar ignores this value. The taskbar becomes
  frosted through `EnableTransparency` instead.
- On some Windows 10 builds, a sign out and a sign in are necessary before the
  Start-menu color changes appear. The script restarts Explorer first.

## What the port does not include

These parts of the original theme have no Windows equivalent. The script leaves
them out on purpose:

- The script does not include the `bspwm` window manager (`others/bspwmrc`).
- It does not include the `polybar` status bar (`polybar/*`). There is no
  drop-in replacement here.
- It does not include the `picom` compositor. Windows does its own acrylic and
  transparency.
- It does not include the `dmenu` launcher. Use PowerToys Run or the Windows
  search instead.
- It does not include the `sxhkd` keybindings. Windows has its own shortcut
  layer.
- It does not include the `taskwarrior` and `pomodoro` polybar modules. These
  are out of scope for a theme.

A top bar like polybar requires a separate app. For example, a small
always-on-top WPF or WinForms window. This script does not include one.

## Files

- `hello-kitty.ps1` contains the full tool (one file, no modules).
- `hello-kitty.bat` is the double-click launcher.
- `assets/` contains the wallpaper and the three fonts. If they are missing,
  the script downloads them from the source repo.
- `RESEARCH.md` is the reverse-engineering map of the native Windows theming
  system.
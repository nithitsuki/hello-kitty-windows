<#
.SYNOPSIS
    Hello Kitty theme switcher for Windows 10 / 11.

.DESCRIPTION
    Ports the look of the Linux "hello-kitty" theme (https://github.com/quandangv/hello-kitty)
    to Windows and lets you flip between it and your own saved theme.

    What it ports:
      * Desktop wallpaper  -> the Hello Kitty background.png (set to "Fill")
      * Accent color       -> the theme's hot pink (#FF2E6D) on taskbar / start / title bars
      * Light mode         -> apps + system set to light to match the white/pink palette
      * Start menu         -> frosted/translucent (EnableTransparency) + pink AccentPalette
      * Taskbar            -> most-transparent acrylic taskbar (TaskbarAcrylicOpacity 0)
      * Windows Terminal   -> a "Hello Kitty" color scheme (incl. translucent acrylic terminal)

    It never needs Administrator: every change is per-user (HKCU / %LOCALAPPDATA%).

.EXAMPLE
    .\hello-kitty.ps1 toggle     # flip between Hello Kitty and your saved theme
    .\hello-kitty.ps1 apply      # turn Hello Kitty ON (auto-saves your theme first)
    .\hello-kitty.ps1 restore    # turn Hello Kitty OFF (back to your saved theme)
    .\hello-kitty.ps1 status     # show what is currently active
    .\hello-kitty.ps1 install    # only fetch assets (no theme change)
    .\hello-kitty.ps1 themes     # list installed themes via the NATIVE Windows theme API
    .\hello-kitty.ps1 theme-save [path]    # save the CURRENT theme as a real .theme file
    .\hello-kitty.ps1 theme-restore <path> # apply a .theme file natively (like double-clicking)
    .\hello-kitty.ps1 restart-shell        # forced explorer restart (guarded, never leaves it dead)
    .\hello-kitty.ps1 theme-switch <idx>   # switch to an installed theme natively (see 'themes')
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('toggle', 'apply', 'restore', 'on', 'off', 'status', 'install',
                 'themes', 'theme-save', 'theme-restore', 'theme-switch', 'theme-file',
                 'restart-shell', 'savetheme', 'taskbar-acrylic', 'start-acrylic')]
    [string]$Command = 'toggle',

    [Parameter(Position = 1)]
    [string]$ThemeArg = ''
)

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------------------
# Paths & constants
# ----------------------------------------------------------------------------
$ScriptDir       = Split-Path -Parent $MyInvocation.MyCommand.Definition
$AssetsDir       = Join-Path $ScriptDir 'assets'
$StateDir        = Join-Path $env:LOCALAPPDATA 'hello-kitty'
$SavedThemePath  = Join-Path $StateDir 'saved-theme.json'
$StatePath       = Join-Path $StateDir 'state.json'
$TerminalBackup  = Join-Path $StateDir 'terminal-backup.json'

$WallpaperSrc    = Join-Path $AssetsDir 'background.png'

# The user themes folder - files here appear in Settings > Themes and in the
# native theme manager listing ("themes" command).
$UserThemesDir   = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Themes'
$HKThemeFilePath = Join-Path $UserThemesDir 'Hello Kitty.theme'

# Hello Kitty palette (from polybar/pink.scheme.ini and others/dmenu.sh)
$HK_PINK        = '#FF2E6D'   # launcher foreground - the signature pink
$HK_PINK_LIGHT  = '#FF699F'   # launcher background
$HK_DMENU_SELBG = '#FF447C'   # dmenu selection background -> accent hover
$HK_DMENU_NORMBG = '#F4E8EC'
$HK_DMENU_SELFG = '#FF0058'
$HK_TITLEBAR    = '#E01E5B'   # slightly darker pink for title bars / borders

$HK_TASKBAR_ACRYLIC = 80    # taskbar acrylic: 0 = fully transparent, 255 = max blur
                            # 80 = visible frosted blur, still translucent (user-verified)
$HK_PALETTE_ALPHA = 96      # accent palette opacity (Start menu / action centre tint):
                            # 0 = fully transparent .. 255 = solid. 96 = clearly frosted,
                            # 170 = light frost, 255 = solid colour (user-tunable)

$RepoRaw = 'https://raw.githubusercontent.com/quandangv/hello-kitty/main'

# Windows 11 gates "Show accent color on Start and taskbar" behind Dark system
# mode (SystemUsesLightTheme=0). Win10 has no such gate. Build >=22000 is Win11.
function Get-OSBuildNumber {
    try { return [Environment]::OSVersion.Version.Build } catch { return 0 }
}
function Test-IsWin11 { return (Get-OSBuildNumber) -ge 22000 }
function Get-HKSystemLight {
    # Apps stay Light (white/pink) on both OSes; System is Dark on 11 so the
    # taskbar accent actually paints, Light on 10 (legacy behaviour).
    if (Test-IsWin11) { return 0 } else { return 1 }
}

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
function Write-Pink($Message) { Write-Host $Message -ForegroundColor Magenta }
function Write-Info($Message) { Write-Host "  $Message" -ForegroundColor Gray }
function Write-Ok($Message)   { Write-Host "  [+] $Message" -ForegroundColor Green }
function Write-Warn($Message) { Write-Host "  [!] $Message" -ForegroundColor Yellow }

# Immediate, unbuffered progress log (survives hangs / interrupted runs)
$LogFile = Join-Path $env:TEMP 'hk-log.txt'
function Step($Message) {
    try { [System.IO.File]::AppendAllText($LogFile, "$(Get-Date -Format 'HH:mm:ss.fff')  $Message`n") } catch { }
}

if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }

<#
  Convert "#RRGGBB" to a registry DWORD.
  ColorizationColor is AARRGGBB (verified: default 0xC40078D7 => #0078D7 blue).
  AccentColorMenu is AABBGGRR (verified empirically: setting it as AABBGGRR makes
  the derived ColorizationColor render pink; setting it as AARRGGBB renders blue).
  Pass -AABBGGRR for AccentColorMenu / StartColorMenu.
#>
function ConvertTo-ColorDWord {
    param([string]$Hex, [byte]$Alpha = 255, [switch]$AABBGGRR)
    $Hex = $Hex.TrimStart('#')
    $r = [Convert]::ToInt32($Hex.Substring(0, 2), 16)
    $g = [Convert]::ToInt32($Hex.Substring(2, 2), 16)
    $b = [Convert]::ToInt32($Hex.Substring(4, 2), 16)
    if ($AABBGGRR) {
        # bytes (LE): R,G,B,A  -> DWORD AABBGGRR
        $bytes = [byte[]]@([byte]$r, [byte]$g, [byte]$b, [byte]$Alpha)
    } else {
        # bytes (LE): B,G,R,A  -> DWORD AARRGGBB
        $bytes = [byte[]]@([byte]$b, [byte]$g, [byte]$r, [byte]$Alpha)
    }
    return [BitConverter]::ToUInt32($bytes, 0)
}

# "#RRGGBB" -> 4 bytes [R,G,B,A] (the AccentPalette binary layout)
function ConvertTo-RGBABytes([string]$Hex, [byte]$Alpha = 255) {
    $Hex = $Hex.TrimStart('#')
    return ,[byte[]]@(
        [Convert]::ToByte($Hex.Substring(0, 2), 16),
        [Convert]::ToByte($Hex.Substring(2, 2), 16),
        [Convert]::ToByte($Hex.Substring(4, 2), 16),
        [byte]$Alpha
    )
}

<#
  32-byte AccentPalette used by the Start menu / taskbar / action center.
  8 entries x 4 bytes, each [R,G,B,A]. Windows ships the DEFAULT BLUE palette here
  and the shell does NOT regenerate it from AccentColorMenu - which is why the
  Start menu stays opaque blue while the taskbar (which reads AccentColorMenu /
  ColorizationColor) turns pink. Writing it is what actually re-colours the
  Start menu (same approach as the well-known "Pitch Black Theme" gists).
#>
function New-HKAccentPalette {
    param([int]$Alpha = $HK_PALETTE_ALPHA)
    # Alpha controls how much of the frosted wallpaper shows through the pink
    # tint on Start menu / action centre: 0 = fully transparent .. 255 = solid.
    # AveYo's themes ship ~0xAA; users asked for more transparency here, so the
    # default is 96 (0x60). Tunable live via 'start-acrylic' command.
    $a = [byte]$Alpha
    $entries = @(
        $HK_DMENU_SELBG,  # 0 Accent hover
        $HK_PINK,         # 1 Accent (main)
        $HK_TITLEBAR,     # 2 Active title bar / border
        $HK_PINK,         # 3 Settings icons / links
        $HK_PINK,         # 4 Start menu background (when transparency off) / active taskbar button
        '#FFFFFF',        # 5 Taskbar front / folders on Start list background (light mode)
        $HK_PINK,         # 6 Taskbar background (when transparency on)
        '#FFFFFF'         # 7 Unused
    )
    $bytes = New-Object System.Collections.Generic.List[byte]
    foreach ($e in $entries) { $bytes.AddRange([byte[]](ConvertTo-RGBABytes $e $a)) }
    return $bytes.ToArray()
}

# ----------------------------------------------------------------------------
# Windows API bits (compiled once per process). Class name MUST match the
# type check below, otherwise Add-Type re-runs and throws "type already exists".
# ----------------------------------------------------------------------------
function Ensure-WinApi {
    if (-not ('HelloKittyWinAPI' -as [type])) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;
public class HelloKittyWinAPI {
    // SPI_SETDESKWALLPAPER (20) with SPIF_UPDATEINIFILE | SPIF_SENDCHANGE (3)
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
"@
    }
}

# ----------------------------------------------------------------------------
# Native theme manager: reverse-engineered IThemeManager2 COM API (themeui.dll)
# (CLSID {9324da94-...} "Windows Theme Manager 2 API" - the same API the
#  Settings app uses to list / apply / save Windows themes.)
# Reverse-engineered by the SecureUxTheme project (LGPL-2.1):
#   https://github.com/namazso/SecureUxTheme  (ThemeLib/theme.cpp, re/*.h)
# Verified S_OK on Windows 10 21H2: Init, GetThemeCount/Current/Custom/Default,
# SetCurrentTheme. NOTE: ExportRoamingThemeToStream returns S_OK but only emits
# an ~82-byte serialization header from a bare CoCreateInstance process, so
# 'theme-save' writes a plain .theme file instead (see Save-ThemeFile below).
# NOTE: theme objects returned by GetTheme are bare C++ vtables (not QI-able)
# whose layout shifts per build - we deliberately don't call into them.
# ----------------------------------------------------------------------------
function Ensure-ThemeApi {
    if (-not ('HelloKittyThemeApi' -as [type])) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Threading;

namespace HelloKittyThemeApi {

  [ComImport]
  [Guid("c1e8c83e-845d-4d95-81db-e283fdffc000")]
  [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IThemeManager2 {
    [PreserveSig] int Init(int flags);
    [PreserveSig] int InitAsync(IntPtr hwnd, int unknown);
    [PreserveSig] int Refresh();
    [PreserveSig] int RefreshAsync(IntPtr hwnd, int unknown);
    [PreserveSig] int RefreshComplete();
    [PreserveSig] int GetThemeCount(out int count);
    [PreserveSig] int GetTheme(int idx, out IntPtr theme);
    [PreserveSig] int IsThemeDisabled(int idx, out int disabled);
    [PreserveSig] int GetCurrentTheme(out int idx);
    [PreserveSig] int SetCurrentTheme(IntPtr parent, int theme_idx, int applyNow, uint applyFlags, uint packFlags);
    [PreserveSig] int GetCustomTheme(out int idx);
    [PreserveSig] int GetDefaultTheme(out int idx);
    [PreserveSig] int CreateThemePack(IntPtr parent, [MarshalAs(UnmanagedType.LPWStr)] string path, uint packFlags);
    [PreserveSig] int CloneAndSetCurrentTheme(IntPtr parent, [MarshalAs(UnmanagedType.LPWStr)] string path, [MarshalAs(UnmanagedType.BStr)] out string resultPath);
    [PreserveSig] int InstallThemePack(IntPtr parent, [MarshalAs(UnmanagedType.LPWStr)] string path, int unknown, uint applyFlags, uint packFlags, [MarshalAs(UnmanagedType.BStr)] out string p1, out IntPtr theme);
    [PreserveSig] int DeleteTheme([MarshalAs(UnmanagedType.LPWStr)] string path);
    [PreserveSig] int OpenTheme(IntPtr parent, [MarshalAs(UnmanagedType.LPWStr)] string path, uint packFlags);
    [PreserveSig] int AddAndSelectTheme(IntPtr parent, [MarshalAs(UnmanagedType.LPWStr)] string path, uint applyFlags, uint packFlags);
    [PreserveSig] int SQMCurrentTheme();
    [PreserveSig] int ExportRoamingThemeToStream([MarshalAs(UnmanagedType.Interface)] IStream stream, int unknown);
    [PreserveSig] int ImportRoamingThemeFromStream([MarshalAs(UnmanagedType.Interface)] IStream stream, int unknown);
    [PreserveSig] int UpdateColorSettingsForLogonUI();
    [PreserveSig] int GetDefaultThemeId(out Guid id);
    [PreserveSig] int UpdateCustomTheme();
  }

  public static class Interop {
    [DllImport("ole32.dll")]
    public static extern int CoInitialize(IntPtr pvReserved);
    [DllImport("ole32.dll")]
    public static extern int CoCreateInstance(ref Guid clsid, IntPtr pUnk, uint dwClsContext, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out object ppv);

    public static readonly Guid CLSID_ThemeManager2 = new Guid("9324da94-50ec-4a14-a770-e90ca03e7c8f");
    public static readonly Guid IID_IThemeManager2 = new Guid("c1e8c83e-845d-4d95-81db-e283fdffc000");
  }

  public static class Native {
    // The COM class is Apartment-threaded with no registered proxy for the
    // RE'd IID; run calls on an STA thread when the caller is MTA.
    static T Sta<T>(Func<T> f) {
      if (Thread.CurrentThread.GetApartmentState() == ApartmentState.STA) return f();
      T result = default(T);
      Exception error = null;
      var th = new Thread(() => { try { result = f(); } catch (Exception e) { error = e; } });
      th.SetApartmentState(ApartmentState.STA);
      th.Start();
      th.Join();
      if (error != null) throw error;
      return result;
    }

    public static int[] GetState() {
      return Sta<int[]>(() => {
        var r = new int[4];
        using (var ctx = Open()) {
          int count = 0, cur = 0, custom = 0, def = 0;
          ctx.Mg.Init(0);
          ctx.Mg.GetThemeCount(out count);
          ctx.Mg.GetCurrentTheme(out cur);
          ctx.Mg.GetCustomTheme(out custom);
          ctx.Mg.GetDefaultTheme(out def);
          r[0] = count; r[1] = cur; r[2] = custom; r[3] = def;
        }
        return r;
      });
    }

    public static int SwitchTheme(int idx, bool applyNow) {
      return Sta<int>(() => {
        using (var ctx = Open()) {
          ctx.Mg.Init(0);
          return ctx.Mg.SetCurrentTheme(IntPtr.Zero, idx, applyNow ? 1 : 0, 0, 0);
        }
      });
    }

    // .theme DisplayName values like '@C:\Windows\...\themeui.dll,-2013' are
    // indirect resource strings - resolve them to human-readable names.
    [DllImport("shlwapi.dll", CharSet = CharSet.Unicode)]
    static extern int SHLoadIndirectString(string pszSource, System.Text.StringBuilder pszOutBuf, int cchOutBuf, IntPtr ppvReserved);

    public static string ResolveIndirect(string s) {
      if (string.IsNullOrEmpty(s) || !s.StartsWith("@")) return s;
      var sb = new System.Text.StringBuilder(512);
      int hr = SHLoadIndirectString(s, sb, sb.Capacity, IntPtr.Zero);
      return (hr == 0 && sb.Length > 0) ? sb.ToString() : s;
    }

    // --- High Contrast safety (SPI_GETHIGHCONTRAST / SPI_SETHIGHCONTRAST) ---
    [StructLayout(LayoutKind.Sequential)]
    struct HIGHCONTRAST { public int cbSize; public int dwFlags; public IntPtr lpszDefaultScheme; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int SystemParametersInfo(int uAction, int uParam, ref HIGHCONTRAST lpvParam, int fuWinIni);
    const int SPI_GETHIGHCONTRAST = 0x0042;
    const int SPI_SETHIGHCONTRAST = 0x0043;
    const int SPIF_SENDCHANGE = 0x2;
    const int HCF_HIGHCONTRASTON = 0x1;

    // Some themes (the "Ease of Access" / high-contrast ones) turn High Contrast
    // mode on when applied. Detect the live state, not just the registry.
    public static bool IsHighContrastOn() {
      HIGHCONTRAST hc = new HIGHCONTRAST();
      hc.cbSize = Marshal.SizeOf(typeof(HIGHCONTRAST));
      SystemParametersInfo(SPI_GETHIGHCONTRAST, hc.cbSize, ref hc, 0);
      return (hc.dwFlags & HCF_HIGHCONTRASTON) != 0;
    }

    public static void ForceHighContrastOff() {
      HIGHCONTRAST hc = new HIGHCONTRAST();
      hc.cbSize = Marshal.SizeOf(typeof(HIGHCONTRAST));
      hc.dwFlags = 0;
      hc.lpszDefaultScheme = IntPtr.Zero;
      SystemParametersInfo(SPI_SETHIGHCONTRAST, hc.cbSize, ref hc, SPIF_SENDCHANGE);
    }

    class Ctx : IDisposable {
      public IThemeManager2 Mg;
      public void Dispose() {
        if (Mg != null) { Marshal.FinalReleaseComObject(Mg); Mg = null; }
      }
    }
    static Ctx Open() {
      Interop.CoInitialize(IntPtr.Zero);
      object obj = null;
      Guid c = Interop.CLSID_ThemeManager2, i = Interop.IID_IThemeManager2;
      int hr = Interop.CoCreateInstance(ref c, IntPtr.Zero, 0x1, ref i, out obj);
      if (hr != 0 || obj == null)
        throw new Exception("CoCreateInstance(ThemeManager2) failed 0x" + ((uint)hr).ToString("X8") +
          " - native theme API unavailable (themes service stopped?)");
      return new Ctx { Mg = (IThemeManager2)obj };
    }
  }
}
"@
    }
}

# Native theme-list helpers
function Get-ThemeFileNames {
    # Names for installed themes come from the .theme files themselves.
    $dirs = @(
        (Join-Path $env:WINDIR 'Resources\Themes'),
        (Join-Path $env:WINDIR 'Resources\Ease of Access Themes'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Themes')
    )
    $files = @()
    foreach ($d in $dirs) {
        if (Test-Path $d) { $files += Get-ChildItem $d -Filter '*.theme' -File -ErrorAction SilentlyContinue }
    }
    $files | ForEach-Object {
        $display = $null
        $inTheme = $false
        foreach ($ln in (Get-Content $_.FullName -ErrorAction SilentlyContinue)) {
            $t = $ln.Trim()
            if ($t -match '^\[') { $inTheme = ($t -ieq '[Theme]'); continue }
            if ($inTheme -and $t -match '^DisplayName\s*=\s*(.+?)\s*$') { $display = $Matches[1]; break }
        }
        # Ease-of-Access themes enable High Contrast mode when applied - flag them.
        $isHc = ($_.FullName -like '*\Ease of Access Themes\*')
        if (-not $isHc) {
            $isHc = [bool](Select-String -Path $_.FullName -Pattern '^HighContrast\s*=' -Quiet -ErrorAction SilentlyContinue)
        }
        [pscustomobject]@{ Name = $display; File = $_.FullName; HighContrast = $isHc }
    }
}

function Show-NativeThemes {
    try {
        Ensure-ThemeApi
        $st = [HelloKittyThemeApi.Native]::GetState()
        Write-Pink "Native theme manager (themeui.dll ThemeManager2)"
        Write-Info "Installed themes : $($st[0])   current=$($st[1])   custom=$($st[2])   default=$($st[3])"
        $names = Get-ThemeFileNames
        if ($names) {
            Write-Info "Installed theme files (name <- path):"
            $names | ForEach-Object {
                $n = $_.Name
                try {
                    if ($n -and $n.StartsWith('@')) { $n = [HelloKittyThemeApi.Native]::ResolveIndirect($n) }
                } catch { }
                $tag = if ($_.HighContrast) { '  [Ease-of-Access theme - applies HIGH CONTRAST mode]' } else { '' }
                Write-Info ("  {0} <- {1}{2}" -f $(if ($n) { "'$n'" } else { '(no DisplayName)' }), $_.File, $tag)
            }
            if ($names | Where-Object { $_.HighContrast }) {
                Write-Warn "High Contrast themes are listed above - theme-switch on them will be auto-undone by this script."
            }
        } else {
            Write-Info "No .theme files found in the standard theme folders."
        }
        Write-Info "Switch with: hello-kitty.ps1 theme-switch <index>"
    } catch {
        Write-Warn "Native theme API failed: $($_.Exception.Message)"
        Write-Warn "Fallback: this script's apply/restore still works (registry layer)."
    }
}

function Save-ThemeFile {
    param([string]$Path)
    # Default: a timestamped .theme in the user themes folder so it shows up in
    # Settings > Personalization > Themes - exactly like "Hello Kitty.theme".
    if (-not $Path) {
        $stamp = Get-Date -Format 'yyyy-MM-dd HHmmss'
        $Path = Join-Path $UserThemesDir "Saved theme $stamp.theme"
    }
    try {
        if (Test-Path $Path) { Write-Warn "Overwriting existing file: $Path" }

        $desk = 'HKCU:\Control Panel\Desktop'
        $dwm  = 'HKCU:\Software\Microsoft\Windows\DWM'
        $per  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'

        $wallpaper = Get-RegString $desk 'Wallpaper'
        if (-not $wallpaper -or -not (Test-Path $wallpaper)) {
            Write-Warn "No wallpaper path in the registry - writing the theme without one."
            $wallpaper = $null
        }
        # registry WallpaperStyle -> .theme PicturePosition:
        #   10 Fill=4, 6 Fit=3, 22 Span=5, 2 Stretch=2 ; TileWallpaper=1 -> Tile=1 ; else Center=0
        $style = Get-RegString $desk 'WallpaperStyle'
        $tile  = Get-RegString $desk 'TileWallpaper'
        if ($tile -eq '1') { $picturePos = 1 }
        else {
            switch ("$style") {
                '10' { $picturePos = 4 }
                '6'  { $picturePos = 3 }
                '22' { $picturePos = 5 }
                '2'  { $picturePos = 2 }
                default { $picturePos = 0 }
            }
        }

        $colorization = Get-RegDWord $dwm 'ColorizationColor'
        if ($null -eq $colorization) { $colorization = ConvertTo-ColorDWord $HK_PINK }
        $colorHex = '0X{0:X8}' -f $colorization
        $autoColor = Get-RegDWord $desk 'AutoColorization'
        if ($null -eq $autoColor) { $autoColor = 0 }

        $perProps = Get-ItemProperty $per -ErrorAction SilentlyContinue
        $sysLight  = if ($null -ne $perProps -and $null -ne $perProps.SystemUsesLightTheme) { [int]$perProps.SystemUsesLightTheme } else { 1 }
        $appsLight = if ($null -ne $perProps -and $null -ne $perProps.AppsUseLightTheme) { [int]$perProps.AppsUseLightTheme } else { 1 }
        $sysMode = if ($sysLight  -eq 1) { 'Light' } else { 'Dark' }
        $appMode = if ($appsLight -eq 1) { 'Light' } else { 'Dark' }

        $displayName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
        $writeTime = 0
        if ($wallpaper -and (Test-Path $wallpaper)) {
            $writeTime = [System.IO.File]::GetLastWriteTimeUtc($wallpaper).ToFileTimeUtc()
        }
        $guid = [guid]::NewGuid().ToString().ToUpper()

        $content = @(
            '; Saved theme - generated by hello-kitty.ps1 theme-save'
            ''
            '[Theme]'
            "DisplayName=$displayName"
            "; stable id so the theme survives re-import"
            "ThemeId={$guid}"
            ''
            '[Control Panel\Desktop]'
            "Wallpaper=$wallpaper"
            'Pattern='
            'MultimonBackgrounds=0'
            "PicturePosition=$picturePos"
            "WallpaperWriteTime=$writeTime"
            ''
            '[VisualStyles]'
            'Path=%SystemRoot%\resources\Themes\Aero\Aero.msstyles'
            'ColorStyle=NormalColor'
            'Size=NormalSize'
            "AutoColorization=$autoColor"
            "ColorizationColor=$colorHex"
            "SystemMode=$sysMode"
            "AppMode=$appMode"
            'VisualStyleVersion=10'
            ''
            '[boot]'
            'SCRNSAVE.EXE='
            ''
            '[MasterThemeSelector]'
            'MTSM=RJSPBS'
        )
        $dir = Split-Path $Path -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $content | Set-Content -Path $Path -Encoding Unicode
        Write-Ok "Saved current theme to: $Path"
        Write-Info "Wallpaper : $wallpaper"
        Write-Info "Accent    : $colorHex   ($sysMode / $appMode mode)"
        Write-Info "It is installed for Settings > Personalization > Themes - double-click it (or run theme-restore) to apply."
    } catch {
        Write-Warn "Could not save theme: $($_.Exception.Message)"
    }
}

<#
  If a theme woke up High Contrast mode and the user didn't have it on before,
  switch it back off (registry + SPI). Used after theme-switch / theme-restore.
#>
function Undo-HighContrastIfNeeded {
    param([bool]$WasOn, [string]$What)
    Start-Sleep -Milliseconds 1500
    $hcFl = Get-ItemProperty 'HKCU:\Control Panel\Accessibility\HighContrast' -ErrorAction SilentlyContinue
    $hcRegOn = ($null -ne $hcFl -and $hcFl.Flags -ne 126)   # 126 = baseline off; anything else = on
    if (-not $WasOn -and ([HelloKittyThemeApi.Native]::IsHighContrastOn() -or $hcRegOn)) {
        [HelloKittyThemeApi.Native]::ForceHighContrastOff() | Out-Null
        $hcK = 'HKCU:\Control Panel\Accessibility\HighContrast'
        if (Test-Path $hcK) {
            Set-ItemProperty -Path $hcK -Name 'Flags' -Value 126 -Type DWord -Force
            Set-ItemProperty -Path $hcK -Name 'High Contrast Scheme' -Value '' -Force
            Remove-ItemProperty -Path $hcK -Name 'Previous High Contrast Scheme MUI Value' -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $hcK -Name 'Previous High Contrast Scheme MUI Ptr' -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $hcK -Name 'LastUpdatedThemeId' -ErrorAction SilentlyContinue
        }
        Write-Warn "$What turned ON High Contrast mode - it was switched back OFF automatically."
    }
}

function Restore-ThemeFile {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) {
        Write-Warn "Usage: hello-kitty.ps1 theme-restore <path-to-.theme-file>"
        return
    }
    try {
        $full = (Resolve-Path $Path).Path
        $disp = $null
        try {
            $raw = Get-Content $full -Raw
            if ($raw -match '(?m)^DisplayName\s*=\s*(.+?)\s*$') { $disp = $Matches[1].Trim() }
        } catch { }
        Write-Info "Applying theme: $(if ($disp) { $disp } else { $full })"
        Write-Info "(native apply via the Windows shell - identical to double-clicking the .theme file)"
        Ensure-ThemeApi
        $hcWasOn = [HelloKittyThemeApi.Native]::IsHighContrastOn()
        Start-Process $full | Out-Null
        Undo-HighContrastIfNeeded $hcWasOn "The applied theme"
        $cur = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes' -ErrorAction SilentlyContinue).CurrentTheme
        if ($cur -eq $full) {
            Write-Ok "Theme applied: $full (now the active theme)"
        } else {
            Write-Ok "Theme handed to Windows to apply: $full"
            Write-Info "Current theme registry value: $cur"
        }
        Write-Warn "Note: .theme files cannot carry the Start-menu palette / transparency / taskbar acrylic."
        Write-Warn "For a full pixel-perfect restore of a saved profile, use 'restore' instead of theme-restore."
    } catch {
        Write-Warn "Could not apply theme: $($_.Exception.Message)"
    }
}

function Switch-NativeTheme {
    param([string]$IndexArg)
    if (-not $IndexArg -or $IndexArg -notmatch '^\d+$') {
        Write-Warn "Usage: hello-kitty.ps1 theme-switch <index>   (list them with 'themes')"
        return
    }
    try {
        Ensure-ThemeApi
        $idx = [int]$IndexArg
        # Safety: remember whether the user had High Contrast on BEFORE switching.
        # (Ease-of-Access themes switch it on - we must not silently keep that.)
        $hcWasOn = [HelloKittyThemeApi.Native]::IsHighContrastOn()
        $hr = [HelloKittyThemeApi.Native]::SwitchTheme($idx, $true)
        if ($hr -eq 0) {
            Write-Ok "Switched to theme index $idx (native apply)."
        } else {
            Write-Warn "Switch failed with HRESULT 0x$('{0:X8}' -f $hr) - index out of range?"
            return
        }
        # Auto-undo High Contrast if the applied theme turned it on.
        Undo-HighContrastIfNeeded $hcWasOn "Theme $idx"
        $curTheme = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes' -ErrorAction SilentlyContinue).CurrentTheme
        if ($curTheme -and $curTheme -like '*\Ease of Access Themes\*') {
            Write-Warn "Note: the applied theme is an Ease-of-Access (High Contrast) theme."
        }
    } catch {
        Write-Warn "Could not switch theme: $($_.Exception.Message)"
    }
}

# ----------------------------------------------------------------------------
# Individual setters
# ----------------------------------------------------------------------------
function Set-Wallpaper {
    param([string]$Path)
    Ensure-WinApi
    [HelloKittyWinAPI]::SystemParametersInfo(20, 0, $Path, 3) | Out-Null
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name Wallpaper -Value $Path -Force
}

function Set-WallpaperStyle([string]$Style) {
    # "10" = Fill, "6" = Fit, "2" = Stretch ; TileWallpaper "0" = off
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value $Style -Force
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name TileWallpaper  -Value '0' -Force
}

function Set-AccentColor {
    param([string]$Hex, [int]$PaletteAlpha = $HK_PALETTE_ALPHA)
    $dwmPath = 'HKCU:\Software\Microsoft\Windows\DWM'
    if (-not (Test-Path $dwmPath)) { New-Item -Force -Path $dwmPath | Out-Null }
    # Taskbar / title-bar colour (ColorPrevalence=1) is driven by ColorizationColor (AARRGGBB)
    Set-ItemProperty -Path $dwmPath -Name ColorizationColor -Value ([uint32](ConvertTo-ColorDWord $Hex)) -Type DWord -Force
    # The Start menu / taskbar also read AccentColorMenu, StartColorMenu (AABBGGRR)
    # and the 32-byte AccentPalette (BGRA). All three must be written or the
    # Start menu keeps the default blue palette.
    $accPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent'
    if (-not (Test-Path $accPath)) { New-Item -Force -Path $accPath | Out-Null }
    Set-ItemProperty -Path $accPath -Name AccentColorMenu -Value ([uint32](ConvertTo-ColorDWord $Hex -AABBGGRR)) -Type DWord -Force
    Set-ItemProperty -Path $accPath -Name StartColorMenu  -Value ([uint32](ConvertTo-ColorDWord $Hex -AABBGGRR)) -Type DWord -Force
    Set-ItemProperty -Path $accPath -Name AccentPalette   -Value ([byte[]](New-HKAccentPalette $PaletteAlpha)) -Type Binary -Force
}

function Set-Personalize {
    param([int]$AppsLight, [int]$SystemLight, [int]$ColorPrevalence)
    $p = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    if (-not (Test-Path $p)) { New-Item -Force -Path $p | Out-Null }
    Set-ItemProperty -Path $p -Name AppsUseLightTheme    -Value $AppsLight      -Type DWord -Force
    Set-ItemProperty -Path $p -Name SystemUsesLightTheme -Value $SystemLight    -Type DWord -Force
    # Win10: "Show color on Start, taskbar, and action center"
    # Win11: "Show accent color on Start and taskbar"
    Set-ItemProperty -Path $p -Name ColorPrevalence      -Value $ColorPrevalence -Type DWord -Force
}

function Set-TransparencyEffects([int]$Value) {
    # 1 = frosted/translucent Start menu, taskbar, action center (Win10 & Win11)
    $p = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    if (-not (Test-Path $p)) { New-Item -Force -Path $p | Out-Null }
    Set-ItemProperty -Path $p -Name EnableTransparency -Value $Value -Type DWord -Force
}

function Set-TitleBarAccent([int]$Value) {
    # Win10: "Show color on title bars"; Win11: "Show accent color on title bars and window borders"
    $dwm = 'HKCU:\Software\Microsoft\Windows\DWM'
    if (-not (Test-Path $dwm)) { New-Item -Force -Path $dwm | Out-Null }
    Set-ItemProperty -Path $dwm -Name ColorPrevalence -Value $Value -Type DWord -Force
}

function Set-AutoColorization([int]$Value) {
    $desk = 'HKCU:\Control Panel\Desktop'
    if (-not (Test-Path $desk)) { New-Item -Force -Path $desk | Out-Null }
    Set-ItemProperty -Path $desk -Name AutoColorization -Value $Value -Type DWord -Force
}

function Set-TaskbarAcrylic([int]$Value) {
    # Windows 10 taskbar acrylic: 0 = fully transparent (no blur) ..
    # 80 = frosted blur, still translucent .. 255 = max blur / almost solid.
    # Windows 11 only: no-op (taskbar re-written; frosted via EnableTransparency).
    $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    if (-not (Test-Path $adv)) { New-Item -Force -Path $adv | Out-Null }
    Set-ItemProperty -Path $adv -Name TaskbarAcrylicOpacity -Value $Value -Type DWord -Force
}

<#
  Write "Hello Kitty.theme" - a real, installable Windows theme file, in the
  same modern format Windows itself writes (see Custom.theme / aero.theme).
  Places it in the user themes folder so it shows up in:
    * Settings > Personalization > Themes
    * our native listing ("themes" command)
  and can be double-clicked (or ShellExecute'd) to apply natively, or shared
  like any other .theme file.
  Note: .theme files cannot carry AccentPalette / StartColorMenu /
  EnableTransparency / TaskbarAcrylicOpacity - those stay registry-only and are
  still applied by the script's registry layer.
#>
function Write-HKThemeFile {
    param(
        [string]$Name = 'Hello Kitty',
        [string]$Wallpaper = $WallpaperSrc,
        [string]$OutputDir = $UserThemesDir
    )
    try {
        if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }
        if (-not $Wallpaper -or -not (Test-Path $Wallpaper)) {
            Write-Warn "Wallpaper missing for .theme file - skipping theme file."
            return $null
        }
        $output = Join-Path $OutputDir "$Name.theme"
        # AARRGGBB, same style Windows writes (ColorizationColor=0XC4FF2E6D)
        $colorHex = '0X{0:X8}' -f (ConvertTo-ColorDWord $HK_PINK)
        $writeTime = [System.IO.File]::GetLastWriteTimeUtc($Wallpaper).ToFileTimeUtc()
        $hkSystemMode = 'Light'
        $content = @(
            '; Hello Kitty theme - generated by hello-kitty.ps1'
            ''
            '[Theme]'
            "DisplayName=$Name"
            '; stable id so the theme survives re-generation'
            'ThemeId={FF2E6D00-4B1C-4E0A-9C5A-00FF2E6D00A1}'
            ''
            '[Control Panel\Desktop]'
            "Wallpaper=$Wallpaper"
            'Pattern='
            'MultimonBackgrounds=0'
            'PicturePosition=4'
            "WallpaperWriteTime=$writeTime"
            ''
            '[VisualStyles]'
            'Path=%SystemRoot%\resources\Themes\Aero\Aero.msstyles'
            'ColorStyle=NormalColor'
            'Size=NormalSize'
            'AutoColorization=0'
            "ColorizationColor=$colorHex"
            "SystemMode=$hkSystemMode"
            'AppMode=Light'
            'VisualStyleVersion=10'
            ''
            '[boot]'
            'SCRNSAVE.EXE='
            ''
            '[MasterThemeSelector]'
            'MTSM=RJSPBS'
        )
        # Windows themes are UTF-16 LE
        $content | Set-Content -Path $output -Encoding Unicode
        Write-Ok "Written Windows theme file: $output"
        return $output
    } catch {
        Write-Warn "Could not write theme file: $_"
        return $null
    }
}

# ----------------------------------------------------------------------------
# Shell refresh - layered and SAFE. The old code force-killed explorer and then
# trusted Winlogon to bring it back; when the shell crashed after restart (a
# recurring explorer.exe 0xc0000005 bug on some machines) Winlogon can refuse /
# throttle the restart, leaving the desktop dead while the script prints "Done".
# New rules:
#   1. Try a live, NON-destructive refresh first (the shell and DWM pick up most
#      accent / palette / transparency changes without a restart).
#   2. Restart ONLY the Start-menu host process (it respawns by itself) to
#      repaint the Start palette.
#   3. If a real explorer restart is still needed, do it with a GUARANTEE:
#      verify stability (not mere presence), retry, and never return with the
#      shell dead.
#   4. A short background watchdog heals the desktop even if explorer crashes
#      in the minutes after we finish (the "done but dead" failure window).
# ----------------------------------------------------------------------------

<#
  Broadcast "per-user system parameters changed" so DWM and the shell re-read the
  Personalize / DWM / Accent keys live. This is the refresh Windows Settings
  performs for most colour / accent / transparency toggles and does NOT kill
  explorer.
#>
function Update-PerUserSettings {
    try {
        Step "Update-PerUserSettings: broadcasting live settings refresh"
        $r = Start-Process (Join-Path $env:SystemRoot 'System32\rundll32.exe') `
                -ArgumentList 'user32.dll,UpdatePerUserSystemParameters' `
                -WindowStyle Hidden -PassThru
        try { $r.WaitForExit(5000) | Out-Null } catch { }
    } catch {
        Step "Update-PerUserSettings skipped: $($_.Exception.Message)"
    }
}

<#
  The Start menu caches its accent palette inside StartMenuExperienceHost.exe.
  Restarting just that host (it respawns automatically on demand) repaints the
  Start menu with the new palette while explorer.exe stays up - a far narrower
  blast radius than a full shell restart.
#>
function Restart-StartMenuHost {
    try {
        $hosts = Get-Process StartMenuExperienceHost -ErrorAction SilentlyContinue
        if ($hosts) {
            Write-Info "Repainting Start menu (restarting its host process - explorer stays up)..."
            $hosts | Stop-Process -Force -ErrorAction SilentlyContinue
            Step "Restart-StartMenuHost: restarted Start menu host PID $($hosts.Id -join ',')"
        }
    } catch {
        Step "Restart-StartMenuHost skipped: $($_.Exception.Message)"
    }
}

function Test-ExplorerRunning {
    return [bool](Get-Process explorer -ErrorAction SilentlyContinue)
}

<#
  Wait for explorer to be present AND STAY alive for the stability window.
  Mere presence is not enough - the old code declared "ok" the moment an
  instance appeared, then the shell died minutes later.
#>
function Wait-ExplorerStable {
    param([int]$TimeoutSeconds = 15, [int]$StableSeconds = 3)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if (Test-ExplorerRunning) {
            Start-Sleep -Seconds $StableSeconds
            return (Test-ExplorerRunning)
        }
    }
    return $false
}

<#
  Bulletproof explorer restart. Returns $true only when explorer is running and
  stable afterwards; never returns having left the shell dead if the OS will
  still start it. Handles:
    * Winlogon not restarting the shell (throttled / refused after crashes)
    * explorer crashing again during the restart window (crash-loop)
    * double-instance races (we only start explorer when no instance exists)
#>
function Restart-ExplorerSafe {
    $TimeoutSeconds = 20
    $MaxAttempts     = 3
    $StableSeconds   = 3

    # Serialize restarts: stop any watchdog left over from a previous run so we
    # (and Windows) are the only ones who can spawn the shell right now.
    Stop-ExplorerWatchdog

    Write-Info "Restarting explorer so the new colours take effect..."
    $existing = Get-Process explorer -ErrorAction SilentlyContinue
    if ($existing) {
        Step "Restart-ExplorerSafe: stopping explorer PID $($existing.Id -join ',')"
        $existing | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Step "Restart-ExplorerSafe: attempt $attempt - waiting for a stable explorer"
        # Let Winlogon try first: it owns the correct session / user context.
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $deadline -and -not (Test-ExplorerRunning)) {
            Start-Sleep -Milliseconds 500
        }
        # Stability check - the guarantee the old code never made.
        if (Wait-ExplorerStable 3 $StableSeconds) {
            Step "Restart-ExplorerSafe: explorer stable after attempt $attempt"
            Write-Ok "Explorer restarted and stable."
            return $true
        }
        # Winlogon did not (or could not) bring it back - start it directly in
        # the interactive session. Safe here: no instance exists right now.
        if ($attempt -lt $MaxAttempts) {
            Write-Warn "Explorer is not coming back by itself - starting it directly (attempt $attempt/$MaxAttempts)."
        } else {
            Write-Warn "Explorer is not coming back - final start attempt."
        }
        try {
            Start-Process explorer.exe | Out-Null
        } catch {
            Step "Restart-ExplorerSafe: start failed: $($_.Exception.Message)"
        }
    }

    if (Test-ExplorerRunning) {
        Step "Restart-ExplorerSafe: explorer is running after manual start"
        Write-Ok "Explorer started."
        return $true
    }
    Write-Warn "Could not start Explorer. Start it manually with: Start-Process explorer.exe  (or log off/on)"
    Step "Restart-ExplorerSafe: FAILED - explorer not running"
    return $false
}

$WatchdogScript = Join-Path $StateDir 'explorer-watchdog.ps1'

<#
  Detached, one-shot background safety net. If explorer dies in the minutes
  after we finish (e.g. a shell crash bug or Winlogon throttle), starting it
  again. Does nothing while explorer is up; exits after $Seconds.
#>
function Start-ExplorerWatchdog {
    param([int]$Seconds = 180)
    try {
        Remove-Item $WatchdogScript -Force -ErrorAction SilentlyContinue
        $content = @'
param([int]$Seconds)
$deadline = (Get-Date).AddSeconds($Seconds)
$missing = 0
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 10
    if (Get-Process explorer -ErrorAction SilentlyContinue) { $missing = 0 }
    else { $missing++ }
    if ($missing -ge 2) {
        $missing = 0
        try { Start-Process explorer.exe -ErrorAction Stop | Out-Null } catch { }
    }
}
'@
        Set-Content -Path $WatchdogScript -Value $content -Encoding ASCII
        Start-Process powershell.exe -ArgumentList @(
            '-NoProfile', '-WindowStyle', 'Hidden',
            '-File', "`"$WatchdogScript`"", $Seconds
        ) -WindowStyle Hidden | Out-Null
        Step "Start-ExplorerWatchdog: watching for $Seconds seconds"
    } catch {
        Step "Start-ExplorerWatchdog skipped: $($_.Exception.Message)"
    }
}

<#
  Kill any watchdog still watching from a previous run. Back-to-back apply/restore
  must NEVER have two watchdogs alive: they could each start explorer and race
  Windows' own restart into a two-instance shell. One watchdog, always the newest.
#>
function Stop-ExplorerWatchdog {
    try {
        Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like '*explorer-watchdog.ps1*' } |
            ForEach-Object {
                Step "Stop-ExplorerWatchdog: stopping old watchdog PID $($_.ProcessId)"
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            }
    } catch {
        Step "Stop-ExplorerWatchdog skipped: $($_.Exception.Message)"
    }
}

function Refresh-Shell {
    # Apply the theme LIVE and never touch explorer. Measured on this machine
    # (Win10 21H2): the theme values do NOT crash explorer - pid stayed stable
    # for 5 minutes. It is the kill + restart cycle that triggers a recurring
    # explorer.exe access violation (fault offset 0x458aa), leaving the desktop
    # dead. So apply/restore NO LONGER restart the shell:
    #   Layer 1: broadcast "per-user system parameters changed" - DWM and the
    #            shell re-read accent / palette / transparency / wallpaper live.
    #   Layer 2: repaint the Start menu palette via its host process only.
    #   Layer 3: short background watchdog as insurance against unrelated crashes.
    # Users who specifically want the shell restarted can run 'restart-shell'.
    Update-PerUserSettings
    Restart-StartMenuHost
    Start-ExplorerWatchdog 90
}

# ----------------------------------------------------------------------------
# Windows Terminal theming
# ----------------------------------------------------------------------------
function Get-WTSettingsPath {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json')
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json')
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
    )
    foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
    return $null
}

<#
  ConvertFrom-Json that also understands JSONC (// and /* */ comments), which is
  what Windows Terminal's settings.json ships with by default. A standard
  ConvertFrom-Json would throw on the comments and kill the whole apply flow.
#>
function ConvertFrom-JsonC {
    param([string]$JsonText)
    $sb = New-Object System.Text.StringBuilder
    $len = $JsonText.Length
    $i = 0
    $inString = $false
    $q = [char]0
    $escape = $false
    while ($i -lt $len) {
        $c = $JsonText[$i]
        if ($inString) {
            $sb.Append($c) | Out-Null
            if ($escape) { $escape = $false }
            elseif ($c -eq '\') { $escape = $true }
            elseif ($c -eq $q) { $inString = $false }
            $i++
        } else {
            if ($c -eq '"' -or $c -eq "'") {
                $inString = $true; $q = $c
                $sb.Append($c) | Out-Null; $i++
            }
            elseif ($c -eq '/' -and ($i + 1) -lt $len -and $JsonText[$i + 1] -eq '/') {
                while ($i -lt $len -and $JsonText[$i] -ne "`n") { $i++ }
                $sb.Append("`n") | Out-Null; $i++
            }
            elseif ($c -eq '/' -and ($i + 1) -lt $len -and $JsonText[$i + 1] -eq '*') {
                $i += 2
                while ($i -lt $len -and -not ($JsonText[$i] -eq '*' -and ($i + 1) -lt $len -and $JsonText[$i + 1] -eq '/')) { $i++ }
                if ($i -lt $len) { $i += 2 }
            }
            else {
                $sb.Append($c) | Out-Null; $i++
            }
        }
    }
    return ($sb.ToString() | ConvertFrom-Json)
}

function Get-HKScheme {
    # Mirrors the termite palette from others/termite (translucent dark-pink bg via acrylic).
    # Mapped to the standard terminal colour slots: color0..15 -> black..brightWhite.
    # NOTE: transparency (useAcrylic/opacity) is a PROFILE setting, not a scheme
    # setting - it is applied in Set-ProfileScheme below.
    return [ordered]@{
        name                = 'Hello Kitty'
        foreground          = '#FFFFFF'
        background          = '#3C1432'
        cursorColor         = '#DDDDDD'
        selectionBackground = $HK_DMENU_SELBG
        black               = '#322B24'   # color0
        red                 = '#00F27A'   # color1
        green               = '#379BFF'   # color2
        yellow              = '#C553FF'   # color3
        blue                = '#FFE500'   # color4
        purple              = '#00EEEE'   # color5
        cyan                = '#FF4D82'   # color6
        white               = '#A6717C'   # color7
        brightBlack         = '#665544'   # color8
        brightRed           = '#63FEB1'   # color9
        brightGreen         = '#6FB7FF'   # color10
        brightYellow        = '#D581FF'   # color11
        brightBlue          = '#FFEF5E'   # color12
        brightPurple        = '#70FFFF'   # color13
        brightCyan          = '#FF6E9A'   # color14
        brightWhite         = '#FFEBEF'   # color15
    }
}

function Apply-TerminalTheme {
    $wt = Get-WTSettingsPath
    if (-not $wt) {
        Write-Warn "Windows Terminal not found - skipping terminal theme (install it from the Store to use the Hello Kitty scheme)."
        return
    }
    try {
        $raw  = Get-Content $wt -Raw -Encoding UTF8
        $json = ConvertFrom-JsonC $raw
    } catch {
        Write-Warn "Could not parse Windows Terminal settings ($_). Skipping terminal theme."
        return
    }

    $scheme = Get-HKScheme
    if (-not $json.PSObject.Properties['schemes']) { $json | Add-Member -MemberType NoteProperty -Name schemes -Value @() }
    # remove any pre-existing Hello Kitty scheme to avoid duplicates
    $json.schemes = @($json.schemes | Where-Object { $_.name -ne 'Hello Kitty' })
    $json.schemes += [pscustomobject]$scheme

    # point EVERY profile at the new scheme + acrylic transparency
    $profiles = $json.profiles
    if ($null -eq $profiles) {
        # settings.json without a "profiles" section at all
        $json | Add-Member -MemberType NoteProperty -Name profiles -Value ([pscustomobject]([ordered]@{
            defaults = [pscustomobject]([ordered]@{})
            list     = @()
        })) -Force
        $profiles = $json.profiles
    }

    # useAcrylic + opacity (0-100) is the current API (1.12+). acrylicOpacity is
    # deprecated. The acrylic blur also needs Windows "Transparency effects" on,
    # which the theme enables via EnableTransparency.
    function Set-ProfileScheme($p) {
        $p | Add-Member -MemberType NoteProperty -Name colorScheme -Value 'Hello Kitty' -Force
        $p | Add-Member -MemberType NoteProperty -Name useAcrylic -Value $true -Force
        $p | Add-Member -MemberType NoteProperty -Name opacity -Value 65 -Force
    }

    if ($profiles -is [System.Array]) {
        # legacy format: profiles is a flat array
        foreach ($p in $profiles) { Set-ProfileScheme $p }
    } else {
        # modern format: profiles.{list,defaults}
        if ($profiles.PSObject.Properties['defaults']) { Set-ProfileScheme $profiles.defaults }
        else {
            $profiles | Add-Member -MemberType NoteProperty -Name defaults -Value ([pscustomobject]([ordered]@{})) -Force
            Set-ProfileScheme $profiles.defaults
        }
        if ($profiles.PSObject.Properties['list']) {
            foreach ($p in $profiles.list) { Set-ProfileScheme $p }
        }
    }

    $json | ConvertTo-Json -Depth 100 | Set-Content $wt -Encoding UTF8
    Write-Ok "Windows Terminal: applied 'Hello Kitty' scheme to all profiles (acrylic 65%)."
}

function Restore-TerminalBackup($SettingsPath, $BackupPath) {
    if (-not $SettingsPath -or -not $BackupPath) { return }
    if (-not (Test-Path $BackupPath)) { Write-Warn "Terminal backup missing - leaving current settings as-is."; return }
    Copy-Item $BackupPath $SettingsPath -Force
    Write-Ok "Windows Terminal: restored your previous settings."
}

# ----------------------------------------------------------------------------
# Save / Apply / Restore
# ----------------------------------------------------------------------------
function Get-RegDWord($Path, $Name) {
    $v = Get-ItemProperty $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -ne $v) { return [uint32]$v.$Name } else { return $null }
}
function Get-RegString($Path, $Name) {
    $v = Get-ItemProperty $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -ne $v) { return $v.$Name } else { return $null }
}

function Save-CurrentTheme {
    if (Test-Path $SavedThemePath) { Step "Save-CurrentTheme: already saved, skip"; return }

    $desk = 'HKCU:\Control Panel\Desktop'
    $dwm  = 'HKCU:\Software\Microsoft\Windows\DWM'
    $acc  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent'
    $per  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    $adv  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'

    $wt = Get-WTSettingsPath
    if ($wt) { Copy-Item $wt $TerminalBackup -Force }

    $perProps  = Get-ItemProperty $per -ErrorAction SilentlyContinue
    $appsLight = $perProps.AppsUseLightTheme
    $sysLight  = $perProps.SystemUsesLightTheme
    $colorPrev = $perProps.ColorPrevalence
    $transp    = $perProps.EnableTransparency

    # Start menu accent lives in the 32-byte AccentPalette (BGRA) - save it verbatim.
    $palette = (Get-ItemProperty $acc -Name AccentPalette -ErrorAction SilentlyContinue).AccentPalette

    $saved = [ordered]@{
        wallpaper              = Get-RegString  $desk 'Wallpaper'
        wallpaperStyle        = Get-RegString  $desk 'WallpaperStyle'
        tileWallpaper         = Get-RegString  $desk 'TileWallpaper'
        autoColorization      = Get-RegDWord   $desk 'AutoColorization'
        colorizationColor     = Get-RegDWord   $dwm  'ColorizationColor'
        accentColorMenu       = Get-RegDWord   $acc  'AccentColorMenu'
        startColorMenu        = Get-RegDWord   $acc  'StartColorMenu'
        accentPaletteB64      = if ($palette) { [Convert]::ToBase64String([byte[]]$palette) } else { $null }
        appsUseLightTheme     = if ($null -ne $appsLight) { [int]$appsLight } else { 1 }
        systemUsesLightTheme  = if ($null -ne $sysLight)  { [int]$sysLight }  else { 1 }
        colorPrevalence       = if ($null -ne $colorPrev) { [int]$colorPrev } else { 0 }
        enableTransparency    = if ($null -ne $transp)    { [int]$transp }    else { $null }
        dwmColorPrevalence    = Get-RegDWord   $dwm  'ColorPrevalence'
        taskbarAcrylicOpacity = Get-RegDWord   $adv  'TaskbarAcrylicOpacity'
        hasTerminalBackup     = if ($wt) { $true } else { $false }
        terminalSettingsPath  = $wt
    }
    $saved | ConvertTo-Json -Depth 10 | Set-Content $SavedThemePath -Encoding UTF8
    Step "Save-CurrentTheme: wrote $SavedThemePath"
    Write-Ok "Saved your current theme to: $SavedThemePath"
}

function Apply-HelloKitty {
    Step "Apply-HelloKitty: start"
    Write-Pink "Applying Hello Kitty theme..."
    # 1. Wallpaper (Fill style)
    if (Test-Path $WallpaperSrc) {
        Set-WallpaperStyle '10'
        Set-Wallpaper $WallpaperSrc
        Step "Apply-HelloKitty: wallpaper set"
        Write-Ok "Wallpaper set to Hello Kitty background (Fill)."
    } else {
        Write-Warn "background.png missing - skipping wallpaper."
    }
    # 2. Accent (hot pink) everywhere: taskbar, Start menu (incl. its AccentPalette),
    #    title bars + light mode + frosted/translucent surfaces
    Set-AccentColor $HK_PINK
    Step "Apply-HelloKitty: accent set"
    Write-Ok "Accent color set to $HK_PINK (taskbar + Start menu + palette)."
    Set-AutoColorization 0
    Step "Apply-HelloKitty: auto-colorization off"
    Write-Ok "Disabled 'auto accent from background' so the pink sticks."
    Set-Personalize -AppsLight 1 -SystemLight 1 -ColorPrevalence 0
    Step "Apply-HelloKitty: personalize set"
    Write-Ok "Light mode + accent on Start/taskbar disabled (ColorPrevalence=0)."
    Set-TitleBarAccent 1
    Write-Ok "Accent on title bars / window borders enabled."
    Set-TransparencyEffects 1
    Step "Apply-HelloKitty: transparency set"
    Write-Ok "Transparency effects ON - Start menu is frosted, not opaque."
    Set-TaskbarAcrylic $HK_TASKBAR_ACRYLIC
    Step "Apply-HelloKitty: taskbar acrylic set"
    Write-Ok "Taskbar set to frosted acrylic ($HK_TASKBAR_ACRYLIC/255 blur)."
    # 3. Windows Terminal (colors + acrylic)
    Apply-TerminalTheme
    # 4. Windows-visible theme file (Settings > Themes / native listing)
    $hkTheme = Write-HKThemeFile
    if ($hkTheme) {
        Write-Info "  (apply it natively anytime with: hello-kitty.ps1 theme-file)`n" 
    }
    # 5. Refresh shell
    Refresh-Shell
    Step "Apply-HelloKitty: shell refreshed"
    Set-Content -Path $StatePath -Value ([ordered]@{ mode = 'hellokitty' } | ConvertTo-Json)
    Write-Pink "Done! Your desktop is now Hello Kitty themed. (run 'restore' or 'toggle' to go back)"
}

function Set-RegValue($Path, $Name, $Value, [switch]$DWord) {
    if (-not (Test-Path $Path)) { New-Item -Force -Path $Path | Out-Null }
    if ($null -ne $Value) {
        if ($DWord) { Set-ItemProperty -Path $Path -Name $Name -Value ([uint32]$Value) -Type DWord -Force }
        else        { Set-ItemProperty -Path $Path -Name $Name -Value $Value -Force }
    } else {
        Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    }
}

function Restore-Saved {
    if (-not (Test-Path $SavedThemePath)) {
        Write-Warn "No saved theme found. Run 'apply' first so we can remember your settings."
        return
    }
    Step "Restore-Saved: start"
    Write-Pink "Restoring your saved theme..."
    $s = Get-Content $SavedThemePath -Raw -Encoding UTF8 | ConvertFrom-Json

    $desk = 'HKCU:\Control Panel\Desktop'
    $dwm  = 'HKCU:\Software\Microsoft\Windows\DWM'
    $acc  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent'
    $per  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    $adv  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'

    if ($s.wallpaper) { Set-WallpaperStyle '10'; Set-Wallpaper $s.wallpaper; Write-Ok "Wallpaper restored." }
    Set-RegValue $desk 'WallpaperStyle'   $s.wallpaperStyle   # string
    Set-RegValue $desk 'TileWallpaper'    $s.tileWallpaper    # string
    Set-RegValue $desk 'AutoColorization' $s.autoColorization -DWord
    Set-RegValue $dwm  'ColorizationColor' $s.colorizationColor -DWord
    Set-RegValue $acc  'AccentColorMenu'   $s.accentColorMenu   -DWord
    Set-RegValue $acc  'StartColorMenu'    $s.startColorMenu    -DWord
    if ($s.accentPaletteB64) {
        Set-ItemProperty -Path $acc -Name AccentPalette -Value ([byte[]][Convert]::FromBase64String($s.accentPaletteB64)) -Type Binary -Force
    }
    Write-Ok "Accent color restored (incl. Start menu palette)."
    Set-Personalize -AppsLight ([int]$s.appsUseLightTheme) -SystemLight ([int]$s.systemUsesLightTheme) -ColorPrevalence ([int]$s.colorPrevalence)
    if ($null -ne $s.enableTransparency) { Set-TransparencyEffects ([int]$s.enableTransparency) }
    if ($null -ne $s.dwmColorPrevalence) { Set-TitleBarAccent ([int]$s.dwmColorPrevalence) }
    Write-Ok "Light/dark mode + transparency restored."
    Set-RegValue $adv 'TaskbarAcrylicOpacity' $s.taskbarAcrylicOpacity -DWord
    Write-Ok "Taskbar acrylic restored."
    Restore-TerminalBackup $s.terminalSettingsPath $TerminalBackup
    Refresh-Shell
    Step "Restore-Saved: shell refreshed"
    Set-Content -Path $StatePath -Value ([ordered]@{ mode = 'saved' } | ConvertTo-Json)
    Write-Pink "Done! Your original theme is back."
}

function Ensure-Assets {
    $wanted = @{
        $WallpaperSrc   = "$RepoRaw/background.png"
    }
    foreach ($local in $wanted.Keys) {
        if (-not (Test-Path $local)) {
            try {
                Write-Info "Downloading $(Split-Path $local -Leaf) ..."
                Invoke-WebRequest -Uri $wanted[$local] -OutFile $local -UseBasicParsing -ErrorAction Stop
            } catch {
                Write-Warn "Could not download $(Split-Path $local -Leaf): $_"
            }
        }
    }
}

function Show-Status {
    $mode = if (Test-Path $StatePath) { (Get-Content $StatePath -Raw | ConvertFrom-Json).mode } else { 'unknown' }
    Write-Pink "Hello Kitty theme switcher"
    Write-Info "Current mode : $mode"
    Write-Info "Saved theme  : $(if (Test-Path $SavedThemePath) { 'yes' } else { 'none (will be saved on first apply)' })"
    $wt = Get-WTSettingsPath
    Write-Info "Terminal     : $(if ($wt) { 'found' } else { 'not installed' })"
    $per = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue
    if ($per) {
        Write-Info "Light apps   : $($per.AppsUseLightTheme)   Light system: $($per.SystemUsesLightTheme)   AccentOnBar: $($per.ColorPrevalence)   Transparency: $($per.EnableTransparency)"
    } else {
        Write-Info "Personalize  : (registry key missing - nothing applied yet)"
    }
    $accent = Get-RegDWord 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' 'AccentColorMenu'
    if ($null -ne $accent) { Write-Info "Accent menu  : 0x$('{0:X8}' -f $accent) (expect 0xFF6D2EFF for Hello Kitty pink)" }
}

# ----------------------------------------------------------------------------
# Main dispatch
# ----------------------------------------------------------------------------
try {
    switch ($Command) {
        'install' {
            Ensure-Assets
            Write-Pink "Assets ready."
        }
        'apply'  { Ensure-Assets; Save-CurrentTheme; Apply-HelloKitty }
        'on'     { Ensure-Assets; Save-CurrentTheme; Apply-HelloKitty }
        'restore'{ Restore-Saved }
        'off'    { Restore-Saved }
        'status' { Show-Status }
        'themes' { Show-NativeThemes }
        'theme-save' { Save-ThemeFile $ThemeArg }
        'savetheme'  { Save-ThemeFile $ThemeArg }
        'theme-restore' { Restore-ThemeFile $ThemeArg }
        'theme-switch'  { Switch-NativeTheme $ThemeArg }
        'restart-shell' {
            # Explicitly opted-in full shell restart with the guaranteed recovery
            # path. apply/restore do NOT restart explorer anymore (see Refresh-Shell).
            Restart-ExplorerSafe
            Start-ExplorerWatchdog 180
        }
        'theme-file' {
            # (Re)generate the installable Hello Kitty.theme and optionally apply
            # it through Windows' own shell handling (same as double-clicking).
            $hkTheme = Write-HKThemeFile
            if ($hkTheme) {
                Write-Info "This theme file is now installed in Settings > Personalization > Themes"
                Write-Info "and listed by the 'themes' command."
                if ($ThemeArg -eq 'apply') {
                    Write-Info "Applying it via the shell (same as double-clicking a .theme)..."
                    Start-Process $hkTheme | Out-Null
                    Write-Ok "Applied: $hkTheme (accent palette etc. are normalized by the next 'apply' run)"
                } else {
                    Write-Info "To apply it natively, double-click it or run: hello-kitty.ps1 theme-file apply"
                }
            }
        }
        'taskbar-acrylic' {
            # Live-tune the taskbar frosting (Windows 10).
            if ($ThemeArg -notmatch '^\d+$' -or [int]$ThemeArg -gt 255) {
                Write-Warn "Usage: hello-kitty.ps1 taskbar-acrylic <0-255>  (0 = fully transparent .. 255 = max blur)"
                return
            }
            Set-TaskbarAcrylic ([int]$ThemeArg)
            Write-Ok "Taskbar acrylic set to $ThemeArg (0 = transparent .. 255 = max blur)."
            Refresh-Shell
        }
        'start-acrylic' {
            # Live-tune Start menu / action centre transparency (accent palette alpha).
            if ($ThemeArg -notmatch '^\d+$' -or [int]$ThemeArg -gt 255) {
                Write-Warn "Usage: hello-kitty.ps1 start-acrylic <0-255>  (0 = fully transparent .. 255 = solid pink)"
                return
            }
            Set-AccentColor $HK_PINK -PaletteAlpha ([int]$ThemeArg)
            Write-Ok "Start menu / accent palette opacity set to $ThemeArg (0 = transparent .. 255 = solid)."
            Refresh-Shell
        }
        'toggle' {
            Ensure-Assets
            $mode = if (Test-Path $StatePath) { (Get-Content $StatePath -Raw | ConvertFrom-Json).mode } else { 'saved' }
            if ($mode -eq 'hellokitty') { Restore-Saved } else { Save-CurrentTheme; Apply-HelloKitty }
        }
    }
} catch {
    Write-Host ""
    Write-Host "Something went wrong:" -ForegroundColor Red
    Write-Host "  $_" -ForegroundColor Red
    Write-Host "  (full trace in: $LogFile)" -ForegroundColor Gray
    exit 1
}

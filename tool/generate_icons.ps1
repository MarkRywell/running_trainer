<#
.SYNOPSIS
    Generates every launcher/app icon from a single source PNG.

.DESCRIPTION
    The source is an opaque square with its background baked in. Simply
    resizing it leaves three problems:

      1. It is not centred - the artwork sits off-centre in the canvas.
      2. Android 8+ uses ADAPTIVE icons. The launcher crops the icon to a
         shape, so the artwork has to live inside the central 66.7% safe zone
         or it gets cut. A raw square loses the runner's arms and the bar chart.
      3. Web "maskable" icons have the same problem at an 80% safe zone.

    So the background is flood-filled away (recovering a transparent
    foreground), the artwork is measured, and it is re-composited centred at
    the correct scale onto a solid base colour. The base is the app's own
    #0E0D0D rather than the source's near-black, so the icon matches the UI
    instead of introducing a second "black".

    Every target below is a real, current requirement - none of it is cosmetic:

      Android  mipmap-anydpi-v26/ic_launcher.xml + foreground + background
      Android  mipmap-*/ic_launcher.png      (pre-8.0 legacy, still shipped)
      iOS      Runner/Assets.xcassets/AppIcon.appiconset (all sizes, 1024 for
               the store; Apple REJECTS an alpha channel, so these are opaque)
      Web      favicon, Icon-192/512, Icon-maskable-192/512

.PARAMETER Source
    The master artwork. Edit this and re-run; never hand-edit a generated icon.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tool\generate_icons.ps1
#>
param(
    [string]$Source = 'assets\logo\mobile-logo.png',
    [string]$BaseHex = '#0E0D0D',
    [int]$Tolerance = 30
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Set-Location (Split-Path -Parent $PSScriptRoot)

function Convert-HexToColor([string]$hex) {
    $h = $hex.TrimStart('#')
    [System.Drawing.Color]::FromArgb(
        255,
        [Convert]::ToInt32($h.Substring(0, 2), 16),
        [Convert]::ToInt32($h.Substring(2, 2), 16),
        [Convert]::ToInt32($h.Substring(4, 2), 16)
    )
}

# --- 1. Read the source into a raw BGRA buffer ------------------------------

$srcPath = (Resolve-Path $Source).Path
$src = [System.Drawing.Bitmap]::new($srcPath)
$W = $src.Width; $H = $src.Height
Write-Host "Source: $W x $H  $($src.PixelFormat)"

$rect = [System.Drawing.Rectangle]::new(0, 0, $W, $H)
$data = $src.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
    [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$stride = $data.Stride
$buf = New-Object byte[] ($stride * $H)
[System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $buf, 0, $buf.Length)
$src.UnlockBits($data)
$src.Dispose()

# `src` is 24bpp so LockBits asked for 32bpp; the driver zero-fills the pad byte
# on little-endian, which makes alpha read as 0 for every pixel. Force it to
# opaque, otherwise nothing is ever treated as background.
for ($i = 3; $i -lt $buf.Length; $i += 4) { $buf[$i] = 255 }

# --- 2. Flood fill the background from the border ----------------------------
#
# From the BORDER, not by colour threshold. A plain "close to the background
# colour" test would also punch holes in dark interior detail; a flood fill can
# only reach pixels actually connected to the outside, which is what a
# background is.

$bgR = $buf[0]; $bgG = $buf[1]; $bgB = $buf[2]
Write-Host "Background sampled at (0,0): $bgR,$bgG,$bgB"

# One byte per pixel. A [bool[]] would be read as an object array by the
# indexer, and `BitArray` needs a non-generic New-Object spelling.
$seen = New-Object 'bool[]' ($W * $H)
$stack = New-Object 'System.Collections.Generic.Stack[int]'

function Test-Bg([int]$p) {
    $d = [Math]::Abs($buf[$p * 4] - $bgR) +
    [Math]::Abs($buf[$p * 4 + 1] - $bgG) +
    [Math]::Abs($buf[$p * 4 + 2] - $bgB)
    return $d -le $Tolerance
}

for ($x = 0; $x -lt $W; $x++) { $stack.Push($x); $stack.Push(($H - 1) * $W + $x) }
for ($y = 0; $y -lt $H; $y++) { $stack.Push($y * $W); $stack.Push($y * $W + $W - 1) }

while ($stack.Count -gt 0) {
    $p = $stack.Pop()
    if ($seen[$p]) { continue }
    if (-not (Test-Bg $p)) { continue }
    $seen[$p] = $true
    $px = $p % $W; $py = [Math]::Floor($p / $W)
    if ($px -gt 0) { $stack.Push($p - 1) }
    if ($px -lt ($W - 1)) { $stack.Push($p + 1) }
    if ($py -gt 0) { $stack.Push($p - $W) }
    if ($py -lt ($H - 1)) { $stack.Push($p + $W) }
}
$bgCount = ($seen | Where-Object { $_ }).Count
Write-Host "Background pixels: $bgCount of $($W * $H) ($([Math]::Round(100 * $bgCount / ($W * $H), 1))%)"

# --- 3. Measure the artwork, and build a feathered transparent foreground ----

$minX = $W; $maxX = -1; $minY = $H; $maxY = -1
for ($p = 0; $p -lt $W * $H; $p++) {
    if ($seen[$p]) { continue }
    $px = $p % $W; $py = [Math]::Floor($p / $W)
    if ($px -lt $minX) { $minX = $px }
    if ($px -gt $maxX) { $maxX = $px }
    if ($py -lt $minY) { $minY = $py }
    if ($py -gt $maxY) { $maxY = $py }
}
$artW = $maxX - $minX + 1; $artH = $maxY - $minY + 1
Write-Host "Artwork bbox: x $minX..$maxX y $minY..$maxY  (${artW} x ${artH})"

$art = [System.Drawing.Bitmap]::new($W, $H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$ad = $art.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly,
    [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$abuf = New-Object byte[] ($stride * $H)
[System.Runtime.InteropServices.Marshal]::Copy($abuf, 0, $ad.Scan0, $abuf.Length)
for ($y = 0; $y -lt $H; $y++) {
    for ($x = 0; $x -lt $W; $x++) {
        $p = $y * $W + $x
        $s = $p * 4; $d = $y * $stride + $x * 4
        $abuf[$d] = $buf[$s]
        $abuf[$d + 1] = $buf[$s + 1]
        $abuf[$d + 2] = $buf[$s + 2]
        $abuf[$d + 3] = if ($seen[$p]) { 0 } else { 255 }
    }
}
# One 3x3 box blur over alpha only. The flood fill is binary, so without this
# the artwork edge keeps the source's hard staircase when it is scaled down to
# 48px for a launcher.
for ($y = 1; $y -lt $H - 1; $y++) {
    for ($x = 1; $x -lt $W - 1; $x++) {
        $sum = 0
        for ($j = -1; $j -le 1; $j++) {
            for ($i = -1; $i -le 1; $i++) {
                $sum += $abuf[($y + $j) * $stride + ($x + $i) * 4 + 3]
            }
        }
        $abuf[$y * $stride + $x * 4 + 3] = [int]($sum / 9)
    }
}
[System.Runtime.InteropServices.Marshal]::Copy($abuf, 0, $ad.Scan0, $abuf.Length)
$art.UnlockBits($ad)

$artRect = [System.Drawing.Rectangle]::new($minX, $minY, $artW, $artH)

# --- 4. Renderers ------------------------------------------------------------

# Deliberately NOT named `$base`: PowerShell variables are case-insensitive, so
# that collided with the `-Base` parameter and the icon was rendered with a
# string where a Color was expected.
$BaseColor = Convert-HexToColor $BaseHex
Write-Host "Base colour: $BaseColor"

function New-Canvas([int]$size, [bool]$opaque) {
    # Opaque targets are created as 24bpp RGB with **no alpha channel at all**.
    # This is not cosmetic: App Store Connect rejects an app icon that merely
    # *has* an alpha channel, even when every pixel in it is fully opaque, and
    # "clear to an opaque colour on a 32bpp canvas" still leaves the channel
    # there. So the depth has to be chosen up front, not worked around.
    $fmt = if ($opaque) {
        [System.Drawing.Imaging.PixelFormat]::Format24bppRgb
    } else {
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
    }
    $b = [System.Drawing.Bitmap]::new($size, $size, $fmt)
    $g = [System.Drawing.Graphics]::FromImage($b)
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.SmoothingMode = 'AntiAlias'
    $g.PixelOffsetMode = 'HighQuality'
    $g.CompositingQuality = 'HighQuality'
    if ($opaque) { $g.Clear($color) } else { $g.Clear([System.Drawing.Color]::Transparent) }
    return @($b, $g)
}

# Draws the artwork centred and scaled to $fraction of the canvas, onto $color.
function Write-Icon([string]$path, [int]$size, [double]$fraction,
        [System.Drawing.Color]$color, [bool]$opaque) {
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    $c = New-Canvas $size $opaque
    $bmp = $c[0]; $g = $c[1]

    # Fit the artwork inside the fraction, preserving its aspect ratio.
    $scale = [Math]::Min(($size * $fraction) / $artW, ($size * $fraction) / $artH)
    $dw = [int][Math]::Round($artW * $scale)
    $dh = [int][Math]::Round($artH * $scale)
    $dx = [int][Math]::Round(($size - $dw) / 2)
    $dy = [int][Math]::Round(($size - $dh) / 2)
    $g.DrawImage($art,
        (New-Object System.Drawing.Rectangle $dx, $dy, $dw, $dh),
        $artRect, [System.Drawing.GraphicsUnit]::Pixel)

    $g.Dispose()
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host ("  {0,-62} {1}x{1}" -f $path.Replace((Get-Location).Path + '\', ''), $size)
}

# --- 5. Android --------------------------------------------------------------
#
# Adaptive: the canvas is 108dp and only the central 72dp (66.7%) is guaranteed
# visible, so the artwork is scaled to 0.667 of the canvas. The foreground is
# composited OPAQUE onto the base colour rather than left transparent: the
# launcher crops the canvas to an arbitrary shape, and a uniform fill means the
# crop edge is invisible whichever shape it picks.
#
# Legacy (pre-8.0): launchers apply their own padding, so the artwork sits
# slightly smaller - 0.84 reads correctly there.

# 0.62, not the 0.667 the spec guarantees. The artwork is 1.35:1, so width is
# the limiting dimension and at 0.667 it lands *exactly* on the safe-zone edge,
# touching the launcher mask. Several OEM launchers (notably some Chinese ROMs)
# crop a little past the spec, and the outermost speed lines are the first thing
# to go. The extra margin costs almost nothing visually.
$safeFraction = 0.62

Write-Host "`nAndroid (adaptive icon, 108dp canvas, artwork at the 62% safe zone)"
$adaptive = @{ 'mdpi' = 108; 'hdpi' = 162; 'xhdpi' = 216; 'xxhdpi' = 324; 'xxxhdpi' = 432 }
foreach ($d in $adaptive.Keys | Sort-Object { $adaptive[$_] }) {
    Write-Icon "android\app\src\main\res\mipmap-$d\ic_launcher_foreground.png" $adaptive[$d] $safeFraction $BaseColor $true
}

# A 432px legacy bitmap is also what the adaptive icon falls back to on some
# OEM launchers, and Android Studio's image-asset tool expects the largest
# bucket to be the master.
Write-Host "`nAndroid (legacy launcher icon, pre-8.0)"
$legacy = @{ 'mdpi' = 48; 'hdpi' = 72; 'xhdpi' = 96; 'xxhdpi' = 144; 'xxxhdpi' = 192 }
foreach ($d in $legacy.Keys | Sort-Object { $legacy[$_] }) {
    Write-Icon "android\app\src\main\res\mipmap-$d\ic_launcher.png" $legacy[$d] 0.84 $BaseColor $true
}

# --- 6. iOS ------------------------------------------------------------------
#
# Opaque, no alpha: App Store Connect rejects an app icon that has one. iOS
# applies a rounded-rect mask, so 0.82 keeps the speed lines off the edge.

Write-Host "`niOS (opaque, no alpha channel)"
$ios = [ordered]@{
    'Icon-App-20x20@1x.png'            = 20
    'Icon-App-20x20@2x.png'            = 40
    'Icon-App-20x20@3x.png'            = 60
    'Icon-App-29x29@1x.png'            = 29
    'Icon-App-29x29@2x.png'            = 58
    'Icon-App-29x29@3x.png'            = 87
    'Icon-App-40x40@1x.png'            = 40
    'Icon-App-40x40@2x.png'            = 80
    'Icon-App-40x40@3x.png'            = 120
    'Icon-App-60x60@2x.png'            = 120
    'Icon-App-60x60@3x.png'            = 180
    'Icon-App-76x76@1x.png'            = 76
    'Icon-App-76x76@2x.png'            = 152
    'Icon-App-83.5x83.5@2x.png'        = 167
    'Icon-App-1024x1024@1x.png'        = 1024
}
foreach ($name in $ios.Keys) {
    Write-Icon "ios\Runner\Assets.xcassets\AppIcon.appiconset\$name" $ios[$name] 0.82 $BaseColor $true
}

# --- 7. Splash artwork -------------------------------------------------------
#
# These are TRANSPARENT - the artwork alone, no background. Each platform
# composites it over the app's own background colour:
#
#   Android <12   layer-list: @color/splash_background + centred @drawable/launch_logo
#   Android 12+   windowSplashScreenAnimatedIcon, which takes the adaptive icon
#   iOS           LaunchImage in the storyboard, over a backgroundColor
#   Web           an <img> in index.html over a CSS background
#
# So the background colour is declared once per platform rather than baked into
# the image, which is what keeps them from drifting apart.

Write-Host "`nSplash artwork (transparent background)"

# $fraction 1.0 with a square canvas of the *desired artwork width* renders the
# artwork exactly that wide, centred, with vertical slack. Width is the limiting
# dimension because the artwork is 1.35:1.
$androidSplash = @{ 'mdpi' = 180; 'hdpi' = 270; 'xhdpi' = 360; 'xxhdpi' = 540; 'xxxhdpi' = 720 }
foreach ($d in $androidSplash.Keys | Sort-Object { $androidSplash[$_] }) {
    $w = $androidSplash[$d]
    Write-Icon "android\app\src\main\res\drawable-$d\launch_logo.png" $w 1.0 $BaseColor $false
}

# iOS LaunchImage is drawn with contentMode="center" at its intrinsic size, so
# these are @1x/@2x/@3x of one point size.
$iosSplash = @{ 'LaunchImage.png' = 200; 'LaunchImage@2x.png' = 400; 'LaunchImage@3x.png' = 600 }
foreach ($name in $iosSplash.Keys) {
    $w = $iosSplash[$name]
    Write-Icon "ios\Runner\Assets.xcassets\LaunchImage.imageset\$name" $w 1.0 $BaseColor $false
}

# Web splash, referenced by index.html.
Write-Icon 'web\icons\splash-logo.png' 512 1.0 $BaseColor $false

# --- 8. Web ------------------------------------------------------------------
#
# Maskable icons get cropped to a circle of diameter 80%, so the artwork must
# sit inside 0.8. The plain icons are shown as-is, so they can fill more.

Write-Host "`nWeb"
Write-Icon 'web\favicon.png' 64 0.92 $BaseColor $true
Write-Icon 'web\icons\Icon-192.png' 192 0.92 $BaseColor $true
Write-Icon 'web\icons\Icon-512.png' 512 0.92 $BaseColor $true
Write-Icon 'web\icons\Icon-maskable-192.png' 192 0.80 $BaseColor $true
Write-Icon 'web\icons\Icon-maskable-512.png' 512 0.80 $BaseColor $true

Write-Host "`nVerifying"
$problems = 0

# 1. iOS must have no alpha channel. App Store Connect rejects it outright.
Get-ChildItem 'ios\Runner\Assets.xcassets\AppIcon.appiconset\*.png' | ForEach-Object {
    $b = [System.Drawing.Bitmap]::new($_.FullName)
    if (($b.PixelFormat -band [System.Drawing.Imaging.PixelFormat]::Alpha) -ne 0) {
        Write-Host "  FAIL $($_.Name) has an alpha channel ($($b.PixelFormat))" -ForegroundColor Red
        $problems++
    }
    $b.Dispose()
}

# 2. The Android adaptive foreground must keep its artwork inside the 66.7%
#    safe zone, or a circular launcher mask eats the speed lines.
$fg = [System.Drawing.Bitmap]::new('android\app\src\main\res\mipmap-xxxhdpi\ic_launcher_foreground.png')
$n = $fg.Width
$off = [int]($n * (1 - $safeFraction) / 2)
$edge = $n - $off
$minX = $n; $maxX = -1; $minY = $n; $maxY = -1
for ($y = 0; $y -lt $n; $y += 2) {
    for ($x = 0; $x -lt $n; $x += 2) {
        $c = $fg.GetPixel($x, $y)
        if ($c.R -gt 60 -or $c.G -gt 60 -or $c.B -gt 60) {
            if ($x -lt $minX) { $minX = $x }; if ($x -gt $maxX) { $maxX = $x }
            if ($y -lt $minY) { $minY = $y }; if ($y -gt $maxY) { $maxY = $y }
        }
    }
}
$fg.Dispose()
Write-Host ("  adaptive foreground: artwork x {0}..{1} y {2}..{3} (safe zone {4}..{5})" -f $minX, $maxX, $minY, $maxY, $off, $edge)
if ($minX -lt $off - 2 -or $maxX -gt $edge + 1 -or $minY -lt $off - 2 -or $maxY -gt $edge + 1) {
    Write-Host "  FAIL adaptive artwork escapes the safe zone" -ForegroundColor Red
    $problems++
}

# 3. Splash artwork MUST be genuinely transparent. If these come out opaque they
#    render as a dark rectangle on the Android/iOS/web background instead of
#    sitting on it, which looks like a bug even though the colours match.
Get-ChildItem 'android\app\src\main\res\drawable-*\launch_logo.png',
    'ios\Runner\Assets.xcassets\LaunchImage.imageset\*.png',
    'web\icons\splash-logo.png' -ErrorAction SilentlyContinue | ForEach-Object {
    $b = [System.Drawing.Bitmap]::new($_.FullName)
    $corner = $b.GetPixel(0, 0)
    if ($corner.A -ne 0) {
        Write-Host "  FAIL $($_.Name) corner alpha is $($corner.A), expected 0 (transparent)" -ForegroundColor Red
        $problems++
    }
    $b.Dispose()
}

# 4. Every generated icon must be a square, which is what each platform expects.
$expected = @(
    'web\favicon.png', 'web\icons\Icon-192.png', 'web\icons\Icon-512.png',
    'web\icons\Icon-maskable-192.png', 'web\icons\Icon-maskable-512.png',
    'android\app\src\main\res\mipmap-xxxhdpi\ic_launcher.png',
    'android\app\src\main\res\mipmap-xxxhdpi\ic_launcher_foreground.png'
)
foreach ($p in $expected) {
    $b = [System.Drawing.Bitmap]::new((Resolve-Path $p).Path)
    if ($b.Width -ne $b.Height) {
        Write-Host "  FAIL $p is $($b.Width)x$($b.Height), not square" -ForegroundColor Red
        $problems++
    }
    $b.Dispose()
}

if ($problems -gt 0) {
    Write-Host "`n$problems problem(s) found." -ForegroundColor Red
    exit 1
}

Write-Host "`nAll checks passed. Verify with: flutter build apk --profile && flutter build web --release"

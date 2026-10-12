<#
.SYNOPSIS
    Generates the square PWA / home-screen icons in pics/icons/ from pics/app_logo.png.

.DESCRIPTION
    The wide banner (pics/app_logo.png) cannot be used as an install icon, so this script
    re-composes a square version with reduced text, reusing the existing artwork:
        SC   (the emblem in pics/sc_logo.png, 251x127 px, so it is sized a bit smaller than SFX)
        TMG  (T, M and G cut from the small "TABLETOP MINIATURES GAME" line of the banner)
        SFX  (cut from the "SFX COMPANION" line of the banner)
    on a dark HUD background with the same blue glow. Pure System.Drawing, no extra tools.

    Output (pics/icons/):
        icon-192.png            purpose "any"
        icon-512.png            purpose "any"
        icon-maskable-512.png   purpose "maskable" (content inside the 80% safe zone)
        apple-touch-icon.png    180x180, opaque (iOS home screen)

    The pixel ranges below were measured on the current pics/app_logo.png (3906x1088).
    If the banner is replaced, re-measure them (or swap the icons by hand).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\generate-pwa-icons.ps1
#>

Add-Type -AssemblyName System.Drawing

$root = $PSScriptRoot
$sourcePath = Join-Path $root 'pics\app_logo.png'
$outDir = Join-Path $root 'pics\icons'
New-Item -ItemType Directory -Force $outDir | Out-Null

$banner = [System.Drawing.Bitmap]::FromFile($sourcePath)
$scLogo = [System.Drawing.Bitmap]::FromFile((Join-Path $root 'pics\sc_logo.png'))

# Cuts a glyph out of a source image as a transparent bitmap trimmed to its visible bounds.
# When $keyLo/$keyHi are given, dark/bluish glow pixels are keyed out by brightness so only
# the light-grey letter remains (used for the small TMG line, which sits on a glow).
function Get-Glyph($source, [int]$x, [int]$y, [int]$w, [int]$h, [int]$keyLo = 0, [int]$keyHi = 0) {
    $rect = New-Object System.Drawing.Rectangle $x, $y, $w, $h
    $glyph = $source.Clone($rect, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $data = $glyph.LockBits((New-Object System.Drawing.Rectangle 0, 0, $w, $h), 'ReadWrite', 'Format32bppArgb')
    $stride = $data.Stride
    $bytes = New-Object byte[] ($stride * $h)
    [Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
    $minX = $w; $minY = $h; $maxX = -1; $maxY = -1
    for ($py = 0; $py -lt $h; $py++) {
        for ($px = 0; $px -lt $w; $px++) {
            $o = $py * $stride + $px * 4
            if ($keyHi -gt $keyLo) {
                $lum = ($bytes[$o] + $bytes[$o + 1] + $bytes[$o + 2]) / 3
                $k = [Math]::Max(0.0, [Math]::Min(1.0, ($lum - $keyLo) / ($keyHi - $keyLo)))
                $bytes[$o + 3] = [byte]($bytes[$o + 3] * $k)
            }
            if ($bytes[$o + 3] -gt 40) {
                if ($px -lt $minX) { $minX = $px }; if ($px -gt $maxX) { $maxX = $px }
                if ($py -lt $minY) { $minY = $py }; if ($py -gt $maxY) { $maxY = $py }
            }
        }
    }
    [Runtime.InteropServices.Marshal]::Copy($bytes, 0, $data.Scan0, $bytes.Length)
    $glyph.UnlockBits($data)
    $trim = New-Object System.Drawing.Rectangle $minX, $minY, ($maxX - $minX + 1), ($maxY - $minY + 1)
    $trimmed = $glyph.Clone($trim, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $glyph.Dispose()
    return $trimmed
}

# --- Glyphs (pixel ranges measured on the 3906x1088 banner) ---
$glyphSC  = Get-Glyph $scLogo 0 0 $scLogo.Width $scLogo.Height   # SC emblem (whole file, trimmed)
$glyphSFX = Get-Glyph $banner 215 760 910 285            # whole SFX
$glyphT   = Get-Glyph $banner 660 560 106 130 70 120     # T of TABLETOP
$glyphM   = Get-Glyph $banner 1648 560 146 130 70 120    # M of MINIATURES
$glyphG   = Get-Glyph $banner 2808 560 118 130 70 120    # G of GAME
$banner.Dispose()
$scLogo.Dispose()

function New-Canvas([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.PixelOffsetMode = 'HighQuality'
    return @{ Bitmap = $bmp; Graphics = $g }
}

function Add-RadialGlow($g, [float]$cx, [float]$cy, [float]$rx, [float]$ry, [int]$alpha, $color) {
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddEllipse($cx - $rx, $cy - $ry, 2 * $rx, 2 * $ry)
    $brush = New-Object System.Drawing.Drawing2D.PathGradientBrush $path
    $brush.CenterColor = [System.Drawing.Color]::FromArgb($alpha, $color)
    $brush.SurroundColors = @([System.Drawing.Color]::FromArgb(0, $color))
    $g.FillPath($brush, $path)
    $brush.Dispose(); $path.Dispose()
}

# Draws a glyph with its horizontal centre at $cx and top at $top, scaled by $scale.
function Draw-Glyph($g, $glyph, [float]$cx, [float]$top, [float]$scale) {
    $w = $glyph.Width * $scale; $h = $glyph.Height * $scale
    $g.DrawImage($glyph, [float]($cx - $w / 2), [float]$top, [float]$w, [float]$h)
}

# Renders the 1024x1024 master. $contentWidth is the width of the widest line in pixels.
function Render-Master([float]$contentWidth) {
    $size = 1024
    $canvas = New-Canvas $size
    $g = $canvas.Graphics

    # Background: dark HUD, slightly lighter in the middle
    $bgPath = New-Object System.Drawing.Drawing2D.GraphicsPath
    $bgPath.AddRectangle((New-Object System.Drawing.Rectangle 0, 0, $size, $size))
    $bg = New-Object System.Drawing.Drawing2D.PathGradientBrush $bgPath
    $bg.CenterColor = [System.Drawing.Color]::FromArgb(255, 14, 28, 46)
    $bg.SurroundColors = @([System.Drawing.Color]::FromArgb(255, 5, 8, 12))
    $bg.CenterPoint = New-Object System.Drawing.PointF ($size / 2), ($size / 2)
    $g.FillRectangle($bg, 0, 0, $size, $size)
    $bg.Dispose(); $bgPath.Dispose()

    # Scales: SFX fills the content width; the SC emblem is 80% of it (it is a small source
    # image, so a bigger upscale would look soft); heights follow from the glyph ratios
    $scScale = ($contentWidth * 0.80) / $glyphSC.Width
    $sfxScale = $contentWidth / $glyphSFX.Width
    $tmgScale = 0.62 * ($contentWidth / 680)

    $scH = $glyphSC.Height * $scScale
    $sfxH = $glyphSFX.Height * $sfxScale
    $tmgH = [Math]::Max($glyphT.Height, [Math]::Max($glyphM.Height, $glyphG.Height)) * $tmgScale
    $gap = 44 * ($contentWidth / 680)
    $total = $scH + $gap + $tmgH + $gap + $sfxH
    $top = ($size - $total) / 2

    # Blue lens glow behind the TMG row (as in the banner)
    $tmgTop = $top + $scH + $gap
    $tmgMid = $tmgTop + $tmgH / 2
    Add-RadialGlow $g ($size / 2) $tmgMid ($contentWidth * 0.62) ($tmgH * 2.4) 150 ([System.Drawing.Color]::FromArgb(0, 120, 255))
    Add-RadialGlow $g ($size / 2) $tmgMid ($contentWidth * 0.30) ($tmgH * 0.9) 200 ([System.Drawing.Color]::FromArgb(120, 190, 255))

    # Thin light lines flanking TMG (fade out towards the edges)
    $lineLeft = ($size - $contentWidth) / 2
    $lineRight = $lineLeft + $contentWidth
    $tmgSpan = 235 * ($contentWidth / 680)
    foreach ($side in @(-1, 1)) {
        $x0 = if ($side -lt 0) { $lineLeft } else { $size / 2 + $tmgSpan / 2 + 30 * ($contentWidth / 680) }
        $x1 = if ($side -lt 0) { $size / 2 - $tmgSpan / 2 - 30 * ($contentWidth / 680) } else { $lineRight }
        $lineBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush ((New-Object System.Drawing.PointF $x0, $tmgMid), (New-Object System.Drawing.PointF $x1, $tmgMid), [System.Drawing.Color]::Transparent, [System.Drawing.Color]::Transparent)
        $blend = New-Object System.Drawing.Drawing2D.ColorBlend 2
        if ($side -lt 0) {
            $blend.Colors = @([System.Drawing.Color]::FromArgb(0, 150, 200, 255), [System.Drawing.Color]::FromArgb(230, 190, 225, 255))
        } else {
            $blend.Colors = @([System.Drawing.Color]::FromArgb(230, 190, 225, 255), [System.Drawing.Color]::FromArgb(0, 150, 200, 255))
        }
        $blend.Positions = @(0.0, 1.0)
        $lineBrush.InterpolationColors = $blend
        $g.FillRectangle($lineBrush, [float][Math]::Min($x0, $x1), [float]($tmgMid - 1.5), [float][Math]::Abs($x1 - $x0), 3.0)
        $lineBrush.Dispose()
    }

    # SC (top line): the emblem, centered
    Draw-Glyph $g $glyphSC ($size / 2) $top $scScale

    # TMG (middle line)
    $letterGap = 70 * ($contentWidth / 680)
    $tw = $glyphT.Width * $tmgScale; $mw = $glyphM.Width * $tmgScale; $gw = $glyphG.Width * $tmgScale
    $rowW = $tw + $mw + $gw + 2 * $letterGap
    $x = ($size - $rowW) / 2
    foreach ($item in @(@($glyphT, $tw), @($glyphM, $mw), @($glyphG, $gw))) {
        $glyph = $item[0]; $gwid = $item[1]; $gh = $glyph.Height * $tmgScale
        $g.DrawImage($glyph, [float]$x, [float]($tmgTop + ($tmgH - $gh) / 2), [float]$gwid, [float]$gh)
        $x += $gwid + $letterGap
    }

    # SFX (bottom line)
    $sfxTop = $tmgTop + $tmgH + $gap
    Draw-Glyph $g $glyphSFX ($size / 2) $sfxTop $sfxScale

    $g.Dispose()
    return $canvas.Bitmap
}

function Save-Resized($master, [int]$size, [string]$name) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.PixelOffsetMode = 'HighQuality'
    $g.DrawImage($master, 0, 0, $size, $size)
    $g.Dispose()
    $path = Join-Path $outDir $name
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host "Wrote $path ($size x $size)"
}

# "any": content fills most of the icon. "maskable": content inside the 80% safe-zone circle.
$anyMaster = Render-Master 780
Save-Resized $anyMaster 512 'icon-512.png'
Save-Resized $anyMaster 192 'icon-192.png'
Save-Resized $anyMaster 180 'apple-touch-icon.png'
$anyMaster.Dispose()

$maskableMaster = Render-Master 560
Save-Resized $maskableMaster 512 'icon-maskable-512.png'
$maskableMaster.Dispose()

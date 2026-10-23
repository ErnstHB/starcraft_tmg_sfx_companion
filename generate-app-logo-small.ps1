<#
.SYNOPSIS
    Makes pics/app_logo_small.png, the reduced copy of the header logo, from pics/app_logo.png.

.DESCRIPTION
    pics/app_logo.png (3906x1088, about 5 MB) is kept as the original artwork and is the source for the install
    icons (generate-pwa-icons.ps1). The header shows the logo at 51 px height, so the page uses this reduced copy
    instead (640 px wide, enough for a 3x screen), which keeps the offline app shell small.
    Pure System.Drawing, no extra tools.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\generate-app-logo-small.ps1
#>

Add-Type -AssemblyName System.Drawing

$targetWidth = 640
$sourcePath = Join-Path $PSScriptRoot 'pics\app_logo.png'
$targetPath = Join-Path $PSScriptRoot 'pics\app_logo_small.png'

$source = [System.Drawing.Image]::FromFile($sourcePath)
try {
    $targetHeight = [int][Math]::Round($source.Height * $targetWidth / $source.Width)
    $target = New-Object System.Drawing.Bitmap $targetWidth, $targetHeight, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($target)
        try {
            $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            # Edge-clamped wrap mode avoids a transparent halo at the borders.
            $attributes = New-Object System.Drawing.Imaging.ImageAttributes
            $attributes.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
            $destination = New-Object System.Drawing.Rectangle 0, 0, $targetWidth, $targetHeight
            $graphics.DrawImage($source, $destination, 0, 0, $source.Width, $source.Height, [System.Drawing.GraphicsUnit]::Pixel, $attributes)
        } finally { $graphics.Dispose() }
        $target.Save($targetPath, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $target.Dispose() }
} finally { $source.Dispose() }

$size = (Get-Item -LiteralPath $targetPath).Length
Write-Host ("pics/app_logo_small.png written: {0}x{1}, {2:N0} KB" -f $targetWidth, $targetHeight, ($size / 1KB))

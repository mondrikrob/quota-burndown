<#
.SYNOPSIS
    Builds docs\social-preview.png (1280x640), the image GitHub shows when the
    repository is shared. Upload it under Settings > General > Social preview.
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$docs = Join-Path (Split-Path $PSScriptRoot) 'docs'
$dot = [string][char]0x00B7

$bmp = [Drawing.Bitmap]::new(1280, 640)
$g = [Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBicubic'; $g.TextRenderingHint = 'AntiAliasGridFit'
$g.Clear([Drawing.ColorTranslator]::FromHtml('#16171A'))

function Draw-Text([string]$Text, [float]$Size, [string]$Color, [float]$X, [float]$Y, [Drawing.FontStyle]$Style = 'Regular', [string]$Family = 'Segoe UI') {
    $font = [Drawing.Font]::new($Family, $Size, $Style, [Drawing.GraphicsUnit]::Pixel)
    $brush = [Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml($Color))
    $g.DrawString($Text, $font, $brush, $X, $Y)
    $font.Dispose(); $brush.Dispose()
}

function Draw-Image([string]$Name, [float]$X, [float]$Y, [float]$Width) {
    $img = [Drawing.Image]::FromFile((Join-Path $docs $Name))
    $g.DrawImage($img, $X, $Y, $Width, $Width * $img.Height / $img.Width)
    $img.Dispose()
}

Draw-Image 'logo.png' 72 92 112
Draw-Text 'Quota Burndown' 66 '#F0F0F0' 200 100 'Bold' 'Segoe UI Semibold'
Draw-Text 'A burndown chart for your Claude Code and Codex limits' 25 '#9AA0A6' 76 236
Draw-Text "Pace $dot run-out forecast $dot tokens and API value" 30 '#E08A6D' 76 316 'Bold' 'Segoe UI Semibold'
Draw-Text "Windows desktop widget + taskbar strip" 26 '#F0F0F0' 76 370
Draw-Text "One readable PowerShell script $dot no install $dot MIT" 26 '#F0F0F0' 76 410
Draw-Image 'strip-dark.png' 76 458 238
Draw-Text 'github.com/mondrikrob/quota-burndown' 22 '#9AA0A6' 76 584

# The widget screenshot on the right, slightly inset from the edges.
Draw-Image 'widget-dark.png' 752 32 492

$g.Dispose()
$out = Join-Path $docs 'social-preview.png'
$bmp.Save($out, [Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
"Saved $out"

param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

Add-Type -AssemblyName System.Drawing

$teal = [System.Drawing.ColorTranslator]::FromHtml('#006D73')
$cream = [System.Drawing.ColorTranslator]::FromHtml('#FFF4DF')
$coral = [System.Drawing.ColorTranslator]::FromHtml('#FF6655')
$gold = [System.Drawing.ColorTranslator]::FromHtml('#FFC247')

function New-LauncherIcon {
    param(
        [int]$Size,
        [string]$OutputPath
    )

    $bitmap = [System.Drawing.Bitmap]::new($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.ScaleTransform($Size / 512.0, $Size / 512.0)
    $graphics.Clear($teal)

    $route = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $route.StartFigure()
    $route.AddBezier(256, 190, 256, 224, 190, 218, 190, 256)
    $route.AddBezier(190, 256, 190, 298, 322, 280, 322, 322)
    $route.AddBezier(322, 322, 322, 346, 284, 350, 256, 340)
    $routePen = [System.Drawing.Pen]::new($cream, 34)
    $routePen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $routePen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $routePen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $graphics.DrawPath($routePen, $route)

    $pin = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $pin.StartFigure()
    $pin.AddBezier(256, 94, 224, 94, 198, 120, 198, 152)
    $pin.AddBezier(198, 152, 198, 194, 256, 234, 256, 234)
    $pin.AddBezier(256, 234, 314, 194, 314, 152, 314, 152)
    $pin.AddBezier(314, 152, 314, 120, 288, 94, 256, 94)
    $pin.CloseFigure()
    $goldBrush = [System.Drawing.SolidBrush]::new($gold)
    $graphics.FillPath($goldBrush, $pin)
    $tealBrush = [System.Drawing.SolidBrush]::new($teal)
    $graphics.FillEllipse($tealBrush, 232, 128, 48, 48)

    $house = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $house.AddPolygon([System.Drawing.Point[]]@(
        [System.Drawing.Point]::new(198, 365),
        [System.Drawing.Point]::new(256, 314),
        [System.Drawing.Point]::new(314, 365),
        [System.Drawing.Point]::new(304, 365),
        [System.Drawing.Point]::new(304, 414),
        [System.Drawing.Point]::new(270, 414),
        [System.Drawing.Point]::new(270, 386),
        [System.Drawing.Point]::new(242, 386),
        [System.Drawing.Point]::new(242, 414),
        [System.Drawing.Point]::new(208, 414),
        [System.Drawing.Point]::new(208, 365)
    ))
    $coralBrush = [System.Drawing.SolidBrush]::new($coral)
    $graphics.FillPath($coralBrush, $house)

    $directory = Split-Path -Parent $OutputPath
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $bitmap.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)

    $coralBrush.Dispose()
    $house.Dispose()
    $tealBrush.Dispose()
    $goldBrush.Dispose()
    $pin.Dispose()
    $routePen.Dispose()
    $route.Dispose()
    $graphics.Dispose()
    $bitmap.Dispose()
}

$outputs = @(
    @{ Size = 48; Path = 'android\app\src\main\res\mipmap-mdpi\ic_launcher.png' },
    @{ Size = 72; Path = 'android\app\src\main\res\mipmap-hdpi\ic_launcher.png' },
    @{ Size = 96; Path = 'android\app\src\main\res\mipmap-xhdpi\ic_launcher.png' },
    @{ Size = 144; Path = 'android\app\src\main\res\mipmap-xxhdpi\ic_launcher.png' },
    @{ Size = 192; Path = 'android\app\src\main\res\mipmap-xxxhdpi\ic_launcher.png' },
    @{ Size = 64; Path = 'web\favicon.png' },
    @{ Size = 192; Path = 'web\icons\Icon-192.png' },
    @{ Size = 512; Path = 'web\icons\Icon-512.png' },
    @{ Size = 192; Path = 'web\icons\Icon-maskable-192.png' },
    @{ Size = 512; Path = 'web\icons\Icon-maskable-512.png' },
    @{ Size = 512; Path = 'store-assets\graphics\app-icon-512.png' }
)

foreach ($output in $outputs) {
    New-LauncherIcon -Size $output.Size -OutputPath (Join-Path $ProjectRoot $output.Path)
}

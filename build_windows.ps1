<#
.SYNOPSIS
    Build Ghostty for Windows.

.DESCRIPTION
    Compiles ghostty.exe using Zig and MSYS2's GTK4 stack, then bundles all
    required DLLs and runtime data into the output directory so the result
    is self-contained and portable.

.PARAMETER ZigPath
    Path to the Zig installation directory (contains zig.exe).
    Default: auto-detected from PATH.

.PARAMETER Msys2Path
    Path to the MSYS2 installation root.
    Default: C:\msys64

.PARAMETER OutputDir
    Where to place the final build artifacts.
    Default: zig-out\bin (standard Zig output)

.PARAMETER SkipBuild
    Skip the Zig build step and only bundle DLLs/runtime data.

.PARAMETER Clean
    Clean the build cache before building.

.EXAMPLE
    .\build_windows.ps1
    .\build_windows.ps1 -ZigPath "C:\zig\zig-0.15.2" -Msys2Path "C:\msys64"
    .\build_windows.ps1 -SkipBuild  # only rebundle DLLs
#>

param(
    [string]$ZigPath = "",
    [string]$Msys2Path = "C:\msys64",
    [string]$OutputDir = "",
    [switch]$SkipBuild,
    [switch]$Clean
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = $PSScriptRoot
if (-not $RepoRoot) { $RepoRoot = Get-Location }

# ── Locate Zig ──────────────────────────────────────────────────────────────
if ($ZigPath) {
    $zigExe = Join-Path $ZigPath "zig.exe"
} else {
    $zigExe = Get-Command zig -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
}
if (-not $zigExe -or -not (Test-Path $zigExe)) {
    Write-Error "zig.exe not found. Install Zig 0.15.2+ and pass -ZigPath or add it to PATH."
    exit 1
}
$ZigPath = Split-Path $zigExe -Parent
Write-Host "[+] Zig: $zigExe" -ForegroundColor Cyan

# Verify minimum Zig version
$zigVer = & $zigExe version 2>&1
Write-Host "    Version: $zigVer"

# ── Locate MSYS2 / mingw64 ─────────────────────────────────────────────────
$mingw = Join-Path $Msys2Path "mingw64"
if (-not (Test-Path "$mingw\bin\pkg-config.exe")) {
    Write-Error "MSYS2 mingw64 toolchain not found at $mingw. Install MSYS2 and the required packages."
    exit 1
}
Write-Host "[+] MSYS2 mingw64: $mingw" -ForegroundColor Cyan

# Verify required packages
$requiredPkgs = @(
    @{ Name = "GTK4";               Check = "$mingw\bin\libgtk-4-1.dll" },
    @{ Name = "libadwaita";         Check = "$mingw\bin\libadwaita-1-0.dll" },
    @{ Name = "blueprint-compiler"; Check = "$mingw\bin\blueprint-compiler" }
)
foreach ($pkg in $requiredPkgs) {
    if (-not (Test-Path $pkg.Check)) {
        Write-Error "$($pkg.Name) not found. Install with: pacman -S mingw-w64-x86_64-$($pkg.Name.ToLower())"
        exit 1
    }
    Write-Host "    $($pkg.Name): OK" -ForegroundColor Green
}

# ── Set up environment ──────────────────────────────────────────────────────
$env:PATH = "$ZigPath;$mingw\bin;$env:PATH"
$env:PKG_CONFIG_PATH = "$mingw\lib\pkgconfig;$mingw\share\pkgconfig"

# ── Zig stdlib cross-drive workaround ───────────────────────────────────────
# Zig 0.15.x has a bug where std.fs.path.relative() asserts when paths span
# different Windows drive letters.  Keep the global cache on the same drive
# as the project to avoid this.
$projectDrive = (Resolve-Path $RepoRoot).Drive.Name
$globalCache = "${projectDrive}:\.zig-global-cache"
Write-Host "[+] Global cache: $globalCache" -ForegroundColor Cyan

# ── Patch check: Zig stdlib Run.zig ─────────────────────────────────────────
# Even with same-drive cache, some dependency build.zig files call setCwd()
# which can still trigger the assertion.  Check if the patch is applied.
$runZig = Join-Path $ZigPath "lib\std\Build\Step\Run.zig"
if (Test-Path $runZig) {
    $runContent = Get-Content $runZig -Raw
    if ($runContent -match 'assert\(!fs\.path\.isAbsolute\(child_cwd_rel\)\)' -or
        $runContent -match 'assert\(!isAbsolute\(child_cwd_rel\)\)') {
        Write-Warning @"
Zig stdlib patch not applied!  The build may fail with an assertion in
convertPathArg when dependency caches are on a different drive.

To fix, edit:
  $runZig

Find the line (around line 662):
  assert(!fs.path.isAbsolute(child_cwd_rel));

Replace with:
  if (fs.path.isAbsolute(child_cwd_rel)) return child_cwd_rel;

Or ensure all paths are on drive ${projectDrive}: by setting:
  `$env:LOCALAPPDATA = "${projectDrive}:\zigcache"` before building.
"@
    }
}

# ── Clean (optional) ───────────────────────────────────────────────────────
if ($Clean) {
    Write-Host "[+] Cleaning build cache..." -ForegroundColor Yellow
    Remove-Item "$RepoRoot\.zig-cache" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$RepoRoot\zig-out" -Recurse -Force -ErrorAction SilentlyContinue
}

# ── Build ───────────────────────────────────────────────────────────────────
if (-not $SkipBuild) {
    Write-Host "`n[+] Building ghostty.exe ..." -ForegroundColor Cyan
    Push-Location $RepoRoot
    try {
        & $zigExe build -Dapp-runtime=gtk --global-cache-dir $globalCache 2>&1 | ForEach-Object {
            Write-Host $_
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Build failed with exit code $LASTEXITCODE"
            exit $LASTEXITCODE
        }
    } finally {
        Pop-Location
    }
    Write-Host "[+] Build succeeded!" -ForegroundColor Green
}

# ── Determine output directory ──────────────────────────────────────────────
if (-not $OutputDir) {
    $OutputDir = Join-Path $RepoRoot "zig-out\bin"
}
$ghosttyExe = Join-Path $OutputDir "ghostty.exe"
if (-not (Test-Path $ghosttyExe)) {
    Write-Error "ghostty.exe not found at $ghosttyExe"
    exit 1
}
Write-Host "`n[+] Bundling runtime dependencies into $OutputDir ..." -ForegroundColor Cyan

# ── Bundle DLLs ─────────────────────────────────────────────────────────────
# Use MSYS2 ldd to find all transitive DLL dependencies from mingw64
$lddExe = Join-Path $Msys2Path "usr\bin\ldd.exe"
if (-not (Test-Path $lddExe)) {
    Write-Warning "ldd not found at $lddExe — falling back to manual DLL list"
    $dllNames = Get-ChildItem "$mingw\bin\*.dll" | Select-Object -ExpandProperty Name
} else {
    $lddOutput = & $lddExe $ghosttyExe 2>&1
    $dllPaths = $lddOutput |
        Select-String "=> /mingw64/bin/" |
        ForEach-Object {
            ($_ -split "=> ")[1].Split(" ")[0] -replace "^/mingw64/bin/", "$mingw\bin\"
        } |
        Sort-Object -Unique
}

$copiedCount = 0
foreach ($dll in $dllPaths) {
    $name = Split-Path $dll -Leaf
    $dest = Join-Path $OutputDir $name
    if (-not (Test-Path $dest)) {
        Copy-Item $dll $dest
        $copiedCount++
    }
}
Write-Host "    Copied $copiedCount DLLs ($($dllPaths.Count) total dependencies)" -ForegroundColor Green

# ── Bundle gdbus.exe (required by GIO on Windows) ──────────────────────────
$gdbus = "$mingw\bin\gdbus.exe"
if (Test-Path $gdbus) {
    Copy-Item $gdbus $OutputDir -Force
    Write-Host "    Copied gdbus.exe" -ForegroundColor Green
}

# ── Bundle GLib schemas ─────────────────────────────────────────────────────
$schemaDir = Join-Path $OutputDir "share\glib-2.0\schemas"
New-Item -ItemType Directory -Path $schemaDir -Force | Out-Null
$schemaFile = "$mingw\share\glib-2.0\schemas\gschemas.compiled"
if (Test-Path $schemaFile) {
    Copy-Item $schemaFile $schemaDir -Force
    Write-Host "    Copied GLib compiled schemas" -ForegroundColor Green
}

# ── Bundle GDK-Pixbuf loaders ──────────────────────────────────────────────
$pixbufSrc = "$mingw\lib\gdk-pixbuf-2.0\2.10.0"
$pixbufDst = Join-Path $OutputDir "lib\gdk-pixbuf-2.0\2.10.0"
if (Test-Path $pixbufSrc) {
    $loaderDst = Join-Path $pixbufDst "loaders"
    New-Item -ItemType Directory -Path $loaderDst -Force | Out-Null
    Copy-Item "$pixbufSrc\loaders\*.dll" $loaderDst -Force
    if (Test-Path "$pixbufSrc\loaders.cache") {
        Copy-Item "$pixbufSrc\loaders.cache" $pixbufDst -Force
    }
    Write-Host "    Copied GDK-Pixbuf loaders" -ForegroundColor Green
}

# ── Bundle Adwaita icons ────────────────────────────────────────────────────
$iconDst = Join-Path $OutputDir "share\icons"
New-Item -ItemType Directory -Path $iconDst -Force | Out-Null
foreach ($theme in @("Adwaita", "hicolor")) {
    $themeSrc = "$mingw\share\icons\$theme"
    if (Test-Path $themeSrc) {
        & robocopy $themeSrc "$iconDst\$theme" /E /NJH /NJS /NDL /NFL /NP | Out-Null
        # robocopy exit codes < 8 are success (1 = files copied, 0 = no change)
        if ($LASTEXITCODE -ge 8) {
            Write-Warning "robocopy failed copying $theme icons (exit code $LASTEXITCODE)"
        }
        Write-Host "    Copied $theme icon theme" -ForegroundColor Green
    }
}
# Reset exit code after robocopy (codes 0-7 are success)
$global:LASTEXITCODE = 0

# ── Summary ─────────────────────────────────────────────────────────────────
$totalSize = [math]::Round(
    (Get-ChildItem $OutputDir -Recurse | Measure-Object -Property Length -Sum).Sum / 1MB, 1
)
$dllCount = (Get-ChildItem $OutputDir -Filter "*.dll").Count

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " Build complete!" -ForegroundColor Green
Write-Host " Output:     $OutputDir" 
Write-Host " Executable: $ghosttyExe"
Write-Host " DLLs:       $dllCount"
Write-Host " Total size: ${totalSize} MB"
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "`nRun with:  .\zig-out\bin\ghostty.exe"

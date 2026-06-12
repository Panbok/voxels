param(
	[Parameter(ValueFromRemainingArguments = $true)]
	[string[]] $AppArgs
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ProjectRoot = $PSScriptRoot
$SourceDir = Join-Path $ProjectRoot "src"
$VendorDir = Join-Path $ProjectRoot "vendor"
$AssetsDir = Join-Path $ProjectRoot "assets"
$BuildDir = Join-Path $ProjectRoot "build"
$ExePath = Join-Path $BuildDir "debug_build.exe"
$PdbPath = Join-Path $BuildDir "debug_build.pdb"

New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null

if (Test-Path $VendorDir) {
	Get-ChildItem -Path $VendorDir -Recurse -File -Filter "*.dll" |
		ForEach-Object {
			Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $BuildDir $_.Name) -Force
		}

	$FontsDir = Join-Path $VendorDir "fonts"
	if (Test-Path $FontsDir) {
		$BuildVendorDir = Join-Path $BuildDir "vendor"
		New-Item -ItemType Directory -Force -Path $BuildVendorDir | Out-Null
		Copy-Item -LiteralPath $FontsDir -Destination $BuildVendorDir -Recurse -Force
	}
}

if (Test-Path $AssetsDir) {
	Copy-Item -LiteralPath $AssetsDir -Destination $BuildDir -Recurse -Force
}

$ShaderSourceDir = Join-Path $AssetsDir "shaders"
$ShaderOutputDir = Join-Path $BuildDir "assets\shaders"
if (Test-Path $ShaderSourceDir) {
	$dxc = Get-Command "dxc" -ErrorAction Stop

	Get-ChildItem -Path $ShaderSourceDir -File -Filter "*.hlsl" |
		ForEach-Object {
			$profile = if ($_.Name -like "*.vert.hlsl") {
				"vs_6_0"
			}
			elseif ($_.Name -like "*.frag.hlsl") {
				"ps_6_0"
			}
			else {
				throw "Unknown shader stage for '$($_.Name)'. Expected *.vert.hlsl or *.frag.hlsl."
			}

			$outputName = $_.Name -replace "\.hlsl$", ".dxil"
			$outputPath = Join-Path $ShaderOutputDir $outputName
			& $dxc.Source -T $profile -E "main" -Fo $outputPath $_.FullName
			if ($LASTEXITCODE -ne 0) {
				exit $LASTEXITCODE
			}
		}
}

odin build $SourceDir -out:$ExePath -pdb-name:$PdbPath -debug -vet -warnings-as-errors -define:EAGER_STARTUP_GRID=false
if ($LASTEXITCODE -ne 0) {
	exit $LASTEXITCODE
}

Push-Location $BuildDir
try {
	& $ExePath @AppArgs
	exit $LASTEXITCODE
}
finally {
	Pop-Location
}

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
$ExePath = Join-Path $BuildDir "release_build.exe"
$AsyncCollectionDir = Join-Path $SourceDir "async"
$GfxCollectionDir = Join-Path $SourceDir "gfx"
$WorldCollectionDir = Join-Path $SourceDir "world"

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
	$slangc = Get-Command "slangc" -ErrorAction Stop

	if (Test-Path $ShaderOutputDir) {
		Get-ChildItem -Path $ShaderOutputDir -File -Filter "*.hlsl" |
			Remove-Item -Force
		Get-ChildItem -Path $ShaderOutputDir -File -Filter "*.dxil" |
			Remove-Item -Force
	}

	Get-ChildItem -Path $ShaderSourceDir -File -Filter "*.slang" |
		ForEach-Object {
			$profile = if ($_.Name -like "*.vert.slang") {
				"vs_6_0"
			}
			elseif ($_.Name -like "*.frag.slang") {
				"ps_6_0"
			}
			else {
				throw "Unknown shader stage for '$($_.Name)'. Expected *.vert.slang or *.frag.slang."
			}

			$outputName = $_.Name -replace "\.slang$", ".dxil"
			$outputPath = Join-Path $ShaderOutputDir $outputName
			& $slangc.Source -target dxil -profile $profile -entry "main" -matrix-layout-column-major -o $outputPath $_.FullName
			if ($LASTEXITCODE -ne 0) {
				exit $LASTEXITCODE
			}
		}
}

odin build $SourceDir -collection:app=$SourceDir -collection:async=$AsyncCollectionDir -collection:gfx=$GfxCollectionDir -collection:world=$WorldCollectionDir -out:$ExePath -o:speed
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

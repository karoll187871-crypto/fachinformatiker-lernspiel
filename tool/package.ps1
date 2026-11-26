# Packt das Spiel in EINE exe (Installer ohne Admin-Rechte), verlustfrei komprimiert.
# Aufruf (im Projektordner):  powershell -ExecutionPolicy Bypass -File tool\package.ps1
# Ergebnis: dist\Fachinformatiker-Lernspiel.exe
#
# Die exe enthält KEINEN Spielstand: Spielstände liegen pro Benutzer in
# %APPDATA%\com.example\fachinformatiker_lernspiel und werden nie mitgepackt.
param([switch]$SkipBuild)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
# Flutter: aus dem PATH oder aus dem Downloads-Ordner
$flutter = (Get-Command flutter -ErrorAction SilentlyContinue).Source
if (-not $flutter) {
    $flutter = Get-ChildItem "$env:USERPROFILE\Downloads\flutter_windows_*\flutter\bin\flutter.bat" -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
}
$dist = Join-Path $root 'dist'
$stage = Join-Path $dist 'staging'
$app = Join-Path $stage 'app'
$out = Join-Path $dist 'Fachinformatiker-Lernspiel.exe'

Get-Process fachinformatiker_lernspiel -ErrorAction SilentlyContinue | Stop-Process -Force
if (-not $SkipBuild) {
    Push-Location $root
    & $flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw 'Build fehlgeschlagen' }
    Pop-Location
}

if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force $app | Out-Null

# 1) Spiel-Dateien
$release = Join-Path $root 'build\windows\x64\runner\Release'
Copy-Item "$release\*" $app -Recurse -Force

# 2) Visual-C++-Laufzeit mitliefern (app-lokal), damit es auf jedem PC startet
$crt = Get-ChildItem 'C:\Program Files\Microsoft Visual Studio\*\*\VC\Redist\MSVC\*\x64\Microsoft.VC14*.CRT' -Directory |
    Sort-Object FullName -Descending | Select-Object -First 1
if ($crt) { Copy-Item (Join-Path $crt.FullName '*.dll') $app -Force } else { Write-Warning 'VC-Laufzeit nicht gefunden' }

# 3) Quellcode (AGPL-3.0 verlangt, dass er mitgegeben wird)
$src = Join-Path $stage 'src'
New-Item -ItemType Directory -Force $src | Out-Null
foreach ($item in 'lib', 'assets', 'windows', 'test', 'tool', 'pubspec.yaml', 'pubspec.lock',
    'analysis_options.yaml', 'README.md', 'LICENSE', 'NOTICE.md') {
    $p = Join-Path $root $item
    if (Test-Path $p) { Copy-Item $p $src -Recurse -Force }
}
Remove-Item (Join-Path $src 'windows\flutter\ephemeral') -Recurse -Force -ErrorAction SilentlyContinue
Compress-Archive -Path "$src\*" -DestinationPath (Join-Path $app 'Quellcode.zip') -CompressionLevel Optimal
Copy-Item (Join-Path $root 'LICENSE') (Join-Path $app 'LICENSE.txt')
Copy-Item (Join-Path $root 'NOTICE.md') (Join-Path $app 'NOTICE.md')
Remove-Item $src -Recurse -Force

# 4) Deinstallation
@'
$ErrorActionPreference = 'SilentlyContinue'
Get-Process fachinformatiker_lernspiel | Stop-Process -Force
foreach ($d in [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs')) {
  Remove-Item (Join-Path $d 'Fachinformatiker Lernspiel.lnk') -Force
  Remove-Item (Join-Path $d 'Fachinformatiker Lernspiel entfernen.lnk') -Force
}
$dir = Join-Path $env:LOCALAPPDATA 'Programs\FachinformatikerLernspiel'
Start-Process cmd.exe -ArgumentList "/c timeout /t 2 >nul & rmdir /s /q `"$dir`"" -WindowStyle Hidden
Add-Type -AssemblyName PresentationFramework
[System.Windows.MessageBox]::Show('Fachinformatiker Lernspiel wurde entfernt. Dein Spielstand bleibt erhalten.', 'Entfernt') | Out-Null
'@ | Set-Content (Join-Path $app 'deinstallieren.ps1') -Encoding UTF8

# 5) Alles verlustfrei zippen
$zip = Join-Path $stage 'spiel.zip'
Compress-Archive -Path "$app\*" -DestinationPath $zip -CompressionLevel Optimal

# 6) Installationsskript (läuft beim Doppelklick, ohne Admin-Rechte)
@'
$ErrorActionPreference = 'Stop'
try {
  $target = Join-Path $env:LOCALAPPDATA 'Programs\FachinformatikerLernspiel'
  Get-Process fachinformatiker_lernspiel -ErrorAction SilentlyContinue | Stop-Process -Force
  if (Test-Path (Join-Path $target 'fachinformatiker_lernspiel.exe')) { Remove-Item $target -Recurse -Force }
  New-Item -ItemType Directory -Force $target | Out-Null
  Expand-Archive -Path (Join-Path $PSScriptRoot 'spiel.zip') -DestinationPath $target -Force
  $exe = Join-Path $target 'fachinformatiker_lernspiel.exe'
  $ws = New-Object -ComObject WScript.Shell
  foreach ($dir in [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs')) {
    $l = $ws.CreateShortcut((Join-Path $dir 'Fachinformatiker Lernspiel.lnk'))
    $l.TargetPath = $exe; $l.WorkingDirectory = $target; $l.IconLocation = "$exe,0"; $l.Save()
  }
  $u = $ws.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Programs')) 'Fachinformatiker Lernspiel entfernen.lnk'))
  $u.TargetPath = 'powershell.exe'
  $u.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$target\deinstallieren.ps1`""
  $u.Save()
  Start-Process $exe -WorkingDirectory $target
} catch {
  Add-Type -AssemblyName PresentationFramework
  [System.Windows.MessageBox]::Show("Installation fehlgeschlagen: $($_.Exception.Message)", 'Fachinformatiker Lernspiel') | Out-Null
}
'@ | Set-Content (Join-Path $stage 'install.ps1') -Encoding UTF8

# 7) Eine exe bauen (IExpress ist in Windows eingebaut, Cabinet = verlustfrei)
if (Test-Path $out) { Remove-Item $out -Force }
$sed = @"
[Version]
Class=IEXPRESS
SEDVersion=3
[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=0
HideExtractAnimation=0
UseLongFileName=1
InsideCompressed=0
CAB_FixedSize=0
CAB_ResvCodeSigning=0
RebootMode=N
InstallPrompt=%InstallPrompt%
DisplayLicense=%DisplayLicense%
FinishMessage=%FinishMessage%
TargetName=%TargetName%
FriendlyName=%FriendlyName%
AppLaunched=%AppLaunched%
PostInstallCmd=%PostInstallCmd%
AdminQuietInstCmd=%AdminQuietInstCmd%
UserQuietInstCmd=%UserQuietInstCmd%
SourceFiles=SourceFiles
[Strings]
InstallPrompt=
DisplayLicense=
FinishMessage=
TargetName=$out
FriendlyName=Fachinformatiker Lernspiel
AppLaunched=powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File install.ps1
PostInstallCmd=<None>
AdminQuietInstCmd=
UserQuietInstCmd=
FILE0="install.ps1"
FILE1="spiel.zip"
[SourceFiles]
SourceFiles0=$stage\
[SourceFiles0]
%FILE0%=
%FILE1%=
"@
$sedPath = Join-Path $stage 'paket.sed'
Set-Content $sedPath $sed -Encoding ASCII
Start-Process -FilePath "$env:WINDIR\System32\iexpress.exe" -ArgumentList '/N', '/Q', $sedPath -Wait -NoNewWindow
if (-not (Test-Path $out)) { throw 'IExpress hat keine exe erzeugt' }
'Fertig: {0} ({1:N1} MB, entpackt {2:N1} MB)' -f $out, ((Get-Item $out).Length / 1MB),
    ((Get-ChildItem $app -Recurse | Measure-Object Length -Sum).Sum / 1MB)

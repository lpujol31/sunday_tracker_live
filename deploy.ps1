# deploy.ps1 — Build + deploiement web de Sunday Tracker Live.
# Usage : depuis le dossier du projet, lance   .\deploy.ps1
#
# Fait, dans l'ordre :
#   1. bump automatique du build number dans pubspec.yaml (format yyyyMMdd + sequence)
#   2. flutter build web --pwa-strategy=none   (SANS service worker)
#   3. firebase deploy --only hosting          (le garde-fou check_build.js s'execute avant)
#
# Options :
#   .\deploy.ps1 -NoBump    -> ne touche pas a la version (redeploie tel quel)

param(
  [switch]$NoBump
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

# --- 1. Bump du build number ---------------------------------------------------
if (-not $NoBump) {
  $pubspec = Join-Path $PSScriptRoot 'pubspec.yaml'
  # Lecture/ecriture en UTF-8 SANS BOM via .NET : Get-Content/Set-Content de
  # PowerShell 5.1 corrompent les accents et ajoutent un BOM (mojibake).
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  $content = [System.IO.File]::ReadAllText($pubspec, [System.Text.Encoding]::UTF8)

  if ($content -match '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$') {
    $semver   = $Matches[1]
    $oldBuild = $Matches[2]
    $today    = Get-Date -Format 'yyyyMMdd'

    if ($oldBuild.Length -ge 8 -and $oldBuild.Substring(0, 8) -eq $today) {
      # meme jour -> on incremente la sequence (2 derniers chiffres)
      $seq = [int]$oldBuild.Substring(8)
      $newBuild = $today + ('{0:D2}' -f ($seq + 1))
    } else {
      # nouveau jour -> sequence 01
      $newBuild = $today + '01'
    }

    $newVersion = "$semver+$newBuild"
    # [^\r\n]* : ne remplace que le contenu de la ligne version, sans toucher aux
    # sauts de ligne (preserve la ligne vide qui suit).
    $content = $content -replace '(?m)^version:[^\r\n]*', "version: $newVersion"
    [System.IO.File]::WriteAllText($pubspec, $content, $utf8NoBom)
    Write-Host "[deploy] Version : $semver+$oldBuild  ->  $newVersion" -ForegroundColor Cyan
  } else {
    Write-Host "[deploy] AVERTISSEMENT : ligne 'version:' introuvable/format inattendu, bump ignore." -ForegroundColor Yellow
  }
}

# --- 2. Build web (sans service worker) ----------------------------------------
# flutter clean OBLIGATOIRE : un build incremental produit par intermittence un
# build incomplet sur cette machine (manifest.json + assets/ manquants -> page
# blanche). Le clean garantit un build complet a chaque fois.
Write-Host "[deploy] flutter clean ..." -ForegroundColor Cyan
flutter clean
if ($LASTEXITCODE -ne 0) { Write-Host "[deploy] ECHEC du flutter clean. Deploiement annule." -ForegroundColor Red; exit 1 }

Write-Host "[deploy] flutter build web --pwa-strategy=none ..." -ForegroundColor Cyan
flutter build web --pwa-strategy=none
if ($LASTEXITCODE -ne 0) { Write-Host "[deploy] ECHEC du build Flutter. Deploiement annule." -ForegroundColor Red; exit 1 }

# --- 3. Deploiement (check_build.js s'execute en predeploy) --------------------
Write-Host "[deploy] firebase deploy --only hosting ..." -ForegroundColor Cyan
firebase deploy --only hosting
if ($LASTEXITCODE -ne 0) { Write-Host "[deploy] ECHEC du deploiement Firebase." -ForegroundColor Red; exit 1 }

Write-Host "[deploy] OK -> https://sunday-tracker-live.web.app" -ForegroundColor Green

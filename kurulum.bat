<# :
@echo off
rem ======================================================================
rem  YSTCore Rust Server - Windows kurulum
rem  Cift tikla: server_config.json okunur, SteamCMD + Rust Dedicated
rem  Server bu klasore kurulur/guncellenir, baslatma betikleri uretilir.
rem  Otomasyon icin: kurulum.bat /nopause
rem ======================================================================
setlocal
set "YST_BASE=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex ([IO.File]::ReadAllText('%~f0',[Text.Encoding]::UTF8))"
set "YST_RC=%ERRORLEVEL%"
if /i not "%~1"=="/nopause" pause
exit /b %YST_RC%
#>

# ----------------------------------------------------------------------
# Buradan sonrasi PowerShell (Windows PowerShell 5.1 uyumlu)
# ----------------------------------------------------------------------
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Base = $env:YST_BASE.TrimEnd('\')
$Utf8NoBom = New-Object Text.UTF8Encoding($false)

function Info($m) { Write-Host "[YSTCore] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[  OK   ] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[ UYARI ] $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "[ HATA  ] $m" -ForegroundColor Red; exit 1 }
function Val($v, $d) { if ($null -eq $v -or "$v" -eq '') { $d } else { $v } }

try {
# ---------------------------------------------------------------- config
$cfgPath = Join-Path $Base 'server_config.json'
if (-not (Test-Path $cfgPath)) { Fail "server_config.json bulunamadi: $cfgPath" }
try { $cfg = [IO.File]::ReadAllText($cfgPath, [Text.Encoding]::UTF8) | ConvertFrom-Json }
catch { Fail "server_config.json gecerli bir JSON degil: $($_.Exception.Message)" }

$S = $cfg.server; $N = $cfg.network; $R = $cfg.rcon; $RT = $cfg.runtime
$identity  = Val $S.identity 'ystcore'
if ($identity -notmatch '^[A-Za-z0-9_\-]+$') { Fail "server.identity sadece harf, rakam, - ve _ icerebilir." }
$framework = (Val $cfg.mods.framework 'none').ToLower()
if ('none','oxide','carbon' -notcontains $framework) { Fail "mods.framework 'none', 'oxide' veya 'carbon' olmali." }
$branch    = Val $cfg.steam.branch 'public'

$SteamDir  = Join-Path $Base 'steamcmd'
$ServerDir = Join-Path $Base 'rustserver'
$LogDir    = Join-Path $Base 'logs'
$StateDir  = Join-Path $Base '.kurulum'
foreach ($d in $SteamDir, $ServerDir, $LogDir, $StateDir) { New-Item -ItemType Directory -Force $d | Out-Null }

Info "Sunucu: $($S.hostname)  |  kapasite: $($S.maxPlayers)  |  mod: $framework  |  branch: $branch"
Info "Kurulum klasoru: $Base"

# ------------------------------------------------- kalici durum (seed/sifre)
$statePath = Join-Path $StateDir 'state.json'
$state = if (Test-Path $statePath) { [IO.File]::ReadAllText($statePath) | ConvertFrom-Json } else { New-Object PSObject }
function Set-State($k, $v) { $state | Add-Member -NotePropertyName $k -NotePropertyValue $v -Force }

$seed = [int64](Val $S.seed 0)
if ($seed -le 0) {
    if (-not $state.seed) { Set-State 'seed' (Get-Random -Minimum 1 -Maximum 2147483647) }
    $seed = $state.seed
}
$rconPw = "$($R.password)"
if ($rconPw -eq '') {
    if (-not $state.rconPassword) {
        $b = New-Object byte[] 24; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
        Set-State 'rconPassword' (([Convert]::ToBase64String($b)) -replace '[+/=]', 'x')
    }
    $rconPw = $state.rconPassword
}
[IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json), $Utf8NoBom)

# ------------------------------------------------------------- SteamCMD
$steamExe = Join-Path $SteamDir 'steamcmd.exe'
if (-not (Test-Path $steamExe)) {
    Info 'SteamCMD indiriliyor (Valve resmi CDN)...'
    $zip = Join-Path $SteamDir 'steamcmd.zip'
    Invoke-WebRequest 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip' -OutFile $zip -UseBasicParsing
    Expand-Archive $zip -DestinationPath $SteamDir -Force
    Remove-Item $zip
}
$sig = Get-AuthenticodeSignature $steamExe
if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Valve( Corp\.)?(,|$)') {
    Fail "steamcmd.exe imzasi dogrulanamadi ($($sig.Status)). Dosyayi silip tekrar deneyin."
}
Ok 'SteamCMD hazir (Valve imzasi dogrulandi).'

# ------------------------------------------------ Rust Dedicated Server
$manifest = Join-Path $ServerDir 'steamapps\appmanifest_258550.acf'
$appArgs = @('+force_install_dir', $ServerDir, '+login', 'anonymous', '+app_update', '258550')
if ($branch -ne 'public') { $appArgs += @('-beta', $branch) }
$appArgs += @('validate', '+quit')
$installed = $false
for ($i = 1; $i -le 5 -and -not $installed; $i++) {
    Info "Rust Dedicated Server kuruluyor/guncelleniyor (deneme $i/5, ilk kurulum ~5 GB)..."
    & $steamExe @appArgs | ForEach-Object { if ($_ -match 'Success|Error|progress: \d+\.\d|Update state') { Write-Host "   $_" } }
    $installed = (Test-Path (Join-Path $ServerDir 'RustDedicated.exe')) -and (Test-Path $manifest) -and
                 ((Get-Content $manifest -Raw) -match '"StateFlags"\s+"4"')
    if (-not $installed -and $i -lt 5) { Warn 'Kurulum tamamlanmadi, 10 sn sonra tekrar denenecek...'; Start-Sleep 10 }
}
if (-not $installed) { Fail 'Rust Dedicated Server kurulamadi. steamcmd\logs\content_log.txt dosyasina bakin.' }
Ok 'Rust Dedicated Server kurulu ve guncel.'

# ------------------------------------------------------- mod framework
$doorstop = @('winhttp.dll', 'doorstop_config.ini') | ForEach-Object { Join-Path $ServerDir $_ }
switch ($framework) {
    'oxide' {
        Info 'Oxide (uMod) indiriliyor (umod.org -> OxideMod resmi surum)...'
        $zip = Join-Path $StateDir 'Oxide.Rust.zip'
        Invoke-WebRequest 'https://github.com/OxideMod/Oxide.Rust/releases/latest/download/Oxide.Rust.zip' -OutFile $zip -UseBasicParsing
        Expand-Archive $zip -DestinationPath $ServerDir -Force; Remove-Item $zip
        Ok 'Oxide kuruldu.'
    }
    'carbon' {
        Info 'Carbon indiriliyor (carbonmod.gg -> production build)...'
        $zip = Join-Path $StateDir 'Carbon.zip'
        Invoke-WebRequest 'https://github.com/CarbonCommunity/Carbon/releases/download/production_build/Carbon.Windows.Release.zip' -OutFile $zip -UseBasicParsing
        Expand-Archive $zip -DestinationPath $ServerDir -Force; Remove-Item $zip
        Ok 'Carbon kuruldu.'
    }
    'none' {
        # Carbon daha once kuruldu ise yukleyicisini devre disi birak (validate Oxide'i zaten geri alir)
        foreach ($f in $doorstop) { if (Test-Path $f) { Move-Item $f "$f.disabled" -Force; Warn "$(Split-Path $f -Leaf) devre disi birakildi (mod: none)." } }
    }
}

# -------------------------------------------------------------- server.cfg
function Q($v) { '"' + ("$v" -replace '"', "'") + '"' }
function B($v) { if ($v) { 'true' } else { 'false' } }
$cfgDir = Join-Path $ServerDir "server\$identity\cfg"
New-Item -ItemType Directory -Force $cfgDir | Out-Null
$lines = @(
    '// BU DOSYA kurulum.bat TARAFINDAN URETILIR - degisiklikleri server_config.json icinde yapin.'
    "server.hostname $(Q $S.hostname)"
    "server.description $(Q ((Val $S.description '') -replace '\r?\n', '\n'))"
    "server.url $(Q (Val $S.url ''))"
    "server.headerimage $(Q (Val $S.headerImage ''))"
    "server.logoimage $(Q (Val $S.logoImage ''))"
    "server.tags $(Q (Val $S.tags ''))"
    "server.maxplayers $([int](Val $S.maxPlayers 50))"
    "server.saveinterval $([int](Val $S.saveInterval 300))"
    "server.pve $(B $S.pve)"
)
if ($cfg.extraConvars) {
    foreach ($p in $cfg.extraConvars.PSObject.Properties) {
        $v = if ($p.Value -is [bool]) { B $p.Value } elseif ($p.Value -is [string]) { Q $p.Value } else { "$($p.Value)" }
        $lines += "$($p.Name) $v"
    }
}
[IO.File]::WriteAllText((Join-Path $cfgDir 'server.cfg'), ($lines -join "`r`n") + "`r`n", $Utf8NoBom)
Ok "server.cfg yazildi: server\$identity\cfg\server.cfg"

# --------------------------------------------------- baslatma betikleri
$gamePort = [int](Val $N.gamePort 28015); $queryPort = [int](Val $N.queryPort 28017)
$appPort  = [int](Val $N.appPort 28082);  $rconPort  = [int](Val $R.port 28016)
$rconIp   = Val $R.ip '127.0.0.1';         $serverIp  = Val $N.ip '0.0.0.0'
$launchArgs = @(
    '-batchmode', '-nographics',
    "+server.identity `"$identity`"",
    "+server.ip $serverIp", "+server.port $gamePort", "+server.queryport $queryPort",
    "+server.level `"$(Val $S.level 'Procedural Map')`"",
    "+server.worldsize $([int](Val $S.worldSize 3500))", "+server.seed $seed",
    "+rcon.ip $rconIp", "+rcon.port $rconPort", "+rcon.web $(if ($R.web -eq $false) { 0 } else { 1 })",
    "+rcon.password `"$rconPw`"",
    "+app.port $appPort",
    "-logfile `"%~dp0logs\server_$identity.log`""
)
$start = @('@echo off', "title $($identity) - Rust Server", 'cd /d "%~dp0rustserver"', ':start',
    ('"%~dp0rustserver\RustDedicated.exe" ' + ($launchArgs -join ' ')))
if ($RT.autoRestart -ne $false) {
    $start += @('echo Sunucu kapandi, 10 sn icinde yeniden baslatiliyor... (Ctrl+C ile iptal)', 'timeout /t 10', 'goto start')
}
[IO.File]::WriteAllText((Join-Path $Base 'start_server.bat'), ($start -join "`r`n") + "`r`n", [Text.Encoding]::ASCII)
[IO.File]::WriteAllText((Join-Path $Base 'update_server.bat'),
    "@echo off`r`nrem Guncelleme = kurulumu tekrar calistirmak (idempotent).`r`ncall `"%~dp0kurulum.bat`" %*`r`n", [Text.Encoding]::ASCII)
Ok 'start_server.bat ve update_server.bat olusturuldu.'

# -------------------------------------------------------------- firewall
if ($RT.openFirewall -ne $false) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $rules = @(@{n="Game";p='UDP';port=$gamePort}, @{n="Query";p='UDP';port=$queryPort}, @{n="RustPlus";p='TCP';port=$appPort})
    if ($rconIp -ne '127.0.0.1') { $rules += @{n="RCON";p='TCP';port=$rconPort} }
    if ($isAdmin) {
        foreach ($r in $rules) {
            $name = "YSTCore Rust $identity $($r.n)"
            Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
            New-NetFirewallRule -DisplayName $name -Direction Inbound -Action Allow -Protocol $r.p -LocalPort $r.port | Out-Null
        }
        Ok "Guvenlik duvari kurallari eklendi: $(($rules | % { "$($_.port)/$($_.p)" }) -join ', ')"
    } else {
        Warn 'Yonetici olarak calismadigi icin guvenlik duvari kurallari eklenmedi.'
        Warn 'Eklemek icin kurulum.bat dosyasina sag tik > Yonetici olarak calistir.'
    }
}

# ----------------------------------------------------------------- bitti
Write-Host ''
Ok '======================= KURULUM TAMAM ======================='
Info "Baglanti   : client.connect <IP>:$gamePort   (yerel: 127.0.0.1:$gamePort)"
Info "RCON       : ws://$($rconIp):$rconPort  (sifre: .kurulum\state.json veya server_config.json)"
Info "Baslatma   : start_server.bat     Guncelleme: update_server.bat"
if ($RT.startAfterInstall -ne $false) {
    Info 'Sunucu yeni pencerede baslatiliyor (ilk acilis harita olusturma ile 3-10 dk surebilir)...'
    Start-Process -FilePath (Join-Path $Base 'start_server.bat') -WorkingDirectory $Base
}
exit 0
} catch {
    Write-Host "[ HATA  ] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

<#
  Ab1BaS NetCheck v1.1
  Диагностика сети для онлайн-игр.

  Скрипт ТОЛЬКО ЧИТАЕТ данные и ничего не меняет в системе.

  Что он делает:
   - пингует твой роутер и два сервера в интернете (1.1.1.1 и 8.8.8.8) раз в секунду, пока ты играешь;
   - смотрит сетевой адаптер, Wi-Fi, Bluetooth, DNS, VPN и прокси;
   - смотрит, какие программы сейчас держат сетевые соединения;
   - делает трассировку до 1.1.1.1 (pathping), чтобы увидеть, на каком участке теряются пакеты.

  Чего он НЕ делает:
   - ничего не скачивает и не устанавливает;
   - не меняет настройки Windows, адаптера, реестра, игр и антивируса;
   - никуда не отправляет данные: отчет сохраняется на рабочий стол и копируется в буфер обмена,
     дальше ты сам решаешь, кому его показать;
   - не собирает пароли, имя Wi-Fi сети, MAC-адреса, внешний IP, имя ПК и имя пользователя.

  Запуск: правой кнопкой по файлу -> "Выполнить с помощью PowerShell",
  или в окне PowerShell: powershell -ExecutionPolicy Bypass -File "$HOME\Downloads\Ab1BaS-NetCheck.ps1"
  (Bypass действует только на этот один запуск и ничего не меняет в системе.)

  Автор: Ab1BaS. Перепродажа запрещена.
#>

param([int]$Seconds = 300)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$Version = '1.1'

function Hide-Mac([string]$s) {
    if (-not $s) { return $s }
    return ($s -replace '([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}', 'XX-XX-XX-XX-XX-XX')
}

function Get-PingStat($list) {
    $all = @($list)
    $ok = @($all | Where-Object { $_ -ge 0 })
    $sent = $all.Count
    $lost = $sent - $ok.Count
    $res = [ordered]@{ Sent = $sent; Lost = $lost; LossPct = 0; Min = 0; Avg = 0; Med = 0; P95 = 0; Max = 0; Jit = 0; Sp50 = 0; Sp100 = 0 }
    if ($sent -gt 0) { $res.LossPct = [math]::Round(100 * $lost / $sent, 1) }
    if ($ok.Count -eq 0) { return [pscustomobject]$res }
    $sorted = @($ok | Sort-Object)
    $res.Min = $sorted[0]
    $res.Max = $sorted[-1]
    $res.Avg = [math]::Round(($ok | Measure-Object -Average).Average, 0)
    $res.Med = $sorted[[int][math]::Floor(($sorted.Count - 1) / 2)]
    $res.P95 = $sorted[[int][math]::Floor(($sorted.Count - 1) * 0.95)]
    $j = 0
    for ($k = 1; $k -lt $ok.Count; $k++) { $j += [math]::Abs($ok[$k] - $ok[$k - 1]) }
    if ($ok.Count -gt 1) { $res.Jit = [math]::Round($j / ($ok.Count - 1), 1) }
    $res.Sp50 = @($ok | Where-Object { $_ -ge $res.Med + 50 }).Count
    $res.Sp100 = @($ok | Where-Object { $_ -ge $res.Med + 100 }).Count
    return [pscustomobject]$res
}

function Test-Dns([string]$server) {
    $times = @()
    $fail = 0
    foreach ($d in 'steamcommunity.com', 'riotgames.com', 'epicgames.com', 'faceit.com', 'youtube.com') {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Resolve-DnsName -Name $d -Server $server -Type A -DnsOnly -QuickTimeout -ErrorAction SilentlyContinue
        $sw.Stop()
        if ($r) { $times += [int]$sw.ElapsedMilliseconds } else { $fail++ }
    }
    if ($times.Count -eq 0) { return "$server нет ответа" }
    $avg = [math]::Round(($times | Measure-Object -Average).Average, 0)
    $max = ($times | Measure-Object -Maximum).Maximum
    return "$server ср $avg / макс $max мс, ошибок $fail"
}

Clear-Host
Write-Host ''
Write-Host "  Ab1BaS NetCheck v$Version" -ForegroundColor Cyan
Write-Host '  Диагностика сети для игр. Скрипт только читает данные и ничего не меняет.' -ForegroundColor Gray
Write-Host ''
Write-Host '  [1/4] Смотрю подключение...' -ForegroundColor Yellow

$route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 |
    Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' } |
    Sort-Object { [int]$_.RouteMetric + [int]$_.InterfaceMetric } |
    Select-Object -First 1

if (-not $route) {
    Write-Host '  Не нашел подключение к интернету (нет шлюза). Проверь, что интернет работает, и запусти снова.' -ForegroundColor Red
    Read-Host '  Нажми Enter, чтобы закрыть'
    exit
}

$gw = [string]$route.NextHop
$ad = Get-NetAdapter -InterfaceIndex $route.ifIndex
$isWifi = ($ad.PhysicalMediaType -match '802\.11') -or ($ad.NdisPhysicalMedium -eq 9) -or ($ad.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN|802\.11')
$connType = if ($isWifi) { 'Wi-Fi' } else { 'Кабель (Ethernet)' }

$os = Get-CimInstance Win32_OperatingSystem
$osLine = "$($os.Caption) сборка $($os.BuildNumber)"

$powerLine = 'н/д'
try {
    Add-Type -AssemblyName System.Windows.Forms
    $ps = [System.Windows.Forms.SystemInformation]::PowerStatus
    if ([string]$ps.BatteryChargeStatus -match 'NoSystemBattery') { $powerLine = 'ПК (без батареи)' }
    else {
        $src = if ([string]$ps.PowerLineStatus -eq 'Online') { 'от сети' } else { 'ОТ БАТАРЕИ' }
        $powerLine = "Ноутбук, $src, заряд $([int]($ps.BatteryLifePercent * 100))%"
    }
} catch {}

$scheme = (powercfg /getactivescheme 2>$null | Out-String).Trim()
if ($scheme -match '\(([^)]+)\)') { $scheme = $Matches[1] }

$wifiPower = ''
$pq = powercfg /q SCHEME_CURRENT 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 2>$null | Out-String
$hx = @([regex]::Matches($pq, '0x[0-9a-fA-F]{8}') | ForEach-Object { [Convert]::ToInt32($_.Value, 16) })
$pwNames = @{ 0 = 'макс. производительность'; 1 = 'слабое энергосбережение'; 2 = 'среднее энергосбережение'; 3 = 'макс. энергосбережение' }
if ($hx.Count -ge 2) { $wifiPower = "от сети: $($pwNames[$hx[0]]), от батареи: $($pwNames[$hx[1]])" }

$wifiInfo = ''
if ($isWifi) {
    $wl = netsh wlan show interfaces 2>$null
    if (($wl | Out-String) -match 'privacy-location|WlanQueryInterface|error 5|ошибка 5') { $wifiInfo = 'Windows не дает данные Wi-Fi без разрешения на геолокацию (это необязательно, остальная диагностика работает)' }
    else {
        $wifiInfo = (@($wl | Where-Object { $_ -match ':' -and $_ -notmatch 'SSID|Profile|Профиль|Профіль|Physical address|Физический адрес|Фізична адреса|GUID' } |
            ForEach-Object { Hide-Mac (($_.Trim()) -replace '\s{2,}', ' ') } | Select-Object -First 22) -join '; ')
    }
}

$advInfo = (@(Get-NetAdapterAdvancedProperty -Name $ad.Name |
    Where-Object { $_.DisplayName -notmatch 'Network Address|Locally Administered|Сетевой адрес|Мережева адреса|MAC' } |
    ForEach-Object { "$($_.DisplayName)=$($_.DisplayValue)" }) -join '; ')

$btRadio = @(Get-PnpDevice -Class Bluetooth -PresentOnly | Where-Object { $_.Status -eq 'OK' -and $_.InstanceId -match '^(USB|PCI)\\' }).Count
$btAudio = @(Get-PnpDevice -Class Bluetooth | Where-Object { $_.InstanceId -match '0000110B|0000111E' } |
    ForEach-Object { if ($_.InstanceId -match '([0-9A-Fa-f]{12})_C') { $Matches[1] } } | Select-Object -Unique).Count
$btLine = if ($btRadio -gt 0) { "адаптер есть, сопряженных аудио-устройств: $btAudio" } else { 'не найден или выключен' }

$vpn = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -match 'VPN|WireGuard|TAP-|Wintun|TUN|WARP|Cloudflare|ZeroTier|Hamachi|Radmin|OpenVPN|Fortinet|AnyConnect|Proton|Nord|Express|Kaspersky|Hotspot|Outline|Amnezia|Tailscale|Hiddify|v2ray|Xray' } |
    ForEach-Object { $_.InterfaceDescription })
$proxyOn = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings').ProxyEnable -eq 1
$vpnLine = if ($vpn.Count) { 'VPN/туннель: ' + ($vpn -join ', ') } else { 'VPN: нет' }
$vpnLine += if ($proxyOn) { '; системный прокси: ВКЛ' } else { '; прокси: нет' }

$conn = @(Get-NetTCPConnection -State Established | Where-Object { $_.RemoteAddress -notmatch '^(127\.|::1)' })
$procNames = @{}
foreach ($c in $conn) {
    $p = Get-Process -Id $c.OwningProcess
    $n = if ($p) { $p.ProcessName } else { 'pid' + $c.OwningProcess }
    if ($procNames.ContainsKey($n)) { $procNames[$n]++ } else { $procNames[$n] = 1 }
}
$topProc = ($procNames.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 10 | ForEach-Object { "$($_.Key)($($_.Value))" }) -join ' '
$heavy = @(Get-Process | Where-Object { $_.ProcessName -match '^(qbittorrent|utorrent|bittorrent|transmission|tixati|biglybt|deluge|onedrive|dropbox|googledrivefs|yandexdisk|megasync|epicgameslauncher|battle\.net|eadesktop|ubisoftconnect|upc|galaxyclient|wgc|lghub_updater)$' } |
    ForEach-Object { $_.ProcessName } | Select-Object -Unique)
$heavyLine = if ($heavy.Count) { $heavy -join ', ' } else { 'нет' }

Write-Host '  [2/4] Проверяю DNS...' -ForegroundColor Yellow
$dnsList = @((Get-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -AddressFamily IPv4).ServerAddresses)
$dnsTests = @()
$tested = @()
foreach ($s in @($dnsList | Select-Object -First 1) + '1.1.1.1' + '8.8.8.8') {
    if ($s -and $tested -notcontains $s) { $dnsTests += Test-Dns $s; $tested += $s }
}

Write-Host ''
Write-Host '  [3/4] Главный тест: замер связи во время игры.' -ForegroundColor Yellow
Write-Host "  Зайди в игру и начни обычный матч. Тест идет $([int]($Seconds / 60)) мин." -ForegroundColor White
Write-Host '  Окно не закрывай, просто сверни его. В конце будет звуковой сигнал.' -ForegroundColor White
Read-Host '  Нажми Enter, чтобы начать'

$job = Start-Job -ScriptBlock { pathping -n -q 25 -p 150 -w 800 1.1.1.1 2>&1 }

$targets = @($gw, '1.1.1.1', '8.8.8.8')
$pingers = @{}
$data = @{}
foreach ($t in $targets) { $pingers[$t] = New-Object System.Net.NetworkInformation.Ping; $data[$t] = New-Object System.Collections.Generic.List[int] }
$rx = New-Object System.Collections.Generic.List[double]
$tx = New-Object System.Collections.Generic.List[double]

$st0 = Get-NetAdapterStatistics -Name $ad.Name
$prevRx = [double]$st0.ReceivedBytes
$prevTx = [double]$st0.SentBytes
$prevT = Get-Date
$start = Get-Date
$end = $start.AddSeconds($Seconds)

while ((Get-Date) -lt $end) {
    $tick = [Diagnostics.Stopwatch]::StartNew()
    $tasks = @{}
    foreach ($t in $targets) { $tasks[$t] = $pingers[$t].SendPingAsync($t, 1000) }
    [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($tasks.Values), 1500)
    foreach ($t in $targets) {
        $tk = $tasks[$t]
        if ($tk.Status -eq 'RanToCompletion' -and $tk.Result.Status -eq 'Success') { $data[$t].Add([int]$tk.Result.RoundtripTime) }
        else { $data[$t].Add(-1) }
    }
    $st = Get-NetAdapterStatistics -Name $ad.Name
    $now = Get-Date
    $dt = ($now - $prevT).TotalSeconds
    if ($dt -le 0) { $dt = 1 }
    $rx.Add([math]::Round((([double]$st.ReceivedBytes - $prevRx) * 8 / 1e6) / $dt, 2))
    $tx.Add([math]::Round((([double]$st.SentBytes - $prevTx) * 8 / 1e6) / $dt, 2))
    $prevRx = [double]$st.ReceivedBytes
    $prevTx = [double]$st.SentBytes
    $prevT = $now
    $left = [int]($end - $now).TotalSeconds
    if ($left -lt 0) { $left = 0 }
    $last = $data[$targets[1]][$data[$targets[1]].Count - 1]
    $lastTxt = if ($last -ge 0) { "$last мс" } else { 'потеря' }
    Write-Host -NoNewline ("`r  Осталось: {0,3} с | пинг до интернета сейчас: {1,-8}   " -f $left, $lastTxt)
    $rest = 1000 - [int]$tick.ElapsedMilliseconds
    if ($rest -gt 0) { Start-Sleep -Milliseconds $rest }
}
Write-Host ''
try { [Console]::Beep(880, 250); [Console]::Beep(1100, 350) } catch {}

Write-Host '  [4/4] Дожидаюсь трассировки и собираю отчет...' -ForegroundColor Yellow
[void](Wait-Job $job -Timeout 150)
$pp = @(Receive-Job $job)
Remove-Job $job -Force
$hops = @()
foreach ($line in $pp) {
    if ([string]$line -match '^\s*(\d+)\s+(\S+)\s+\d+/\s*\d+\s*=\s*(\d+)%\s+\d+/\s*\d+\s*=\s*(\d+)%\s+(\S+)') {
        if ($Matches[2] -match '^-+$') { $hops += "$($Matches[1]): узел не отвечает на пинг, это нормально ($($Matches[5]))" }
        else { $hops += "$($Matches[1]): $($Matches[2]) потери до узла $($Matches[3])%, на узле $($Matches[4])% ($($Matches[5]))" }
    }
}
$hopsLine = if ($hops.Count) { $hops -join ' | ' } else { 'не удалось получить' }

$sG = Get-PingStat $data[$gw]
$sA = Get-PingStat $data['1.1.1.1']
$sB = Get-PingStat $data['8.8.8.8']

$n = $data[$gw].Count
$netSp = 0; $withGw = 0; $withLoad = 0
$gwSpikeIdx = @()
$worst = @()
for ($k = 0; $k -lt $n; $k++) {
    $g = $data[$gw][$k]; $a = $data['1.1.1.1'][$k]; $b = $data['8.8.8.8'][$k]
    $gSp = ($g -lt 0) -or ($g -ge $sG.Med + 30)
    $aSp = ($a -lt 0) -or ($a -ge $sA.Med + 50)
    if ($gSp) { $gwSpikeIdx += $k }
    $load = ($rx[$k] + $tx[$k]) -ge 5
    if ($aSp) {
        $netSp++
        if ($gSp) { $withGw++ }
        if ($load) { $withLoad++ }
    }
    if ($gSp -or $aSp) {
        $fmt = { param($v) if ($v -lt 0) { 'потеря' } else { "$v" } }
        $score = [math]::Max($(if ($g -lt 0) { 999 } else { $g - $sG.Med }), $(if ($a -lt 0) { 999 } else { $a - $sA.Med }))
        $worst += [pscustomobject]@{ S = $score; T = "t=$($k)с роутер $(& $fmt $g) / 1.1.1.1 $(& $fmt $a) / 8.8.8.8 $(& $fmt $b) / трафик $($rx[$k])v $($tx[$k])^" }
    }
}
$worstLine = (@($worst | Sort-Object S -Descending | Select-Object -First 8 | ForEach-Object { $_.T }) -join '; ')
if (-not $worstLine) { $worstLine = 'нет' }

$intervalLine = 'н/д'
if ($gwSpikeIdx.Count -ge 3) {
    $iv = @()
    for ($k = 1; $k -lt $gwSpikeIdx.Count; $k++) { if ($gwSpikeIdx[$k] - $gwSpikeIdx[$k - 1] -gt 1) { $iv += $gwSpikeIdx[$k] - $gwSpikeIdx[$k - 1] } }
    if ($iv.Count) { $ivs = @($iv | Sort-Object); $intervalLine = "~$($ivs[[int][math]::Floor(($ivs.Count - 1) / 2)]) с" }
}

$rxAvg = [math]::Round(($rx | Measure-Object -Average).Average, 2)
$txAvg = [math]::Round(($tx | Measure-Object -Average).Average, 2)
$rxMax = ($rx | Measure-Object -Maximum).Maximum
$txMax = ($tx | Measure-Object -Maximum).Maximum

$fmtS = { param($name, $s) "$name потери $($s.Lost)/$($s.Sent) ($($s.LossPct)%), мин/сред/95%/макс $($s.Min)/$($s.Avg)/$($s.P95)/$($s.Max), джиттер $($s.Jit), скачки +50:$($s.Sp50) +100:$($s.Sp100)" }

$verdict = 'Во время теста явных проблем со связью не видно. Если лаги были, напиши, в какой момент.'
$localBad = ($sG.LossPct -ge 1) -or ($sG.Sp50 -ge 3)
$netBad = ($sA.LossPct -ge 1) -or ($sB.LossPct -ge 1) -or ($sA.Sp50 -ge 3)
if ($localBad) { $verdict = 'Проблема похожа на локальную: связь ПК с роутером (Wi-Fi, адаптер, драйвер или сам роутер).' }
elseif ($netBad -and $withLoad -ge [math]::Max(2, [int]($netSp / 2))) { $verdict = 'Скачки совпадают с загрузкой канала: что-то качает или роутер не справляется с нагрузкой.' }
elseif ($netBad) { $verdict = 'До роутера все чисто, проблема дальше: провайдер или маршрут до серверов.' }

$report = @"
=== Ab1BaS NetCheck v$Version ===
Дата: $($start.ToString('yyyy-MM-dd HH:mm')) | тест $Seconds с
Система: $osLine | $powerLine | схема питания: $scheme
Подключение: $connType | $($ad.InterfaceDescription) | $($ad.LinkSpeed) | драйвер $($ad.DriverVersionString) от $($ad.DriverDate)
Энергосбережение Wi-Fi: $wifiPower
Wi-Fi: $wifiInfo
Адаптер: $advInfo
Bluetooth: $btLine
DNS: $($dnsList -join ', ') | $($dnsTests -join '; ')
$vpnLine
Соединения программ: $topProc
Фоновые качалки: $heavyLine
Трафик за тест, Мбит/с: ср вход $rxAvg / выход $txAvg, пик $rxMax / $txMax
ПИНГ, мс:
$(& $fmtS "Роутер $gw" $sG)
$(& $fmtS '1.1.1.1' $sA)
$(& $fmtS '8.8.8.8' $sB)
Скачки до интернета: $netSp, из них вместе со скачком до роутера: $withGw, при загрузке канала: $withLoad
Интервал между скачками роутера: $intervalLine
Худшие моменты: $worstLine
Маршрут: $hopsLine
Предварительно: $verdict
"@

$report = Hide-Mac $report

$file = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Ab1BaS-NetCheck.txt'
$report | Out-File -FilePath $file -Encoding utf8
$copied = $false
try { Set-Clipboard -Value $report; $copied = $true } catch {}

Write-Host ''
Write-Host $report
Write-Host ''
if ($copied) { Write-Host '  Готово. Отчет уже скопирован: вставь его (Ctrl+V) в чат FunPay.' -ForegroundColor Green }
else { Write-Host '  Готово. Скопируй отчет из файла на рабочем столе и вставь в чат FunPay.' -ForegroundColor Green }
Write-Host '  Копия отчета: файл Ab1BaS-NetCheck.txt на рабочем столе.' -ForegroundColor Gray
Write-Host ''
Read-Host '  Нажми Enter, чтобы закрыть'

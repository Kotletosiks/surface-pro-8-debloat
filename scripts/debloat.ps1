param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('snapshot', 'restorepoint', 'telemetry', 'services', 'ads', 'extras', 'undo', 'all')]
    [string]$Step
)

# Debloat engine for Windows 11 (Surface Pro 8). Called by the .bat files.
# Every change is logged to C:\Debloat\logs and the original value is saved to C:\Debloat\state\undo.tsv

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$Root     = Join-Path $env:SystemDrive 'Debloat'
$LogDir   = Join-Path $Root 'logs'
$StateDir = Join-Path $Root 'state'
$UndoFile = Join-Path $StateDir 'undo.tsv'
$RpMarker = Join-Path $StateDir 'restorepoint.ok'
New-Item -ItemType Directory -Force -Path $LogDir, $StateDir | Out-Null
$Stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogFile = Join-Path $LogDir ("{0}_{1}.log" -f $Step, $Stamp)

$script:cOk = 0
$script:cSkip = 0
$script:cFail = 0

function Write-Log([string]$level, [string]$msg) {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $level, $msg
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    switch ($level) {
        'OK'   { Write-Host $line -ForegroundColor Green }
        'SKIP' { Write-Host $line -ForegroundColor Yellow }
        'WARN' { Write-Host $line -ForegroundColor Yellow }
        'FAIL' { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line }
    }
}

function Save-Undo([string]$kind, [string]$target, [string]$orig) {
    $key = "$kind`t$target`t"
    if (Test-Path -LiteralPath $UndoFile) {
        if (Select-String -LiteralPath $UndoFile -SimpleMatch -Pattern $key -Quiet) { return }
    }
    Add-Content -LiteralPath $UndoFile -Value ("$kind`t$target`t$orig") -Encoding UTF8
}

# ---------- primitives ----------

function Disable-Svc([string]$name) {
    $svc = Get-CimInstance Win32_Service -Filter "Name='$name'" -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Log 'SKIP' "Служба $name не найдена на этой сборке"
        $script:cSkip++
        return
    }
    $orig = 'demand'
    switch ($svc.StartMode) {
        'Auto'     { if ($svc.DelayedAutoStart) { $orig = 'delayed-auto' } else { $orig = 'auto' } }
        'Manual'   { $orig = 'demand' }
        'Disabled' { $orig = 'disabled' }
    }
    if ($orig -eq 'disabled') {
        Write-Log 'SKIP' "Служба $name уже отключена"
        $script:cSkip++
        return
    }
    Save-Undo 'svc' $name $orig
    try {
        if ($svc.State -eq 'Running') { Stop-Service -Name $name -Force -ErrorAction Stop }
    } catch {
        Write-Log 'INFO' "Не удалось остановить $name прямо сейчас ($($_.Exception.Message)); запуск отключу, остановится после перезагрузки"
    }
    $out = & sc.exe config $name start= disabled 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Log 'OK' "Служба $name ($($svc.DisplayName)): было '$orig' -> disabled"
        $script:cOk++
    } else {
        Write-Log 'FAIL' "Служба ${name}: sc config вернул код $LASTEXITCODE : $out"
        $script:cFail++
    }
}

function Disable-Task([string]$full) {
    $path = (Split-Path $full -Parent) + '\'
    $name = Split-Path $full -Leaf
    $t = Get-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction SilentlyContinue
    if (-not $t) {
        Write-Log 'SKIP' "Задача $full не найдена"
        $script:cSkip++
        return
    }
    if ($t.State -eq 'Disabled') {
        Write-Log 'SKIP' "Задача $full уже отключена"
        $script:cSkip++
        return
    }
    Save-Undo 'task' $full 'enabled'
    try {
        Disable-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction Stop | Out-Null
        Write-Log 'OK' "Задача ${full}: было '$($t.State)' -> Disabled"
        $script:cOk++
    } catch {
        Write-Log 'FAIL' "Задача ${full}: $($_.Exception.Message)"
        $script:cFail++
    }
}

function Set-Reg([string]$path, [string]$name, $value, [string]$type = 'DWord') {
    try {
        $exists = $false
        $old = $null
        if (Test-Path -Path $path) {
            $prop = Get-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue
            if ($null -ne $prop) { $exists = $true; $old = $prop.$name }
        }
        if ($exists -and ("$old" -eq "$value")) {
            Write-Log 'SKIP' "Реестр $path\$name уже = $value"
            $script:cSkip++
            return
        }
        if ($exists) { $orig = "$old" } else { $orig = '<absent>' }
        Save-Undo 'reg' "$path|$name|$type" $orig
        if (-not (Test-Path -Path $path)) { New-Item -Path $path -Force | Out-Null }
        New-ItemProperty -Path $path -Name $name -Value $value -PropertyType $type -Force | Out-Null
        Write-Log 'OK' "Реестр $path\${name}: было '$orig' -> $value"
        $script:cOk++
    } catch {
        Write-Log 'FAIL' "Реестр $path\${name}: $($_.Exception.Message)"
        $script:cFail++
    }
}

# ---------- steps ----------

function Do-Snapshot([string]$title) {
    Write-Log 'INFO' "=== Снимок состояния: $title ==="
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    Write-Log 'INFO' "Устройство: $($cs.Manufacturer) $($cs.Model)"
    Write-Log 'INFO' "ОС: $($os.Caption) build $($os.BuildNumber), пользователь: $env:USERNAME"
    $totalMb = [math]::Round($os.TotalVisibleMemorySize / 1024)
    $freeMb  = [math]::Round($os.FreePhysicalMemory / 1024)
    Write-Log 'INFO' "Память: всего $totalMb МБ, свободно $freeMb МБ, занято $($totalMb - $freeMb) МБ"
    foreach ($d in (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3')) {
        $sz = [math]::Round($d.Size / 1GB, 1)
        $fr = [math]::Round($d.FreeSpace / 1GB, 1)
        Write-Log 'INFO' "Диск $($d.DeviceID): всего $sz ГБ, свободно $fr ГБ"
    }
    try {
        foreach ($pd in (Get-PhysicalDisk -ErrorAction Stop)) {
            Write-Log 'INFO' "Накопитель: $($pd.FriendlyName), тип $($pd.MediaType), состояние $($pd.HealthStatus)"
        }
    } catch {}
    $running = @(Get-CimInstance Win32_Service | Where-Object { $_.State -eq 'Running' }).Count
    $procs = @(Get-Process).Count
    $startup = @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue).Count
    Write-Log 'INFO' "Процессов: $procs, служб запущено: $running, записей автозагрузки: $startup"
    Write-Log 'INFO' 'Топ-15 процессов по памяти:'
    Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 15 | ForEach-Object {
        Write-Log 'INFO' ("   {0,-30} {1,7} МБ" -f $_.ProcessName, [math]::Round($_.WorkingSet64 / 1MB))
    }
    $safe = $title -replace '[^A-Za-z0-9_-]', '_'
    $csv = Join-Path $LogDir ("services_{0}_{1}.csv" -f $safe, $Stamp)
    Get-CimInstance Win32_Service | Select-Object Name, DisplayName, StartMode, State |
        Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
    Write-Log 'INFO' "Полный список служб сохранён: $csv"
}

function Do-RestorePoint {
    $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $prop = 'SystemRestorePointCreationFrequency'
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop | Out-Null
        $old = $null
        $p = Get-ItemProperty -Path $k -Name $prop -ErrorAction SilentlyContinue
        if ($null -ne $p) { $old = $p.$prop }
        New-ItemProperty -Path $k -Name $prop -Value 0 -PropertyType DWord -Force | Out-Null
        Checkpoint-Computer -Description "Debloat $Stamp" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop | Out-Null
        if ($null -ne $old) {
            New-ItemProperty -Path $k -Name $prop -Value $old -PropertyType DWord -Force | Out-Null
        } else {
            Remove-ItemProperty -Path $k -Name $prop -ErrorAction SilentlyContinue
        }
        $last = Get-ComputerRestorePoint | Sort-Object SequenceNumber | Select-Object -Last 1
        Write-Log 'OK' "Точка восстановления создана: '$($last.Description)' (№$($last.SequenceNumber))"
        Set-Content -LiteralPath $RpMarker -Value $Stamp
        $script:cOk++
        return $true
    } catch {
        Write-Log 'FAIL' "Точка восстановления не создана: $($_.Exception.Message)"
        $script:cFail++
        return $false
    }
}

function Do-Telemetry {
    Write-Log 'INFO' '=== Телеметрия: политики реестра ==='
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat' 'AITEnable' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat' 'DisableInventory' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows' 'CEIPEnable' 0
    Write-Log 'INFO' '=== Телеметрия: службы ==='
    foreach ($s in 'DiagTrack', 'dmwappushservice', 'WerSvc', 'diagnosticshub.standardcollector.service') { Disable-Svc $s }
    Write-Log 'INFO' '=== Телеметрия: задачи планировщика ==='
    $tasks = @(
        '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
        '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
        '\Microsoft\Windows\Customer Experience Improvement Program\KernelCeipTask',
        '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
        '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
        '\Microsoft\Windows\Autochk\Proxy',
        '\Microsoft\Windows\Feedback\Siuf\DmClient',
        '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload',
        '\Microsoft\Windows\Windows Error Reporting\QueueReporting',
        '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector'
    )
    foreach ($t in $tasks) { Disable-Task $t }
}

function Do-Services {
    Write-Log 'INFO' '=== Ненужные фоновые службы ==='
    foreach ($s in 'MapsBroker', 'RetailDemo', 'Fax', 'XblAuthManager', 'XblGameSave', 'XboxNetApiSvc', 'SysMain') { Disable-Svc $s }
}

function Do-Ads {
    Write-Log 'INFO' '=== Реклама, советы, рекомендуемые приложения ==='
    Write-Log 'INFO' "Пользователь для настроек HKCU: $env:USERNAME"
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    foreach ($n in 'SilentInstalledAppsEnabled', 'SystemPaneSuggestionsEnabled', 'SoftLandingEnabled', 'OemPreInstalledAppsEnabled', 'PreInstalledAppsEnabled',
                   'SubscribedContent-338387Enabled', 'SubscribedContent-338388Enabled', 'SubscribedContent-338389Enabled',
                   'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled', 'SubscribedContent-310093Enabled') {
        Set-Reg $cdm $n 0
    }
    $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    Set-Reg $adv 'Start_IrisRecommendations' 0
    Set-Reg $adv 'ShowSyncProviderNotifications' 0
    Write-Log 'INFO' '=== Фоновая работа приложений ==='
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsRunInBackground' 2
}

function Remove-OneDrive {
    Write-Log 'INFO' '--- OneDrive ---'
    $dirs = @(Get-ChildItem -LiteralPath $env:USERPROFILE -Directory -Filter 'OneDrive*' -Force -ErrorAction SilentlyContinue)
    $cloud = 0
    foreach ($d in $dirs) {
        Write-Log 'INFO' "Проверяю папку $($d.FullName) на файлы, которые лежат только в облаке..."
        $cloud += @(Get-ChildItem -LiteralPath $d.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { ($_.Attributes.value__ -band 0x441000) -ne 0 }).Count
    }
    if ($cloud -gt 0) {
        Write-Log 'SKIP' "OneDrive НЕ удалён: найдено файлов только в облаке: $cloud. После удаления они пропали бы с этого компьютера. Скачай их (ПКМ по папке -> 'Всегда хранить на этом устройстве') и запусти 05_extras.bat ещё раз."
        $script:cSkip++
        return
    }
    foreach ($kf in 'Desktop', 'MyDocuments', 'MyPictures') {
        $p = [Environment]::GetFolderPath($kf)
        if ($p -like '*OneDrive*') { Write-Log 'WARN' "Папка $kf сейчас находится внутри OneDrive ($p). Файлы останутся на диске, но проверь их после удаления." }
    }
    $exe = @("$env:SystemRoot\SysWOW64\OneDriveSetup.exe", "$env:SystemRoot\System32\OneDriveSetup.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $exe) {
        Write-Log 'SKIP' 'Установщик OneDriveSetup.exe не найден, OneDrive уже удалён или не установлен'
        $script:cSkip++
        return
    }
    Save-Undo 'onedrive' $exe 'reinstall'
    try {
        Stop-Process -Name 'OneDrive' -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        $proc = Start-Process -FilePath $exe -ArgumentList '/uninstall' -Wait -PassThru -ErrorAction Stop
        Write-Log 'OK' "OneDrive удалён (код завершения $($proc.ExitCode)). Файлы в папке OneDrive не тронуты."
        $script:cOk++
    } catch {
        Write-Log 'FAIL' "OneDrive: $($_.Exception.Message)"
        $script:cFail++
    }
}

function Do-Extras {
    Write-Log 'INFO' '=== Индексация поиска ==='
    Disable-Svc 'WSearch'
    Write-Log 'INFO' '=== OneDrive ==='
    Remove-OneDrive
    Write-Log 'INFO' '=== Виджеты (Widgets) ==='
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
    Stop-Process -Name 'Widgets', 'WidgetService' -Force -ErrorAction SilentlyContinue
    Write-Log 'INFO' '=== Поиск Windows: убираю интернет-подсказки и облачный поиск ==='
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0
    $ss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings'
    Set-Reg $ss 'IsDynamicSearchBoxEnabled' 0
    Set-Reg $ss 'IsAADCloudSearchEnabled' 0
    Set-Reg $ss 'IsMSACloudSearchEnabled' 0
}

function Do-Undo {
    Write-Log 'INFO' '=== Откат изменений по файлу состояния ==='
    if (-not (Test-Path -LiteralPath $UndoFile)) {
        Write-Log 'FAIL' "Файл $UndoFile не найден: откатывать нечего (или ты ещё ничего не запускала). Можно откатиться через точку восстановления Windows."
        $script:cFail++
        return
    }
    $lines = @(Get-Content -LiteralPath $UndoFile -Encoding UTF8 | Where-Object { $_.Trim() })
    [array]::Reverse($lines)
    foreach ($l in $lines) {
        $parts = $l -split "`t", 3
        if ($parts.Count -lt 3) { continue }
        $kind = $parts[0]; $target = $parts[1]; $orig = $parts[2]
        try {
            switch ($kind) {
                'svc' {
                    $out = & sc.exe config $target start= $orig 2>&1
                    if ($LASTEXITCODE -eq 0) { Write-Log 'OK' "Служба ${target}: возвращено '$orig'"; $script:cOk++ }
                    else { Write-Log 'FAIL' "Служба ${target}: код $LASTEXITCODE : $out"; $script:cFail++ }
                }
                'task' {
                    $path = (Split-Path $target -Parent) + '\'
                    $name = Split-Path $target -Leaf
                    Enable-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction Stop | Out-Null
                    Write-Log 'OK' "Задача ${target}: включена обратно"
                    $script:cOk++
                }
                'reg' {
                    $rp = $target -split '\|'
                    $path = $rp[0]; $name = $rp[1]; $type = $rp[2]
                    if ($orig -eq '<absent>') {
                        Remove-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue
                        Write-Log 'OK' "Реестр $path\${name}: значение удалено (как было)"
                    } else {
                        if ($type -eq 'DWord') { $val = [int]$orig } else { $val = $orig }
                        if (-not (Test-Path -Path $path)) { New-Item -Path $path -Force | Out-Null }
                        New-ItemProperty -Path $path -Name $name -Value $val -PropertyType $type -Force | Out-Null
                        Write-Log 'OK' "Реестр $path\${name}: возвращено '$orig'"
                    }
                    $script:cOk++
                }
                'onedrive' {
                    if (Test-Path -LiteralPath $target) {
                        Start-Process -FilePath $target -ErrorAction Stop
                        Write-Log 'OK' 'OneDrive: запущена переустановка'
                        $script:cOk++
                    } else {
                        Write-Log 'SKIP' "OneDrive: установщик $target не найден; скачай OneDrive с сайта Microsoft"
                        $script:cSkip++
                    }
                }
            }
        } catch {
            Write-Log 'FAIL' "Откат '$l': $($_.Exception.Message)"
            $script:cFail++
        }
    }
    $done = Join-Path $StateDir ("undo_done_{0}.tsv" -f $Stamp)
    Move-Item -LiteralPath $UndoFile -Destination $done -Force
    Write-Log 'INFO' "Файл состояния архивирован: $done"
    Write-Log 'INFO' 'Перезагрузи Surface, чтобы службы вернулись в работу.'
}

# ---------- main ----------

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Log 'INFO' "Шаг: $Step | лог: $LogFile"
if (-not $isAdmin) {
    Write-Log 'FAIL' 'Нужны права администратора. Запусти .bat двойным кликом и подтверди окно UAC.'
    exit 1
}

if ($Step -in 'telemetry', 'services', 'ads', 'extras') {
    if (-not (Test-Path -LiteralPath $RpMarker)) {
        Write-Log 'FAIL' 'Точка восстановления ещё не создана. Сначала запусти 01_restore_point.bat (или run_all.bat).'
        exit 1
    }
}

switch ($Step) {
    'snapshot'     { Do-Snapshot 'before' }
    'restorepoint' { if (-not (Do-RestorePoint)) { exit 1 } }
    'telemetry'    { Do-Telemetry }
    'services'     { Do-Services }
    'ads'          { Do-Ads }
    'extras'       { Do-Extras }
    'undo'         { Do-Undo }
    'all' {
        Do-Snapshot 'before'
        if (-not (Do-RestorePoint)) {
            Write-Log 'FAIL' 'Без точки восстановления дальше не иду. Ничего не изменено.'
            exit 1
        }
        Do-Telemetry
        Do-Services
        Do-Ads
        Do-Extras
        Do-Snapshot 'after'
    }
}

Write-Log 'INFO' ("ИТОГО: успешно={0}, пропущено={1}, ошибок={2}" -f $script:cOk, $script:cSkip, $script:cFail)
Write-Log 'INFO' "Лог сохранён: $LogFile"
if ($Step -notin 'snapshot', 'undo') { Write-Log 'INFO' 'Перезагрузи Surface, чтобы изменения вступили в силу полностью.' }
if ($script:cFail -gt 0) { exit 2 } else { exit 0 }

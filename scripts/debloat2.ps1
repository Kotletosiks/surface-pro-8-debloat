param(
    [ValidateSet('apps', 'startup', 'services2', 'fastboot', 'cleanup', 'simfix', 'undo', 'all')]
    [string]$Step = 'all'
)
# Debloat - vtoraya volna. Vse izmeneniya pishutsya v C:\Debloat\state\undo2.tsv
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$Root     = Join-Path $env:SystemDrive 'Debloat'
$LogDir   = Join-Path $Root 'logs'
$StateDir = Join-Path $Root 'state'
$ParkDir  = Join-Path $StateDir 'startup_disabled'
foreach ($d in @($LogDir, $StateDir, $ParkDir)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
$UndoFile = Join-Path $StateDir 'undo2.tsv'
$LogFile  = Join-Path $LogDir ("wave2_{0}_{1}.log" -f $Step, (Get-Date -Format 'yyyyMMdd_HHmmss'))
$script:OkCount = 0; $script:SkipCount = 0; $script:FailCount = 0

function Say([string]$level, [string]$msg) {
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $level, $msg
    switch ($level) {
        'OK'   { Write-Host $line -ForegroundColor Green;  $script:OkCount++ }
        'SKIP' { Write-Host $line -ForegroundColor Yellow; $script:SkipCount++ }
        'FAIL' { Write-Host $line -ForegroundColor Red;    $script:FailCount++ }
        default { Write-Host $line }
    }
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}
function Keep([string]$kind, [string]$target, [string]$orig) {
    Add-Content -Path $UndoFile -Value ("{0}`t{1}`t{2}" -f $kind, $target, $orig) -Encoding UTF8
}

# ---------- primitivy ----------
function SetReg([string]$path, [string]$name, $value, [string]$type = 'DWord') {
    try {
        if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
        $cur = (Get-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue).$name
        if ($null -eq $cur) { $orig = '<absent>' } else { $orig = [string]$cur }
        if ($orig -eq [string]$value) { Say 'SKIP' "Реестр $path\$name уже = $value"; return }
        Keep 'reg' ("{0}|{1}|{2}" -f $path, $name, $type) $orig
        New-ItemProperty -Path $path -Name $name -Value $value -PropertyType $type -Force | Out-Null
        Say 'OK' "Реестр $path\$name : было '$orig' -> $value"
    } catch { Say 'FAIL' "Реестр $path\$name : $($_.Exception.Message)" }
}

function SetSvc([string]$name, [string]$mode) {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if (-not $svc) { Say 'SKIP' "Служба $name не найдена"; return }
    $cim = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $name) -ErrorAction SilentlyContinue
    $orig = 'demand'
    switch ($svc.StartType) {
        'Automatic' { if ($cim -and $cim.DelayedAutoStart) { $orig = 'delayed-auto' } else { $orig = 'auto' } }
        'Manual'    { $orig = 'demand' }
        'Disabled'  { $orig = 'disabled' }
    }
    if ($orig -eq $mode) { Say 'SKIP' "Служба $name уже '$mode'"; return }
    try {
        Keep 'svc' $name $orig
        & sc.exe config $name start= $mode | Out-Null
        if ($mode -eq 'disabled') { Stop-Service -Name $name -Force -ErrorAction SilentlyContinue }
        Say 'OK' "Служба $name ($($svc.DisplayName)): было '$orig' -> $mode"
    } catch { Say 'FAIL' "Служба $name : $($_.Exception.Message)" }
}

function OffTask([string]$path, [string]$name) {
    $t = Get-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction SilentlyContinue
    if (-not $t) { Say 'SKIP' "Задача $path$name не найдена"; return }
    if ($t.State -eq 'Disabled') { Say 'SKIP' "Задача $path$name уже отключена"; return }
    try {
        Keep 'task' ($path + $name) 'enabled'
        Disable-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction Stop | Out-Null
        Say 'OK' "Задача $path$name отключена"
    } catch { Say 'FAIL' "Задача $path$name : $($_.Exception.Message)" }
}

function KillAppx([string]$name) {
    $hit = $false
    foreach ($pkg in (Get-AppxPackage -Name $name -AllUsers -ErrorAction SilentlyContinue)) {
        $hit = $true
        try {
            Keep 'appx' $pkg.PackageFullName $pkg.InstallLocation
            Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
            Say 'OK' "Приложение удалено: $($pkg.Name)"
        } catch { Say 'FAIL' "Приложение $($pkg.Name): $($_.Exception.Message)" }
    }
    foreach ($pp in (Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq $name })) {
        $hit = $true
        try {
            Keep 'appxprov' $pp.PackageName $pp.DisplayName
            Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName -ErrorAction Stop | Out-Null
            Say 'OK' "Убрано из образа (не поставится новым пользователям): $($pp.DisplayName)"
        } catch { Say 'FAIL' "Образ $($pp.DisplayName): $($_.Exception.Message)" }
    }
    if (-not $hit) { Say 'SKIP' "Приложение $name не установлено" }
}

function ParkStartupLink([string]$full) {
    if (-not (Test-Path $full)) { Say 'SKIP' "Ярлык автозагрузки не найден: $full"; return }
    $dest = Join-Path $ParkDir (Split-Path -Leaf $full)
    try {
        Keep 'file' $dest $full
        Move-Item -LiteralPath $full -Destination $dest -Force -ErrorAction Stop
        Say 'OK' "Из автозагрузки убран ярлык: $(Split-Path -Leaf $full)"
    } catch { Say 'FAIL' "Ярлык $full : $($_.Exception.Message)" }
}

# ---------- shagi ----------
function Do-Apps {
    Say 'INFO' '=== Удаление ненужных приложений Store ==='
    $list = @(
        'BytedancePte.Ltd.TikTok',
        '56869Yu-weiz.SketchCreator',
        'Clipchamp.Clipchamp',
        'Microsoft.BingNews',
        'Microsoft.BingSearch',
        'Microsoft.Copilot',
        'Microsoft.GamingApp',
        'Microsoft.XboxGameCallableUI',
        'Microsoft.MicrosoftJournal',
        'Microsoft.OutlookForWindows',
        'Microsoft.PowerAutomateDesktop',
        'Microsoft.Todos',
        'Microsoft.Windows.DevHome',
        'MSTeams',
        'MicrosoftCorporationII.QuickAssist',
        'MicrosoftWindows.Client.WebExperience',
        'MicrosoftWindows.CrossDevice',
        'Microsoft.StartExperiencesApp',
        'Microsoft.MSPaint',
        'Microsoft.OneDriveSync',
        'DolbyLaboratories.DolbyAccessOEM',
        'Microsoft.Windows.NarratorQuickStart',
        'Microsoft.ApplicationCompatibilityEnhancements'
    )
    foreach ($a in $list) { KillAppx $a }

    Say 'INFO' '=== Copilot как обычная программа ==='
    $cop = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
           Where-Object { $_.DisplayName -eq 'Copilot' }
    if ($cop) { Say 'INFO' "Copilot установлен как программа, удаляю политикой и пакетом Store (строка удаления: $($cop.UninstallString))" }
    else { Say 'SKIP' 'Copilot как обычная программа не найден' }
}

function Do-Startup {
    Say 'INFO' '=== Автозагрузка: ярлыки ==='
    ParkStartupLink (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup\RustDesk Tray.lnk')
    ParkStartupLink (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup\Tailscale.lnk')

    Say 'INFO' '=== Автозагрузка: скрытая задача Windows Terminal ==='
    SetReg 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData\Microsoft.WindowsTerminal_8wekyb3d8bbwe\StartTerminalOnLoginTask' 'State' 1

    Say 'INFO' '=== Задачи: рекламные подсказки и телеметрия Chrome ==='
    $junkTasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskPath -like '\SoftLanding\*' -or $_.TaskPath -like '\GoogleUserPEH\*'
    }
    if (-not $junkTasks) { Say 'SKIP' 'Задачи SoftLanding и GoogleUserPEH не найдены' }
    foreach ($t in $junkTasks) { OffTask $t.TaskPath $t.TaskName }

    Say 'INFO' '=== Edge: фоновый режим и ускоренный запуск ==='
    SetReg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' 0
    SetReg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' 0
    SetReg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'HubsSidebarEnabled' 0

    Say 'INFO' '=== Copilot и ИИ-функции ==='
    SetReg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
    SetReg 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
    SetReg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
    SetReg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'TurnOffSavingSnapshots' 1

    Say 'INFO' '=== Игровая запись Game Bar ==='
    SetReg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
    SetReg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
}

function Do-Services2 {
    Say 'INFO' '=== Вторая волна служб: отключаю ==='
    foreach ($s in @('InventorySvc', 'PcaSvc', 'TrkWks', 'LanmanServer', 'lfsvc',
                     'whesvc', 'WSAIFabricSvc', 'CDPSvc', 'TbtP2pShortcutService',
                     'igfxCUIService2.0.0.0')) { SetSvc $s 'disabled' }

    Say 'INFO' '=== Перевожу в ручной запуск (не стартуют сами, но работают по требованию) ==='
    foreach ($s in @('DoSvc', 'LGHUBUpdaterService')) { SetSvc $s 'demand' }

    Say 'INFO' 'НЕ ТРОГАЮ (нужны этому Surface): WwanSvc, SmsRouter, RmSvc, WUService (LTE-модем), SurfaceService, Spooler (печать), Defender, аудио Realtek/Intel/Dolby'
}

function Do-Fastboot {
    Say 'INFO' '=== Гибернация и быстрый запуск ==='
    if (Test-Path 'C:\hiberfil.sys') { Say 'SKIP' 'Гибернация уже включена, файл hiberfil.sys на месте' }
    else {
        try {
            Keep 'hib' 'hiberfil' 'off'
            & powercfg.exe /hibernate on 2>&1 | ForEach-Object { Say 'INFO' "powercfg /h on: $_" }
            Start-Sleep -Seconds 2
            if (Test-Path 'C:\hiberfil.sys') {
                & powercfg.exe /hibernate /size 40 2>&1 | ForEach-Object { Say 'INFO' "powercfg /size: $_" }
                $h = Get-Item 'C:\hiberfil.sys' -Force
                Say 'OK' ("Гибернация включена, hiberfil.sys = {0:N1} ГБ. Быстрый запуск Windows снова работает." -f ($h.Length / 1GB))
            } else {
                Say 'FAIL' 'powercfg отработал без ошибки, но файл hiberfil.sys не создан - смотри вывод powercfg /a ниже'
            }
        } catch { Say 'FAIL' "Гибернация: $($_.Exception.Message)" }
    }

    Say 'INFO' '--- Какие режимы сна доступны этому устройству (powercfg /a) ---'
    & powercfg.exe /a 2>&1 | ForEach-Object { if ("$_".Trim() -ne '') { Say 'INFO' "  $_" } }

    $fs = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled
    Say 'INFO' "Быстрый запуск (HiberbootEnabled) = $fs  (1 = включён, 0 или пусто = выключен)"
}

function Do-Cleanup {
    Say 'INFO' '=== Copilot, установленный как обычная программа ==='
    $cop = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
           Where-Object { $_.DisplayName -eq 'Copilot' } | Select-Object -First 1
    if (-not $cop) { Say 'SKIP' 'Copilot как программа не найден' }
    else {
        $us = $cop.UninstallString
        if ($us -match '^"([^"]+)"\s*(.*)$') { $exe = $Matches[1]; $argline = $Matches[2] }
        else { $exe = $us; $argline = '' }
        if (-not (Test-Path $exe)) { Say 'SKIP' "Установщик Copilot не найден: $exe" }
        else {
            try {
                Say 'INFO' "Запускаю удаление: $exe $argline"
                $pr = Start-Process -FilePath $exe -ArgumentList $argline -Wait -PassThru -ErrorAction Stop
                Say 'OK' "Copilot удалён, код завершения $($pr.ExitCode). Вернуть можно только установкой заново с сайта Microsoft."
            } catch { Say 'FAIL' "Удаление Copilot: $($_.Exception.Message)" }
        }
    }

    Say 'INFO' 'НЕ ТРОГАЮ службы смарт-карт (SCardSvr, ScDeviceEnum): через них работает слот SIM у LTE-модема'

    Say 'INFO' '=== Временные файлы ==='
    $freed = 0
    foreach ($t in @("$env:TEMP", 'C:\Windows\Temp')) {
        $before = (Get-ChildItem $t -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        Get-ChildItem $t -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        $after = (Get-ChildItem $t -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        if ($null -eq $before) { $before = 0 }; if ($null -eq $after) { $after = 0 }
        $freed += ($before - $after)
    }
    Say 'OK' ("Временные файлы очищены, освобождено примерно {0} МБ" -f [int]($freed / 1MB))
}

function Do-Simfix {
    Say 'INFO' '=== Возврат служб смарт-карт (через них работает слот SIM у LTE-модема) ==='
    foreach ($s in @('SCardSvr', 'ScDeviceEnum', 'SCPolicySvc')) { SetSvc $s 'demand' }
    Say 'INFO' 'Готово. Эти службы запускаются по требованию и в простое ничего не едят.'
}

function Do-Undo {
    Say 'INFO' '=== ОТКАТ второй волны ==='
    if (-not (Test-Path $UndoFile)) { Say 'SKIP' 'Файл undo2.tsv не найден, откатывать нечего'; return }
    $lines = Get-Content $UndoFile -Encoding UTF8 | Where-Object { $_.Trim() -ne '' }
    [array]::Reverse($lines)
    foreach ($line in $lines) {
        $p = $line -split "`t"
        if ($p.Count -lt 3) { continue }
        $kind = $p[0]; $target = $p[1]; $orig = $p[2]
        try {
            switch ($kind) {
                'svc' { & sc.exe config $target start= $orig | Out-Null; Say 'OK' "Служба $target возвращена в '$orig'" }
                'task' {
                    $tp = Split-Path $target -Parent; if (-not $tp.EndsWith('\')) { $tp += '\' }
                    Enable-ScheduledTask -TaskPath $tp -TaskName (Split-Path $target -Leaf) -ErrorAction Stop | Out-Null
                    Say 'OK' "Задача $target включена"
                }
                'reg' {
                    $q = $target -split '\|'
                    if ($orig -eq '<absent>') {
                        Remove-ItemProperty -Path $q[0] -Name $q[1] -ErrorAction SilentlyContinue
                        Say 'OK' "Реестр $($q[0])\$($q[1]) удалён (как было)"
                    } else {
                        New-ItemProperty -Path $q[0] -Name $q[1] -Value $orig -PropertyType $q[2] -Force | Out-Null
                        Say 'OK' "Реестр $($q[0])\$($q[1]) возвращён в '$orig'"
                    }
                }
                'file' {
                    if (Test-Path $target) { Move-Item -LiteralPath $target -Destination $orig -Force; Say 'OK' "Ярлык возвращён в автозагрузку: $orig" }
                    else { Say 'SKIP' "Ярлык не найден: $target" }
                }
                'appx' {
                    $manifest = Join-Path $orig 'AppxManifest.xml'
                    if (Test-Path $manifest) {
                        Add-AppxPackage -DisableDevelopmentMode -Register $manifest -ErrorAction Stop
                        Say 'OK' "Приложение восстановлено из файлов: $target"
                    } else {
                        Say 'SKIP' "Файлы $target уже удалены - переустанови это приложение из Microsoft Store"
                    }
                }
                'appxprov' { Say 'SKIP' "Пакет образа ${orig} - вернуть можно только переустановкой из Store" }
                'hib' { & powercfg.exe /hibernate off; Say 'OK' 'Гибернация выключена обратно' }
            }
        } catch { Say 'FAIL' "Откат $kind $target : $($_.Exception.Message)" }
    }
    Rename-Item -Path $UndoFile -NewName ("undo2_restored_{0}.tsv" -f (Get-Date -Format 'yyyyMMdd_HHmmss')) -Force
    Say 'INFO' 'Откат завершён. Перезагрузи Surface.'
}

# ---------- main ----------
Say 'INFO' "Шаг: $Step | лог: $LogFile"
switch ($Step) {
    'apps'      { Do-Apps }
    'startup'   { Do-Startup }
    'services2' { Do-Services2 }
    'fastboot'  { Do-Fastboot }
    'cleanup'   { Do-Cleanup }
    'simfix'    { Do-Simfix }
    'undo'      { Do-Undo }
    'all'       { Do-Apps; Do-Startup; Do-Services2 }
}
Say 'INFO' ("ИТОГО: успешно={0}, пропущено={1}, ошибок={2}" -f $script:OkCount, $script:SkipCount, $script:FailCount)
Say 'INFO' 'Перезагрузи Surface, чтобы изменения вступили в силу.'
if ($script:FailCount -gt 0) { exit 2 } else { exit 0 }

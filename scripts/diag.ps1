#requires -Version 5.1
# Diagnostika Windows 11 / Surface. TOLKO CHTENIE - nichego ne menyaet.
# Rezultat: C:\Debloat\logs\diag_<data>.txt

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$dir = Join-Path $env:SystemDrive 'Debloat\logs'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$out = Join-Path $dir "diag_$stamp.txt"
$buf = New-Object System.Text.StringBuilder

function W([string]$s = '') { [void]$buf.AppendLine($s) }
function H([string]$s) { W; W ('=' * 70); W ("== $s"); W ('=' * 70) }
function SizeMB($path) {
    $m = Get-ChildItem $path -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum
    if ($m -and $m.Sum) { return [int]($m.Sum / 1MB) } else { return 0 }
}

W ("Диагностика собрана: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

# ---------------- sistema ----------------
H 'СИСТЕМА'
$cs  = Get-CimInstance Win32_ComputerSystem
$os  = Get-CimInstance Win32_OperatingSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$cv  = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
W ("Устройство    : " + $cs.Manufacturer + " " + $cs.Model)
W ("CPU           : " + $cpu.Name.Trim() + "  ядер " + $cpu.NumberOfCores + " / потоков " + $cpu.NumberOfLogicalProcessors)
W ("ОС            : " + $os.Caption + " build " + $os.BuildNumber + "." + $cv.UBR + "  (" + $cv.DisplayVersion + ")")
W ("RAM           : всего " + [int]($os.TotalVisibleMemorySize/1KB) + " МБ, свободно " + [int]($os.FreePhysicalMemory/1KB) + " МБ")
W ("Время работы  : " + ((Get-Date) - $os.LastBootUpTime).ToString())
W ("Процессов     : " + (Get-Process).Count)
$allSvc = Get-Service
W ("Служб запущено: " + ($allSvc | Where-Object { $_.Status -eq 'Running' }).Count + " из " + $allSvc.Count)
W ("Схема питания : " + ((powercfg /getactivescheme) -join ' '))

H 'ДИСК И ВРЕМЕННЫЕ ФАЙЛЫ'
Get-Volume | Where-Object { $_.DriveLetter } | ForEach-Object {
    W ($_.DriveLetter + ": " + $_.FileSystemLabel + " - всего " + [math]::Round($_.Size/1GB,1) + " ГБ, свободно " + [math]::Round($_.SizeRemaining/1GB,1) + " ГБ")
}
$hib = Get-Item 'C:\hiberfil.sys' -Force -ErrorAction SilentlyContinue
if ($hib) { W ("hiberfil.sys  : " + [math]::Round($hib.Length/1GB,1) + " ГБ") } else { W 'hiberfil.sys  : отсутствует' }
W ("Windows\Temp  : " + (SizeMB 'C:\Windows\Temp') + " МБ")
W ("Temp польз.   : " + (SizeMB $env:TEMP) + " МБ")
W ("SoftwareDistribution\Download: " + (SizeMB 'C:\Windows\SoftwareDistribution\Download') + " МБ")

# ---------------- processy ----------------
H 'ТОП-25 ПРОЦЕССОВ ПО ПАМЯТИ (сгруппировано по имени)'
Get-Process | Group-Object ProcessName | ForEach-Object {
    New-Object psobject -Property @{
        PName = $_.Name
        Cnt   = $_.Count
        Mem   = [int](($_.Group | Measure-Object WorkingSet64 -Sum).Sum / 1MB)
    }
} | Sort-Object Mem -Descending | Select-Object -First 25 | ForEach-Object {
    W ("{0,-34} {1,3} шт  {2,6} МБ" -f $_.PName, $_.Cnt, $_.Mem)
}

# ---------------- avtozagruzka ----------------
H 'АВТОЗАГРУЗКА: ключи Run в реестре'
$runKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
)
foreach ($hive in $runKeys) {
    $k = Get-Item $hive -ErrorAction SilentlyContinue
    if (-not $k) { continue }
    W; W ("[" + $hive + "]")
    foreach ($n in $k.GetValueNames()) {
        if ($n -eq '') { continue }
        W ("  {0,-30} = {1}" -f $n, $k.GetValue($n))
    }
}

H 'АВТОЗАГРУЗКА: включено / отключено (StartupApproved)'
$appKeys = @(
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder32',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
)
foreach ($p in $appKeys) {
    $k = Get-Item $p -ErrorAction SilentlyContinue
    if (-not $k) { continue }
    W; W ("[" + $p + "]")
    foreach ($n in $k.GetValueNames()) {
        $b = $k.GetValue($n)
        $state = 'включено'
        if ($b -and ($b[0] -band 1)) { $state = 'ОТКЛЮЧЕНО' }
        W ("  {0,-45} {1}" -f $n, $state)
    }
}

H 'АВТОЗАГРУЗКА: папки Startup'
$startFolders = @(
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'),
    (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup')
)
foreach ($f in $startFolders) {
    W; W ("[" + $f + "]")
    Get-ChildItem $f -Force -ErrorAction SilentlyContinue | ForEach-Object { W ("  " + $_.Name) }
}

H 'АВТОЗАГРУЗКА: скрытые StartupTask у приложений Store'
foreach ($pkg in (Get-AppxPackage)) {
    $m = Get-AppxPackageManifest $pkg -ErrorAction SilentlyContinue
    if (-not $m) { continue }
    $ext = $m.Package.Applications.Application.Extensions.Extension
    if (-not $ext) { continue }
    $tasks = $ext | Where-Object { $_.Category -eq 'windows.startupTask' }
    if ($tasks) { W ("  " + $pkg.Name + "  ->  " + (($tasks.StartupTask.TaskId) -join ', ')) }
}

# ---------------- sluzhby ----------------
H 'ЗАПУЩЕННЫЕ СЛУЖБЫ (имя | автозапуск | описание | файл)'
$svcCim = @{}
Get-CimInstance Win32_Service | ForEach-Object { $svcCim[$_.Name] = $_ }
Get-Service | Where-Object { $_.Status -eq 'Running' } | Sort-Object Name | ForEach-Object {
    $c = $svcCim[$_.Name]
    $exe = ''
    if ($c -and $c.PathName) { $exe = Split-Path -Leaf ($c.PathName -replace '^"([^"]+)".*', '$1') }
    W ("{0,-28} {1,-12} {2,-52} {3}" -f $_.Name, $_.StartType, $_.DisplayName, $exe)
}

H 'СЛУЖБЫ НЕ ОТ MICROSOFT (сторонний софт, не отключённые)'
Get-CimInstance Win32_Service | Where-Object {
    $_.PathName -and ($_.PathName -notmatch 'C:\\WINDOWS') -and ($_.StartMode -ne 'Disabled')
} | Sort-Object Name | ForEach-Object {
    W ("{0,-34} {1,-10} {2,-9} {3}" -f $_.Name, $_.StartMode, $_.State, $_.PathName)
}

# ---------------- prilozheniya ----------------
H 'ПРИЛОЖЕНИЯ STORE (Appx) у текущего пользователя'
Get-AppxPackage | Sort-Object Name | ForEach-Object { W ("{0,-62} {1}" -f $_.Name, $_.Version) }

H 'APPX ВСТРОЕННЫЕ В ОБРАЗ (provisioned)'
Get-AppxProvisionedPackage -Online | Sort-Object DisplayName | ForEach-Object { W ("{0,-62} {1}" -f $_.DisplayName, $_.Version) }

H 'ОБЫЧНЫЕ ПРОГРАММЫ (Win32)'
$unKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
foreach ($p in $unKeys) {
    Get-ItemProperty $p -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName } | Sort-Object DisplayName | ForEach-Object {
        W ("{0,-56} {1,-18} {2}" -f $_.DisplayName, $_.DisplayVersion, $_.Publisher)
    }
}

# ---------------- zadachi ----------------
H 'ЗАДАЧИ ПЛАНИРОВЩИКА: включённые, НЕ в \Microsoft\'
Get-ScheduledTask | Where-Object { $_.State -ne 'Disabled' -and $_.TaskPath -notlike '\Microsoft\*' } |
    Sort-Object TaskPath, TaskName | ForEach-Object { W ("{0,-10} {1}{2}" -f $_.State, $_.TaskPath, $_.TaskName) }

H 'ЗАДАЧИ ПЛАНИРОВЩИКА: включённые, запуск при входе или загрузке'
Get-ScheduledTask | Where-Object {
    $_.State -ne 'Disabled' -and (($_.Triggers.CimClass.CimClassName -join ',') -match 'Logon|Boot')
} | Sort-Object TaskPath, TaskName | ForEach-Object { W ("  " + $_.TaskPath + $_.TaskName) }

# ---------------- zashchita ----------------
H 'АНТИВИРУС / ЗАЩИТА'
Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue |
    ForEach-Object { W ($_.displayName + "  (state=" + $_.productState + ")") }
$mpc = Get-MpComputerStatus -ErrorAction SilentlyContinue
if ($mpc) { W ("Defender: защита в реальном времени включена = " + $mpc.RealTimeProtectionEnabled) }

H 'ЖУРНАЛ: ошибки и критические события System за 7 дней (топ-15)'
Get-WinEvent -FilterHashtable @{LogName='System'; Level=1,2; StartTime=(Get-Date).AddDays(-7)} -MaxEvents 400 -ErrorAction SilentlyContinue |
    Group-Object Id, ProviderName | Sort-Object Count -Descending | Select-Object -First 15 |
    ForEach-Object { W ("{0,4} x  {1}" -f $_.Count, $_.Name) }

H 'ВРЕМЯ ЗАГРУЗКИ (журнал Diagnostics-Performance, последние 5)'
Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Diagnostics-Performance/Operational'; Id=100} -MaxEvents 5 -ErrorAction SilentlyContinue |
    ForEach-Object {
        $x = [xml]$_.ToXml()
        $d = @{}
        $x.Event.EventData.Data | ForEach-Object { $d[$_.Name] = $_.'#text' }
        W ($_.TimeCreated.ToString() + "  загрузка " + $d['BootTime'] + " мс, из них автозагрузка приложений " + $d['BootPostBootTime'] + " мс")
    }

[System.IO.File]::WriteAllText($out, $buf.ToString(), (New-Object System.Text.UTF8Encoding $true))
Write-Host ''
Write-Host ("Отчёт готов: " + $out) -ForegroundColor Green
Write-Host 'Ничего не изменено - скрипт только читал систему.' -ForegroundColor Green

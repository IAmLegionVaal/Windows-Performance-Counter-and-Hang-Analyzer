#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateRange(10, 3600)]
    [int]$DurationSeconds = 60,

    [Parameter()]
    [ValidateRange(1, 60)]
    [int]$SampleIntervalSeconds = 5,

    [Parameter()]
    [string]$ProcessName,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = (Join-Path $PWD ('Performance-Hang-{0:yyyyMMdd_HHmmss}' -f (Get-Date)))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$ErrorLog = Join-Path $OutputPath 'command-errors.log'

function Invoke-SafeCommand {
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory)][string]$Label
    )

    try {
        & $ScriptBlock
    }
    catch {
        '[{0}] {1} :: {2}' -f (Get-Date -Format 'o'), $Label, $_.Exception.Message |
            Add-Content -LiteralPath $ErrorLog -Encoding UTF8
        return $null
    }
}

function Get-ProcessPropertyValue {
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory)][ValidateSet('Responding', 'StartTime', 'Path')][string]$PropertyName
    )

    try {
        return $Process.$PropertyName
    }
    catch {
        return $null
    }
}

$counterPaths = @(
    '\Processor(_Total)\% Processor Time',
    '\System\Processor Queue Length',
    '\Memory\Available MBytes',
    '\Memory\% Committed Bytes In Use',
    '\Memory\Pages/sec',
    '\Paging File(_Total)\% Usage',
    '\PhysicalDisk(_Total)\Avg. Disk sec/Read',
    '\PhysicalDisk(_Total)\Avg. Disk sec/Write',
    '\PhysicalDisk(_Total)\Current Disk Queue Length',
    '\Network Interface(*)\Bytes Total/sec'
)

$sampleCount = [math]::Max(1, [math]::Ceiling($DurationSeconds / $SampleIntervalSeconds))
$counterData = Invoke-SafeCommand -Label 'Performance counters' -ScriptBlock {
    Get-Counter -Counter $counterPaths `
        -SampleInterval $SampleIntervalSeconds `
        -MaxSamples $sampleCount `
        -ErrorAction Stop
}

$counterRows = [System.Collections.Generic.List[object]]::new()
if ($null -ne $counterData) {
    foreach ($sample in @($counterData.CounterSamples)) {
        $counterRows.Add([pscustomobject]@{
            Timestamp = $sample.Timestamp
            Path = $sample.Path
            InstanceName = $sample.InstanceName
            CookedValue = [math]::Round($sample.CookedValue, 4)
            Status = $sample.Status
        })
    }
}
$counterRows | Export-Csv (Join-Path $OutputPath 'performance-counters.csv') -NoTypeInformation -Encoding UTF8

$processes = @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
    $process = $_
    [pscustomobject]@{
        Name = $process.ProcessName
        Id = $process.Id
        CPUSeconds = if ($null -ne $process.CPU) { [math]::Round($process.CPU, 2) } else { $null }
        WorkingSetMB = [math]::Round($process.WorkingSet64 / 1MB, 2)
        PrivateMemoryMB = [math]::Round($process.PrivateMemorySize64 / 1MB, 2)
        Handles = $process.HandleCount
        Threads = @($process.Threads).Count
        Responding = Get-ProcessPropertyValue -Process $process -PropertyName Responding
        StartTime = Get-ProcessPropertyValue -Process $process -PropertyName StartTime
        Path = Get-ProcessPropertyValue -Process $process -PropertyName Path
    }
})
$processes |
    Sort-Object WorkingSetMB -Descending |
    Export-Csv (Join-Path $OutputPath 'process-inventory.csv') -NoTypeInformation -Encoding UTF8

$targetProcesses = @()
if (-not [string]::IsNullOrWhiteSpace($ProcessName)) {
    $targetProcesses = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | ForEach-Object {
        $process = $_
        [pscustomobject]@{
            Name = $process.ProcessName
            Id = $process.Id
            Responding = Get-ProcessPropertyValue -Process $process -PropertyName Responding
            CPUSeconds = if ($null -ne $process.CPU) { [math]::Round($process.CPU, 2) } else { $null }
            WorkingSetMB = [math]::Round($process.WorkingSet64 / 1MB, 2)
            PrivateMemoryMB = [math]::Round($process.PrivateMemorySize64 / 1MB, 2)
            Handles = $process.HandleCount
            Threads = @($process.Threads).Count
            MainWindowTitle = $process.MainWindowTitle
            Path = Get-ProcessPropertyValue -Process $process -PropertyName Path
        }
    })
    $targetProcesses |
        Export-Csv (Join-Path $OutputPath 'target-processes.csv') -NoTypeInformation -Encoding UTF8
}

$services = @(Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue | ForEach-Object {
    [pscustomobject]@{
        Name = $_.Name
        DisplayName = $_.DisplayName
        State = $_.State
        StartMode = $_.StartMode
        ProcessId = $_.ProcessId
        Status = $_.Status
        AutomaticButStopped = ($_.StartMode -eq 'Auto' -and $_.State -ne 'Running')
    }
})
$services | Export-Csv (Join-Path $OutputPath 'service-inventory.csv') -NoTypeInformation -Encoding UTF8

$startTime = (Get-Date).AddDays(-3)
$events = [System.Collections.Generic.List[object]]::new()
$filters = @(
    @{ LogName = 'Application'; ProviderName = 'Application Hang'; StartTime = $startTime },
    @{ LogName = 'Application'; ProviderName = 'Windows Error Reporting'; StartTime = $startTime },
    @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Resource-Exhaustion-Detector'; StartTime = $startTime },
    @{ LogName = 'System'; ProviderName = 'disk'; StartTime = $startTime },
    @{ LogName = 'System'; ProviderName = 'storahci'; StartTime = $startTime },
    @{ LogName = 'System'; ProviderName = 'stornvme'; StartTime = $startTime }
)
foreach ($filter in $filters) {
    $items = Invoke-SafeCommand -Label "Events $($filter.ProviderName)" -ScriptBlock {
        Get-WinEvent -FilterHashtable $filter -ErrorAction Stop |
            Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message
    }

    foreach ($item in @($items)) {
        if ($null -ne $item) {
            $events.Add([pscustomobject]@{
                TimeCreated = $item.TimeCreated
                Id = $item.Id
                Level = $item.LevelDisplayName
                Provider = $item.ProviderName
                Message = $item.Message
            })
        }
    }
}
$events | Export-Csv (Join-Path $OutputPath 'performance-related-events.csv') -NoTypeInformation -Encoding UTF8

function Get-AverageCounterValue {
    param([Parameter(Mandatory)][string]$Pattern)

    $values = @($counterRows |
        Where-Object Path -Like $Pattern |
        Select-Object -ExpandProperty CookedValue)
    if ($values.Count -eq 0) {
        return $null
    }

    return [math]::Round((($values | Measure-Object -Average).Average), 2)
}

$avgCpu = Get-AverageCounterValue '*\processor(_total)\% processor time'
$avgMemory = Get-AverageCounterValue '*\memory\% committed bytes in use'
$avgDiskRead = Get-AverageCounterValue '*\physicaldisk(_total)\avg. disk sec/read'
$avgDiskWrite = Get-AverageCounterValue '*\physicaldisk(_total)\avg. disk sec/write'
$avgQueue = Get-AverageCounterValue '*\physicaldisk(_total)\current disk queue length'

$summary = [pscustomobject]@{
    CollectedAt = (Get-Date).ToString('o')
    ComputerName = $env:COMPUTERNAME
    DurationSeconds = $DurationSeconds
    SampleIntervalSeconds = $SampleIntervalSeconds
    CounterSamples = $counterRows.Count
    AverageCpuPercent = $avgCpu
    AverageCommittedMemoryPercent = $avgMemory
    AverageDiskReadLatencySeconds = $avgDiskRead
    AverageDiskWriteLatencySeconds = $avgDiskWrite
    AverageDiskQueueLength = $avgQueue
    ProcessCount = $processes.Count
    NonRespondingProcesses = @($processes | Where-Object Responding -eq $false).Count
    AutomaticServicesStopped = @($services | Where-Object AutomaticButStopped).Count
    RelatedEventCount = $events.Count
    TargetProcessName = $ProcessName
    TargetProcessInstances = $targetProcesses.Count
    TargetProcessNonResponding = @($targetProcesses | Where-Object Responding -eq $false).Count
}
$summary | Export-Csv (Join-Path $OutputPath 'summary.csv') -NoTypeInformation -Encoding UTF8
$summary | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutputPath 'summary.json') -Encoding UTF8

$style = '<style>body{font-family:Segoe UI,Arial;margin:28px;color:#172033}table{border-collapse:collapse;width:100%}th,td{border:1px solid #d5dde7;padding:7px;text-align:left}th{background:#eaf2f8}h1,h2{color:#0b3558}</style>'
$body = @()
$body += $summary | ConvertTo-Html -Fragment -PreContent '<h2>Summary</h2>'
$body += $processes | Sort-Object WorkingSetMB -Descending | Select-Object -First 25 | ConvertTo-Html -Fragment -PreContent '<h2>Top Processes by Working Set</h2>'
$body += $processes | Sort-Object CPUSeconds -Descending | Select-Object -First 25 | ConvertTo-Html -Fragment -PreContent '<h2>Top Processes by CPU Time</h2>'
if ($targetProcesses.Count -gt 0) {
    $body += $targetProcesses | ConvertTo-Html -Fragment -PreContent '<h2>Target Process</h2>'
}
$body += $events | Select-Object -First 200 | ConvertTo-Html -Fragment -PreContent '<h2>Related Events</h2>'
$body += '<p>Diagnostic-only. Correlate trends and timing before assigning root cause.</p>'
ConvertTo-Html -Title 'Windows Performance and Hang Analysis' -Head $style -Body $body |
    Set-Content (Join-Path $OutputPath 'Performance-Hang-Analysis.html') -Encoding UTF8

Write-Host "Performance and hang analysis completed: $OutputPath"

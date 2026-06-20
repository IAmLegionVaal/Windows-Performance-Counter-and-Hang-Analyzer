[CmdletBinding()]
param(
    [Parameter()]
    [ValidateRange(10,3600)]
    [int]$DurationSeconds = 60,

    [Parameter()]
    [ValidateRange(1,60)]
    [int]$SampleIntervalSeconds = 5,

    [Parameter()]
    [string]$ProcessName,

    [Parameter()]
    [string]$OutputPath = (Join-Path $PWD ("Performance-Hang-{0:yyyyMMdd_HHmmss}" -f (Get-Date)))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$ErrorLog = Join-Path $OutputPath 'command-errors.log'

function Invoke-Safe {
    param([scriptblock]$ScriptBlock,[string]$Label)
    try { & $ScriptBlock }
    catch { "[$(Get-Date -Format o)] $Label :: $($_.Exception.Message)" | Add-Content $ErrorLog; $null }
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

$sampleCount = [math]::Max(1,[math]::Ceiling($DurationSeconds / $SampleIntervalSeconds))
$counterData = Invoke-Safe -Label 'Performance counters' -ScriptBlock {
    Get-Counter -Counter $counterPaths -SampleInterval $SampleIntervalSeconds -MaxSamples $sampleCount -ErrorAction Stop
}

$counterRows = New-Object System.Collections.Generic.List[object]
foreach ($sample in @($counterData.CounterSamples)) {
    $counterRows.Add([pscustomobject]@{
        Timestamp = $sample.Timestamp
        Path = $sample.Path
        InstanceName = $sample.InstanceName
        CookedValue = [math]::Round($sample.CookedValue,4)
        Status = $sample.Status
    })
}
$counterRows | Export-Csv (Join-Path $OutputPath 'performance-counters.csv') -NoTypeInformation -Encoding UTF8

$processes = Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
    [pscustomobject]@{
        Name = $_.ProcessName
        Id = $_.Id
        CPUSeconds = if ($null -ne $_.CPU) { [math]::Round($_.CPU,2) } else { $null }
        WorkingSetMB = [math]::Round($_.WorkingSet64 / 1MB,2)
        PrivateMemoryMB = [math]::Round($_.PrivateMemorySize64 / 1MB,2)
        Handles = $_.HandleCount
        Threads = @($_.Threads).Count
        Responding = try { $_.Responding } catch { $null }
        StartTime = try { $_.StartTime } catch { $null }
        Path = try { $_.Path } catch { $null }
    }
}
$processes | Sort-Object WorkingSetMB -Descending | Export-Csv (Join-Path $OutputPath 'process-inventory.csv') -NoTypeInformation -Encoding UTF8

$targetProcesses = @()
if ($ProcessName) {
    $targetProcesses = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{
            Name = $_.ProcessName
            Id = $_.Id
            Responding = try { $_.Responding } catch { $null }
            CPUSeconds = if ($null -ne $_.CPU) { [math]::Round($_.CPU,2) } else { $null }
            WorkingSetMB = [math]::Round($_.WorkingSet64 / 1MB,2)
            PrivateMemoryMB = [math]::Round($_.PrivateMemorySize64 / 1MB,2)
            Handles = $_.HandleCount
            Threads = @($_.Threads).Count
            MainWindowTitle = $_.MainWindowTitle
            Path = try { $_.Path } catch { $null }
        }
    })
    $targetProcesses | Export-Csv (Join-Path $OutputPath 'target-processes.csv') -NoTypeInformation -Encoding UTF8
}

$services = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | ForEach-Object {
    [pscustomobject]@{
        Name = $_.Name
        DisplayName = $_.DisplayName
        State = $_.State
        StartMode = $_.StartMode
        ProcessId = $_.ProcessId
        Status = $_.Status
        AutomaticButStopped = ($_.StartMode -eq 'Auto' -and $_.State -ne 'Running')
    }
}
$services | Export-Csv (Join-Path $OutputPath 'service-inventory.csv') -NoTypeInformation -Encoding UTF8

$startTime = (Get-Date).AddDays(-3)
$events = New-Object System.Collections.Generic.List[object]
$filters = @(
    @{ LogName='Application'; ProviderName='Application Hang'; StartTime=$startTime },
    @{ LogName='Application'; ProviderName='Windows Error Reporting'; StartTime=$startTime },
    @{ LogName='System'; ProviderName='Microsoft-Windows-Resource-Exhaustion-Detector'; StartTime=$startTime },
    @{ LogName='System'; ProviderName='disk'; StartTime=$startTime },
    @{ LogName='System'; ProviderName='storahci'; StartTime=$startTime },
    @{ LogName='System'; ProviderName='stornvme'; StartTime=$startTime }
)
foreach ($filter in $filters) {
    $items = Invoke-Safe -Label "Events $($filter.ProviderName)" -ScriptBlock {
        Get-WinEvent -FilterHashtable $filter -ErrorAction Stop |
            Select-Object TimeCreated,Id,LevelDisplayName,ProviderName,Message
    }
    foreach ($item in @($items)) {
        if ($item) {
            $events.Add([pscustomobject]@{
                TimeCreated=$item.TimeCreated
                Id=$item.Id
                Level=$item.LevelDisplayName
                Provider=$item.ProviderName
                Message=$item.Message
            })
        }
    }
}
$events | Export-Csv (Join-Path $OutputPath 'performance-related-events.csv') -NoTypeInformation -Encoding UTF8

function Get-AverageCounterValue {
    param([string]$Pattern)
    $values = @($counterRows | Where-Object Path -like $Pattern | Select-Object -ExpandProperty CookedValue)
    if ($values.Count -eq 0) { return $null }
    [math]::Round((($values | Measure-Object -Average).Average),2)
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
    ProcessCount = @($processes).Count
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
if ($targetProcesses.Count -gt 0) { $body += $targetProcesses | ConvertTo-Html -Fragment -PreContent '<h2>Target Process</h2>' }
$body += $events | Select-Object -First 200 | ConvertTo-Html -Fragment -PreContent '<h2>Related Events</h2>'
$body += '<p>Diagnostic-only. Correlate trends and timing before assigning root cause.</p>'
ConvertTo-Html -Title 'Windows Performance and Hang Analysis' -Head $style -Body $body | Set-Content (Join-Path $OutputPath 'Performance-Hang-Analysis.html') -Encoding UTF8

Write-Host "Performance and hang analysis completed: $OutputPath"

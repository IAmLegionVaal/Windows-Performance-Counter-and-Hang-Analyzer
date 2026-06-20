# Windows Performance Counter and Hang Analyzer

A read-only PowerShell toolkit for collecting Windows performance counters, process evidence, responsiveness indicators, and event data during slow or hanging system incidents.

## Features

- Configurable sampling duration and interval
- CPU, memory, paging, disk latency, queue, and network counters
- Top CPU, memory, handle, and thread-consuming processes
- Process responding state for interactive applications
- Service state and automatic-service failure inventory
- Application Hang, Windows Error Reporting, Resource Exhaustion, disk, and performance events
- Optional process-specific wait-chain and dump-readiness evidence where tools are available
- CSV, JSON, HTML, and text outputs

## Usage

Run from an elevated PowerShell console:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\src\Get-PerformanceHangAnalysis.ps1
```

Collect 60 seconds of samples every 5 seconds:

```powershell
.\src\Get-PerformanceHangAnalysis.ps1 -DurationSeconds 60 -SampleIntervalSeconds 5
```

Target one process by name:

```powershell
.\src\Get-PerformanceHangAnalysis.ps1 -ProcessName outlook
```

## Safety

The toolkit does not terminate processes, restart services, change performance settings, clear logs, or create memory dumps automatically.

## Interpretation

Single samples can be misleading. Correlate trends, user impact, event timing, storage latency, and process behaviour before assigning root cause.

## Validation

Test during CPU pressure, memory pressure, disk contention, a deliberately unresponsive lab application, and normal baseline conditions.

## Author

Dewald Pretorius — L2 IT Support Engineer

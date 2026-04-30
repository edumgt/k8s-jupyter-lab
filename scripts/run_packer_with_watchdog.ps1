Param(
  [string]$RepoRoot = "C:\devtest\Kubernetes-Jupyter-Sandbox",
  [string]$VarFile = "variables.auto.pkrvars.hcl",
  [string]$Template = ".\k8s-data-platform.pkr.hcl",
  [string]$LogPath = "C:\devtest\Kubernetes-Jupyter-Sandbox\packer\packer-build-watchdog.log",
  [string]$VmName = "k8s-data-platform",
  [string]$VirtualBoxVmRoot = "C:\Users\1\VirtualBox VMs",
  [int]$IdleMinutes = 12,
  [int]$MaxRuntimeMinutes = 18,
  [int]$MaxSshAuthFailures = 10,
  [int]$AuthFailureGraceMinutes = 8,
  [int]$PollSeconds = 30,
  [ValidateSet("abort", "ask", "cleanup", "run-cleanup-provisioner")]
  [string]$OnError = "abort",
  [switch]$Force
)

$ErrorActionPreference = "Stop"

function Write-Status {
  param([string]$Message)
  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  Write-Host "[$timestamp] $Message"
}

function Get-LogState {
  param([string]$Path)

  if (!(Test-Path $Path)) {
    return @{
      Exists = $false
      Length = 0
      LastWriteTime = [datetime]::MinValue
    }
  }

  $item = Get-Item $Path
  return @{
    Exists = $true
    Length = $item.Length
    LastWriteTime = $item.LastWriteTime
  }
}

function Show-LogTail {
  param(
    [string]$Path,
    [int]$Lines = 120
  )

  if (Test-Path $Path) {
    Write-Host ""
    Write-Host "===== packer log tail ====="
    Get-Content $Path -Tail $Lines
    Write-Host "===== end log tail ====="
    Write-Host ""
  }
}

function Invoke-VBoxManage {
  param([string[]]$Arguments)

  $vboxManage = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
  if (!(Test-Path $vboxManage)) {
    throw "VBoxManage not found: $vboxManage"
  }

  & $vboxManage @Arguments
  return $LASTEXITCODE
}

function Remove-StaleVirtualBoxState {
  param(
    [string]$MachineName,
    [string]$RepoRootPath,
    [string]$VmRootPath
  )

  $outputDir = "C:\ffmpeg"
  $vdiPath = Join-Path $outputDir "k8s-data-platform.vdi"
  $vmDir = Join-Path $VmRootPath $MachineName

  Write-Status "Cleaning stale VirtualBox state for $MachineName"

  $registered = & "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" list vms 2>$null
  if ($registered -match ('"' + [regex]::Escape($MachineName) + '"')) {
    Write-Status "Unregistering existing VM $MachineName"
    Invoke-VBoxManage -Arguments @("controlvm", $MachineName, "poweroff") | Out-Null
    Start-Sleep -Seconds 3
    Invoke-VBoxManage -Arguments @("unregistervm", $MachineName, "--delete") | Out-Null
  }

  if (Test-Path $vdiPath) {
    Write-Status "Closing stale VDI $vdiPath"
    Invoke-VBoxManage -Arguments @("closemedium", "disk", $vdiPath, "--delete") | Out-Null
  }

  if (Test-Path $outputDir) {
    Write-Status "Removing stale output directory $outputDir"
    Remove-Item $outputDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  if (Test-Path $vmDir) {
    Write-Status "Removing stale VM directory $vmDir"
    Remove-Item $vmDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

$packerDir = Join-Path $RepoRoot "packer"
if (!(Test-Path $packerDir)) {
  throw "Packer directory not found: $packerDir"
}

$stdoutPath = Join-Path $packerDir "packer-build-watchdog.stdout.log"
$stderrPath = Join-Path $packerDir "packer-build-watchdog.stderr.log"

foreach ($path in @($LogPath, $stdoutPath, $stderrPath)) {
  if (Test-Path $path) {
    Remove-Item $path -Force
  }
}

if ($Force) {
  Remove-StaleVirtualBoxState -MachineName $VmName -RepoRootPath $RepoRoot -VmRootPath $VirtualBoxVmRoot
}

$buildArgs = @("build")
if ($Force) {
  $buildArgs += "-force"
}
$buildArgs += "-on-error=$OnError"
$buildArgs += "-var-file=$VarFile"
$buildArgs += $Template

Write-Status "Starting packer build with watchdog"
Write-Status "Log path: $LogPath"
Write-Status "Idle timeout: $IdleMinutes minutes"
Write-Status "Max runtime: $MaxRuntimeMinutes minutes"
Write-Status "Max SSH auth failures in log tail: $MaxSshAuthFailures"
Write-Status "SSH auth failure grace period: $AuthFailureGraceMinutes minutes"
Write-Status "On-error policy: $OnError"

$env:PACKER_LOG = "1"
$env:PACKER_LOG_PATH = $LogPath

$process = Start-Process `
  -FilePath "packer" `
  -ArgumentList $buildArgs `
  -WorkingDirectory $packerDir `
  -RedirectStandardOutput $stdoutPath `
  -RedirectStandardError $stderrPath `
  -PassThru

$lastState = Get-LogState -Path $LogPath
$lastProgressAt = Get-Date
$startedAt = Get-Date
$sshConnected = $false

function Stop-PackerProcess {
  param(
    [System.Diagnostics.Process]$TargetProcess,
    [string]$Reason
  )
  Write-Status $Reason
  try {
    Stop-Process -Id $TargetProcess.Id -Force
  } catch {
    Write-Status "Process already stopped."
  }
}

while (!$process.HasExited) {
  Start-Sleep -Seconds $PollSeconds

  $elapsed = (Get-Date) - $startedAt
  if ($elapsed.TotalMinutes -ge $MaxRuntimeMinutes) {
    Stop-PackerProcess -TargetProcess $process -Reason ("Max runtime exceeded ({0:n1} minutes). Stopping packer build process." -f $elapsed.TotalMinutes)
    break
  }

  if (Test-Path $LogPath) {
    $recentLines = Get-Content $LogPath -Tail 220
    if (!$sshConnected) {
      $connectedHits = ($recentLines | Select-String -SimpleMatch "Connected to SSH!").Count
      if ($connectedHits -gt 0) {
        $sshConnected = $true
        Write-Status "SSH connection established. Disabling pre-connection auth-failure guard."
      }
    }

    if (!$sshConnected -and $elapsed.TotalMinutes -ge $AuthFailureGraceMinutes) {
      $authFailures = ($recentLines | Select-String -SimpleMatch "unable to authenticate, attempted methods [none password]").Count
      if ($authFailures -ge $MaxSshAuthFailures) {
        Stop-PackerProcess -TargetProcess $process -Reason ("Detected repeated SSH password auth failures ({0} in recent log tail). Stopping packer build process." -f $authFailures)
        break
      }
    }
  }

  $currentState = Get-LogState -Path $LogPath
  $changed = $false

  if ($currentState.Exists -and !$lastState.Exists) {
    $changed = $true
  } elseif ($currentState.Length -ne $lastState.Length -or $currentState.LastWriteTime -ne $lastState.LastWriteTime) {
    $changed = $true
  }

  if ($changed) {
    $lastProgressAt = Get-Date
    Write-Status ("Log updated: {0} bytes" -f $currentState.Length)
    $lastState = $currentState
    continue
  }

  $idleFor = (Get-Date) - $lastProgressAt
  Write-Status ("No log change for {0:n1} minutes" -f $idleFor.TotalMinutes)

  if ($idleFor.TotalMinutes -ge $IdleMinutes) {
    Stop-PackerProcess -TargetProcess $process -Reason "Idle timeout exceeded. Stopping packer build process."
    break
  }
}

if ($process.HasExited) {
  Write-Status ("Packer process exited with code {0}" -f $process.ExitCode)
} else {
  Write-Status "Packer process was stopped by watchdog."
}

Show-LogTail -Path $LogPath -Lines 150

if (Test-Path $stdoutPath) {
  Write-Host "stdout log: $stdoutPath"
}
if (Test-Path $stderrPath) {
  Write-Host "stderr log: $stderrPath"
}
if (Test-Path $LogPath) {
  Write-Host "packer log: $LogPath"
}

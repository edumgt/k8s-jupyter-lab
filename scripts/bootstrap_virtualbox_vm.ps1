Param(
  [string]$VmName = "k8s-data-platform",
  [string]$Username = "ubuntu",
  [string]$Password = "ubuntu",
  [string]$RepoRoot = "C:\devtest\Kubernetes-Jupyter-Sandbox",
  [string]$GuestRepoRoot = "/tmp/k8s-data-platform-src",
  [string]$VBoxManagePath = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
)

$ErrorActionPreference = "Stop"

function Write-Status {
  param([string]$Message)
  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  Write-Host "[$timestamp] $Message"
}

function Invoke-VBoxManage {
  param([string[]]$Arguments)
  & $VBoxManagePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "VBoxManage failed: $($Arguments -join ' ')"
  }
}

function Invoke-GuestRun {
  param(
    [string]$Exe,
    [string[]]$Args = @()
  )

  $cmd = @(
    "guestcontrol", $VmName, "run",
    "--username=$Username",
    "--password=$Password",
    "--wait-stdout",
    "--wait-stderr",
    "--exe=$Exe",
    "--"
  ) + $Args

  Invoke-VBoxManage -Arguments $cmd
}

if (!(Test-Path $VBoxManagePath)) {
  throw "VBoxManage not found: $VBoxManagePath"
}

$requiredPaths = @(
  (Join-Path $RepoRoot "ansible"),
  (Join-Path $RepoRoot "apps"),
  (Join-Path $RepoRoot "infra"),
  (Join-Path $RepoRoot "scripts"),
  (Join-Path $RepoRoot "docs"),
  (Join-Path $RepoRoot "README.md")
)

foreach ($path in $requiredPaths) {
  if (!(Test-Path $path)) {
    throw "Required path not found: $path"
  }
}

Write-Status "Preparing guest directories"
Invoke-VBoxManage -Arguments @("guestcontrol", $VmName, "mkdir", "--parents", "--username=$Username", "--password=$Password", $GuestRepoRoot)

Write-Status "Copying repository payload into VM"
$copyItems = @("ansible", "apps", "infra", "scripts", "docs", "README.md")
foreach ($item in $copyItems) {
  $hostPath = Join-Path $RepoRoot $item
  Write-Status "Copying $item"
  $args = @(
    "guestcontrol", $VmName, "copyto",
    "--username=$Username",
    "--password=$Password",
    "--target-directory=$GuestRepoRoot"
  )
  if (Test-Path $hostPath -PathType Container) {
    $args += "--recursive"
  }
  $args += $hostPath
  Invoke-VBoxManage -Arguments $args
}

Write-Status "Ensuring bootstrap script is executable"
Invoke-GuestRun -Exe "/bin/chmod" -Args @("+x", "$GuestRepoRoot/scripts/bootstrap_local_vm.sh")

Write-Status "Running in-guest bootstrap"
$bootstrapCmd = "echo '$Password' | sudo -S bash '$GuestRepoRoot/scripts/bootstrap_local_vm.sh' --repo-root '$GuestRepoRoot'"
Invoke-GuestRun -Exe "/bin/bash" -Args @("-lc", $bootstrapCmd)

Write-Status "Bootstrap completed"

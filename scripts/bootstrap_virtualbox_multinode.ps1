Param(
  [string]$ControlPlaneVmName = "k8s-data-platform",
  [string]$WorkerNamePrefix = "k8s-worker",
  [int]$WorkerCount = 3,
  [string]$Username = "ubuntu",
  [string]$Password = "ubuntu",
  [string]$RepoRoot = "C:\devtest\Kubernetes-Jupyter-Sandbox",
  [string]$GuestRepoRoot = "/tmp/k8s-data-platform-src",
  [string]$VBoxManagePath = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe",
  [string]$NatNetworkName = "k8s-data-platform-net",
  [string]$NatNetworkCidr = "10.77.0.0/24",
  [int]$WorkerCpu = 2,
  [int]$WorkerMemoryMb = 6144,
  [switch]$ForceRecreateWorkers,
  [switch]$SkipRepoCopy,
  [switch]$SkipOverlayApply
)

$ErrorActionPreference = "Stop"

function Write-Status {
  param([string]$Message)
  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  Write-Host "[$timestamp] $Message"
}

function Join-Lines {
  param([object]$Value)
  if ($null -eq $Value) {
    return ""
  }
  if ($Value -is [System.Array]) {
    return ($Value -join "`n")
  }
  return [string]$Value
}

function Invoke-VBoxManage {
  param(
    [string[]]$Arguments,
    [switch]$IgnoreExitCode
  )

  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & $VBoxManagePath @Arguments 2>&1
  } finally {
    $ErrorActionPreference = $previousPreference
  }

  if (!$IgnoreExitCode -and $LASTEXITCODE -ne 0) {
    $joined = $Arguments -join " "
    throw "VBoxManage failed ($joined): $(Join-Lines $output)"
  }
  return $output
}

function Test-VmExists {
  param([string]$VmName)
  $list = Join-Lines (Invoke-VBoxManage -Arguments @("list", "vms") -IgnoreExitCode)
  return $list -match ('"' + [regex]::Escape($VmName) + '"')
}

function Test-VmRunning {
  param([string]$VmName)
  $list = Join-Lines (Invoke-VBoxManage -Arguments @("list", "runningvms") -IgnoreExitCode)
  return $list -match ('"' + [regex]::Escape($VmName) + '"')
}

function Ensure-VmPoweredOff {
  param([string]$VmName)
  if (Test-VmRunning -VmName $VmName) {
    Write-Status "Powering off VM: $VmName"
    Invoke-VBoxManage -Arguments @("controlvm", $VmName, "poweroff") -IgnoreExitCode | Out-Null
    Start-Sleep -Seconds 4
  }

  # A cloned VM can remain in "Saved" state and refuse hardware changes.
  # Discarding saved state is safe when no running execution exists.
  Invoke-VBoxManage -Arguments @("discardstate", $VmName) -IgnoreExitCode | Out-Null
}

function Remove-VmIfExists {
  param([string]$VmName)
  if (Test-VmExists -VmName $VmName) {
    Ensure-VmPoweredOff -VmName $VmName
    Write-Status "Removing existing VM: $VmName"
    Invoke-VBoxManage -Arguments @("unregistervm", $VmName, "--delete") -IgnoreExitCode | Out-Null
  }
}

function Ensure-NatNetwork {
  Write-Status "Updating NAT network: $NatNetworkName"
  Invoke-VBoxManage -Arguments @(
    "natnetwork", "modify",
    "--netname", $NatNetworkName,
    "--network", $NatNetworkCidr,
    "--dhcp", "on",
    "--enable"
  ) -IgnoreExitCode | Out-Null

  if ($LASTEXITCODE -eq 0) {
    return
  }

  Write-Status "Creating NAT network: $NatNetworkName ($NatNetworkCidr)"
  $addOutput = Invoke-VBoxManage -Arguments @(
    "natnetwork", "add",
    "--netname", $NatNetworkName,
    "--network", $NatNetworkCidr,
    "--dhcp", "on",
    "--enable"
  ) -IgnoreExitCode

  if ($LASTEXITCODE -eq 0) {
    return
  }

  if ((Join-Lines $addOutput) -match "already exists") {
    Invoke-VBoxManage -Arguments @(
      "natnetwork", "modify",
      "--netname", $NatNetworkName,
      "--network", $NatNetworkCidr,
      "--dhcp", "on",
      "--enable"
    ) | Out-Null
    return
  }

  throw "Failed to configure NAT network '$NatNetworkName': $(Join-Lines $addOutput)"
}

function Configure-VmNetwork {
  param([string]$VmName)
  Write-Status "Configuring NAT network for VM: $VmName"
  Invoke-VBoxManage -Arguments @(
    "modifyvm", $VmName,
    "--nic1", "natnetwork",
    "--nat-network1", $NatNetworkName,
    "--cableconnected1", "on"
  ) | Out-Null
}

function Start-VmIfNeeded {
  param([string]$VmName)
  if (Test-VmRunning -VmName $VmName) {
    return
  }
  Write-Status "Starting VM: $VmName"
  Invoke-VBoxManage -Arguments @("startvm", $VmName, "--type", "headless") | Out-Null
}

function Invoke-GuestRun {
  param(
    [string]$VmName,
    [string]$Command,
    [switch]$AsRoot
  )

  $commandB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Command))
  if ($AsRoot) {
    $wrapped = "echo '$Password' | sudo -S -p '' bash -lc ""echo '$commandB64' | base64 -d | bash"""
  } else {
    $wrapped = "echo '$commandB64' | base64 -d | bash"
  }

  $args = @(
    "guestcontrol", $VmName, "run",
    "--username=$Username",
    "--password=$Password",
    "--wait-stdout",
    "--wait-stderr",
    "--exe=/bin/bash",
    "--",
    "/bin/bash", "-lc", $wrapped
  )

  return Invoke-VBoxManage -Arguments $args
}

function Wait-GuestReady {
  param(
    [string]$VmName,
    [int]$TimeoutSeconds = 900
  )

  $started = Get-Date
  while ($true) {
    try {
      Invoke-GuestRun -VmName $VmName -Command "id -u" | Out-Null
      Write-Status "Guest ready: $VmName"
      return
    } catch {
      $elapsed = (Get-Date) - $started
      if ($elapsed.TotalSeconds -ge $TimeoutSeconds) {
        throw "Timed out waiting for guest readiness: $VmName"
      }
      Start-Sleep -Seconds 10
    }
  }
}

function Copy-RepoPayloadToGuest {
  param([string]$VmName)

  Write-Status "Creating guest payload directory on ${VmName}: $GuestRepoRoot"
  Invoke-VBoxManage -Arguments @(
    "guestcontrol", $VmName, "mkdir", "--parents",
    "--username=$Username",
    "--password=$Password",
    $GuestRepoRoot
  ) | Out-Null

  $items = @("ansible", "apps", "infra", "scripts", "docs", "README.md")
  foreach ($item in $items) {
    $hostPath = Join-Path $RepoRoot $item
    if (!(Test-Path $hostPath)) {
      throw "Missing required payload path: $hostPath"
    }

    Write-Status "Copying $item to $VmName"
    $copyArgs = @(
      "guestcontrol", $VmName, "copyto",
      "--username=$Username",
      "--password=$Password",
      "--target-directory=$GuestRepoRoot"
    )
    if (Test-Path $hostPath -PathType Container) {
      $copyArgs += "--recursive"
    }
    $copyArgs += $hostPath
    Invoke-VBoxManage -Arguments $copyArgs | Out-Null
  }
}

if (!(Test-Path $VBoxManagePath)) {
  throw "VBoxManage not found: $VBoxManagePath"
}
if (!(Test-Path $RepoRoot)) {
  throw "Repo root not found: $RepoRoot"
}
if ($WorkerCount -lt 1) {
  throw "WorkerCount must be >= 1"
}
if (!(Test-VmExists -VmName $ControlPlaneVmName)) {
  throw "Control-plane VM not found: $ControlPlaneVmName"
}

$workerNames = @()
for ($i = 1; $i -le $WorkerCount; $i++) {
  $workerNames += "$WorkerNamePrefix-$i"
}

Write-Status "Preparing VirtualBox network"
Ensure-NatNetwork

Write-Status "Stopping control-plane for worker clone workflow"
Ensure-VmPoweredOff -VmName $ControlPlaneVmName
Configure-VmNetwork -VmName $ControlPlaneVmName

foreach ($worker in $workerNames) {
  $exists = Test-VmExists -VmName $worker
  if ($exists -and $ForceRecreateWorkers) {
    Remove-VmIfExists -VmName $worker
    $exists = $false
  }

  if (-not $exists) {
    Write-Status "Cloning worker VM: $worker"
    Invoke-VBoxManage -Arguments @(
      "clonevm", $ControlPlaneVmName,
      "--name", $worker,
      "--register",
      "--mode", "machine"
    ) | Out-Null
  } else {
    Write-Status "Worker VM exists and will be reused: $worker"
  }

  Ensure-VmPoweredOff -VmName $worker
  Invoke-VBoxManage -Arguments @(
    "modifyvm", $worker,
    "--cpus", "$WorkerCpu",
    "--memory", "$WorkerMemoryMb"
  ) | Out-Null
  Configure-VmNetwork -VmName $worker
}

Start-VmIfNeeded -VmName $ControlPlaneVmName
foreach ($worker in $workerNames) {
  Start-VmIfNeeded -VmName $worker
}

Wait-GuestReady -VmName $ControlPlaneVmName
foreach ($worker in $workerNames) {
  Wait-GuestReady -VmName $worker
}

$guestPlatformRoot = $GuestRepoRoot
if ($SkipRepoCopy) {
  $guestPlatformRoot = "/opt/k8s-data-platform"
} else {
  Copy-RepoPayloadToGuest -VmName $ControlPlaneVmName
  foreach ($worker in $workerNames) {
    Copy-RepoPayloadToGuest -VmName $worker
  }
}

$joinScriptPath = "$guestPlatformRoot/scripts/generate_join_command.sh"
$workerJoinScriptPath = "$guestPlatformRoot/scripts/join_worker_node.sh"
$multiNodeScriptPath = "$guestPlatformRoot/scripts/configure_multinode_cluster.sh"

Write-Status "Generating kubeadm join command from control-plane"
$joinOutput = Invoke-GuestRun -VmName $ControlPlaneVmName -AsRoot -Command @"
chmod +x '$joinScriptPath'
'$joinScriptPath'
"@
$joinLine = $joinOutput | Where-Object { $_ -match '^kubeadm join ' } | Select-Object -Last 1
if ([string]::IsNullOrWhiteSpace($joinLine)) {
  throw "Could not parse kubeadm join command. Raw output:`n$(Join-Lines $joinOutput)"
}
$joinCommand = $joinLine.Trim()
$joinCommandB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($joinCommand))

foreach ($worker in $workerNames) {
  Write-Status "Joining worker to cluster: $worker"
  Invoke-GuestRun -VmName $worker -AsRoot -Command @"
chmod +x '$workerJoinScriptPath'
'$workerJoinScriptPath' --hostname '$worker' --join-command-b64 '$joinCommandB64'
"@ | Out-Null
}

if (-not $SkipOverlayApply) {
  $workerCsv = [string]::Join(",", $workerNames)
  Write-Status "Applying dev-multinode overlay from control-plane"
  Invoke-GuestRun -VmName $ControlPlaneVmName -AsRoot -Command @"
chmod +x '$multiNodeScriptPath'
'$multiNodeScriptPath' --env dev --overlay dev-multinode --workers '$workerCsv'
"@ | Out-Null
}

Write-Status "Cluster node status"
$nodes = Invoke-GuestRun -VmName $ControlPlaneVmName -AsRoot -Command "KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide"
Write-Host (Join-Lines $nodes)

Write-Status "Pod placement (data-platform-dev)"
$pods = Invoke-GuestRun -VmName $ControlPlaneVmName -AsRoot -Command "KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pods -n data-platform-dev -o wide"
Write-Host (Join-Lines $pods)

Write-Status "Multi-node bootstrap completed"

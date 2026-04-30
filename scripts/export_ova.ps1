Param(
  [string]$VmName = "k8s-data-platform",
  [string]$OutputDir = "C:\ffmpeg",
  [string]$DistDir = "C:\ffmpeg",
  [ValidateSet("auto", "vboxmanage", "ovftool")]
  [string]$Exporter = "auto",
  [string]$VBoxManage = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe",
  [string]$OvfTool = "C:\Program Files\VMware\VMware OVF Tool\ovftool.exe"
)

$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null

$vmx = Join-Path $OutputDir "$VmName.vmx"
$ova = Join-Path $DistDir "$VmName.ova"

function Invoke-VBoxManageExport {
  param(
    [string]$ToolPath
  )

  if (!(Test-Path $ToolPath)) {
    return $false
  }

  & $ToolPath export $VmName --output $ova
  return $true
}

function Invoke-OvfToolExport {
  param(
    [string]$ToolPath
  )

  if (!(Test-Path $vmx)) {
    throw "VMX not found: $vmx"
  }
  if (!(Test-Path $ToolPath)) {
    return $false
  }

  & $ToolPath --acceptAllEulas --skipManifestCheck $vmx $ova
  return $true
}

if ($Exporter -eq "vboxmanage") {
  if (!(Invoke-VBoxManageExport -ToolPath $VBoxManage)) {
    throw "VBoxManage not found: $VBoxManage"
  }
  Write-Host "OVA exported: $ova"
  exit 0
}

if ($Exporter -eq "ovftool") {
  if (!(Invoke-OvfToolExport -ToolPath $OvfTool)) {
    throw "OVF Tool not found: $OvfTool"
  }
  Write-Host "OVA exported: $ova"
  exit 0
}

if (Invoke-VBoxManageExport -ToolPath $VBoxManage) {
  Write-Host "OVA exported with VBoxManage: $ova"
  exit 0
}

if (Invoke-OvfToolExport -ToolPath $OvfTool) {
  Write-Host "OVA exported with OVF Tool: $ova"
  exit 0
}

throw "OVA export failed. VBoxManage='$VBoxManage', OvfTool='$OvfTool'"

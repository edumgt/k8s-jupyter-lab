Param(
  [string]$Vmrun = "C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe",
  [string]$OvfTool = "C:\Program Files (x86)\VMware\VMware Workstation\OVFTool\ovftool.exe",
  [string]$DistDir = "E:"
)

$ErrorActionPreference = "Stop"

$jobs = @(
  @{ Name = "k8s-data-platform"; Vmx = "C:\ffmpeg\cp.vmx"; Ova = (Join-Path $DistDir "k8s-data-platform.ova") },
  @{ Name = "k8s-worker-1"; Vmx = "C:\ffmpeg\w1.vmx"; Ova = (Join-Path $DistDir "k8s-worker-1.ova") },
  @{ Name = "k8s-worker-2"; Vmx = "C:\ffmpeg\w2.vmx"; Ova = (Join-Path $DistDir "k8s-worker-2.ova") },
  @{ Name = "k8s-worker-3"; Vmx = "C:\ffmpeg\w3.vmx"; Ova = (Join-Path $DistDir "k8s-worker-3.ova") }
)

if (!(Test-Path -LiteralPath $Vmrun)) {
  throw "vmrun.exe not found: $Vmrun"
}
if (!(Test-Path -LiteralPath $OvfTool)) {
  throw "ovftool.exe not found: $OvfTool"
}

if (!(Test-Path -LiteralPath $DistDir)) {
  throw "Destination path not found: $DistDir"
}
$running = @((& $Vmrun list) | Select-Object -Skip 1)

foreach ($job in $jobs) {
  Write-Host ("=== EXPORT {0}" -f $job.Name)
  if (!(Test-Path -LiteralPath $job.Vmx)) {
    throw "VMX not found: $($job.Vmx)"
  }

  if ($running -contains $job.Vmx) {
    Write-Host ("Stopping {0}" -f $job.Vmx)
    & $Vmrun stop $job.Vmx soft
    if ($LASTEXITCODE -ne 0) {
      & $Vmrun stop $job.Vmx hard
      if ($LASTEXITCODE -ne 0) {
        throw "Failed to stop VM: $($job.Vmx)"
      }
    }
  } else {
    Write-Host ("Already stopped: {0}" -f $job.Vmx)
  }

  Remove-Item -LiteralPath $job.Ova -Force -ErrorAction SilentlyContinue
  & $OvfTool --acceptAllEulas --skipManifestCheck $job.Vmx $job.Ova
  if ($LASTEXITCODE -ne 0) {
    throw "OVF export failed: $($job.Ova)"
  }
}

$manifestPath = Join-Path $DistDir "ova-sha256.txt"
$hashes = foreach ($job in $jobs) {
  Get-FileHash -LiteralPath $job.Ova -Algorithm SHA256 |
    ForEach-Object {
      "{0} *{1}" -f $_.Hash.ToLower(), [System.IO.Path]::GetFileName($_.Path)
    }
}
Set-Content -LiteralPath $manifestPath -Value $hashes -Encoding ascii

Get-Item @(
  (Join-Path $DistDir "k8s-data-platform.ova"),
  (Join-Path $DistDir "k8s-worker-1.ova"),
  (Join-Path $DistDir "k8s-worker-2.ova"),
  (Join-Path $DistDir "k8s-worker-3.ova"),
  $manifestPath
) | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize

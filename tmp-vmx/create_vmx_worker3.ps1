$dir = 'C:\ffmpeg'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$vmx = @'
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "14"
displayName = "k8s-worker-3"
guestOS = "otherlinux-64"
memsize = "2048"
numvcpus = "2"
scsi0.present = "TRUE"
scsi0.virtualDev = "lsilogic"
scsi0:0.present = "TRUE"
scsi0:0.fileName = "C:\Users\1\VirtualBox VMs\k8s-worker-3\k8s-worker-3-disk1.vmdk"
ethernet0.present = "FALSE"
'@
Set-Content -LiteralPath (Join-Path $dir 'k8s-worker-3.vmx') -Value $vmx -Encoding ASCII
Write-Output "WROTE: $dir\k8s-worker-3.vmx"

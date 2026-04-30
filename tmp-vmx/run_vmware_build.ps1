$ErrorActionPreference = 'Stop'
$repoPacker = '\\wsl.localhost\Ubuntu\home\Kubernetes-Jupyter-Sandbox\packer'
$template = '\\wsl.localhost\Ubuntu\home\Kubernetes-Jupyter-Sandbox\packer\k8s-data-platform-vmware.pkr.hcl'
$vars = '\\wsl.localhost\Ubuntu\home\Kubernetes-Jupyter-Sandbox\packer\variables.vmware.auto.pkrvars.hcl'

$env:PACKER_LOG = '1'
$env:PACKER_LOG_PATH = 'C:\ffmpeg\vmware-build.log'
$env:PACKER_CACHE_DIR = 'C:\ffmpeg\packer-cache'

Set-Location -LiteralPath $repoPacker
& 'C:\Users\1\AppData\Local\Microsoft\WinGet\Links\packer.exe' init $template
& 'C:\Users\1\AppData\Local\Microsoft\WinGet\Links\packer.exe' validate -var-file $vars $template
& 'C:\Users\1\AppData\Local\Microsoft\WinGet\Links\packer.exe' build -force -on-error=abort -var-file $vars $template

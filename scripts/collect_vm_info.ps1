<#
.SYNOPSIS
    VMware Workstation에서 실행 중인 VM 정보를 수집합니다.

.DESCRIPTION
    vmrun guest operations로 각 VM에 접속하여 hostname, IP, CPU, MEM, Disk, OS 정보를 수집합니다.
    nas-omv 는 계정이 다르므로 --nas-user / --nas-pass 로 별도 지정하거나 -SkipNasOmv 로 스킵합니다.

.PARAMETER GuestUser
    Ubuntu VM 공통 로그인 계정 (기본값: ubuntu)

.PARAMETER GuestPass
    Ubuntu VM 공통 로그인 비밀번호 (기본값: ubuntu)

.PARAMETER NasUser
    nas-omv 전용 계정

.PARAMETER NasPass
    nas-omv 전용 비밀번호

.PARAMETER SkipNasOmv
    nas-omv 수집을 건너뜁니다.

.PARAMETER VmrunPath
    vmrun.exe 경로 (기본값: VMware Workstation 표준 경로)

.PARAMETER OutputCsv
    결과를 저장할 CSV 경로 (선택)

.EXAMPLE
    .\collect_vm_info.ps1
    .\collect_vm_info.ps1 -SkipNasOmv
    .\collect_vm_info.ps1 -NasUser root -NasPass mypass -OutputCsv C:\vm_inventory.csv
#>

[CmdletBinding()]
param(
    [string]$GuestUser   = "ubuntu",
    [string]$GuestPass   = "ubuntu",
    [string]$NasUser     = "",
    [string]$NasPass     = "",
    [switch]$SkipNasOmv,
    [string]$VmrunPath   = "",
    [string]$OutputCsv   = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── vmrun.exe 경로 탐색 ──────────────────────────────────────────────────────
if (-not $VmrunPath) {
    $candidates = @(
        "C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe",
        "C:\Program Files\VMware\VMware Workstation\vmrun.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $VmrunPath = $c; break }
    }
}
if (-not $VmrunPath -or -not (Test-Path $VmrunPath)) {
    Write-Error "vmrun.exe 를 찾을 수 없습니다. -VmrunPath 로 직접 지정하세요."
    exit 1
}
Write-Host "[vmrun] $VmrunPath" -ForegroundColor Cyan

# ── 실행 중인 VM 목록 수집 ────────────────────────────────────────────────────
Write-Host "`n[1/3] 실행 중인 VM 목록 수집..." -ForegroundColor Yellow
$listOutput = & $VmrunPath list 2>&1
$vmxPaths   = $listOutput | Select-Object -Skip 1 | Where-Object { $_ -match '\.vmx$' }

if (-not $vmxPaths) {
    Write-Warning "실행 중인 VM이 없습니다."
    exit 0
}

Write-Host "  발견된 VM: $($vmxPaths.Count)개"
$vmxPaths | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }

# ── VM 이름 → 계정 매핑 ───────────────────────────────────────────────────────
# nas-omv 는 별도 처리, 나머지는 GuestUser/GuestPass 공통 사용
function Get-VmLabel($vmxPath) {
    return [System.IO.Path]::GetFileNameWithoutExtension($vmxPath)
}

# ── Guest 명령 실행 헬퍼 ─────────────────────────────────────────────────────
function Invoke-GuestScript {
    param(
        [string]$Vmx,
        [string]$User,
        [string]$Pass,
        [string]$Script,
        [string]$TmpGuest  = "/tmp/_vm_info_collect.txt",
        [string]$TmpHost   = [System.IO.Path]::GetTempFileName()
    )

    # 1) 스크립트를 게스트에서 실행하고 결과를 임시 파일에 저장
    $wrapped = "$Script > $TmpGuest 2>&1"
    $null = & $VmrunPath -T ws -gu $User -gp $Pass runScriptInGuest $Vmx "/bin/bash" "-c `"$wrapped`"" 2>&1

    # 2) 임시 파일을 호스트로 복사
    $null = & $VmrunPath -T ws -gu $User -gp $Pass copyFileFromGuestToHost $Vmx $TmpGuest $TmpHost 2>&1

    if (Test-Path $TmpHost) {
        $content = Get-Content $TmpHost -Raw -ErrorAction SilentlyContinue
        Remove-Item $TmpHost -Force -ErrorAction SilentlyContinue
        return $content
    }
    return $null
}

# ── 정보 수집 쿼리 ────────────────────────────────────────────────────────────
$infoScript = @'
printf "HOSTNAME=%s\n"  "$(hostname)"
printf "OS=%s\n"        "$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '\"')"
printf "IPS=%s\n"       "$(ip -4 a | awk '/inet / && !/127\.0\.0\.1/{printf "%s ", $2}')"
printf "CPU=%s\n"       "$(nproc)"
printf "MEM_TOTAL=%s\n" "$(free -h | awk '/^Mem/{print $2}')"
printf "MEM_USED=%s\n"  "$(free -h | awk '/^Mem/{print $3}')"
printf "DISK_SIZE=%s\n" "$(df -h / | awk 'NR==2{print $2}')"
printf "DISK_USED=%s\n" "$(df -h / | awk 'NR==2{print $3}')"
printf "DISK_USE%%=%s\n" "$(df -h / | awk 'NR==2{print $5}')"
printf "UPTIME=%s\n"    "$(uptime -p 2>/dev/null || uptime)"
'@

# ── 각 VM 정보 수집 ──────────────────────────────────────────────────────────
Write-Host "`n[2/3] 각 VM 정보 수집 중..." -ForegroundColor Yellow
$results = @()

foreach ($vmx in $vmxPaths) {
    $label = Get-VmLabel $vmx
    Write-Host "  >> $label ..." -NoNewline

    # nas-omv 처리
    $isNas = ($label -like "*nas*" -or $label -like "*omv*")
    if ($isNas -and $SkipNasOmv) {
        Write-Host " [SKIP - nas-omv]" -ForegroundColor DarkGray
        $results += [PSCustomObject]@{
            VM        = $label
            Hostname  = "(skipped)"
            OS        = "(skipped)"
            IPs       = ""
            CPU       = ""
            MemTotal  = ""; MemUsed  = ""
            DiskSize  = ""; DiskUsed = ""; DiskPct  = ""
            Uptime    = ""
            VMX       = $vmx
        }
        continue
    }

    $user = if ($isNas -and $NasUser) { $NasUser } else { $GuestUser }
    $pass = if ($isNas -and $NasPass) { $NasPass } else { $GuestPass }

    try {
        $raw = Invoke-GuestScript -Vmx $vmx -User $user -Pass $pass -Script $infoScript
        if (-not $raw) { throw "게스트 응답 없음" }

        # key=value 파싱
        $map = @{}
        $raw -split "`n" | Where-Object { $_ -match "^(\w[^=]*)=(.*)$" } | ForEach-Object {
            if ($_ -match "^([^=]+)=(.*)$") { $map[$Matches[1].Trim()] = $Matches[2].Trim() }
        }

        $results += [PSCustomObject]@{
            VM        = $label
            Hostname  = $map["HOSTNAME"]
            OS        = $map["OS"]
            IPs       = $map["IPS"]
            CPU       = $map["CPU"]
            MemTotal  = $map["MEM_TOTAL"]; MemUsed = $map["MEM_USED"]
            DiskSize  = $map["DISK_SIZE"]; DiskUsed = $map["DISK_USED"]; DiskPct = $map["DISK_USE%"]
            Uptime    = $map["UPTIME"]
            VMX       = $vmx
        }
        Write-Host " OK" -ForegroundColor Green
    }
    catch {
        Write-Host " FAILED ($_)" -ForegroundColor Red
        $results += [PSCustomObject]@{
            VM        = $label
            Hostname  = "ERROR"
            OS        = $_.ToString()
            IPs       = ""; CPU = ""; MemTotal = ""; MemUsed = ""
            DiskSize  = ""; DiskUsed = ""; DiskPct = ""
            Uptime    = ""
            VMX       = $vmx
        }
    }
}

# ── 결과 출력 ────────────────────────────────────────────────────────────────
Write-Host "`n[3/3] 수집 결과 ────────────────────────────────────────────" -ForegroundColor Yellow
$results | Format-Table -AutoSize VM, Hostname, OS, IPs, CPU, MemTotal, MemUsed, DiskSize, DiskPct, Uptime

# ── CSV 저장 (선택) ──────────────────────────────────────────────────────────
if ($OutputCsv) {
    $results | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
    Write-Host "CSV 저장 완료: $OutputCsv" -ForegroundColor Cyan
}

# ── README 업데이트용 Markdown 출력 ─────────────────────────────────────────
Write-Host "`n## VM 인벤토리 (Markdown 형식)" -ForegroundColor Cyan
Write-Host "| VM | Hostname | OS | IPs | CPU | MEM | Disk |"
Write-Host "|---|---|---|---|---|---|---|"
foreach ($r in $results) {
    $mem  = if ($r.MemUsed -and $r.MemTotal) { "$($r.MemUsed)/$($r.MemTotal)" } else { "-" }
    $disk = if ($r.DiskUsed -and $r.DiskSize) { "$($r.DiskUsed)/$($r.DiskSize) ($($r.DiskPct))" } else { "-" }
    Write-Host "| $($r.VM) | $($r.Hostname) | $($r.OS) | $($r.IPs) | $($r.CPU) | $mem | $disk |"
}

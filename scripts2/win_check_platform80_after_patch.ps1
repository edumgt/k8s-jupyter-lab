try {
  $r1 = Invoke-WebRequest -Uri 'http://platform.local' -Method GET -TimeoutSec 8 -UseBasicParsing
  Write-Output ('win_platform80_status=' + [int]$r1.StatusCode)
} catch {
  Write-Output ('win_platform80_error=' + $_.Exception.Message)
}
try {
  $r2 = Invoke-WebRequest -Uri 'http://platform.local:32347/lab?token=8cd9e8392bd313dcf651002c' -Method GET -TimeoutSec 8 -UseBasicParsing
  Write-Output ('win_platform32347_status=' + [int]$r2.StatusCode)
} catch {
  Write-Output ('win_platform32347_error=' + $_.Exception.Message)
}

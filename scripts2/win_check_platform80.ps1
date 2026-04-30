try {
  $r = Invoke-WebRequest -Uri 'http://platform.local' -Method GET -TimeoutSec 8 -UseBasicParsing
  Write-Output ('win_platform80_status=' + [int]$r.StatusCode)
} catch {
  if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
    Write-Output ('win_platform80_http_error=' + [int]$_.Exception.Response.StatusCode)
  }
  Write-Output ('win_platform80_error=' + $_.Exception.Message)
}

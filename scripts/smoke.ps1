<#
.SYNOPSIS
  Post-deploy smoke test (same checks the CI pipeline will run on EKS).
  Exits 1 on the first failed check.
#>
param(
    [string]$BaseUrl = "http://localhost:8080",
    [string]$RequesterKey = "alice-local-key",
    [string]$ApproverKey = "bob-local-key",
    [int]$TimeoutSeconds = 60
)
$ErrorActionPreference = "Stop"

function Call($method, $path, $key, $body = $null) {
    $headers = @{}
    if ($key) { $headers["X-API-Key"] = $key }
    $params = @{ Method = $method; Uri = "$BaseUrl$path"; Headers = $headers; ContentType = "application/json" }
    if ($null -ne $body) { $params["Body"] = ($body | ConvertTo-Json -Depth 5) }
    try {
        $resp = Invoke-WebRequest @params -UseBasicParsing
        return @{ Status = [int]$resp.StatusCode; Body = ($resp.Content | ConvertFrom-Json) }
    } catch {
        $r = $_.Exception.Response
        if ($null -eq $r) { throw }
        return @{ Status = [int]$r.StatusCode; Body = $null }
    }
}
function Check($name, $ok) {
    if ($ok) { Write-Host "  PASS  $name" -ForegroundColor Green }
    else { Write-Host "  FAIL  $name" -ForegroundColor Red; exit 1 }
}

# Wait for the LoadBalancer to answer
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
do {
    try { $ready = Call GET "/readyz" $null } catch { $ready = @{ Status = 0 } }
    if ($ready.Status -eq 200) { break }
    Start-Sleep -Seconds 2
} while ((Get-Date) -lt $deadline)
Check "readyz returns 200" ($ready.Status -eq 200)

try { $ui = Invoke-WebRequest -Uri "$BaseUrl/ui/" -UseBasicParsing } catch { $ui = $null }
Check "web UI served with a Content-Security-Policy" ($ui -and $ui.StatusCode -eq 200 -and $ui.Headers["Content-Security-Policy"])

Check "request without API key is rejected (401)" ((Call GET "/tickets" $null).Status -eq 401)
Check "alert webhook requires its bearer token (401)" ((Call POST "/integrations/alertmanager" $null @{ alerts = @() }).Status -eq 401)

$created = Call POST "/tickets" $RequesterKey @{
    type = "access_request"; title = "Smoke test: read-only on staging"; priority = "low"; team = "platform"
    access = @{ resource = "staging-eks"; requested_role = "read-only"; justification = "smoke test"; duration_days = 1 }
}
Check "create access request (201)" ($created.Status -eq 201)
$id = $created.Body.id
Check "ticket auto-assigned to an approver" ($null -ne $created.Body.assignee_id)

Check "requester cannot approve (403)" ((Call POST "/tickets/$id/approve" $RequesterKey @{}).Status -eq 403)
$approved = Call POST "/tickets/$id/approve" $ApproverKey @{ reason = "smoke test" }
Check "approver approves (200)" ($approved.Status -eq 200 -and $approved.Body.access_request.decision -eq "approved")
Check "second decision conflicts (409)" ((Call POST "/tickets/$id/reject" $ApproverKey @{}).Status -eq 409)

$own = Call POST "/tickets" $ApproverKey @{
    type = "access_request"; title = "Smoke test: self-approval"
    access = @{ resource = "prod-eks"; requested_role = "admin"; justification = "should be blocked" }
}
Check "self-approval blocked (403)" ((Call POST "/tickets/$($own.Body.id)/approve" $ApproverKey @{}).Status -eq 403)

Check "invalid status jump rejected (409)" ((Call PATCH "/tickets/$id/status" $ApproverKey @{ status = "closed" }).Status -eq 409)

# Worker end-to-end: both notifications (created + approved) must reach "sent"
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
do {
    $notes = (Call GET "/tickets/$id/notifications" $RequesterKey).Body
    $sent = @($notes | Where-Object { $_.status -eq "sent" }).Count
    if ($sent -ge 2) { break }
    Start-Sleep -Seconds 2
} while ((Get-Date) -lt $deadline)
Check "worker delivered both notifications" ($sent -ge 2)

$audit = (Call GET "/tickets/$id/audit" $ApproverKey).Body
Check "audit trail recorded with trace_id" ($audit.Count -ge 2 -and $audit[0].trace_id)
Write-Host "`nSmoke test passed. Ticket #$id, trace_id $($audit[0].trace_id) (search it in Grafana > Explore > Tempo)" -ForegroundColor Green

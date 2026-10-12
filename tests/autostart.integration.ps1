param([Parameter(Mandatory)][string]$TestExe)

$ErrorActionPreference = 'Stop'
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$taskName = "DeepSeek Harness Launcher Autostart Test - $sid"
$TestExe = (Resolve-Path -LiteralPath $TestExe).Path

try {
    & $TestExe disable
    if ($LASTEXITCODE -ne 0) { throw 'Deleting an absent autostart task must succeed.' }
    & $TestExe query
    if ($LASTEXITCODE -ne 1) { throw 'An absent autostart task must report disabled.' }
    & $TestExe enable
    if ($LASTEXITCODE -ne 0) { throw 'Registering elevated autostart failed.' }
    & $TestExe query
    if ($LASTEXITCODE -ne 0) { throw 'Registered autostart must report enabled.' }
    & $TestExe query-path
    if ($LASTEXITCODE -ne 0) { throw 'Registered autostart must match the running executable.' }

    $task = Get-ScheduledTask -TaskName $taskName
    if ($task.Principal.RunLevel -ne 'Highest' -or $task.Principal.LogonType -ne 'Interactive') { throw 'Autostart must use highest privileges in the interactive user session.' }
    if ($task.Actions.Execute -ne $TestExe) { throw 'Autostart must preserve the exact executable path, including XML characters.' }
    if ($task.Actions.WorkingDirectory -ne (Split-Path -Parent $TestExe)) { throw 'Autostart must use the executable directory.' }
    if ($task.Settings.ExecutionTimeLimit -ne 'PT0S') { throw 'Autostart must not have an execution time limit.' }
    if ($task.Settings.DisallowStartIfOnBatteries -or $task.Settings.StopIfGoingOnBatteries) { throw 'Autostart must work on battery power.' }
    if ($task.Triggers.Delay -ne 'PT10S') { throw 'Autostart must allow the desktop to initialise before launching.' }
    $triggerUser = $task.Triggers.UserId
    $triggerSid = if ($triggerUser -like 'S-1-*') { $triggerUser } else { [Security.Principal.NTAccount]::new($triggerUser).Translate([Security.Principal.SecurityIdentifier]).Value }
    if ($triggerSid -ne $sid) { throw 'Autostart must only trigger for the current user.' }

    $otherAction = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\notepad.exe"
    Set-ScheduledTask -TaskName $taskName -Action $otherAction | Out-Null
    & $TestExe query-path
    if ($LASTEXITCODE -ne 1) { throw 'A task pointing elsewhere must not replace the current executable Run entry.' }

    Disable-ScheduledTask -TaskName $taskName | Out-Null
    & $TestExe query
    if ($LASTEXITCODE -ne 1) { throw 'A disabled autostart task must report disabled.' }
    & $TestExe enable
    if ($LASTEXITCODE -ne 0) { throw 'Re-enabling existing autostart failed.' }
    & $TestExe query
    if ($LASTEXITCODE -ne 0) { throw 'Re-enabled autostart must report enabled.' }
    & $TestExe disable
    if ($LASTEXITCODE -ne 0) { throw 'Removing autostart failed.' }
    & $TestExe query
    if ($LASTEXITCODE -ne 1) { throw 'Removed autostart must report disabled.' }
    Write-Host 'autostart integration tests passed.'
} finally {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false }
}
$global:LASTEXITCODE = 0

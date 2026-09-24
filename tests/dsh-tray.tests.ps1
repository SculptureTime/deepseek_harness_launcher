$ErrorActionPreference = 'Stop'
$NoTray = $true
. (Join-Path $PSScriptRoot '..\assets\dsh-tray.ps1')

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "$Message`nExpected: $Expected`nActual:   $Actual" }
}

# A DSH Web process that owns the configured port must still be recognized even
# when the in-memory tracked PID has been lost.
$startCommand = @('node', '--import', 'tsx/esm', 'apps/cli/src/bin.ts', 'web', '--port', $port)
$launcher = Get-Command $startCommand[0] -CommandType Application -ErrorAction SilentlyContinue
$mockExecutablePath = if ($launcher) { $launcher.Path } else { [string]$startCommand[0] }
function Get-CimInstance {
    [pscustomobject]@{
        ProcessId = 4242
        Name = 'node.exe'
        ExecutablePath = $mockExecutablePath
        CommandLine = [string]::Join(' ', [string[]]$startCommand) + ' --no-open'
    }
}
$script:trackedPid = 0
$managed = @(Get-ManagedLocalOwnerPids @(4242))
Assert-Equal 1 $managed.Count 'Configured DSH Web process should be recognized as tray-managed.'
Assert-Equal 4242 $managed[0] 'Managed PID should match the port owner.'

# Keep the PowerShell source ASCII-only while proving the runtime UI strings are Chinese.
$startTextBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($uiText.StartServer))
$restartTextBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($uiText.RestartServer))
Assert-Equal '5ZCv5Yqo5pyN5Yqh' $startTextBase64 'Start menu text should be Chinese.'
Assert-Equal '6YeN5ZCv5pyN5Yqh' $restartTextBase64 'Restart menu text should be Chinese.'

Write-Host 'dsh-tray tests passed.'

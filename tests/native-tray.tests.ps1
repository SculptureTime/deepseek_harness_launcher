$ErrorActionPreference = 'Stop'

$source = Get-Content (Join-Path $PSScriptRoot '..\native\dsh-tray.c') -Raw
$resource = Get-Content (Join-Path $PSScriptRoot '..\native\dsh-tray.rc') -Raw

function Assert-Contains([string]$Text, [string]$Expected, [string]$Message) {
    if (-not $Text.Contains($Expected)) { throw "$Message`nMissing: $Expected" }
}

function Assert-NotContains([string]$Text, [string]$Unexpected, [string]$Message) {
    if ($Text.Contains($Unexpected)) { throw "$Message`nUnexpected: $Unexpected" }
}

Assert-NotContains $source 'SetCurrentProcessExplicitAppUserModelID' 'Portable tray must not set an unregistered AppUserModelID because Windows can suppress notifications.'
Assert-Contains $source 'g_nid.hBalloonIcon = g_icon;' 'Notification should explicitly use the DeepSeek Harness icon.'
Assert-Contains $source 'NIIF_USER' 'Notification should request the custom application icon.'
Assert-Contains $source 'NOTIFYICON_VERSION_4' 'Tray icon should opt into the modern Shell notification behavior.'
Assert-Contains $source 'SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)' 'Tray process should be per-monitor DPI aware for crisp context menus.'
Assert-Contains $source 'static bool g_starting;' 'Native tray should track the service startup phase.'
Assert-Contains $source 'static int g_operation = OP_NONE;' 'Native tray should track the active start/stop/restart operation.'
Assert-Contains $source 'bool operation_busy = g_operation != OP_NONE;' 'All service commands should share one operation-busy state.'
Assert-Contains $source 'CMD_START, MF_BYCOMMAND | (!operation_busy && !running ? MF_ENABLED : MF_GRAYED)' 'Start should stay disabled while any service operation is running.'
Assert-Contains $source 'CMD_STOP, MF_BYCOMMAND | (!operation_busy && running ? MF_ENABLED : MF_GRAYED)' 'Stop should stay disabled while any service operation is running.'
Assert-Contains $source 'CMD_RESTART, MF_BYCOMMAND | (!operation_busy && running ? MF_ENABLED : MF_GRAYED)' 'Restart should stay disabled while any service operation is running.'
Assert-NotContains $source 'D:\\\\dev\\\\nvm\\\\installs\\\\v24.11.1\\\\node.exe' "Portable tray must not hard-code one machine's Node path."
Assert-NotContains $source 'http://127.0.0.1:7890' 'Portable tray must not hard-code a proxy port.'
Assert-Contains $source 'SearchPathW(NULL, L"dsh.cmd"' 'Portable tray should resolve the installed DSH command from PATH.'
Assert-Contains $source 'ProxyServer' 'Portable tray should read the current Windows proxy settings.'
Assert-Contains $source 'WM_ACTIVATE_INSTANCE' 'A second launch should activate the existing tray instance.'
Assert-Contains $source 'PostMessageW(existing, WM_ACTIVATE_INSTANCE' 'A second launch should ask the existing tray to open the Web UI instead of starting another instance.'
Assert-Contains $source 'ConfigureChildProxy();' 'Proxy settings should be refreshed each time DSH starts.'
Assert-Contains $source 'hide-powershell-console.cjs' 'Tray should inject the PowerShell console-hiding preload into DSH.'
Assert-Contains $source 'windowsHide: true' 'The preload should hide implicit PowerShell console windows.'
Assert-Contains $source 'syncBuiltinESMExports' 'The preload should sync patched child_process exports for ESM plugins.'
Assert-Contains $source 'NIF_SHOWTIP' 'Version 4 tray icons must request the standard hover tooltip explicitly.'
Assert-Contains $source 'static const wchar_t *APP_NAME = L"DeepSeek Harness Launcher";' 'Native tray should use the unified launcher application name.'
Assert-Contains $source 'L"%s - 运行中（:%d）"' 'Running tooltip should expose the current service state.'
Assert-Contains $source 'L"%s - 已停止（:%d）"' 'Stopped tooltip should expose the current service state.'
Assert-Contains $source 'APP_NAME, DSH_PORT' 'Tray tooltip should format the unified application name with the service port.'
Assert-Contains $resource 'VALUE "FileDescription", "DeepSeek Harness Launcher"' 'Executable metadata should use the unified launcher application name.'
Assert-Contains $resource 'VALUE "ProductName", "DeepSeek Harness Launcher"' 'Executable product name should use the unified launcher application name.'

Write-Host 'native tray tests passed.'

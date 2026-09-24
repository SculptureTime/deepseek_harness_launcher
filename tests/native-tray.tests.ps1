$ErrorActionPreference = 'Stop'

$source = Get-Content (Join-Path $PSScriptRoot '..\native\dsh-tray.c') -Raw
$resource = Get-Content (Join-Path $PSScriptRoot '..\native\dsh-tray.rc') -Raw
$release = Get-Content (Join-Path $PSScriptRoot '..\.github\workflows\release.yml') -Raw

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
Assert-NotContains $source 'NODE_OPTIONS' 'Launcher must not inject NODE_OPTIONS into DSH because the known-good executable does not alter Node startup options.'
Assert-NotContains $source 'hide-powershell-console.cjs' 'Launcher must not inject a Node preload into DSH because the known-good executable starts without one.'
Assert-Contains $source 'NIF_SHOWTIP' 'Version 4 tray icons must request the standard hover tooltip explicitly.'
Assert-Contains $source 'static const wchar_t *APP_NAME = L"DeepSeek Harness Launcher";' 'Native tray should use the unified launcher application name.'
Assert-Contains $source 'L"%s - 运行中（:%d）"' 'Running tooltip should expose the current service state.'
Assert-Contains $source 'L"%s - 已停止（:%d）"' 'Stopped tooltip should expose the current service state.'
Assert-Contains $source 'APP_NAME, DSH_PORT' 'Tray tooltip should format the unified application name with the service port.'
Assert-Contains $resource 'VALUE "FileDescription", "DeepSeek Harness Launcher"' 'Executable metadata should use the unified launcher application name.'
Assert-Contains $resource 'VALUE "ProductName", "DeepSeek Harness Launcher"' 'Executable product name should use the unified launcher application name.'
Assert-Contains $resource 'VALUE "FileVersion", "1.0.8"' 'Executable metadata should match release version 1.0.8.'
Assert-Contains $source 'L"DeepSeek Harness Launcher 已就绪，右键图标可进行控制。"' 'Ready notification should use the unified launcher application name.'
Assert-NotContains $source 'L"DeepSeek Harness 已就绪，右键图标可进行控制。"' 'Ready notification must not expose the legacy application name.'
Assert-Contains $release 'ilammy/msvc-dev-cmd@v1' 'Release build must initialize the MSVC toolchain used by the working launcher.'
Assert-Contains $release 'rc /nologo /fo dsh-tray.res dsh-tray.rc' 'Release build must compile Windows resources with rc.'
Assert-Contains $release 'cl /nologo /W4 /O2 /MT' 'Release build must use MSVC with the static runtime.'
Assert-Contains $release '/SUBSYSTEM:WINDOWS' 'Release build must produce a Windows GUI executable without a console window.'
Assert-NotContains $release 'zig cc' 'Release must not switch back to the GNU ABI build that failed to launch DSH.'
Assert-Contains $release 'Compress-Archive' 'Release should package the launcher so the exact spaced EXE filename is preserved.'
Assert-Contains $release 'DeepSeek-Harness-Launcher.zip' 'Release archive should use a GitHub-safe filename.'

Write-Host 'native tray tests passed.'

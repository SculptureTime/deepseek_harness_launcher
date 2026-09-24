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
Assert-Contains $source 'static wchar_t g_dsh_script[MAX_PATH];' 'Launcher should resolve the DSH JavaScript entry point for direct Node startup.'
Assert-Contains $source 'const wchar_t *application = g_node_path;' 'Launcher should prefer direct Node startup to avoid a console wrapper.'
Assert-Contains $source 'ProxyServer' 'Portable tray should read the current Windows proxy settings.'
Assert-Contains $source 'WM_ACTIVATE_INSTANCE' 'A second launch should activate the existing tray instance.'
Assert-Contains $source 'PostMessageW(existing, WM_ACTIVATE_INSTANCE' 'A second launch should ask the existing tray to open the Web UI instead of starting another instance.'
Assert-Contains $source 'ConfigureChildProxy();' 'Proxy settings should be refreshed each time DSH starts.'
Assert-Contains $source 'STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW' 'Launcher should explicitly hide the command wrapper window.'
Assert-Contains $source 'startup.wShowWindow = SW_HIDE;' 'Launcher should start the command wrapper hidden.'
Assert-NotContains $source 'NODE_OPTIONS' 'Launcher must not inject NODE_OPTIONS into DSH because the known-good executable does not alter Node startup options.'
Assert-NotContains $source 'hide-powershell-console.cjs' 'Launcher must not inject a Node preload into DSH because the known-good executable starts without one.'
Assert-Contains $source 'NIF_SHOWTIP' 'Version 4 tray icons must request the standard hover tooltip explicitly.'
Assert-Contains $source 'static const wchar_t *APP_NAME = L"DeepSeek Harness Launcher";' 'Native tray should use the unified launcher application name.'
Assert-Contains $source 'if (g_operation == OP_RESTART) status = L"重启中";' 'Restart should be visible in the tray tooltip.'
Assert-Contains $source 'else if (g_operation == OP_START || g_starting) status = L"启动中";' 'Startup should be visible in the tray tooltip instead of appearing stopped.'
Assert-Contains $source 'else if (g_operation == OP_STOP) status = L"停止中";' 'Stop should be visible in the tray tooltip.'
Assert-Contains $source 'else if (running) status = L"运行中";' 'Running tooltip should expose the current service state.'
Assert-Contains $source 'const wchar_t *status = L"已停止";' 'Stopped tooltip should expose the current service state.'
Assert-Contains $source 'L"%s - %s（:%d）"' 'Tray tooltip should format the application name, operation state and service port.'
Assert-Contains $resource 'VALUE "FileDescription", "DeepSeek Harness Launcher"' 'Executable metadata should use the unified launcher application name.'
Assert-Contains $resource 'VALUE "ProductName", "DeepSeek Harness Launcher"' 'Executable product name should use the unified launcher application name.'
Assert-Contains $resource 'VALUE "FileVersion", "1.0.11"' 'Executable metadata should match release version 1.0.11.'
Assert-Contains $source 'L"DeepSeek Harness Launcher 已就绪，右键图标可进行控制。"' 'Ready notification should use the unified launcher application name.'
Assert-NotContains $source 'L"DeepSeek Harness 已就绪，右键图标可进行控制。"' 'Ready notification must not expose the legacy application name.'
Assert-Contains $release 'ilammy/msvc-dev-cmd@v1' 'Release build must initialize the MSVC toolchain used by the working launcher.'
Assert-Contains $release 'rc /nologo /fo dsh-tray.res dsh-tray.rc' 'Release build must compile Windows resources with rc.'
Assert-Contains $release 'cl /nologo /W4 /O2 /MT /utf-8' 'Release build must use MSVC with the static runtime and compile Chinese source as UTF-8.'
Assert-Contains $release '/SUBSYSTEM:WINDOWS' 'Release build must produce a Windows GUI executable without a console window.'
Assert-NotContains $release 'zig cc' 'Release must not switch back to the GNU ABI build that failed to launch DSH.'
Assert-Contains $release 'Compress-Archive' 'Release should package the launcher so the exact spaced EXE filename is preserved.'
Assert-Contains $release 'DeepSeek-Harness-Launcher.zip' 'Release archive should use a GitHub-safe filename.'
Assert-Contains $release 'Launcher failed to start fake DSH on port 3080.' 'Release must smoke-test the real launcher startup path before publishing.'
Assert-Contains $release 'Launcher startup must not create a cmd.exe child' 'Release must verify direct startup does not create the console wrapper that can flash.'
Assert-NotContains $release '-lt 500KB' 'Release validation must not assume the legacy executable size.'

Write-Host 'native tray tests passed.'

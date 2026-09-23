# DSH Web system-tray launcher (standalone, download-and-run).
# Keeps the server running HEADLESS (no console window) and uses the tray
# icon as the control surface: start / stop / restart / open UI / show logs,
# plus a launch-at-login toggle.
#
# Usage: (optional) copy dsh-tray.config.example.ps1 to dsh-tray.config.ps1 and
# edit it, then run:
#   powershell -File dsh-tray.ps1
# (or double-click it). To load the functions without showing the tray
# (used by tests), run from PowerShell:  $NoTray = $true; . .\dsh-tray.ps1
#
# NOTE: ASCII-only. PowerShell 5.1 reads .ps1 as the system codepage and
# non-ASCII breaks string parsing.

# $NoTray defaults to false; a caller that dot-sources the script may set it
# first to load the functions without launching the tray.
if (-not (Test-Path variable:NoTray)) { $NoTray = $false }

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ===== CONFIG =====
# User config lives in dsh-tray.config.ps1 next to this script. Copy
# dsh-tray.config.example.ps1 to that name and edit it. It is NOT tracked by
# git, so your host/key paths stay local. If it is missing, the defaults below
# are used. Any value the config file sets overrides the matching default.
$scriptDir = try { Split-Path -Parent $MyInvocation.MyCommand.Definition } catch { $null }
if (-not $scriptDir) { $scriptDir = $PSScriptRoot }
$configFile = Join-Path $scriptDir 'dsh-tray.config.ps1'

# --- defaults (overridden by dsh-tray.config.ps1 when present) ---
$port = 3080
# Root of the DeepSeek Harness repo (local mode). The server is started from
# here so apps/cli/src/bin.ts and tsx resolve correctly.
$workDir = 'E:\2026Workplace\Code\deepseek-harness'
# Command to start the server locally (local mode). The first element is
# resolved via PATH; the rest are its arguments.
$startCommand = @('node', '--import', 'tsx/esm', 'apps/cli/src/bin.ts', 'web', '--port', $port)
# Log files for the server output (used by "Show Logs").
$logOut = Join-Path $env:TEMP 'dsh-tray.out.log'
$logErr = Join-Path $env:TEMP 'dsh-tray.err.log'
# Start the server automatically on launch if it is not already running.
$autoStart = $true
# How often (ms) the tray re-checks the server port to refresh icon/menu state.
$pollIntervalMs = 3000
# 'local' runs the server on this machine; 'remote' launches it on a cloud host
# over SSH and tunnels it to 127.0.0.1:$port.
$mode = 'local'
# --- remote mode config (only used when $mode = 'remote') ---
$sshHost = 'ubuntu@your-cloud-host.example.com'   # user@host
$sshKey  = Join-Path $env:USERPROFILE '.ssh\DSH.pem'  # identity file
# Remote command that starts the server (must bind 127.0.0.1 so the tunnel reaches it).
$remoteStartCommand = 'dsh web --port ' + $port
# Also kill the server on the cloud host when stopping (otherwise it keeps running).
$stopRemoteServer = $true
# Load the user config last so any value it sets overrides the defaults above.
if (Test-Path -LiteralPath $configFile) { . $configFile }
# ============================

$wt = Get-Command wt.exe -ErrorAction SilentlyContinue

$runKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runValueName = 'DSH Tray'

# --- Script-scope runtime state ---
$script:trackedPid = 0          # root PID of the server THIS tray instance started
$script:lastRunning = $null     # last known running state (for transitions)
$script:suppressUntil = [datetime]::MinValue  # skip crash/exit balloons until here
$script:openWhenUp = $false     # open the Web UI locally once the server is up

function ConvertFrom-Base64Text([string]$Text) {
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Text))
}

# Keep the script ASCII-only for Windows PowerShell 5.1 while displaying Chinese UI text.
$uiText = @{
    TitleTray = ConvertFrom-Base64Text 'RFNIIOaJmOebmA=='
    OpenUI = ConvertFrom-Base64Text '5omT5byAIFdlYiDnlYzpnaI='
    ShowLogs = ConvertFrom-Base64Text '5p+l55yL5pel5b+X77yIV2luZG93cyBUZXJtaW5hbO+8iQ=='
    StartServer = ConvertFrom-Base64Text '5ZCv5Yqo5pyN5Yqh'
    StopServer = ConvertFrom-Base64Text '5YGc5q2i5pyN5Yqh'
    RestartServer = ConvertFrom-Base64Text '6YeN5ZCv5pyN5Yqh'
    LaunchAtLogin = ConvertFrom-Base64Text '5byA5py66Ieq5Yqo5ZCv5Yqo'
    ExitStopServer = ConvertFrom-Base64Text '6YCA5Ye677yI5YGc5q2i5pyN5Yqh77yJ'
    LauncherNotFound = ConvertFrom-Base64Text '5om+5LiN5Yiw5ZCv5Yqo56iL5bqP4oCcezB94oCd44CCCuivt+WcqCBkc2gtdHJheS5wczEg5Lit5qOA5p+lICRzdGFydENvbW1hbmTjgII='
    SshNotFound = ConvertFrom-Base64Text (
        '5om+5LiN5YiwIHNzaC5leGXjgIIKV2luZG93cyAxMCDlj4rku6XkuIrns7vnu5/lj6/lkK/nlKggT3BlblNTSO+8jOaIluWwhiBzc2guZXhlIOWKoOWFpSBQQVRI44CC'
    )
    SshKeyNotFound = ConvertFrom-Base64Text '5om+5LiN5YiwIFNTSCDlr4bpkqXvvJp7MH0K6K+35ZyoIGRzaC10cmF5LnBzMSDkuK3mo4Dmn6UgJHNzaEtleeOAgg=='
    UnknownPortOwner = ConvertFrom-Base64Text (
        '56uv5Y+jIHswfSDlt7LooqsgezF9IOWNoOeUqO+8jOS9huivpei/m+eoi+W5tumdnueUsSBEU0ggVHJheSDlkK/liqjjgIIKCuS7jeimgeW8uuWItuWBnOatouWQl++8nw=='
    )
    StartingRemote = ConvertFrom-Base64Text '5q2j5Zyo5ZCv5Yqo5LqR56uv5pyN5Yqh5ZKM6Zqn6YGT77yM5pyN5Yqh5bCx57uq5ZCO5bCG5omT5byAIFdlYiDnlYzpnaIuLi4='
    StartingLocal = ConvertFrom-Base64Text '5q2j5Zyo5ZCv5Yqo5pyN5Yqh77yaaHR0cDovLzEyNy4wLjAuMTp7MH0gLi4u'
    Stopping = ConvertFrom-Base64Text '5q2j5Zyo5YGc5q2i5pyN5YqhLi4u'
    Restarting = ConvertFrom-Base64Text '5q2j5Zyo6YeN5ZCv5pyN5YqhLi4u'
    LoginEnabled = ConvertFrom-Base64Text 'RFNIIFRyYXkg5bey6K6+5Li65byA5py66Ieq5Yqo5ZCv5Yqo44CC'
    LoginDisabled = ConvertFrom-Base64Text 'RFNIIFRyYXkg5bey5Y+W5raI5byA5py66Ieq5Yqo5ZCv5Yqo44CC'
    UnexpectedExit = ConvertFrom-Base64Text '5pyN5Yqh5oSP5aSW6YCA5Ye677yI56uv5Y+jIHswfSDlt7Lph4rmlL7vvInjgII='
    DetectedRunning = ConvertFrom-Base64Text '5bey5qOA5rWL5Yiw5pyN5Yqh5q2j5Zyo6L+Q6KGM77yaaHR0cDovLzEyNy4wLjAuMTp7MH0='
    OpeningUI = ConvertFrom-Base64Text '5q2j5Zyo5omT5byAIFdlYiDnlYzpnaLvvJp7MH0='
    RunningTooltip = ConvertFrom-Base64Text 'RFNIIFdlYiAtIOi/kOihjOS4re+8iDp7MH3vvIk='
    StoppedTooltip = ConvertFrom-Base64Text 'RFNIIFdlYiAtIOW3suWBnOatou+8iDp7MH3vvIk='
    TrayReady = ConvertFrom-Base64Text 'RFNIIFdlYiDmiZjnm5jlt7LlsLHnu6rvvJpodHRwOi8vMTI3LjAuMC4xOnswfQrlj7PplK7ngrnlh7vlm77moIflj6/ov5vooYzmjqfliLbjgII='
}

function Get-PortOwnerPids {
    $c = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    @($c.OwningProcess | Where-Object { $_ -ne 0 } | Sort-Object -Unique)
}

function Get-ManagedLocalOwnerPids {
    param([int[]]$OwnerPids)
    if (-not $OwnerPids -or -not $OwnerPids.Count) { return @() }

    $launcher = Get-Command $startCommand[0] -CommandType Application -ErrorAction SilentlyContinue
    $expectedExe = if ($launcher) { $launcher.Path } else { [string]$startCommand[0] }
    $serverArg = $startCommand | Where-Object { [string]$_ -match '(?i)bin\.(?:js|ts)$' } | Select-Object -First 1
    return @($OwnerPids | Where-Object {
            $proc = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $_) -ErrorAction SilentlyContinue
            if (-not $proc -or -not $proc.CommandLine) { return $false }
            if ($proc.ExecutablePath -and $expectedExe -and
                -not [string]::Equals($proc.ExecutablePath, $expectedExe, [StringComparison]::OrdinalIgnoreCase)) { return $false }
            $commandLine = [string]$proc.CommandLine
            if ($serverArg -and $commandLine.IndexOf([string]$serverArg, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
            return $commandLine -match '(?i)(?:^|\s)web(?:\s|$)' -and $commandLine -match ('(?i)--port\s+' + [regex]::Escape([string]$port) + '(?:\s|$)')
        })
}

function Get-DshRunning {
    if ($mode -eq 'local') {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $connect = $client.BeginConnect('127.0.0.1', $port, $null, $null)
            if (-not $connect.AsyncWaitHandle.WaitOne(100)) { return $false }
            $client.EndConnect($connect)
            return $client.Connected
        } catch {
            return $false
        } finally {
            $client.Close()
        }
    }

    if (-not (Get-PortOwnerPids).Count) { return $false }
    # In remote mode the local port is only the ssh tunnel. A TCP connect to it
    # always succeeds (ssh accepts locally) even when the cloud server is down, so
    # probe the server itself: it is "ready" only once dsh web actually serves
    # HTTP. This keeps the icon/browser from going live while the server warms up
    # (which otherwise leaves the browser spinning forever).
    try {
        $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$port/")
        $req.Timeout = 1500
        $req.Method = 'GET'
        $resp = $req.GetResponse()
        $resp.Close()
        return $true
    } catch [System.Net.WebException] {
        # A response (even non-2xx) means the server answered => it is up.
        # Only a connection failure (tunnel forwards to nothing) means not ready.
        if ($_.Exception.Response -ne $null) { return $true }
        return $false
    } catch {
        return $false
    }
}

function Get-DshWebUrl {
    $fallback = "http://127.0.0.1:$port"
    if ($mode -ne 'local' -or -not (Test-Path -LiteralPath $logOut)) { return $fallback }
    $line = Get-Content -LiteralPath $logOut -ErrorAction SilentlyContinue | Where-Object { $_ -like "dsh web: $fallback/?token=*" } | Select-Object -Last 1
    if ($line) { return $line.Substring(9) }
    return $fallback
}

function Start-Dsh {
    $script:openWhenUp = $true
    if ($mode -eq 'remote') { Start-RemoteDsh; return }
    Start-LocalDsh
}

function Start-LocalDsh {
    $exe = Get-Command $startCommand[0] -CommandType Application -ErrorAction SilentlyContinue
    if (-not $exe) {
        [System.Windows.Forms.MessageBox]::Show(($uiText.LauncherNotFound -f $startCommand[0]), $uiText.TitleTray) | Out-Null
        return
    }
    Remove-Item -LiteralPath $logOut, $logErr -Force -ErrorAction SilentlyContinue
    $args = @($startCommand[1..($startCommand.Count - 1)])
    if ($args -notcontains '--no-open') { $args += '--no-open' }
    $proc = Start-Process -FilePath $exe.Path -WindowStyle Hidden `
        -WorkingDirectory $workDir `
        -ArgumentList $args `
        -RedirectStandardOutput $logOut -RedirectStandardError $logErr -PassThru
    if ($proc) { $script:trackedPid = $proc.Id }
}

function Start-RemoteDsh {
    $ssh = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if (-not $ssh) {
        [System.Windows.Forms.MessageBox]::Show($uiText.SshNotFound, $uiText.TitleTray) | Out-Null
        return
    }
    if (-not (Test-Path -LiteralPath $sshKey)) {
        [System.Windows.Forms.MessageBox]::Show(($uiText.SshKeyNotFound -f $sshKey), $uiText.TitleTray) | Out-Null
        return
    }
    # Clear any stale local tunnel on $port so a lingering ssh does not make the
    # new one bail on ExitOnForwardFailure (a killed tray can leave one behind).
    foreach ($p in Get-PortOwnerPids) {
        $proc = Get-Process -Id $p -ErrorAction SilentlyContinue
        if ($proc -and $proc.Name -eq 'ssh') { Stop-ProcessTree $p }
    }
    # 1) Start the server on the cloud host. The remote non-login shell often has
    #    an empty PATH, so prepend the standard dirs (where dsh lives) first.
    $remoteCmd = "export PATH=/usr/local/bin:/usr/bin:/bin:`$PATH; nohup $remoteStartCommand >/tmp/dsh-tray.out.log 2>&1 &"
    $startArgs = @('-o', 'StrictHostKeyChecking=accept-new', '-E', "$logErr", '-i', "$sshKey", $sshHost, $remoteCmd)
    Start-Process -FilePath $ssh.Path -WindowStyle Hidden -ArgumentList $startArgs | Out-Null
    # 2) Open the persistent local tunnel immediately. It is only a pipe; the tray
    #    reports "ready" (and auto-opens the Web UI) only once the cloud server is
    #    actually serving HTTP, so the browser never opens against a not-yet-ready
    #    server and spin. Splitting the tunnel into its own ssh (-f -N -L) avoids
    #    the unreliable -f-with-remote-command forwarding on Windows.
    $tunnelArgs = @('-f', '-N', '-o', 'StrictHostKeyChecking=accept-new',
                    '-i', "$sshKey", '-L', ('{0}:127.0.0.1:{0}' -f $port), $sshHost)
    $proc = Start-Process -FilePath $ssh.Path -WindowStyle Hidden -ArgumentList $tunnelArgs -PassThru
    if ($proc) { $script:trackedPid = $proc.Id }
}

function Stop-ProcessTree([int]$processId) {
    # taskkill /T kills the whole tree; hidden window avoids a console flash.
    try {
        Start-Process -FilePath 'taskkill.exe' -WindowStyle Hidden -Wait `
            -ArgumentList @('/PID', "$processId", '/T', '/F')
    } catch { }
}

function Stop-Dsh {
    param([switch]$Quiet)
    $script:openWhenUp = $false
    if ($mode -eq 'remote') { Stop-RemoteDsh $Quiet; return }
    Stop-LocalDsh $Quiet
}

function Stop-LocalDsh {
    param([switch]$Quiet)

    # A user-initiated stop/restart must not trigger the crash balloon.
    $script:suppressUntil = (Get-Date).AddSeconds(15)

    $ownerPids = Get-PortOwnerPids
    if ($script:trackedPid -and (Get-Process -Id $script:trackedPid -ErrorAction SilentlyContinue)) {
        if (-not $ownerPids.Count -or $ownerPids -contains $script:trackedPid) {
            Stop-ProcessTree $script:trackedPid
            $script:trackedPid = 0
            return
        }
        Stop-ProcessTree $script:trackedPid
    }
    $script:trackedPid = 0
    if (-not $ownerPids.Count) { return }

    # The tray can lose its in-memory PID after a transient status miss or tray restart.
    # Recognize the configured DSH Web command on this port before treating it as foreign.
    $managedPids = @(Get-ManagedLocalOwnerPids $ownerPids)
    foreach ($managedPid in $managedPids) { Stop-ProcessTree $managedPid }
    $ownerPids = @($ownerPids | Where-Object { $managedPids -notcontains $_ })
    if (-not $ownerPids.Count -or $Quiet) { return }

    $names = ($ownerPids | ForEach-Object {
            $p = Get-Process -Id $_ -ErrorAction SilentlyContinue
            if ($p) { '{0} (PID {1})' -f $p.ProcessName, $p.Id } else { "PID $_" }
        }) -join ', '
    $answer = [System.Windows.Forms.MessageBox]::Show(($uiText.UnknownPortOwner -f $port, $names), $uiText.TitleTray, 'YesNo', 'Warning')
    if ($answer -eq 'Yes') {
        foreach ($opid in $ownerPids) { Stop-ProcessTree $opid }
    }
}

function Stop-RemoteDsh {
    param([switch]$Quiet)

    # A user-initiated stop/restart must not trigger the crash balloon.
    $script:suppressUntil = (Get-Date).AddSeconds(15)

    # 1) Kill the local tunnel (the ssh.exe that owns local port $port).
    foreach ($p in Get-PortOwnerPids) {
        $proc = Get-Process -Id $p -ErrorAction SilentlyContinue
        if ($proc -and $proc.Name -eq 'ssh') { Stop-ProcessTree $p }
    }
    # 2) Optionally kill the server on the cloud host too.
    if ($stopRemoteServer) {
        $ssh = Get-Command ssh.exe -ErrorAction SilentlyContinue
        if ($ssh -and (Test-Path -LiteralPath $sshKey)) {
            $pattern = (($remoteStartCommand -split ' ')[0..1] -join ' ')
            $kargs = @('-o', 'StrictHostKeyChecking=accept-new', '-i', "$sshKey",
                       $sshHost, "pkill -f '$pattern'")
            try { Start-Process -FilePath $ssh.Path -WindowStyle Hidden -ArgumentList $kargs } catch { }
        }
    }
    $script:trackedPid = 0
}

function ShowLogs {
    if ($mode -eq 'remote') {
        # Tail the server log on the cloud host (written by the remote command).
        $rk = @('-o', 'StrictHostKeyChecking=accept-new', '-i', "$sshKey", $sshHost,
                "tail -n 50 -f /tmp/dsh-tray.out.log")
        $cmd = 'ssh ' + ($rk -join ' ')
        if ($wt) {
            Start-Process -FilePath $wt.Path -ArgumentList @('powershell', '-NoProfile', '-Command', $cmd)
        } else {
            Start-Process -FilePath 'powershell' -ArgumentList @('-NoProfile', '-Command', $cmd)
        }
        return
    }
    if ($wt) {
        Start-Process -FilePath $wt.Path -ArgumentList @(
            'powershell', '-NoProfile', '-Command', "Get-Content -LiteralPath '$logOut' -Wait -Tail 50"
        )
    } else {
        Start-Process -FilePath 'powershell' -ArgumentList @(
            '-NoProfile', '-Command', "Get-Content -LiteralPath '$logOut' -Wait -Tail 50"
        )
    }
}

function Restart-Dsh {
    Stop-Dsh
    Start-Sleep -Seconds 2
    Start-Dsh
}

# --- Launch-at-login toggle (HKCU Run key, per-user, no admin needed) ---
function Get-LaunchCommand {
    # Prefer the VBS wrapper (zero console flash); fall back to hidden PowerShell.
    $vbs = Join-Path (Split-Path -Parent $PSScriptRoot) 'dsh-tray.vbs'
    if (Test-Path -LiteralPath $vbs) {
        return "wscript.exe `"$vbs`""
    }
    return "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
}

function Get-LaunchAtLogin {
    $item = Get-ItemProperty -LiteralPath $runKeyPath -Name $runValueName -ErrorAction SilentlyContinue
    return ($null -ne $item)
}

function Set-LaunchAtLogin {
    param([bool]$Enabled)
    if ($Enabled) {
        Set-ItemProperty -LiteralPath $runKeyPath -Name $runValueName -Value (Get-LaunchCommand)
    } else {
        Remove-ItemProperty -LiteralPath $runKeyPath -Name $runValueName -ErrorAction SilentlyContinue
    }
}

# --- Status icons (green = running, red = stopped) ---
function New-StateIcon {
    param([System.Drawing.Color]$Color)
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $brush = New-Object System.Drawing.SolidBrush($Color)
    $g.FillEllipse($brush, 2, 2, 12, 12)
    $g.DrawEllipse([System.Drawing.Pens]::DimGray, 2, 2, 12, 12)
    $g.Dispose()
    $brush.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    return $icon
}

# --- Tray icon + context menu ---
if (-not $NoTray) {
    $iconRunning = New-StateIcon ([System.Drawing.Color]::ForestGreen)
    $iconStopped = New-StateIcon ([System.Drawing.Color]::Firebrick)

    $notify = New-Object System.Windows.Forms.NotifyIcon
    $notify.Icon = $iconStopped
    $notify.Text = 'DSH Web'
    $notify.Visible = $true

    $menu = New-Object System.Windows.Forms.ContextMenuStrip

    $openUI = $menu.Items.Add($uiText.OpenUI)
    $openUI.Add_Click({ Start-Process (Get-DshWebUrl) })

    $showLogs = $menu.Items.Add($uiText.ShowLogs)
    $showLogs.Add_Click({ ShowLogs })

    $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    $start = $menu.Items.Add($uiText.StartServer)
    $start.Add_Click({
            Start-Dsh
            $msg = if ($mode -eq 'remote') {
                $uiText.StartingRemote
            } else {
                ($uiText.StartingLocal -f $port)
            }
            $notify.ShowBalloonTip(3000, 'DSH Web', $msg, 'Info')
        })

    $stop = $menu.Items.Add($uiText.StopServer)
    $stop.Add_Click({
            Stop-Dsh
            $notify.ShowBalloonTip(3000, 'DSH Web', $uiText.Stopping, 'Info')
        })

    $restart = $menu.Items.Add($uiText.RestartServer)
    $restart.Add_Click({
            Restart-Dsh
            $notify.ShowBalloonTip(3000, 'DSH Web', $uiText.Restarting, 'Info')
        })

    $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    $launchAtLogin = $menu.Items.Add($uiText.LaunchAtLogin)
    $launchAtLogin.CheckOnClick = $true
    $launchAtLogin.Checked = Get-LaunchAtLogin
    $launchAtLogin.Add_Click({
            Set-LaunchAtLogin $launchAtLogin.Checked
            if ($launchAtLogin.Checked) {
                $notify.ShowBalloonTip(3000, $uiText.TitleTray, $uiText.LoginEnabled, 'Info')
            } else {
                $notify.ShowBalloonTip(3000, $uiText.TitleTray, $uiText.LoginDisabled, 'Info')
            }
        })

    $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    $exit = $menu.Items.Add($uiText.ExitStopServer)
    $exit.Add_Click({
            Stop-Dsh -Quiet
            $notify.Visible = $false
            [System.Windows.Forms.Application]::Exit()
        })

    function Update-MenuState {
        $running = Get-DshRunning

        if ($null -ne $script:lastRunning) {
            if ($script:lastRunning -and -not $running) {
                $script:trackedPid = 0
                if ((Get-Date) -gt $script:suppressUntil) {
                    $notify.ShowBalloonTip(5000, 'DSH Web', ($uiText.UnexpectedExit -f $port), 'Warning')
                }
            } elseif (-not $script:lastRunning -and $running -and -not $script:openWhenUp -and (Get-Date) -gt $script:suppressUntil) {
                $notify.ShowBalloonTip(5000, 'DSH Web', ($uiText.DetectedRunning -f $port), 'Info')
            }
        }
        if ($running -and $script:openWhenUp) {
            $url = Get-DshWebUrl
            if ($mode -eq 'remote' -or $url -like '*?token=*') {
                $script:openWhenUp = $false
                Start-Process $url
                $notify.ShowBalloonTip(3000, 'DSH Web', ($uiText.OpeningUI -f $url), 'Info')
            }
        }
        $script:lastRunning = $running

        $start.Enabled = -not $running
        $stop.Enabled = $running
        $restart.Enabled = $running
        $notify.Icon = if ($running) { $iconRunning } else { $iconStopped }
        $notify.Text = if ($running) { $uiText.RunningTooltip -f $port } else { $uiText.StoppedTooltip -f $port }
    }

    $pollTimer = New-Object System.Windows.Forms.Timer
    $pollTimer.Interval = $pollIntervalMs
    $pollTimer.Add_Tick({ Update-MenuState })

    $notify.ContextMenuStrip = $menu
    $notify.Add_DoubleClick({ if (Get-DshRunning) { Start-Process (Get-DshWebUrl) } })

    # Auto-start the server on launch when not already running (skipped under -NoTray).
    if ($autoStart -and -not (Get-DshRunning)) {
        Start-Dsh
    }
    Update-MenuState
    $pollTimer.Start()

    $notify.ShowBalloonTip(3000, 'DSH Web', ($uiText.TrayReady -f $port), 'Info')

    $hiddenForm = New-Object System.Windows.Forms.Form
    $hiddenForm.WindowState = 'Minimized'
    $hiddenForm.ShowInTaskbar = $false
    $hiddenForm.Visible = $false
    [System.Windows.Forms.Application]::Run($hiddenForm)
}

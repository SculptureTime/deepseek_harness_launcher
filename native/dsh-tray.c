#define _WIN32_WINNT 0x0A00
#define WIN32_LEAN_AND_MEAN

#include <winsock2.h>
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <iphlpapi.h>
#include <tcpmib.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <wchar.h>

#define IDI_APP_ICON 101
#define WM_TRAYICON (WM_APP + 1)
#define WM_ACTIVATE_INSTANCE (WM_APP + 2)
#define TIMER_STATUS 1

#define CMD_OPEN_WEB 1001
#define CMD_SHOW_LOGS 1002
#define CMD_START 1003
#define CMD_STOP 1004
#define CMD_RESTART 1005
#define CMD_AUTOSTART 1006
#define CMD_EXIT 1007

#define OP_NONE 0
#define OP_START 1
#define OP_STOP 2
#define OP_RESTART 3

static const int DSH_PORT = 3080;
static const char *PATCH_CONTENT = "- id: tool-fs-search\r\n  config:\r\n    sampleOverCapGlobResults: false\r\n    timeoutMs: 120000\r\n";
static const wchar_t *RUN_KEY = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
static const wchar_t *RUN_VALUE = L"DeepSeek Harness Launcher";
static const wchar_t *LEGACY_RUN_VALUE = L"DeepSeek Harness";
static const wchar_t *LEGACY_RUN_VALUE_OLD = L"DSH Tray";
static const wchar_t *APP_NAME = L"DeepSeek Harness Launcher";

static HWND g_hwnd;
static HMENU g_menu;
static HICON g_icon;
static NOTIFYICONDATAW g_nid;
static DWORD g_tracked_pid;
static DWORD g_launch_pid;
static uint64_t g_tracked_created;
static int g_last_running = -1;
static ULONGLONG g_suppress_until;
static bool g_open_when_up;
static bool g_restart_notify_pending;
static bool g_start_notify_pending;
static bool g_starting;
static int g_operation = OP_NONE;
static wchar_t g_log_out[MAX_PATH];
static wchar_t g_log_err[MAX_PATH];
static wchar_t g_state_file[MAX_PATH];
static wchar_t g_patch_file[MAX_PATH];
static wchar_t g_node_path[MAX_PATH];
static wchar_t g_dsh_command[MAX_PATH];
static UINT g_taskbar_created;

static void ShowBalloon(const wchar_t *title, const wchar_t *message, DWORD flags) {
    (void) flags;
    wcsncpy_s(g_nid.szInfoTitle, _countof(g_nid.szInfoTitle), title, _TRUNCATE);
    wcsncpy_s(g_nid.szInfo, _countof(g_nid.szInfo), message, _TRUNCATE);
    g_nid.hBalloonIcon = g_icon;
    g_nid.dwInfoFlags = NIIF_USER | NIIF_LARGE_ICON;
    g_nid.uFlags = NIF_INFO;
    Shell_NotifyIconW(NIM_MODIFY, &g_nid);
}

static void InitPaths(void) {
    wchar_t temp[MAX_PATH] = {0};
    wchar_t local[MAX_PATH] = {0};
    GetTempPathW(_countof(temp), temp);
    swprintf_s(g_log_out, _countof(g_log_out), L"%sdsh-tray.out.log", temp);
    swprintf_s(g_log_err, _countof(g_log_err), L"%sdsh-tray.err.log", temp);
    if (!GetEnvironmentVariableW(L"LOCALAPPDATA", local, _countof(local))) {
        GetTempPathW(_countof(local), local);
    }
    wchar_t state_dir[MAX_PATH] = {0};
    swprintf_s(state_dir, _countof(state_dir), L"%s\\DeepSeek Harness", local);
    CreateDirectoryW(state_dir, NULL);
    swprintf_s(g_state_file, _countof(g_state_file), L"%s\\dsh.pid", state_dir);
    swprintf_s(g_patch_file, _countof(g_patch_file), L"%s\\dsh-tool-timeout.patch.yml", state_dir);
    HANDLE patch = CreateFileW(g_patch_file, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (patch != INVALID_HANDLE_VALUE) {
        DWORD written = 0;
        WriteFile(patch, PATCH_CONTENT, (DWORD) strlen(PATCH_CONTENT), &written, NULL);
        CloseHandle(patch);
    }
}

static bool GetNodeVersion(const wchar_t *path, int *major, int *minor, int *patch) {
    if (GetFileAttributesW(path) == INVALID_FILE_ATTRIBUTES) {
        return false;
    }
    SECURITY_ATTRIBUTES security = {sizeof(security), NULL, TRUE};
    HANDLE read_pipe = NULL, write_pipe = NULL;
    if (!CreatePipe(&read_pipe, &write_pipe, &security, 0)) {
        return false;
    }
    SetHandleInformation(read_pipe, HANDLE_FLAG_INHERIT, 0);
    wchar_t command[MAX_PATH + 32] = {0};
    swprintf_s(command, _countof(command), L"\"%s\" --version", path);
    STARTUPINFOW startup = {0};
    PROCESS_INFORMATION process = {0};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdOutput = write_pipe;
    startup.hStdError = write_pipe;
    BOOL started = CreateProcessW(path, command, NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, NULL, &startup, &process);
    CloseHandle(write_pipe);
    if (!started) {
        CloseHandle(read_pipe);
        return false;
    }
    DWORD wait = WaitForSingleObject(process.hProcess, 3000);
    if (wait == WAIT_TIMEOUT) {
        TerminateProcess(process.hProcess, 1);
    }
    char output[128] = {0};
    DWORD read = 0;
    ReadFile(read_pipe, output, sizeof(output) - 1, &read, NULL);
    CloseHandle(read_pipe);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return sscanf_s(output, "v%d.%d.%d", major, minor, patch) == 3;
}

static bool IsCompatibleNode(const wchar_t *path, int *major, int *minor, int *patch) {
    if (!GetNodeVersion(path, major, minor, patch)) {
        return false;
    }
    return *major >= 24 || (*major == 22 && *minor >= 19);
}

static void ScanNodeRoot(const wchar_t *root, wchar_t *best_path, int *best_major, int *best_minor, int *best_patch) {
    if (!root[0]) {
        return;
    }
    const wchar_t *patterns[] = {L"%s\\v*", L"%s\\installs\\v*"};
    for (int p = 0; p < 2; p++) {
        wchar_t pattern[MAX_PATH] = {0};
        swprintf_s(pattern, _countof(pattern), patterns[p], root);
        WIN32_FIND_DATAW data = {0};
        HANDLE find = FindFirstFileW(pattern, &data);
        if (find == INVALID_HANDLE_VALUE) {
            continue;
        }
        do {
            if (!(data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) || data.cFileName[0] != L'v') {
                continue;
            }
            wchar_t candidate[MAX_PATH] = {0};
            if (p == 0) swprintf_s(candidate, _countof(candidate), L"%s\\%s\\node.exe", root, data.cFileName);
            else swprintf_s(candidate, _countof(candidate), L"%s\\installs\\%s\\node.exe", root, data.cFileName);
            int major = 0, minor = 0, patch = 0;
            if (IsCompatibleNode(candidate, &major, &minor, &patch) && (major > *best_major || (major == *best_major && minor > *best_minor) || (major == *best_major && minor == *best_minor && patch > *best_patch))) {
                wcscpy_s(best_path, MAX_PATH, candidate);
                *best_major = major;
                *best_minor = minor;
                *best_patch = patch;
            }
        } while (FindNextFileW(find, &data));
        FindClose(find);
    }
}

static bool ResolveRuntime(void) {
    DWORD found = SearchPathW(NULL, L"dsh.cmd", NULL, _countof(g_dsh_command), g_dsh_command, NULL);
    if (!found || found >= _countof(g_dsh_command)) {
        MessageBoxW(g_hwnd, L"未找到 dsh.cmd。请先安装 DeepSeek Harness，并确保 dsh 命令已加入 PATH。", APP_NAME, MB_OK | MB_ICONERROR);
        return false;
    }

    // 优先采用 dsh.cmd 自己绑定的 Node，避免系统默认 Node 版本过低。
    HANDLE wrapper = CreateFileW(g_dsh_command, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (wrapper != INVALID_HANDLE_VALUE) {
        char raw[8192] = {0};
        DWORD read = 0;
        if (ReadFile(wrapper, raw, sizeof(raw) - 1, &read, NULL) && read) {
            wchar_t text[8192] = {0};
            MultiByteToWideChar(CP_UTF8, 0, raw, (int) read, text, _countof(text) - 1);
            wchar_t *node_end = wcsstr(text, L"node.exe");
            if (node_end) {
                wchar_t *start = node_end;
                while (start > text && *start != L'\"') start--;
                if (*start == L'\"') {
                    size_t length = (size_t) (node_end + wcslen(L"node.exe") - (start + 1));
                    if (length < _countof(g_node_path)) {
                        wcsncpy_s(g_node_path, _countof(g_node_path), start + 1, length);
                        int major = 0, minor = 0, patch = 0;
                        if (IsCompatibleNode(g_node_path, &major, &minor, &patch)) {
                            CloseHandle(wrapper);
                            return true;
                        }
                        g_node_path[0] = L'\0';
                    }
                }
            }
        }
        CloseHandle(wrapper);
    }

    wchar_t best[MAX_PATH] = {0};
    int best_major = 0, best_minor = 0, best_patch = 0;
    wchar_t root[MAX_PATH] = {0};
    if (GetEnvironmentVariableW(L"NVM_HOME", root, _countof(root))) {
        ScanNodeRoot(root, best, &best_major, &best_minor, &best_patch);
    }
    if (GetEnvironmentVariableW(L"APPDATA", root, _countof(root))) {
        wcscat_s(root, _countof(root), L"\\nvm");
        ScanNodeRoot(root, best, &best_major, &best_minor, &best_patch);
    }
    if (GetEnvironmentVariableW(L"LOCALAPPDATA", root, _countof(root))) {
        wcscat_s(root, _countof(root), L"\\nvm");
        ScanNodeRoot(root, best, &best_major, &best_minor, &best_patch);
    }
    wchar_t path_node[MAX_PATH] = {0};
    found = SearchPathW(NULL, L"node.exe", NULL, _countof(path_node), path_node, NULL);
    int major = 0, minor = 0, patch = 0;
    if (found && found < _countof(path_node) && IsCompatibleNode(path_node, &major, &minor, &patch) && (major > best_major || (major == best_major && minor > best_minor) || (major == best_major && minor == best_minor && patch > best_patch))) {
        wcscpy_s(best, _countof(best), path_node);
    }
    if (!best[0]) {
        MessageBoxW(g_hwnd, L"未找到兼容的 Node.js。DeepSeek Harness 当前需要 Node 22.19+（22.x）或 Node 24+。", APP_NAME, MB_OK | MB_ICONERROR);
        return false;
    }
    wcscpy_s(g_node_path, _countof(g_node_path), best);
    return true;
}

static uint64_t FileTimeToUint64(FILETIME value) {
    ULARGE_INTEGER number;
    number.LowPart = value.dwLowDateTime;
    number.HighPart = value.dwHighDateTime;
    return number.QuadPart;
}

static bool QueryProcessIdentity(DWORD pid, wchar_t *image, DWORD image_chars, uint64_t *created) {
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!process) {
        return false;
    }
    DWORD size = image_chars;
    FILETIME create_time, exit_time, kernel_time, user_time;
    bool ok = QueryFullProcessImageNameW(process, 0, image, &size) && GetProcessTimes(process, &create_time, &exit_time, &kernel_time, &user_time);
    if (ok) {
        *created = FileTimeToUint64(create_time);
    }
    CloseHandle(process);
    return ok;
}

static void SaveTrackedProcess(DWORD pid) {
    wchar_t image[MAX_PATH] = {0};
    uint64_t created = 0;
    if (!QueryProcessIdentity(pid, image, _countof(image), &created)) {
        return;
    }
    FILE *file = _wfopen(g_state_file, L"w");
    if (!file) {
        return;
    }
    fwprintf(file, L"%lu %llu\n", pid, (unsigned long long) created);
    fclose(file);
    g_tracked_pid = pid;
    g_tracked_created = created;
}

static void ClearTrackedProcess(void) {
    g_tracked_pid = 0;
    g_tracked_created = 0;
    DeleteFileW(g_state_file);
}

static bool IsTrackedProcessValid(void) {
    if (!g_tracked_pid || !g_tracked_created) {
        return false;
    }
    wchar_t image[MAX_PATH] = {0};
    uint64_t created = 0;
    if (!QueryProcessIdentity(g_tracked_pid, image, _countof(image), &created)) {
        return false;
    }
    return created == g_tracked_created && _wcsicmp(image, g_node_path) == 0;
}

static void LoadTrackedProcess(void) {
    FILE *file = _wfopen(g_state_file, L"r");
    if (!file) {
        return;
    }
    unsigned long pid = 0;
    unsigned long long created = 0;
    int read = fwscanf(file, L"%lu %llu", &pid, &created);
    fclose(file);
    if (read == 2) {
        g_tracked_pid = (DWORD) pid;
        g_tracked_created = (uint64_t) created;
    }
    if (!IsTrackedProcessValid()) {
        ClearTrackedProcess();
    }
}

static DWORD GetPortOwnerPid(void) {
    ULONG size = 0;
    GetExtendedTcpTable(NULL, &size, FALSE, AF_INET, TCP_TABLE_OWNER_PID_LISTENER, 0);
    PMIB_TCPTABLE_OWNER_PID table4 = (PMIB_TCPTABLE_OWNER_PID) HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, size);
    if (table4 && GetExtendedTcpTable(table4, &size, FALSE, AF_INET, TCP_TABLE_OWNER_PID_LISTENER, 0) == NO_ERROR) {
        for (DWORD i = 0; i < table4->dwNumEntries; i++) {
            if (ntohs((u_short) table4->table[i].dwLocalPort) == DSH_PORT) {
                DWORD pid = table4->table[i].dwOwningPid;
                HeapFree(GetProcessHeap(), 0, table4);
                return pid;
            }
        }
    }
    if (table4) {
        HeapFree(GetProcessHeap(), 0, table4);
    }

    size = 0;
    GetExtendedTcpTable(NULL, &size, FALSE, AF_INET6, TCP_TABLE_OWNER_PID_LISTENER, 0);
    PMIB_TCP6TABLE_OWNER_PID table6 = (PMIB_TCP6TABLE_OWNER_PID) HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, size);
    if (table6 && GetExtendedTcpTable(table6, &size, FALSE, AF_INET6, TCP_TABLE_OWNER_PID_LISTENER, 0) == NO_ERROR) {
        for (DWORD i = 0; i < table6->dwNumEntries; i++) {
            if (ntohs((u_short) table6->table[i].dwLocalPort) == DSH_PORT) {
                DWORD pid = table6->table[i].dwOwningPid;
                HeapFree(GetProcessHeap(), 0, table6);
                return pid;
            }
        }
    }
    if (table6) {
        HeapFree(GetProcessHeap(), 0, table6);
    }
    return 0;
}

static bool IsManagedOwner(DWORD pid) {
    wchar_t image[MAX_PATH] = {0};
    uint64_t created = 0;
    return QueryProcessIdentity(pid, image, _countof(image), &created) && _wcsicmp(image, g_node_path) == 0;
}

static bool RunHiddenAndWait(wchar_t *command_line, DWORD timeout_ms) {
    STARTUPINFOW startup = {0};
    PROCESS_INFORMATION process = {0};
    startup.cb = sizeof(startup);
    BOOL started = CreateProcessW(NULL, command_line, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &startup, &process);
    if (!started) {
        return false;
    }
    WaitForSingleObject(process.hProcess, timeout_ms);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return true;
}

static void KillProcessTree(DWORD pid) {
    wchar_t command[128] = {0};
    swprintf_s(command, _countof(command), L"taskkill.exe /PID %lu /T /F", pid);
    RunHiddenAndWait(command, 10000);
}

static bool WaitPortStopped(DWORD timeout_ms) {
    ULONGLONG end = GetTickCount64() + timeout_ms;
    while (GetTickCount64() < end) {
        if (!GetPortOwnerPid()) {
            return true;
        }
        Sleep(100);
    }
    return !GetPortOwnerPid();
}

static bool ReadWebUrl(wchar_t *url, size_t url_chars) {
    swprintf_s(url, url_chars, L"http://127.0.0.1:%d", DSH_PORT);
    HANDLE file = CreateFileW(g_log_out, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) {
        return false;
    }
    char buffer[65536] = {0};
    DWORD read = 0;
    BOOL ok = ReadFile(file, buffer, sizeof(buffer) - 1, &read, NULL);
    CloseHandle(file);
    if (!ok || !read) {
        return false;
    }
    buffer[read] = '\0';
    const char *marker = "dsh web: http://127.0.0.1:3080/?token=";
    char *found = strstr(buffer, marker);
    if (!found) {
        return false;
    }
    found += strlen("dsh web: ");
    char *end = strpbrk(found, "\r\n");
    if (end) {
        *end = '\0';
    }
    return MultiByteToWideChar(CP_UTF8, 0, found, -1, url, (int) url_chars) > 0;
}

static void OpenWeb(void) {
    wchar_t url[2048] = {0};
    ReadWebUrl(url, _countof(url));
    ShellExecuteW(NULL, L"open", url, NULL, NULL, SW_SHOWNORMAL);
}

static void ShowLogs(void) {
    ShellExecuteW(NULL, L"open", L"notepad.exe", g_log_out, NULL, SW_SHOWNORMAL);
}

static void ApplyChildEnvironment(void) {
    wchar_t node_dir[MAX_PATH] = {0};
    wcscpy_s(node_dir, _countof(node_dir), g_node_path);
    wchar_t *slash = wcsrchr(node_dir, L'\\');
    if (slash) {
        *slash = L'\0';
    }
    wchar_t current[32768] = {0};
    wchar_t merged[32768] = {0};
    GetEnvironmentVariableW(L"Path", current, _countof(current));
    swprintf_s(merged, _countof(merged), L"%s;%s", node_dir, current);
    SetEnvironmentVariableW(L"Path", merged);
    SetEnvironmentVariableW(L"NO_PROXY", L"127.0.0.1,localhost");
}

static void ConfigureChildProxy(void) {
    HKEY key;
    DWORD enabled = 0;
    DWORD enabled_size = sizeof(enabled);
    wchar_t server[1024] = {0};
    DWORD server_size = sizeof(server);
    bool has_proxy = false;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings", 0, KEY_QUERY_VALUE, &key) == ERROR_SUCCESS) {
        DWORD type = 0;
        if (RegQueryValueExW(key, L"ProxyEnable", NULL, &type, (BYTE *) &enabled, &enabled_size) == ERROR_SUCCESS && enabled &&
            RegQueryValueExW(key, L"ProxyServer", NULL, &type, (BYTE *) server, &server_size) == ERROR_SUCCESS && server[0]) {
            has_proxy = true;
        }
        RegCloseKey(key);
    }
    if (!has_proxy) {
        SetEnvironmentVariableW(L"HTTP_PROXY", NULL);
        SetEnvironmentVariableW(L"HTTPS_PROXY", NULL);
        return;
    }

    wchar_t http[512] = {0};
    wchar_t https[512] = {0};
    if (!wcschr(server, L'=')) {
        wcscpy_s(http, _countof(http), server);
        wcscpy_s(https, _countof(https), server);
    } else {
        wchar_t copy[1024] = {0};
        wcscpy_s(copy, _countof(copy), server);
        wchar_t *context = NULL;
        for (wchar_t *part = wcstok_s(copy, L";", &context); part; part = wcstok_s(NULL, L";", &context)) {
            wchar_t *equal = wcschr(part, L'=');
            if (!equal) continue;
            *equal = L'\0';
            if (_wcsicmp(part, L"http") == 0) wcscpy_s(http, _countof(http), equal + 1);
            if (_wcsicmp(part, L"https") == 0) wcscpy_s(https, _countof(https), equal + 1);
        }
        if (!http[0] && https[0]) wcscpy_s(http, _countof(http), https);
        if (!https[0] && http[0]) wcscpy_s(https, _countof(https), http);
    }
    wchar_t http_url[544] = {0};
    wchar_t https_url[544] = {0};
    swprintf_s(http_url, _countof(http_url), wcsstr(http, L"://") ? L"%s" : L"http://%s", http);
    swprintf_s(https_url, _countof(https_url), wcsstr(https, L"://") ? L"%s" : L"http://%s", https);
    SetEnvironmentVariableW(L"HTTP_PROXY", http_url);
    SetEnvironmentVariableW(L"HTTPS_PROXY", https_url);
}

static bool StartDsh(void) {
    if (GetPortOwnerPid()) {
        g_starting = false;
        return true;
    }
    g_starting = true;
    ConfigureChildProxy();
    DeleteFileW(g_log_out);
    DeleteFileW(g_log_err);

    SECURITY_ATTRIBUTES security = {0};
    security.nLength = sizeof(security);
    security.bInheritHandle = TRUE;
    HANDLE out = CreateFileW(g_log_out, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, &security, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    HANDLE err = CreateFileW(g_log_err, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, &security, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (out == INVALID_HANDLE_VALUE || err == INVALID_HANDLE_VALUE) {
        if (out != INVALID_HANDLE_VALUE) CloseHandle(out);
        if (err != INVALID_HANDLE_VALUE) CloseHandle(err);
        g_starting = false;
        MessageBoxW(g_hwnd, L"无法创建 DSH 日志文件。", APP_NAME, MB_OK | MB_ICONERROR);
        return false;
    }

    wchar_t comspec[MAX_PATH] = {0};
    if (!GetEnvironmentVariableW(L"ComSpec", comspec, _countof(comspec))) {
        wcscpy_s(comspec, _countof(comspec), L"C:\\Windows\\System32\\cmd.exe");
    }
    wchar_t command[4096] = {0};
    swprintf_s(command, _countof(command), L"\"%s\" /d /s /c \"\"%s\" web --patch \"%s\" --port %d --no-open\"", comspec, g_dsh_command, g_patch_file, DSH_PORT);
    STARTUPINFOW startup = {0};
    PROCESS_INFORMATION process = {0};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdOutput = out;
    startup.hStdError = err;
    startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    BOOL started = CreateProcessW(comspec, command, NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, NULL, &startup, &process);
    CloseHandle(out);
    CloseHandle(err);
    if (!started) {
        wchar_t message[256] = {0};
        swprintf_s(message, _countof(message), L"DSH 服务启动失败，错误码：%lu", GetLastError());
        g_starting = false;
        MessageBoxW(g_hwnd, message, APP_NAME, MB_OK | MB_ICONERROR);
        return false;
    }
    g_launch_pid = process.dwProcessId;
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    g_open_when_up = true;
    return true;
}

static bool StopDsh(bool quiet) {
    g_starting = false;
    g_open_when_up = false;
    g_suppress_until = GetTickCount64() + 15000;

    if (g_launch_pid) {
        KillProcessTree(g_launch_pid);
        g_launch_pid = 0;
        WaitPortStopped(5000);
    }
    if (IsTrackedProcessValid()) {
        KillProcessTree(g_tracked_pid);
        WaitPortStopped(5000);
    }
    ClearTrackedProcess();

    DWORD owner = GetPortOwnerPid();
    if (!owner) {
        return true;
    }
    if (IsManagedOwner(owner)) {
        KillProcessTree(owner);
        return WaitPortStopped(5000);
    }
    if (quiet) {
        return false;
    }

    wchar_t image[MAX_PATH] = L"未知进程";
    uint64_t created = 0;
    QueryProcessIdentity(owner, image, _countof(image), &created);
    wchar_t message[768] = {0};
    swprintf_s(message, _countof(message), L"端口 %d 已被其他进程占用：\n%s\nPID %lu\n\n是否强制停止该进程？", DSH_PORT, image, owner);
    if (MessageBoxW(g_hwnd, message, APP_NAME, MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2) == IDYES) {
        KillProcessTree(owner);
        return WaitPortStopped(5000);
    }
    return false;
}

static bool RestartDsh(void) {
    if (!StopDsh(false)) {
        return false;
    }
    Sleep(300);
    return StartDsh();
}

static bool IsLaunchAtLoginEnabled(void) {
    HKEY key;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, RUN_KEY, 0, KEY_QUERY_VALUE, &key) != ERROR_SUCCESS) {
        return false;
    }
    LONG result = RegQueryValueExW(key, RUN_VALUE, NULL, NULL, NULL, NULL);
    if (result != ERROR_SUCCESS) {
        result = RegQueryValueExW(key, LEGACY_RUN_VALUE, NULL, NULL, NULL, NULL);
    }
    if (result != ERROR_SUCCESS) {
        result = RegQueryValueExW(key, LEGACY_RUN_VALUE_OLD, NULL, NULL, NULL, NULL);
    }
    RegCloseKey(key);
    return result == ERROR_SUCCESS;
}

static bool SetLaunchAtLogin(bool enabled) {
    HKEY key;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, RUN_KEY, 0, NULL, 0, KEY_SET_VALUE, NULL, &key, NULL) != ERROR_SUCCESS) {
        return false;
    }
    LONG result;
    if (enabled) {
        wchar_t exe[MAX_PATH] = {0};
        wchar_t command[MAX_PATH + 8] = {0};
        GetModuleFileNameW(NULL, exe, _countof(exe));
        swprintf_s(command, _countof(command), L"\"%s\"", exe);
        result = RegSetValueExW(key, RUN_VALUE, 0, REG_SZ, (const BYTE *) command, (DWORD) ((wcslen(command) + 1) * sizeof(wchar_t)));
        if (result == ERROR_SUCCESS) {
            RegDeleteValueW(key, LEGACY_RUN_VALUE);
            RegDeleteValueW(key, LEGACY_RUN_VALUE_OLD);
        }
    } else {
        result = RegDeleteValueW(key, RUN_VALUE);
        RegDeleteValueW(key, LEGACY_RUN_VALUE);
        RegDeleteValueW(key, LEGACY_RUN_VALUE_OLD);
        if (result == ERROR_FILE_NOT_FOUND) {
            result = ERROR_SUCCESS;
        }
    }
    RegCloseKey(key);
    return result == ERROR_SUCCESS;
}

static void RemoveLegacyDesktopShortcut(void) {
    wchar_t desktop[MAX_PATH] = {0};
    if (SUCCEEDED(SHGetFolderPathW(NULL, CSIDL_DESKTOPDIRECTORY, NULL, SHGFP_TYPE_CURRENT, desktop))) {
        wchar_t shortcut[MAX_PATH] = {0};
        swprintf_s(shortcut, _countof(shortcut), L"%s\\DeepSeek Harness.lnk", desktop);
        DeleteFileW(shortcut);
    }
}

static void AddTrayIcon(void) {
    ZeroMemory(&g_nid, sizeof(g_nid));
    g_nid.cbSize = sizeof(g_nid);
    g_nid.hWnd = g_hwnd;
    g_nid.uID = 1;
    g_nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP | NIF_SHOWTIP;
    g_nid.uCallbackMessage = WM_TRAYICON;
    g_nid.hIcon = g_icon;
    wcscpy_s(g_nid.szTip, _countof(g_nid.szTip), APP_NAME);
    if (Shell_NotifyIconW(NIM_ADD, &g_nid)) {
        g_nid.uVersion = NOTIFYICON_VERSION_4;
        Shell_NotifyIconW(NIM_SETVERSION, &g_nid);
    }
}

static void UpdateMenuState(void) {
    DWORD owner = GetPortOwnerPid();
    bool running = owner != 0;
    if (running) {
        g_starting = false;
        g_launch_pid = 0;
        if (IsManagedOwner(owner) && (!IsTrackedProcessValid() || g_tracked_pid != owner)) {
            SaveTrackedProcess(owner);
        }
    } else if (g_starting && g_launch_pid) {
        HANDLE launch = OpenProcess(SYNCHRONIZE, FALSE, g_launch_pid);
        if (launch && WaitForSingleObject(launch, 0) == WAIT_OBJECT_0) {
            g_starting = false;
            g_launch_pid = 0;
            g_operation = OP_NONE;
            ShowBalloon(APP_NAME, L"DSH 服务启动失败，请查看日志。", NIIF_ERROR);
        }
        if (launch) CloseHandle(launch);
    }
    bool operation_busy = g_operation != OP_NONE;
    EnableMenuItem(g_menu, CMD_OPEN_WEB, MF_BYCOMMAND | (running ? MF_ENABLED : MF_GRAYED));
    EnableMenuItem(g_menu, CMD_START, MF_BYCOMMAND | (!operation_busy && !running ? MF_ENABLED : MF_GRAYED));
    EnableMenuItem(g_menu, CMD_STOP, MF_BYCOMMAND | (!operation_busy && running ? MF_ENABLED : MF_GRAYED));
    EnableMenuItem(g_menu, CMD_RESTART, MF_BYCOMMAND | (!operation_busy && running ? MF_ENABLED : MF_GRAYED));
    CheckMenuItem(g_menu, CMD_AUTOSTART, MF_BYCOMMAND | (IsLaunchAtLoginEnabled() ? MF_CHECKED : MF_UNCHECKED));

    g_nid.uFlags = NIF_ICON | NIF_TIP | NIF_SHOWTIP;
    g_nid.hIcon = g_icon;
    swprintf_s(g_nid.szTip, _countof(g_nid.szTip), running ? L"%s - 运行中（:%d）" : L"%s - 已停止（:%d）", APP_NAME, DSH_PORT);
    Shell_NotifyIconW(NIM_MODIFY, &g_nid);

    if (g_last_running != -1) {
        if (g_last_running && !running && GetTickCount64() > g_suppress_until) {
            ShowBalloon(APP_NAME, L"DSH 服务意外退出。", NIIF_WARNING);
        } else if (!g_last_running && running && !g_open_when_up && GetTickCount64() > g_suppress_until) {
            ShowBalloon(APP_NAME, L"已检测到 DSH 服务正在运行。", NIIF_INFO);
        }
    }
    if (running && g_open_when_up) {
        wchar_t url[2048] = {0};
        if (ReadWebUrl(url, _countof(url)) && wcsstr(url, L"?token=")) {
            g_open_when_up = false;
            if (g_restart_notify_pending) {
                g_restart_notify_pending = false;
                g_operation = OP_NONE;
                ShowBalloon(APP_NAME, L"DSH 服务重启完成。", NIIF_INFO);
            } else if (g_start_notify_pending) {
                g_start_notify_pending = false;
                g_operation = OP_NONE;
                ShowBalloon(APP_NAME, L"DSH 服务启动完成。", NIIF_INFO);
            }
            ShellExecuteW(NULL, L"open", url, NULL, NULL, SW_SHOWNORMAL);
        }
    }
    g_last_running = running ? 1 : 0;
}

static void ShowTrayMenu(void) {
    POINT point;
    GetCursorPos(&point);
    SetForegroundWindow(g_hwnd);
    UpdateMenuState();
    TrackPopupMenu(g_menu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN | TPM_LEFTALIGN, point.x, point.y, 0, g_hwnd, NULL);
    PostMessageW(g_hwnd, WM_NULL, 0, 0);
}

static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM w_param, LPARAM l_param) {
    if (message == g_taskbar_created) {
        AddTrayIcon();
        return 0;
    }
    switch (message) {
        case WM_ACTIVATE_INSTANCE:
            if (GetPortOwnerPid()) {
                OpenWeb();
            } else if (g_operation != OP_NONE || g_starting) {
                g_open_when_up = true;
            } else {
                g_operation = OP_START;
                ShowBalloon(APP_NAME, L"正在启动 DSH 服务……", NIIF_INFO);
                g_start_notify_pending = StartDsh();
                if (!g_start_notify_pending) {
                    g_operation = OP_NONE;
                    ShowBalloon(APP_NAME, L"DSH 服务启动失败，请查看日志。", NIIF_ERROR);
                }
                UpdateMenuState();
            }
            return 0;
        case WM_COMMAND:
            switch (LOWORD(w_param)) {
                case CMD_OPEN_WEB:
                    OpenWeb();
                    break;
                case CMD_SHOW_LOGS:
                    ShowLogs();
                    break;
                case CMD_START:
                    g_operation = OP_START;
                    ShowBalloon(APP_NAME, L"正在启动 DSH 服务……", NIIF_INFO);
                    g_start_notify_pending = StartDsh();
                    if (!g_start_notify_pending) {
                        g_operation = OP_NONE;
                        ShowBalloon(APP_NAME, L"DSH 服务启动失败，请查看日志。", NIIF_ERROR);
                    }
                    UpdateMenuState();
                    break;
                case CMD_STOP:
                    g_operation = OP_STOP;
                    ShowBalloon(APP_NAME, L"正在停止 DSH 服务……", NIIF_INFO);
                    StopDsh(false);
                    g_operation = OP_NONE;
                    UpdateMenuState();
                    break;
                case CMD_RESTART:
                    g_operation = OP_RESTART;
                    ShowBalloon(APP_NAME, L"正在重启 DSH 服务。", NIIF_INFO);
                    g_restart_notify_pending = RestartDsh();
                    if (!g_restart_notify_pending) {
                        g_operation = OP_NONE;
                        ShowBalloon(APP_NAME, L"DSH 服务重启失败，请查看日志。", NIIF_ERROR);
                    }
                    UpdateMenuState();
                    break;
                case CMD_AUTOSTART: {
                    bool enabled = !IsLaunchAtLoginEnabled();
                    if (SetLaunchAtLogin(enabled)) {
                        ShowBalloon(APP_NAME, enabled ? L"已开启开机自动启动。" : L"已关闭开机自动启动。", NIIF_INFO);
                    }
                    break;
                }
                case CMD_EXIT:
                    StopDsh(true);
                    DestroyWindow(hwnd);
                    break;
            }
            return 0;
        case WM_TIMER:
            if (w_param == TIMER_STATUS) UpdateMenuState();
            return 0;
        case WM_TRAYICON: {
            UINT tray_event = LOWORD(l_param);
            if (tray_event == WM_RBUTTONUP || tray_event == WM_CONTEXTMENU) {
                ShowTrayMenu();
            } else if ((tray_event == WM_LBUTTONDBLCLK || tray_event == NIN_SELECT) && GetPortOwnerPid()) {
                OpenWeb();
            }
            return 0;
        }
        case WM_DESTROY:
            KillTimer(hwnd, TIMER_STATUS);
            Shell_NotifyIconW(NIM_DELETE, &g_nid);
            PostQuitMessage(0);
            return 0;
        default:
            return DefWindowProcW(hwnd, message, w_param, l_param);
    }
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, PWSTR command_line, int show_command) {
    (void) previous;
    (void) show_command;

    HANDLE mutex = CreateMutexW(NULL, TRUE, L"Local\\DSHTrayNative");
    bool already_running = mutex && GetLastError() == ERROR_ALREADY_EXISTS;
    if (already_running && command_line && wcsstr(command_line, L"--replace")) {
        CloseHandle(mutex);
        mutex = NULL;
        HWND existing = FindWindowW(L"DSHTrayNativeWindow", NULL);
        if (existing) {
            PostMessageW(existing, WM_CLOSE, 0, 0);
        }
        for (int i = 0; i < 50; i++) {
            Sleep(100);
            mutex = CreateMutexW(NULL, TRUE, L"Local\\DSHTrayNative");
            already_running = mutex && GetLastError() == ERROR_ALREADY_EXISTS;
            if (mutex && !already_running) {
                break;
            }
            if (mutex) {
                CloseHandle(mutex);
                mutex = NULL;
            }
        }
    }
    if (already_running) {
        HWND existing = FindWindowW(L"DSHTrayNativeWindow", NULL);
        if (existing) {
            PostMessageW(existing, WM_ACTIVATE_INSTANCE, 0, 0);
        }
        if (mutex) CloseHandle(mutex);
        return 0;
    }
    if (!mutex) {
        return 0;
    }

    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    WSADATA winsock;
    if (WSAStartup(MAKEWORD(2, 2), &winsock) != 0) {
        CloseHandle(mutex);
        return 1;
    }
    InitPaths();
    if (!ResolveRuntime()) {
        WSACleanup();
        CloseHandle(mutex);
        return 1;
    }
    LoadTrackedProcess();
    ApplyChildEnvironment();
    RemoveLegacyDesktopShortcut();
    // 桌面改为直接使用 DeepSeek Harness Launcher.exe 后，清理旧的 dsh-tray.exe。
    wchar_t desktop[MAX_PATH] = {0};
    wchar_t current_exe[MAX_PATH] = {0};
    wchar_t legacy_exe[MAX_PATH] = {0};
    if (SUCCEEDED(SHGetFolderPathW(NULL, CSIDL_DESKTOPDIRECTORY, NULL, SHGFP_TYPE_CURRENT, desktop)) && GetModuleFileNameW(NULL, current_exe, _countof(current_exe))) {
        swprintf_s(legacy_exe, _countof(legacy_exe), L"%s\\dsh-tray.exe", desktop);
        if (_wcsicmp(legacy_exe, current_exe) != 0) {
            DeleteFileW(legacy_exe);
        }
    }
    if (IsLaunchAtLoginEnabled()) {
        SetLaunchAtLogin(true);
    }

    g_icon = LoadIconW(instance, MAKEINTRESOURCEW(IDI_APP_ICON));
    g_taskbar_created = RegisterWindowMessageW(L"TaskbarCreated");

    WNDCLASSEXW window_class = {0};
    window_class.cbSize = sizeof(window_class);
    window_class.lpfnWndProc = WindowProc;
    window_class.hInstance = instance;
    window_class.hIcon = g_icon;
    window_class.hIconSm = g_icon;
    window_class.lpszClassName = L"DSHTrayNativeWindow";
    if (!RegisterClassExW(&window_class)) {
        WSACleanup();
        CloseHandle(mutex);
        return 1;
    }

    g_hwnd = CreateWindowExW(0, window_class.lpszClassName, APP_NAME, WS_OVERLAPPED, 0, 0, 0, 0, NULL, NULL, instance, NULL);
    if (!g_hwnd) {
        WSACleanup();
        CloseHandle(mutex);
        return 1;
    }

    g_menu = CreatePopupMenu();
    AppendMenuW(g_menu, MF_STRING, CMD_OPEN_WEB, L"打开 Web 界面");
    AppendMenuW(g_menu, MF_STRING, CMD_SHOW_LOGS, L"查看日志");
    AppendMenuW(g_menu, MF_SEPARATOR, 0, NULL);
    AppendMenuW(g_menu, MF_STRING, CMD_START, L"启动服务");
    AppendMenuW(g_menu, MF_STRING, CMD_STOP, L"停止服务");
    AppendMenuW(g_menu, MF_STRING, CMD_RESTART, L"重启服务");
    AppendMenuW(g_menu, MF_SEPARATOR, 0, NULL);
    AppendMenuW(g_menu, MF_STRING, CMD_AUTOSTART, L"开机自动启动");
    AppendMenuW(g_menu, MF_SEPARATOR, 0, NULL);
    AppendMenuW(g_menu, MF_STRING, CMD_EXIT, L"退出（停止服务）");

    AddTrayIcon();
    SetTimer(g_hwnd, TIMER_STATUS, 3000, NULL);
    if (!GetPortOwnerPid()) {
        g_operation = OP_START;
        ShowBalloon(APP_NAME, L"正在启动 DSH 服务……", NIIF_INFO);
        g_start_notify_pending = StartDsh();
        if (!g_start_notify_pending) g_operation = OP_NONE;
    } else {
        ShowBalloon(APP_NAME, L"DeepSeek Harness Launcher 已就绪，右键图标可进行控制。", NIIF_INFO);
    }
    UpdateMenuState();

    MSG message;
    while (GetMessageW(&message, NULL, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }

    DestroyMenu(g_menu);
    WSACleanup();
    ReleaseMutex(mutex);
    CloseHandle(mutex);
    return 0;
}

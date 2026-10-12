#define LOGIN_TASK_NAME L"DeepSeek Harness Launcher Autostart Test"
#include "../native/launcher.c"

/** 对独立测试任务调用真实的自启注册、查询和删除代码。 */
int wmain(int argc, wchar_t **argv) {
    if (argc != 2) return 2;
    if (wcscmp(argv[1], L"enable") == 0) return UpdateLoginTask(LOGIN_TASK_ENABLE) ? 0 : 1;
    if (wcscmp(argv[1], L"disable") == 0) return UpdateLoginTask(LOGIN_TASK_DISABLE) ? 0 : 1;
    if (wcscmp(argv[1], L"query") == 0) return UpdateLoginTask(LOGIN_TASK_QUERY) ? 0 : 1;
    if (wcscmp(argv[1], L"query-path") == 0) return UpdateLoginTask(LOGIN_TASK_QUERY_PATH) ? 0 : 1;
    return 2;
}

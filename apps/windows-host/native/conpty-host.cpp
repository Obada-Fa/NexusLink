// ConPTY helper: real Windows PTY so terminal.resize works.
// Build (Developer Command Prompt):
//   cl /O2 /EHsc /Fe:conpty-host.exe conpty-host.cpp
//
// Usage: conpty-host.exe --cols 80 --rows 24 -- powershell.exe
// Resize: write JSON {"cols":n,"rows":n} to \\.\pipe\nexuslink-pty-<pid>

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <string>
#include <vector>
#include <thread>
#include <cstdio>

static HPCON g_hpc = nullptr;
static HANDLE g_inWrite = nullptr;
static HANDLE g_outRead = nullptr;
static HANDLE g_child = nullptr;

static void pump(HANDLE from, HANDLE to) {
  char buf[4096];
  DWORD n = 0, w = 0;
  while (ReadFile(from, buf, sizeof(buf), &n, nullptr) && n) {
    DWORD off = 0;
    while (off < n) {
      if (!WriteFile(to, buf + off, n - off, &w, nullptr)) return;
      off += w;
    }
  }
}

static void resize_server(DWORD pid) {
  wchar_t name[128];
  swprintf(name, 128, L"\\\\.\\pipe\\nexuslink-pty-%lu", pid);
  HANDLE pipe = CreateNamedPipeW(
      name, PIPE_ACCESS_INBOUND, PIPE_TYPE_BYTE | PIPE_WAIT,
      1, 1024, 1024, 0, nullptr);
  if (pipe == INVALID_HANDLE_VALUE) return;
  for (;;) {
    if (!ConnectNamedPipe(pipe, nullptr) && GetLastError() != ERROR_PIPE_CONNECTED) break;
    char buf[128] = {};
    DWORD n = 0;
    if (ReadFile(pipe, buf, sizeof(buf) - 1, &n, nullptr) && n && g_hpc) {
      int cols = 80, rows = 24;
      sscanf(buf, "{\"cols\":%d,\"rows\":%d}", &cols, &rows);
      COORD size;
      size.X = (SHORT)(cols > 0 ? cols : 80);
      size.Y = (SHORT)(rows > 0 ? rows : 24);
      ResizePseudoConsole(g_hpc, size);
    }
    DisconnectNamedPipe(pipe);
  }
  CloseHandle(pipe);
}

int wmain(int argc, wchar_t** argv) {
  SHORT cols = 80, rows = 24;
  std::wstring shell = L"powershell.exe";
  for (int i = 1; i < argc; i++) {
    if (wcscmp(argv[i], L"--cols") == 0 && i + 1 < argc) cols = (SHORT)_wtoi(argv[++i]);
    else if (wcscmp(argv[i], L"--rows") == 0 && i + 1 < argc) rows = (SHORT)_wtoi(argv[++i]);
    else if (wcscmp(argv[i], L"--") == 0 && i + 1 < argc) {
      shell = argv[++i];
      break;
    } else if (argv[i][0] != L'-') {
      shell = argv[i];
    }
  }

  HANDLE inRead = nullptr, outWrite = nullptr;
  SECURITY_ATTRIBUTES sa{ sizeof(sa), nullptr, TRUE };
  CreatePipe(&inRead, &g_inWrite, &sa, 0);
  CreatePipe(&g_outRead, &outWrite, &sa, 0);
  SetHandleInformation(g_inWrite, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(g_outRead, HANDLE_FLAG_INHERIT, 0);

  COORD size{ cols, rows };
  if (FAILED(CreatePseudoConsole(size, inRead, outWrite, 0, &g_hpc))) return 1;
  CloseHandle(inRead);
  CloseHandle(outWrite);

  STARTUPINFOEXW si{ sizeof(STARTUPINFOEXW) };
  SIZE_T attr = 0;
  InitializeProcThreadAttributeList(nullptr, 1, 0, &attr);
  si.lpAttributeList = (LPPROC_THREAD_ATTRIBUTE_LIST)HeapAlloc(GetProcessHeap(), 0, attr);
  InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &attr);
  UpdateProcThreadAttribute(si.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, g_hpc, sizeof(g_hpc), nullptr, nullptr);

  PROCESS_INFORMATION pi{};
  std::wstring cmd = L"\"" + shell + L"\"";
  std::vector<wchar_t> cmdBuf(cmd.begin(), cmd.end());
  cmdBuf.push_back(0);
  if (!CreateProcessW(nullptr, cmdBuf.data(), nullptr, nullptr, FALSE, EXTENDED_STARTUPINFO_PRESENT, nullptr, nullptr, &si.StartupInfo, &pi)) {
    return 2;
  }
  g_child = pi.hProcess;
  CloseHandle(pi.hThread);
  DeleteProcThreadAttributeList(si.lpAttributeList);

  std::thread(resize_server, GetCurrentProcessId()).detach();
  std::thread([] { pump(GetStdHandle(STD_INPUT_HANDLE), g_inWrite); }).detach();
  pump(g_outRead, GetStdHandle(STD_OUTPUT_HANDLE));
  WaitForSingleObject(g_child, INFINITE);
  ClosePseudoConsole(g_hpc);
  return 0;
}

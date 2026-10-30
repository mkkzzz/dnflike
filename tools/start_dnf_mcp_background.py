"""Run the MCP server and its Godot children on a private Windows desktop.

The desktop is never switched to the user's input desktop. Inherited stdio keeps
MCP transport unchanged; a kill-on-close job prevents orphaned render processes.
"""
from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
import msvcrt
import os
from pathlib import Path
import subprocess
import sys
import uuid


class STARTUPINFO(ctypes.Structure):
    _fields_ = [
        ('cb', wintypes.DWORD), ('lpReserved', wintypes.LPWSTR),
        ('lpDesktop', wintypes.LPWSTR), ('lpTitle', wintypes.LPWSTR),
        ('dwX', wintypes.DWORD), ('dwY', wintypes.DWORD),
        ('dwXSize', wintypes.DWORD), ('dwYSize', wintypes.DWORD),
        ('dwXCountChars', wintypes.DWORD), ('dwYCountChars', wintypes.DWORD),
        ('dwFillAttribute', wintypes.DWORD), ('dwFlags', wintypes.DWORD),
        ('wShowWindow', wintypes.WORD), ('cbReserved2', wintypes.WORD),
        ('lpReserved2', ctypes.POINTER(ctypes.c_byte)),
        ('hStdInput', wintypes.HANDLE), ('hStdOutput', wintypes.HANDLE),
        ('hStdError', wintypes.HANDLE),
    ]


class PROCESS_INFORMATION(ctypes.Structure):
    _fields_ = [('hProcess', wintypes.HANDLE), ('hThread', wintypes.HANDLE),
                ('dwProcessId', wintypes.DWORD), ('dwThreadId', wintypes.DWORD)]


class BASIC_LIMIT(ctypes.Structure):
    _fields_ = [('PerProcessUserTimeLimit', ctypes.c_int64),
                ('PerJobUserTimeLimit', ctypes.c_int64),
                ('LimitFlags', wintypes.DWORD),
                ('MinimumWorkingSetSize', ctypes.c_size_t),
                ('MaximumWorkingSetSize', ctypes.c_size_t),
                ('ActiveProcessLimit', wintypes.DWORD),
                ('Affinity', ctypes.c_size_t),
                ('PriorityClass', wintypes.DWORD),
                ('SchedulingClass', wintypes.DWORD)]


class IO_COUNTERS(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint64) for name in
                ('ReadOperationCount', 'WriteOperationCount', 'OtherOperationCount',
                 'ReadTransferCount', 'WriteTransferCount', 'OtherTransferCount')]


class EXTENDED_LIMIT(ctypes.Structure):
    _fields_ = [('BasicLimitInformation', BASIC_LIMIT), ('IoInfo', IO_COUNTERS),
                ('ProcessMemoryLimit', ctypes.c_size_t),
                ('JobMemoryLimit', ctypes.c_size_t),
                ('PeakProcessMemoryUsed', ctypes.c_size_t),
                ('PeakJobMemoryUsed', ctypes.c_size_t)]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--node', required=True, type=Path)
    args = parser.parse_args()
    node = args.node.resolve(strict=True)
    entry = Path(__file__).resolve().with_name('start_dnf_mcp.mjs')
    os.environ['DNF_PRIVATE_DESKTOP'] = '1'
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    user = ctypes.WinDLL('user32', use_last_error=True)
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    user.CreateDesktopW.argtypes = [wintypes.LPCWSTR, wintypes.LPCWSTR,
                                    ctypes.c_void_p, wintypes.DWORD,
                                    wintypes.DWORD, ctypes.c_void_p]
    user.CreateDesktopW.restype = wintypes.HANDLE
    user.CloseDesktop.argtypes = [wintypes.HANDLE]
    kernel.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
    kernel.CreateJobObjectW.restype = wintypes.HANDLE
    kernel.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int,
                                               ctypes.c_void_p, wintypes.DWORD]
    kernel.SetHandleInformation.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.DWORD]
    kernel.CreateProcessW.argtypes = [wintypes.LPCWSTR, wintypes.LPWSTR,
                                     ctypes.c_void_p, ctypes.c_void_p,
                                     wintypes.BOOL, wintypes.DWORD,
                                     ctypes.c_void_p, wintypes.LPCWSTR,
                                     ctypes.POINTER(STARTUPINFO),
                                     ctypes.POINTER(PROCESS_INFORMATION)]
    kernel.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
    kernel.ResumeThread.argtypes = [wintypes.HANDLE]
    kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    kernel.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    kernel.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
    def check(value):
        if not value:
            raise ctypes.WinError(ctypes.get_last_error())
        return value

    desktop_name = 'dnf_codex_' + uuid.uuid4().hex
    desktop = check(user.CreateDesktopW(desktop_name, None, None, 0, 0x01FF, None))
    job = None
    process = PROCESS_INFORMATION()
    try:
        job = check(kernel.CreateJobObjectW(None, None))
        limits = EXTENDED_LIMIT()
        limits.BasicLimitInformation.LimitFlags = 0x2000  # KILL_ON_JOB_CLOSE
        check(kernel.SetInformationJobObject(job, 9, ctypes.byref(limits), ctypes.sizeof(limits)))
        startup = STARTUPINFO()
        startup.cb = ctypes.sizeof(startup)
        startup.lpDesktop = 'WinSta0\\' + desktop_name
        startup.dwFlags = 0x0101  # USESTDHANDLES | USESHOWWINDOW
        startup.wShowWindow = 0  # SW_HIDE; private desktop also isolates GUI windows
        for attribute, stream in [('hStdInput', sys.stdin), ('hStdOutput', sys.stdout),
                                  ('hStdError', sys.stderr)]:
            handle = msvcrt.get_osfhandle(stream.fileno())
            check(kernel.SetHandleInformation(handle, 1, 1))
            setattr(startup, attribute, handle)
        command = ctypes.create_unicode_buffer(subprocess.list2cmdline([str(node), str(entry)]))
        # Start suspended so no descendant can escape the cleanup job assignment.
        check(kernel.CreateProcessW(str(node), command, None, None, True,
                                    0x08000004, None, str(entry.parent.parent),
                                    ctypes.byref(startup), ctypes.byref(process)))
        try:
            check(kernel.AssignProcessToJobObject(job, process.hProcess))
        except Exception:
            kernel.TerminateProcess(process.hProcess, 1)
            raise
        if kernel.ResumeThread(process.hThread) == 0xFFFFFFFF:
            raise ctypes.WinError(ctypes.get_last_error())
        print('[DNF_BACKGROUND] MCP rendering isolated on a private desktop.', file=sys.stderr, flush=True)
        result = kernel.WaitForSingleObject(process.hProcess, 0xFFFFFFFF)
        if result == 0xFFFFFFFF:
            raise ctypes.WinError(ctypes.get_last_error())
        code = wintypes.DWORD()
        check(kernel.GetExitCodeProcess(process.hProcess, ctypes.byref(code)))
        return code.value
    finally:
        # Closing the job also terminates any Godot child left after a failed MCP.
        if job:
            kernel.CloseHandle(job)
        if process.hThread:
            kernel.CloseHandle(process.hThread)
        if process.hProcess:
            kernel.CloseHandle(process.hProcess)
        user.CloseDesktop(desktop)


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f'[DNF_BACKGROUND] Cannot start isolated desktop: {error}', file=sys.stderr)
        raise SystemExit(1)

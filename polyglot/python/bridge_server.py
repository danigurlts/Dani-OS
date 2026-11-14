#!/usr/bin/env python3
"""
DaniOs Zone 3 Polyglot Worker: Python Low-Level Syscall, Hardware & Memory Probe Daemon
License: GNU GPLv3
"""

import ctypes
import hashlib
import json
import os
import platform
import re
import shutil
import socket
import stat
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict

PIPE_NAME = os.environ.get("DANIOS_PIPE_NAME", "DaniOs.Pipe.Python")
SESSION_NONCE = os.environ.get("DANIOS_SESSION_NONCE", "")

if not SESSION_NONCE:
    sys.stderr.write("[DaniOs::Python] FATAL: Missing DANIOS_SESSION_NONCE in environment.\n")
    sys.exit(1)

RESTRICTED_PATH_PATTERN = re.compile(
    r"[/\\](tier_1_active|tier_2_rolling|tier_3_baseline|kernel[/\\]seeds)",
    re.IGNORECASE,
)


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def assert_non_restricted_path(target_path: str) -> Path:
    if RESTRICTED_PATH_PATTERN.search(target_path):
        raise PermissionError(
            f"ZoneBoundaryViolation: Python worker blocked from accessing parallel 3x3 path '{target_path}'."
        )
    return Path(target_path).resolve()


def probe_hardware_telemetry(_payload: Dict[str, Any]) -> Dict[str, Any]:
    cpu_count = os.cpu_count() or 1
    mem_total_bytes = 0
    mem_avail_bytes = 0
    mem_load_pct = 0.0
    uptime_sec = 0.0

    if sys.platform == "win32":
        class MEMORYSTATUSEX(ctypes.Structure):
            _fields_ = [
                ("dwLength", ctypes.c_ulong),
                ("dwMemoryLoad", ctypes.c_ulong),
                ("ullTotalPhys", ctypes.c_ulonglong),
                ("ullAvailPhys", ctypes.c_ulonglong),
                ("ullTotalPageFile", ctypes.c_ulonglong),
                ("ullAvailPageFile", ctypes.c_ulonglong),
                ("ullTotalVirtual", ctypes.c_ulonglong),
                ("ullAvailVirtual", ctypes.c_ulonglong),
                ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
            ]

        mem_status = MEMORYSTATUSEX()
        mem_status.dwLength = ctypes.sizeof(MEMORYSTATUSEX)
        if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(mem_status)):
            mem_total_bytes = int(mem_status.ullTotalPhys)
            mem_avail_bytes = int(mem_status.ullAvailPhys)
            mem_load_pct = float(mem_status.dwMemoryLoad)

        ctypes.windll.kernel32.GetTickCount64.restype = ctypes.c_ulonglong
        uptime_sec = round(ctypes.windll.kernel32.GetTickCount64() / 1000.0, 2)
    else:
        meminfo: Dict[str, int] = {}
        try:
            with open("/proc/meminfo", "r", encoding="utf-8") as fh:
                for line in fh:
                    parts = line.split()
                    if len(parts) >= 2:
                        meminfo[parts[0].rstrip(":")] = int(parts[1]) * 1024
            mem_total_bytes = meminfo.get("MemTotal", 0)
            mem_avail_bytes = meminfo.get("MemAvailable", meminfo.get("MemFree", 0))
            if mem_total_bytes > 0:
                mem_load_pct = round(((mem_total_bytes - mem_avail_bytes) / mem_total_bytes) * 100.0, 2)
        except OSError:
            pass

        try:
            with open("/proc/uptime", "r", encoding="utf-8") as fh:
                uptime_sec = round(float(fh.read().split()[0]), 2)
        except OSError:
            pass

    root_anchor = os.environ.get("SystemDrive", "C:\\") if sys.platform == "win32" else "/"
    disk = shutil.disk_usage(root_anchor)

    return {
        "platform": platform.system(),
        "release": platform.release(),
        "arch": platform.machine(),
        "cpuLogicalCores": cpu_count,
        "uptimeSeconds": uptime_sec,
        "memory": {
            "totalBytes": mem_total_bytes,
            "availableBytes": mem_avail_bytes,
            "usedPercent": mem_load_pct,
        },
        "storageRoot": {
            "mount": root_anchor,
            "totalBytes": disk.total,
            "freeBytes": disk.free,
            "usedPercent": round(((disk.total - disk.free) / max(1, disk.total)) * 100.0, 2),
        },
    }


def inspect_block_io(payload: Dict[str, Any]) -> Dict[str, Any]:
    raw_target = str(payload.get("path") or (os.environ.get("SystemDrive", "C:\\") if sys.platform == "win32" else "/"))
    target = assert_non_restricted_path(raw_target)
    usage = shutil.disk_usage(target)

    bytes_per_sector = 512
    sectors_per_cluster = 8
    read_only = False

    if sys.platform == "win32":
        root_path = os.path.splitdrive(str(target))[0] + "\\"
        spc = ctypes.c_ulong()
        bps = ctypes.c_ulong()
        nfc = ctypes.c_ulong()
        tnc = ctypes.c_ulong()
        ok = ctypes.windll.kernel32.GetDiskFreeSpaceW(
            ctypes.c_wchar_p(root_path), ctypes.byref(spc), ctypes.byref(bps), ctypes.byref(nfc), ctypes.byref(tnc)
        )
        if ok:
            bytes_per_sector = int(bps.value)
            sectors_per_cluster = int(spc.value)
    else:
        st = os.statvfs(target)
        bytes_per_sector = int(st.f_frsize or st.f_bsize or 4096)
        sectors_per_cluster = max(1, int(st.f_bsize // max(1, bytes_per_sector)))
        read_only = bool(st.f_flag & getattr(os, "ST_RDONLY", 1))

    free_ratio = usage.free / max(1, usage.total)
    integrity_score = round(min(1.0, max(0.0, (0.0 if read_only else 0.7) + (0.3 * min(1.0, free_ratio * 5.0)))), 4)

    return {
        "target": str(target),
        "bytesPerSector": bytes_per_sector,
        "sectorsPerCluster": sectors_per_cluster,
        "clusterBytes": bytes_per_sector * sectors_per_cluster,
        "totalBytes": usage.total,
        "freeBytes": usage.free,
        "readOnly": read_only,
        "IntegrityScore": integrity_score,
    }


def inspect_process_memory(payload: Dict[str, Any]) -> Dict[str, Any]:
    pid = int(payload.get("pid") or os.getpid())
    if pid <= 0:
        raise ValueError("InvalidPid: PID must be greater than 0.")

    if sys.platform == "win32":
        class PROCESS_MEMORY_COUNTERS(ctypes.Structure):
            _fields_ = [
                ("cb", ctypes.c_ulong),
                ("PageFaultCount", ctypes.c_ulong),
                ("PeakWorkingSetSize", ctypes.c_size_t),
                ("WorkingSetSize", ctypes.c_size_t),
                ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
                ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                ("PagefileUsage", ctypes.c_size_t),
                ("PeakPagefileUsage", ctypes.c_size_t),
            ]

        h_proc = ctypes.windll.kernel32.OpenProcess(0x1000 | 0x0010, False, pid)
        if not h_proc:
            raise OSError(f"OpenProcessFailed for PID {pid}")

        try:
            pmc = PROCESS_MEMORY_COUNTERS()
            pmc.cb = ctypes.sizeof(PROCESS_MEMORY_COUNTERS)
            if not ctypes.windll.psapi.GetProcessMemoryInfo(h_proc, ctypes.byref(pmc), pmc.cb):
                raise OSError(f"GetProcessMemoryInfoFailed for PID {pid}")

            return {
                "pid": pid,
                "workingSetBytes": int(pmc.WorkingSetSize),
                "peakWorkingSetBytes": int(pmc.PeakWorkingSetSize),
                "pagefileBytes": int(pmc.PagefileUsage),
                "pageFaults": int(pmc.PageFaultCount),
            }
        finally:
            ctypes.windll.kernel32.CloseHandle(h_proc)
    else:
        status_file = Path(f"/proc/{pid}/status")
        if not status_file.exists():
            raise FileNotFoundError(f"ProcessNotFound: /proc/{pid}/status does not exist.")

        metrics: Dict[str, int] = {}
        for line in status_file.read_text(encoding="utf-8").splitlines():
            if line.startswith(("VmRSS:", "VmPeak:", "VmSize:", "Threads:")):
                key, rest = line.split(":", 1)
                num = int(rest.strip().split()[0])
                metrics[key] = num * 1024 if key.startswith("Vm") else num

        return {
            "pid": pid,
            "workingSetBytes": metrics.get("VmRSS", 0),
            "peakWorkingSetBytes": metrics.get("VmPeak", 0),
            "virtualBytes": metrics.get("VmSize", 0),
            "threads": metrics.get("Threads", 0),
        }


def verify_file_integrity(payload: Dict[str, Any]) -> Dict[str, Any]:
    raw_path = str(payload.get("path") or "")
    if not raw_path:
        raise ValueError("Missing 'path' in VerifyFileIntegrity payload.")

    target = assert_non_restricted_path(raw_path)
    if not target.is_file():
        raise FileNotFoundError(f"FileNotFound: '{target}'")

    hasher = hashlib.sha256()
    with target.open("rb") as fh:
        while chunk := fh.read(65536):
            hasher.update(chunk)

    st = target.stat()
    return {
        "path": str(target),
        "sha256": hasher.hexdigest(),
        "sizeBytes": st.st_size,
        "modeOctal": oct(stat.S_IMODE(st.st_mode)),
        "modifiedUtc": datetime.fromtimestamp(st.st_mtime, timezone.utc).isoformat().replace("+00:00", "Z"),
    }


ACTION_DISPATCH: Dict[str, Callable[[Dict[str, Any]], Dict[str, Any]]] = {
    "ProbeHardwareTelemetry": probe_hardware_telemetry,
    "InspectBlockIO": inspect_block_io,
    "inspect_sectors": inspect_block_io,
    "InspectProcessMemory": inspect_process_memory,
    "VerifyFileIntegrity": verify_file_integrity,
    "Ping": lambda _p: {"pong": True, "pythonVersion": sys.version.split()[0]},
}


def process_envelope(raw_line: str) -> str:
    request_id = None
    try:
        if RESTRICTED_PATH_PATTERN.search(raw_line):
            raise PermissionError("ZoneBoundaryViolation: Restricted 3x3 partition path detected in Python worker.")

        envelope = json.loads(raw_line)
        request_id = envelope.get("Id")

        if envelope.get("Nonce") != SESSION_NONCE:
            raise PermissionError("ZoneBoundaryViolation: Session nonce mismatch on Python IPC pipe.")

        action = str(envelope.get("Action") or "")
        payload = envelope.get("Payload")
        if not isinstance(payload, dict):
            payload = {}

        handler = ACTION_DISPATCH.get(action)
        if handler is None:
            raise ValueError(f"UnsupportedPythonAction: '{action}'")

        result = handler(payload)
        return json.dumps({
            "Id": request_id, "Nonce": SESSION_NONCE, "Domain": "Python",
            "Ok": True, "Timestamp": utc_now_iso(), "Payload": result,
        }) + "\n"
    except Exception as exc:
        return json.dumps({
            "Id": request_id, "Nonce": SESSION_NONCE, "Domain": "Python",
            "Ok": False, "Timestamp": utc_now_iso(), "Payload": {"error": str(exc)},
        }) + "\n"


def serve_windows_named_pipe(pipe_name: str) -> None:
    kernel32 = ctypes.windll.kernel32
    win_pipe_path = f"\\\\.\\pipe\\{pipe_name}"
    INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value
    ERROR_PIPE_CONNECTED = 535

    kernel32.CreateNamedPipeW.restype = ctypes.c_void_p
    h_pipe = kernel32.CreateNamedPipeW(
        ctypes.c_wchar_p(win_pipe_path), 0x00000003, 0x00000000, 16, 65536, 65536, 0, None
    )
    if not h_pipe or h_pipe == INVALID_HANDLE_VALUE:
        sys.exit(1)

    sys.stdout.write(f"[DaniOs::Python] Listening on {win_pipe_path}\n")
    sys.stdout.flush()

    read_buf = ctypes.create_string_buffer(65536)
    bytes_read = ctypes.c_ulong(0)
    bytes_written = ctypes.c_ulong(0)

    try:
        while True:
            connected = kernel32.ConnectNamedPipe(ctypes.c_void_p(h_pipe), None)
            if connected == 0 and kernel32.GetLastError() != ERROR_PIPE_CONNECTED:
                time.sleep(0.01)
                continue

            line_buffer = ""
            while True:
                ok = kernel32.ReadFile(ctypes.c_void_p(h_pipe), read_buf, 65535, ctypes.byref(bytes_read), None)
                if ok == 0 or bytes_read.value == 0:
                    break
                line_buffer += read_buf.raw[: bytes_read.value].decode("utf-8", errors="replace")
                while "\n" in line_buffer:
                    line, line_buffer = line_buffer.split("\n", 1)
                    line = line.strip()
                    if not line:
                        continue
                    response_bytes = process_envelope(line).encode("utf-8")
                    kernel32.WriteFile(ctypes.c_void_p(h_pipe), response_bytes, len(response_bytes), ctypes.byref(bytes_written), None)
                    kernel32.FlushFileBuffers(ctypes.c_void_p(h_pipe))

            kernel32.DisconnectNamedPipe(ctypes.c_void_p(h_pipe))
    finally:
        kernel32.CloseHandle(ctypes.c_void_p(h_pipe))


def serve_posix_unix_pipe(pipe_name: str) -> None:
    sock_path = f"/tmp/CoreFxPipe_{pipe_name}"
    if os.path.exists(sock_path):
        os.unlink(sock_path)

    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(sock_path)
    os.chmod(sock_path, 0o600)
    srv.listen(16)

    sys.stdout.write(f"[DaniOs::Python] Listening on {sock_path}\n")
    sys.stdout.flush()

    try:
        while True:
            conn, _ = srv.accept()
            with conn:
                reader = conn.makefile("r", encoding="utf-8")
                for line in reader:
                    trimmed = line.strip()
                    if not trimmed:
                        continue
                    conn.sendall(process_envelope(trimmed).encode("utf-8"))
    finally:
        srv.close()
        if os.path.exists(sock_path):
            os.unlink(sock_path)


if __name__ == "__main__":
    try:
        if sys.platform == "win32":
            serve_windows_named_pipe(PIPE_NAME)
        else:
            serve_posix_unix_pipe(PIPE_NAME)
    except KeyboardInterrupt:
        sys.exit(0)

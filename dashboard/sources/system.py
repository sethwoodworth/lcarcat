"""Local machine telemetry.

``psutil`` when it is installed, platform commands when it is not. The fallback
exists because this pane should render on a machine where nothing has been
installed for it -- an LCARS status board that needs a pip install before it can
report a load average is not a status board.

Every reading is optional. A value that could not be measured comes back as
``None`` and the widget leaves that row blank rather than showing a zero, which
would read as a real measurement.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import time
from dataclasses import dataclass
from typing import List, Optional, Tuple

try:  # pragma: no cover - depends on the machine
    import psutil
except ImportError:  # pragma: no cover
    psutil = None


@dataclass(frozen=True)
class Telemetry:
    load_average: Optional[Tuple[float, float, float]]
    cpu_count: int
    memory_used_bytes: Optional[int]
    memory_total_bytes: Optional[int]
    disk_used_bytes: Optional[int]
    disk_total_bytes: Optional[int]
    battery_percent: Optional[float]
    battery_charging: Optional[bool]
    uptime_seconds: Optional[float]
    hostname: str

    @property
    def load_fraction(self) -> Optional[float]:
        """One-minute load as a share of the machine's cores."""
        if self.load_average is None or not self.cpu_count:
            return None
        return self.load_average[0] / self.cpu_count

    @property
    def memory_fraction(self) -> Optional[float]:
        if not self.memory_total_bytes or self.memory_used_bytes is None:
            return None
        return self.memory_used_bytes / self.memory_total_bytes

    @property
    def disk_fraction(self) -> Optional[float]:
        if not self.disk_total_bytes or self.disk_used_bytes is None:
            return None
        return self.disk_used_bytes / self.disk_total_bytes

    def uptime_label(self) -> str:
        if self.uptime_seconds is None:
            return "UNKNOWN"
        days, remainder = divmod(int(self.uptime_seconds), 86400)
        hours, remainder = divmod(remainder, 3600)
        minutes = remainder // 60
        if days:
            return "%dD %02dH" % (days, hours)
        return "%02dH %02dM" % (hours, minutes)


def _gigabytes(value: Optional[int]) -> str:
    if value is None:
        return "--"
    return "%.1fG" % (value / 1024 ** 3)


def format_bytes(value: Optional[int]) -> str:
    return _gigabytes(value)


def _macos_memory() -> Tuple[Optional[int], Optional[int]]:
    """Used and total physical memory on macOS, from ``vm_stat`` and ``sysctl``.

    "Used" is counted the way Activity Monitor's memory pressure does -- active,
    wired and compressed pages -- rather than as everything that is not free.
    macOS keeps almost nothing free by design, so the naive sum reads as 99% on an
    idle machine and tells you nothing.
    """
    total: Optional[int] = None
    try:
        output = subprocess.run(["sysctl", "-n", "hw.memsize"],
                                capture_output=True, text=True, timeout=3)
        if output.returncode == 0:
            total = int(output.stdout.strip())
    except (OSError, ValueError, subprocess.SubprocessError):
        pass

    used: Optional[int] = None
    try:
        output = subprocess.run(["vm_stat"], capture_output=True, text=True, timeout=3)
        if output.returncode == 0:
            page_size = 4096
            header = re.search(r"page size of (\d+) bytes", output.stdout)
            if header:
                page_size = int(header.group(1))
            counts = dict(re.findall(r"^(.+?):\s+(\d+)\.$", output.stdout, re.MULTILINE))
            pages = 0
            for key in ("Pages active", "Pages wired down", "Pages occupied by compressor"):
                pages += int(counts.get(key, 0))
            used = pages * page_size
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    return (used, total)


def _macos_battery() -> Tuple[Optional[float], Optional[bool]]:
    if shutil.which("pmset") is None:
        return (None, None)
    try:
        output = subprocess.run(["pmset", "-g", "batt"],
                                capture_output=True, text=True, timeout=3)
    except (OSError, subprocess.SubprocessError):
        return (None, None)
    if output.returncode != 0:
        return (None, None)
    percent = re.search(r"(\d+)%", output.stdout)
    if percent is None:
        return (None, None)
    charging = ("AC Power" in output.stdout
                or "charging" in output.stdout.lower()
                and "discharging" not in output.stdout.lower())
    return (float(percent.group(1)), charging)


def _uptime_seconds() -> Optional[float]:
    if psutil is not None:  # pragma: no cover - depends on the machine
        try:
            return time.time() - psutil.boot_time()
        except Exception:  # noqa: BLE001
            return None
    try:
        output = subprocess.run(["sysctl", "-n", "kern.boottime"],
                                capture_output=True, text=True, timeout=3)
        if output.returncode == 0:
            match = re.search(r"sec\s*=\s*(\d+)", output.stdout)
            if match:
                return time.time() - int(match.group(1))
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    try:
        with open("/proc/uptime", encoding="utf-8") as handle:
            return float(handle.read().split()[0])
    except (OSError, ValueError, IndexError):
        return None


def read(disk_path: str = "/") -> Telemetry:
    """Take one reading. Never raises."""
    try:
        load_average = os.getloadavg()
    except (OSError, AttributeError):
        load_average = None

    memory_used = memory_total = None
    battery_percent = battery_charging = None
    if psutil is not None:  # pragma: no cover - depends on the machine
        try:
            virtual = psutil.virtual_memory()
            memory_total = virtual.total
            memory_used = virtual.total - virtual.available
        except Exception:  # noqa: BLE001
            pass
        try:
            battery = psutil.sensors_battery()
            if battery is not None:
                battery_percent = battery.percent
                battery_charging = battery.power_plugged
        except Exception:  # noqa: BLE001
            pass
    if memory_total is None:
        memory_used, memory_total = _macos_memory()
    if battery_percent is None:
        battery_percent, battery_charging = _macos_battery()

    disk_used = disk_total = None
    try:
        usage = shutil.disk_usage(disk_path)
        disk_used, disk_total = usage.used, usage.total
    except OSError:
        pass

    return Telemetry(
        load_average=load_average,
        cpu_count=os.cpu_count() or 1,
        memory_used_bytes=memory_used,
        memory_total_bytes=memory_total,
        disk_used_bytes=disk_used,
        disk_total_bytes=disk_total,
        battery_percent=battery_percent,
        battery_charging=battery_charging,
        uptime_seconds=_uptime_seconds(),
        hostname=(os.uname().nodename.split(".")[0] if hasattr(os, "uname") else "LOCAL"),
    )


class History:
    """A bounded ring of past readings, for sparklines."""

    def __init__(self, size: int = 120) -> None:
        self.size = size
        self.values: List[float] = []

    def push(self, value: Optional[float]) -> None:
        if value is None:
            return
        self.values.append(value)
        if len(self.values) > self.size:
            del self.values[: len(self.values) - self.size]

    def tail(self, count: int) -> List[float]:
        return self.values[-count:] if count > 0 else []

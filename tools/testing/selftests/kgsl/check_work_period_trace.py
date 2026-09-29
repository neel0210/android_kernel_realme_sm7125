#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Validate the work-period contract in a collected ftrace snapshot."""
import collections
import pathlib
import re
import sys

pattern = re.compile(r'gpu_work_period: gpu_id=(\d+) uid=(\d+) start_time_ns=(\d+) end_time_ns=(\d+) total_active_duration_ns=(\d+)')
events = [tuple(map(int, m.groups())) for m in pattern.finditer(pathlib.Path(sys.argv[1]).read_text())]
if not events:
    raise SystemExit('FAIL: no GPU work-period events; exercise the GPU during capture')
last = {}
totals = collections.Counter()
for gpu, uid, start, end, active in sorted(events, key=lambda e: (e[0], e[1], e[2])):
    assert 0 < active <= end - start <= 1_000_000_000, (gpu, uid, start, end, active)
    assert start >= last.get((gpu, uid), 0), ('overlapping UID periods', gpu, uid)
    last[gpu, uid] = end
    totals[gpu, uid] += active
print(f'PASS: {len(events)} events, {len(totals)} GPU/UID pairs; valid durations and nonoverlapping periods')
for (gpu, uid), active in sorted(totals.items()):
    print(f'  GPU {gpu}, UID {uid}: {active / 1_000_000:.3f} ms active')

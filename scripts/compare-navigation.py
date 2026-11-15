#!/usr/bin/env python3
# 两版按帧交替，一版等待管道时另一版才执行，避免把不同时段的机器负载差当成代码退步。
# 工具只依赖 Python 标准库；配套插桩在报告中的 performance-stepper.patch，不进入正常界面。
import argparse
import json
import math
import signal
import subprocess
from pathlib import Path

PREFIX = b"SKYSHEET_STEP "


def timeout(_signal, _frame):
    raise TimeoutError("benchmark did not produce the next frame")


signal.signal(signal.SIGALRM, timeout)


def stats(values):
    values = sorted(values)
    return {"frames": len(values), "median": values[len(values) // 2],
            "p95": values[math.ceil(len(values) * .95) - 1], "min": values[0], "max": values[-1]}


class Runner:
    def __init__(self, binary, workbook, mode, frames, stem):
        self.log = stem.with_suffix(".log").open("wb")
        self.process = subprocess.Popen([str(binary), "--benchmark", str(workbook), "--benchmark-only", mode,
                                         "--frames", str(frames + 20), "--benchmark-json", str(stem.with_suffix(".json")),
                                         "--benchmark-stepper"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.log, bufsize=0)
        try:
            self.ready = self.event()
            if self.ready is None or self.ready["state"] != "ready":
                raise RuntimeError("missing benchmark stepper instrumentation")
        except BaseException:
            self.close()
            raise

    def event(self):
        signal.alarm(900)
        try:
            while True:
                line = self.process.stdout.readline()
                if not line:
                    code = self.process.wait()
                    if code != 0:
                        raise RuntimeError(f"benchmark exited with {code}")
                    return None
                self.log.write(line)
                if line.startswith(PREFIX):
                    return json.loads(line[len(PREFIX):])
        finally:
            signal.alarm(0)

    def step(self):
        self.process.stdin.write(b"go\n")
        self.process.stdin.flush()
        sample = self.event()
        if sample is None or sample["state"] != "sample":
            raise RuntimeError(f"expected a frame sample, got {sample}")
        self.ready = self.event()
        return sample

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                # 只清理本工具启动、记录了 PID 的子进程，不能碰作者正在用的程序。
                self.process.terminate()
                self.process.wait(timeout=15)
        self.log.close()


def compare(before, after, workbook, mode, frames, stem, reverse):
    runners = {}
    rows = []
    try:
        binaries = {"before": before, "after": after}
        # 启动第二版之前，第一版已载入并停在管道上，载入过程也不并行。
        for version in (["after", "before"] if reverse else ["before", "after"]):
            runners[version] = Runner(binaries[version], workbook, mode, frames,
                                      Path(str(stem) + "-" + version))
        while any(runner.ready is not None for runner in runners.values()):
            left, right = runners["before"].ready, runners["after"].ready
            if left is None or right is None or left["state"] != "ready" or right["state"] != "ready" or (left["name"], left["index"]) != (right["name"], right["index"]):
                raise RuntimeError(f"frame sequences differ: {left}, {right}")
            index, name = left["index"], left["name"]
            samples = {}
            # 连帧内的先后顺序也交替；等前一个进入下一次等待后，才放行另一个。
            for version in (["after", "before"] if index % 2 else ["before", "after"]):
                samples[version] = runners[version].step()
            for sample in samples.values():
                if (sample["name"], sample["index"]) != (name, index):
                    raise RuntimeError("unexpected sample order")
            # 两版均已载入后，再丢弃前 20 对样本，让被暂时挤出的页和字体缓存恢复。
            if index >= 20:
                rows.append({"name": name, "index": index,
                             "before": samples["before"]["ms"], "after": samples["after"]["ms"]})
    finally:
        for runner in runners.values():
            runner.close()
    stem.with_suffix(".frames.json").write_text(json.dumps(rows, indent=2))
    results = []
    for name in dict.fromkeys(row["name"] for row in rows):
        selected = [row for row in rows if row["name"] == name]
        if len(selected) != frames:
            raise RuntimeError(f"expected {frames} samples, got {len(selected)}")
        result = {"name": name, "before": stats([row["before"] for row in selected]),
                  "after": stats([row["after"] for row in selected]),
                  "pairedDifference": stats([row["after"] - row["before"] for row in selected])}
        results.append(result)
        print(f"{stem.name} {name}: {result['before']['median']:.3f} -> {result['after']['median']:.3f} ms", flush=True)
    stem.with_suffix(".summary.json").write_text(json.dumps(results, indent=2))


parser = argparse.ArgumentParser()
parser.add_argument("before", type=Path)
parser.add_argument("after", type=Path)
parser.add_argument("inputs", type=Path)
parser.add_argument("output", type=Path)
parser.add_argument("--frames", type=int, default=200)
parser.add_argument("--rounds", type=int, default=3)
parser.add_argument("--sheets", nargs="+", default=["loan", "data", "formulas", "styles"])
parser.add_argument("--modes", nargs="+", choices=["arrows", "scroll"], default=["arrows", "scroll"])
args = parser.parse_args()
if args.frames < 1 or args.rounds < 1:
    parser.error("frames and rounds must be positive")
args.output.mkdir(parents=True, exist_ok=False)
for turn in range(1, args.rounds + 1):
    for sheet in args.sheets:
        workbook = (Path(__file__).resolve().parents[1] / "Fixtures/loan.xlsx"
                    if sheet == "loan" else args.inputs / f"{sheet}.xlsx")
        for mode in args.modes:
            compare(args.before, args.after, workbook, mode, args.frames,
                    args.output / f"{turn}-{sheet}-{mode}", reverse=turn % 2 == 0)

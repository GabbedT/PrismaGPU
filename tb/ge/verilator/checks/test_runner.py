"""Verify transient artifact cleanup and summaries across failure paths."""

from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import run
from coverage_report import BIN_LABELS


def settings(directory, **overrides):
    return dict(MODE="standalone", TEST="identity", OUT=str(directory), SEED="1", SEEDS="16",
                TIMING_SEED="2", CASES="100", VERBOSE="0", TIMEOUT="200000",
                WALL_TIMEOUT="300", LATENCY="3", PAUSE="25", OUTPUT_HOLD="0",
                WAVE="0", COVERAGE="0", XY_TOL="0.25", Z_TOL="0.001",
                UV_TOL="0.001", COLOR_TOL="3", W_TOL="0.001", **overrides)


def counters():
    return "".join('[triangle_coverage] ' + json.dumps(
        dict(group=group, counts=[1] + [0] * (len(labels) - 1))) + '\n'
        for group, labels in BIN_LABELS.items())


class RunnerArtifacts(unittest.TestCase):
    def test_campaigns_drop_pass_logs_and_preserve_reports(self):
        for action in ("test", "regression", "coverage"):
            with self.subTest(action=action), tempfile.TemporaryDirectory() as directory:
                def simulate(command, timeout, **callbacks):
                    Path(command[-2]).write_bytes(b"triangle")
                    if command[-1] != "-":
                        Path(command[-1]).write_text("checkpoint")
                    output = counters()
                    callbacks["on_line"](output)
                    return 0, output
                with patch.dict(run.os.environ, settings(directory), clear=True), \
                     patch.object(run.sys, "argv", ["run.py", action]), \
                     patch.object(run.subprocess, "run", return_value=SimpleNamespace(returncode=0)), \
                     patch.object(run, "execute", side_effect=simulate), \
                     patch.object(run.CoverageAccumulator, "merge"), \
                     redirect_stdout(io.StringIO()):
                    self.assertEqual(run.main(), 0)
                root = next(Path(directory).iterdir())
                results = json.loads((root / "results.json").read_text())["results"]
                self.assertTrue(results)
                for result in results:
                    if action == "test":
                        self.assertEqual((root / result["log"]).read_text(), counters())
                    else:
                        self.assertIsNone(result["log"])
                    self.assertIsNotNone(result["triangle_coverage"])
                    self.assertIsNotNone(result["output_fingerprint"])
                    self.assertTrue(result["reproduce"])
                if action != "test":
                    self.assertEqual(list(root.glob("*-g*-t*.log")), [])
                self.assertTrue((root / "coverage.md").is_file())
                self.assertTrue(json.loads((root / "coverage.json").read_text())["complete"])

    def test_campaign_retains_failed_logs_and_diagnostics(self):
        failures = (
            (1, counters() + "FAIL phase=compare\n", "compare"),
            (124, counters() + "FAIL phase=wall_timeout\n", "wall_timeout"),
            (127, "FAIL phase=launch\n", "launch"),
            (0, "PASS\n", "triangle_coverage"),
            (0, counters(), "artifacts"),  # Missing output capture despite exit zero.
        )
        for code, output, diagnostic in failures:
            with self.subTest(diagnostic=diagnostic), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                results, errors = [], []
                with patch.object(run, "execute", return_value=(code, output)), \
                     redirect_stdout(io.StringIO()):
                    run.run_cases(settings(root), root, ["identity"], [2], results,
                                  None, errors, keep_pass_logs=False)
                self.assertNotEqual(results[0]["exit_code"], 0)
                self.assertIn(diagnostic, (root / results[0]["log"]).read_text())
                saved = json.loads((root / "results.json").read_text())["results"]
                self.assertEqual(saved[0]["log"], results[0]["log"])

    def test_campaign_preserves_total_budget_and_wraps_geometry_seeds(self):
        cfg = settings("out")
        cfg.update(CASES="1003", SEEDS="4", SEED=str(2**32 - 1))
        plan = list(run.campaign_plan(cfg))
        self.assertEqual(set(plan[0][1]), set(run.TESTS) - {"random"})
        random = [current for current, selected in plan[1:]]
        self.assertEqual([int(current["SEED"]) for current in random], [2**32 - 1, 0, 1, 2])
        self.assertEqual([int(current["CASES"]) for current in random], [251, 251, 251, 250])
        self.assertEqual(sum(int(current["CASES"]) for current in random), 1003)
        cfg.update(CASES="3", SEEDS="16")
        random = list(run.campaign_plan(cfg))[1:]
        self.assertEqual(len(random), 3)
        self.assertTrue(all(current["CASES"] == "1" for current, _ in random))

    def test_campaign_compares_timing_outputs_within_each_geometry_seed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cfg = settings(root)
            results, errors = [], []
            def simulate(command, timeout, **callbacks):
                Path(command[-2]).write_bytes(bytes([int(command[3])]))
                return 0, counters()
            with patch.object(run, "execute", side_effect=simulate), redirect_stdout(io.StringIO()):
                for seed in (1, 2):
                    current = dict(cfg, SEED=str(seed))
                    run.run_cases(current, root, ["random"], [2, 3], results, None,
                                  errors, report_config=cfg)
            self.assertTrue(all(result["exit_code"] == 0 for result in results))
            self.assertEqual([result["seed"] for result in results], [1, 1, 2, 2])
            self.assertNotEqual(results[0]["output_fingerprint"], results[2]["output_fingerprint"])
            self.assertEqual(json.loads((root / "results.json").read_text())["config"], cfg)

    def test_output_is_delivered_before_process_completion(self):
        with tempfile.TemporaryDirectory() as directory:
            gate = Path(directory) / "continue"
            source = (
                "import pathlib,sys,time\n"
                "print('ready', flush=True)\n"
                "while not pathlib.Path(sys.argv[1]).exists(): time.sleep(0.01)\n"
                "sys.stdout.write('finished \\u20ac'); sys.stdout.flush()\n"
            )
            lines = []
            def receive(line):
                lines.append(line)
                if line == "ready\n":
                    gate.touch()
            code, output = run.execute([sys.executable, "-c", source, str(gate)], 3,
                                       on_line=receive)
            self.assertEqual(code, 0)
            self.assertEqual(output, "ready\nfinished €")
            self.assertEqual(lines, ["ready\n", "finished €"])

    def test_streaming_timeout_retains_partial_output(self):
        lines = []
        source = "import sys,time; sys.stdout.write('partial'); sys.stdout.flush(); time.sleep(10)"
        code, output = run.execute([sys.executable, "-c", source], 0.2,
                                   on_line=lines.append)
        self.assertEqual(code, 124)
        self.assertEqual(lines, ["partial"])
        self.assertIn("partial\nFAIL phase=wall_timeout", output)

    def test_deleted_outputs_still_detect_timing_mismatch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            results, errors = [], []
            def simulate(command, timeout, **callbacks):
                self.assertFalse(list(root.glob("*.bin")))
                Path(command[-2]).write_bytes(bytes([len(results)]))
                return 0, counters()
            with patch.object(run, "execute", side_effect=simulate), redirect_stdout(io.StringIO()):
                run.run_cases(settings(root), root, ["identity"], [2, 3], results, None, errors,
                              keep_pass_logs=False)
            self.assertEqual([r["exit_code"] for r in results], [0, 1])
            self.assertIsNone(results[0]["log"])
            self.assertEqual(len(list(root.glob("*.log"))), 1)
            self.assertFalse(list(root.glob("*.bin")))
            self.assertIn("timing_invariance", (root / results[1]["log"]).read_text())
            self.assertEqual(results[0]["output_fingerprint"]["bytes"], 1)

    def test_merge_failure_removes_per_test_artifacts_and_continues(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            results, errors = [], []
            def simulate(command, timeout, **callbacks):
                self.assertFalse(list(root.glob("*.bin")))
                self.assertFalse(list(root.glob("identity-*.dat*")))
                Path(command[-2]).write_bytes(b"triangle")
                Path(command[-1]).write_text("checkpoint")
                Path(command[-1] + ".tmp").write_text("interrupted checkpoint")
                return 0, counters()
            def fail_merge(path):
                raise ValueError("analyzer failure")
            cfg = settings(root)
            cfg["COVERAGE"] = "1"
            with patch.object(run, "execute", side_effect=simulate), redirect_stdout(io.StringIO()):
                run.run_cases(cfg, root, ["identity"], [2, 3], results,
                              SimpleNamespace(merge=fail_merge), errors, keep_pass_logs=False)
            self.assertEqual(len(results), 2)
            self.assertTrue(all(r["exit_code"] for r in results))
            self.assertTrue(all((root / r["log"]).is_file() for r in results))
            self.assertEqual(len(errors), 2)
            self.assertFalse(list(root.glob("*.bin")) + list(root.glob("*.dat*")))

    def test_failed_merge_preserves_previous_total(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            coverage = run.CoverageAccumulator(root, 300)
            coverage.data.write_text("previous total")
            incoming = root / "test.dat"
            incoming.write_text("new points")
            def analyzer(command, timeout):
                Path(command[2]).write_text("partial corrupt total")
                return 1, "analyzer failure\n"
            with patch.object(run, "execute", side_effect=analyzer):
                with self.assertRaises(ValueError):
                    coverage.merge(incoming)
            self.assertEqual(coverage.data.read_text(), "previous total")
            self.assertFalse((root / "coverage.tmp").exists())

    def test_export_failures_keep_computed_totals(self):
        with tempfile.TemporaryDirectory() as directory:
            coverage = run.CoverageAccumulator(Path(directory), 300)
            source = run.HERE.parents[2] / "hw/example.sv"
            coverage.data.write_text(f"C '\x01f\x02{source}\x01page\x02v_line/example' 7\n")
            errors = []
            with patch.object(run, "execute", return_value=(1, "export failed\n")):
                summary = coverage.finish(errors)
            self.assertEqual(summary["totals"]["v_line"], {"hit": 1, "total": 1})
            self.assertEqual(len(errors), 2)
            self.assertTrue(coverage.data.exists())

    def test_build_failure_still_prints_totals(self):
        with tempfile.TemporaryDirectory() as directory:
            output = io.StringIO()
            with patch.dict(run.os.environ, settings(directory), clear=True), \
                 patch.object(run.sys, "argv", ["run.py", "regression"]), \
                 patch.object(run.subprocess, "run", return_value=SimpleNamespace(returncode=1)), \
                 redirect_stdout(output):
                self.assertEqual(run.main(), 1)
            self.assertIn("TOTAL triangle_bins=0/", output.getvalue())
            self.assertIn("TOTAL RTL v_line=unavailable", output.getvalue())
            report = json.loads(next(Path(directory).glob("*/coverage.json")).read_text())
            self.assertFalse(report["complete"])

    def test_large_campaign_default_budget_and_explicit_override(self):
        cfg = settings("out")
        cfg.update(CASES="100000", WALL_TIMEOUT="auto")
        self.assertEqual(run.configuration(cfg)["WALL_TIMEOUT"], "5000")
        cfg["WALL_TIMEOUT"] = "12"
        self.assertEqual(run.configuration(cfg)["WALL_TIMEOUT"], "12")


if __name__ == "__main__":
    unittest.main()

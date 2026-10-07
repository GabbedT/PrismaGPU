"""Checks for aggregation semantics that are hard to see in a single RTL run."""

import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from coverage_report import BIN_LABELS, rtl_summary, triangle_counts, write_reports


class CoverageReports(unittest.TestCase):
    def test_random_input_totals_exclude_timing_duplicates(self):
        def counters(count):
            return {group: [count] + [0] * (len(labels) - 1)
                    for group, labels in BIN_LABELS.items()}
        results = [dict(test="random", seed=seed, exit_code=0,
                        triangle_coverage=counters(count))
                   for seed, count in ((1, 100), (1, 100), (2, 250), (2, 250))]
        with tempfile.TemporaryDirectory() as directory:
            report = write_reports(Path(directory), results, ["random"])
        self.assertEqual(report["random_geometry_seeds"], [1, 2])
        self.assertEqual(report["unique_random_verified"], 350)
        self.assertEqual(report["triangles"]["verified_triangles"]["bins"]["verified"], 700)
        self.assertTrue(report["complete"])
        self.assertFalse(report["functional_goals_met"])

    def test_latest_complete_checkpoint_survives_a_truncated_snapshot(self):
        def snapshot(count):
            return "".join('[triangle_coverage] ' + json.dumps(
                dict(group=group, counts=[count] + [0] * (len(labels) - 1))) + '\n'
                for group, labels in BIN_LABELS.items())
        output = snapshot(0) + snapshot(1000) + snapshot(2000)
        output += '[triangle_coverage] {"group":"verified_triangles","counts":[3000]}\n'
        output += '[triangle_coverage] {"group":"plane_left","counts":['
        output += '\nFAIL phase=wall_timeout limit=300s\n'
        counters = triangle_counts(output)
        self.assertEqual(counters["verified_triangles"], [2000])
        self.assertEqual(counters["plane_left"][0], 2000)

    def test_timing_runs_merge_counts_but_not_category_bins(self):
        counters = {group: [0] * len(labels) for group, labels in BIN_LABELS.items()}
        for group in counters:
            counters[group][0] = 12
        results = [dict(test="backpressure", exit_code=0, triangle_coverage=counters,
                        stalls={"input_stalls": 2, "output_stalls": 3}) for _ in range(2)]
        with tempfile.TemporaryDirectory() as directory:
            report = write_reports(Path(directory), results, ["backpressure", "random"])
            self.assertEqual(report["categories"]["hit"], 1)
            self.assertEqual(report["categories"]["missing"], ["random"])
            self.assertEqual(report["triangles"]["verified_triangles"]["bins"]["verified"], 24)
            self.assertEqual(report["triangles"]["output_triangles"]["hit"], 1)
            self.assertEqual(report["stalls"]["output_stalls"], 6)
            self.assertEqual(json.loads((Path(directory) / "coverage.json").read_text()), report)

    def test_incomplete_run_preserves_previously_verified_cases(self):
        counters = {group: [0] * len(labels) for group, labels in BIN_LABELS.items()}
        counters["verified_triangles"][0] = 3
        results = [dict(test="random", exit_code=1, triangle_coverage=counters),
                   dict(test="reset", exit_code=124, triangle_coverage=None)]
        with tempfile.TemporaryDirectory() as directory:
            report = write_reports(Path(directory), results, ["random", "reset"],
                                   errors=["reset: missing counters"])
        self.assertFalse(report["complete"])
        self.assertEqual(report["measured_runs"], 1)
        self.assertEqual(report["categories"]["hit"], 0)
        self.assertEqual(report["triangles"]["verified_triangles"]["bins"]["verified"], 3)

    def test_missing_and_malformed_triangle_counters_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "missing"):
            triangle_counts("[wrapper] FAIL\n")
        with self.assertRaisesRegex(ValueError, "invalid"):
            triangle_counts('[triangle_coverage] {"group":"matrix","counts":[-1,2]}')

    def test_rtl_totals_separate_toggle_from_branches_and_exclude_testbench(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            rtl = root / "hw"
            rtl.mkdir()
            def point(source, kind, hits, threshold=1):
                return f"C '\x01f\x02{source}\x01t\x02{kind}\x01s\x02{threshold}' {hits}\n"
            data = root / "coverage.dat"
            data.write_text(point(rtl / "ge.sv", "line", 3) +
                            point(rtl / "ge.sv", "line", 0) +
                            f"C '\x01f\x02{rtl / 'ge.sv'}\x01page\x02v_branch/ge' 4\n" +
                            point(rtl / "ge.sv", "toggle", 1, 2) +
                            point(root / "tb.sv", "line", 100))
            report = rtl_summary(data, rtl)
        self.assertEqual(report["totals"]["line"], {"hit": 1, "total": 2})
        self.assertEqual(report["totals"]["toggle"], {"hit": 0, "total": 1})
        self.assertEqual(report["totals"]["v_branch"], {"hit": 1, "total": 1})
        self.assertEqual(list(report["files"]), ["hw/ge.sv"])


if __name__ == "__main__":
    unittest.main()

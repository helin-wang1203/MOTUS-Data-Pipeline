"""Round-trip tests: simulate station files, parse them, check the tables.

Run from the repo root:  python3 -m unittest discover -s python/tests
"""

import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import sg_files  # noqa: E402
import sg_simulate  # noqa: E402

START = datetime(2027, 2, 1, tzinfo=timezone.utc)


class RoundTrip(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.dir = Path(cls.tmp.name)
        cls.files = sg_simulate.simulate(
            cls.dir, days=2, ports=[1, 2, 3, 4], start=START, base_rate=40,
            dead_port=3, dead_from_hour=30, hot_port=2, hot_hour=10, hot_hours=3,
            outage_hour=20, outage_hours=4, gps_minutes=5, tag_passes=3,
            lat=43.72, lon=-72.25, alt=160, seed=1)
        cls.res = sg_files.parse([cls.dir])

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_file_count_and_names(self):
        self.assertEqual(len(self.files), 48 - 4)                 # outage hours have no file
        self.assertEqual(len(self.res.files), 44)
        self.assertTrue(all(f.serno == sg_simulate.SERNO for f in self.res.files))
        self.assertEqual(self.res.files[0].started, START)

    def test_boot_count_increments_after_outage(self):
        boots = {f.started.hour + 24 * (f.started.day - 1): f.boot for f in self.res.files}
        self.assertEqual(boots[19], 1)
        self.assertEqual(boots[24], 2)

    def test_settings_written_at_each_boot(self):
        self.assertEqual(len(self.res.settings), 2 * 4)
        self.assertTrue(all(s.param == "-m" and s.value == "166.376" for s in self.res.settings))

    def test_gps_cadence(self):
        self.assertEqual(len(self.res.gps), 44 * 12)
        self.assertAlmostEqual(self.res.gps[0].lat, 43.72, places=2)

    def test_no_unparsed_lines(self):
        self.assertEqual(dict(self.res.skipped), {})
        self.assertEqual(dict(self.res.unknown_types), {})

    def test_hourly_shape_matches_antenna_activity(self):
        rows = self.res.hourly()
        self.assertEqual(list(rows[0].keys()), ["batchID", "port", "hour", "n_pulses"])
        self.assertEqual(rows[0]["hour"], "2027-02-01 00:00:00")

    def test_dead_port_has_no_pulses_after_fault(self):
        rows = self.res.hourly()
        p3_hours = sorted(r["hour"] for r in rows if r["port"] == "3")
        self.assertTrue(p3_hours[-1] < "2027-02-02 06:00:00")  # hour 30 = Feb 2 06:00
        self.assertTrue(any(r["port"] == "3" for r in rows))

    def test_hot_port_spike(self):
        rows = {(r["port"], r["hour"]): r["n_pulses"] for r in self.res.hourly()}
        self.assertGreater(rows[("2", "2027-02-01 10:00:00")], 1500)
        self.assertLess(rows[("2", "2027-02-01 09:00:00")], 300)

    def test_outage_hours_absent_on_every_port(self):
        hours = {r["hour"] for r in self.res.hourly()}
        for h in (20, 21, 22, 23):
            self.assertNotIn(f"2027-02-01 {h:02d}:00:00", hours)

    def test_tag_bursts_present(self):
        tag_pulses = [p for p in self.res.pulses if abs(p.dfreq - 4.0) < 1.0]
        self.assertGreater(len(tag_pulses), 100)

    def test_ctt_tag_lines(self):
        self.assertTrue(all(t.port == "CTT" for t in self.res.tags))

    def test_bad_lines_are_counted_not_fatal(self):
        bad = self.dir / f"{sg_simulate.SERNO}-000009-2027-02-05T00-00-00.0000-all.txt"
        bad.write_text("p1,notanumber,0,0,0\nX,1,2\n\np2,1800000000.0,0.1,-60.0,-85.0\n")
        res = sg_files.parse([bad])
        self.assertEqual(res.skipped["p"], 1)
        self.assertEqual(res.unknown_types["X"], 1)
        self.assertEqual(len(res.pulses), 1)

    def test_unrecognised_filename_is_skipped(self):
        other = self.dir / "notes.txt"
        other.write_text("hello\n")
        res = sg_files.parse([other])
        self.assertEqual(res.skipped["unrecognised filename"], 1)
        self.assertEqual(res.files, [])


if __name__ == "__main__":
    unittest.main()

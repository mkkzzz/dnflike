"""Invariants for the offline level-60 parity baseline."""
from __future__ import annotations

import unittest

try:
    from .build_dnf_60_baseline import (
        LEVEL_CAP,
        build_baseline,
        render_report,
    )
except ImportError:
    from build_dnf_60_baseline import (
        LEVEL_CAP,
        build_baseline,
        render_report,
    )


class Dnf60BaselineTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest, cls.rules, cls.parity = build_baseline()

    def test_schema_and_scope(self):
        self.assertEqual(self.manifest["schema"], "dnf_60_target_manifest/1")
        self.assertEqual(self.manifest["scope"]["level_cap"], LEVEL_CAP)
        self.assertEqual(self.manifest["scope"]["server_process"], "excluded")
        self.assertEqual(self.manifest["scope"]["updater"], "excluded")
        self.assertEqual(self.rules["scope"]["local_authority_required"], True)

    def test_target_entries_respect_level_cap(self):
        for row in self.manifest["entries"]["skills"]:
            self.assertLessEqual(row["required_level"], LEVEL_CAP)
        for row in self.manifest["entries"]["dungeons"]:
            self.assertLessEqual(row["min_level"], LEVEL_CAP)
        for row in self.manifest["entries"]["quests"]:
            self.assertLessEqual(row["level_min"], LEVEL_CAP)
        for row in self.manifest["entries"]["monsters"]:
            self.assertLessEqual(row["level_min"], LEVEL_CAP)

    def test_item_buckets_cover_source_catalog(self):
        items = self.manifest["summary"]["items"]
        self.assertEqual(
            items["source"],
            items["target"] + items["post_60"] + items["unknown_level"],
        )

    def test_runtime_is_bounded_by_target(self):
        for key in ("characters", "skills", "dungeons", "quests", "items", "monsters"):
            summary = self.manifest["summary"][key]
            self.assertLessEqual(summary["runtime"], summary["target"])

    def test_parity_has_no_aggregate_percentage(self):
        self.assertFalse(self.parity["policy"]["aggregate_percentage"])
        self.assertEqual(len(self.parity["categories"]), 7)
        for row in self.parity["categories"].values():
            self.assertGreaterEqual(row.get("runtime", 0), 0)

    def test_offline_scope_and_blocking_rules_are_explicit(self):
        by_id = {row["id"]: row for row in self.rules["rules"]}
        self.assertEqual(by_id["scope.offline_single_player"]["status"], "implemented")
        self.assertEqual(by_id["scope.no_updater"]["status"], "fixed_scope")
        self.assertEqual(by_id["scope.above_60_future"]["status"], "fixed_scope")
        self.assertEqual(by_id["progression.fatigue"]["status"], "missing")
        self.assertTrue(by_id["progression.fatigue"]["blocks_target"])
        self.assertEqual(by_id["scope.party_pvp_social"]["status"], "excluded")

    def test_current_post_60_content_is_not_counted_as_target_runtime(self):
        self.assertGreater(self.manifest["summary"]["items"]["runtime_post_60"], 0)
        self.assertGreater(self.manifest["summary"]["dungeons"]["runtime_post_60"], 0)
        self.assertGreater(self.manifest["summary"]["monsters"]["runtime_post_60"], 0)

    def test_report_contains_baseline_sections(self):
        report = render_report(self.manifest, self.rules, self.parity)
        for heading in (
            "## 一、目标范围",
            "## 二、内容候选快照",
            "## 三、本地规则缺口",
            "## 四、待决策",
            "## 五、执行与复跑",
        ):
            self.assertIn(heading, report)
        self.assertIn("不做更新器", report)
        self.assertIn("服务端规则本地化", report)
        self.assertIn("保留为后续拓展", report)


if __name__ == "__main__":
    unittest.main()

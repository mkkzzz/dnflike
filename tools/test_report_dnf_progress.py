"""Data invariants for the generated engineering-progress snapshot."""
import unittest

try:
    from .report_dnf_progress import collect_snapshot, render_markdown
except ImportError:
    from report_dnf_progress import collect_snapshot, render_markdown


class DnfProgressReportTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.snapshot = collect_snapshot()

    def test_dungeon_totals_are_consistent(self):
        world = self.snapshot["world"]
        self.assertEqual(
            world["dungeon_entries"],
            world["playable_routes"] + world["legacy_routes"],
        )
        self.assertEqual(
            world["playable_routes"],
            world["selectable_routes"] + world["hidden_routes"],
        )
        self.assertEqual(
            world["playable_routes"],
            sum(world["level_bands"].values()) + len(world["level_unknown"]),
        )

    def test_quest_runtime_matches_catalog(self):
        quests = self.snapshot["quests"]
        self.assertEqual(quests["source_failed"], 0)
        self.assertEqual(
            quests["runtime_total"],
            quests["catalog_implemented"],
        )
        self.assertLessEqual(quests["epic_runtime"], quests["epic_total"])

    def test_item_kind_counts_sum_to_runtime_total(self):
        items = self.snapshot["items"]
        self.assertEqual(
            items["runtime_total"],
            sum(items["runtime_by_kind"].values()),
        )

    def test_skill_counts_are_bounded(self):
        skills = self.snapshot["skills"]
        self.assertGreater(skills["panel_total"], 0)
        self.assertLessEqual(skills["runtime_total"], skills["panel_total"])

    def test_markdown_has_separate_layers_and_sources(self):
        markdown = render_markdown(self.snapshot)
        for heading in (
            "## 一、总览",
            "## 二、世界与等级覆盖",
            "## 三、任务执行覆盖",
            "## 四、物品数据与功能缺口",
            "## 五、技能与怪物",
            "## 六、复跑",
        ):
            self.assertIn(heading, markdown)
        self.assertIn("不生成容易误导的总完成率", markdown)


if __name__ == "__main__":
    unittest.main()

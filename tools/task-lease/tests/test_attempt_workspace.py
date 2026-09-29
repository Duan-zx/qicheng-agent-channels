import json
import subprocess
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import attempt_workspace as workspace


class AttemptWorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.source = root / "source"
        self.worktrees = root / "worktrees"
        self.builds = root / "builds"
        for path in (self.source, self.worktrees, self.builds):
            path.mkdir()
        self.git("init", "-q")
        (self.source / "file.txt").write_text("source", encoding="utf-8")
        self.git("add", "file.txt")
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                 "commit", "-qm", "initial")

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.source), *args],
                                       text=True).strip()

    def prepare(self, task="task1", attempt="a1", **kwargs):
        return workspace.prepare(str(self.source), str(self.worktrees),
                                 str(self.builds), task, attempt, **kwargs)

    def test_two_attempts_concurrent_and_idempotent(self):
        script = Path(workspace.__file__)
        def launch(attempt):
            result = subprocess.run([sys.executable, "-B", str(script),
                "--source", str(self.source), "--worktree-root", str(self.worktrees),
                "--build-root", str(self.builds), "--task-id", "task1",
                "--attempt-id", attempt], text=True, capture_output=True)
            self.assertEqual(0, result.returncode, result.stderr)
            return json.loads(result.stdout)
        with ThreadPoolExecutor(max_workers=2) as pool:
            first, second = list(pool.map(launch, ("a1", "a2")))
        self.assertNotEqual(first["worktree"], second["worktree"])
        self.assertNotEqual(first["build_output"], second["build_output"])
        for result, content in ((first, "one"), (second, "two")):
            (Path(result["worktree"]) / "generated.txt").write_text(content)
            (Path(result["build_output"]) / "bundle.txt").write_text(content)
        self.assertEqual("one", (Path(first["worktree"]) / "generated.txt").read_text())
        self.assertEqual("two", (Path(second["worktree"]) / "generated.txt").read_text())
        self.assertEqual("source", (self.source / "file.txt").read_text())
        self.assertEqual("", self.git("status", "--porcelain"))
        self.assertEqual(first["worktree"], launch("a1")["worktree"])

    def test_conflict_and_unknown_user_files_are_preserved(self):
        first = self.prepare()
        (Path(first["build_output"]) / "my-file.txt").write_text("keep")
        (self.source / "file.txt").write_text("new source")
        self.git("add", "file.txt")
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                 "commit", "-qm", "second")
        with self.assertRaisesRegex(workspace.PreparationError, "conflicts"):
            self.prepare()
        self.assertEqual("keep", (Path(first["build_output"]) / "my-file.txt").read_text())
        occupied = self.worktrees / "task2" / "a1"
        occupied.mkdir(parents=True)
        (occupied / "user.txt").write_text("keep")
        with self.assertRaisesRegex(workspace.PreparationError, "without a complete"):
            self.prepare("task2")
        self.assertEqual("keep", (occupied / "user.txt").read_text())

    def test_rejects_escape_and_link(self):
        for identifier in ("../elsewhere", ".", "bad/name"):
            with self.assertRaises(workspace.PreparationError):
                self.prepare(attempt=identifier)
        linked = self.worktrees / "task1"
        try:
            linked.symlink_to(self.source, target_is_directory=True)
        except (OSError, NotImplementedError):
            return  # Windows developer mode may forbid symlink creation.
        with self.assertRaisesRegex(workspace.PreparationError, "link or junction"):
            self.prepare()

    def test_failure_after_git_add_removes_only_clean_new_worktree(self):
        original_mkdir = Path.mkdir
        # Production canonicalizes roots; Windows temp paths may use 8.3 aliases.
        target = self.builds.resolve() / "task1" / "a1"
        def fail_build(path, *args, **kwargs):
            if path == target:
                raise OSError("simulated build directory failure")
            return original_mkdir(path, *args, **kwargs)
        head = self.git("rev-parse", "HEAD")
        with patch.object(Path, "mkdir", fail_build):
            with self.assertRaisesRegex(OSError, "simulated"):
                self.prepare()
        self.assertFalse((self.worktrees / "task1" / "a1").exists())
        self.assertFalse(target.exists())
        self.assertEqual(head, self.git("rev-parse", "HEAD"))
        self.assertEqual("", self.git("status", "--porcelain"))
        self.assertNotIn(str(self.worktrees / "task1" / "a1"),
                         self.git("worktree", "list", "--porcelain"))


if __name__ == "__main__":
    unittest.main()

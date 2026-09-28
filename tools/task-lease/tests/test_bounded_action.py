import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from bounded_action import OUTPUT_LIMIT, run_action  # noqa: E402


class BoundedActionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)

    def run_python(self, source, timeout=2, env=None):
        return run_action([sys.executable, "-B", "-c", source], cwd=self.work,
                          env=env, timeout_seconds=timeout)

    def test_normal_output_fixed_cwd_and_env(self):
        env = os.environ.copy()
        env["BOUNDED_ACTION_TEST"] = "provided"
        result = self.run_python(
            "import os,sys; "
            "sys.stdout.write(os.getcwd()+'|'+os.environ['BOUNDED_ACTION_TEST']); "
            "sys.stderr.write('warning')", env=env)
        self.assertEqual(0, result.exit_code)
        self.assertFalse(result.timed_out)
        self.assertFalse(result.termination_uncertain)
        self.assertEqual((str(self.work) + "|provided").encode(), result.stdout)
        self.assertEqual(b"warning", result.stderr)

    def test_large_output_is_capped_independently(self):
        result = self.run_python(
            "import os; os.write(1,b'a'*200000); os.write(2,b'b'*200000)")
        self.assertEqual(0, result.exit_code)
        self.assertFalse(result.timed_out)
        self.assertEqual(b"a" * OUTPUT_LIMIT, result.stdout)
        self.assertEqual(b"b" * OUTPUT_LIMIT, result.stderr)
        self.assertTrue(result.stdout_truncated)
        self.assertTrue(result.stderr_truncated)

    def test_direct_process_timeout(self):
        start = time.monotonic()
        result = self.run_python("import time; print('ready',flush=True); time.sleep(30)",
                                 timeout=0.2)
        self.assertLess(time.monotonic() - start, 2)
        self.assertTrue(result.timed_out)
        self.assertEqual([b"ready"], result.stdout.splitlines())

    def test_inherited_pipes_do_not_block_after_parent_exits(self):
        marker = self.work / "child_finished"
        pid_file = self.work / "child.pid"
        child = ("import pathlib,time; time.sleep(1.1); "
                 f"pathlib.Path({str(marker)!r}).write_text('alive')")
        parent = ("import pathlib,subprocess,sys; "
                  f"p=subprocess.Popen([sys.executable,'-B','-c',{child!r}], "
                  "stdout=sys.stdout,stderr=sys.stderr); "
                  f"pathlib.Path({str(pid_file)!r}).write_text(str(p.pid))")
        try:
            start = time.monotonic()
            result = self.run_python(parent, timeout=0.4)
            self.assertLess(time.monotonic() - start, 2)
            self.assertTrue(result.timed_out)
            # The direct process can have exited normally while its child holds
            # the pipes; the action still has an indeterminate outcome.
            self.assertEqual(0, result.exit_code)
            time.sleep(1)
            self.assertFalse(marker.exists(), "descendant survived tree cleanup")
        finally:
            if pid_file.exists():
                pid = int(pid_file.read_text())
                if os.name == "nt":
                    subprocess.run(["taskkill", "/PID", str(pid), "/F"],
                                   stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, timeout=2, check=False)
                else:
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_normal_return_cleans_descendant_without_inherited_pipes(self):
        marker = self.work / "late_marker"
        child = ("import pathlib,time; time.sleep(0.7); "
                 f"pathlib.Path({str(marker)!r}).write_text('alive')")
        parent = ("import subprocess,sys; "
                  f"subprocess.Popen([sys.executable,'-B','-c',{child!r}], "
                  "stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)")
        result = self.run_python(parent)
        self.assertFalse(result.timed_out)
        self.assertEqual(0, result.exit_code)
        time.sleep(0.9)
        self.assertFalse(marker.exists(), "descendant survived normal cleanup")

    @unittest.skipUnless(os.name == "nt", "Windows Job assignment only")
    def test_job_assignment_failure_does_not_start_action(self):
        marker = self.work / "must_not_run"
        source = f"import pathlib; pathlib.Path({str(marker)!r}).touch()"
        with patch("bounded_action._WindowsJob", side_effect=OSError("job denied")):
            with self.assertRaises(OSError):
                self.run_python(source)
        self.assertFalse(marker.exists())

    @unittest.skipUnless(os.name == "nt", "Windows Job configuration only")
    def test_kill_on_close_configuration_failure_does_not_start_action(self):
        marker = self.work / "must_not_run"
        source = f"import pathlib; pathlib.Path({str(marker)!r}).touch()"
        with patch("bounded_action._WindowsJob._set_kill_on_close",
                   return_value=False):
            with self.assertRaisesRegex(OSError, "SetInformationJobObject"):
                self.run_python(source)
        self.assertFalse(marker.exists())

    @unittest.skipUnless(os.name == "nt", "Windows Job handle lifetime only")
    def test_parent_crash_closes_job_and_kills_descendant(self):
        marker = self.work / "survived_parent"
        pid_file = self.work / "crash_child.pid"
        child = ("import pathlib,time; time.sleep(1.5); "
                 f"pathlib.Path({str(marker)!r}).write_text('alive')")
        action = ("import pathlib,subprocess,sys; "
                  f"p=subprocess.Popen([sys.executable,'-B','-c',{child!r}], "
                  "stdout=sys.stdout,stderr=sys.stderr); "
                  f"pathlib.Path({str(pid_file)!r}).write_text(str(p.pid))")
        controller = (f"import sys; sys.path.insert(0,{str(Path(__file__).resolve().parents[1])!r}); "
                      "from bounded_action import run_action; "
                      f"run_action([sys.executable,'-B','-c',{action!r}], "
                      f"cwd={str(self.work)!r},env=None,timeout_seconds=5)")
        owner = subprocess.Popen([sys.executable, "-B", "-c", controller],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 3
            while not pid_file.exists() and time.monotonic() < deadline:
                self.assertIsNone(owner.poll(), "controller exited before action spawn")
                time.sleep(0.01)
            self.assertTrue(pid_file.exists(), "action never spawned descendant")
            owner.kill()
            owner.wait(timeout=2)
            time.sleep(1.7)
            self.assertFalse(marker.exists(), "Job descendants survived owner crash")
        finally:
            if owner.poll() is None:
                owner.kill()
                owner.wait(timeout=2)
            if pid_file.exists():
                subprocess.run(["taskkill", "/PID", pid_file.read_text(), "/F"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               timeout=2, check=False)

    def test_invalid_timeout_rejected(self):
        for value in (0, 9, float("nan"), True):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.run_python("pass", timeout=value)


if __name__ == "__main__":
    unittest.main()

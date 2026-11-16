import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


class AptFailFastTest(unittest.TestCase):
    def test_apt_errors_stop_the_dockerfile_run(self):
        dockerfile = (Path(__file__).resolve().parents[1] / "Dockerfile").read_text()
        blocks = re.findall(r"RUN <<EOF\n(.*?)\nEOF", dockerfile, re.DOTALL)
        script = next(block for block in blocks if "apt-get install" in block)

        for failing_command, expected_calls in (
            ("update", ["update"]),
            ("install", ["update", "install"]),
        ):
            with self.subTest(failing_command=failing_command):
                with tempfile.TemporaryDirectory() as temp:
                    temp_path = Path(temp)
                    calls = temp_path / "calls"
                    fake_apt = temp_path / "apt-get"
                    fake_apt.write_text(
                        '#!/bin/sh\n'
                        'printf "%s\\n" "$1" >> "$APT_CALLS"\n'
                        'if [ "$1" = "$FAIL_ON" ]; then exit 100; fi\n'
                        'exit 0\n'
                    )
                    fake_apt.chmod(0o755)
                    for name in ("rm", "sed"):
                        command = temp_path / name
                        command.write_text("#!/bin/sh\nexit 0\n")
                        command.chmod(0o755)

                    env = dict(
                        os.environ, PATH=temp, APT_CALLS=str(calls), FAIL_ON=failing_command
                    )
                    result = subprocess.run(
                        ["/bin/sh", "-c", script],
                        env=env,
                        capture_output=True,
                        text=True,
                    )

                    self.assertEqual(calls.read_text().splitlines(), expected_calls)
                    self.assertEqual(result.returncode, 100, result.stderr)


if __name__ == "__main__":
    unittest.main()

"""Exercise the actual updater helper only against disposable CI copies."""
import pathlib
import shutil
import subprocess
import tempfile
import time

with tempfile.TemporaryDirectory(prefix="Minutes-update-smoke-") as folder:
    root = pathlib.Path(folder)
    source = pathlib.Path("dist/Minutes.app").resolve()
    installed = root / "Minutes.app"
    staged = root / "staged" / "Minutes.app"
    shutil.copytree(source, installed, symlinks=True)
    shutil.copytree(source, staged, symlinks=True)
    notes = root / "notes.json"
    notes.write_text('{"notes":"must survive replacement"}')
    status = root / "result.txt"
    parent = subprocess.Popen(["/usr/bin/true"])
    parent.wait()
    subprocess.run([str(source / "Contents/Helpers/MinutesUpdateHelper"), str(parent.pid), str(staged), str(installed), str(status)], check=True, timeout=90)
    assert status.read_text().startswith("Minutes updated successfully"), status.read_text()
    assert notes.read_text() == '{"notes":"must survive replacement"}'
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(installed)], check=True)
    subprocess.run(["/usr/bin/pkill", "-TERM", "-x", "Minutes"], check=False)
    time.sleep(1)
    print("Updater smoke check passed: validated replacement, relaunch accepted, unrelated data preserved.")

"""The laptop fetches its own phrase and does not print it."""
import importlib.util
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("recovery_passphrase", HERE / "recovery_passphrase.py")
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)


def test_pull_writes_the_phrase_and_marks_it_filed(tmp_path):
    phrase = "b" * 48

    def get(mac):
        assert mac == "aa:bb:cc:dd:ee:01"
        return phrase + "\n"

    assert recovery.pull(tmp_path, ["aa:bb:cc:dd:ee:01"], get) is True
    assert recovery.read_phrase(tmp_path / "recovery-passphrase") == phrase
    assert (tmp_path / "recovery-filed").read_text() == "host\n"
    assert (tmp_path / "recovery-passphrase").stat().st_mode & 0o777 == 0o400


def test_pull_ignores_a_miss_and_a_short_body(tmp_path):
    def get(mac):
        if mac.endswith("01"):
            raise OSError("down")
        return "nope"

    assert recovery.pull(tmp_path, ["aa:bb:cc:dd:ee:01", "aa:bb:cc:dd:ee:02"], get) is False
    assert not (tmp_path / "recovery-passphrase").exists()


def test_push_stops_at_the_mac_the_host_accepts(tmp_path):
    seen = []

    def post(mac, phrase):
        seen.append(mac)
        return mac.endswith("02")

    assert recovery.push_phrase("c" * 48, ["aa:bb:cc:dd:ee:01", "aa:bb:cc:dd:ee:02"], post) is True
    assert seen == ["aa:bb:cc:dd:ee:01", "aa:bb:cc:dd:ee:02"]
    assert recovery.push_phrase("short", ["aa:bb:cc:dd:ee:01"], post) is False

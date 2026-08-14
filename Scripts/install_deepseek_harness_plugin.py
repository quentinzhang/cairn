#!/usr/bin/env python3
"""Install Cairn's prebuilt bundle into one DeepSeek Harness Web profile.

This installer never installs or upgrades Harness and never invokes npx. It
finds an existing dsh CLI (or a verified running source checkout), copies the
three-file Cairn bundle to a stable Application Support path, and asks the
official ``dsh plugin`` command to add or remove only that local bundle.

The on-disk profile and the live runtime marker are intentionally separate:
DeepSeek Harness does not hot-load profile additions/removals, so status can
say "restart to connect" and "restart to disconnect" without pretending a
disk edit changed an already-running process.
"""

from __future__ import annotations

import argparse
import errno
import json
import os
import re
import shutil
import subprocess
import sys
import uuid
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

from cairn_payload import payload_path

PLUGIN_NAME = "@cairn/deepseek-harness-plugin"
PLUGIN_VERSION = "0.1.0"
PROFILE_NAME = "web"
SUPPORTED_DSH_VERSIONS = {"0.1.0-rc.5", "0.1.0-rc.6"}

HOME = Path.home()
DEFAULT_DSH_HOME = HOME / ".dsh"
CAIRN_SUPPORT = HOME / "Library" / "Application Support" / "Cairn"
SOURCE = payload_path("DeepSeekHarnessPlugin")
STABLE_BUNDLE = CAIRN_SUPPORT / "DeepSeekHarnessPlugin"
SELECTION_FILE = CAIRN_SUPPORT / "deepseek-harness.json"
MARKER_FILENAME = "cairn-deepseek-harness.json"

PRIVATE_DIRECTORY_MODE = 0o700
PRIVATE_FILE_MODE = 0o600
_selected_home: Optional[Path] = None


class InstallerError(RuntimeError):
    """A safe, user-actionable refusal."""


def _read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise InstallerError(
            "invalid JSON at %s line %d: %s" % (path, error.lineno, error.msg)
        )
    except OSError as error:
        raise InstallerError("could not read %s: %s" % (path, error))


def _atomic_private_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=PRIVATE_DIRECTORY_MODE)
    os.chmod(path.parent, PRIVATE_DIRECTORY_MODE)
    temporary = path.with_name(".%s.%s.pending" % (path.name, uuid.uuid4().hex))
    descriptor = os.open(
        str(temporary), os.O_WRONLY | os.O_CREAT | os.O_EXCL, PRIVATE_FILE_MODE
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
        os.chmod(temporary, PRIVATE_FILE_MODE)
        os.replace(temporary, path)
        os.chmod(path, PRIVATE_FILE_MODE)
    except BaseException:
        try:
            temporary.unlink()
        except OSError:
            pass
        raise


def select_dsh_home(path: Path, persist: bool = False) -> Path:
    """Select an explicit DSH_HOME; optionally remember it for the Cairn GUI."""
    global _selected_home
    candidate = path.expanduser()
    if not candidate.is_absolute():
        raise InstallerError("DSH_HOME must be an absolute path")
    candidate = candidate.resolve()
    if not candidate.is_dir():
        raise InstallerError("DSH_HOME does not exist: %s" % candidate)
    _selected_home = candidate
    if persist:
        _atomic_private_json(SELECTION_FILE, {"dsh_home": str(candidate)})
    return candidate


def selected_dsh_home() -> Path:
    if _selected_home is not None:
        return _selected_home
    if SELECTION_FILE.is_file():
        value = _read_json(SELECTION_FILE)
        configured = value.get("dsh_home") if isinstance(value, dict) else None
        if not isinstance(configured, str) or not Path(configured).is_absolute():
            raise InstallerError("invalid saved DSH_HOME in %s" % SELECTION_FILE)
        candidate = Path(configured)
        if not candidate.is_dir():
            raise InstallerError("saved DSH_HOME no longer exists: %s" % candidate)
        return candidate.resolve()
    return DEFAULT_DSH_HOME


def profile_dir(dsh_home: Optional[Path] = None) -> Path:
    return (dsh_home or selected_dsh_home()) / "profiles" / PROFILE_NAME


def marker_path(dsh_home: Optional[Path] = None) -> Path:
    return (dsh_home or selected_dsh_home()) / "runtime" / MARKER_FILENAME


def _command_output(command: Sequence[str], timeout: int = 12) -> Tuple[int, str]:
    try:
        finished = subprocess.run(
            list(command), capture_output=True, text=True, timeout=timeout, check=False
        )
        output = (finished.stdout + finished.stderr).strip()
        return finished.returncode, output
    except (OSError, subprocess.SubprocessError) as error:
        return 127, str(error)


def _version_from_command(command: Sequence[str]) -> str:
    code, output = _command_output([*command, "--version"])
    if code != 0:
        return ""
    match = re.search(r"(?:^|\s)(\d+\.\d+\.\d+-rc\.\d+)(?:\s|$)", output)
    return match.group(1) if match else ""


def _valid_source_checkout(root: Path) -> bool:
    try:
        root_manifest = json.loads((root / "package.json").read_text(encoding="utf-8"))
        cli_manifest = json.loads(
            (root / "apps" / "cli" / "package.json").read_text(encoding="utf-8")
        )
    except (OSError, json.JSONDecodeError):
        return False
    return (
        root_manifest.get("name") == "@deepseek-ai/dsh-root"
        and cli_manifest.get("name") == "@deepseek-ai/dsh"
        and isinstance(cli_manifest.get("version"), str)
        and (root / "pnpm-lock.yaml").is_file()
    )


def _process_rows() -> List[Tuple[int, str]]:
    code, output = _command_output(["/bin/ps", "-axo", "pid=,command="])
    if code != 0:
        return []
    rows: List[Tuple[int, str]] = []
    for line in output.splitlines():
        match = re.match(r"\s*(\d+)\s+(.*)$", line)
        if not match:
            continue
        command = match.group(2)
        source_entry = "/deepseek-harness/apps/cli/" in command
        pnpm_dsh = bool(re.search(r"(?:^|/)pnpm(?:\.cjs)?\s+(?:--dir\s+\S+\s+)?dsh(?:\s|$)", command))
        if source_entry or pnpm_dsh:
            rows.append((int(match.group(1)), command))
    return rows


def _process_cwd(pid: int) -> Optional[Path]:
    lsof = shutil.which("lsof") or "/usr/sbin/lsof"
    code, output = _command_output([lsof, "-a", "-p", str(pid), "-d", "cwd", "-Fn"])
    if code != 0:
        return None
    for line in output.splitlines():
        if line.startswith("n/"):
            return Path(line[1:])
    return None


def discover_source_checkout() -> Optional[Path]:
    """Find a running source dsh by PID and cwd, without reading its environment."""
    for pid, _command in _process_rows():
        cwd = _process_cwd(pid)
        if cwd is not None and _valid_source_checkout(cwd):
            return cwd.resolve()
    return None


def discover_cli() -> Optional[Dict[str, Any]]:
    executable = shutil.which("dsh")
    if executable:
        command = [executable]
        return {
            "kind": "global",
            "command": command,
            "version": _version_from_command(command),
        }

    checkout = discover_source_checkout()
    pnpm = shutil.which("pnpm")
    if checkout is None or pnpm is None:
        return None
    command = [pnpm, "--dir", str(checkout), "dsh"]
    try:
        version = json.loads(
            (checkout / "apps" / "cli" / "package.json").read_text(encoding="utf-8")
        ).get("version", "")
    except (OSError, json.JSONDecodeError):
        version = ""
    return {
        "kind": "source",
        "command": command,
        "version": version if isinstance(version, str) else "",
        "checkout": str(checkout),
    }


def supported_version(version: str) -> bool:
    return version in SUPPORTED_DSH_VERSIONS


def _profile_manifest(dsh_home: Path) -> Optional[Dict[str, Any]]:
    path = profile_dir(dsh_home) / "package.json"
    if not path.exists():
        return None
    value = _read_json(path)
    if not isinstance(value, dict):
        raise InstallerError("profile manifest must be a JSON object: %s" % path)
    dsh = value.get("dsh")
    profile = dsh.get("profile") if isinstance(dsh, dict) else None
    bundles = profile.get("bundles") if isinstance(profile, dict) else None
    dependencies = value.get("dependencies", {})
    if not isinstance(bundles, list) or not all(isinstance(item, str) for item in bundles):
        raise InstallerError("profile manifest has invalid dsh.profile.bundles: %s" % path)
    if not isinstance(dependencies, dict) or not all(
        isinstance(key, str) and isinstance(item, str)
        for key, item in dependencies.items()
    ):
        raise InstallerError("profile manifest has invalid dependencies: %s" % path)
    return value


def _dependency_target(spec: str, directory: Path) -> Optional[Path]:
    match = re.match(r"^(?:link|file):(.*)$", spec)
    if not match:
        return None
    raw = Path(match.group(1)).expanduser()
    return (raw if raw.is_absolute() else directory / raw).resolve()


def _installed_package_path(directory: Path) -> Path:
    return directory / "node_modules" / "@cairn" / "deepseek-harness-plugin"


def inspect_profile(dsh_home: Optional[Path] = None) -> Dict[str, Any]:
    home = dsh_home or selected_dsh_home()
    directory = profile_dir(home)
    manifest = _profile_manifest(home)
    if manifest is None:
        return {
            "exists": False,
            "profile_on": False,
            "dependency_on": False,
            "ownership": "none",
            "manifest": None,
        }

    bundles = manifest["dsh"]["profile"]["bundles"]
    dependencies = manifest.get("dependencies", {})
    profile_on = PLUGIN_NAME in bundles
    dependency_on = PLUGIN_NAME in dependencies
    ownership = "none"
    dependency_target = None
    if dependency_on:
        dependency_target = _dependency_target(dependencies[PLUGIN_NAME], directory)
        if dependency_target == STABLE_BUNDLE.resolve():
            ownership = "ours"
        else:
            installed = _installed_package_path(directory)
            try:
                if installed.resolve(strict=True) == STABLE_BUNDLE.resolve():
                    ownership = "ours"
                else:
                    ownership = "foreign"
            except OSError:
                ownership = "foreign"
    elif profile_on:
        ownership = "foreign"

    return {
        "exists": True,
        "profile_on": profile_on,
        "dependency_on": dependency_on,
        "ownership": ownership,
        "dependency_target": str(dependency_target) if dependency_target else "",
        "manifest": manifest,
    }


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except PermissionError:
        return True
    except ProcessLookupError:
        return False
    except OSError as error:
        return error.errno == errno.EPERM


def live_marker(dsh_home: Optional[Path] = None) -> Optional[Dict[str, Any]]:
    path = marker_path(dsh_home)
    if not path.is_file():
        return None
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(value, dict) or value.get("plugin") != PLUGIN_NAME:
        return None
    pid = value.get("pid")
    port = value.get("port")
    owner = value.get("owner")
    if (
        not isinstance(pid, int)
        or pid <= 0
        or not isinstance(port, int)
        or port <= 0
        or not isinstance(owner, str)
        or not owner
        or not _pid_alive(pid)
    ):
        return None
    return value


def status(dsh_home: Optional[Path] = None) -> Dict[str, Any]:
    home = dsh_home or selected_dsh_home()
    try:
        profile = inspect_profile(home)
    except InstallerError as error:
        return {
            "state": "attention",
            "issue": "config_invalid",
            "message": str(error),
            "consent": True,
            "follow_up": None,
            "dsh_home": str(home),
        }
    marker = live_marker(home)
    cli = discover_cli()

    if profile["ownership"] == "foreign":
        return {
            "state": "attention",
            "issue": "foreign_plugin",
            "message": str(profile_dir(home) / "package.json"),
            "consent": not profile["profile_on"],
            "follow_up": None,
            "dsh_home": str(home),
        }
    if profile["profile_on"] != profile["dependency_on"]:
        return {
            "state": "attention",
            "issue": "partial",
            "message": str(profile_dir(home) / "package.json"),
            "consent": not profile["profile_on"],
            "follow_up": None,
            "dsh_home": str(home),
        }
    if cli is None:
        if not profile["exists"] and marker is None:
            state, issue = "not_installed", None
        else:
            state, issue = "attention", "cli_missing"
        return {
            "state": state,
            "issue": issue,
            "message": None,
            "consent": not profile["profile_on"],
            "follow_up": None,
            "dsh_home": str(home),
        }

    version = str(cli.get("version") or "")
    if not supported_version(version):
        return {
            "state": "attention",
            "issue": "unsupported_version",
            "message": version or "unknown",
            "consent": not profile["profile_on"],
            "follow_up": None,
            "dsh_home": str(home),
        }

    if profile["profile_on"] and marker is not None:
        state, follow_up = "connected", None
    elif profile["profile_on"]:
        state, follow_up = "restart_to_connect", "deepseek_harness_restart"
    elif marker is not None:
        state, follow_up = "restart_to_disconnect", "deepseek_harness_restart"
    else:
        state, follow_up = "available", None
    return {
        "state": state,
        "issue": None,
        "message": None,
        "consent": not profile["profile_on"],
        "follow_up": follow_up,
        "dsh_home": str(home),
        "version": version,
        "cli_kind": cli["kind"],
        "port": marker.get("port") if marker else None,
    }


def _validate_source_bundle() -> Dict[str, Any]:
    manifest_path = SOURCE / "package.json"
    patch_path = SOURCE / "cordis.patch.yml"
    entry_path = SOURCE / "index.js"
    if not (manifest_path.is_file() and patch_path.is_file() and entry_path.is_file()):
        raise InstallerError("missing DeepSeek Harness plugin payload: %s" % SOURCE)
    manifest = _read_json(manifest_path)
    if not isinstance(manifest, dict) or manifest.get("name") != PLUGIN_NAME:
        raise InstallerError("unexpected plugin manifest at %s" % manifest_path)
    scripts = manifest.get("scripts", {})
    if scripts:
        raise InstallerError("bundled plugin must not declare install or build scripts")
    patch = manifest.get("dsh", {}).get("bundle", {}).get("patch")
    if patch != "./cordis.patch.yml":
        raise InstallerError("bundled plugin has no dsh.bundle.patch declaration")
    return manifest


def _private_tree(path: Path) -> None:
    for directory, directories, files in os.walk(path):
        os.chmod(directory, PRIVATE_DIRECTORY_MODE)
        for name in directories:
            os.chmod(Path(directory) / name, PRIVATE_DIRECTORY_MODE)
        for name in files:
            os.chmod(Path(directory) / name, PRIVATE_FILE_MODE)


def stage_stable_bundle() -> Path:
    """Atomically replace only Cairn's owned stable bundle directory."""
    _validate_source_bundle()
    CAIRN_SUPPORT.mkdir(parents=True, exist_ok=True, mode=PRIVATE_DIRECTORY_MODE)
    os.chmod(CAIRN_SUPPORT, PRIVATE_DIRECTORY_MODE)

    if STABLE_BUNDLE.exists():
        try:
            existing = _read_json(STABLE_BUNDLE / "package.json")
        except InstallerError:
            raise InstallerError("refusing to replace unrecognized path: %s" % STABLE_BUNDLE)
        if not isinstance(existing, dict) or existing.get("name") != PLUGIN_NAME:
            raise InstallerError("refusing to replace unrecognized path: %s" % STABLE_BUNDLE)

    staged = CAIRN_SUPPORT / (".DeepSeekHarnessPlugin.%s.pending" % uuid.uuid4().hex)
    backup = CAIRN_SUPPORT / (".DeepSeekHarnessPlugin.%s.backup" % uuid.uuid4().hex)
    staged.mkdir(mode=PRIVATE_DIRECTORY_MODE)
    try:
        for name in ("package.json", "cordis.patch.yml", "index.js"):
            shutil.copy2(SOURCE / name, staged / name)
        _private_tree(staged)
        had_existing = STABLE_BUNDLE.exists()
        if had_existing:
            os.replace(STABLE_BUNDLE, backup)
        try:
            os.replace(staged, STABLE_BUNDLE)
        except BaseException:
            if had_existing and backup.exists() and not STABLE_BUNDLE.exists():
                os.replace(backup, STABLE_BUNDLE)
            raise
        if backup.exists():
            shutil.rmtree(backup)
        return STABLE_BUNDLE
    finally:
        if staged.exists():
            shutil.rmtree(staged, ignore_errors=True)
        if backup.exists() and STABLE_BUNDLE.exists():
            shutil.rmtree(backup, ignore_errors=True)


class _ProfileSnapshot:
    FILENAMES = ("package.json", "pnpm-lock.yaml", "pnpm-workspace.yaml")

    def __init__(self, directory: Path) -> None:
        self.directory = directory
        self.values: Dict[str, Optional[bytes]] = {}
        for name in self.FILENAMES:
            path = directory / name
            self.values[name] = path.read_bytes() if path.is_file() else None

    def restore(self) -> None:
        self.directory.mkdir(parents=True, exist_ok=True)
        for name, value in self.values.items():
            path = self.directory / name
            if value is None:
                try:
                    path.unlink()
                except FileNotFoundError:
                    pass
            else:
                temporary = path.with_name(".%s.%s.restore" % (name, uuid.uuid4().hex))
                temporary.write_bytes(value)
                os.replace(temporary, path)


def _run_plugin_command(
    cli: Dict[str, Any], home: Path, arguments: Sequence[str], snapshot: _ProfileSnapshot
) -> None:
    environment = dict(os.environ)
    environment["DSH_HOME"] = str(home)
    command = [*cli["command"], "plugin", "--profile", PROFILE_NAME, *arguments]
    try:
        finished = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=120,
            env=environment,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as error:
        snapshot.restore()
        raise InstallerError("DeepSeek Harness plugin command failed: %s" % error)
    if finished.returncode != 0:
        snapshot.restore()
        detail = (finished.stderr or finished.stdout).strip()
        raise InstallerError(
            "DeepSeek Harness plugin command failed%s"
            % ((": " + detail[-800:]) if detail else "")
        )


def install(dsh_home: Optional[Path] = None) -> Dict[str, Any]:
    home = dsh_home or selected_dsh_home()
    cli = discover_cli()
    if cli is None:
        raise InstallerError("DeepSeek Harness CLI not found")
    version = str(cli.get("version") or "")
    if not supported_version(version):
        raise InstallerError("unsupported DeepSeek Harness version: %s" % (version or "unknown"))

    before = inspect_profile(home)
    if before["ownership"] == "foreign":
        raise InstallerError("refusing to replace external bundle named %s" % PLUGIN_NAME)
    stage_stable_bundle()
    if before["profile_on"] and before["dependency_on"]:
        return status(home)

    directory = profile_dir(home)
    snapshot = _ProfileSnapshot(directory)
    _run_plugin_command(cli, home, ["add", "link:%s" % STABLE_BUNDLE], snapshot)
    after = inspect_profile(home)
    if not (
        after["profile_on"]
        and after["dependency_on"]
        and after["ownership"] == "ours"
    ):
        snapshot.restore()
        raise InstallerError("dsh reported success but did not install Cairn's bundle")
    return status(home)


def uninstall(dsh_home: Optional[Path] = None) -> Dict[str, Any]:
    home = dsh_home or selected_dsh_home()
    before = inspect_profile(home)
    if before["ownership"] == "foreign":
        raise InstallerError("refusing to remove external bundle named %s" % PLUGIN_NAME)
    if not before["profile_on"] and not before["dependency_on"]:
        return status(home)

    cli = discover_cli()
    if cli is None:
        raise InstallerError("DeepSeek Harness CLI not found; profile was not changed")
    directory = profile_dir(home)
    snapshot = _ProfileSnapshot(directory)
    _run_plugin_command(cli, home, ["remove", PLUGIN_NAME], snapshot)
    after = inspect_profile(home)
    if after["profile_on"] or after["dependency_on"]:
        snapshot.restore()
        raise InstallerError("dsh reported success but did not remove Cairn's bundle")
    return status(home)


def main() -> int:
    parser = argparse.ArgumentParser(description="Manage Cairn's DeepSeek Harness bundle")
    parser.add_argument("action", choices=("status", "install", "uninstall"))
    parser.add_argument("--dsh-home", type=Path, help="explicit existing DSH_HOME")
    parser.add_argument("--json", action="store_true")
    arguments = parser.parse_args()
    try:
        home = (
            select_dsh_home(arguments.dsh_home, persist=arguments.action != "status")
            if arguments.dsh_home
            else selected_dsh_home()
        )
        if arguments.action == "install":
            payload = install(home)
        elif arguments.action == "uninstall":
            payload = uninstall(home)
        else:
            payload = status(home)
        ok = True
    except InstallerError as error:
        payload = {"state": "attention", "issue": None, "message": str(error)}
        ok = False
    if arguments.json:
        print(json.dumps(payload, ensure_ascii=False))
    else:
        print(payload.get("message") or payload["state"])
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())

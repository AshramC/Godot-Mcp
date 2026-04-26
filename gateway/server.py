from __future__ import annotations

import argparse
import asyncio
from collections import deque
import json
import os
from pathlib import Path
import platform
import re
import shutil
import socket
import time
import uuid
from typing import Any

import websockets
from fastmcp import FastMCP
from fastmcp.exceptions import ToolError
from fastmcp.server.providers import Provider
from fastmcp.tools import Tool, ToolResult


DEFAULT_BRIDGE_URL = "ws://127.0.0.1:3000/bridge"
DEFAULT_GATEWAY_HOST = "127.0.0.1"
DEFAULT_GATEWAY_PORT = 3001
DEFAULT_BRIDGE_TOKEN_FILE = ".bridge_token"
DEFAULT_ENDPOINT_FILE = ".gateway_endpoint.json"
DEFAULT_RUNTIME_BUFFER_LINES = 2000
DEFAULT_TEST_TIMEOUT_SECONDS = 30.0
DEFAULT_OUTPUT_TAIL_LINES = 120

BRIDGE_TOOL_ACTIONS: dict[str, list[str]] = {
    "godot_scene": [
        "get_current",
        "open",
        "save",
        "save_as",
        "create",
        "close",
        "reload",
        "tree",
        "selection",
        "select",
        "play_main",
        "play_current",
        "play_custom",
        "stop_playing",
    ],
    "godot_node": [
        "find",
        "info",
        "children",
        "create",
        "delete",
        "duplicate",
        "instantiate",
        "reparent",
        "reorder",
        "get_property",
        "set_property",
        "list_properties",
        "transform",
        "visibility",
    ],
    "godot_script": [
        "create",
        "read",
        "write",
        "info",
        "attach",
        "detach",
        "open",
        "open_at_line",
        "list_open",
    ],
    "godot_resource": [
        "list",
        "search",
        "info",
        "dependencies",
        "create",
        "copy",
        "move",
        "delete",
        "reload",
        "uid",
        "refresh_uids",
        "assign_texture",
    ],
    "godot_project": [
        "info",
        "get_setting",
        "set_setting",
        "list_settings",
        "input_list",
        "input_add",
        "input_remove",
        "autoload_list",
        "autoload_add",
        "autoload_remove",
    ],
    "godot_editor": [
        "status",
        "main_screen",
        "set_main_screen",
        "filesystem_scan",
        "filesystem_reimport",
        "select_file",
        "selected_files",
        "inspect_node",
        "inspect_resource",
        "classdb",
    ],
    "godot_debug": [
        "sessions",
        "set_breakpoint",
        "send_message",
        "captured_messages",
        "clear_messages",
    ],
    "godot_view": ["capture_editor_viewport"],
}

BRIDGE_TOOL_DESCRIPTIONS: dict[str, str] = {
    "godot_scene": "Bridge-backed scene editing and playback. Use action to choose the operation.",
    "godot_node": "Bridge-backed node lookup and scene tree editing.",
    "godot_script": "Bridge-backed GDScript file management, node attachment, and editor opening.",
    "godot_resource": "Bridge-backed resource lookup, creation, movement, UID refresh, and texture assignment.",
    "godot_project": "Bridge-backed project settings, input action, and autoload management.",
    "godot_editor": "Bridge-backed editor state, filesystem refresh, inspector, and ClassDB access.",
    "godot_debug": "Bridge-backed debugger sessions, breakpoints, and captured debug messages.",
    "godot_view": "Bridge-backed editor 2D/3D viewport screenshot capture.",
}


def make_bridge_tool_definitions(available_names: set[str] | None = None) -> list[dict[str, Any]]:
    definitions: list[dict[str, Any]] = []
    for name, actions in BRIDGE_TOOL_ACTIONS.items():
        if available_names is not None and name not in available_names:
            continue
        definitions.append(
            {
                "name": name,
                "description": (
                    f"{BRIDGE_TOOL_DESCRIPTIONS[name]} Actions: {', '.join(actions)}. "
                    "Call project_environment first and godot_bridge_health before using this tool. "
                    "Connect agents to the Gateway endpoint, never directly to the Godot Bridge."
                ),
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "action": {
                            "type": "string",
                            "enum": actions,
                            "description": "Operation to perform.",
                        }
                    },
                    "required": ["action"],
                },
            }
        )
    return definitions


class GodotBridgeError(RuntimeError):
    """Raised when the Godot editor bridge cannot complete a request."""


class GodotHostError(RuntimeError):
    """Raised when host-side Godot operations cannot complete."""


def is_bridge_auth_error(error: BaseException) -> bool:
    message = str(error).lower()
    return "unauthorized" in message or "rejected the gateway token" in message


def bridge_auth_hint() -> str:
    return (
        "Godot Bridge authentication failed. Start the Gateway with "
        "--project pointing at the target Godot project. The Gateway will read "
        ".bridge_token and write .gateway_endpoint.json from that project. "
        "If the project token is missing, open the project in Godot with the "
        "Godot Bridge plugin enabled so it can generate one. "
        "Advanced users can still pass --bridge-token-file or "
        "GODOT_MCP_BRIDGE_TOKEN explicitly."
    )


def read_text_file_if_exists(path: str | None) -> str | None:
    if not path:
        return None
    token_path = Path(path).expanduser()
    if not token_path.is_file():
        return None
    content = token_path.read_text(encoding="utf-8").strip()
    return content or None


class GodotRuntimeProcess:
    def __init__(
        self,
        process: asyncio.subprocess.Process,
        project_path: str,
        scene: str | None,
        max_lines: int,
    ) -> None:
        self.process = process
        self.project_path = project_path
        self.scene = scene
        self.started_at = time.time()
        self.stdout: deque[str] = deque(maxlen=max_lines)
        self.stderr: deque[str] = deque(maxlen=max_lines)
        self._reader_tasks: list[asyncio.Task[None]] = []

    def add_reader_task(self, task: asyncio.Task[None]) -> None:
        self._reader_tasks.append(task)

    async def close(self) -> None:
        if self.process.returncode is None:
            self.process.terminate()
            try:
                await asyncio.wait_for(self.process.wait(), timeout=5)
            except asyncio.TimeoutError:
                self.process.kill()
                await self.process.wait()

        if self._reader_tasks:
            await asyncio.gather(*self._reader_tasks, return_exceptions=True)

    def status(self) -> dict[str, Any]:
        return {
            "running": self.process.returncode is None,
            "returncode": self.process.returncode,
            "pid": self.process.pid,
            "project_path": self.project_path,
            "scene": self.scene,
            "started_at": self.started_at,
            "uptime_seconds": max(0.0, time.time() - self.started_at),
        }


class GodotOutputAnalyzer:
    ERROR_MARKERS = (
        "SCRIPT ERROR:",
        "ERROR:",
        "Parse Error:",
        "Invalid call",
        "Invalid get index",
        "Cannot call method",
        "Resource file not found",
        "Failed loading resource",
        "Node not found",
    )
    WARNING_MARKERS = ("WARNING:", "WARN:")

    LOCATION_PATTERNS = (
        re.compile(r"\((res://[^:()]+):(\d+)\)"),
        re.compile(r"\b(res://\S+):(\d+)\b"),
    )
    AT_PATTERN = re.compile(r"\bat:\s*(?:(?P<function>[^\s(]+)\s*)?\((?P<file>res://[^:()]+):(?P<line>\d+)\)")

    def analyze(
        self,
        stdout: str | list[str] | None = None,
        stderr: str | list[str] | None = None,
        project_path: str | None = None,
    ) -> dict[str, Any]:
        output_lines = self._coerce_lines(stdout)
        error_lines = self._coerce_lines(stderr)
        issues: list[dict[str, Any]] = []

        self._scan_lines(output_lines, "stdout", issues)
        self._scan_lines(error_lines, "stderr", issues)

        error_count = sum(1 for issue in issues if issue["severity"] == "error")
        warning_count = sum(1 for issue in issues if issue["severity"] == "warning")
        summary_parts = []
        if error_count:
            summary_parts.append(f"{error_count} error{'s' if error_count != 1 else ''}")
        if warning_count:
            summary_parts.append(f"{warning_count} warning{'s' if warning_count != 1 else ''}")
        summary = ", ".join(summary_parts) if summary_parts else "No Godot errors or warnings detected."

        return {
            "has_errors": error_count > 0,
            "has_warnings": warning_count > 0,
            "error_count": error_count,
            "warning_count": warning_count,
            "issues": issues,
            "summary": summary,
            "project_path": project_path,
        }

    def _coerce_lines(self, value: str | list[str] | None) -> list[str]:
        if value is None:
            return []
        if isinstance(value, list):
            return [str(item) for item in value]
        return str(value).splitlines()

    def _scan_lines(self, lines: list[str], source: str, issues: list[dict[str, Any]]) -> None:
        for line in lines:
            stripped = line.strip()
            if not stripped:
                continue

            at_match = self.AT_PATTERN.search(stripped)
            if at_match and issues:
                issue = issues[-1]
                issue.setdefault("file", at_match.group("file"))
                issue.setdefault("line", int(at_match.group("line")))
                if at_match.group("function"):
                    issue.setdefault("function", at_match.group("function"))
                continue

            severity = self._severity_for_line(stripped, source)
            if not severity:
                continue

            file_path, line_number = self._extract_location(stripped)
            issue: dict[str, Any] = {
                "severity": severity,
                "kind": self._kind_for_line(stripped),
                "message": self._clean_message(stripped),
                "source": source,
                "raw": line,
            }
            if file_path:
                issue["file"] = file_path
            if line_number is not None:
                issue["line"] = line_number
            issues.append(issue)

    def _severity_for_line(self, line: str, source: str) -> str | None:
        if any(marker in line for marker in self.ERROR_MARKERS):
            return "error"
        if any(marker in line for marker in self.WARNING_MARKERS):
            return "warning"
        if source == "stderr" and line.startswith(("E ", "ERROR ")):
            return "error"
        return None

    def _kind_for_line(self, line: str) -> str:
        if "SCRIPT ERROR:" in line:
            return "script_error"
        if "Parse Error:" in line:
            return "parse_error"
        if "Resource file not found" in line or "Failed loading resource" in line:
            return "resource_error"
        if "Invalid call" in line or "Cannot call method" in line:
            return "api_error"
        if "Node not found" in line:
            return "node_reference_error"
        if "WARNING:" in line or "WARN:" in line:
            return "warning"
        return "godot_error"

    def _clean_message(self, line: str) -> str:
        for prefix in ("SCRIPT ERROR:", "ERROR:", "WARNING:", "WARN:"):
            if line.startswith(prefix):
                return line.removeprefix(prefix).strip()
        return line

    def _extract_location(self, line: str) -> tuple[str | None, int | None]:
        for pattern in self.LOCATION_PATTERNS:
            match = pattern.search(line)
            if match:
                return match.group(1), int(match.group(2))
        return None, None


class GodotHostManager:
    def __init__(
        self,
        godot_path: str | None = None,
        runtime_buffer_lines: int = DEFAULT_RUNTIME_BUFFER_LINES,
    ) -> None:
        self._configured_godot_path = godot_path
        self._detected_godot_path: str | None = None
        self._runtime_buffer_lines = runtime_buffer_lines
        self._active_runtime: GodotRuntimeProcess | None = None
        self._analyzer = GodotOutputAnalyzer()

    def _candidate_paths(self) -> list[str]:
        candidates: list[str] = []
        if self._configured_godot_path:
            candidates.append(self._configured_godot_path)

        env_path = os.getenv("GODOT_PATH")
        if env_path:
            candidates.append(env_path)

        for executable in ("godot", "godot4"):
            resolved = shutil.which(executable)
            if resolved:
                candidates.append(resolved)

        home = Path.home()
        system = platform.system().lower()
        if system == "darwin":
            candidates.extend(
                [
                    "/Applications/Godot.app/Contents/MacOS/Godot",
                    "/Applications/Godot_4.app/Contents/MacOS/Godot",
                    str(home / "Applications/Godot.app/Contents/MacOS/Godot"),
                    str(home / "Applications/Godot_4.app/Contents/MacOS/Godot"),
                    str(
                        home
                        / "Library/Application Support/Steam/steamapps/common/Godot Engine/Godot.app/Contents/MacOS/Godot"
                    ),
                ]
            )
        elif system == "windows":
            candidates.extend(
                [
                    r"C:\Program Files\Godot\Godot.exe",
                    r"C:\Program Files (x86)\Godot\Godot.exe",
                    r"C:\Program Files\Godot_4\Godot.exe",
                    r"C:\Program Files (x86)\Godot_4\Godot.exe",
                    str(home / "Godot/Godot.exe"),
                ]
            )
        else:
            candidates.extend(
                [
                    "/usr/bin/godot",
                    "/usr/local/bin/godot",
                    "/snap/bin/godot",
                    str(home / ".local/bin/godot"),
                ]
            )

        seen: set[str] = set()
        unique: list[str] = []
        for candidate in candidates:
            expanded = str(Path(candidate).expanduser())
            if expanded not in seen:
                seen.add(expanded)
                unique.append(expanded)
        return unique

    async def _run_version(self, executable: str, timeout: float = 8.0) -> str:
        try:
            process = await asyncio.create_subprocess_exec(
                executable,
                "--version",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout, stderr = await asyncio.wait_for(process.communicate(), timeout=timeout)
        except FileNotFoundError as exc:
            raise GodotHostError(f"Godot executable not found: {executable}") from exc
        except PermissionError as exc:
            raise GodotHostError(f"Godot executable is not runnable: {executable}") from exc
        except asyncio.TimeoutError as exc:
            raise GodotHostError(f"Timed out checking Godot executable: {executable}") from exc

        if process.returncode != 0:
            error = stderr.decode(errors="replace").strip()
            raise GodotHostError(error or f"Godot returned exit code {process.returncode}.")
        return stdout.decode(errors="replace").strip()

    async def detect_godot(self, force: bool = False) -> dict[str, Any]:
        if self._detected_godot_path and not force:
            version = await self._run_version(self._detected_godot_path)
            return {
                "path": self._detected_godot_path,
                "version": version,
                "cached": True,
            }

        errors: list[dict[str, str]] = []
        for candidate in self._candidate_paths():
            if not Path(candidate).exists() and os.path.sep in candidate:
                errors.append({"path": candidate, "error": "not found"})
                continue

            try:
                version = await self._run_version(candidate)
            except GodotHostError as exc:
                errors.append({"path": candidate, "error": str(exc)})
                continue

            self._detected_godot_path = candidate
            return {
                "path": candidate,
                "version": version,
                "cached": False,
                "checked": len(errors) + 1,
            }

        raise GodotHostError(
            "Could not find a runnable Godot executable. Set --godot-path or GODOT_PATH."
        )

    async def get_godot_path(self) -> str:
        detected = await self.detect_godot()
        return str(detected["path"])

    async def get_godot_version(self) -> dict[str, Any]:
        detected = await self.detect_godot()
        return {
            "path": detected["path"],
            "version": detected["version"],
        }

    def resolve_project_path(self, project_path: str | None) -> Path:
        if not project_path:
            raise GodotHostError("project_path is required.")

        path = Path(project_path).expanduser()
        if not path.is_absolute():
            path = Path.cwd() / path
        path = path.resolve()

        if not path.is_dir():
            raise GodotHostError(f"Project path is not a directory: {path}")
        if not (path / "project.godot").is_file():
            raise GodotHostError(f"Not a Godot project: {path}")
        return path

    def list_projects(self, directory: str | None, recursive: bool = False) -> dict[str, Any]:
        if not directory:
            raise GodotHostError("directory is required.")

        root = Path(directory).expanduser()
        if not root.is_absolute():
            root = Path.cwd() / root
        root = root.resolve()
        if not root.is_dir():
            raise GodotHostError(f"Directory does not exist: {root}")

        projects: list[dict[str, str]] = []
        if (root / "project.godot").is_file():
            projects.append({"name": root.name, "path": str(root)})

        if recursive:
            walker = os.walk(root)
        else:
            walker = ((str(root), [entry.name for entry in root.iterdir() if entry.is_dir()], []),)

        for current, dirs, _files in walker:
            dirs[:] = [
                name
                for name in dirs
                if not name.startswith(".") and name not in {"node_modules", ".godot"}
            ]
            for dirname in list(dirs):
                candidate = Path(current) / dirname
                if (candidate / "project.godot").is_file():
                    projects.append({"name": candidate.name, "path": str(candidate.resolve())})
                    if recursive:
                        dirs.remove(dirname)

        unique: dict[str, dict[str, str]] = {project["path"]: project for project in projects}
        return {
            "directory": str(root),
            "recursive": recursive,
            "count": len(unique),
            "projects": sorted(unique.values(), key=lambda item: item["path"]),
        }

    async def get_project_info(self, project_path: str | None) -> dict[str, Any]:
        path = self.resolve_project_path(project_path)
        version = await self.get_godot_version()

        counts = {"scenes": 0, "scripts": 0, "assets": 0, "other": 0}
        asset_extensions = {".png", ".jpg", ".jpeg", ".webp", ".svg", ".ttf", ".otf", ".wav", ".mp3", ".ogg"}
        for current, dirs, files in os.walk(path):
            dirs[:] = [name for name in dirs if not name.startswith(".") and name != ".godot"]
            for filename in files:
                suffix = Path(filename).suffix.lower()
                if suffix in {".tscn", ".scn"}:
                    counts["scenes"] += 1
                elif suffix in {".gd", ".cs", ".gdshader", ".shader"}:
                    counts["scripts"] += 1
                elif suffix in asset_extensions:
                    counts["assets"] += 1
                else:
                    counts["other"] += 1

        project_name = path.name
        try:
            for line in (path / "project.godot").read_text(encoding="utf-8").splitlines():
                if line.startswith('config/name="') and line.endswith('"'):
                    project_name = line.removeprefix('config/name="').removesuffix('"')
                    break
        except OSError:
            pass

        return {
            "name": project_name,
            "path": str(path),
            "godot": version,
            "structure": counts,
        }

    async def launch_editor(self, project_path: str | None) -> dict[str, Any]:
        path = self.resolve_project_path(project_path)
        godot_path = await self.get_godot_path()
        process = await asyncio.create_subprocess_exec(
            godot_path,
            "-e",
            "--path",
            str(path),
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        return {
            "pid": process.pid,
            "project_path": str(path),
            "message": "Godot editor launched.",
        }

    async def run_project(self, project_path: str | None, scene: str | None = None) -> dict[str, Any]:
        path = self.resolve_project_path(project_path)
        godot_path = await self.get_godot_path()
        if self._active_runtime:
            await self._active_runtime.close()
            self._active_runtime = None

        args = ["-d", "--path", str(path)]
        if scene:
            args.append(scene)

        process = await asyncio.create_subprocess_exec(
            godot_path,
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        runtime = GodotRuntimeProcess(process, str(path), scene, self._runtime_buffer_lines)
        if process.stdout:
            runtime.add_reader_task(asyncio.create_task(self._read_stream(process.stdout, runtime.stdout)))
        if process.stderr:
            runtime.add_reader_task(asyncio.create_task(self._read_stream(process.stderr, runtime.stderr)))
        self._active_runtime = runtime

        return runtime.status()

    async def _read_stream(
        self,
        stream: asyncio.StreamReader,
        buffer: deque[str],
    ) -> None:
        while True:
            line = await stream.readline()
            if not line:
                break
            buffer.append(line.decode(errors="replace").rstrip("\n"))

    def runtime_status(self) -> dict[str, Any]:
        if not self._active_runtime:
            return {"running": False, "active": False}
        return {"active": True, **self._active_runtime.status()}

    def get_debug_output(self, max_lines: int | None = None, clear: bool = False) -> dict[str, Any]:
        if not self._active_runtime:
            return {"active": False, "running": False, "output": [], "errors": []}

        line_count = max(1, max_lines or self._runtime_buffer_lines)
        output = list(self._active_runtime.stdout)[-line_count:]
        errors = list(self._active_runtime.stderr)[-line_count:]
        result = {
            **self._active_runtime.status(),
            "active": True,
            "output": output,
            "errors": errors,
        }
        if clear:
            self._active_runtime.stdout.clear()
            self._active_runtime.stderr.clear()
        return result

    async def stop_project(self) -> dict[str, Any]:
        if not self._active_runtime:
            return {"active": False, "running": False, "message": "No active Godot project process."}

        runtime = self._active_runtime
        await runtime.close()
        self._active_runtime = None
        return {
            **runtime.status(),
            "active": False,
            "output": list(runtime.stdout),
            "errors": list(runtime.stderr),
            "message": "Godot project stopped.",
        }

    def analyze_output(
        self,
        stdout: str | list[str] | None = None,
        stderr: str | list[str] | None = None,
        project_path: str | None = None,
    ) -> dict[str, Any]:
        return self._analyzer.analyze(stdout=stdout, stderr=stderr, project_path=project_path)

    def analyze_runtime_output(self, max_lines: int | None = None) -> dict[str, Any]:
        runtime_output = self.get_debug_output(max_lines=max_lines, clear=False)
        diagnostics = self.analyze_output(
            stdout=runtime_output.get("output", []),
            stderr=runtime_output.get("errors", []),
            project_path=runtime_output.get("project_path"),
        )
        return {
            **diagnostics,
            "runtime": {
                key: runtime_output.get(key)
                for key in ("active", "running", "returncode", "pid", "project_path", "scene")
            },
        }

    async def run_test(
        self,
        action: str,
        project_path: str | None,
        scene: str | None = None,
        timeout_seconds: float = DEFAULT_TEST_TIMEOUT_SECONDS,
        success_patterns: list[str] | None = None,
        failure_patterns: list[str] | None = None,
        expect_json: bool = False,
        command_args: list[str] | None = None,
        headless: bool = True,
        tail_lines: int = DEFAULT_OUTPUT_TAIL_LINES,
    ) -> dict[str, Any]:
        path = self.resolve_project_path(project_path)
        godot_path = await self.get_godot_path()
        args = self._test_command_args(
            action=action,
            project_path=path,
            scene=scene,
            command_args=command_args,
            headless=headless,
        )

        start = time.monotonic()
        process = await asyncio.create_subprocess_exec(
            godot_path,
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )

        timed_out = False
        try:
            stdout_bytes, stderr_bytes = await asyncio.wait_for(
                process.communicate(),
                timeout=max(0.1, timeout_seconds),
            )
        except asyncio.TimeoutError:
            timed_out = True
            process.kill()
            stdout_bytes, stderr_bytes = await process.communicate()

        duration_ms = int((time.monotonic() - start) * 1000)
        stdout_lines = stdout_bytes.decode(errors="replace").splitlines()
        stderr_lines = stderr_bytes.decode(errors="replace").splitlines()
        diagnostics = self.analyze_output(stdout_lines, stderr_lines, project_path=str(path))
        joined_output = "\n".join([*stdout_lines, *stderr_lines])

        matched_success = self._matched_patterns(joined_output, success_patterns)
        matched_failure = self._matched_patterns(joined_output, failure_patterns)
        json_result = self._extract_json_result(stdout_lines, stderr_lines) if expect_json else None

        passed = True
        failure_reasons: list[str] = []
        if timed_out:
            passed = False
            failure_reasons.append("Timed out")
        if process.returncode not in (0, None):
            passed = False
            failure_reasons.append(f"Godot exited with code {process.returncode}")
        if diagnostics["has_errors"]:
            passed = False
            failure_reasons.append(diagnostics["summary"])
        if matched_failure:
            passed = False
            failure_reasons.append("Matched failure pattern: " + ", ".join(matched_failure))
        if success_patterns and not matched_success:
            passed = False
            failure_reasons.append("Did not match required success pattern")
        if expect_json and json_result is None:
            passed = False
            failure_reasons.append("Did not find valid JSON output")

        summary = "Passed" if passed else "; ".join(failure_reasons)
        return {
            "passed": passed,
            "timed_out": timed_out,
            "exit_code": process.returncode,
            "duration_ms": duration_ms,
            "summary": summary,
            "command": [godot_path, *args],
            "project_path": str(path),
            "scene": scene,
            "matched_success_patterns": matched_success,
            "matched_failure_patterns": matched_failure,
            "json": json_result,
            "diagnostics": diagnostics,
            "stdout_tail": stdout_lines[-tail_lines:],
            "stderr_tail": stderr_lines[-tail_lines:],
        }

    def _test_command_args(
        self,
        action: str,
        project_path: Path,
        scene: str | None,
        command_args: list[str] | None,
        headless: bool,
    ) -> list[str]:
        args: list[str] = []
        if headless:
            args.append("--headless")

        if action == "run_command":
            if not command_args:
                raise GodotHostError("command_args is required for run_command.")
            return [*args, *[str(arg) for arg in command_args]]

        args.extend(["-d", "--path", str(project_path)])
        if action == "run_scene":
            if not scene:
                raise GodotHostError("scene is required for run_scene.")
            args.append(scene)
            return args
        if action == "run_main":
            return args
        raise GodotHostError(f"Unknown project_test action: {action}")

    def _matched_patterns(self, text: str, patterns: list[str] | None) -> list[str]:
        if not patterns:
            return []
        return [pattern for pattern in patterns if pattern and pattern in text]

    def _extract_json_result(self, stdout: list[str], stderr: list[str]) -> Any:
        for line in [*reversed(stdout), *reversed(stderr)]:
            stripped = line.strip()
            if not stripped:
                continue
            try:
                return json.loads(stripped)
            except json.JSONDecodeError:
                continue
        return None


class GodotBridgeClient:
    def __init__(
        self,
        base_url: str = DEFAULT_BRIDGE_URL,
        token: str | None = None,
        timeout: float = 30.0,
    ) -> None:
        self.base_url = self._normalize_ws_url(base_url)
        self.token = token
        self.timeout = timeout
        self._connection: Any | None = None
        self._reader_task: asyncio.Task[None] | None = None
        self._connect_lock = asyncio.Lock()
        self._pending: dict[str, asyncio.Future[dict[str, Any]]] = {}
        self._events: deque[dict[str, Any]] = deque(maxlen=500)
        self._request_seq = 0
        self._connected_at: float | None = None

    def _normalize_ws_url(self, url: str) -> str:
        normalized = url.rstrip("/")
        if normalized.startswith("http://"):
            normalized = "ws://" + normalized[len("http://") :]
        elif normalized.startswith("https://"):
            normalized = "wss://" + normalized[len("https://") :]
        if normalized in {"ws://127.0.0.1:3000", "ws://localhost:3000"}:
            normalized += "/bridge"
        return normalized

    def _next_id(self) -> str:
        self._request_seq += 1
        return f"{int(time.time() * 1000)}-{self._request_seq}"

    async def _connect(self) -> None:
        async with self._connect_lock:
            if self._connection is not None:
                return
            try:
                self._connection = await websockets.connect(
                    self.base_url,
                    subprotocols=["godot-bridge"],
                    ping_interval=10,
                    ping_timeout=10,
                    close_timeout=2,
                )
                self._connected_at = time.time()
                self._reader_task = asyncio.create_task(self._reader_loop())
                if self.token:
                    await self._send_auth()
            except Exception as exc:
                await self._drop_connection()
                raise GodotBridgeError(
                    f"Godot bridge is not reachable at {self.base_url}. "
                    "Start the Godot plugin bridge before using the gateway."
                ) from exc

    async def _send_auth(self) -> None:
        request_id = self._next_id()
        future: asyncio.Future[dict[str, Any]] = asyncio.get_running_loop().create_future()
        self._pending[request_id] = future
        await self._connection.send(
            json.dumps(
                {
                    "type": "auth",
                    "id": request_id,
                    "token": self.token,
                },
                ensure_ascii=False,
            )
        )
        response = await asyncio.wait_for(future, timeout=self.timeout)
        if not response.get("ok"):
            raise GodotBridgeError("Godot bridge rejected the gateway token.")

    async def _reader_loop(self) -> None:
        try:
            async for raw_message in self._connection:
                try:
                    message = json.loads(raw_message)
                except json.JSONDecodeError:
                    continue
                if not isinstance(message, dict):
                    continue
                message_type = message.get("type")
                if message_type == "response":
                    request_id = str(message.get("id", ""))
                    future = self._pending.pop(request_id, None)
                    if future and not future.done():
                        future.set_result(message)
                elif message_type == "event":
                    self._events.append(message)
        except Exception as exc:
            for future in self._pending.values():
                if not future.done():
                    future.set_exception(GodotBridgeError(f"Godot bridge connection closed: {exc}"))
            self._pending.clear()
        finally:
            self._connection = None
            self._connected_at = None

    async def _drop_connection(self) -> None:
        connection = self._connection
        self._connection = None
        self._connected_at = None
        if connection is not None:
            try:
                await connection.close()
            except Exception:
                pass
        if self._reader_task and not self._reader_task.done():
            self._reader_task.cancel()
        self._reader_task = None

    async def _request(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        await self._connect()
        request_id = self._next_id()
        future: asyncio.Future[dict[str, Any]] = asyncio.get_running_loop().create_future()
        self._pending[request_id] = future
        try:
            await self._connection.send(
                json.dumps(
                    {
                        "type": "request",
                        "id": request_id,
                        "method": method,
                        "params": params or {},
                    },
                    ensure_ascii=False,
                )
            )
            response = await asyncio.wait_for(future, timeout=self.timeout)
        except Exception:
            self._pending.pop(request_id, None)
            await self._drop_connection()
            raise

        if not response.get("ok"):
            raise GodotBridgeError(str(response.get("error") or f"Godot bridge request {method!r} failed."))
        result = response.get("result")
        if not isinstance(result, dict):
            raise GodotBridgeError(f"Godot bridge returned an invalid result for {method!r}.")
        return result

    async def health(self) -> dict[str, Any]:
        try:
            health = await self._request("health")
        except (OSError, TimeoutError, websockets.WebSocketException, asyncio.TimeoutError) as exc:
            raise GodotBridgeError(
                f"Godot bridge is not reachable at {self.base_url}. "
                "Start the Godot plugin bridge before using the gateway."
            ) from exc
        if health.get("auth"):
            try:
                await self.list_tools()
            except GodotBridgeError as exc:
                if is_bridge_auth_error(exc):
                    health["authenticated"] = False
                    health["authentication_error"] = str(exc)
                    health["hint"] = bridge_auth_hint()
                    health["problem"] = "Gateway is missing or using the wrong project token."
                    health["fix"] = "Start the Gateway with --project pointing at the target Godot project."
                else:
                    health["authenticated"] = False
                    health["authentication_error"] = str(exc)
            else:
                health["authenticated"] = True
        else:
            health["authenticated"] = True
        health["bridge_reachable"] = True
        health["ready_for_editor_tools"] = bool(health.get("authenticated"))
        return health

    async def list_tools(self) -> list[dict[str, Any]]:
        try:
            payload = await self._request("list_tools")
        except (OSError, TimeoutError, websockets.WebSocketException, asyncio.TimeoutError) as exc:
            raise GodotBridgeError(
                f"Godot bridge is not reachable at {self.base_url}. "
                "Start the Godot plugin bridge before using the gateway."
            ) from exc

        bridge_tools = payload.get("tools", payload)
        if not isinstance(bridge_tools, list):
            raise GodotBridgeError("Godot bridge returned an invalid tools payload.")

        available_names: set[str] = set()
        for tool in bridge_tools:
            if isinstance(tool, dict):
                name = str(tool.get("name", ""))
            else:
                name = str(tool)
            if name:
                available_names.add(name)

        return make_bridge_tool_definitions(available_names)

    async def execute(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        try:
            payload = await self._request("execute", {"name": name, "arguments": arguments})
        except (OSError, TimeoutError, websockets.WebSocketException, asyncio.TimeoutError) as exc:
            raise GodotBridgeError(
                f"Godot bridge is not reachable at {self.base_url}. "
                "Start the Godot plugin bridge before calling tools."
            ) from exc

        if not isinstance(payload, dict):
            raise GodotBridgeError(f"Godot bridge returned an invalid result for {name!r}.")
        return payload

    def events_status(self) -> dict[str, Any]:
        return {
            "connected": self._connection is not None,
            "connected_at": self._connected_at,
            "event_count": len(self._events),
            "bridge_url": self.base_url,
        }

    def poll_events(self, limit: int = 100, clear: bool = False) -> dict[str, Any]:
        count = max(1, limit)
        events = list(self._events)[-count:]
        if clear:
            self._events.clear()
        return {"events": events, "count": len(events), **self.events_status()}

    def clear_events(self) -> dict[str, Any]:
        self._events.clear()
        return {"cleared": True, **self.events_status()}


class GodotBridgeTool(Tool):
    def __init__(self, bridge: GodotBridgeClient, **kwargs: Any) -> None:
        super().__init__(**kwargs)
        self._bridge = bridge

    async def run(self, arguments: dict[str, Any]) -> ToolResult:
        try:
            result = await self._bridge.execute(self.name, arguments)
        except GodotBridgeError as exc:
            raise ToolError(str(exc)) from exc

        if result.get("success") is False:
            message = str(result.get("error") or f"Godot tool {self.name!r} failed.")
            hints = result.get("hints")
            if hints:
                message = f"{message} Hints: {json.dumps(hints, ensure_ascii=False)}"
            raise ToolError(message)

        text = json.dumps(result, ensure_ascii=False)
        return ToolResult(content=text, structured_content=result)


class GodotBridgeProvider(Provider):
    def __init__(self, bridge: GodotBridgeClient) -> None:
        super().__init__()
        self._bridge = bridge

    async def _list_tools(self) -> list[Tool]:
        try:
            definitions = await self._bridge.list_tools()
        except GodotBridgeError as exc:
            if is_bridge_auth_error(exc):
                definitions = make_bridge_tool_definitions()
                return [
                    self._make_tool(
                        {
                            **definition,
                            "description": f"{definition.get('description', '')} {bridge_auth_hint()}",
                        }
                    )
                    for definition in definitions
                ]
            return []
        return [self._make_tool(definition) for definition in definitions]

    async def _get_tool(self, name: str, version: Any = None) -> Tool | None:
        try:
            definitions = await self._bridge.list_tools()
        except GodotBridgeError as exc:
            if is_bridge_auth_error(exc):
                definitions = make_bridge_tool_definitions()
            else:
                return None

        for definition in definitions:
            if definition.get("name") == name:
                return self._make_tool(definition)
        return None

    def _make_tool(self, definition: dict[str, Any]) -> GodotBridgeTool:
        name = str(definition.get("name", ""))
        description = str(definition.get("description", ""))
        parameters = definition.get("inputSchema")
        if not isinstance(parameters, dict):
            parameters = {"type": "object", "properties": {}}

        return GodotBridgeTool(
            bridge=self._bridge,
            name=name,
            description=description,
            parameters=parameters,
            tags={"godot"},
        )


RUNTIME_AUTOLOAD_NAME = "GodotBridgeRuntime"
RUNTIME_AUTOLOAD_PATH = "res://addons/godot_bridge/runtime/runtime_bridge.gd"
RUNTIME_AUTOLOAD_VALUE = f"*{RUNTIME_AUTOLOAD_PATH}"


async def prepare_runtime_helper(bridge: GodotBridgeClient) -> dict[str, Any]:
    autoloads = await bridge.execute("godot_project", {"action": "autoload_list"})
    existing = (autoloads.get("data") or {}).get("autoloads", [])
    for item in existing:
        if not isinstance(item, dict):
            continue
        if item.get("name") == RUNTIME_AUTOLOAD_NAME:
            if item.get("path") not in {RUNTIME_AUTOLOAD_PATH, RUNTIME_AUTOLOAD_VALUE}:
                raise GodotBridgeError(
                    f"Autoload {RUNTIME_AUTOLOAD_NAME!r} already exists and does not point to the Godot Bridge runtime helper."
                )
            return {
                "prepared": True,
                "changed": False,
                "autoload": item,
            }
    result = await bridge.execute(
        "godot_project",
        {
            "action": "autoload_add",
            "name": RUNTIME_AUTOLOAD_NAME,
            "path": RUNTIME_AUTOLOAD_PATH,
        },
    )
    return {"prepared": True, "changed": True, "result": result}


async def uninstall_runtime_helper(bridge: GodotBridgeClient) -> dict[str, Any]:
    autoloads = await bridge.execute("godot_project", {"action": "autoload_list"})
    existing = (autoloads.get("data") or {}).get("autoloads", [])
    for item in existing:
        if not isinstance(item, dict):
            continue
        if item.get("name") != RUNTIME_AUTOLOAD_NAME:
            continue
        if item.get("path") not in {RUNTIME_AUTOLOAD_PATH, RUNTIME_AUTOLOAD_VALUE}:
            return {"removed": False, "reason": "Autoload exists but does not match the Godot Bridge runtime helper.", "autoload": item}
        result = await bridge.execute("godot_project", {"action": "autoload_remove", "name": RUNTIME_AUTOLOAD_NAME})
        return {"removed": True, "result": result}
    return {"removed": False, "reason": "Autoload is not installed."}


async def request_runtime(
    bridge: GodotBridgeClient,
    *,
    action: str,
    session_id: int,
    payload: dict[str, Any],
    timeout: float,
) -> dict[str, Any]:
    request_id = f"runtime-{uuid.uuid4().hex}"
    await bridge.execute(
        "godot_debug",
        {
            "action": "send_message",
            "session_id": session_id,
            "message": "godot_bridge:request",
            "data": [{"id": request_id, "action": action, "payload": payload}],
        },
    )

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        messages = await bridge.execute("godot_debug", {"action": "captured_messages", "limit": 200})
        for entry in (messages.get("data") or {}).get("messages", []):
            if not isinstance(entry, dict):
                continue
            if entry.get("session_id") != session_id or entry.get("message") != "godot_bridge:response":
                continue
            data = entry.get("data") or []
            if not data or not isinstance(data[0], dict):
                continue
            response = data[0]
            if response.get("id") != request_id:
                continue
            if not response.get("success"):
                raise GodotBridgeError(str(response.get("error") or f"Runtime action {action!r} failed."))
            return {
                "success": True,
                "session_id": session_id,
                "request_id": request_id,
                "data": response.get("data"),
            }
        await asyncio.sleep(0.05)
    raise GodotBridgeError(f"Timed out waiting for runtime response to {action!r}.")


def build_bridge_server(args: argparse.Namespace) -> FastMCP:
    token = args.bridge_token or os.getenv("GODOT_MCP_BRIDGE_TOKEN")
    if args.bridge_token_file and not token:
        token = read_text_file_if_exists(args.bridge_token_file)
    if not token and os.path.exists(DEFAULT_BRIDGE_TOKEN_FILE):
        token = read_text_file_if_exists(DEFAULT_BRIDGE_TOKEN_FILE)

    bridge = GodotBridgeClient(
        base_url=args.bridge_url,
        token=token,
        timeout=args.bridge_timeout,
    )
    host = GodotHostManager(
        godot_path=args.godot_path,
        runtime_buffer_lines=args.runtime_buffer_lines,
    )

    server = FastMCP(
        "Godot MCP Gateway",
        instructions=(
            "Agents connect to this FastMCP Gateway, not directly to the Godot "
            "Bridge. Start with project_environment, then call godot_bridge_health "
            "before using Bridge-backed godot_* editor tools. Host-side project tools remain "
            "available even when the editor plugin is not running."
        ),
        providers=[GodotBridgeProvider(bridge)],
        mask_error_details=False,
    )

    @server.tool(
        name="godot_bridge_health",
        description=(
            "Check whether the local Godot MCP Bridge plugin is reachable. "
            "Call this before godot_scene, godot_node, godot_script, "
            "godot_resource, godot_project, godot_editor, godot_debug, or godot_view."
        ),
        tags={"godot", "health"},
    )
    async def godot_bridge_health() -> dict[str, Any]:
        try:
            return await bridge.health()
        except GodotBridgeError as exc:
            raise ToolError(str(exc)) from exc

    @server.tool(
        name="godot_events",
        description=(
            "Read Gateway-buffered events pushed by the Godot Bridge WebSocket. "
            "Actions: status, poll, clear."
        ),
        tags={"godot", "events"},
    )
    async def godot_events(
        action: str,
        limit: int = 100,
        clear: bool = False,
    ) -> dict[str, Any]:
        if action == "status":
            return bridge.events_status()
        if action == "poll":
            return bridge.poll_events(limit=limit, clear=clear)
        if action == "clear":
            return bridge.clear_events()
        raise ToolError(f"Unknown godot_events action: {action}")

    @server.tool(
        name="godot_runtime",
        description=(
            "Interact with a running Godot project through the Bridge debugger runtime helper. "
            "Actions: prepare, status, ping, tree, get_property, set_property, call_method, "
            "eval, exec, screenshot, uninstall_helper."
        ),
        tags={"godot", "runtime"},
    )
    async def godot_runtime(
        action: str,
        session_id: int = 0,
        path: str | None = None,
        property: str | None = None,
        value: Any = None,
        method: str | None = None,
        args: list[Any] | None = None,
        expression: str | None = None,
        code: str | None = None,
        include_base64: bool = False,
        timeout_seconds: float = 5.0,
    ) -> dict[str, Any]:
        try:
            if action == "prepare":
                return await prepare_runtime_helper(bridge)
            if action == "uninstall_helper":
                return await uninstall_runtime_helper(bridge)
            payload = {
                "path": path,
                "property": property,
                "value": value,
                "method": method,
                "args": args or [],
                "expression": expression,
                "code": code,
                "include_base64": include_base64,
            }
            return await request_runtime(
                bridge,
                action=action,
                session_id=session_id,
                payload={key: val for key, val in payload.items() if val is not None},
                timeout=timeout_seconds,
            )
        except GodotBridgeError as exc:
            raise ToolError(str(exc)) from exc

    @server.tool(
        name="project_environment",
        description=(
            "Host-side Godot environment tools that do not require the Bridge. "
            "Use this first to detect Godot and inspect projects. Actions: "
            "detect_godot, get_godot_version, list_projects, get_project_info."
        ),
        tags={"godot", "project", "environment"},
    )
    async def project_environment(
        action: str,
        project_path: str | None = None,
        directory: str | None = None,
        recursive: bool = False,
        force: bool = False,
    ) -> dict[str, Any]:
        try:
            if action == "detect_godot":
                return await host.detect_godot(force=force)
            if action == "get_godot_version":
                return await host.get_godot_version()
            if action == "list_projects":
                return host.list_projects(directory, recursive=recursive)
            if action == "get_project_info":
                return await host.get_project_info(project_path)
        except GodotHostError as exc:
            raise ToolError(str(exc)) from exc

        raise ToolError(f"Unknown project_environment action: {action}")

    @server.tool(
        name="project_runtime",
        description=(
            "Host-side Godot runtime tools that do not require the Bridge. Use "
            "after edits to launch the editor, run projects, read stdout/stderr, "
            "and stop processes. Actions: launch_editor, run_project, status, "
            "get_debug_output, stop_project."
        ),
        tags={"godot", "project", "runtime"},
    )
    async def project_runtime(
        action: str,
        project_path: str | None = None,
        scene: str | None = None,
        max_lines: int | None = None,
        clear: bool = False,
        runtime_bridge: bool = True,
    ) -> dict[str, Any]:
        try:
            if action == "launch_editor":
                return await host.launch_editor(project_path)
            if action == "run_project":
                runtime_warning = None
                if runtime_bridge:
                    try:
                        await prepare_runtime_helper(bridge)
                    except GodotBridgeError as exc:
                        runtime_warning = str(exc)
                result = await host.run_project(project_path, scene=scene)
                if runtime_warning:
                    result["runtime_bridge_warning"] = runtime_warning
                else:
                    result["runtime_bridge_prepared"] = bool(runtime_bridge)
                return result
            if action == "status":
                return host.runtime_status()
            if action == "get_debug_output":
                return host.get_debug_output(max_lines=max_lines, clear=clear)
            if action == "stop_project":
                return await host.stop_project()
        except GodotHostError as exc:
            raise ToolError(str(exc)) from exc

        raise ToolError(f"Unknown project_runtime action: {action}")

    @server.tool(
        name="project_diagnostics",
        description=(
            "Host-side diagnostics that do not require the Bridge. Analyze Godot "
            "stdout/stderr into structured errors, warnings, file paths, and line "
            "numbers after project_runtime or project_test. Actions: "
            "analyze_runtime_output, analyze_text."
        ),
        tags={"godot", "project", "diagnostics"},
    )
    async def project_diagnostics(
        action: str,
        stdout: str | list[str] | None = None,
        stderr: str | list[str] | None = None,
        project_path: str | None = None,
        max_lines: int | None = None,
    ) -> dict[str, Any]:
        if action == "analyze_runtime_output":
            return host.analyze_runtime_output(max_lines=max_lines)
        if action == "analyze_text":
            return host.analyze_output(stdout=stdout, stderr=stderr, project_path=project_path)

        raise ToolError(f"Unknown project_diagnostics action: {action}")

    @server.tool(
        name="project_test",
        description=(
            "Host-side test runner that does not require the Bridge. Run a Godot "
            "project, scene, or command as a verification step and return pass/fail "
            "with structured diagnostics. Actions: run_main, run_scene, run_command."
        ),
        tags={"godot", "project", "test"},
    )
    async def project_test(
        action: str,
        project_path: str | None = None,
        scene: str | None = None,
        timeout_seconds: float = DEFAULT_TEST_TIMEOUT_SECONDS,
        success_patterns: list[str] | None = None,
        failure_patterns: list[str] | None = None,
        expect_json: bool = False,
        command_args: list[str] | None = None,
        headless: bool = True,
        tail_lines: int = DEFAULT_OUTPUT_TAIL_LINES,
    ) -> dict[str, Any]:
        try:
            return await host.run_test(
                action=action,
                project_path=project_path,
                scene=scene,
                timeout_seconds=timeout_seconds,
                success_patterns=success_patterns,
                failure_patterns=failure_patterns,
                expect_json=expect_json,
                command_args=command_args,
                headless=headless,
                tail_lines=tail_lines,
            )
        except GodotHostError as exc:
            raise ToolError(str(exc)) from exc

    @server.custom_route("/health", methods=["GET"])
    async def health(_request):
        from starlette.responses import JSONResponse

        try:
            bridge_health = await bridge.health()
            return JSONResponse(
                {
                    "status": "ok",
                    "mode": "bridge",
                    "bridge": bridge_health,
                }
            )
        except GodotBridgeError as exc:
            return JSONResponse(
                {
                    "status": "error",
                    "mode": "bridge",
                    "error": str(exc),
                },
                status_code=503,
            )

    @server.custom_route("/endpoint", methods=["GET"])
    async def endpoint(_request):
        from starlette.responses import JSONResponse

        return JSONResponse(make_endpoint_payload(args.host, args.port, args.bridge_url))

    return server


def is_port_available(host: str, port: int) -> bool:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind((host, port))
            return True
    except OSError:
        return False


def choose_gateway_port(host: str, requested_port: int, auto_port: bool) -> int:
    if requested_port <= 0:
        raise ValueError("--port must be greater than 0")

    if is_port_available(host, requested_port):
        return requested_port

    if not auto_port:
        raise RuntimeError(
            f"Gateway port {requested_port} is already in use. "
            "Stop the process using it or restart with --auto-port / --port <port>."
        )

    for port in range(requested_port + 1, 65536):
        if is_port_available(host, port):
            return port

    raise RuntimeError(f"No available Gateway port found after {requested_port}.")


def make_endpoint_payload(host: str, port: int, bridge_url: str) -> dict[str, Any]:
    visible_host = "127.0.0.1" if host in {"0.0.0.0", "::"} else host
    mcp_url = f"http://{visible_host}:{port}/mcp"
    return {
        "name": "godot-bridge",
        "host": host,
        "port": port,
        "mcp_url": mcp_url,
        "bridge_url": bridge_url,
        "pid": os.getpid(),
        "started_at": time.time(),
    }


def write_endpoint_file(path: str | None, host: str, port: int, bridge_url: str) -> None:
    if not path:
        return

    endpoint_path = Path(path).expanduser()
    payload = make_endpoint_payload(host, port, bridge_url)
    endpoint_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Godot MCP Gateway endpoint: {payload['mcp_url']}")
    print(f"Endpoint manifest: {endpoint_path.resolve()}")


def resolve_project_path(project: str | None) -> Path | None:
    if not project:
        return None

    project_path = Path(project).expanduser().resolve()
    if not project_path.exists():
        raise ValueError(f"--project does not exist: {project_path}")
    if not project_path.is_dir():
        raise ValueError(f"--project must point to a Godot project directory: {project_path}")
    return project_path


def apply_project_defaults(args: argparse.Namespace) -> None:
    project_path = resolve_project_path(args.project)
    if project_path is not None:
        if args.bridge_token_file is None:
            args.bridge_token_file = str(project_path / DEFAULT_BRIDGE_TOKEN_FILE)
        if args.endpoint_file is None:
            args.endpoint_file = str(project_path / DEFAULT_ENDPOINT_FILE)
    elif args.endpoint_file is None:
        args.endpoint_file = DEFAULT_ENDPOINT_FILE


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the Godot MCP FastMCP gateway.")
    parser.add_argument(
        "--project",
        default=None,
        help=(
            "Path to the target Godot project. When set, the Gateway reads "
            ".bridge_token and writes .gateway_endpoint.json inside that project."
        ),
    )
    parser.add_argument("--host", default=DEFAULT_GATEWAY_HOST)
    parser.add_argument("--port", type=int, default=DEFAULT_GATEWAY_PORT)
    parser.add_argument(
        "--auto-port",
        action="store_true",
        help="Use the next available port if --port is already occupied.",
    )
    parser.add_argument(
        "--endpoint-file",
        default=None,
        help=(
            "Write the selected MCP endpoint to this JSON file. Defaults to "
            "<project>/.gateway_endpoint.json when --project is set, otherwise "
            ".gateway_endpoint.json. Use an empty value to disable."
        ),
    )
    parser.add_argument("--bridge-url", default=DEFAULT_BRIDGE_URL)
    parser.add_argument("--bridge-token", default=None)
    parser.add_argument("--bridge-token-file", default=None)
    parser.add_argument("--bridge-timeout", type=float, default=30.0)
    parser.add_argument("--godot-path", default=None)
    parser.add_argument("--runtime-buffer-lines", type=int, default=DEFAULT_RUNTIME_BUFFER_LINES)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    try:
        apply_project_defaults(args)
        args.port = choose_gateway_port(args.host, args.port, args.auto_port)
    except (RuntimeError, ValueError) as exc:
        raise SystemExit(str(exc)) from exc
    write_endpoint_file(args.endpoint_file, args.host, args.port, args.bridge_url)
    server = build_bridge_server(args)
    server.run(transport="http", host=args.host, port=args.port)


if __name__ == "__main__":
    main()

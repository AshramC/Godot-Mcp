from __future__ import annotations

import argparse
import asyncio
import json
from pathlib import Path
import sys

from fastmcp import Client


DEFAULT_GATEWAY_URL = "http://127.0.0.1:3001/mcp"
DEFAULT_ENDPOINT_FILE = ".gateway_endpoint.json"
DEFAULT_EXPECTED_TOOLS = [
    "project_environment",
    "project_runtime",
    "project_diagnostics",
    "project_test",
    "godot_bridge_health",
    "godot_events",
    "godot_runtime",
    "godot_scene",
    "godot_node",
    "godot_script",
    "godot_resource",
    "godot_project",
    "godot_editor",
    "godot_debug",
    "godot_view",
]


async def run_smoke_test(gateway_url: str, expected_tools: list[str]) -> int:
    async with Client(gateway_url) as client:
        tools = await client.list_tools()
        names = sorted(tool.name for tool in tools)

        print(f"Connected to {gateway_url}")
        print(f"Tools: {len(names)}")

        missing = [name for name in expected_tools if name not in names]
        if missing:
            print("Missing expected tools: " + ", ".join(missing), file=sys.stderr)
            return 1

        if "godot_bridge_health" in expected_tools and "godot_bridge_health" in names:
            try:
                health = await client.call_tool("godot_bridge_health", {})
                print(f"Bridge health: {health.structured_content}")
            except Exception as exc:
                print(f"Bridge health unavailable: {exc}")

    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Smoke test the Godot MCP FastMCP gateway.")
    parser.add_argument("--gateway-url", default=None)
    parser.add_argument(
        "--endpoint-file",
        default=DEFAULT_ENDPOINT_FILE,
        help="Read the Gateway MCP URL from this endpoint manifest when --gateway-url is omitted.",
    )
    parser.add_argument(
        "--expect-tool",
        action="append",
        dest="expected_tools",
        help="Tool name expected in the gateway tool list. Can be provided multiple times.",
    )
    return parser.parse_args()


def resolve_gateway_url(args: argparse.Namespace) -> str:
    if args.gateway_url:
        return args.gateway_url

    endpoint_file = Path(args.endpoint_file).expanduser()
    if endpoint_file.is_file():
        try:
            payload = json.loads(endpoint_file.read_text(encoding="utf-8"))
            mcp_url = payload.get("mcp_url")
            if isinstance(mcp_url, str) and mcp_url:
                return mcp_url
        except (OSError, json.JSONDecodeError):
            pass

    return DEFAULT_GATEWAY_URL


def main() -> None:
    args = parse_args()
    expected_tools = args.expected_tools or DEFAULT_EXPECTED_TOOLS
    raise SystemExit(asyncio.run(run_smoke_test(resolve_gateway_url(args), expected_tools)))


if __name__ == "__main__":
    main()

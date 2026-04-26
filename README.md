# Godot MCP Bridge

[![Python 3.10+](https://img.shields.io/badge/python-3.10+-blue.svg)](https://www.python.org/)
[![Godot 4.x](https://img.shields.io/badge/godot-4.x-478CBF.svg)](https://godotengine.org/)
[![FastMCP](https://img.shields.io/badge/MCP-FastMCP-orange.svg)](https://github.com/jlowin/fastmcp)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**[English](README_EN.md)** | 中文

> 让 AI（Claude、Gemini、Codex 等）直接在 Godot 4 编辑器里帮你写代码、修改场景、运行项目——通过 MCP 协议实现实时双向通信。


---

## 为什么选择 Godot MCP Bridge？

Godot MCP 生态里已经有十多个方案，这个项目的差异化在于：

- **🏗️ 双层架构（Gateway + Bridge）**——AI 客户端连接 Python Gateway，Gateway 再转发给编辑器插件。这意味着 Gateway 侧的项目检测、headless 运行、诊断分析等功能 **不需要 Godot 编辑器运行** 也能工作，适合 CI/CD 和自动化流水线。
- **🧪 内置测试与诊断闭环**——`project_test` 支持 headless 运行 + 成功/失败模式匹配 + JSON 输出提取；`project_diagnostics` 自动将 Godot 输出解析为带文件路径和行号的结构化错误。AI 可以完成"编辑 → 运行 → 诊断 → 修复"的完整循环。
- **📦 Slim Tool 设计**——8 个工具组覆盖 60+ 操作，通过 `action` 参数分发，而非暴露上百个独立工具。大幅节省 LLM 的 context window，让 AI 更高效地理解可用能力。
- **🐍 Python 原生**——基于 FastMCP + uv，一行命令启动，无需 Node.js 构建步骤。对 Python 生态开发者零摩擦。
- **🌐 多客户端友好**——HTTP MCP 端点天然支持多客户端切换，不受 stdio 一对一绑定限制。Claude Code、Gemini CLI、Codex 均可即插即用。

---

## 前置要求

- [Godot 4.x](https://godotengine.org/)
- [uv](https://docs.astral.sh/uv/getting-started/installation/)（Python 包管理器）
- 支持 MCP 的 AI 客户端，例如 Claude Code、Gemini CLI、Codex

---

## 快速上手

### 第 1 步：安装 Godot 插件

将本仓库中的 `addons/godot_bridge/` 文件夹复制到你的 Godot 项目里：

```
你的Godot项目/
└── addons/
    └── godot_bridge/   ← 复制到这里
```

在 Godot 中启用插件：`项目 → 项目设置 → 插件 → Godot Bridge → 启用`

在右侧面板找到 **Godot AI 连接器**，进入「连接状态」页，点击「启动服务」。

### 第 2 步：启动 Gateway

在**本仓库根目录**运行（`gateway/` 等文件保留在本仓库，不需要复制到 Godot 项目）：

```bash
uv run godot-bridge-gateway --project /path/to/your-godot-project
```

> Godot 面板「客户端设置」页会生成带正确项目路径的完整命令，优先复制面板里的命令。Gateway 会在内部读取项目的 `.bridge_token`，不需要手动传 token 文件。  
> 如果 3001 端口被占用，追加 `--auto-port`，实际 MCP URL 会写入该 Godot 项目的 `.gateway_endpoint.json`。

### 第 3 步：配置 AI 客户端

在 Godot 面板的「客户端设置」页，复制「给 AI 的初始指令」粘贴给你的 AI。需要手动配置时，复制「AI 客户端连接地址」填入支持 MCP 的客户端即可。

---

## AI Agent 集成

本项目为 AI agent 提供了开箱即用的行为指南，让 agent 不需要额外的 prompt 工程就能正确使用工具：

- **[`AGENTS.md`](AGENTS.md)**——Agent 行为规范，定义了标准工作流（先检测环境 → 检查 Bridge 健康 → 编辑 → 保存 → 测试 → 诊断）、安全规则（优先用 `res://` 路径、避免破坏性删除）和客户端配置方法。支持 Claude Code、Codex 等自动读取。
- **[`skills/godot-mcp/SKILL.md`](skills/godot-mcp/SKILL.md)**——Claude Code 技能包。将 `skills/` 目录放到你的项目中后，Claude Code 会自动加载该技能，agent 无需手动提示即可按正确顺序调用工具。

---

## 架构说明

```
AI 客户端 (Claude Code / Gemini CLI / Codex)
   │  MCP (HTTP)
   ▼
FastMCP Gateway  (本仓库, http://127.0.0.1:3001/mcp)
   │  WebSocket           ← Gateway 宿主侧工具在这一层独立运作
   ▼
Godot Bridge 插件  (目标项目, ws://127.0.0.1:3000/bridge)
   │
   ▼
Godot 4 编辑器           ← Bridge 工具在这一层操作编辑器
```

- AI 客户端**只连接 Gateway**，不直接连接 Bridge。
- Gateway 负责协议转换和宿主侧工具（无需编辑器运行）。
- Bridge 插件负责编辑器内的实时操作。

---

## 工具一览

### Gateway 宿主侧工具（无需 Godot 编辑器运行）

| 工具 | 用途 | 典型场景 |
|---|---|---|
| `project_environment` | 检测 Godot 版本、查找项目 | "帮我找到这个目录下所有 Godot 项目" |
| `project_runtime` | 启动编辑器、运行项目/场景、读取输出 | "运行主场景，把控制台输出给我看" |
| `project_diagnostics` | 将 Godot 输出解析为结构化错误和警告 | "分析刚才的运行日志，告诉我哪些脚本报错了" |
| `project_test` | 以 headless 方式运行项目并返回 pass/fail | "跑一下这个场景，检查是否输出了 test_passed" |
| `godot_bridge_health` | 检查编辑器 Bridge 是否在线 | 任何编辑器操作前的前置检查 |

### Bridge 工具（需要 Godot 编辑器 + 插件运行）

| 工具 | 主要功能 | 典型场景 |
|---|---|---|
| `godot_scene` | 场景打开、保存、创建、播放/停止 | "创建一个以 Node3D 为根节点的新场景保存到 res://levels/" |
| `godot_node` | 节点查找、创建、删除、属性编辑、变换 | "在 Player 节点下添加一个 CollisionShape3D，设置它的 position" |
| `godot_script` | 脚本创建、读写、挂载、在编辑器打开 | "给 Player 节点创建一个新脚本，写入移动逻辑" |
| `godot_resource` | 资源查询、创建、复制、移动、UID 管理 | "列出 res://assets/ 下所有纹理资源" |
| `godot_project` | 项目设置、输入动作、autoload | "添加一个 move_left 输入动作，绑定 A 键" |
| `godot_editor` | 编辑器状态、文件系统刷新、Inspector、ClassDB | "查看 CharacterBody3D 有哪些属性和方法" |
| `godot_debug` | 调试会话、断点、捕获调试消息 | "在 player.gd 第 42 行设置一个断点" |
| `godot_view` | 截取编辑器 2D/3D 视口截图 | "截取当前 3D 视口截图让我看看场景布局" |

---

## 常见问题

<details>
<summary><b>Gateway 正常启动，但 AI 只看到宿主侧工具，没有 godot_scene 等 Bridge 工具？</b></summary>

检查 Godot 插件是否已启用并点击了「启动服务」按钮。面板状态应显示「运行中」。
</details>

<details>
<summary><b>端口冲突？</b></summary>

用 `--auto-port` 启动 Gateway，然后在面板「连接状态」页复制实际的「AI 客户端连接地址」重新配置客户端。
</details>

<details>
<summary><b>支持哪些 AI 客户端？</b></summary>

所有支持 MCP 的客户端都可以使用，包括 Claude Code、Gemini CLI、OpenAI Codex、Cursor 等。Gateway 暴露的是标准 HTTP MCP 端点，不依赖 stdio 传输。
</details>

<details>
<summary><b>跟 AI 直接读写 .tscn/.gd 文件相比有什么优势？</b></summary>

Bridge 工具通过 Godot 编辑器 API 操作，能正确处理 UID、资源引用、场景树层级关系，避免手动编辑文本格式时的各种兼容性问题。同时可以实时在编辑器中看到修改效果。
</details>

<details>
<summary><b>能不能只用 Gateway 不装编辑器插件？</b></summary>

可以。Gateway 的宿主侧工具（`project_environment`、`project_runtime`、`project_test`、`project_diagnostics`）不需要编辑器运行。你可以用它们来检测项目、headless 运行、分析错误。只是 `godot_*` 系列的编辑器操作工具不可用。
</details>

<details>
<summary><b>重载插件后翻译没有更新？</b></summary>

在 Godot 中完全禁用再重新启用插件（仅刷新脚本不够）。
</details>

---

## 许可证

本项目基于 [MIT 许可证](LICENSE) 开源。

---

<details>
<summary>开发者：冒烟测试</summary>

```bash
# 仅宿主侧工具
uv run python -m gateway.smoke_test \
  --expect-tool project_environment \
  --expect-tool project_runtime \
  --expect-tool project_diagnostics \
  --expect-tool project_test \
  --expect-tool godot_bridge_health

# Bridge 工具（需要 Godot 插件运行）
uv run python -m gateway.smoke_test \
  --expect-tool godot_scene \
  --expect-tool godot_node \
  --expect-tool godot_script \
  --expect-tool godot_resource \
  --expect-tool godot_project \
  --expect-tool godot_editor \
  --expect-tool godot_debug \
  --expect-tool godot_view
```

</details>

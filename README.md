# Scribe — 自动手记人偶

**一个零依赖的 Bash 终端 AI 聊天客户端。** 单文件脚本，支持 OpenAI / Anthropic 双 API，流式响应、对话存档、角色扮演技能系统，开箱即用。

## 应用场景

### 日常 AI 助手

直接在终端里与 AI 对话，无需打开浏览器或任何 GUI 应用。适合在 SSH 远程服务器、Docker 容器、嵌入式设备、临时云主机等无图形环境的场景下使用。

### 角色扮演与沉浸式交互

内置可扩展的 **Skill 系统**，通过加载不同的角色 skill 文件，AI 可以切换为特定人设进行对话。适用于：

- **同人创作 / 世界观探索**：与特定角色进行符合原作的沉浸式对话，辅助剧情构思、角色语音定调
- **文字互动游戏**：将 AI 包装成 NPC 或叙事角色，提供风格统一的交互体验
- **写作辅助**：在特定角色的语感下生成文本片段

附带几个示例 skill（《明日方舟》角色风格），但 Skill 系统本身是通用框架——你可以编写任意角色的 skill 文件，其约定格式为 YAML frontmatter + Markdown 正文。

### 终端即用环境

适合以下需要“轻量 AI 前端”的场景：

- **远程服务器 / VPS**：SSH 连上去就能聊，不需要安装 Python 环境、Node 或任何包管理器
- **临时环境**：云主机重启后，只需一个脚本文件即可恢复 AI 对话能力
- **自动化管道**：将 AI 回复接入 shell 脚本，作为文本处理流水线的一环（配合 `/read` 命令读取文件输入）
- **教学 / 演示**：展示 AI API 调用原理、流式响应、多 provider 切换的最简实现

## 特点

### 零运行环境要求

**不需要任何运行时、包管理器或第三方库。** Scribe 唯一依赖的是绝大多数 Linux 发行版预装的三个工具：

| 依赖 | 用途 | 预装率 |
|------|------|--------|
| `bash` (≥4.0) | 脚本解释器 | 所有 Linux 发行版 |
| `curl` | HTTPS 请求 | 几乎所有系统 |
| `jq` | JSON 处理 | 可通过包管理器一键安装 |

没有 `pip install`，没有 `npm install`，没有虚拟环境，没有 Docker 镜像。把 `scribe.sh` 放到任意目录，确保 `bash`、`curl`、`jq` 可用，填入 API Key 即可开始使用。

### 双 API 兼容

同时支持 OpenAI 兼容 API（包括 DeepSeek 等第三方厂商）和 Anthropic 原生 API。`/provider` 命令一键切换，各自独立的 Key、URL 和 Model 配置互不干扰。你可以随时在两者之间切换，对话上下文会被重置以适配新的 API 格式。

### 流式响应与思考过程

实时流式输出 AI 回复，支持同时展示：
- **思考过程**（Reasoning / Thinking）：AI 在生成最终回复前的内部推理链，可随时开关
- **Token 用量统计**：每次对话结束时显示 Prompt / Completion / Total tokens

### 本地对话管理

所有对话历史以 JSON 格式保存在本地 `.scribe_history/` 目录中，支持：
- `/save` / `/load` / `/delete` 管理对话存档
- 对话完全离线存储，不经过任何第三方服务器
- 可手动编辑 JSON 文件进行历史裁剪或迁移

### 可扩展角色技能系统

Skill 文件使用 `YAML frontmatter + Markdown` 格式，存放在 `.skills/<skill-id>/SKILL.md`，支持引用子目录 `references/` 中的附录文件。`/skill <id>` 即可加载并重建对话上下文。

*注：附带几个《明日方舟》角色示例 skill（佩丽卡 / 凯尔希 / 普瑞赛斯 + 默认通用助手），后续会独立提交。Skill 系统本身与具体角色内容无关，你可以编写任何风格的角色文件。*

### Tab 自动补全

内置命令、文件名、存档名、skill 名的 Tab 补全，无需额外配置。

## 快速开始

```bash
# 1. 确保依赖可用（通常已预装）
bash --version   # ≥ 4.0
curl --version
jq --version

# 2. 赋予执行权限
chmod +x scribe.sh

# 3. 启动（首次运行会提示输入 API Key）
./scribe.sh

# 4. 内部常用命令
/key sk-your-api-key       # 设置 API Key（会持久化到本地设置文件）
/provider [openai|anthropic]  # 查看或切换 API 提供商
/model <模型名>               # 切换模型
/think [on|off]               # 开关思考过程显示
/ai-think [on|off]            # 开关 AI Thinking Mode
/skill <id>                   # 加载角色 skill
/help                         # 查看完整命令列表
```

## 配置持久化

所有设置（Provider、API Key、Model、偏好）保存在 `.scribe_settings.json`，程序内通过命令修改会自动写入，无需手动编辑 JSON。文件位于脚本同级目录，方便备份或迁移。

## 文件结构

```
scribe/
├── scribe.sh                  # 主程序（单文件）
├── .scribe_settings.json      # 持久化设置（自动生成）
├── .scribe_history/           # 对话存档目录
├── .scribe_cmd_history        # 命令历史
└── .skills/                   # Skill 文件目录
    ├── default-assistant/     # 默认通用助手
    ├── kaltsit-style-reply/   # 示例：凯尔希风格
    └── priestess-style-reply/ # 示例：普瑞赛斯风格
        └── references/        # 附录资料
```

## 协议

MIT License — 详见项目根目录的 LICENSE 文件。

---

> “自动手记人偶”的名称来自《紫罗兰永恒花园》。

## 第三方内容声明

本项目附带的角色 skill 文件涉及《明日方舟》（© Hypergryph / 上海鹰角网络科技有限公司）的角色名称、设定和台词片段。上述内容的知识产权归鹰角网络所有，不包含在本项目的 MIT 许可范围内。Skill 文件的原创表达部分（结构编排、分析性文字、示例对话等）遵循 MIT 协议。

本项目为非商业性粉丝创作，与鹰角网络无关联。

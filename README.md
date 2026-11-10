# DSH 插件管理器

> 给 [DeepSeek Harness](https://github.com/deepseek-ai) 桌面版用的命令行插件管理器：**仪表盘 + 命令操作 + 内置插件市场搜索**，彻底绕开「插件市场装不上」的文件锁问题。

```
  DSH 插件管理器   2026-11-08 13:05
  ----------------------------------------------------------------------------
  #   插件                                         版本          状态
  1   @eddyskywalker/dsh-chatgpt-subscription    0.62.0      未启用
  2   @linxin666/dsh-web-all                     0.4.15      启用
  3   dsh-better-sidebar                         0.30.1      启用
  4   dsh-pet                                    0.4.5       启用  → 0.4.6
  ----------------------------------------------------------------------------
  17 个插件 · 15 启用 · 2 未启用 · 12 个可更新（1 天前检查）

  > i sidebar
```

---

## 为什么需要它

DSH 桌面版的插件市场在 Windows 上有个结构性缺陷：**装一个新插件会触发 pnpm 全量重排（约 347 个包），其中必然要替换两个被占用的文件**：

| 文件 | 谁占着 | 能不能释放 |
|---|---|---|
| `node_modules/electron` | 桌面宠物的 electron 子进程 | 改配置能释放，但要重启 |
| `node_modules/lightningcss-win32-x64-msvc` | **DSH 主进程自己**（原生模块，Node 无法卸载） | 只要 DSH 在跑就永远不能 |

结果就是：

```
[ERR_PNPM_EPERM] [importPackage ...\node_modules\lightningcss-win32-x64-msvc]
EPERM: operation not permitted, rename '..._tmp_3924_1' -> '...'
```

市场提示「文件正被打开着」，安装回滚，重试必现。**这不是某个插件的 bug，是「在进程内替换自己正在用的原生模块」这个动作本身不可能成功。**

本工具的解法很直接：**退出 DSH，在进程外跑 pnpm，再把插件名写进 profile 的 bundles。** 没有任何进程占用文件，安装自然成功。

---

## 特性

- **仪表盘**：一屏看清所有插件的版本、启用状态、可更新标记
- **内置市场搜索**：接入插件市场同款目录（9463 条，4872 个可安装），输关键词就能搜
- **批量操作**：`rm 3,5` 一次卸多个，`u all` 一次全更
- **自动备份**：每次写操作前备份 `package.json` / `pnpm-lock.yaml` / `cordis.patch.yml`
- **自动修 electron**：pnpm 重排会清空 electron 二进制（357 MB），工具检测到会自动用国内镜像补回
- **安全卸载数据**：可选清理插件配置，默认保留，且只移到回收目录不永久删除
- **零依赖**：只用 Windows 自带的 PowerShell 5.1 + Node（DSH 本身就要 Node）

---

## 快速开始

### 1. 下载

```bash
git clone <本仓库地址> %USERPROFILE%\.dsh\tools
```

或者直接下载 ZIP 解压到 `C:\Users\<你>\.dsh\tools`。

### 2. 运行

双击 `插件管理.cmd`，或：

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.dsh\tools\dsh-plugin-manager.ps1"
```

> 为什么需要 `-ExecutionPolicy Bypass`：Windows 默认禁止运行脚本。这一参数只对本次执行生效，不改系统设置。

### 3. 装第一个插件

```
  > i sidebar
```

搜索 → 选序号 → 输 `y` 确认。装完重启 DSH 生效。

---

## 命令

| 命令 | 作用 | 需要退出 DSH |
|---|---|---|
| `i 关键词` | 从插件市场目录搜索并安装 | ✅ |
| `3` 或 `dsh-pet` | 查看插件详情 + 操作菜单（更新 / 卸载 / 打开仓库） | — |
| `u 3` 或 `u dsh-pet` | 更新指定插件 | ✅ |
| `u all` | 更新全部可更新插件（精确版本安装） | ✅ |
| `rm 3,5` | 批量卸载（可选清理配置与数据） | ✅ |
| `start` | 启动 DSH（自动定位安装路径） | ❌ |
| `refresh` | 刷新插件目录缓存（约 60 秒） | ❌ |
| `check` | 立即检查更新（启动时已自动检查，通常不需要） | ❌ |
| `ls` | 重绘仪表盘 | ❌ |
| `help` / `q` | 帮助 / 退出 | — |

> 表中尖括号 `<...>` 表示占位，**实际输入时不要写**。例如搜插件直接输 `i sidebar`，不是 `i <sidebar>`。


**所有写操作都会先检查 DSH 是否完全退出**，没退干净直接拒绝，不会留下半成品。

---

## 内置市场搜索

数据源是 `https://awesome-dsh-plugin.com/plugins.json`——和 DSH 插件市场用的是同一份。

| 项 | 值 |
|---|---|
| 总条目 | 9463 个插件 |
| 可 npm 安装 | 4872 个 |
| 仅 GitHub 发布 | 4591 个（本工具装不了，需要 clone 仓库手动装） |
| 缓存 | `~/.dsh/tools/.cache/`，7 天有效 |
| 索引 | 11 MB JSON → 1.1 MB TSV，搜索 < 0.5 秒 |

```
  > i theme

  找到 20 个结果（目录 2026-11-08 · 共 4872 个可安装）

  [ 1] dsh-theme-aurora                          1.2.0
       极光渐变主题，支持亮暗双模式与自定义强调色…
  [ 2] @someone/dsh-theme-neon                   0.4.1    ★已装
       ...
  输入序号安装（回车取消，k 换关键词）:
```

支持多关键词（空格分隔，AND 匹配）：`i dsh theme`。

---

## 安全设计

考虑到「插件被删光」这类事故，卸载路径做了多重保险。

**数据清理**（`~/.dsh/<插件名>`）：

| 措施 | 说明 |
|---|---|
| 默认保留 | 询问「删除插件数据？」时直接回车 = 不删 |
| 二次确认 | 输 `y` 之后还要手打**完整包名**，输错即放弃 |
| 只移动不删除 | 数据移到 `~/.dsh/_uninstall-trash-时间戳/`，随时取回 |

**配置清理**（`cordis.patch.yml` 里的条目）：

| 措施 | 说明 |
|---|---|
| 精确匹配 | 只删插件自己 `cordis.patch.yml` 里声明过的 id，不靠猜测 |
| 先看再删 | 列出每条 id 和行号范围，确认后才动 |
| **改前校验** | 删除后若其它条目数量/内容不符预期，直接放弃修改 |
| **改后回滚** | 写入后重新读取校验，不对就立刻从备份还原 |
| 独立备份 | 每次修改前生成 `cordis.patch.yml.bak-时间戳` |

实测：46 条配置里删掉 2 条 `web-ui-pet`，其余 44 条一条不少。

**硬编码保护名单**——这些目录永远不会被当作插件数据删除：

```
profiles  storages  skills  logs  dsh-session-archive
dsh-usage  dsh-agents  task-board  bin  cache  node_modules
```

即使插件名撞上这些词，也会被跳过。你的会话记录、聊天历史、技能、profile 配置都在里面。

---

## 环境要求

| 项 | 要求 |
|---|---|
| 系统 | Windows 10 / 11 |
| PowerShell | 5.1（系统自带） |
| Node.js | 任意 LTS（DSH 本身已带） |
| pnpm | 需在 PATH 中，缺失时执行 `npm install -g pnpm` |
| DSH | 0.2.x（profile 结构为 `dependencies` + `dsh.profile.bundles`） |

在 DSH Desktop `0.2.2-rc.1` + Windows 11 + PowerShell 5.1 上测试。

---

## 常见问题

<details>
<summary><b>装完 DSH 启动卡在 "Downloading Electron binary"</b></summary>

pnpm 重排清空了 electron 二进制。工具会自动修复；手动修：

```powershell
cd "$env:USERPROFILE\.dsh\profiles\desktop\node_modules\electron"
$env:ELECTRON_MIRROR = "https://npmmirror.com/mirrors/electron/"
$env:ELECTRON_CUSTOM_DIR = "{{ version }}"
node install.js
```
</details>

<details>
<summary><b>启动报 "Unexpected token ... is not valid JSON"</b></summary>

`package.json` 被写入了 UTF-8 BOM。PowerShell 5.1 的 `Set-Content -Encoding UTF8` 会加 BOM，本工具已改用 `[System.IO.File]::WriteAllText(..., UTF8Encoding($false))` 规避。

如果已经出现，手动去 BOM：

```powershell
$p = "$env:USERPROFILE\.dsh\profiles\desktop\package.json"
$t = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($false)))
```
</details>

<details>
<summary><b>启动报 "desktop welcome: Web authentication failed"</b></summary>

Electron 会话数据损坏，与插件无关。重命名应用数据目录后重启：

```powershell
Rename-Item "$env:APPDATA\@deepseek-ai\dsh-desktop" "dsh-desktop.bak"
```

任务数据在 `~/.dsh` 不受影响，但需要重新登录 DSH 账号。
</details>

<details>
<summary><b>搜到了插件但装不上</b></summary>

看包名前面有没有 npm 字段。目录里 4591 个插件**只在 GitHub 发布**，没有 npm 包，本工具装不了——索引已经过滤掉它们，如果你在市场上看到了却搜不到，多半是这个原因。
</details>

<details>
<summary><b>能用在别的 profile 上吗</b></summary>

可以：

```powershell
.\dsh-plugin-manager.ps1 -Profile web
```
</details>

---

## 目录结构

```
.dsh/tools/
├── 插件管理.cmd              # 双击入口
├── dsh-plugin-manager.ps1    # 主程序
├── lib/
│   ├── catalog.ps1           # 目录下载 / 缓存 / 搜索
│   └── build-index.js        # 生成 TSV 搜索索引
├── docs/
│   └── 使用说明.md            # 完整教程（含手动步骤、错误对照表）
├── legacy/                   # v1 单功能脚本，已废弃
└── .cache/                   # 目录缓存（自动生成）
```

---

## 免责声明

本工具直接修改 DSH profile 的 `package.json` 与 `node_modules`。**每次写操作前都会自动备份**（`_install-backup-时间戳/`），但请自行评估风险。建议先在虚拟机或非主力环境验证。

插件本身的质量、安全性与兼容性由各插件作者负责，与本工具无关。

---

## License

[MIT](LICENSE)

---

<sub>English: A CLI plugin manager for DeepSeek Harness desktop on Windows. Works around the `EPERM` file-lock failure that makes the in-app plugin market unable to install anything, by running `pnpm` outside the DSH process. Includes a dashboard, batch operations, and built-in search over the community plugin catalog (9463 entries). Requires PowerShell 5.1 and Node.js.</sub>

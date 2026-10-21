# Neat Download Manager 中文汉化（Windows / 纯 PowerShell）

> 给 [Neat Download Manager](https://www.neatdownloadmanager.com)（简称 NDM）Windows 版做简体中文界面汉化的补丁脚本。
> 不需要安装 Python 或任何运行时，Windows 自带 PowerShell 即可运行。

---

## 为什么需要这个补丁

NDM 体积只有 0.87 MB，是 IDM 的极佳免费替代品（多线程分段、断点续传、浏览器接管）。
但它**官方只有英文界面**，而且**没有任何语言机制**：

| 检查项 | 结果 |
|---|---|
| PE 资源中的 `RT_STRING` / `RT_DIALOG` / `RT_MENU` | 全部不存在 |
| 唯一的自定义资源 `RC_DATA` | 是内嵌的 SQLite 模板库，不是语言包 |
| 界面文字存放方式 | 约 200 条 **UTF-16LE 字符串硬编码在 `.rdata` 段**，UI 完全自绘 |
| 数字签名 | `NotSigned`（所以改完不会出现签名失效问题） |

结论：**不可能通过配置文件或语言包换语言，只能原地修改 `NeatDM.exe` 里的字符串常量。**

本脚本就是把这件事件做得安全、可回滚、可维护。

---

## 汉化原理

1. 把 `NeatDM.exe` 读进内存，按 `原文 + \x00\x00`（UTF-16LE 空终止符）**精确匹配**定位；
   - 加终止符是为了避免把 `Download` 误伤到 `Download Completed` 内部。
2. 用中文的 UTF-16LE 字节替换；
3. 中文比原文短时，多余位置补 `\x00`；**中文比原文长时直接跳过**（绝不撑爆原位置）；
4. 因此**文件总长度永远不变**，PE 节表、资源目录、代码段都不受影响；
5. 替换前自动备份原版，随时可一键还原。

> 小知识：C++ 编译器会把相同字符串字面量合并到同一块内存，所以程序内部做逻辑比较用的
> `"Complete"` 和界面上显示的 `"Complete"` 是**同一份常量**。汉化后两者一起变成中文，
> 比较逻辑依然一致——这也是这套方案能安全工作的关键。

---

## 支持版本

| 项目 | 说明 |
|---|---|
| 目标版本 | **NDM 1.4.24 (Windows)** |
| 系统 | Windows 10 / 11（32 / 64 位均可） |
| 权限 | **管理员**（需要写入 `Program Files`） |
| 依赖 | 无（Windows PowerShell 5.1 或 PowerShell 7 均可） |
| 词条数 | 178 条，覆盖主窗口、设置页、下载窗口、属性、关于、浏览器扩展等 |

其他 1.4.x 版本理论上可用：脚本用**动态字符串查找**而非固定偏移，
新版里不存在的词条会被自动跳过并报告，不会损坏文件。

---

## 快速开始

### 1. 下载

```powershell
git clone <本仓库地址>
cd <仓库目录>
```

或直接下载 `Invoke-NDMzhPatch.ps1` 和 `translations.json`（两个文件必须放在同一目录）。

### 2. 以管理员身份打开 PowerShell

开始菜单搜索 `PowerShell` → 右键 → **以管理员身份运行**。

### 3. 先预演（可选，推荐）

```powershell
.\Invoke-NDMzhPatch.ps1 -Action DryRun
```

这一步**不修改任何文件**，只告诉你：能替换多少条、哪些中文过长会被跳过、哪些词条在你这版 exe 里不存在。

### 4. 执行汉化

```powershell
.\Invoke-NDMzhPatch.ps1
```

脚本会自动：检查权限 → 定位 NDM → 关闭正在运行的 NDM → 备份原版 → 替换 → 校验长度 → 重新启动 NDM。

如果提示脚本被禁止运行，先执行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

---

## 参数说明

| 参数 | 说明 |
|---|---|
| `-Action Install` | 汉化（默认） |
| `-Action Restore` | 从备份还原英文原版 |
| `-Action DryRun` | 预演，只统计不写文件 |
| `-Action Status` | 查看当前版本、是否已汉化、备份情况、运行状态 |
| `-ExePath "D:\xxx\NeatDM.exe"` | 手动指定路径（装在非默认位置时用） |
| `-Force` | 不询问，自动关闭正在运行的 NDM |
| `-NoRestart` | 汉化后不自动启动 NDM |

### 常用示例

```powershell
# 查看状态
.\Invoke-NDMzhPatch.ps1 -Action Status

# 静默汉化并关闭/重启 NDM
.\Invoke-NDMzhPatch.ps1 -Force

# 还原英文
.\Invoke-NDMzhPatch.ps1 -Action Restore

# 自定义安装路径
.\Invoke-NDMzhPatch.ps1 -ExePath "E:\Apps\Neat Download Manager\NeatDM.exe"
```

---

## 备份与还原

* **原版备份**：`%LOCALAPPDATA%\NDMzhPatch\backup\NeatDM.exe.orig`
* **最近一次替换报告**：`%LOCALAPPDATA%\NDMzhPatch\backup\last-report.txt`

还原方式（任选其一）：

1. `.\Invoke-NDMzhPatch.ps1 -Action Restore`
2. 手工把 `NeatDM.exe.orig` 复制回去覆盖 `NeatDM.exe`
3. 从官网重新安装 NDM（会覆盖汉化版）

> 备份**只在第一次运行时创建**，之后不会被覆盖。所以即使反复运行补丁，
> 手里始终留着真正的英文原版。

---

## 汉化后你要设的东西（顺便说说）

汉化只是让界面看得懂。如果你和我一样只需要"简单多线程下载"，设置页（`设置` → `常规`）就两项关键：

| 界面 | 建议 |
|---|---|
| **每个下载最大连接数** | 填 `32`（NDM 上限是 32；旁边的"推荐 8 个连接"只是建议值） |
| **同时创建所有附加连接** | **选中**它（另一项"逐一创建"是逐个追加，起速慢） |
| **单个下载带宽限制 (KB/s)** | 留空或 `0` = 不限速 |
| **下载目录 / 临时目录** | 建议改到非系统盘，且两者在同一磁盘 |

浏览器接管只需点工具栏的 `浏览器` → 按提示给 Chrome / Edge / Firefox 装扩展。

---

## 已知限制

1. **错误信息保留英文** — 如 `Connection TimeOut.`、`Failed to Start DownloadEngine.`。
   这类提示通常只在排查故障时才出现，保留英文更利于搜索定位；需要的话可以在
   `translations.json` 里自行补充词条。
2. **个别按钮文字会被轻微挤压** — NDM 的按钮宽度是按英文长度写死的，
   例如 `Reset → 重置` 两个字会挤在一起。这是布局问题，改字无法解决（换成单字可缓解）。
3. **NDM 升级会覆盖汉化** — 每次更新后需要重新运行脚本。词条缺失会自动报告，不会损坏文件。
4. **杀毒软件可能误报** — 任何修改 exe 的行为都可能被启发式引擎标记，可加入信任。
5. **会被翻译的"分类名"** — `压缩包 / 音频 / 视频 / 文档 / 应用程序 / 杂项` 同时是分类文件夹名和
   数据库 `category` 字段值。汉化后**新建任务会使用中文分类**，而汉化前已存在的老任务
   可能不显示在对应分类下（只影响历史任务，不影响下载本身）。

---

## 参与贡献

翻译表是独立的 `translations.json`，按窗口分组，结构很简单：

```json
{
  "translations": {
    "设置窗口": {
      "Max Connections per Download": "每个下载最大连接数"
    }
  }
}
```

改词条只需编辑它，然后重新运行脚本即可生效。

**两条硬性规则：**

1. **英文键必须和 exe 里完全一致**，包括首尾空格和标点。
   例如 `Default User-Agent ` 末尾那个空格不能丢，否则匹配不到。
   不确定的话，用下面这段命令把 exe 里的字符串全导出来看：

   ```powershell
   $b = [IO.File]::ReadAllBytes("C:\Program Files (x86)\Neat Download Manager\NeatDM.exe")
   $s = $b -join ''   # 简化写法，实际见 scripts/dump-strings.ps1
   ```

   仓库里提供了 `scripts/dump-strings.ps1`，可直接导出全部 UTF-16 字符串供对照。

2. **中文不能比英文长**（UTF-16 字节数 ≤ 原文字节数，含终止符）。
   太长会被自动跳过，并在输出里提示。

---

## 与上游项目的关系

本项目的 Windows 实现思路与翻译表参考了：

* **[qiqi258/NeatDownloadManager-zh](https://github.com/qiqi258/NeatDownloadManager-zh)** — Windows 版汉化（Python 实现）
* **[hardwin2023/NeatDownloadManager-zh](https://github.com/hardwin2023/NeatDownloadManager-zh)** — macOS 版汉化（NIB 补丁）

在此基础上做了这些改进（不重复造轮子，只补对方的坑）：

| 改进 | 说明 |
|---|---|
| **不依赖 Python** | 纯 PowerShell，Windows 开箱即用；用 Latin1 映射做字节查找，1.7 MB 文件全量替换只需 1～2 秒 |
| **修正 8 条匹配不到的键** | 上游词条如 `Download Directory` 实际在 exe 里是 `Download Directory `（带尾空格），导致**下载目录这一整项漏翻**；本项目按真实形态修正 |
| **补充 7 条遗漏项** | `Video`（分类树）、`Yes`、`User`（列头）、`OK`、`(Editable)`、端口占用提示等 |
| **先写临时文件再替换** | 避免写入中途失败留下半个坏文件 |
| **幂等 + 自动跳过** | 重复运行、版本不匹配都只报告不破坏 |
| **`-Action DryRun / Status`** | 改之前能先看清楚会发生什么 |
| **备份只创建一次** | 反复运行也不会把"已汉化版"误当原版备份 |

---

## 免责声明

* 本项目**不包含** Neat Download Manager 本体，NDM 版权归原作者 Javad Motallebi 所有。
* 修改可执行文件属于个人使用范畴，请自行评估风险；本脚本会完整备份并支持一键还原。
* 请支持原作者，官网：<https://www.neatdownloadmanager.com>

## 许可证

[MIT](LICENSE)

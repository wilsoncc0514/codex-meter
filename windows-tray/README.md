# Windows 任务栏 Codex Meter

BAT 启动，使用 Windows 自带 PowerShell / WinForms，保持任务栏背景融合和两行文字。平时常驻 5 小时额度；每 5 分钟联网刷新成功后，周额度和重置卡各展示 6 秒，再回到 5 小时额度并停止轮播。手动刷新成功也触发一次展示：

- 5 小时剩余额度 + 重置倒计时
- 周剩余额度 + 重置倒计时
- 重置卡可用次数 + 最近到期倒计时

悬停暂停自动轮播；左键或鼠标滚轮切页。右键中文菜单包含立即刷新、额度和重置卡明细、自动轮播开关、打开错误日志、退出。明细列出各张卡的本地到期时间，次数以服务端 availableCount 为准。未知与 0 次分开显示；明细缺失会明确提示。只展示，不兑换重置卡。

## 启动

双击 start-widget.bat；停止使用右键“退出”或 stop-widget.bat。
当前用户登录启动项会自动注册。守护脚本在组件意外退出后 3 秒重启；主动退出保留开机启动项。

## 数据与响应

优先使用本机 codex.exe 的 App Server，通过 account/rateLimits/read 联网获取额度和 rateLimitResetCredits。优先读取 rateLimitsByLimitId.codex 聚合额度，不混入特定模型额度。

App Server 自身使用现有登录状态。Windows 组件不直接读取认证文件，也不从 sessions / JSONL / 本地额度缓存回退。App Server 查询失败显示超时。

查询在独立 PowerShell runspace 中执行，界面无需等待网络。每次只允许一个请求；默认每 300 秒查询，超时 15 秒。失败显示“超时”，停止轮播并隐藏旧额度和旧重置卡次数。状态保存或通知失败不会被误报为联网失败。

通知图标由 UI 统一持有并清理，修复原先定时器回调作用域丢失导致的连续空值异常。重置通知需观察到新的重置周期，避免只因时间经过就误报。

## 配置

taskbar-widget.json：

- rotateSeconds：分页间隔，3–60 秒，默认 6
- autoRotate：刷新后轮播；也可从右键菜单保存开关。手动切页仍可使用，看完后自动回到 5 小时页
- appServerPath：可选 codex.exe 完整路径；空值通过 PATH 查找
- refreshSeconds：联网刷新间隔，30–3600 秒
- requestTimeoutSeconds：单路径超时，5–60 秒
- width：文字区域宽度，120–220
- gap、xOffset、yOffset：任务栏位置微调
- notifyOnReset：额度恢复通知开关

编辑文件后重启组件。

## 日志与测试

日志：%LOCALAPPDATA%\\CodexMeter\\logs\\taskbar-widget.log，1 MB 轮换。
日志只记录来源、窗口数、重置卡次数和错误；不记录令牌或服务端原始响应。

运行 powershell.exe -NoProfile -ExecutionPolicy Bypass -File windows-tray/test-quota.ps1 进行离线解析和显示测试；增加 -Live 做只读联网测试。

2026-09-05 验证：Windows PowerShell 5.1 离线测试通过；真实 App Server 返回两个窗口、2 次重置卡和两条明细；后台组件查询成功。Computer Use 未枚举到工具窗口，真实鼠标滚轮、悬停与菜单交互尚未自动验收。

设计参考本地 wilson-codex-meter 0.4.2 的分页状态栏与重置卡明细；Windows 实现独立于 macOS Swift UI。
协议依据：https://learn.chatgpt.com/docs/app-server

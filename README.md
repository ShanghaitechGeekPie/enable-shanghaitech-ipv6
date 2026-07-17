# 上海科技大学校园网 IPv6 配置 Skill

这是一个面向上海科技大学校园网的 Codex skill，用于让已经获得校园 IPv6 地址的 Windows 或 Linux 设备进一步完成路由配置并验证公网 IPv6 连通性。

## 使用前提

- 设备直接连接上海科技大学校园网。
- 设备已经通过 DHCPv6 等校园网机制获得 `2001:da8:...` 全局 IPv6 地址。
- 本项目不负责申请 DHCPv6 地址，也不用于配置 OpenWrt 下游设备、前缀委派或 NAT66。

校园网可能已经分配 IPv6 地址，但没有可供普通应用使用的通用 IPv6 默认路由。已验证的校园网链路本地网关为：

```text
fe80::200:5eff:fe00:101
```

不同接入位置的网关可能变化，因此脚本会优先自动发现路由器，只在邻居发现确认成功后使用上述地址作为回退值。

## 文件结构

```text
enable-shanghaitech-ipv6/
├── SKILL.md
├── README.md
├── agents/openai.yaml
└── scripts/
    ├── configure-windows.ps1
    └── configure-linux.sh
```

## Windows

先运行只读诊断：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\configure-windows.ps1
```

如果脚本确认缺少默认路由，以管理员 PowerShell 执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\configure-windows.ps1 -Apply
```

Windows 验收命令：

```powershell
curl.exe -6 http://ipv6.test-ipv6.com/
```

必须使用 `curl.exe`，避免旧版 Windows PowerShell 将 `curl` 解析成 `Invoke-WebRequest` 别名。

## Linux

依赖 `bash`、`iproute2`、`getent` 和 `curl`。先运行只读诊断：

```bash
bash scripts/configure-linux.sh
```

如果脚本确认缺少默认路由，以 root 权限执行：

```bash
sudo bash scripts/configure-linux.sh --apply
```

Linux 验收命令：

```bash
curl -6 http://ipv6.test-ipv6.com/
```

## 持久化

脚本默认只添加活动路由，断开网络或重启后可能消失。这样可以避免同一网卡连接其他网络时继续使用校园网的链路本地网关。

只有明确需要时才启用持久化：

```powershell
# Windows
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\configure-windows.ps1 -Apply -Persist
```

```bash
# Linux，仅支持由 NetworkManager 管理的活动连接
sudo bash scripts/configure-linux.sh --apply --persist
```

## 安全行为

- 不修改 IPv4 路由、DNS、系统代理、防火墙或其他网络接口。
- 验收时仅为当前 `curl` 进程绕过代理，不永久修改代理设置。
- 添加链路本地网关时始终绑定明确的网络接口。
- 新增路由后若 IPv6 验收失败，自动回滚该路由。
- 多个校园 IPv6 接口并存时停止执行，要求显式指定接口。

## 背景资料

实现思路参考了[上海科技大学校园网 OpenWrt 配置指南](https://youyou.moe/2026/05/openwrt-shanghaitech-guide/)，但本项目只实现直接连接校园网的 Windows/Linux 主机配置，不照搬 OpenWrt 的 LAN、ULA 和 NAT66 配置。

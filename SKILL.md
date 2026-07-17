---
name: enable-shanghaitech-ipv6
description: Make an existing ShanghaiTech campus DHCPv6 address usable for outbound IPv6 on Windows or Linux by diagnosing the selected interface, discovering the link-local campus gateway, adding a missing general IPv6 default route, and validating with curl over IPv6. Use when a directly connected campus device already has a DHCPv6 global address (normally 2001:da8:...) but IPv6 Internet access or curl -6 fails. Do not use to obtain the DHCPv6 lease, configure OpenWrt LAN prefix delegation, or build NAT66.
---

# Enable ShanghaiTech IPv6

Treat a global DHCPv6 address as a strict prerequisite. Configure only the host that is directly connected to the campus network. The campus does not delegate a prefix, and its link uses a source-specific/default route through a link-local router; a host does not need the OpenWrt guide's ULA, RA server, or NAT66 steps.

## Workflow

1. Detect the operating system. Support Windows and Linux only.
2. Run the matching script without its apply flag. It identifies a `2001:da8:...` address, interface, existing IPv6 default route, verifies that the test destination resolves through that interface, and runs a proxy-safe direct IPv6 test.
3. Stop if no global DHCPv6 address exists. Do not attempt DHCPv6 acquisition because the lease is this skill's prerequisite.
4. If the script reports success, make no network changes.
5. If it reports a missing default route, rerun it with elevated privileges and its apply flag.
6. Do not persist the route unless the user explicitly requests persistence. A persistent link-local gateway can break IPv6 when the same interface is used on another network.
7. Require the platform-specific acceptance command to exit zero.

## Windows

Use [scripts/configure-windows.ps1](scripts/configure-windows.ps1):

```powershell
powershell -ExecutionPolicy Bypass -File scripts/configure-windows.ps1
# If it identifies a missing route, rerun from an elevated PowerShell:
powershell -ExecutionPolicy Bypass -File scripts/configure-windows.ps1 -Apply
```

Use `-Persist` only when explicitly requested. Use `-InterfaceIndex` or `-Gateway` only to resolve an ambiguity that the script reports; never guess an interface index.

Use this Windows acceptance command. Keep the `.exe` suffix so Windows PowerShell cannot resolve `curl` to its historical `Invoke-WebRequest` alias:

```powershell
curl.exe -6 http://ipv6.test-ipv6.com/
```

Historical evidence on the validated machine shows that this command caused Windows to acquire the address and automatic routes:

```powershell
netsh interface ipv6 set address "<interface>" dhcp
```

Do not run it as part of this skill because acquisition is a prerequisite. If the address exists but the automatic route did not appear, add only `::/0` through the discovered link-local router.

## Linux

Use [scripts/configure-linux.sh](scripts/configure-linux.sh):

```bash
bash scripts/configure-linux.sh
# If it identifies a missing route:
sudo bash scripts/configure-linux.sh --apply
```

Use `--persist` only when explicitly requested. Persistence is supported only for an active NetworkManager connection; otherwise leave the verified route in the active routing table and report that the script must be rerun after reconnect.

Use this Linux acceptance command:

```bash
curl -6 http://ipv6.test-ipv6.com/
```

## Guardrails

- Preserve IPv4 routes, DNS, proxy configuration, firewall rules, Router Discovery, and other interfaces.
- Prefer an existing default route or a neighbor marked as a router. Use `fe80::200:5eff:fe00:101` only as the campus fallback confirmed by the source article and local packet capture, and only if neighbor discovery resolves it on the selected interface.
- Treat link-local gateways as interface-scoped. Never add one without the selected interface.
- Roll back a route created by the script if the final IPv6 test fails.
- Do not apply OpenWrt NAT66 instructions to a directly connected Windows or Linux host.
- Proxy variables can make `curl -6` try to reach an IPv4-only proxy. Set `NO_PROXY` only for the test process; do not persistently alter user proxy settings.
- Treat DHCPv6 as a caller-provided prerequisite. Windows may report a usable campus address with `PrefixOrigin=RouterAdvertisement`; do not reject it or claim that origin metadata proves how the lease was acquired.

## Success

Report the chosen interface, DHCPv6 address, effective `::/0` next hop, whether a route was changed, whether it is active or persistent, and the exit status of the matching command:

```powershell
# Windows
curl.exe -6 http://ipv6.test-ipv6.com/
```

```bash
# Linux
curl -6 http://ipv6.test-ipv6.com/
```

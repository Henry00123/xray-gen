# xray-gen

Xray-core 安装、配置管理与状态监测脚本（基于 Bash + jq）。

## 安装并使用

默认安装到 `/usr/local/bin/xray_gen`，之后在任意目录直接运行 `xg` 即可。

使用 `curl` 安装并运行（非 root 用户请在 `curl` 和 `chmod` 前分别加 `sudo`）：

```bash
curl -fsSL https://raw.githubusercontent.com/Henry00123/xray-gen/main/xray_gen.sh -o /usr/local/bin/xg && chmod +x /usr/local/bin/xg && xg
```

或使用 `wget` 安装并运行：

```bash
wget -qO /usr/local/bin/xray_gen https://raw.githubusercontent.com/Henry00123/xray-gen/main/xray_gen.sh && chmod +x /usr/local/bin/xg && xg
```

> 默认管理的配置文件路径为 `/usr/local/etc/xray/config.json`（与官方 `XTLS/Xray-install` 安装路径一致，支持通过 `-c` / `-o` 指定其他路径）。缺少 `jq` 等依赖时，交互模式下会提示一键自动安装。


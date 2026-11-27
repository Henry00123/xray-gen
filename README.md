# xray-gen

Xray-core 安装、配置管理与状态监测脚本（基于 Bash + jq）。

## 安装并使用

默认安装到 `/usr/local/bin/xray_gen`，之后在任意目录直接运行 `xray_gen` 即可。

使用 `curl` 安装并运行（非 root 用户请在 `curl` 和 `chmod` 前分别加 `sudo`）：

```bash
curl -fsSL https://raw.githubusercontent.com/Henry00123/xray-gen/main/xray_gen.sh -o /usr/local/bin/xray_gen && chmod +x /usr/local/bin/xray_gen && xray_gen
```

或使用 `wget` 安装并运行：

```bash
wget -qO /usr/local/bin/xray_gen https://raw.githubusercontent.com/Henry00123/xray-gen/main/xray_gen.sh && chmod +x /usr/local/bin/xray_gen && xray_gen
```

> 默认管理的配置文件路径为 `/usr/local/etc/xray/config.json`（与官方 `XTLS/Xray-install` 安装路径一致，支持通过 `-c` / `-o` 指定其他路径）。缺少 `jq` 等依赖时，交互模式下会提示一键自动安装。

## 常用命令

```bash
# 打开交互式主菜单（管理 /usr/local/etc/xray/config.json）
xray_gen

# 指定其他配置文件路径
xray_gen -c ./config.json

# 查看当前配置文件摘要
xray_gen -s

# 将第 2 条出站切换为默认主出站
xray_gen --out-index 2

# 安装 / 更新 Xray（官方 install-release.sh）
xray_gen --install-xray
xray_gen --install-xray --xray-user root

# 查看 Xray 运行状态、监听端口与最近日志
xray_gen --status

# 启停 / 重启 Xray 服务
xray_gen --restart

# 检查并更新本脚本到最新版本
xray_gen -u

# 通过镜像/自定义地址更新脚本
xray_gen -u --update-url "https://你的镜像地址/xray_gen.sh"

# 查看全部参数帮助
xray_gen -h
```

# xray-gen

Xray-core 配置生成与修改脚本（基于 Bash + jq）。

## 下载并使用

使用 `curl` 下载并运行：

```bash
curl -fsSL https://raw.githubusercontent.com/Henry00123/xray-gen/main/xray_gen.sh -o xray_gen.sh && chmod +x xray_gen.sh && ./xray_gen.sh
```

或使用 `wget` 下载并运行：

```bash
wget -qO xray_gen.sh https://raw.githubusercontent.com/Henry00123/xray-gen/main/xray_gen.sh && chmod +x xray_gen.sh && ./xray_gen.sh
```

> 运行配置管理功能前需确保系统已安装 `jq`。

## 常用命令

```bash
# 交互式生成或修改当前目录的 ./config.json
./xray_gen.sh

# 查看当前配置文件摘要
./xray_gen.sh -s

# 将第 2 条出站切换为默认主出站
./xray_gen.sh --out-index 2

# 安装 / 更新 Xray（官方 install-release.sh）
./xray_gen.sh --install-xray
./xray_gen.sh --install-xray --xray-user root

# 查看 Xray 运行状态、监听端口与最近日志
./xray_gen.sh --status

# 启停 / 重启 Xray 服务
./xray_gen.sh --restart

# 检查并更新脚本到最新版本
./xray_gen.sh -u

# 通过镜像/自定义地址更新脚本
./xray_gen.sh -u --update-url "https://你的镜像地址/xray_gen.sh"

# 查看全部参数帮助
./xray_gen.sh -h
```

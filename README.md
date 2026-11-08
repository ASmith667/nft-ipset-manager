# nftables set IP 白名单管理脚本

适用于 Debian 11 / Debian 12 / Debian 13 的 nftables IP/CIDR 白名单管理脚本。

## 使用

推荐一键命令：

```bash
sudo mkdir -p /root/1 && sudo curl --fail --location --proto '=https' --output /root/1/nft-ipset-manager-v8.sh https://raw.githubusercontent.com/ASmith667/nft-ipset-manager/main/nft-ipset-manager-v8.sh && sudo chmod 700 /root/1/nft-ipset-manager-v8.sh && sudo bash -n /root/1/nft-ipset-manager-v8.sh && sudo bash /root/1/nft-ipset-manager-v8.sh
```

它会依次执行：

1. 创建 `/root/1`；
2. 从 GitHub 下载最新脚本；
3. 保存为 `/root/1/nft-ipset-manager-v8.sh`；
4. 设置权限为 `700`；
5. 执行 Bash 语法检查；
6. 语法正确后启动脚本菜单。

再次更新并启动使用：

```bash
sudo curl --fail --location --proto '=https' --output /root/1/nft-ipset-manager-v8.sh https://raw.githubusercontent.com/ASmith667/nft-ipset-manager/main/nft-ipset-manager-v8.sh && sudo chmod 700 /root/1/nft-ipset-manager-v8.sh && sudo bash -n /root/1/nft-ipset-manager-v8.sh && sudo bash /root/1/nft-ipset-manager-v8.sh
```

更新时只替换脚本文件，不会删除 `/root/1` 中已经生成的：

```text
groups/
groups.tsv
config.conf
wl/
bd/
nft/
```

如果你已经设置了快捷命令如 `nf`，以后直接运行：

```bash
nf
```

即可打开菜单。

## 重要说明

脚本会在自己的 `table inet ipmgr` 中管理规则，不负责管理 UFW、Docker、云安全组或其他 nftables 表。

运行时产生的 `groups/`、`groups.tsv`、`config.conf`、`wl/`、`bd/` 和 `nft/` 数据不应提交到公开仓库。

## 许可证

本项目采用 GNU General Public License v3.0（GPL-3.0）。完整条款见仓库根目录的 `LICENSE` 文件。

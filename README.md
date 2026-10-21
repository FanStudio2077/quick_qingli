# qingli 安装与服务脚本

本仓库**只包含安装/运维脚本**，不含 qingli 的程序源码。适用于已经拿到 `qingli` 可执行文件（或自行从源码构建好）的场景。

包含：

| 文件 | 作用 |
|---|---|
| `install.sh` | 一键安装 / 卸载：装二进制、生成令牌、渲染 systemd 单元、触发首扫 |
| `deploy/qingli-ctl` | 日常管理命令：状态、信息、启停、重启、日志、立即扫描 |
| `deploy/qingli-web.service` | Web 管理界面（默认仅监听 127.0.0.1） |
| `deploy/qingli-watch.service` | fanotify 实时变更监听（需要 CAP_SYS_ADMIN） |
| `deploy/qingli-scan.service` / `.timer` | 全量扫描（一次性任务 + 每日定时器） |
| `deploy/qingli.toml.example` | 参数与取舍说明（配置参考，非解析文件） |

## 环境要求

- Linux，推荐有 systemd（无 systemd 也能装，只是不会自动启服务）
- root（要写 `/usr/local/bin`、`/etc/systemd/system`）
- `qingli` 二进制（本仓库不提供源码；用 `--bin` 指定路径）

## 安装

```bash
git clone <this-repo> && cd <this-repo>

# 必须用 --bin 指定已编译好的 qingli
sudo bash install.sh --root /data --bin /path/to/qingli
```

常用参数：

```bash
sudo bash install.sh --root /data --bin ./qingli      # 指定扫描根
sudo bash install.sh --port 9000 --bin ./qingli       # 指定端口（被占用会自动顺延）
sudo bash install.sh --no-first-scan --bin ./qingli   # 装完不立即扫描
sudo bash install.sh --force --bin ./qingli           # 强制重新生成令牌
```

不指定 `--root` 时，会自动选择**容量最大的可写真实挂载点**
（只考虑 ext2/3/4、xfs、btrfs、f2fs、zfs、vfat、nfs、cifs，排除 `/proc`、`/sys`、squashfs、只读挂载）。

安装后会打印带令牌的直接访问地址，例如：

```
http://127.0.0.1:8686/?token=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

## 安装后的常用命令

```bash
qingli-ctl status                  # 各单元状态 + 最近快照摘要
qingli-ctl info                    # 路径、库大小、端口、令牌、可点 URL
qingli-ctl restart web             # 重启界面
qingli-ctl stop all                # 全部停止
qingli-ctl start all               # 全部启动
qingli-ctl start watch             # 开启实时监听
qingli-ctl scan-now                # 立即后台全量扫描
qingli-ctl logs web -f             # 跟随日志
qingli-ctl token                   # 打印令牌（给脚本用）
qingli-ctl url                     # 打印访问地址（给脚本用）
```

`target` 可选：`web` / `watch` / `scan` / `timer` / `all`。

## 安全默认值

- Web **只监听 `127.0.0.1`**；远程请用 SSH 隧道：
  `ssh -L 8686:127.0.0.1:8686 user@server`
- 访问令牌写在 `/etc/qingli/web.env`，权限 **0600**。
- 若要用 `--bind 0.0.0.0` 对外，程序会**强制要求** `--token`，否则拒绝启动。
- 界面里的删除默认**移入回收站**（`<root>/.qingli-trash`），可恢复；彻底删除需显式选择，
  并可用 `--allow-purge 0` 在服务端整体禁用。

## 卸载

```bash
sudo bash install.sh --uninstall            # 停服务、删单元与二进制，保留配置与数据
sudo bash install.sh --uninstall --purge    # 连 /etc/qingli 与 /var/lib/qingli 一起删
```

## 安装后的文件布局

| 路径 | 内容 |
|---|---|
| `/usr/local/bin/qingli` | 主程序 |
| `/usr/local/bin/qingli-ctl` | 管理命令 |
| `/etc/qingli/install.conf` | 扫描根 / 端口 / 库路径 |
| `/etc/qingli/web.env` | 访问令牌（0600） |
| `/var/lib/qingli/qingli.db` | 建档库（SQLite WAL） |
| `/var/lib/qingli/snapshot.spool` | 最近一次扫描的 spool |
| `/etc/systemd/system/qingli-*.service`、`qingli-scan.timer` | 服务单元 |

## 兼容性

脚本通过固定的命令行接口调用 `qingli`（`scan` / `import` / `serve` / `watch` / `top` / `version`），
请确保二进制版本与脚本同期。若二进制缺少某个子命令，`install.sh` 会在安装前用 `qingli version`
做一次可执行性校验并直接报错。

# 服务器月度出向流量限制 — 部署说明

> **部署记录（2026-10-30）**
> - 目标服务器：`<已脱敏>`（Ubuntu 22.04.5 LTS，root）
> - 公网网卡：`ens3`（公网 IP `<已脱敏>`，NAT 环境）
> - 阈值：`190 GB/月`（香港属非中国内地，免费额度 200GB，留 10GB 余量）
> - 脚本：`/usr/local/bin/traffic_limit.sh`
> - cron：每 5 分钟检查（已移除每月 1 号 00:01 的 vnstat reset 任务，改用跨月自愈）
> - 断流/恢复功能已实测通过（断流出向 ping 100% 丢包，恢复后 0% 丢包）
> - **跨月自愈（2026-10-30 17:25）**：脚本用 `/var/run/traffic_limit_month` 记录上次运行月份，每次运行比对当前月份，发现跨月即自动清理上月断流规则并解除断流。因此不依赖每月 1 号 00:01 是否在线，只要下次开机/cron 触发即自动纠正。
> - **SSH 后门修复（2026-10-30 17:45）**：首次断流测试时发现致命缺陷——断流规则 `-o ens3 DROP` 会把 SSH 管理流量一并拦截，导致断流后无法远程登录、锁死服务器。已修复：断流链先 `RETURN` 放行 SSH 22 端口（dpt+spt）再 DROP 其余，断流后仍可远程管理。实测：断流时 ping/curl 100% 被拦，SSH 会话全程不断。
> - **Bug 修复（2026-10-30 17:20）**：原脚本用 `date '+%b'` 匹配 vnstat 月份缩写，但 vnstat 2.9 输出为 `2026-10` 数字格式，导致永远匹配失败、脚本一直误报"无数据"而跳过判断。已改用 `vnstat --oneline`（分号分隔、字段14为当月tx）重写读取逻辑，验证 tx 值与 vnstat 官方显示完全一致。

## 一、背景与口径

阿里云 CDT 公网流量免费额度为 **220 GB/月**（中国内地 20GB + 非中国内地 200GB），
**只计「出方向」流量（服务器 → 互联网），入方向流量不计费**。

因此脚本只需统计并限制网卡**出方向(tx)**流量即可。香港等非中国内地地域免费额度为 200GB，建议阈值设为 190GB 留出余量。

> 补充：CDT 2.0 升级（2026-05-20 起）仅做商品/计费项合并，目录价、免费额度、阶梯规则均不变，对本方案无影响。

## 二、安装依赖

```bash
# CentOS / RHEL / Rocky
yum install -y vnstat iptables-services

# Ubuntu / Debian
apt-get update && apt-get install -y vnstat iptables
```

## 三、初始化 vnstat（务必先确认网卡名）

```bash
# 1. 查看网卡名
ip -o link show | awk -F': ' '{print $2}'

# 2. 假设网卡为 eth0，添加监控并启用
systemctl enable --now vnstat
vnstat -i eth0 --add
systemctl restart vnstat
```

> 若网卡名不是 eth0，务必修改 `traffic_limit.sh` 顶部的 `IFACE` 变量。

## 四、部署脚本

```bash
# 1. 上传并赋予执行权限
cp traffic_limit.sh /usr/local/bin/traffic_limit.sh
chmod +x /usr/local/bin/traffic_limit.sh

# 2. 先手动跑一次验证（观察 /var/log/traffic_limit.log）
/usr/local/bin/traffic_limit.sh
cat /var/log/traffic_limit.log
```

## 五、配置定时任务

```bash
crontab -e
```

添加以下内容：

```
# 每 5 分钟检查一次出向流量
*/5 * * * * /usr/local/bin/traffic_limit.sh >/dev/null 2>&1
```

> 注意：**无需**添加每月 1 号的重置任务。vnstat 会按自然月自动切分流量，
> 脚本内置「跨月自愈」逻辑（比对 `/var/run/traffic_limit_month`），跨月后自动归零并解除断流。

## 六、验证命令

```bash
# 查看当月出向流量
vnstat -m -i eth0

# 查看当前 iptables 规则（断流后会出现 TRAFFIC_OUT_LIMIT 链）
iptables -L OUTPUT -n --line-numbers

# 查看脚本日志
tail -f /var/log/traffic_limit.log

# 手动触发断流测试（临时把 MONTHLY_LIMIT_GB 改小后运行，验证后改回）
```

## 七、注意事项 / 易踩坑点

1. **网卡名必须核对**：云主机常见 `eth0`、`ens5`、`enp0s3`，填错则统计不到、不会触发限制。
2. **口径误差**：vnstat 统计网卡层出向字节，与阿里云账单可能存在 1%~3% 差异，
   建议把 `MONTHLY_LIMIT_GB` 设为 190 留出余量，避免"本地没到、云端已超额"。
3. **断流是止血而非预防**：建议开启 `NOTIFY_CMD` 告警，在 90% 时提前通知，
   而不是等到 100% 直接断网。
4. **生产变更**：上线前先在测试机验证；iptables 规则在重启后默认不持久化，
   如需持久化请使用 `iptables-save` / `netfilter-persistent`（Ubuntu）或
   `service iptables save`（CentOS）。
5. **仅限 Linux**：Windows Server 需改用性能计数器 + 任务计划实现，逻辑可类比。

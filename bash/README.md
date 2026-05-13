# ddnsman — Bash 版

自动检测公网 IP 变化并更新阿里云 DNS 记录。场景说明和前提条件见项目根目录的 `alidns-方案.md`。

---

## 环境准备

### 安装阿里云 CLI

```bash
curl -fsSL https://aliyuncli.alicdn.com/install.sh | sudo bash
```

### 安装 jq 和 curl

```bash
sudo apt install jq curl -y
```

### 安装 cron

```bash
sudo apt-get install cron -y
sudo systemctl enable cron
```

---

## 下载

登录到你的服务器后，任选一种方式：

**方式一：直接用 wget 下载（推荐，最快）**

```bash
wget https://raw.githubusercontent.com/aajin32/ddnsman/main/bash/ddnsman.sh
chmod +x ddnsman.sh
```

**方式二：git clone 整个项目**

```bash
git clone https://github.com/aajin32/ddnsman.git
cd ddnsman/bash
chmod +x ddnsman.sh
```

---

## 第一次运行

```bash
./ddnsman.sh
```

首次运行会进入**配置引导**，依次输入：

```
请配置阿里云 AccessKey（RAM 子账号，最小权限）

AccessKey ID: LTAI5txxx
AccessKey Secret:           ← 输入时不显示字符，正常
默认域名（如 example.com）: example.com
```

填完后脚本会自动验证配置是否可用：

```
正在验证配置...
✅ 配置验证通过
```

---

## 新增一条 DNS 记录并开启 DDNS

接着你会看到**主菜单**：

```
主菜单  [域名: example.com]
  1. 查看/管理解析记录
  2. 新增解析记录
  3. 切换域名
  4. 重新配置 AccessKey
  5. DDNS 设置
  6. 退出
```

输入 **2** 选择新增记录，然后按提示一步步来：

```
主机记录（如 www、@）: myhome
记录类型:
1) A
2) AAAA
3) CNAME
4) MX
5) TXT
6) NS
#? 1
是否自动获取本机公网 IP？(y/N): y
⏳ 正在获取公网 IP... ✅ 1.2.3.4
是否开启定时更新（检测 IP 变化自动同步）？(y/N): y
确认新增: myhome.example.com  A -> 1.2.3.4  TTL=600  [定时更新] (y/N): y
```

看到这个就是搞定了：

```
✅ 已新增: myhome.example.com  A -> 1.2.3.4
📌 已添加 crontab 定时任务，每 5 分钟检测一次
```

**DDNS 功能已自动开启**，脚本每 5 分钟自动检查一次 IP，变了就更新。

---

## 常用操作

### 查看已有记录

主菜单选 1 → 输入序号选一条记录 → 可修改、删除、或开关 DDNS：

```
操作 [myhome.example.com (A -> 1.2.3.4)]
  1. 修改记录值
  2. 删除该记录
  3. 定时更新 [开启]
  4. 返回
```

### DDNS 设置

主菜单选 5，进入 DDNS 管理：

```
DDNS 设置  [跟踪: myhome]  [间隔: 5分钟]  [cron: ✅ 已安装]
  1. 查看/修改跟踪记录
  2. 修改检测间隔
  3. 卸载 crontab
  4. 返回
```

### 修改检测频率

主菜单选 5（DDNS 设置）→ 选「修改检测间隔」，输入 1~60 分钟。

### 彻底停掉 DDNS

主菜单选 5 → 选「卸载 crontab」— 不会删行，只是加 `#` 注释掉。

### 手动检测一次 IP

```bash
./ddnsman.sh --watch
```

正常输出：

```
[ddnsman] 2026-05-13 09:00:00  公网 IP: 1.2.3.4
  myhome.example.com: IP 无变化 (1.2.3.4)
```

### 重新配置

删除配置文件后重新运行脚本：

```bash
rm -f ~/.alidns_config.sh
./ddnsman.sh
```

---

## 常见问题

### 执行报错说没权限

```bash
chmod +x ddnsman.sh
```

### 提示 aliyun 命令找不到

先安装阿里云 CLI：

```bash
curl -fsSL https://aliyuncli.alicdn.com/install.sh | sudo bash
```

### 提示 jq 找不到

```bash
sudo apt install jq -y
```

### 运行后菜单显示乱码或不清晰

检查终端是否支持 UTF-8，执行 `locale`，确保输出中有 `LANG=zh_CN.UTF-8`。

### crontab 报错 "command not found"

说明系统没装 cron，执行：

```bash
sudo apt-get install cron -y
```

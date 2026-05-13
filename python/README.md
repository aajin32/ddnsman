# ddnsman — Python 版

自动检测公网 IP 变化并更新阿里云 DNS 记录。场景说明和前提条件见项目根目录的 `alidns-方案.md`。

---

## 下载

登录到你的服务器后，任选一种方式：

**方式一：直接用 wget 下载（推荐，最快）**

```bash
wget https://raw.githubusercontent.com/aajin32/ddnsman/main/python/ddnsman.py
chmod +x ddnsman.py
```

**方式二：git clone 整个项目**

```bash
git clone https://github.com/aajin32/ddnsman.git
cd ddnsman/python
chmod +x ddnsman.py
```

---

## 第一次运行

```bash
./ddnsman.py
```

第一次运行会看到类似下面的输出：

```
⏳ 正在安装依赖: aliyun-python-sdk-alidns, questionary, requests
```

**这是正常的**，脚本在自动安装需要的组件。

> 如果系统没有 pip，脚本会自动安装。这时会弹一次 `sudo` 密码输入框：
>
> ```
> [sudo] 你的用户名 的密码：
> ```
>
> **输入你的登录密码**（输入时屏幕不会显示字符，这是正常的），回车继续。
>
> 如果脚本发现 pip 被系统限制（新版 Ubuntu 常见），还会自动第二次尝试 `sudo pip install`，同样会弹一次 sudo 密码框。**全程只需看着就行**，脚本会自动处理。

看到下面就是装好了：

```
✅ 依赖安装完成
```

---

## 配置 AccessKey

然后会进入**配置引导**（AccessKey 的获取方式见根目录 `alidns-方案.md` 的 RAM 权限配置章节）：

```
请配置阿里云 AccessKey（RAM 子账号，最小权限）

? AccessKey ID:   <-- 输入你的 AccessKey ID
? AccessKey Secret:   <-- 输入你的 AccessKey Secret（输入时不显示，正常）
? 默认域名（如 example.com）: example.com
```

填完后会自动验证你的 AccessKey 是否可用。看到下面就是成功了：

```
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

按键盘 **↓** 键移动到「2. 新增解析记录」，按回车。

然后按提示一步步来：

```
? 主机记录（如 www、@）: myhome          ← 填 myhome 就是 myhome.example.com
? 记录类型: → A                          ← 选 A（按 ↑↓ 然后回车）
? 是否自动获取本机公网 IP？ Yes           ← 选 Yes，脚本会帮你查
```

这时会有一个**倒计时**：

```
⏳ 正在获取公网 IP... 10秒
```

正常的话几秒内就能查到：

```
✅ 获取到公网 IP: 1.2.3.4
```

然后关键一步：

```
? 是否开启定时更新（检测 IP 变化自动同步）？ Yes   ← 选 Yes！
```

最后确认：

```
? 确认新增: myhome.example.com A -> 1.2.3.4 TTL=600 [定时更新]
```

看到这个就是搞定了：

```
✅ 已新增: myhome.example.com A -> 1.2.3.4
✅ 已添加 crontab 定时任务，每 5 分钟检测一次
```

**DDNS 功能已自动开启**，脚本每 5 分钟自动检查一次 IP，变了就更新。

---

## 常用操作

### 查看已有记录

主菜单选 1 → 选一条记录 → 可以点修改或删除，或开关该记录的 DDNS 跟踪：

```
操作 [myhome.example.com (A -> 1.2.3.4)]
  1. 修改记录值
  2. 删除该记录
  3. 定时更新 [开启]
  4. 返回
```

### 修改检测频率

主菜单选 5（DDNS 设置）→ 选「修改检测间隔」，输入 1~60 分钟。

### 彻底停掉 DDNS

主菜单选 5 → 选「卸载 crontab」— 脚本不会删行，只是加 `#` 注释掉，想恢复去掉 `#` 就行。

### 手动检测一次 IP

```bash
./ddnsman.py --watch
```

正常输出：

```
[ddnsman] 2026-05-12 14:30:00  公网 IP: 1.2.3.4
  myhome.example.com: IP 无变化 (1.2.3.4)
```

### 重新配置

```bash
rm -f ~/.alidns_config.json
./ddnsman.py
```

---

## 常见问题

### 执行 ./ddnsman.py 报错说没权限

先执行 `chmod +x ddnsman.py` 再重新运行。

### 运行后菜单是乱码或不清晰

检查你的终端是否支持 UTF-8，执行 `locale`，确保输出中有 `LANG=zh_CN.UTF-8`。

### DDNS 开启了，但域名还是解析到旧的 IP

执行 `./ddnsman.py --watch` 手动检测一次。

如果显示「IP 无变化」，说明当前 IP 和阿里云上记录的一样，是正常的。如果显示「更新失败」，检查 AccessKey 权限。

也可以登录[阿里云云解析控制台](https://dns.console.aliyun.com/) 检查记录值是否已更新。

### crontab 报错 "command not found"

说明系统没装 cron，执行：

```bash
sudo apt-get install cron -y
```

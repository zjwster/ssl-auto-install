# SSL 自动安装脚本

本项目提供一键脚本用于自动申请并安装 SSL 证书。

---

## 使用说明

### 1. 下载或更新脚本

```bash
curl -sSL "https://raw.githubusercontent.com/zjwster/ssl-auto-install/main/install_ssl.sh" -o install_ssl.sh
```

### 2. 赋予执行权限并以 sudo 权限运行

```bash
chmod +x install_ssl.sh && sudo ./install_ssl.sh
```

### 查看定时任务（证书续签相关）

```bash
crontab -l
```

## 注意事项

* 确保系统已安装 curl。
* 建议以 root 或 sudo 权限运行脚本。
* 脚本会自动处理证书申请、安装及续期任务。

# Yoga SaaS production bootstrap

这是 Yoga SaaS 的公开、无密钥服务器引导工具仓库。

- `bootstrap-production-server.sh` 仅用于**全新 Ubuntu/Debian 服务器**。
- `migrate-production-to-deploy.sh` 仅用于把固定路径下的旧 root 部署安全、可续跑地迁移到专用非 root `deploy` 账号。

- 它以 `root` 完成系统准备，再以受控非 root 账号 `deploy` 克隆和运行应用安装器。
- 它支持 GitHub 私有或公开项目仓库，服务器使用仓库级只读 Deploy Key。
- 它不是日常更新脚本，也不会覆盖 `/opt/yoga-saas/yoga-saas-app` 中的现有系统。
- Docker 官方便利安装脚本会从 `https://get.docker.com` 下载；这是首次安装的外部供应链边界。

请严格使用 Yoga SaaS 主项目部署教程中固定到不可变提交的下载地址和 SHA-256。不要直接运行 `main` 分支，也不要使用未经校验的 `curl | bash`。

迁移器也必须使用主教程中固定到不可变提交的下载地址和独立 SHA-256。已有系统的日常更新应使用 GitHub Actions，或在 root 终端显式从第一行起以 `deploy` 执行项目内的 `update.sh`。

#!/usr/bin/env bash
# Secret-free bootstrap for the first installation on Ubuntu/Debian.
set -Eeuo pipefail

official_ed25519_fingerprint='SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU'
deploy_user='deploy'
install_parent='/opt/yoga-saas'
install_path="$install_parent/yoga-saas-app"
docker_installer=''
work_dir=''
checkout_created=false
install_started=false
phase='启动前检查'

usage() {
  cat <<'EOF'
用法（仅限全新 Ubuntu/Debian 服务器的 root 终端）：
  bash bootstrap-production-server.sh OWNER/REPO

示例：
  bash bootstrap-production-server.sh nbbk/yoga-saas

脚本安装系统依赖与 Docker，创建 deploy，生成只读仓库公钥，核对 GitHub
Ed25519 指纹，克隆到 /opt/yoga-saas/yoga-saas-app，并以 deploy 启动 install.sh。
唯一人工步骤是在 GitHub Deploy keys 添加显示的公钥且不授予写权限。
EOF
}

finish() {
  local status=$?
  trap - HUP INT TERM EXIT
  [[ -z "$docker_installer" ]] || rm -f -- "$docker_installer"
  if [[ -n "$work_dir" && -d "$work_dir" ]]; then
    rm -f -- "$work_dir/github_known_hosts"
    rmdir -- "$work_dir" 2>/dev/null || true
  fi
  if (( status != 0 )); then
    printf '\n引导失败（阶段：%s，退出码：%s）。\n' "$phase" "$status" >&2
    if [[ "$checkout_created" == true && "$install_started" == false && -d "$install_path" && ! -L "$install_path" ]]; then
      local quarantine="$install_parent/yoga-saas-app.bootstrap-incomplete-$(date -u +%Y%m%dT%H%M%SZ)"
      if mv -- "$install_path" "$quarantine"; then
        printf '首次安装尚未开始；本次不完整检出已移动到：%s\n' "$quarantine" >&2
        printf '保留现场后可重新执行原引导命令；确认无需排查时再人工删除该目录。\n' >&2
      else
        printf '无法移动不完整检出。请先核对 %s，勿直接覆盖或递归改权限。\n' "$install_path" >&2
      fi
    elif [[ "$install_started" == true ]]; then
      printf 'install.sh 已开始，可能已有 production.env、容器或数据卷；不要删除目录、环境文件或数据卷，也不要重跑全新引导。\n' >&2
      printf '请保留完整日志，并按部署主教程“首次安装中断恢复”处理：%s/docs/deploy-tutorial.md\n' "$install_path" >&2
    else
      printf '尚未开始首次安装；修复上方错误后可重新执行原引导命令。\n' >&2
    fi
  fi
  exit "$status"
}
trap finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[[ ${1:-} != '-h' && ${1:-} != '--help' ]] || { usage; exit 0; }
repository_slug=${1:-}

(( EUID == 0 )) || { echo '错误：请在服务器 root 终端执行本脚本。' >&2; exit 77; }
[[ -t 0 && -t 1 ]] || { echo '错误：必须在交互式服务器终端执行。' >&2; exit 77; }
[[ "$repository_slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo '错误：OWNER/REPO 格式无效。' >&2; exit 64; }
[[ ! -L "$install_parent" && ! -L "$install_path" ]] || { echo '错误：安装路径不能是符号链接。' >&2; exit 73; }
[[ ! -e "$install_path" ]] || { echo "错误：检测到现有系统，拒绝覆盖：$install_path" >&2; exit 73; }

validate_deploy_account() {
  local passwd_entry
  (( $(id -u "$deploy_user") != 0 )) || { echo '错误：deploy 账号的 UID 不能为 0。' >&2; return 77; }
  passwd_entry=$(getent passwd "$deploy_user")
  deploy_home=$(awk -F: 'NR == 1 { print $6 }' <<<"$passwd_entry")
  deploy_shell=$(awk -F: 'NR == 1 { print $7 }' <<<"$passwd_entry")
  deploy_group=$(id -gn "$deploy_user")
  [[ "$deploy_home" =~ ^/[A-Za-z0-9._/-]+$ && -d "$deploy_home" && ! -L "$deploy_home" ]] || { echo '错误：deploy 家目录无效或为符号链接。' >&2; return 72; }
  [[ "$(stat -c '%U' -- "$deploy_home")" == "$deploy_user" ]] || { echo '错误：deploy 家目录不属于 deploy；拒绝自动接管。' >&2; return 77; }
  case "$deploy_shell" in
    ''|*/false|*/nologin) echo '错误：deploy 账号没有可登录 Shell。' >&2; return 77 ;;
  esac
  [[ -x "$deploy_shell" ]] || { echo "错误：deploy 登录 Shell 不可执行：$deploy_shell" >&2; return 77; }
}

deploy_account_preexisting=false
if id -u "$deploy_user" >/dev/null 2>&1; then
  deploy_account_preexisting=true
  validate_deploy_account
fi

parent_preexisting=false
if [[ -e "$install_parent" ]]; then
  [[ -d "$install_parent" ]] || { echo "错误：$install_parent 已存在但不是目录。" >&2; exit 73; }
  parent_preexisting=true
  [[ "$deploy_account_preexisting" == true ]] || { echo "错误：$install_parent 已存在但 deploy 账号不存在；拒绝接管未知目录。" >&2; exit 77; }
  [[ "$(stat -c '%U:%G' -- "$install_parent")" == "$deploy_user:$deploy_group" ]] || {
    echo "错误：$install_parent 已存在但不属于 $deploy_user:$deploy_group；拒绝自动修改所有权。" >&2; exit 77;
  }
fi

[[ -r /etc/os-release ]] || { echo '错误：无法识别 Linux 发行版。' >&2; exit 69; }
. /etc/os-release
case "${ID:-}:${ID_LIKE:-}" in
  ubuntu:*|debian:*|*:debian*) ;;
  *) echo '错误：一键引导仅支持 Ubuntu/Debian；其他系统请使用部署主教程手工流程。' >&2; exit 69 ;;
esac

phase='安装系统依赖与 Docker'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates coreutils curl gawk git openssh-client openssl sudo util-linux

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  docker_installer=$(mktemp /tmp/yoga-saas-get-docker.XXXXXX)
  curl --fail --silent --show-error --location https://get.docker.com --output "$docker_installer"
  sh "$docker_installer"
  rm -f -- "$docker_installer"
  docker_installer=''
fi
if command -v systemctl >/dev/null 2>&1; then
  systemctl enable --now docker >/dev/null
else
  service docker start >/dev/null
fi
docker info >/dev/null || { echo '错误：Docker daemon 不可用。' >&2; exit 69; }
docker compose version >/dev/null || { echo '错误：Docker Compose v2 不可用。' >&2; exit 69; }

phase='准备受控 deploy 账号与目录'
if [[ "$deploy_account_preexisting" == false ]]; then
  useradd --create-home --shell /bin/bash "$deploy_user"
  validate_deploy_account
fi

if [[ "$parent_preexisting" == false ]]; then
  install -d -m 755 -o "$deploy_user" -g "$deploy_group" "$install_parent"
fi
[[ ! -L "$install_parent" && -d "$install_parent" && "$(stat -c '%U:%G' -- "$install_parent")" == "$deploy_user:$deploy_group" ]] || {
  echo "错误：安装父目录最终权限不符合预期；拒绝继续。" >&2; exit 77;
}

[[ "$(stat -c '%G' /var/run/docker.sock)" == docker ]] || {
  echo '错误：Docker 套接字不属于标准 docker 组；拒绝修改未知权限模型。' >&2; exit 77;
}
printf '安全提示：docker 组等同服务器 root 能力，仅授予受控 deploy 账号。\n'
usermod -aG docker "$deploy_user"

run_as_deploy() { sudo -u "$deploy_user" -H -- "$@"; }
run_as_deploy docker info >/dev/null || { echo '错误：deploy 新会话无法访问 Docker。' >&2; exit 77; }
run_as_deploy docker compose version >/dev/null || { echo '错误：deploy 无法使用 Docker Compose v2。' >&2; exit 77; }

phase='生成并验证仓库只读密钥'
ssh_dir="$deploy_home/.ssh"
private_key="$ssh_dir/yoga_saas_repo"
public_key="${private_key}.pub"
known_hosts_file="$ssh_dir/yoga_saas_github_known_hosts"
for candidate in "$ssh_dir" "$private_key" "$public_key" "$known_hosts_file"; do
  [[ ! -L "$candidate" ]] || { echo "错误：拒绝通过符号链接写入 SSH 路径：$candidate" >&2; exit 73; }
done
if [[ -e "$ssh_dir" ]]; then
  [[ -d "$ssh_dir" && "$(stat -c '%U:%G' -- "$ssh_dir")" == "$deploy_user:$deploy_group" ]] || {
    echo '错误：现有 deploy .ssh 目录所有权无效；拒绝自动接管。' >&2; exit 77;
  }
  run_as_deploy chmod 700 "$ssh_dir"
else
  install -d -m 700 -o "$deploy_user" -g "$deploy_group" "$ssh_dir"
fi
if [[ ! -e "$private_key" && ! -e "$public_key" ]]; then
  run_as_deploy ssh-keygen -q -t ed25519 -a 100 -N '' -f "$private_key" -C 'yoga-saas-server'
fi
[[ -f "$private_key" && -f "$public_key" ]] || { echo '错误：引导密钥文件不完整，拒绝覆盖。' >&2; exit 73; }
[[ "$(stat -c '%U:%G' -- "$private_key")" == "$deploy_user:$deploy_group" && "$(stat -c '%U:%G' -- "$public_key")" == "$deploy_user:$deploy_group" ]] || {
  echo '错误：现有引导密钥不属于 deploy；拒绝自动接管。' >&2; exit 77;
}
derived_public=$(run_as_deploy ssh-keygen -y -f "$private_key")
stored_public=$(awk 'NF >= 2 { print $1 " " $2; exit }' "$public_key")
[[ "$derived_public" == ssh-ed25519\ * && "$stored_public" == "$derived_public" ]] || {
  echo '错误：引导公私钥不匹配或不是 Ed25519；拒绝继续。' >&2; exit 76;
}
run_as_deploy chmod 600 "$private_key"
run_as_deploy chmod 644 "$public_key"

printf '\n============================================================\n'
printf '请打开：https://github.com/%s/settings/keys\n' "$repository_slug"
printf 'Title：yoga-saas-server-bootstrap\n'
printf 'Key（复制下面完整一行）：\n\n'
cat "$public_key"
printf '\n必须保持 Allow write access 未勾选。\n'
printf '============================================================\n\n'
read -r -p 'GitHub 只读 Deploy Key 保存完成后按回车继续；Ctrl+C 可安全退出：' _

phase='核对 GitHub 主机并验证仓库权限'
work_dir=$(mktemp -d /tmp/yoga-saas-bootstrap.XXXXXX)
scanned_hosts="$work_dir/github_known_hosts"
ssh-keyscan -T 10 -t ed25519 github.com 2>/dev/null | sort -u > "$scanned_hosts" || {
  echo '错误：无法读取 GitHub Ed25519 主机公钥。' >&2; exit 69;
}
scanned_fingerprint=$(ssh-keygen -lf "$scanned_hosts" -E sha256 | awk '{print $2}' | sort -u) || {
  echo '错误：无法计算 GitHub 主机指纹。' >&2; exit 69;
}
[[ "$scanned_fingerprint" == "$official_ed25519_fingerprint" ]] || {
  printf '错误：GitHub Ed25519 指纹不匹配。\n扫描：%s\n预期：%s\n' "$scanned_fingerprint" "$official_ed25519_fingerprint" >&2
  exit 76
}
install -m 600 -o "$deploy_user" -g "$deploy_group" "$scanned_hosts" "$known_hosts_file"

ssh_command="ssh -F /dev/null -i $private_key -o IdentityAgent=none -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$known_hosts_file"
candidate_url="git@github.com:${repository_slug}.git"
run_as_deploy env GIT_SSH_COMMAND="$ssh_command" git ls-remote --exit-code "$candidate_url" HEAD >/dev/null || {
  echo '错误：GitHub 尚未接受该 Deploy Key；未克隆仓库。' >&2; exit 77;
}

phase='克隆并固定仓库 SSH 配置'
checkout_created=true
run_as_deploy env GIT_SSH_COMMAND="$ssh_command" git clone "$candidate_url" "$install_path"
[[ -d "$install_path/.git" && ! -L "$install_path" ]] || { echo '错误：仓库检出结果无效。' >&2; exit 73; }
run_as_deploy git -C "$install_path" config --local core.sshCommand "$ssh_command"
run_as_deploy git -C "$install_path" fetch --dry-run --no-tags origin >/dev/null

phase='运行首次安装'
install_started=true
printf '\n仓库只读 SSH 验证与克隆成功，开始首次安装。\n'
printf '安装过程中请按提示填写域名、平台管理员账号、密码和手机号。\n\n'
run_as_deploy bash -c 'cd -- "$1" && exec ./yoga-saas-api/deploy/install.sh' bash "$install_path"

phase='完成'
printf '\nSUCCESS：Yoga SaaS 首次安装完成。\n'
printf '下一步：配置宝塔 HTTPS，然后按部署主教程第 5、7 节验收并启用自动部署。\n'

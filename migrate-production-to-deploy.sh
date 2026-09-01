#!/usr/bin/env bash
# One-time, resumable migration of the fixed production checkout from UID 0 to deploy.
set -Eeuo pipefail

repo='/opt/yoga-saas/yoga-saas-app'
deploy_user='deploy'
state_dir='/var/lib/yoga-saas-deploy-migration'
state_file="$state_dir/yoga-saas-app.state"
work_dir=''
state_tmp=''

(( EUID == 0 )) || { echo '错误：迁移器必须从服务器 root 终端执行。' >&2; exit 77; }
[[ -t 0 && -t 1 ]] || { echo '错误：迁移器必须在交互式服务器终端执行。' >&2; exit 77; }
for command_name in awk bash chmod chown docker find findmnt flock getent git grep id install mktemp mv readlink rm sort stat sudo tr useradd usermod; do
  command -v "$command_name" >/dev/null 2>&1 || { echo "错误：缺少命令 $command_name。" >&2; exit 69; }
done

work_dir=$(mktemp -d /tmp/yoga-saas-deploy-migration.XXXXXX)
cleanup() {
  rm -f -- "${state_tmp:-}"
  [[ -z "$work_dir" ]] || rm -rf -- "$work_dir"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[[ "$(readlink -f -- "$repo")" == "$repo" && -d "$repo" && ! -L "$repo" ]] || { echo "错误：生产仓库真实路径不是 $repo。" >&2; exit 73; }
[[ -d "$repo/.git" && ! -L "$repo/.git" ]] || { echo '错误：.git 不存在或为符号链接。' >&2; exit 73; }
[[ -f "$repo/yoga-saas-api/deploy/production.env" && ! -L "$repo/yoga-saas-api/deploy/production.env" ]] || {
  echo '错误：production.env 不存在或为符号链接；这不是可迁移的已安装系统。' >&2; exit 73;
}
mounts_file="$work_dir/mounts"
findmnt -rn -o TARGET > "$mounts_file" || { echo '错误：无法完整枚举挂载点。' >&2; exit 71; }
while IFS= read -r mount_target; do
  [[ "$mount_target" != "$repo" && "$mount_target" != "$repo/"* ]] || {
    echo "错误：仓库内存在独立挂载点，拒绝跨文件系统修改所有权：$mount_target" >&2; exit 77;
  }
done < "$mounts_file"

lock_file="$repo/.git/yoga-saas-production-deploy.lock"
if [[ -e "$lock_file" || -L "$lock_file" ]]; then
  [[ -f "$lock_file" && ! -L "$lock_file" && "$(stat -c '%h' -- "$lock_file")" == 1 ]] || {
    echo '错误：生产发布锁必须是单硬链接的普通文件。' >&2; exit 73;
  }
fi
exec 9>>"$lock_file"
flock -n 9 || { echo '错误：已有生产更新或回滚正在运行；迁移未开始。' >&2; exit 75; }
[[ -f "$lock_file" && ! -L "$lock_file" && "$(stat -c '%h' -- "$lock_file")" == 1 ]] || {
  echo '错误：获取锁后发现生产发布锁类型异常。' >&2; exit 73;
}

assert_no_hardlinks() {
  local output_file="$1"
  find "$repo" -xdev -type f -links +1 -print -quit > "$output_file" || {
    echo '错误：无法完整检查仓库硬链接。' >&2; return 71;
  }
  [[ ! -s "$output_file" ]] || {
    echo "错误：仓库存在多硬链接普通文件，拒绝越界修改 inode：$(<"$output_file")" >&2; return 77;
  }
}
assert_no_hardlinks "$work_dir/hardlinks-before-state"

validate_deploy() {
  local passwd_entry deploy_home deploy_shell
  (( $(id -u "$deploy_user") != 0 )) || { echo '错误：deploy 的 UID 不能为 0。' >&2; return 77; }
  passwd_entry=$(getent passwd "$deploy_user")
  deploy_home=$(awk -F: 'NR == 1 { print $6 }' <<<"$passwd_entry")
  deploy_shell=$(awk -F: 'NR == 1 { print $7 }' <<<"$passwd_entry")
  [[ -n "$deploy_home" && -d "$deploy_home" && ! -L "$deploy_home" && "$(stat -c '%U' -- "$deploy_home")" == "$deploy_user" ]] || {
    echo '错误：deploy 家目录无效、为符号链接或所有者错误。' >&2; return 77;
  }
  case "$deploy_shell" in ''|*/false|*/nologin) echo '错误：deploy 没有可登录 Shell。' >&2; return 77;; esac
  [[ -x "$deploy_shell" ]] || { echo '错误：deploy 登录 Shell 不可执行。' >&2; return 77; }
}

deploy_exists=false
deploy_uid=''
deploy_gid=''
if id -u "$deploy_user" >/dev/null 2>&1; then
  deploy_exists=true
  validate_deploy
  deploy_uid=$(id -u "$deploy_user")
  deploy_gid=$(id -g "$deploy_user")
fi

initial_pairs_raw="$work_dir/initial-pairs.raw"
initial_pairs_file="$work_dir/initial-pairs"
find "$repo" -xdev ! -path "$lock_file" -printf '%U:%G\n' > "$initial_pairs_raw" || { echo '错误：无法完整读取迁移前所有权。' >&2; exit 71; }
sort -u "$initial_pairs_raw" > "$initial_pairs_file" || { echo '错误：无法整理迁移前所有权。' >&2; exit 71; }
mapfile -t initial_pairs < "$initial_pairs_file"
(( ${#initial_pairs[@]} > 0 )) || { echo '错误：无法读取仓库所有权。' >&2; exit 71; }
all_root=true
all_deploy=true
only_root_or_deploy=true
for owner_pair in "${initial_pairs[@]}"; do
  owner_uid=${owner_pair%%:*}
  owner_gid=${owner_pair##*:}
  [[ "$owner_pair" == '0:0' ]] || all_root=false
  [[ -n "$deploy_uid" && "$owner_pair" == "$deploy_uid:$deploy_gid" ]] || all_deploy=false
  [[ ( "$owner_uid" == 0 || ( -n "$deploy_uid" && "$owner_uid" == "$deploy_uid" ) ) \
    && ( "$owner_gid" == 0 || ( -n "$deploy_gid" && "$owner_gid" == "$deploy_gid" ) ) ]] || only_root_or_deploy=false
done

state_valid=false
if [[ -e "$state_dir" ]]; then
  [[ -d "$state_dir" && ! -L "$state_dir" && "$(stat -c '%u:%g:%a' -- "$state_dir")" == '0:0:700' ]] || {
    echo '错误：迁移状态目录必须是 root:root 且权限为 0700 的真实目录。' >&2; exit 77;
  }
fi
if [[ -e "$state_file" ]]; then
  [[ -f "$state_file" && ! -L "$state_file" && "$(stat -c '%u:%g:%a' -- "$state_file")" == '0:0:600' ]] || {
    echo '错误：迁移状态文件权限异常。' >&2; exit 77;
  }
  [[ "$(<"$state_file")" == "$repo" ]] || { echo '错误：迁移状态文件目标不匹配。' >&2; exit 77; }
  state_valid=true
fi

if [[ "$all_deploy" == true ]]; then
  echo '仓库已经全部属于 deploy；正在做最终权限与 Docker 复验。'
elif [[ "$all_root" == true ]]; then
  if [[ "$state_valid" == false ]]; then
    install -d -m 700 -o root -g root "$state_dir"
    state_tmp="$state_dir/.yoga-saas-app.state.$$"
    printf '%s' "$repo" > "$state_tmp"
    chmod 600 "$state_tmp"
    mv -f -- "$state_tmp" "$state_file"
    state_tmp=''
    state_valid=true
  fi
elif [[ "$only_root_or_deploy" == true && "$state_valid" == true ]]; then
  echo '检测到上次迁移中断留下的 root/deploy 混合所有权；将从状态文件安全继续。'
else
  echo '错误：仓库存在混合或第三方所有者，且没有可信迁移状态；拒绝强制接管。' >&2
  printf '检测到的 UID:GID：%s\n' "${initial_pairs[*]}" >&2
  exit 77
fi

if [[ "$deploy_exists" == false ]]; then
  useradd --create-home --shell /bin/bash "$deploy_user"
  deploy_exists=true
  validate_deploy
  deploy_uid=$(id -u "$deploy_user")
  deploy_gid=$(id -g "$deploy_user")
fi
deploy_group=$(id -gn "$deploy_user")

[[ "$(stat -c '%G' /var/run/docker.sock)" == docker ]] || { echo '错误：Docker 套接字不属于标准 docker 组。' >&2; exit 77; }
getent group docker >/dev/null || { echo '错误：docker 组不存在。' >&2; exit 77; }
usermod -aG docker "$deploy_user"
sudo -u "$deploy_user" -H -- bash -c 'set -Eeuo pipefail; id -nG | tr " " "\n" | grep -Fx docker >/dev/null; docker info >/dev/null; docker compose version >/dev/null'

if [[ "$all_deploy" != true ]]; then
  echo '正在迁移固定生产仓库；不会跟随符号链接或进入子挂载点...'
  assert_no_hardlinks "$work_dir/hardlinks-before-chown"
  find "$repo" -xdev -exec chown -h -- "$deploy_user:$deploy_group" {} +
else
  chown -h -- "$deploy_user:$deploy_group" "$lock_file"
fi

final_uids_raw="$work_dir/final-uids.raw"
final_uids_file="$work_dir/final-uids"
final_gids_raw="$work_dir/final-gids.raw"
final_gids_file="$work_dir/final-gids"
find "$repo" -xdev -printf '%U\n' > "$final_uids_raw" || { echo '错误：无法完整读取迁移后 UID；保留状态文件。' >&2; exit 71; }
sort -un "$final_uids_raw" > "$final_uids_file" || { echo '错误：无法整理迁移后 UID；保留状态文件。' >&2; exit 71; }
find "$repo" -xdev -printf '%G\n' > "$final_gids_raw" || { echo '错误：无法完整读取迁移后 GID；保留状态文件。' >&2; exit 71; }
sort -un "$final_gids_raw" > "$final_gids_file" || { echo '错误：无法整理迁移后 GID；保留状态文件。' >&2; exit 71; }
mapfile -t final_uids < "$final_uids_file"
mapfile -t final_gids < "$final_gids_file"
[[ ${#final_uids[@]} == 1 && "${final_uids[0]}" == "$deploy_uid" ]] || { echo '错误：迁移后仍存在非 deploy 所有者；保留状态文件，可修复后重跑。' >&2; exit 71; }
[[ ${#final_gids[@]} == 1 && "${final_gids[0]}" == "$deploy_gid" ]] || { echo '错误：迁移后仍存在非 deploy 组；保留状态文件，可修复后重跑。' >&2; exit 71; }
sudo -u "$deploy_user" -H -- bash -c 'set -Eeuo pipefail; cd /opt/yoga-saas/yoga-saas-app; test "$(git branch --show-current)" = main; test -r yoga-saas-api/deploy/production.env; test -w .git/config; docker info >/dev/null; docker compose version >/dev/null'

if [[ -e "$state_file" ]]; then
  [[ "$state_valid" == true ]] || { echo '错误：拒绝删除未经验证的状态文件。' >&2; exit 77; }
  rm -f -- "$state_file"
fi
echo 'SUCCESS：生产仓库已完整迁移到非 root deploy；下一步重新配置两套 SSH 密钥和 6 个 GitHub Secrets。'

set -Eeuo pipefail

readonly source_repository="${HOME_MANAGER_UPDATE_REPOSITORY:-$HOME/.config/home-manager}"
readonly state_root="${XDG_STATE_HOME:-$HOME/.local/state}/home-manager-auto-update"
readonly automation_repository="$state_root/repository"
readonly transaction_directory="$state_root/transaction"
readonly candidate_repository="$transaction_directory/repository"
readonly lock_file="$state_root/update.lock"
readonly home_manager_profile="${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/home-manager"
readonly network_attempts=5
readonly network_retry_delay=60
readonly graceful_stop_timeout=30
readonly application_start_timeout=15

mkdir -p "$state_root"
exec 9>"$lock_file"
if ! flock -n 9; then
  echo "另一个 Home Manager 自动更新事务正在运行。"
  exit 0
fi

log() {
  printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"
}

safe_remove_tree() {
  local target="$1"

  case "$target" in
    "$transaction_directory" | "$state_root/repository.new")
      rm -rf -- "$target"
      ;;
    *)
      log "拒绝删除不受管理的路径：$target"
      return 1
      ;;
  esac
}

write_state() {
  local name="$1"
  local value="$2"
  local temporary="$transaction_directory/$name.new"

  printf '%s\n' "$value" >"$temporary"
  mv -f -- "$temporary" "$transaction_directory/$name"
}

read_state() {
  local name="$1"

  if [[ -f "$transaction_directory/$name" ]]; then
    head -n 1 "$transaction_directory/$name"
  fi
}

set_phase() {
  write_state phase "$1"
  log "事务阶段：$1"
}

retry_network() {
  local attempt=1

  while ! "$@"; do
    if ((attempt >= network_attempts)); then
      log "网络操作在 $network_attempts 次尝试后仍然失败：$*"
      return 1
    fi

    log "网络操作失败，${network_retry_delay} 秒后进行第 $((attempt + 1)) 次尝试：$*"
    sleep "$network_retry_delay"
    ((attempt += 1))
  done
}

origin_url() {
  git -C "$source_repository" remote get-url origin
}

ensure_automation_repository() {
  local remote_url
  remote_url="$(origin_url)"

  if [[ -e "$state_root/repository.new" ]]; then
    safe_remove_tree "$state_root/repository.new"
  fi

  if
    [[ -e "$automation_repository" ]] &&
      {
        [[ ! -d "$automation_repository/.git" ]] ||
          ! git -C "$automation_repository" rev-parse --verify refs/heads/main >/dev/null 2>&1
      }
  then
    log "清理不完整的自动化仓库。"
    mv -- "$automation_repository" "$state_root/repository.new"
    safe_remove_tree "$state_root/repository.new"
  fi

  if [[ ! -d "$automation_repository/.git" ]]; then
    log "创建隔离的自动化仓库。"
    retry_network git clone --single-branch --branch main "$remote_url" "$automation_repository"
  fi

  git -C "$automation_repository" remote set-url origin "$remote_url"
}

candidate_remote_head() {
  local output
  local attempt=1

  while true; do
    if output="$(git -C "$automation_repository" ls-remote --heads origin refs/heads/main)"; then
      awk 'NR == 1 { print $1 }' <<<"$output"
      return 0
    fi

    if ((attempt >= network_attempts)); then
      return 1
    fi

    log "无法确认远端 main，${network_retry_delay} 秒后重试。"
    sleep "$network_retry_delay"
    ((attempt += 1))
  done
}

app_pids() {
  local app="$1"
  local process_name
  local pid
  local command_line
  local -a process_names=()

  case "$app" in
    vivaldi)
      process_names=(vivaldi-bin)
      ;;
    thunderbird)
      process_names=(thunderbird)
      ;;
    qq)
      process_names=(qq QQ)
      ;;
    *)
      return 1
      ;;
  esac

  for process_name in "${process_names[@]}"; do
    while read -r pid; do
      [[ -n "$pid" && -r "/proc/$pid/cmdline" ]] || continue
      command_line="$(tr '\0' ' ' <"/proc/$pid/cmdline")"

      case "$app" in
        vivaldi | qq)
          [[ "$command_line" == *"--type="* ]] && continue
          ;;
        thunderbird)
          [[ "$command_line" == *"-contentproc"* ]] && continue
          ;;
      esac

      printf '%s\n' "$pid"
    done < <(pgrep -u "$UID" -x "$process_name" || true)
  done | sort -nu
}

app_is_running() {
  [[ -n "$(app_pids "$1")" ]]
}

stop_app() {
  local app="$1"
  local waited=0
  local -a pids=()

  mapfile -t pids < <(app_pids "$app")
  if ((${#pids[@]} == 0)); then
    return 0
  fi

  log "请求 $app 正常退出。"
  kill -TERM "${pids[@]}"

  while ((waited < graceful_stop_timeout)); do
    if ! app_is_running "$app"; then
      return 0
    fi
    sleep 1
    ((waited += 1))
  done

  log "$app 未在 ${graceful_stop_timeout} 秒内退出；不会强制结束进程。"
  return 1
}

app_executable() {
  case "$1" in
    vivaldi)
      printf '%s\n' "$HOME/.nix-profile/bin/vivaldi"
      ;;
    thunderbird)
      printf '%s\n' "$HOME/.nix-profile/bin/thunderbird"
      ;;
    qq)
      printf '%s\n' "$HOME/.nix-profile/bin/qq"
      ;;
    *)
      return 1
      ;;
  esac
}

start_app() {
  local app="$1"
  local executable
  local unit
  local waited=0

  executable="$(app_executable "$app")"
  unit="home-manager-auto-update-${app}-$(date +%s)"

  if [[ ! -x "$executable" ]]; then
    log "找不到 $app 的可执行文件：$executable"
    return 1
  fi

  log "启动 $app。"
  systemd-run \
    --user \
    --quiet \
    --collect \
    --unit="$unit" \
    --property=Type=exec \
    "$executable"

  while ((waited < application_start_timeout)); do
    if app_is_running "$app"; then
      return 0
    fi
    sleep 1
    ((waited += 1))
  done

  log "$app 未在 ${application_start_timeout} 秒内成功启动。"
  return 1
}

record_running_apps() {
  local app
  : >"$transaction_directory/running-apps"

  for app in vivaldi thunderbird qq; do
    if app_is_running "$app"; then
      printf '%s\n' "$app" >>"$transaction_directory/running-apps"
    fi
  done
}

rollback_local_state() {
  local old_generation
  local app
  local stop_failed=0
  local start_failed=0

  old_generation="$(read_state old-generation)"
  if [[ -z "$old_generation" || ! -x "$old_generation/activate" ]]; then
    log "缺少可用的旧 Home Manager generation，无法自动回滚。"
    return 1
  fi

  log "开始回滚到 $old_generation。"

  if [[ -f "$transaction_directory/running-apps" ]]; then
    while read -r app; do
      [[ -n "$app" ]] || continue
      if app_is_running "$app" && ! stop_app "$app"; then
        stop_failed=1
      fi
    done <"$transaction_directory/running-apps"
  fi

  if ! "$old_generation/activate"; then
    log "旧 Home Manager generation 激活失败。"
    return 1
  fi

  if [[ -f "$transaction_directory/running-apps" ]]; then
    while read -r app; do
      [[ -n "$app" ]] || continue
      if ! app_is_running "$app" && ! start_app "$app"; then
        start_failed=1
      fi
    done <"$transaction_directory/running-apps"
  fi

  if ((stop_failed != 0 || start_failed != 0)); then
    log "配置已回滚，但至少一个桌面应用未能完全恢复。"
  fi

  log "本地状态已回滚。"
}

cleanup_transaction() {
  if [[ -d "$candidate_repository" ]]; then
    # 候选 worktree 只包含自动任务生成的内容，失败时应完整丢弃。
    if ! git -C "$automation_repository" worktree remove --force "$candidate_repository"; then
      log "候选 worktree 元数据不完整，按受管事务目录清理。"
      safe_remove_tree "$transaction_directory"
      git -C "$automation_repository" worktree prune
      return 0
    fi
  fi
  git -C "$automation_repository" worktree prune
  safe_remove_tree "$transaction_directory"
}

sync_source_main() {
  local candidate_commit
  local remote_main
  local local_main
  local main_worktree

  candidate_commit="$(read_state candidate-commit)"
  retry_network git -C "$source_repository" fetch --prune origin main
  remote_main="$(git -C "$source_repository" rev-parse refs/remotes/origin/main)"

  if [[ "$remote_main" != "$candidate_commit" ]]; then
    log "源仓库看到的远端 main 与已提交候选版本不一致。"
    return 1
  fi

  main_worktree="$(
    git -C "$source_repository" worktree list --porcelain |
      awk '
        $1 == "worktree" { path = $2 }
        $1 == "branch" && $2 == "refs/heads/main" { print path; exit }
      '
  )"

  if [[ -n "$main_worktree" ]]; then
    if [[ -n "$(git -C "$main_worktree" status --porcelain)" ]]; then
      log "本地 main worktree 正在修改，跳过本地快进；远端和运行环境已经提交。"
      return 0
    fi

    git -C "$main_worktree" merge --ff-only "$candidate_commit"
    log "本地 main worktree 已快进到 $candidate_commit。"
    return 0
  fi

  local_main="$(git -C "$source_repository" rev-parse refs/heads/main)"
  if ! git -C "$source_repository" merge-base --is-ancestor "$local_main" "$candidate_commit"; then
    log "本地 main 含有远端没有的提交，跳过本地引用更新。"
    return 0
  fi

  git -C "$source_repository" update-ref refs/heads/main "$candidate_commit" "$local_main"
  log "本地 main 引用已快进到 $candidate_commit。"
}

finalize_committed_transaction() {
  local candidate_commit
  local candidate_generation
  local current_generation
  local app

  candidate_commit="$(read_state candidate-commit)"
  candidate_generation="$(read_state candidate-generation)"

  if [[ -z "$candidate_commit" ]]; then
    log "已提交事务缺少候选提交标识。"
    return 1
  fi

  if [[ -n "$candidate_generation" && -x "$candidate_generation/activate" ]]; then
    current_generation="$(readlink -f "$home_manager_profile" 2>/dev/null || true)"
    if [[ "$current_generation" != "$candidate_generation" ]]; then
      log "远端已提交候选版本，重新激活对应 Home Manager generation。"
      "$candidate_generation/activate"
    fi
  fi

  if [[ -f "$transaction_directory/running-apps" ]]; then
    while read -r app; do
      [[ -n "$app" ]] || continue
      if ! app_is_running "$app"; then
        start_app "$app"
      fi
    done <"$transaction_directory/running-apps"
  fi

  git -C "$automation_repository" checkout --quiet main
  git -C "$automation_repository" merge --ff-only "$candidate_commit"
  sync_source_main
  cleanup_transaction
  log "已完成并清理事务。"
}

recover_transaction() {
  local phase
  local candidate_commit
  local base_commit
  local remote_head

  [[ -d "$transaction_directory" ]] || return 0

  phase="$(read_state phase)"
  log "发现未完成事务，当前阶段：${phase:-unknown}"

  case "$phase" in
    prepared | candidate-ready)
      cleanup_transaction
      ;;
    mutating | activated | apps-restarted)
      rollback_local_state
      cleanup_transaction
      ;;
    pushing)
      candidate_commit="$(read_state candidate-commit)"
      base_commit="$(read_state base-commit)"
      remote_head="$(candidate_remote_head)"

      if [[ -n "$candidate_commit" && "$remote_head" == "$candidate_commit" ]]; then
        set_phase committed
        finalize_committed_transaction
      elif [[ -n "$base_commit" && "$remote_head" == "$base_commit" ]]; then
        if [[ "$(read_state local-mutated)" == "true" ]]; then
          rollback_local_state
        fi
        cleanup_transaction
      else
        log "远端 main 已发生无法自动判定的变化，保留事务等待人工检查。"
        return 1
      fi
      ;;
    committed)
      finalize_committed_transaction
      ;;
    *)
      log "事务状态未知，保留现场等待人工检查。"
      return 1
      ;;
  esac
}

handle_unexpected_exit() {
  local status=$?

  trap - EXIT
  if ((status != 0)) && [[ -d "$transaction_directory" ]]; then
    log "更新进程异常退出，立即执行事务恢复。"
    recover_transaction || log "自动恢复未完成；下次运行会再次尝试。"
  fi
  exit "$status"
}

trap handle_unexpected_exit EXIT

ensure_automation_repository
recover_transaction

log "同步远端 main。"
retry_network git -C "$automation_repository" fetch --prune origin main
git -C "$automation_repository" checkout --quiet main
git -C "$automation_repository" merge --ff-only origin/main

mkdir "$transaction_directory"
write_state base-commit "$(git -C "$automation_repository" rev-parse main)"
set_phase prepared
git -C "$automation_repository" worktree add --quiet --detach "$candidate_repository" main

log "更新高频软件输入。"
retry_network nix flake update nixpkgs-unstable codex-desktop-linux --flake "$candidate_repository"

if git -C "$candidate_repository" diff --quiet -- flake.lock; then
  log "高频软件输入没有变化。"
  cleanup_transaction
  exit 0
fi

log "构建候选 Home Manager generation。"
candidate_generation="$(
  nix build \
    --no-link \
    --print-out-paths \
    "$candidate_repository#homeConfigurations.user.activationPackage"
)"

if [[ ! -x "$candidate_generation/activate" ]]; then
  log "候选构建没有生成可执行的 activation package。"
  exit 1
fi

write_state candidate-generation "$candidate_generation"
git -C "$candidate_repository" add flake.lock
git -C "$candidate_repository" \
  -c commit.gpgsign=false \
  commit \
  --quiet \
  -m "Update fast-moving packages ($(date --iso-8601=date))"
write_state candidate-commit "$(git -C "$candidate_repository" rev-parse HEAD)"
set_phase candidate-ready

log "预检远端推送权限和快进条件。"
retry_network git -C "$candidate_repository" push --dry-run origin HEAD:refs/heads/main

old_generation="$(readlink -f "$home_manager_profile")"
write_state old-generation "$old_generation"
record_running_apps

if [[ "$candidate_generation" != "$old_generation" ]]; then
  write_state local-mutated true
  set_phase mutating

  while read -r app; do
    [[ -n "$app" ]] || continue
    stop_app "$app" || true
  done <"$transaction_directory/running-apps"

  log "激活候选 Home Manager generation。"
  "$candidate_generation/activate"
  set_phase activated

  while read -r app; do
    [[ -n "$app" ]] || continue
    if ! app_is_running "$app"; then
      start_app "$app"
    fi
  done <"$transaction_directory/running-apps"

  set_phase apps-restarted
else
  write_state local-mutated false
fi

set_phase pushing
log "推送候选提交到远端 main。"
retry_network git -C "$candidate_repository" push origin HEAD:refs/heads/main

remote_head="$(candidate_remote_head)"
candidate_commit="$(read_state candidate-commit)"
if [[ "$remote_head" != "$candidate_commit" ]]; then
  log "推送后的远端提交与候选提交不一致。"
  exit 1
fi

set_phase committed
finalize_committed_transaction
log "Home Manager 高频软件自动更新成功。"

#!/usr/bin/env bash

set -euo pipefail

# Remove KernelSU/SUSFS integration from a kernel source tree.
#
# Usage:
#   bash scripts/remove_ksu.sh
#
# The script operates ONLY on the current Git repository.
# It removes:
#   - CONFIG_KSU / CONFIG_KSU_* / CONFIG_SUSFS / CONFIG_SUSFS_*
#   - KernelSU manual-hook preprocessor blocks
#   - KernelSU source directories/symlinks
#   - obvious KernelSU integration helper scripts
#
# It intentionally does NOT restore whole source files from Git, because
# those files may contain unrelated changes that must be preserved.

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "错误：请在内核 Git 仓库内运行此脚本。" >&2
  exit 1
}

cd -- "$ROOT"

echo "==> 当前分支"
git branch --show-current

echo
echo "==> 清理 KSU/SUSFS 配置"

python3 - <<'PY'
from pathlib import Path
import re

root = Path.cwd()

config_symbol_re = re.compile(
  r"^\s*(?:#\s*)?CONFIG_(?:KSU(?:_[A-Z0-9_]+)?|SUSFS(?:_[A-Z0-9_]+)?)"
  r"(?:\s*=.*|\s+is not set)?\s*$"
)

config_file_names = {
  "Kconfig",
  "Kconfig.ksu",
  "Kconfig.kernelsu",
  "Makefile.ksu",
  "ksu.config",
  "kernelsu.config",
  ".config",
}

def is_config_file(path: Path) -> bool:
  name = path.name

  if name in config_file_names:
    return True

  if name.endswith(
    (
      "_defconfig",
      ".config",
      ".cfg",
      ".config.fragment",
    )
  ):
    return True

  if name.startswith("build.config"):
    return True

  return False


changed = []

# Only inspect normal kernel/config source directories.
config_roots = [
  root,
  root / "arch",
  root / "drivers",
  root / "fs",
  root / "include",
  root / "init",
  root / "kernel",
  root / "security",
  root / "scripts",
]

seen = set()

for base in config_roots:
  if not base.exists():
    continue

  for path in base.rglob("*"):
    if not path.is_file():
      continue

    if path in seen:
      continue

    seen.add(path)

    if ".git" in path.parts:
      continue

    if not is_config_file(path):
      continue

    try:
      text = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
      continue

    lines = text.splitlines(keepends=True)
    output = []
    removed = 0

    for line in lines:
      if config_symbol_re.match(line.rstrip("\r\n")):
        removed += 1
        continue

      output.append(line)

    if removed:
      path.write_text(
        "".join(output),
        encoding="utf-8",
        newline="",
      )

      changed.append(
        (
          str(path.relative_to(root)),
          removed,
        )
      )

print(f"修改文件数：{len(changed)}")

for path, count in changed:
  print(f"  {path}: 删除 {count} 行")
PY

echo
echo "==> 删除 KernelSU 源码目录/链接"

for path in \
  "KernelSU" \
  "kernelsu" \
  "drivers/kernelsu" \
  "drivers/KernelSU" \
  "drivers/ksu" \
  "kernel/kernelsu" \
  "kernel/KernelSU" \
  "kernel/ksu"; do

  if [ -e "$path" ] || [ -L "$path" ]; then
    echo "  删除：$path"
    rm -rf -- "$path"
  fi
done

echo
echo "==> 删除 KernelSU 集成辅助脚本"

# findx3.sh in this kernel tree is a KernelSU/ReSukiSU integration helper.
if [ -f "findx3.sh" ] &&
  grep -qE 'KernelSU|kernelsu|drivers/kernelsu|RESUKISU' "findx3.sh"; then
  echo "  删除：findx3.sh"
  rm -f -- "findx3.sh"
fi

echo
echo "==> 清理 KSU 手动 Hook"

python3 - <<'PY'
from pathlib import Path
import re

root = Path.cwd()

# KernelSU-related preprocessor conditions.
# Examples:
#   #ifdef CONFIG_KSU
#   #ifdef CONFIG_KSU_MANUAL_HOOK
#   #if defined(CONFIG_KSU)
#   #if IS_ENABLED(CONFIG_KSU)
ksu_open_re = re.compile(
  r"^\s*#\s*(?:if|ifdef)\b.*CONFIG_(?:KSU|SUSFS)(?:\b|_)"
)

preprocessor_re = re.compile(
  r"^\s*#\s*(?:if|ifdef|ifndef|elif|else|endif)\b"
)

source_suffixes = {
  ".c",
  ".h",
  ".S",
  ".s",
}

changed = []

# Only inspect actual kernel source files.
for path in root.rglob("*"):
  if not path.is_file():
    continue

  if ".git" in path.parts:
    continue

  if path.suffix not in source_suffixes:
    continue

  try:
    text = path.read_text(encoding="utf-8")
  except (UnicodeDecodeError, OSError):
    continue

  lines = text.splitlines(keepends=True)

  output = []
  i = 0
  removed_blocks = 0

  while i < len(lines):
    line = lines[i]

    if not ksu_open_re.match(line):
      output.append(line)
      i += 1
      continue

    start = i
    depth = 1
    has_else = False
    end = None

    i += 1

    while i < len(lines):
      current = lines[i]

      if preprocessor_re.match(current):
        stripped = current.lstrip()

        if re.match(r"#\s*(?:if|ifdef|ifndef)\b", stripped):
          depth += 1

        elif re.match(r"#\s*endif\b", stripped):
          depth -= 1

          if depth == 0:
            end = i
            break

        elif depth == 1 and re.match(r"#\s*(?:else|elif)\b", stripped):
          has_else = True

      i += 1

    if end is None:
      raise SystemExit(
        f"错误：无法找到 KSU 条件块的 #endif："
        f"{path.relative_to(root)}:{start + 1}"
      )

    if has_else:
      # Do not guess how a KSU conditional with an #else should be
      # transformed. Keeping it is safer than deleting non-KSU code.
      output.extend(lines[start:end + 1])
      i = end + 1

      print(
        f"警告：跳过包含 #else/#elif 的 KSU 条件块："
        f"{path.relative_to(root)}:{start + 1}"
      )

      continue

    # Entire block is KernelSU-specific.
    removed_blocks += 1
    i = end + 1

  if removed_blocks:
    path.write_text(
      "".join(output),
      encoding="utf-8",
      newline="",
    )

    changed.append(
      (
        str(path.relative_to(root)),
        removed_blocks,
      )
    )

print(f"清理 Hook 文件数：{len(changed)}")

for path, count in changed:
  print(f"  {path}: 删除 {count} 个 KSU 条件块")
PY

echo
echo "==> 删除明显残留的 KSU 配置文件"

find . \
  -path "./.git" -prune -o \
  -type f \
  \( \
    -iname "ksu.config" -o \
    -iname "kernelsu.config" -o \
    -iname "*ksu*.mk" -o \
    -iname "*ksu*.conf" \
  \) \
  -print \
  -delete

echo
echo "==> 检查 KernelSU 残留"

set +e

git grep -nE \
  'CONFIG_KSU|CONFIG_SUSFS|ksu_handle_|ksu_[A-Za-z0-9_]+|KernelSU|kernelsu|drivers/kernelsu|RESUKISU' \
  -- \
  ':!Documentation' \
  ':!LICENSE*' \
  ':!CREDITS'

rc=$?

set -e

if [ "$rc" -eq 0 ]; then
  echo
  echo "错误：内核源码中仍存在 KernelSU/SUSFS 相关内容。"
  echo "请检查上面的文件和行号。"
  exit 2
fi

echo
echo "==> KernelSU 清理完成"
echo "==> 未发现 KSU/SUSFS 源码、配置或集成残留"

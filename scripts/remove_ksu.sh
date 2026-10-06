#!/usr/bin/env bash
set -euo pipefail

# Remove KernelSU-related CONFIG/Kconfig/build configuration from a local
# android_kernel_oneplus_sm8250 checkout.
#
# This script intentionally does NOT regex-delete arbitrary KernelSU C code:
# source hooks must be reverted from their originating commit/patch to avoid
# leaving uncompilable code behind.

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "错误：请在内核 Git 仓库内运行此脚本。" >&2
  exit 1
}
cd "$ROOT"

echo "==> 当前分支"
git branch --show-current

echo
echo "==> 清理 KSU/Kernelsu 配置文件中的配置项"

python3 - <<'PY'
from pathlib import Path
import re

root = Path(".").resolve()

# KSU-specific config symbols used by the common KernelSU integrations.
# Keep the match deliberately narrow so ordinary kernel options such as KPROBES
# are not removed just because KernelSU may use them.
symbol_re = re.compile(
    r"^(?:#\s*)?CONFIG_(?:KSU(?:_[A-Z0-9_]+)?|SUSFS(?:_[A-Z0-9_]+)?)"
    r"(?:\s*=.*|\s+is not set)?\s*$"
)

# KSU-specific standalone build/config references.
text_re = re.compile(
    r"(?i)"
    r"(?:^|\s)"
    r"(?:KSU_CONFIG|KSUD|KERNELSU|KERNEL_SU|ksu\.config)"
    r"(?:\s|$)"
)

config_roots = [
    root / "arch",
    root / "init",
    root / "scripts",
    root / "security",
    root / "kernel",
    root / "fs",
]

candidate_names = {
    "Kconfig",
    "Kconfig.kernelsu",
    "Kconfig.ksu",
    "Makefile",
    "Makefile.ksu",
    "ksu.config",
    ".config",
}

candidate_suffixes = (
    "_defconfig",
    ".config",
    ".cfg",
    ".config.fragment",
)

changed = []

def is_config_candidate(path: Path) -> bool:
    rel = path.relative_to(root)
    name = path.name
    if name in candidate_names:
        return True
    if name.endswith(candidate_suffixes):
        return True
    # Build/config files commonly found in Android kernel trees.
    if name.startswith("build.config"):
        return True
    if name.endswith((".mk", ".bp")) and (
        "config" in name.lower() or "build" in name.lower()
    ):
        return True
    return False

for base in config_roots:
    if not base.exists():
        continue
    for path in base.rglob("*"):
        if not path.is_file() or not is_config_candidate(path):
            continue
        try:
            data = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue

        lines = data.splitlines(keepends=True)
        out = []
        removed = 0

        for line in lines:
            stripped = line.rstrip("\r\n")

            if symbol_re.match(stripped):
                removed += 1
                continue

            # Remove only obviously KSU-specific configuration references.
            if text_re.search(stripped):
                # For a whole-line config/build declaration this is safe.
                # Otherwise leave the line alone and report it for manual review.
                if (
                    stripped.lstrip().startswith(("#", "export ", "KSU_", "CONFIG_KSU"))
                    or "ksu.config" in stripped.lower()
                ):
                    removed += 1
                    continue

            out.append(line)

        if removed:
            path.write_text("".join(out), encoding="utf-8", newline="")
            changed.append((str(path.relative_to(root)), removed))

print(f"修改文件数：{len(changed)}")
for path, count in changed:
    print(f"  {path}: 删除 {count} 行")

PY

echo
echo "==> 删除明显属于 KernelSU 的独立配置文件/目录（若存在）"
find . -type d \( \
  -iname 'KernelSU' -o \
  -iname 'kernelsu' -o \
  -iname 'ksu' \
\) -prune -print -exec rm -rf {} +

find . -type f \( \
  -iname 'ksu.config' -o \
  -iname 'kernelsu.config' -o \
  -iname '*ksu*.mk' -o \
  -iname '*ksu*.conf' \
\) -print -delete

echo
echo "==> 检查残留"
set +e
git grep -nE 'CONFIG_KSU|CONFIG_SUSFS|KernelSU|kernelsu|KSU_CONFIG|ksu\.config' -- \
  ':!Documentation' ':!LICENSE*' ':!CREDITS' ':!.gitmodules'
rc=$?
set -e

if [[ $rc -eq 0 ]]; then
  echo
  echo "警告：仍有 KSU 相关文本残留。"
  echo "这些残留很可能属于源码 Hook/补丁，而不是单纯配置；不要用全局正则删除。"
  echo "请根据上面的文件和行号，对照加入 KernelSU 的原始 commit/patch 做反向回滚。"
  exit 2
fi

echo
echo "==> KSU 配置扫描通过：没有发现 CONFIG_KSU/CONFIG_SUSFS/KernelSU 等残留。"
echo

#!/bin/bash
# ==============================================================================
# build-nabu-rpms.sh
#
# 功能: 从 TwinbornPlate75/nabu_fedora_packages (release 分支) 拉取 spec，
#       实时构建指定的 nabu RPM 包，并把产物整理成可供 dnf --repofrompath
#       使用的本地仓库目录。
#
# 用法:
#   ./build-nabu-rpms.sh <pkg1> [pkg2 ...]
#
# 可选环境变量:
#   NABU_SPEC_REPO   覆盖 spec 源仓库 URL (默认 https://github.com/TwinbornPlate75/nabu_fedora_packages.git)
#   NABU_RPM_OUT     本地仓库输出目录 (默认 $PWD/rpms-local)
#
# 注意:
#   - 仅适用于 aarch64 (构建内核时 --target 由 spec ExclusiveArch 决定)
#   - 依赖 rpmdevtools/spectool/createrepo_c 已安装 (builder 镜像已包含)
#   - Source0 仍从 spec 内 URL (jhuang6451 release) 下载，与 spec 同步
# ==============================================================================

set -euo pipefail

SPEC_REPO="${NABU_SPEC_REPO:-https://github.com/TwinbornPlate75/nabu_fedora_packages.git}"
SPEC_BRANCH="release"
RPM_OUT="${NABU_RPM_OUT:-$PWD/rpms-local}"

if [ $# -lt 1 ]; then
    echo "用法: $0 <pkg1> [pkg2 ...]" >&2
    echo "示例: $0 kernel-sm8150 xiaomi-nabu-firmware nabu-fedora-configs-core" >&2
    exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# 1. 克隆 spec 仓库 (release 分支)
echo "==> Cloning spec repo $SPEC_REPO (branch $SPEC_BRANCH) ..."
git clone --depth 1 -b "$SPEC_BRANCH" "$SPEC_REPO" "$WORK_DIR/packages"

# 2. 建立 rpmbuild 目录树
RPMBUILD_DIR="$WORK_DIR/rpmbuild"
mkdir -p "$RPMBUILD_DIR"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

# 3. 逐个包构建
mkdir -p "$RPM_OUT"

for pkg in "$@"; do
    spec_dir="$WORK_DIR/packages/$pkg"
    spec_file="$spec_dir/$pkg.spec"

    # 支持 utils/ 子目录下的包 (如 utils/swaylock-effects)
    if [ ! -f "$spec_file" ]; then
        spec_dir="$WORK_DIR/packages/utils/$pkg"
        spec_file="$spec_dir/$pkg.spec"
    fi

    if [ ! -f "$spec_file" ]; then
        echo "❎ ERROR: 找不到 spec 文件: $pkg ($spec_file)" >&2
        exit 1
    fi

    # 若 spec 定义了 Source (有需下载的 URL) 才用 spectool 下载;
    # 无 Source 的 spec (如 kernel-sm8150 直接在 %prep 里 git clone) 跳过。
    if grep -qE '^Source[0-9]*:' "$spec_file"; then
        echo "==> [${pkg}] 下载 Source 文件 ..."
        (cd "$spec_dir" && spectool -g -C "$RPMBUILD_DIR/SOURCES" "$pkg.spec")
    else
        echo "==> [${pkg}] spec 无 Source 定义, 跳过 spectool (源码由 %prep 获取)"
    fi

    echo "==> [${pkg}] rpmbuild -ba ..."
    (cd "$spec_dir" && rpmbuild -ba \
        --define "_topdir $RPMBUILD_DIR" \
        "$pkg.spec")
done

# 4. 收集构建产物 (不含 src.rpm 和 debuginfo，避免重复)
echo "==> 收集 RPM 到 $RPM_OUT ..."
find "$RPMBUILD_DIR/RPMS" -type f -name '*.rpm' ! -name '*.src.rpm' ! -name '*-debuginfo-*.rpm' ! -name '*-debugsource-*.rpm' \
    -exec cp -a {} "$RPM_OUT/" \;

# 5. 生成本地仓库元数据
echo "==> createrepo_c $RPM_OUT ..."
createrepo_c "$RPM_OUT"

echo "✅ 构建完成。RPM 已就绪: $RPM_OUT"
echo "RPM_OUT=$RPM_OUT"

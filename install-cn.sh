#!/usr/bin/env sh
# ==============================================================================
#  QL Cloud 国内网络一键安装入口（Release 资产镜像 + 内置指纹校验）
#
#  用法（单行命令，整行复制即可；本脚本与版本绑定，升级时请改用新版本 Release 里的 install-cn.sh）：
#    curl -4 --http1.1 -fL --progress-bar --retry 3 --retry-delay 2 --connect-timeout 15 -o /tmp/qlcloud-install-cn.sh "https://ghfast.top/https://github.com/ccmaoxiong/qlcloud-dist/releases/download/v1.0.3/install-cn.sh" && sudo QL_LICENSE=QLC-xxxx sh /tmp/qlcloud-install-cn.sh
#
#  本脚本与版本绑定：依次尝试国内镜像，从 Release 资产下载 SHA256SUMS 与
#  install.sh，并与此脚本内置指纹（构建发行时写入）逐一比对，全部一致才执行；
#  任一镜像校验失败即换下一个，全部失败则中止——不会运行未经验证的脚本。
#
#  升级：改用新版本 Release 资产里的 install-cn.sh（内置该版本指纹）。
#
#  可选环境变量：
#    QL_CN_MIRROR_BASE_URL  自定义镜像基址（空格分隔多个，按序尝试；自建镜像/调试用，
#                           指完整的 Release 资产基址：<基址>/SHA256SUMS、<基址>/install.sh 可访问）
#    其余 QL_* 变量（QL_LICENSE / QL_PORT / QL_INSTALL_DOCKER …）原样透传给 install.sh
# ==============================================================================
set -eu

QL_REPO="${QL_REPO:-ccmaoxiong/qlcloud-dist}"
# 版本与指纹均由发行构建（tools/build-release.js）写入，勿手工修改
QL_VERSION="v1.0.3"
QL_EXPECTED_INSTALL_SHA256="f4a48ffa4d56a4dcd1d7d5caa3b4a9f4a0bda1585646ed3d75257080e782c738"
QL_EXPECTED_SUMS_SHA256="2d34c4f5d3441b81633c55ce5123c9eaebb74da4a2a503eb8713065ae6ead617"
QL_RELEASE_URL="https://github.com/$QL_REPO/releases/download/$QL_VERSION"
QL_CONNECT_TIMEOUT="${QL_CONNECT_TIMEOUT:-15}"
QL_MAX_TIME="${QL_MAX_TIME:-300}"
QL_RETRIES="${QL_RETRIES:-5}"
TMP_DIR=""

log() {
    printf '%s\n' "==> $*"
}

warn() {
    printf '%s\n' "warning: $*" >&2
}

die() {
    printf '%s\n' "error: $*" >&2
    exit 1
}

mask_license() {
    raw="$1"
    tail="$(printf '%s' "$raw" | tail -c 4 2>/dev/null || true)"
    case "$raw" in
        QLC-*) printf 'QLC-****%s' "$tail" ;;
        *) printf '****%s' "$tail" ;;
    esac
}

cleanup() {
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
}

trap 'cleanup' EXIT HUP INT TERM

have() {
    command -v "$1" >/dev/null 2>&1
}

validate_url() {
    url="$1"
    case "$url" in
        http://* | https://*) ;;
        *) die "非法的镜像地址：$url" ;;
    esac
    case "$url" in
        *[[:space:]]*) die "镜像地址包含空白或控制字符：$url" ;;
    esac
}

download_file() {
    url="$1"
    destination="$2"
    label="${3:-${destination##*/}}"
    temporary="$destination.part"
    validate_url "$url"
    rm -f "$destination" "$temporary"
    log "下载 $label …"
    if have curl; then
        if ! curl -4 --http1.1 -fL --progress-bar --location --retry "$QL_RETRIES" --retry-delay 2 \
            --connect-timeout "$QL_CONNECT_TIMEOUT" --max-time "$QL_MAX_TIME" \
            -H "User-Agent: qlcloud-cn-installer" \
            -o "$temporary" "$url"; then
            rm -f "$temporary"
            warn "下载失败：$label"
            return 1
        fi
    elif have wget; then
        if wget --help 2>&1 | grep -q -- '--show-progress'; then
            progress="--show-progress"
        else
            progress=""
        fi
        if ! wget -4 -q $progress --tries="$QL_RETRIES" --timeout="$QL_CONNECT_TIMEOUT" \
            --header="User-Agent: qlcloud-cn-installer" \
            -O "$temporary" "$url"; then
            rm -f "$temporary"
            warn "下载失败：$label"
            return 1
        fi
    else
        die "需要 curl 或 wget"
    fi
    if [ -s "$temporary" ]; then
        mv -f "$temporary" "$destination"
        log "下载完成：$label（$(wc -c < "$destination" | tr -d ' ') 字节）"
        return 0
    fi
    rm -f "$temporary"
    warn "下载失败：$label（文件为空）"
    return 1
}

sha256_file() {
    file="$1"
    if have sha256sum; then
        sha256sum "$file" | awk '{print $1}'
    elif have shasum; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        die "需要 sha256sum 或 shasum 来计算文件摘要"
    fi
}

verify_sha256() {
    file="$1"
    expected="$2"
    actual="$(sha256_file "$file")"
    [ "$actual" = "$expected" ]
}

# 指纹必须为 64 位十六进制（构建发行时写入）；源码模板中为空，拒绝直接运行
pins_present() {
    case "$QL_EXPECTED_INSTALL_SHA256:$QL_EXPECTED_SUMS_SHA256" in
        *[!0-9a-fA-F:]*) return 1 ;;
    esac
    [ "${#QL_EXPECTED_INSTALL_SHA256}" -eq 64 ] && [ "${#QL_EXPECTED_SUMS_SHA256}" -eq 64 ]
}

mirror_bases() {
    if [ -n "${QL_CN_MIRROR_BASE_URL:-}" ]; then
        # 自定义基址（完整 Release 资产基址），空格分隔多个，按序尝试
        for base in $QL_CN_MIRROR_BASE_URL; do
            printf '%s\n' "${base%/}"
        done
        return
    fi
    # 默认：镜像前缀 + 官方 Release 资产路径；最后回退直连
    printf '%s\n' \
        "https://ghfast.top/$QL_RELEASE_URL" \
        "https://gh-proxy.com/$QL_RELEASE_URL" \
        "https://ghproxy.net/$QL_RELEASE_URL" \
        "https://gh.acmsz.top/$QL_RELEASE_URL" \
        "https://mirror.ghproxy.com/$QL_RELEASE_URL" \
        "$QL_RELEASE_URL"
}

# 从镜像完整基址反推 QL_DOWNLOAD_BASE_URL（install.sh 用它把发行包下载也走同一镜像）
download_prefix_for_base() {
    base="$1"
    case "$base" in
        *"$QL_RELEASE_URL")
            prefix="${base%"$QL_RELEASE_URL"}"
            printf '%s' "${prefix%/}"
            ;;
        *) printf '%s' "" ;;
    esac
}

prepare_mirror() {
    base="$1"
    sums="$2"
    installer="$3"
    if ! download_file "$base/SHA256SUMS" "$sums"; then
        return 1
    fi
    if ! verify_sha256 "$sums" "$QL_EXPECTED_SUMS_SHA256"; then
        warn "镜像校验清单指纹不符：$base"
        return 1
    fi
    if ! download_file "$base/install.sh" "$installer"; then
        return 1
    fi
    if ! verify_sha256 "$installer" "$QL_EXPECTED_INSTALL_SHA256"; then
        warn "安装脚本指纹不符：$base"
        return 1
    fi
    return 0
}

main() {
    # 付费发行：本地先拦一道，无授权密钥时不下载任何文件（深度 Ed25519 验签在 install.sh 内）
    QL_LICENSE_VALUE="${QL_LICENSE:-${QL_LICENSE_KEY:-}}"
    [ -n "$QL_LICENSE_VALUE" ] || die "本软件是付费发行版：请设置 QL_LICENSE 为你的授权密钥，例如
  curl -4 --http1.1 -fL --progress-bar --retry 3 --retry-delay 2 --connect-timeout 15 -o /tmp/qlcloud-install-cn.sh \"https://ghfast.top/https://github.com/ccmaoxiong/qlcloud-dist/releases/download/v1.0.3/install-cn.sh\" && sudo QL_LICENSE=QLC-xxx sh /tmp/qlcloud-install-cn.sh
请向厂商购买授权后重试。"

    if [ "$(id -u)" -ne 0 ] && [ "${QL_CN_ALLOW_NONROOT:-0}" != "1" ]; then
        die "请用 root 运行（sudo QL_LICENSE=QLC-xxx sh $0）"
    fi

    log "授权密钥：$(mask_license "$QL_LICENSE_VALUE")"
    log "正在下载安装脚本；Ed25519 验签通过后将显示客户名称、到期时间与最大安装数"
    log "下载过程中会显示进度条，请稍候…"

    if ! pins_present; then
        if [ "${QL_CN_ALLOW_UNVERIFIED:-0}" = "1" ]; then
            warn "QL_CN_ALLOW_UNVERIFIED=1：跳过镜像指纹校验（仅限本地调试，禁止用于正式安装）"
        else
            die "install-cn.sh 未携带发行指纹（源码模板）：请使用 Release 资产中的 install-cn.sh；本地调试可设 QL_CN_ALLOW_UNVERIFIED=1 跳过校验"
        fi
    fi

    TMP_DIR="$(mktemp -d)"
    sums="$TMP_DIR/SHA256SUMS"
    installer="$TMP_DIR/install.sh"

    for base in $(mirror_bases); do
        log "尝试镜像：$base"
        if prepare_mirror "$base" "$sums" "$installer"; then
            log "镜像校验通过：$base"
            download_prefix="$(download_prefix_for_base "$base")"
            if [ -n "$download_prefix" ]; then
                log "发行包下载与安装脚本同源：$download_prefix"
                QL_LICENSE="$QL_LICENSE_VALUE" \
                    QL_DOWNLOAD_BASE_URL="$download_prefix" \
                    QL_USE_GITHUB_API=0 \
                    QL_VERSION="$QL_VERSION" \
                    sh "$installer" "$@"
            else
                QL_LICENSE="$QL_LICENSE_VALUE" \
                    QL_USE_GITHUB_API=0 \
                    QL_VERSION="$QL_VERSION" \
                    sh "$installer" "$@"
            fi
            exit $?
        fi
        warn "镜像不可用或校验失败：$base"
    done

    die "所有镜像均失败；可设置 QL_CN_MIRROR_BASE_URL 指向自建镜像后重试"
}

if [ "${QL_CN_LIB_ONLY:-0}" != "1" ]; then
    main "$@"
fi

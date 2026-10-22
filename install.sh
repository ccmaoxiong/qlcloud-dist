#!/usr/bin/env sh
# ==============================================================================
#  QL Cloud · 青龙面板自助开通平台 —— 云端一键安装 / 升级脚本（Linux）
#
#  本软件是付费闭源商业软件：安装前会用内嵌公钥在本地校验授权密钥（Ed25519），
#  密钥缺失、签名不符或已过期会立即中止，不会下载任何文件。
#
#  一键安装（单行命令，整行复制即可；重复执行同一命令即为升级，数据、配置、授权密钥都会保留）：
#    curl --http1.1 -fL --progress-bar --retry 5 --retry-delay 2 https://raw.githubusercontent.com/ccmaoxiong/qlcloud-dist/main/install.sh -o /tmp/qlcloud-install.sh && sudo QL_LICENSE=QLC-xxxx sh /tmp/qlcloud-install.sh
#
#  国内网络（GitHub 直连慢）：用 install-cn.sh（单行命令见发行说明），或加 QL_DOWNLOAD_BASE_URL=https://ghfast.top
#
#  常用环境变量：
#    QL_LICENSE       厂商签发的授权密钥（必填，QLC-…）
#    QL_VERSION       指定版本，如 v1.0.3；默认 v1.0.3；latest = 取最新 Release
#    QL_PORT          服务端口，默认 3000
#    QL_INSTALL_DIR   程序目录，默认 /opt/qlcloud
#    QL_DATA_DIR      数据目录，默认 /var/lib/qlcloud
#    QL_CONFIG_DIR    配置目录，默认 /etc/qlcloud
#    QL_SERVICE_USER  服务用户，默认 qlcloud
#    QL_JWT_SECRET    固定 JWT 密钥（默认自动生成并写入配置文件）
#    QL_DOWNLOAD_BASE_URL  下载镜像前缀（如 https://ghfast.top），可加速 GitHub 下载
#    QL_LOCAL_DIR     离线安装：指向本地发布目录（含 .tar.gz 与 SHA256SUMS）
#    QL_INSTALL_DOCKER=1   顺带安装 Docker 并拉取青龙镜像（默认只提示）
#    QL_OPEN_FIREWALL=1    用 ufw / firewalld 放行服务端口（默认只提示）
#    QL_UNINSTALL=1        卸载（保留数据目录）；QL_PURGE=1 连数据一起删除
# ==============================================================================
set -eu

QL_REPO="${QL_REPO:-ccmaoxiong/qlcloud-dist}"
QL_VERSION="${QL_VERSION:-v1.0.3}"
QL_GITHUB_API_URL="${QL_GITHUB_API_URL:-https://api.github.com}"
QL_GITHUB_DOWNLOAD_URL="${QL_GITHUB_DOWNLOAD_URL:-https://github.com}"
QL_DOWNLOAD_BASE_URL="${QL_DOWNLOAD_BASE_URL:-}"
QL_LOCAL_DIR="${QL_LOCAL_DIR:-}"
QL_TOKEN="${QL_TOKEN:-${GITHUB_TOKEN:-}}"
QL_USE_GITHUB_API="${QL_USE_GITHUB_API:-}"
QL_CONNECT_TIMEOUT="${QL_CONNECT_TIMEOUT:-15}"
QL_MAX_TIME="${QL_MAX_TIME:-600}"
QL_RETRIES="${QL_RETRIES:-5}"

QL_INSTALL_DIR="${QL_INSTALL_DIR:-/opt/qlcloud}"
QL_DATA_DIR="${QL_DATA_DIR:-/var/lib/qlcloud}"
QL_CONFIG_DIR="${QL_CONFIG_DIR:-/etc/qlcloud}"
QL_SERVICE_USER="${QL_SERVICE_USER:-qlcloud}"
QL_PORT="${QL_PORT:-3000}"
QL_INSTALL_DOCKER="${QL_INSTALL_DOCKER:-}"
QL_OPEN_FIREWALL="${QL_OPEN_FIREWALL:-}"
QL_UNINSTALL="${QL_UNINSTALL:-}"
QL_PURGE="${QL_PURGE:-}"

SERVICE_NAME="qlcloud"
TMP_DIR=""

# --- 付费授权门（仅服务端；脚本内只内嵌公钥，私钥由厂商离线保管）----------------
QL_LICENSE="${QL_LICENSE:-${QL_LICENSE_KEY:-}}"
QL_LICENSE_PUBLIC_KEY="1z82OF0KYipIrvyS0rel7fK6kYJpMkPDqm4wKJvEHfk"

LICENSE_CUSTOMER=""
LICENSE_EXPIRES_TEXT=""
LICENSE_MAX_INSTALLS=""
LICENSE_MASKED=""

case "$QL_VERSION" in
    v*) ;;
    latest | LATEST | "") ;;
    *) QL_VERSION="v$QL_VERSION" ;;
esac

case "$QL_USE_GITHUB_API" in
    "")
        if [ -n "$QL_TOKEN" ]; then QL_USE_GITHUB_API=1; else QL_USE_GITHUB_API=0; fi
        ;;
    1 | true | yes) QL_USE_GITHUB_API=1 ;;
    *) QL_USE_GITHUB_API=0 ;;
esac

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

human_size() {
    file="$1"
    [ -f "$file" ] || { printf '0 B'; return 0; }
    bytes="$(wc -c < "$file" | tr -d ' ')"
    if [ "$bytes" -ge 1048576 ]; then
        awk -v b="$bytes" 'BEGIN { printf "%.1f MB", b / 1048576 }'
    elif [ "$bytes" -ge 1024 ]; then
        awk -v b="$bytes" 'BEGIN { printf "%.1f KB", b / 1024 }'
    else
        printf '%s B' "$bytes"
    fi
}

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "请用 root 运行（sudo sh install.sh），或设置 QL_INSTALL_DIR 等变量以普通用户安装"
    fi
}

have() {
    command -v "$1" >/dev/null 2>&1
}

# 写入/刷新环境文件中的单个键值（面板内一键更新依赖 QL_VERSION / QL_UPDATE_REPO）
set_env_line() {
    key="$1"
    value="$2"
    file="$3"
    [ -n "$value" ] || return 0
    if grep -q "^$key=" "$file" 2>/dev/null; then
        sed -i "s|^$key=.*|$key=$value|" "$file" 2>/dev/null || true
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}

validate_url() {
    url="$1"
    case "$url" in
        http://* | https://*) ;;
        *) die "非法的下载地址：$url" ;;
    esac
    case "$url" in
        *[[:space:]]*) die "下载地址包含空白或控制字符：$url" ;;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) printf '%s' "amd64" ;;
        aarch64 | arm64) printf '%s' "arm64" ;;
        *) die "不支持的 CPU 架构：$(uname -m)（可用 QL_LOCAL_DIR 离线安装或联系我们）" ;;
    esac
}

http_get() {
    url="$1"
    accept="${2:-application/vnd.github+json}"
    validate_url "$url"
    if have curl; then
        if [ -n "$QL_TOKEN" ]; then
            curl --http1.1 -fsSL --location --retry "$QL_RETRIES" --retry-delay 2 \
                --connect-timeout "$QL_CONNECT_TIMEOUT" --max-time "$QL_MAX_TIME" \
                -H "Authorization: Bearer $QL_TOKEN" \
                -H "Accept: $accept" \
                -H "X-GitHub-Api-Version: 2022-11-28" \
                -H "User-Agent: qlcloud-installer" \
                "$url"
        else
            curl --http1.1 -fsSL --location --retry "$QL_RETRIES" --retry-delay 2 \
                --connect-timeout "$QL_CONNECT_TIMEOUT" --max-time "$QL_MAX_TIME" \
                -H "Accept: $accept" \
                -H "User-Agent: qlcloud-installer" \
                "$url"
        fi
        return
    fi
    if have wget; then
        if [ -n "$QL_TOKEN" ]; then
            wget -qO- --tries="$QL_RETRIES" --timeout="$QL_CONNECT_TIMEOUT" \
                --header="Authorization: Bearer $QL_TOKEN" \
                --header="Accept: $accept" \
                --header="User-Agent: qlcloud-installer" \
                "$url"
        else
            wget -qO- --tries="$QL_RETRIES" --timeout="$QL_CONNECT_TIMEOUT" \
                --header="Accept: $accept" \
                --header="User-Agent: qlcloud-installer" \
                "$url"
        fi
        return
    fi
    die "需要 curl 或 wget"
}

download_file() {
    url="$1"
    destination="$2"
    label="${3:-${destination##*/}}"
    validate_url "$url"
    log "下载 $label …"
    if have curl; then
        if curl --http1.1 -fL --progress-bar --location --retry "$QL_RETRIES" --retry-delay 2 \
            --connect-timeout "$QL_CONNECT_TIMEOUT" --max-time "$QL_MAX_TIME" \
            -H "User-Agent: qlcloud-installer" \
            -o "$destination" "$url"; then
            log "下载完成：$label（$(human_size "$destination")）"
            return 0
        fi
        rm -f "$destination"
        warn "下载失败：$label"
        return 1
    fi
    if have wget; then
        if wget --help 2>&1 | grep -q -- '--show-progress'; then
            wget -q --show-progress --tries="$QL_RETRIES" --timeout="$QL_CONNECT_TIMEOUT" \
                --header="User-Agent: qlcloud-installer" \
                -O "$destination" "$url" \
                && { log "下载完成：$label（$(human_size "$destination")）"; return 0; }
        else
            wget -q --tries="$QL_RETRIES" --timeout="$QL_CONNECT_TIMEOUT" \
                --header="User-Agent: qlcloud-installer" \
                -O "$destination" "$url" \
                && { log "下载完成：$label（$(human_size "$destination")）"; return 0; }
        fi
        rm -f "$destination"
        warn "下载失败：$label"
        return 1
    fi
    die "需要 curl 或 wget"
}

# --- 版本与发行资产 -------------------------------------------------------------

github_base() {
    printf '%s' "${QL_GITHUB_DOWNLOAD_URL%/}/$QL_REPO"
}

resolve_latest_version() {
    info_json=""
    if [ "$QL_USE_GITHUB_API" = "1" ]; then
        info_json="$(http_get "${QL_GITHUB_API_URL%/}/repos/$QL_REPO/releases/latest" 2>/dev/null || true)"
    fi
    tag=""
    if [ -n "$info_json" ]; then
        tag="$(printf '%s' "$info_json" | tr ',' '\n' | sed -n 's/.*"tag_name":"\([^"]*\)".*/\1/p' | head -n1)"
    fi
    if [ -z "$tag" ]; then
        tag="$(http_get "$(github_base)/releases/latest" "text/html" 2>/dev/null \
            | sed -n 's#.*releases/tag/\(v[0-9][0-9.]*\).*#\1#p' | head -n1 || true)"
    fi
    [ -n "$tag" ] || die "无法确定最新版本，请用 QL_VERSION=vX.Y.Z 指定"
    QL_VERSION="$tag"
    log "使用最新版本：$QL_VERSION"
}

load_release() {
    if [ -n "$QL_DOWNLOAD_BASE_URL" ] || [ "$QL_USE_GITHUB_API" != "1" ]; then
        return
    fi
    api_base="${QL_GITHUB_API_URL%/}"
    if RELEASE_JSON="$(http_get "$api_base/repos/$QL_REPO/releases/tags/$QL_VERSION" 2>/dev/null)" && [ -n "$RELEASE_JSON" ]; then
        return
    fi
    RELEASE_JSON=""
    warn "GitHub Release 元数据不可用，改用公开下载地址"
}

asset_id() {
    asset_name="$1"
    printf '%s\n' "$RELEASE_JSON" | tr ',' '\n' | tr -d '\r' | awk -v wanted="\"name\":\"$asset_name\"" '
        /"id":[[:space:]]*[0-9]+/ {
            line = $0
            sub(/^.*"id":[[:space:]]*/, "", line)
            sub(/[^0-9].*$/, "", line)
            id = line
        }
        index($0, wanted) > 0 {
            print id
            exit
        }
    '
}

if [ -n "$QL_LOCAL_DIR" ]; then
    [ -d "$QL_LOCAL_DIR" ] || die "QL_LOCAL_DIR 不是目录：$QL_LOCAL_DIR"
    [ -f "$QL_LOCAL_DIR/SHA256SUMS" ] || die "QL_LOCAL_DIR 缺少 SHA256SUMS：$QL_LOCAL_DIR"
fi

download_asset() {
    asset_name="$1"
    destination="$2"
    if [ -n "$QL_LOCAL_DIR" ]; then
        [ -f "$QL_LOCAL_DIR/$asset_name" ] || die "本地发布目录缺少资产：$QL_LOCAL_DIR/$asset_name"
        cp -f "$QL_LOCAL_DIR/$asset_name" "$destination"
        return
    fi
    download_base="${QL_DOWNLOAD_BASE_URL%/}"
    if [ -n "$download_base" ]; then
        download_file "$download_base/$(github_base)/releases/download/$QL_VERSION/$asset_name" "$destination"
        return
    fi
    id=""
    if [ "$QL_USE_GITHUB_API" = "1" ] && [ -n "$RELEASE_JSON" ]; then
        id="$(asset_id "$asset_name")"
    fi
    case "$id" in
        '' | *[!0-9]*) id="" ;;
    esac
    api_base="${QL_GITHUB_API_URL%/}"
    if [ -n "$id" ] && download_file "$api_base/repos/$QL_REPO/releases/assets/$id" "$destination"; then
        return
    fi
    [ -z "$id" ] || warn "GitHub API 下载失败，改用公开下载地址：$asset_name"
    download_file "$(github_base)/releases/download/$QL_VERSION/$asset_name" "$destination"
}

checksum_for_asset() {
    asset_name="$1"
    sums="$2"
    awk -v name="$asset_name" '
        {
            checksum = $1
            file = $2
            sub(/\r$/, "", checksum)
            sub(/\r$/, "", file)
            sub(/^\*/, "", file)
            sub(/^\.\//, "", file)
            if (length(checksum) == 64 && file == name) {
                print tolower(checksum)
                exit
            }
        }
    ' "$sums"
}

download_checksums() {
    destination="$1"
    manifest_asset="qlcloud-server-$QL_VERSION-linux-amd64.tar.gz"
    if [ -n "$QL_LOCAL_DIR" ]; then
        cp -f "$QL_LOCAL_DIR/SHA256SUMS" "$destination"
        [ -n "$(checksum_for_asset "$manifest_asset" "$destination")" ] || die "本地 SHA256SUMS 内容无效"
        return
    fi
    download_base="${QL_DOWNLOAD_BASE_URL%/}"
    if [ -n "$download_base" ]; then
        download_file "$download_base/$(github_base)/releases/download/$QL_VERSION/SHA256SUMS" "$destination"
        [ -n "$(checksum_for_asset "$manifest_asset" "$destination")" ] || die "下载到的 SHA256SUMS 内容无效"
        return
    fi
    id=""
    if [ "$QL_USE_GITHUB_API" = "1" ] && [ -n "$RELEASE_JSON" ]; then
        id="$(asset_id "SHA256SUMS")"
    fi
    case "$id" in
        '' | *[!0-9]*) id="" ;;
    esac
    api_base="${QL_GITHUB_API_URL%/}"
    if [ -n "$id" ] && download_file "$api_base/repos/$QL_REPO/releases/assets/$id" "$destination" \
        && [ -n "$(checksum_for_asset "$manifest_asset" "$destination")" ]; then
        return
    fi
    [ -z "$id" ] || warn "GitHub API 的 SHA256SUMS 不可用，改用公开下载地址"
    download_file "$(github_base)/releases/download/$QL_VERSION/SHA256SUMS" "$destination"
    [ -n "$(checksum_for_asset "$manifest_asset" "$destination")" ] || die "下载到的 SHA256SUMS 内容无效"
}

# --- 授权校验（POSIX sh：需要 base64 + openssl + perl）--------------------------

b64url_decode() {
    # stdin: 未填充的 base64url（可能含 '~' 分组分隔符）；stdout: 二进制
    tr -d "~ \t\r\n" | tr "_-" "/+" | awk '{
        mod = length($0) % 4
        if (mod == 2) printf "%s==", $0
        else if (mod == 3) printf "%s=", $0
        else if (mod == 0) printf "%s", $0
        else { printf "\nbase64 长度非法\n" > "/dev/stderr"; exit 1 }
    }' | base64 -d 2>/dev/null
}

hex_to_binary() {
    # 可移植的 hex -> 二进制（有 openssl 的机器一般都有 perl）
    perl -ne 'chomp; print pack("H*", $_)'
}

verify_license() {
    [ -n "$QL_LICENSE" ] || die "本软件是付费发行版：请设置 QL_LICENSE 为你的授权密钥，例如
  curl --http1.1 -fL --progress-bar --retry 5 --retry-delay 2 https://raw.githubusercontent.com/ccmaoxiong/qlcloud-dist/main/install.sh -o /tmp/qlcloud-install.sh && sudo QL_LICENSE=QLC-xxx sh /tmp/qlcloud-install.sh
如需购买授权请联系厂商。"
    have base64 || die "校验授权需要 base64（请安装 coreutils）"
    have openssl || die "校验授权需要 openssl"
    have perl || die "校验授权需要 perl"
    have awk || die "校验授权需要 awk"
    have date || die "校验授权需要 date"

    key="$QL_LICENSE"
    case "$(printf '%s' "$key" | tr 'a-z' 'A-Z')" in
        QLC-*) key="${key#????}" ;;
        *) die "授权密钥格式无效（应以 QLC- 开头）" ;;
    esac
    payload_b64="${key%%.*}"
    sig_b64="${key#*.}"
    [ "$payload_b64" != "$key" ] || die "授权密钥格式无效（缺少签名段）"

    LIC_TMP="$(mktemp -d)"
    trap 'rm -rf "$LIC_TMP"' EXIT HUP INT TERM

    printf '%s' "$payload_b64" | b64url_decode > "$LIC_TMP/payload" \
        || die "授权密钥载荷无法解码"
    [ -s "$LIC_TMP/payload" ] || die "授权密钥载荷无法解码"
    printf '%s' "$sig_b64" | b64url_decode > "$LIC_TMP/sig" \
        || die "授权密钥签名无法解码"
    [ "$(wc -c < "$LIC_TMP/sig" | tr -d ' ')" = "64" ] || die "授权签名长度非法"

    printf '%s' "$QL_LICENSE_PUBLIC_KEY" | b64url_decode | od -An -tx1 -v | tr -d ' \n' > "$LIC_TMP/pub.hex"
    {
        printf '302a300506032b6570032100'
        cat "$LIC_TMP/pub.hex"
    } | hex_to_binary > "$LIC_TMP/pub.der"

    if ! openssl pkeyutl -verify -pubin -keyform DER \
        -inkey "$LIC_TMP/pub.der" -rawin \
        -in "$LIC_TMP/payload" -sigfile "$LIC_TMP/sig" >/dev/null 2>&1; then
        die "授权密钥验签失败（密钥被篡改或不属于本产品）"
    fi

    case "$(cut -d'|' -f1 < "$LIC_TMP/payload")" in
        v1) ;;
        *) die "授权密钥载荷版本不受支持" ;;
    esac
    expires="$(cut -d'|' -f3 < "$LIC_TMP/payload")"
    case "$expires" in
        '' | *[!0-9]*) die "授权密钥的到期时间字段无效" ;;
    esac
    now="$(date +%s)"
    [ "$now" -le "$expires" ] || die "授权已于 $(date -d "@$expires" +%Y-%m-%d 2>/dev/null || date -r "$expires" +%Y-%m-%d 2>/dev/null || printf '%s' "$expires") 到期，请联系厂商续期"

    customer="$(cut -d'|' -f2 < "$LIC_TMP/payload")"
    max_installs="$(cut -d'|' -f4 < "$LIC_TMP/payload")"
    expires_text="$(date -d "@$expires" +%Y-%m-%d 2>/dev/null || date -r "$expires" +%Y-%m-%d 2>/dev/null || printf '%s' "$expires")"
    LICENSE_CUSTOMER="$customer"
    LICENSE_EXPIRES_TEXT="$expires_text"
    case "$max_installs" in
        '' | 0 | *[!0-9]*) LICENSE_MAX_INSTALLS="不限" ;;
        *) LICENSE_MAX_INSTALLS="$max_installs" ;;
    esac
    LICENSE_MASKED="$(mask_license "$QL_LICENSE")"
    log "授权校验通过"
    log "  授权状态：有效"
    log "  客户名称：$LICENSE_CUSTOMER"
    log "  到期时间：$LICENSE_EXPIRES_TEXT"
    log "  最大安装数：$LICENSE_MAX_INSTALLS"
    log "  授权密钥：$LICENSE_MASKED"
    rm -rf "$LIC_TMP"
    trap - EXIT HUP INT TERM
}

sha256_file() {
    file="$1"
    if have sha256sum; then
        sha256sum "$file" | awk '{print $1}'
    elif have shasum; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        die "需要 sha256sum 或 shasum"
    fi
}

verify_asset() {
    asset_name="$1"
    file="$2"
    sums="$3"
    expected="$(checksum_for_asset "$asset_name" "$sums")"
    [ -n "$expected" ] || die "SHA256SUMS 中没有 $asset_name 的记录"
    actual="$(sha256_file "$file")"
    [ "$actual" = "$expected" ] || die "$asset_name 校验失败（期望 $expected，实际 $actual）"
    log "$asset_name SHA256 校验通过"
}

generate_secret() {
    if have openssl; then
        openssl rand -hex 32
        return
    fi
    if [ -r /dev/urandom ] && have od; then
        od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
        return
    fi
    die "无法生成安全的 JWT 密钥，请安装 openssl 或设置 QL_JWT_SECRET"
}

ensure_user() {
    if id -u "$QL_SERVICE_USER" >/dev/null 2>&1; then
        return
    fi
    if have useradd; then
        useradd --system --home-dir "$QL_INSTALL_DIR" --shell /usr/sbin/nologin "$QL_SERVICE_USER"
    elif have adduser; then
        adduser -S -D -H -h "$QL_INSTALL_DIR" -s /sbin/nologin "$QL_SERVICE_USER"
    else
        die "请手动创建服务用户 $QL_SERVICE_USER，或用 QL_SERVICE_USER 指定已有用户"
    fi
}

write_systemd_unit() {
    unit_path="/etc/systemd/system/$SERVICE_NAME.service"
    cat > "$unit_path" <<EOF
[Unit]
Description=QL Cloud server (qinglong panel hosting platform)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=$QL_SERVICE_USER
Group=$QL_SERVICE_USER
WorkingDirectory=$QL_INSTALL_DIR
EnvironmentFile=$QL_CONFIG_DIR/qlcloud.env
ExecStart=$QL_INSTALL_DIR/qlcloud-server
Restart=always
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$unit_path"
    if have systemctl; then
        systemctl daemon-reload
        systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
        systemctl restart "$SERVICE_NAME"
        log "systemd 服务已启动：$SERVICE_NAME"
    else
        warn "未检测到 systemd；请手工启动：$QL_INSTALL_DIR/qlcloud-server"
    fi
}

install_binary() {
    arch="$(detect_arch)"
    asset_name="qlcloud-server-$QL_VERSION-linux-$arch.tar.gz"
    download_asset "$asset_name" "$TMP_DIR/$asset_name"
    verify_asset "$asset_name" "$TMP_DIR/$asset_name" "$TMP_DIR/SHA256SUMS"

    mkdir -p "$TMP_DIR/extract"
    if have tar && tar -xzf "$TMP_DIR/$asset_name" -C "$TMP_DIR/extract" 2>/dev/null; then
        :
    elif have gzip && have tar; then
        gzip -dc "$TMP_DIR/$asset_name" | tar -xf - -C "$TMP_DIR/extract"
    else
        die "需要 tar（支持 gzip）来解开发行包"
    fi
    [ -f "$TMP_DIR/extract/qlcloud-server" ] || die "发行包结构异常：缺少 qlcloud-server"
    [ "$(wc -c < "$TMP_DIR/extract/qlcloud-server" | tr -d ' ')" -gt 1000000 ] || die "发行包中的可执行文件异常（过小）"
    magic="$(head -c 4 "$TMP_DIR/extract/qlcloud-server" | od -An -c -v | tr -d ' \n')"
    case "$magic" in
        '177ELF') ;;
        *) die "发行包中的文件不是 Linux 可执行文件（magic=$magic）" ;;
    esac

    install -m 0755 "$TMP_DIR/extract/qlcloud-server" "$QL_INSTALL_DIR/qlcloud-server"
    log "程序已安装：$QL_INSTALL_DIR/qlcloud-server"
}

health_check() {
    if ! have curl && ! have wget; then
        return
    fi
    i=0
    while [ "$i" -lt 30 ]; do
        if have curl; then
            if curl -fsS --max-time 3 "http://127.0.0.1:$QL_PORT/api/site" >/dev/null 2>&1; then
                log "服务自检通过：http://127.0.0.1:$QL_PORT/api/site"
                return
            fi
        else
            if wget -q -T 3 -O /dev/null "http://127.0.0.1:$QL_PORT/api/site" 2>/dev/null; then
                log "服务自检通过：http://127.0.0.1:$QL_PORT/api/site"
                return
            fi
        fi
        i=$((i + 1))
        sleep 1
    done
    warn "服务自检超时：请用 journalctl -u $SERVICE_NAME -n 50 查看日志（授权过期/端口占用等）"
}

install_docker_if_requested() {
    if have docker; then
        if [ "$QL_INSTALL_DOCKER" = "1" ] && have systemctl; then
            systemctl start docker >/dev/null 2>&1 || true
        fi
    else
        if [ "$QL_INSTALL_DOCKER" = "1" ]; then
            log "安装 Docker（get.docker.com）…"
            if have curl; then
                curl -fsSL --connect-timeout "$QL_CONNECT_TIMEOUT" https://get.docker.com | sh || warn "Docker 安装失败，请手工安装"
            elif have wget; then
                wget -qO- --timeout="$QL_CONNECT_TIMEOUT" https://get.docker.com | sh || warn "Docker 安装失败，请手工安装"
            fi
            if have systemctl; then systemctl enable --now docker >/dev/null 2>&1 || true; fi
        else
            warn "未检测到 Docker：本平台需要 Docker 承载青龙实例（安装：curl -fsSL https://get.docker.com | sh，或重跑本脚本时加 QL_INSTALL_DOCKER=1）"
        fi
    fi
    if have docker; then
        docker pull whyour/qinglong:latest >/dev/null 2>&1 && log "青龙镜像已就绪：whyour/qinglong:latest" || warn "青龙镜像拉取失败（平台仍可用，开通实例时再重试）"
    fi
    # 服务用户需加入 docker 组（否则服务进程无权访问 /var/run/docker.sock，无法创建实例）
    if have docker && [ -r /etc/group ] && grep -q '^docker:' /etc/group; then
        if ! id -nG "$QL_SERVICE_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
            if have usermod; then
                usermod -aG docker "$QL_SERVICE_USER" 2>/dev/null || true
            elif have adduser; then
                adduser "$QL_SERVICE_USER" docker >/dev/null 2>&1 || true
            fi
            if id -nG "$QL_SERVICE_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
                log "已将 $QL_SERVICE_USER 加入 docker 组"
                if have systemctl; then systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true; fi
            else
                warn "未能将 $QL_SERVICE_USER 加入 docker 组，请手工执行：usermod -aG docker $QL_SERVICE_USER && systemctl restart $SERVICE_NAME"
            fi
        fi
    fi
}

open_firewall_if_requested() {
    if [ "$QL_OPEN_FIREWALL" != "1" ]; then
        warn "如无法访问，请放行 TCP $QL_PORT（ufw allow $QL_PORT 或 firewall-cmd --add-port=$QL_PORT/tcp --permanent）"
        return
    fi
    if have ufw; then
        ufw allow "$QL_PORT"/tcp >/dev/null 2>&1 && log "ufw 已放行 $QL_PORT/tcp" || warn "ufw 放行失败"
    elif have firewall-cmd; then
        firewall-cmd --permanent --add-port="$QL_PORT"/tcp >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1 \
            && log "firewalld 已放行 $QL_PORT/tcp" || warn "firewalld 放行失败"
    else
        warn "未检测到 ufw / firewalld，请手工放行 TCP $QL_PORT"
    fi
}

install_server() {
    [ "$QL_VERSION" = "latest" ] && resolve_latest_version
    mkdir -p "$QL_INSTALL_DIR" "$QL_CONFIG_DIR" "$QL_DATA_DIR"
    ensure_user

    # 授权密钥落盘：服务端每次启动与每 6 小时复验
    license_file="$QL_CONFIG_DIR/license.key"
    printf '%s\n' "$QL_LICENSE" > "$license_file"
    if chown root:"$QL_SERVICE_USER" "$license_file" 2>/dev/null; then
        chmod 0640 "$license_file"
    else
        chown "$QL_SERVICE_USER" "$license_file" 2>/dev/null || true
        chmod 0600 "$license_file"
    fi
    log "授权密钥已写入：$license_file"

    install_binary

    env_file="$QL_CONFIG_DIR/qlcloud.env"
    if [ ! -f "$env_file" ]; then
        jwt_secret="${QL_JWT_SECRET:-$(generate_secret)}"
        cat > "$env_file" <<EOF
PORT=$QL_PORT
DATA_DIR=$QL_DATA_DIR
QL_LICENSE_FILE=$license_file
JWT_SECRET=$jwt_secret
EOF
        chmod 0600 "$env_file"
    else
        log "保留已有配置文件：$env_file（如需改端口请编辑该文件后重启服务）"
    fi
    # 面板内「检查更新 / 在线更新」所需：当前版本与发行仓库（升级时同步刷新，面板启动即可读）
    set_env_line QL_VERSION "$QL_VERSION" "$env_file"
    set_env_line QL_UPDATE_REPO "$QL_REPO" "$env_file"
    if [ -n "${QL_UPDATE_MIRRORS:-}" ]; then
        set_env_line QL_UPDATE_MIRRORS "$QL_UPDATE_MIRRORS" "$env_file"
    fi
    printf '%s\n' "$QL_VERSION" > "$QL_DATA_DIR/installed-version"
    if chown root:"$QL_SERVICE_USER" "$env_file" 2>/dev/null; then chmod 0640 "$env_file"; fi

    chown -R "$QL_SERVICE_USER:$QL_SERVICE_USER" "$QL_DATA_DIR" "$QL_INSTALL_DIR" 2>/dev/null || true
    write_systemd_unit
    install_docker_if_requested
    health_check
    open_firewall_if_requested

    ip_hint="<服务器公网 IP>"
    log "QL Cloud $QL_VERSION 安装完成"
    log "授权信息：$LICENSE_CUSTOMER · 到期 $LICENSE_EXPIRES_TEXT · 最大安装数 $LICENSE_MAX_INSTALLS · $LICENSE_MASKED"
    log "用户面板：http://$ip_hint:$QL_PORT"
    log "管理后台：http://$ip_hint:$QL_PORT/admin-panel"
    log "默认管理员：admin@example.com / admin12345（登录后请立即修改）"
    log "默认用户：user@example.com / user12345（登录后请立即修改）"
    log "数据目录：$QL_DATA_DIR · 配置：$env_file"
warn "生产环境请在前面加 HTTPS 反向代理，并放行青龙实例端口段（默认 15700-15999，可在管理后台调整）"
}

do_uninstall() {
    if have systemctl; then
        systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi
    rm -f "/etc/systemd/system/$SERVICE_NAME.service"
    have systemctl && systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf "$QL_INSTALL_DIR" "$QL_CONFIG_DIR"
    if [ "$QL_PURGE" = "1" ]; then
        rm -rf "$QL_DATA_DIR"
        log "已卸载（含数据目录 $QL_DATA_DIR）"
    else
        log "已卸载程序与配置；数据保留在 $QL_DATA_DIR（如需删除：QL_PURGE=1 重跑，或手动 rm -rf）"
    fi
}

main() {
    need_root
    [ "$(uname -s)" = "Linux" ] || die "install.sh 仅支持 Linux（其他系统请手工部署或使用容器）"

    if [ "$QL_UNINSTALL" = "1" ]; then
        do_uninstall
        return 0
    fi

    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

    # 先验授权，再下载任何文件
    verify_license
    if [ -n "$QL_LOCAL_DIR" ]; then
        log "离线安装模式：$QL_LOCAL_DIR"
    else
        load_release
    fi
    download_checksums "$TMP_DIR/SHA256SUMS"
    install_server
}

if [ "${QL_INSTALL_LIB_ONLY:-0}" != "1" ]; then
    main "$@"
fi

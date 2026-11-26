#!/usr/bin/env bash
# =============================================================================
#  tests/resolve-upstream.sh · 用桩件离线验证 scripts/resolve-upstream.sh
#
#  不访问网络、不需要 jq/curl：在临时目录里伪造 curl 与 jq，
#  校验「版本归一化 → 资产齐备性 → 标签组装 → 跳过/构建」这条逻辑。
#
#  用法： bash tests/resolve-upstream.sh
# =============================================================================

set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/scripts/resolve-upstream.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/qbt-resolve.XXXXXX")"
FAIL=0

trap 'rm -rf "${TMP}" 2>/dev/null || true' EXIT

pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
eq()   { if [[ "$2" == "$3" ]]; then pass "$1 = $2"; else fail "$1：期望 '$3'，实际 '$2'"; fi; }
has()  { if grep -qxF "$3" <<<"$2"; then pass "$1 含 $3"; else fail "$1 缺少 $3"; fi; }

mkdir -p "${TMP}/bin" "${TMP}/out"

# --- 伪造 curl ---------------------------------------------------------------
# FAKE_HTTP_CODE  注册表 manifest 请求返回的状态码（默认 404 = 标签不存在）
# FAKE_REQUIRE_OCI 1 = 只接受含 OCI image manifest 类型的 Accept（模拟 GHCR 内容协商）
# FAKE_TAG_JSON   带 tag 的 release JSON 文件
# FAKE_LIST_JSON  列表形式的 release JSON 文件
cat > "${TMP}/bin/curl" <<'CURL'
#!/usr/bin/env bash
out=""; url=""; wantcode=0; accept=""
args=("$@")
for i in "${!args[@]}"; do
	case "${args[$i]}" in
		-o) out="${args[$((i + 1))]}" ;;
		-w) wantcode=1 ;;
		Accept:*) accept="${args[$i]}" ;;
	esac
done
for a in "${args[@]}"; do
	case "$a" in
		http*|*ghcr.io*) url="$a" ;;
	esac
done

if [[ "${wantcode}" -eq 1 ]]; then
	# 模拟注册表的内容协商：清单 media type 不在 Accept 里时回 404（不是 406）
	if [[ "${FAKE_REQUIRE_OCI:-0}" == "1" ]]; then
		case "${accept}" in
			*application/vnd.oci.image.manifest.v1+json*) : ;;
			*) printf '404'; exit 0 ;;
		esac
	fi
	# 与真实 curl 一致：-w 的输出不带换行。
	# FAKE_HEAD_EXIT 用来模拟 curl 自身的退出码（-X HEAD 会以 18 结束）。
	printf '%s' "${FAKE_HTTP_CODE:-404}"
	exit "${FAKE_HEAD_EXIT:-0}"
fi

emit() { # $1 文件
	if [[ -n "${out}" && "${out}" != "/dev/null" ]]; then
		cat "$1" > "${out}"
	else
		cat "$1"
	fi
}

case "${url}" in
	*api.github.com/repos/*/releases/tags/*) emit "${FAKE_TAG_JSON}" ;;
	*api.github.com/repos/*/releases*)       emit "${FAKE_LIST_JSON}" ;;
	*ghcr.io/token*)                         echo "{\"token\":\"${FAKE_TOKEN:-}\"}" ;;
	*) exit 22 ;;
esac
CURL

# --- 伪造 jq（只认本脚本用到的过滤器；过滤器永远是最后一个参数）---------------
cat > "${TMP}/bin/jq" <<'JQ'
#!/usr/bin/env bash
filter="${!#}"
case "${filter}" in
	*".token"*)                   printf '%s\n' "${FAKE_TOKEN:-}" ;;
	*".published_at // \"\""*)    printf '%s\n' "${FAKE_PUBLISHED:-2026-10-03T18:04:46Z}" ;;
	*".prerelease // false"*)     printf '%s\n' "${FAKE_PRERELEASE:-false}" ;;
	*".assets[].name"*)           printf '%s\n' ${FAKE_ASSETS} ;;
	*"test("*)                    printf '%s\n' "${FAKE_TAG:-release-5.2.4.10}" ;;
	*"select(.tag_name==\$t)"*)   printf '%s\n' "${FAKE_PUBLISHED:-2026-10-03T18:04:46Z}" ;;
	*)                            printf '' ;;
esac
JQ
chmod +x "${TMP}/bin/curl" "${TMP}/bin/jq"

# --- 伪造 release JSON -------------------------------------------------------
cat > "${TMP}/release.json" <<'JSON'
{
  "tag_name": "release-5.2.4.10",
  "published_at": "2026-10-03T18:04:46Z",
  "prerelease": false,
  "assets": [
    {"name": "qbittorrent-enhanced-nox_x86_64-linux-musl_static.zip"},
    {"name": "qbittorrent-enhanced-nox_aarch64-linux-musl_static.zip"},
    {"name": "qbittorrent-enhanced-nox_someotherarch-linux-musl_static.zip"}
  ]
}
JSON

cat > "${TMP}/release-missing-arm64.json" <<'JSON'
{
  "tag_name": "release-5.2.4.11",
  "published_at": "2026-10-10T00:00:00Z",
  "prerelease": false,
  "assets": [
    {"name": "qbittorrent-enhanced-nox_x86_64-linux-musl_static.zip"}
  ]
}
JSON

cat > "${TMP}/release-missing-amd64.json" <<'JSON'
{
  "tag_name": "release-5.2.4.12",
  "published_at": "2026-10-11T00:00:00Z",
  "prerelease": false,
  "assets": [
    {"name": "qbittorrent-enhanced-nox_aarch64-linux-musl_static.zip"}
  ]
}
JSON

export PATH="${TMP}/bin:${PATH}"
export FAKE_TAG_JSON="${TMP}/release.json"
export FAKE_LIST_JSON="${TMP}/release.json"
export FAKE_ASSETS="qbittorrent-enhanced-nox_x86_64-linux-musl_static.zip
qbittorrent-enhanced-nox_aarch64-linux-musl_static.zip
qbittorrent-enhanced-nox_someotherarch-linux-musl_static.zip"

run_case() { # $1 输出文件
	# 前缀赋值作用于 bash 子进程（对函数调用本身的赋值不会自动 export）
	IMAGE="ghcr.io/Some/Repo" \
	GITHUB_OUTPUT="$1" \
	GITHUB_SHA="${GITHUB_SHA:-}" \
	GITHUB_REF="${GITHUB_REF:-}" \
	GH_TOKEN="" \
	FORCE="${FORCE:-false}" \
	INPUT_VERSION="${INPUT_VERSION:-}" \
	EVENT_NAME="${EVENT_NAME:-workflow_dispatch}" \
	FAKE_TOKEN="${FAKE_TOKEN:-}" \
	FAKE_HTTP_CODE="${FAKE_HTTP_CODE:-404}" \
	FAKE_REQUIRE_OCI="${FAKE_REQUIRE_OCI:-0}" \
	FAKE_HEAD_EXIT="${FAKE_HEAD_EXIT:-0}" \
	bash "${SCRIPT}" >"${TMP}/log" 2>&1
}

multiline() { sed -n "/^$2<<__EOF__\$/,/^__EOF__\$/p" "$1" | sed '1d;$d'; }

echo "== 用例 1：自动取最新版本，FORCE=true =="
: > "${TMP}/out/1"
if FORCE=true EVENT_NAME=schedule GITHUB_SHA=abcdef1234567890 run_case "${TMP}/out/1"; then
	pass "脚本执行成功"
	o="$(cat "${TMP}/out/1")"
	eq "build"          "$(sed -n 's/^build=//p' <<<"${o}")" "true"
	eq "version"        "$(sed -n 's/^version=//p' <<<"${o}")" "5.2.4.10"
	eq "published_at"   "$(sed -n 's/^published_at=//p' <<<"${o}")" "2026-10-03T18:04:46Z"
	eq "image 已转小写" "$(sed -n 's/^image=//p' <<<"${o}")" "ghcr.io/some/repo"
	eq "platforms"      "$(sed -n 's/^platforms=//p' <<<"${o}")" "linux/amd64,linux/arm64"
	has "tags"    "$(multiline "${TMP}/out/1" tags)"    "ghcr.io/some/repo:5.2.4.10"
	has "tags"    "$(multiline "${TMP}/out/1" tags)"    "ghcr.io/some/repo:sha-abcdef1"
	has "aliases" "$(multiline "${TMP}/out/1" aliases)" "ghcr.io/some/repo:5.2"
	has "aliases" "$(multiline "${TMP}/out/1" aliases)" "ghcr.io/some/repo:5"
	has "aliases" "$(multiline "${TMP}/out/1" aliases)" "ghcr.io/some/repo:latest"
	# push_tags 是 tags + aliases 的合集，CI 冒烟通过后按它一次性推送
	has "push_tags" "$(multiline "${TMP}/out/1" push_tags)" "ghcr.io/some/repo:5.2.4.10"
	has "push_tags" "$(multiline "${TMP}/out/1" push_tags)" "ghcr.io/some/repo:5.2"
	has "push_tags" "$(multiline "${TMP}/out/1" push_tags)" "ghcr.io/some/repo:latest"
else
	fail "脚本执行失败：$(cat "${TMP}/log")"
fi

echo "== 用例 2：main 分支 push 额外产出 edge 标签 =="
: > "${TMP}/out/2"
if FORCE=false EVENT_NAME=push GITHUB_REF=refs/heads/main GITHUB_SHA=abcdef1234567890 run_case "${TMP}/out/2"; then
	has "tags" "$(multiline "${TMP}/out/2" tags)" "ghcr.io/some/repo:edge"
else
	fail "脚本执行失败：$(cat "${TMP}/log")"
fi

echo "== 用例 2b：tag push 不产出 edge（edge 只代表 main 最新）=="
: > "${TMP}/out/2b"
if FORCE=false EVENT_NAME=push GITHUB_REF=refs/tags/v0.1.0 GITHUB_SHA=abcdef1234567890 run_case "${TMP}/out/2b"; then
	if grep -qxF "ghcr.io/some/repo:edge" <<<"$(multiline "${TMP}/out/2b" tags)"; then
		fail "tag push 竟然产出了 edge 标签"
	else
		pass "tag push 未产出 edge"
	fi
	eq "版本仍取上游" "$(sed -n 's/^version=//p' "${TMP}/out/2b")" "5.2.4.10"
	has "tags" "$(multiline "${TMP}/out/2b" tags)" "ghcr.io/some/repo:5.2.4.10"
else
	fail "脚本执行失败：$(cat "${TMP}/log")"
fi

echo "== 用例 3：手动指定版本（带 release- 前缀）=="
: > "${TMP}/out/3"
if INPUT_VERSION="release-5.2.4.9" FORCE=true EVENT_NAME=workflow_dispatch run_case "${TMP}/out/3"; then
	eq "version" "$(sed -n 's/^version=//p' "${TMP}/out/3")" "5.2.4.9"
	has "tags"   "$(multiline "${TMP}/out/3" tags)" "ghcr.io/some/repo:5.2.4.9"
	has "aliases" "$(multiline "${TMP}/out/3" aliases)" "ghcr.io/some/repo:5.2"
else
	fail "脚本执行失败：$(cat "${TMP}/log")"
fi

echo "== 用例 4：非法版本号应失败 =="
: > "${TMP}/out/4"
if INPUT_VERSION="oops" FORCE=true run_case "${TMP}/out/4"; then
	fail "非法版本号竟然通过了"
else
	pass "非法版本号被拒绝"
fi

echo "== 用例 4b：本仓库 tag（v0.1.0）不得被当成镜像版本 =="
: > "${TMP}/out/4b"
if INPUT_VERSION="v0.1.0" FORCE=true EVENT_NAME=workflow_dispatch run_case "${TMP}/out/4b"; then
	fail "v0.1.0 竟然被接受为镜像版本"
elif grep -q "上游 release" "${TMP}/log"; then
	pass "v0.1.0 被拒绝，且指明只接受上游 release 版本"
else
	fail "失败但提示不明确：$(cat "${TMP}/log")"
fi

echo "== 用例 5：上游缺 arm64 静态包应失败 =="
: > "${TMP}/out/5"
if FAKE_TAG_JSON="${TMP}/release-missing-arm64.json" \
	FAKE_LIST_JSON="${TMP}/release-missing-arm64.json" \
	FAKE_TAG="release-5.2.4.11" \
	FAKE_ASSETS="qbittorrent-enhanced-nox_x86_64-linux-musl_static.zip
qbittorrent-enhanced-nox_someotherarch-linux-musl_static.zip" \
	FORCE=true EVENT_NAME=schedule run_case "${TMP}/out/5"; then
	fail "缺 arm64 资产竟然通过了"
elif grep -q "缺少必需资产" "${TMP}/log" \
	&& grep -q "aarch64" "${TMP}/log"; then
	pass "缺 arm64 资产被拒绝，且提示清晰"
else
	fail "失败但提示不明确：$(cat "${TMP}/log")"
fi

echo "== 用例 5b：上游缺 amd64 静态包应失败 =="
: > "${TMP}/out/5b"
if FAKE_TAG_JSON="${TMP}/release-missing-amd64.json" \
	FAKE_LIST_JSON="${TMP}/release-missing-amd64.json" \
	FAKE_TAG="release-5.2.4.12" \
	FAKE_ASSETS="qbittorrent-enhanced-nox_aarch64-linux-musl_static.zip" \
	FORCE=true EVENT_NAME=schedule run_case "${TMP}/out/5b"; then
	fail "缺 amd64 资产竟然通过了"
elif grep -q "缺少必需资产" "${TMP}/log" \
	&& grep -q "x86_64" "${TMP}/log"; then
	pass "缺 amd64 资产被拒绝，且提示清晰"
else
	fail "失败但提示不明确：$(cat "${TMP}/log")"
fi

echo "== 用例 6：标签已存在时应 SKIP（零构建开销）=="
: > "${TMP}/out/6"
if FAKE_TOKEN=fake FAKE_HTTP_CODE=200 FORCE=false EVENT_NAME=schedule run_case "${TMP}/out/6"; then
	eq "build"  "$(sed -n 's/^build=//p' "${TMP}/out/6")" "false"
	eq "reason" "$(sed -n 's/^reason=//p' "${TMP}/out/6")" "镜像 ghcr.io/some/repo:5.2.4.10 已存在，上游无新版本"
else
	fail "SKIP 分支执行失败：$(cat "${TMP}/log")"
fi

echo "== 用例 6b：清单为 OCI 类型时仍能识别「已存在」（Accept 必须含 OCI 类型）=="
# 回归用例：GHCR 按 Accept 做内容协商，面板里没有实际 media type 就回 404。
# 曾因 Accept 只列 docker 类型，导致 docker push 产出 OCI 清单后每次都误判
# 「标签不存在」→ 每 6 小时重建，不可变标签被反复覆盖。
: > "${TMP}/out/6b"
if FAKE_TOKEN=fake FAKE_HTTP_CODE=200 FAKE_REQUIRE_OCI=1 \
	FORCE=false EVENT_NAME=schedule run_case "${TMP}/out/6b"; then
	eq "build" "$(sed -n 's/^build=//p' "${TMP}/out/6b")" "false"
else
	fail "OCI 清单场景判定失败（Accept 可能缺 OCI 类型）：$(cat "${TMP}/log")"
fi

echo "== 用例 6c：curl 以非零码退出但已输出 200 时，不得拼出 '200000' =="
# 回归用例：-X HEAD 会让 curl 以 exit 18 结束（注册表只回头不回体），
# 旧实现的 `|| echo 000` 于是把状态码拼成 "200000"，与 "200" 永不相等，
# 标签恒被判为不存在 —— 这才是定时任务每 6 小时重建的真正原因。
: > "${TMP}/out/6c"
if FAKE_TOKEN=fake FAKE_HTTP_CODE=200 FAKE_HEAD_EXIT=18 FAKE_REQUIRE_OCI=1 \
	FORCE=false EVENT_NAME=schedule run_case "${TMP}/out/6c"; then
	eq "build" "$(sed -n 's/^build=//p' "${TMP}/out/6c")" "false"
else
	fail "curl 非零退出码场景判定失败：$(cat "${TMP}/log")"
fi

echo "== 用例 6d：GHCR 查询失败时应 SKIP，而不是当作「标签不存在」触发重建 =="
: > "${TMP}/out/6d"
if FAKE_TOKEN=fake FAKE_HTTP_CODE=000 FAKE_HEAD_EXIT=18 FAKE_REQUIRE_OCI=1 \
	FORCE=false EVENT_NAME=schedule run_case "${TMP}/out/6d"; then
	eq "build"  "$(sed -n 's/^build=//p' "${TMP}/out/6d")" "false"
	if grep -q "无法确认 GHCR 标签状态" "${TMP}/log"; then
		pass "网络/注册表异常被识别为 SKIP，未触发重建"
	else
		fail "SKIP 原因未说明 GHCR 查询失败：$(cat "${TMP}/log")"
	fi
else
	fail "GHCR 查询失败场景执行失败：$(cat "${TMP}/log")"
fi

echo "== 用例 7：已存在但 FORCE=true 时必须重建 =="
: > "${TMP}/out/7"
if FAKE_TOKEN=fake FAKE_HTTP_CODE=200 FORCE=true EVENT_NAME=workflow_dispatch run_case "${TMP}/out/7"; then
	eq "build" "$(sed -n 's/^build=//p' "${TMP}/out/7")" "true"
else
	fail "FORCE 分支执行失败：$(cat "${TMP}/log")"
fi

echo
if [[ "${FAIL}" -eq 0 ]]; then
	printf '\033[32m全部通过\033[0m\n'
	exit 0
fi
printf '\033[31m%d 个用例失败\033[0m\n' "${FAIL}"
exit 1

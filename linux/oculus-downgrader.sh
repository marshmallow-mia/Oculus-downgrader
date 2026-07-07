#!/usr/bin/env bash
#
# oculus-downgrader.sh - Linux port of ComputerElite's Oculus Downgrader
#
# Downloads specific (older) versions of Oculus/Meta Quest, Go, GearVR and Rift
# apps straight from Meta's CDN and, for Quest, installs them over ADB.
#
# This is a from-scratch bash reimplementation of the useful, portable parts of
# the original C# tool. The Rift "install/launch" flow of the original is
# Windows-only (it copies files into C:\...\Oculus\Software and launches an
# .exe), so on Linux that becomes "download the game files to a folder".
#
# Requires: bash 4+, curl, jq. Optional: adb (Quest install), python3 or
# zlib-flate (Rift segment decompression), unzip (Rift manifest).
#
# Data:   ${XDG_DATA_HOME:-~/.local/share}/oculus-downgrader/apps/<appId>/<verId>/
# Config: ${XDG_CONFIG_HOME:-~/.config}/oculus-downgrader/config.json
#
set -uo pipefail

# ----------------------------------------------------------------------------
# Constants (mirrored from the original OculusGraphQLApiLib)
# ----------------------------------------------------------------------------
readonly OCULUS_GRAPHQL="https://graph.oculus.com/graphql"
readonly META_GRAPHQL="https://www.meta.com/ocapi/graphql"
readonly SECURECDN="https://securecdn.oculus.com/binaries"
readonly OCULUSDB="https://oculusdb.rui2015.me/api/v1"
readonly STORE_TOKEN="OC|752908224809889|"
readonly UA="OculusGraphQLApiLib/1.0"

# Browser login (native SSO) flow, mirrored from LoginClient
readonly OCULUS_CLIENT_TOKEN="FRL|512466987071624|01d4a1f7fd0682aea7ee8ae987704d63"
readonly WEBVIEW_TOKENS_QUERY="https://meta.graph.meta.com/webview_tokens_query"
readonly WEBVIEW_BLOBS_DECRYPT="https://meta.graph.meta.com/webview_blobs_decrypt"
readonly META_FRL_GRAPHQL="https://meta.graph.meta.com/graphql"
readonly LOGIN_APP_ID="512466987071624"
readonly XFR_APP_ID="1582076955407037"
readonly XFR_DOC_ID="5787825127910775"

# GraphQL persisted-query doc_ids used by the original tool
readonly DOC_CURRENT_USER="4149322231793299"
readonly DOC_ALL_VERSIONS="2885322071572384"
readonly DOC_CHANGE_CHANNEL="5380372352071467"
readonly DOC_BINARY_DETAILS="4734929166632773"
readonly DOC_STORE_SEARCH="24633449332970329"

# App ids for the "Downgrade Beat Saber" shortcut
readonly RIFT_BS_APPID="1304877726278670"
readonly QUEST_BS_APPID="2448060205267927"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/oculus-downgrader"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/oculus-downgrader"
CONFIG_FILE="$CONFIG_DIR/config.json"
APPS_DIR="$DATA_DIR/apps"
TMP_DIR="$DATA_DIR/tmp"

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_CYN=$'\033[36m'; C_BOLD=$'\033[1m'; C_RST=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_BOLD=""; C_RST=""
fi
err()  { echo "${C_RED}$*${C_RST}" >&2; }
good() { echo "${C_GRN}$*${C_RST}"; }
warn() { echo "${C_YEL}$*${C_RST}"; }
info() { echo "${C_CYN}$*${C_RST}"; }
die()  { err "$*"; exit 1; }

# ----------------------------------------------------------------------------
# Dependency checks
# ----------------------------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1; }
require() { need "$1" || die "Missing required dependency: $1"; }

check_core_deps() {
    require curl
    require jq
}

# ----------------------------------------------------------------------------
# Config (JSON via jq)
# ----------------------------------------------------------------------------
config_init() {
    mkdir -p "$CONFIG_DIR" "$APPS_DIR" "$TMP_DIR"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo '{"access_token":"","headset":"HOLLYWOOD","apps":[]}' > "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
    fi
}

cfg() { jq -r "$1" "$CONFIG_FILE"; }

cfg_set() {
    # cfg_set <jq-filter using $v> <value>
    local filter="$1" value="$2" tmp
    tmp="$(mktemp)"
    jq --arg v "$value" "$filter" "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
}

get_token()   { cfg '.access_token // ""'; }
get_headset() { cfg '.headset // "HOLLYWOOD"'; }

# ----------------------------------------------------------------------------
# Headset helpers
# ----------------------------------------------------------------------------
# Canonical enum names used by the Meta API code names.
headset_display() {
    case "$1" in
        RIFT|LAGUNA) echo "Rift" ;;
        MONTEREY) echo "Quest 1" ;;
        HOLLYWOOD) echo "Quest 2" ;;
        EUREKA) echo "Quest 3" ;;
        PANTHER) echo "Quest 3S" ;;
        SEACLIFF) echo "Quest Pro" ;;
        GEARVR) echo "GearVR" ;;
        PACIFIC) echo "Go" ;;
        *) echo "$1" ;;
    esac
}

# General family (used to decide download strategy: Rift = PC, others = Android)
headset_is_rift() { [[ "$1" == "RIFT" || "$1" == "LAGUNA" ]]; }

normalize_headset() {
    case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
        quest|quest2|hollywood|monterey) echo "HOLLYWOOD" ;;
        quest3|eureka) echo "EUREKA" ;;
        quest3s|panther) echo "PANTHER" ;;
        questpro|seacliff) echo "SEACLIFF" ;;
        rift|laguna|rifts) echo "RIFT" ;;
        gearvr) echo "GEARVR" ;;
        go|pacific) echo "PACIFIC" ;;
        *) echo "" ;;
    esac
}

# ----------------------------------------------------------------------------
# API helpers
# ----------------------------------------------------------------------------
# GraphQL POST against Oculus/Meta. Args: <doc_id> <variables-json> [token] [uri]
graphql() {
    local doc_id="$1" variables="$2" token="${3:-$STORE_TOKEN}" uri="${4:-$OCULUS_GRAPHQL}"
    local -a args=(-s --max-time 60 -X POST "$uri" -H "User-Agent: $UA"
        --data-urlencode "variables=$variables" --data "doc_id=$doc_id")
    [[ -n "$token" ]] && args+=(--data-urlencode "access_token=$token")
    curl "${args[@]}"
}

oculusdb() {
    # oculusdb <path> -> raw JSON. Returns non-zero on curl failure.
    curl -sf --max-time 60 -H "User-Agent: $UA" "$OCULUSDB/$1"
}

# ----------------------------------------------------------------------------
# Token: validate + store
# ----------------------------------------------------------------------------
token_looks_valid() {
    local t="$1"
    [[ "$t" == *"%"* ]] && { err "Token contains '%'. Grab it from the payload tab, not the URL."; return 1; }
    [[ "$t" == FRL* || "$t" == OC* ]] || { err "Tokens must start with 'FRL' or 'OC'."; return 1; }
    [[ "$t" == *"|"* ]] && { err "Token contains '|' - that's an application token, not YOUR user token."; return 1; }
    [[ "$t" =~ ^OC[0-9]{15} ]] && { err "That looks like a modified store token. Use the real one from another request."; return 1; }
    return 0
}

# Returns 0 and prints alias if the token authenticates.
token_whoami() {
    local token="$1" resp alias
    resp="$(graphql "$DOC_CURRENT_USER" '{}' "$token")"
    alias="$(echo "$resp" | jq -r '.data.viewer.user.alias // empty' 2>/dev/null)"
    [[ -n "$alias" ]] && { echo "$alias"; return 0; }
    return 1
}

# Validate + persist a token. Shared by manual paste and browser login.
save_token() {
    local token="$1"
    token="${token//[[:space:]]/}"
    [[ "$token" == *:* ]] && token="${token##*:}"   # drop optional "access_token:" prefix
    token_looks_valid "$token" || return 1
    info "Verifying token with Meta..."
    local who
    if who="$(token_whoami "$token")"; then
        cfg_set '.access_token = $v' "$token"
        good "Token saved. Logged in as $who"
        warn "Note: the token is stored in plaintext at $CONFIG_FILE (chmod 600)."
        return 0
    fi
    err "Token did not authenticate. It may be expired or wrong. Not saving."
    return 1
}

cmd_token() {
    local token="${1:-}"
    if [[ -n "$token" ]]; then
        save_token "$token"; return $?
    fi

    local current; current="$(get_token)"
    if [[ -n "$current" ]]; then
        info "A token is stored. Verifying..."
        local who; if who="$(token_whoami "$current")"; then
            good "Logged in as $who"
        else
            warn "Stored token is invalid or expired. Set a new one."
        fi
    fi
    echo
    local choice
    read -rp "Log in with your Meta account in the browser? (Y/n): " choice
    if [[ -z "$choice" || "${choice,,}" == "y" ]]; then
        cmd_login
        return $?
    fi
    echo
    echo "How to get your token manually:"
    echo "  Open ${C_BOLD}https://computerelite.github.io/tools/Oculus/ObtainTokenNew.html${C_RST}"
    echo "  and follow the guide (Meta account -> network payload -> access_token)."
    echo
    read -rsp "Paste access_token (hidden): " token; echo
    save_token "$token"
}

# ----------------------------------------------------------------------------
# Browser login (native SSO), mirroring the original's LoginClient flow
# ----------------------------------------------------------------------------
post_json() {
    curl -s --max-time 60 -X POST "$1" \
        -H "Content-Type: application/json" -H "User-Agent: $UA" -d "$2"
}

urldecode() { local d="${1//+/ }"; printf '%b' "${d//%/\\x}"; }

# Upgrade an intermediate/"Rift app" token into a full FRL user token.
login_second_stage() {
    local first_token="$1" body resp
    body="$(jq -cn --arg at "$first_token" --arg v '{"app_id":"'"$XFR_APP_ID"'"}' --arg doc "$XFR_DOC_ID" \
        '{access_token:$at, variables:$v, doc_id:$doc, doc:null}')"
    resp="$(post_json "$META_FRL_GRAPHQL" "$body")"
    echo "$resp" | jq -r '.data.xfr_create_profile_token.profile_tokens[0].access_token // empty' 2>/dev/null
}

cmd_login() {
    info "Requesting a login session from Meta..."
    local resp; resp="$(post_json "$WEBVIEW_TOKENS_QUERY" \
        "$(jq -cn --arg at "$OCULUS_CLIENT_TOKEN" '{access_token:$at}')")"
    local etoken native_token
    etoken="$(echo "$resp" | jq -r '.native_sso_etoken // empty' 2>/dev/null)"
    native_token="$(echo "$resp" | jq -r '.native_sso_token // empty' 2>/dev/null)"
    [[ -z "$etoken" || -z "$native_token" ]] && { err "Could not start a login session. Try again later."; return 1; }

    local url="https://auth.meta.com/native_sso/confirm?native_app_id=$LOGIN_APP_ID&native_sso_etoken=$etoken&utm_source=skyline_splash"
    echo
    info "Opening the Meta login page in your browser..."
    echo "If it doesn't open automatically, paste this URL into your browser:"
    echo "  ${C_BOLD}$url${C_RST}"
    if need xdg-open; then (xdg-open "$url" >/dev/null 2>&1 &) ; fi
    echo
    cat <<'EOF'
Log in and approve. When finished, the page tries to redirect to a URL that
starts with 'oculus://' - your browser cannot open it, so grab that URL:

  * Easiest: open DevTools (F12) -> Network tab BEFORE approving, find the
    'approve' request, and copy the "uri" from its JSON response, OR
  * Copy whatever 'oculus://...' URL your browser shows in an error/prompt.

Then paste it below (a bare 'blob=...' value works too).
EOF
    echo
    local uri; read -rp "Paste the oculus:// URL: " uri
    [[ -z "$uri" ]] && { err "Nothing pasted."; return 1; }

    local blob
    blob="$(printf '%s' "$uri" | sed -n 's/.*[?&]blob=\([^&]*\).*/\1/p')"
    [[ -z "$blob" && "$uri" != *"://"* && "$uri" != *"="* ]] && blob="$uri"  # allow raw blob
    [[ -z "$blob" ]] && { err "Couldn't find a 'blob' value in that URL."; return 1; }
    blob="$(urldecode "$blob")"

    info "Decrypting login blob..."
    local dresp first_token
    dresp="$(post_json "$WEBVIEW_BLOBS_DECRYPT" \
        "$(jq -cn --arg at "$OCULUS_CLIENT_TOKEN" --arg b "$blob" --arg rt "$native_token" \
            '{access_token:$at, blob:$b, request_token:$rt}')")"
    first_token="$(echo "$dresp" | jq -r '.access_token // empty' 2>/dev/null)"
    [[ -z "$first_token" ]] && { err "Blob decryption failed - the login link may have expired. Run login again."; return 1; }

    info "Upgrading to a user token..."
    local final; final="$(login_second_stage "$first_token")"
    [[ -z "$final" ]] && { err "Token upgrade failed."; return 1; }

    save_token "$final"
}

# Ensure we have a working token; prints it on stdout, or fails.
ensure_token() {
    local t; t="$(get_token)"
    [[ -z "$t" ]] && { err "No access token set. Run: $0 token"; return 1; }
    echo "$t"
}

# ----------------------------------------------------------------------------
# Headset command
# ----------------------------------------------------------------------------
cmd_headset() {
    local input="${1:-}"
    if [[ -z "$input" ]]; then
        info "Current headset: $(headset_display "$(get_headset)")"
        read -rp "Set headset (Quest, Quest3, Quest3S, QuestPro, Rift, GearVR, Go): " input
        [[ -z "$input" ]] && return 0
    fi
    local h; h="$(normalize_headset "$input")"
    [[ -z "$h" ]] && { err "Unknown headset '$input'."; return 1; }
    cfg_set '.headset = $v' "$h"
    good "Headset set to $(headset_display "$h")"
}

# ----------------------------------------------------------------------------
# Search
# ----------------------------------------------------------------------------
# Prints "id<TAB>name" lines merged from OculusDB and the Meta store.
search_results() {
    local term="$1" headset="$2" got=0
    # OculusDB REST search
    local db; if db="$(oculusdb "search/$(jq -rn --arg t "$term" '$t|@uri')")"; then
        echo "$db" | jq -r '.[] | "\(.id)\t\(.displayName // .appName)"' 2>/dev/null && got=1
    fi
    # Meta store GraphQL search (fallback / extra results)
    local resp; resp="$(graphql "$DOC_STORE_SEARCH" \
        "$(jq -cn --arg q "$term" --arg h "$headset" \
            '{query:$q,hmdType:$h,firstSearchResultItems:100}')" "" "$META_GRAPHQL")"
    echo "$resp" | jq -r '
        (.data.viewer.contextual_search.all_category_results // [])[]
        | select(.name=="APPS" or .name=="CONCEPT")
        | .search_results.nodes[]?.target_object
        | select(.id!=null) | "\(.id)\t\(.display_name)"' 2>/dev/null
    return $((1-got))
}

cmd_search() {
    local term="${1:-}"
    [[ -z "$term" ]] && read -rp "Search term: " term
    [[ -z "$term" ]] && { err "No search term."; return 1; }
    local headset; headset="$(get_headset)"
    info "Searching for '$term'..."
    local out; out="$(search_results "$term" "$headset" | awk -F'\t' '!seen[$1]++')"
    if [[ -z "$out" ]]; then
        warn "No results found."
        return 1
    fi
    echo
    printf "%-20s  %s\n" "APP ID" "NAME"
    printf "%-20s  %s\n" "--------------------" "----"
    echo "$out" | while IFS=$'\t' read -r id name; do
        printf "%-20s  %s\n" "$id" "$name"
    done
    echo
    info "List versions with: $0 versions <APP ID>"
}

# ----------------------------------------------------------------------------
# Versions
# ----------------------------------------------------------------------------
# Emits to stdout: line 1 = app display name, then one TSV row per version:
#   version_code<TAB>version<TAB>binaryId<TAB>channelId<TAB>channels
# (App name is emitted rather than set as a global because callers invoke this
#  via command substitution, which runs in a subshell.)
VERSIONS_APPNAME=""
fetch_versions() {
    local appid="$1"
    local resp
    if resp="$(oculusdb "connected/$appid")" && \
       [[ "$(echo "$resp" | jq '.versions | length' 2>/dev/null)" -gt 0 ]]; then
        echo "$resp" | jq -r '.applications[0].displayName // "Unknown"'
        echo "$resp" | jq -r '
            [.versions[] | select((.binary_release_channels.nodes|length) > 0)]
            | sort_by(.versionCode)[]
            | [ (.versionCode|tostring), .version, .id,
                (.binary_release_channels.nodes[0].id // ""),
                ([.binary_release_channels.nodes[].channel_name]|join(",")) ]
            | @tsv'
        return 0
    fi
    # Fallback: Meta GraphQL (does not carry release-channel ids, uses store token)
    warn "OculusDB unavailable, falling back to Meta GraphQL..." >&2
    resp="$(graphql "$DOC_ALL_VERSIONS" "$(jq -cn --arg id "$appid" '{applicationID:$id}')")"
    echo "$resp" | jq -r '.data.node.display_name // "Unknown"'
    echo "$resp" | jq -r '
        [ (.data.node.primary_binaries.nodes // [])[]
          | select((.binary_release_channels.nodes|length) > 0) ]
        | sort_by(.version_code)[]
        | [ (.version_code|tostring), .version, .id,
            (.binary_release_channels.nodes[0].id // ""),
            ([.binary_release_channels.nodes[].channel_name]|join(",")) ]
        | @tsv'
}

cmd_versions() {
    local appid="${1:-}"
    [[ -z "$appid" ]] && { err "Usage: $0 versions <APP ID>"; return 1; }
    info "Fetching versions for $appid..."
    local raw; raw="$(fetch_versions "$appid")"
    VERSIONS_APPNAME="$(head -1 <<< "$raw")"
    local vers; vers="$(tail -n +2 <<< "$raw")"
    [[ -z "$vers" ]] && { warn "No downloadable versions found."; return 1; }
    echo
    good "Versions of $VERSIONS_APPNAME  (app id $appid)"
    echo
    printf "%-18s  %-8s  %-20s  %s\n" "VERSION" "CODE" "BINARY ID" "CHANNELS"
    printf "%-18s  %-8s  %-20s  %s\n" "-------" "----" "---------" "--------"
    echo "$vers" | while IFS=$'\t' read -r code version binid chanid channels; do
        printf "%-18s  %-8s  %-20s  %s\n" "$version" "$code" "$binid" "$channels"
    done
    echo
    info "Download with: $0 download --appid $appid --versionid <BINARY ID>"
}

# ----------------------------------------------------------------------------
# Download
# ----------------------------------------------------------------------------
# Resolve a version row for an appid + selector. Sets globals:
#   V_CODE V_VER V_BINID V_CHANID V_CHANNELS
resolve_version() {
    local appid="$1" sel_id="$2" sel_code="$3" sel_str="$4"
    local raw; raw="$(fetch_versions "$appid")"
    VERSIONS_APPNAME="$(head -1 <<< "$raw")"
    local vers; vers="$(tail -n +2 <<< "$raw")"
    [[ -z "$vers" ]] && return 1
    local line=""
    if [[ -n "$sel_id" ]]; then
        line="$(echo "$vers" | awk -F'\t' -v x="$sel_id" '$3==x{print;exit}')"
    elif [[ -n "$sel_code" ]]; then
        line="$(echo "$vers" | awk -F'\t' -v x="$sel_code" '$1==x{print;exit}')"
    elif [[ -n "$sel_str" ]]; then
        line="$(echo "$vers" | awk -F'\t' -v x="$sel_str" '$2==x{print;exit}')"
    fi
    [[ -z "$line" ]] && return 1
    IFS=$'\t' read -r V_CODE V_VER V_BINID V_CHANID V_CHANNELS <<< "$line"
    return 0
}

# curl a securecdn binary download URL to a file. Args: <id> <token> <dest> [extraquery]
# Retries hard on transient failures (5xx, connection resets, refused).
cdn_download() {
    local id="$1" token="$2" dest="$3" extra="${4:-}"
    curl -fL --retry 5 --retry-delay 3 --retry-connrefused \
        --max-time 7200 -A "$UA" \
        -G "$SECURECDN/download/" \
        --data-urlencode "id=$id" \
        --data-urlencode "access_token=$token" \
        ${extra:+--data "$extra"} \
        -o "$dest"
}

# Download OBBs for a Quest binary into <destdir>. Uses OculusDB, then GraphQL.
download_obbs() {
    local binid="$1" token="$2" destdir="$3"
    local obbs=""
    local db; if db="$(oculusdb "id/$binid")"; then
        obbs="$(echo "$db" | jq -r '(.obbList // [])[] | "\(.id)\t\(.file_name)"' 2>/dev/null)"
    fi
    if [[ -z "$obbs" ]]; then
        local resp; resp="$(graphql "$DOC_BINARY_DETAILS" \
            "$(jq -cn --arg id "$binid" '{binaryID:$id}')" "$token")"
        obbs="$(echo "$resp" | jq -r '
            [ (.data.node.obb_binary // empty | {id,file_name}),
              (.data.node.asset_files.nodes[]? | {id,file_name}) ]
            | .[] | "\(.id)\t\(.file_name)"' 2>/dev/null)"
    fi
    if [[ -z "$obbs" ]]; then
        info "No OBBs to download."
        return 0
    fi
    mkdir -p "$destdir/obbs"
    echo "$obbs" | while IFS=$'\t' read -r oid oname; do
        [[ -z "$oid" ]] && continue
        info "Downloading OBB $oname"
        cdn_download "$oid" "$token" "$destdir/obbs/$oname" \
            || err "Failed to download OBB $oname"
    done
}

# Android (Quest/Go/GearVR): download apk + obbs
download_android() {
    local appid="$1" token="$2" destdir="$3"
    mkdir -p "$destdir"
    info "Downloading APK..."
    if ! cdn_download "$V_BINID" "$token" "$destdir/app.apk"; then
        err "APK download failed. Do you own this game and is the right headset selected?"
        return 1
    fi
    good "APK downloaded ($(du -h "$destdir/app.apk" | cut -f1))."
    download_obbs "$V_BINID" "$token" "$destdir"
    return 0
}

# Rift (PC): manifest + parallel segment download + in-process reassembly.
download_rift() {
    local token="$1" destdir="$2"
    mkdir -p "$destdir"
    need unzip || die "unzip is required for Rift downloads."
    need python3 || die "python3 is required for Rift downloads (fast assembly + verification)."

    # IMPORTANT: keep the download manifest OUTSIDE the game tree. Some games
    # (e.g. Echo VR) ship a file literally named 'manifest.json', which would
    # otherwise clobber our manifest during assembly.
    local segdir="$TMP_DIR/segments_$V_BINID"
    local manifest="$TMP_DIR/manifest_$V_BINID.json"
    local mzip="$TMP_DIR/manifest_$V_BINID.zip"
    local mfx="$TMP_DIR/mfx_$V_BINID"
    mkdir -p "$segdir"

    info "Downloading manifest..."
    if ! curl -fsSL --retry 5 --retry-delay 2 --retry-connrefused --max-time 300 -A "$UA" \
            -G "$SECURECDN/download/" \
            --data-urlencode "id=$V_BINID" \
            --data-urlencode "access_token=$token" \
            --data "get_manifest=1" \
            -o "$mzip"; then
        err "Manifest download failed. Do you own this game / is your token valid?"
        return 1
    fi
    rm -rf "$mfx"; mkdir -p "$mfx"
    unzip -o -q "$mzip" -d "$mfx"
    local extracted; extracted="$(find "$mfx" -type f -name '*.json' | head -1)"
    [[ -z "$extracted" ]] && { err "Manifest not found in archive."; return 1; }
    mv -f "$extracted" "$manifest"
    rm -rf "$mfx" "$mzip"
    [[ -f "$manifest" ]] || { err "Manifest not found in archive."; return 1; }

    good "Manifest downloaded."
    local total; total="$(jq '[.files[].size] | add // 0' "$manifest")"
    info "Total install size: $(numfmt --to=iec "$total" 2>/dev/null || echo "$total bytes")"

    # Heal downloads made by older versions that wrote backslash-named flat files.
    migrate_legacy_paths "$destdir"

    export -f cdn_seg_worker
    export SECURECDN UA
    local total_files; total_files="$(jq '.files | length' "$manifest")"

    # Assemble + verify in-process, fetching ONLY the segments still needed.
    # A clean download converges in 2 passes (identify -> fetch -> assemble+verify).
    local round ok=0 needfile="$segdir/needed.tsv" prev_missing=""
    for round in 1 2 3 4 5 6; do
        info "Verifying/assembling files (pass $round)..."
        if rift_assemble "$manifest" "$destdir" "$segdir" "$needfile"; then ok=1; break; fi
        local nseg; nseg="$(grep -c . "$needfile" 2>/dev/null || echo 0)"
        if [[ "$nseg" -eq 0 ]]; then break; fi   # incomplete but nothing to fetch
        # REFETCH = present but produced a bad file -> delete so we get a fresh copy.
        awk -F'\t' '$1=="REFETCH"{print $2}' "$needfile" | while read -r s; do rm -f "$segdir/$s"; done
        awk -F'\t' '{print $2}' "$needfile" | sort -u > "$segdir/fetch.txt"
        fetch_segments "$segdir/fetch.txt" "$segdir"

        # Segments still missing after the fetch. If a whole round makes zero
        # progress on them, the CDN genuinely can't serve them - stop looping.
        local still="$segdir/still.txt"; : > "$still"
        while read -r s; do [[ -s "$segdir/$s" ]] || echo "$s" >> "$still"; done < "$segdir/fetch.txt"
        if [[ -s "$still" ]]; then
            local cur_missing; cur_missing="$(sort "$still" | md5sum | cut -d' ' -f1)"
            if [[ "$cur_missing" == "$prev_missing" ]]; then
                rift_report_unfetchable "$manifest" "$still" "$total_files"
                return 1
            fi
            prev_missing="$cur_missing"
        fi
    done

    if [[ "$ok" != 1 ]]; then
        # Fell through all rounds still incomplete.
        local still="$segdir/fetch.txt"
        rift_report_unfetchable "$manifest" "$still" "$total_files"
        return 1
    fi

    rm -rf "$segdir" "$manifest"
    good "Rift game downloaded and verified: $destdir"
    warn "Note: launching Rift games requires Windows + the Oculus app."
    warn "On Linux these files are provided for use with e.g. Wine/Proton or manual copy."
    return 0
}

# In-process assemble + verify. Reads the manifest once, and for each file:
#   - skips it if already present with the correct SHA-256
#   - otherwise assembles it from decompressed segments and verifies the hash
# Writes the segments still needed (TSV: "FETCH|REFETCH\t<sha>") to $4.
# Exits 0 only when every file is present and verified.
rift_assemble() {
    local manifest="$1" destdir="$2" segdir="$3" needfile="$4"
    python3 - "$manifest" "$destdir" "$segdir" "$needfile" <<'PYEOF'
import json, os, sys, zlib, hashlib
manifest, destdir, segdir, needfile = sys.argv[1:5]
files = json.load(open(manifest))["files"]
need = {}          # sha -> "FETCH" (missing) / "REFETCH" (present but bad)
incomplete = 0
total = len(files); done = 0

def sha_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

for fpath, meta in files.items():
    done += 1
    if done % 250 == 0:
        sys.stderr.write("\r  %d/%d checked..." % (done, total)); sys.stderr.flush()
    dest = os.path.join(destdir, fpath.replace("\\", "/"))
    want = (meta.get("sha256") or "").lower()
    segs = [s[1] for s in meta.get("segments", [])]

    # Already present and valid? leave it alone.
    if want and os.path.isfile(dest) and sha_of(dest) == want:
        continue

    # Any segments missing from disk? note them and move on.
    missing = [s for s in segs
               if not (os.path.isfile(os.path.join(segdir, s)) and os.path.getsize(os.path.join(segdir, s)) > 0)]
    if missing:
        for s in missing:
            need.setdefault(s, "FETCH")
        incomplete += 1
        continue

    # Assemble from segments and verify.
    ok = True
    try:
        d = os.path.dirname(dest)
        if d:
            os.makedirs(d, exist_ok=True)
        h = hashlib.sha256()
        with open(dest, "wb") as out:
            for s in segs:
                with open(os.path.join(segdir, s), "rb") as sf:
                    raw = zlib.decompress(sf.read())
                out.write(raw); h.update(raw)
        if want and h.hexdigest() != want:
            ok = False
    except Exception:
        ok = False
    if not ok:
        for s in segs:            # a segment produced bad output -> refetch fresh
            need[s] = "REFETCH"
        incomplete += 1

sys.stderr.write("\r" + " " * 40 + "\r")
with open(needfile, "w") as nf:
    for s, mode in need.items():
        nf.write(mode + "\t" + s + "\n")
sys.exit(0 if incomplete == 0 else 1)
PYEOF
}

# Rename backslash-named flat files (written by pre-fix versions) into the
# correct nested directory layout. Content is unchanged, so this salvages a
# prior download instead of re-fetching it.
migrate_legacy_paths() {
    local destdir="$1" found=0 oldf base newf
    while IFS= read -r -d '' oldf; do
        base="${oldf#"$destdir"/}"
        [[ "$base" == *'\'* ]] || continue
        newf="$destdir/${base//\\//}"
        mkdir -p "$(dirname "$newf")"
        mv -f "$oldf" "$newf"
        found=$((found+1))
    done < <(find "$destdir" -maxdepth 1 -type f -name '*\\*' -print0 2>/dev/null)
    [[ $found -gt 0 ]] && info "Salvaged $found file(s) from a previous version's naming (no re-download needed)."
    return 0
}

# Download a newline-delimited list of segment shas into segdir (parallel).
fetch_segments() {
    local listfile="$1" segdir="$2"
    local count; count="$(grep -c . "$listfile" 2>/dev/null || echo 0)"
    info "Fetching $count segment(s) (7 parallel)..."
    < "$listfile" xargs -P 7 -I {} bash -c \
        'cdn_seg_worker "$1" "$2" "$3" "$4"' _ {} "$V_BINID" "$token" "$segdir" || true
}

# Report segments that Oculus's CDN won't serve, and which files they belong to.
# $1 manifest, $2 file listing the still-missing segment shas, $3 total file count.
rift_report_unfetchable() {
    local manifest="$1" stillfile="$2" total_files="$3"
    err ""
    err "Some segments could not be downloaded from Oculus's CDN after retries and"
    err "chunked range requests. Oculus's server advertises the file size but stops"
    err "serving part of the data - i.e. this game version is partially unavailable"
    err "on Oculus's servers. This is not something the downloader can work around."
    python3 - "$manifest" "$stillfile" "$total_files" <<'PYEOF'
import json, sys
manifest, stillfile, total = sys.argv[1:4]
files = json.load(open(manifest))["files"]
bad = {l.strip() for l in open(stillfile) if l.strip()}
affected = [f.replace("\\", "/") for f, m in files.items()
            if {s[1] for s in m.get("segments", [])} & bad]
ok = int(total) - len(affected)
print("\n  %s of %s files completed successfully." % (ok, total), file=sys.stderr)
print("  %d file(s) could not be completed:" % len(affected), file=sys.stderr)
for f in affected[:25]:
    print("    - " + f, file=sys.stderr)
if len(affected) > 25:
    print("    ... and %d more" % (len(affected) - 25), file=sys.stderr)
PYEOF
    warn ""
    warn "The files that DID download are kept. If you believe this version should be"
    warn "available, try again later (CDN caches can change) or pick another version."
}

# Select the release channel so entitlement checks pass (needs user token).
change_channel() {
    local appid="$1" chanid="$2" token="$3"
    [[ -z "$chanid" ]] && return 0
    info "Selecting release channel..."
    graphql "$DOC_CHANGE_CHANNEL" \
        "$(jq -cn --arg a "$appid" --arg r "$chanid" \
            '{input:{client_mutation_id:"2",app_id:$a,release_channel_id:$r}}')" \
        "$token" >/dev/null
}

cmd_download() {
    local appid="" sel_id="" sel_code="" sel_str="" dest=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --appid) appid="$2"; shift 2 ;;
            --versionid) sel_id="$2"; shift 2 ;;
            --versioncode) sel_code="$2"; shift 2 ;;
            --versionstring) sel_str="$2"; shift 2 ;;
            --dest|--destination) dest="$2"; shift 2 ;;
            *) if [[ -z "$appid" ]]; then appid="$1"; elif [[ -z "$sel_id" ]]; then sel_id="$1"; fi; shift ;;
        esac
    done
    [[ -z "$appid" ]] && { err "Usage: $0 download --appid <id> --versionid <binaryId> [--dest DIR]"; return 1; }
    [[ -z "$sel_id$sel_code$sel_str" ]] && { err "Specify --versionid, --versioncode or --versionstring."; return 1; }

    local token; token="$(ensure_token)" || return 1
    local headset; headset="$(get_headset)"

    info "Resolving version..."
    if ! resolve_version "$appid" "$sel_id" "$sel_code" "$sel_str"; then
        err "That version was not found among the downloadable versions."
        return 1
    fi
    good "Selected $VERSIONS_APPNAME $V_VER (code $V_CODE, id $V_BINID) [channel: $V_CHANNELS]"

    change_channel "$appid" "$V_CHANID" "$token"

    local destdir="${dest:-$APPS_DIR/$appid/$V_BINID}"
    local ok=1
    if headset_is_rift "$headset"; then
        download_rift "$token" "$destdir" || ok=0
    else
        download_android "$appid" "$token" "$destdir" || ok=0
    fi
    [[ "$ok" == 0 ]] && return 1

    # record in config for list/install
    record_app "$appid" "$VERSIONS_APPNAME" "$headset" "$V_BINID" "$V_VER" "$V_CODE"
    good "Done. Stored in $destdir"
    if ! headset_is_rift "$headset"; then
        info "Install to a connected Quest with: $0 install --appid $appid --versionid $V_BINID"
    fi
}

# Worker for parallel segment download (must be exported for xargs subshell).
# Uses HTTP/1.1 (the CDN resets HTTP/2 streams on large objects), verifies the
# full Content-Length was received, and falls back to a chunked Range download
# to recover segments whose stream is reset mid-transfer. A non-empty file on
# disk is treated as already done (so downloads are resumable).
cdn_seg_worker() {
    local sha="$1" binid="$2" token="$3" segdir="$4"
    local out="$segdir/$sha" tmp="$segdir/$sha.part"
    [[ -s "$out" ]] && return 0
    local url="$SECURECDN/segment/?access_token=$token&binary_id=$binid&segment_sha256=$sha"
    local i
    # Straight download first (fast path for the vast majority of segments).
    # curl -f errors if fewer than Content-Length bytes arrive, so truncated
    # responses are rejected rather than saved.
    for i in 1 2 3; do
        rm -f "$tmp"
        if curl -fsSL --http1.1 --retry 3 --retry-delay 2 --retry-connrefused --retry-all-errors \
                --max-time 1800 -A "$UA" "$url" -o "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
            mv -f "$tmp" "$out"; return 0
        fi
        sleep "$i"
    done
    # Chunked Range fallback: fetch in 1 MiB pieces that complete before a reset.
    rm -f "$tmp"
    local clen
    clen="$(curl -fsSIL --http1.1 -A "$UA" "$url" 2>/dev/null \
            | awk 'tolower($1)=="content-length:"{v=$2} END{gsub(/\r/,"",v); print v}')"
    [[ -z "$clen" || "$clen" -le 0 ]] && { rm -f "$tmp"; return 1; }
    : > "$tmp"
    local start=0 chunk=$((1024*1024)) end want got a ctmp="$segdir/$sha.chunk"
    while [[ $start -lt $clen ]]; do
        end=$((start+chunk-1)); [[ $end -ge $clen ]] && end=$((clen-1))
        want=$((end-start+1)); got=0
        for a in 1 2 3 4 5; do
            if curl -fsS --http1.1 -r "${start}-${end}" --max-time 300 -A "$UA" "$url" -o "$ctmp" 2>/dev/null; then
                got="$(stat -c%s "$ctmp" 2>/dev/null || echo 0)"
                if [[ "$got" -eq "$want" ]]; then cat "$ctmp" >> "$tmp"; break; fi
            fi
            got=0; sleep 1
        done
        rm -f "$ctmp"
        [[ "$got" -ne "$want" ]] && { rm -f "$tmp"; return 1; }  # a byte range the CDN won't serve
        start=$((end+1))
    done
    if [[ "$(stat -c%s "$tmp" 2>/dev/null || echo 0)" -eq "$clen" ]]; then
        mv -f "$tmp" "$out"; return 0
    fi
    rm -f "$tmp"; return 1
}

# ----------------------------------------------------------------------------
# App recording / list
# ----------------------------------------------------------------------------
record_app() {
    local id="$1" name="$2" headset="$3" verid="$4" ver="$5" code="$6" tmp
    tmp="$(mktemp)"
    jq --arg id "$id" --arg name "$name" --arg h "$headset" \
       --arg vid "$verid" --arg v "$ver" --arg c "$code" '
        .apps = ((.apps // []) as $apps |
          if ($apps | map(select(.id==$id and .headset==$h)) | length) > 0
          then ($apps | map(
                if (.id==$id and .headset==$h) then
                    .name=$name |
                    .versions = ((.versions // []) +
                        (if ((.versions // []) | map(select(.id==$vid)) | length)==0
                         then [{id:$vid,version:$v,version_code:$c}] else [] end))
                else . end))
          else ($apps + [{id:$id,name:$name,headset:$h,
                versions:[{id:$vid,version:$v,version_code:$c}]}])
          end)' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
}

cmd_list() {
    local n; n="$(cfg '(.apps // []) | length')"
    if [[ "$n" -eq 0 ]]; then warn "No apps downloaded yet."; return 0; fi
    echo
    cfg '(.apps // [])[] | "\(.name)  [\(.headset)]  (\(.id))",
         (.versions[] | "    - \(.version)  code=\(.version_code)  id=\(.id)")' \
        | sed 's/^/  /'
    echo
    info "Downloaded files live under: $APPS_DIR/<appId>/<binaryId>/"
}

# ----------------------------------------------------------------------------
# Install (Quest via ADB)
# ----------------------------------------------------------------------------
apk_package_id() {
    # Extract package name from an APK using aapt if present, else unzip+strings.
    local apk="$1"
    if need aapt; then
        aapt dump badging "$apk" 2>/dev/null | sed -n "s/.*package: name='\([^']*\)'.*/\1/p" | head -1
    else
        echo ""
    fi
}

cmd_install() {
    local appid="" verid=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --appid) appid="$2"; shift 2 ;;
            --versionid) verid="$2"; shift 2 ;;
            *) if [[ -z "$appid" ]]; then appid="$1"; elif [[ -z "$verid" ]]; then verid="$1"; fi; shift ;;
        esac
    done
    [[ -z "$appid" || -z "$verid" ]] && { err "Usage: $0 install --appid <id> --versionid <binaryId>"; return 1; }
    local headset; headset="$(get_headset)"
    if headset_is_rift "$headset"; then
        err "Rift games can't be installed on Linux (Windows-only Oculus runtime)."
        info "Files are in: $APPS_DIR/$appid/$verid/"
        return 1
    fi
    require adb
    local dir="$APPS_DIR/$appid/$verid"
    local apk="$dir/app.apk"
    [[ -f "$apk" ]] || { err "APK not found at $apk. Download it first."; return 1; }

    info "Checking for a connected device..."
    adb start-server >/dev/null 2>&1
    local devs; devs="$(adb devices | awk 'NR>1 && $2=="device"{print $1}')"
    [[ -z "$devs" ]] && { err "No authorized ADB device. Plug in your Quest and allow USB debugging."; return 1; }
    info "Device(s): $devs"

    local pkg; pkg="$(apk_package_id "$apk")"
    if [[ -n "$pkg" ]]; then
        info "Uninstalling old version of $pkg (keeping data)..."
        adb uninstall -k "$pkg" >/dev/null 2>&1 || true
    else
        warn "Could not read package id (install 'aapt' for cleaner upgrades). Continuing."
    fi

    info "Installing APK (this can take a minute)..."
    if ! adb install -r -g "$apk"; then
        err "adb install failed. See output above."
        return 1
    fi
    good "APK installed."

    if [[ -d "$dir/obbs" ]] && [[ -n "$pkg" ]]; then
        info "Pushing OBBs..."
        adb shell mkdir -p "/sdcard/Android/obb/$pkg" >/dev/null 2>&1 || true
        local f
        for f in "$dir/obbs"/*; do
            [[ -e "$f" ]] || continue
            info "  push $(basename "$f")"
            adb push "$f" "/sdcard/Android/obb/$pkg/$(basename "$f")"
        done
    elif [[ -d "$dir/obbs" ]]; then
        warn "OBBs present but package id unknown (need aapt); skipping OBB push."
    fi
    good "Done. Launch the game from your headset."
}

# ----------------------------------------------------------------------------
# Interactive menu
# ----------------------------------------------------------------------------
menu() {
    while true; do
        echo
        local hs; hs="$(headset_display "$(get_headset)")"
        echo "${C_BOLD}=== Oculus Downgrader (Linux) ===${C_RST}   headset: $hs"
        echo "[1] Search for an app"
        echo "[2] List versions of an app id"
        echo "[3] Download a version"
        echo "[4] Install a downloaded version to Quest (adb)"
        echo "[5] List downloaded apps"
        echo "[6] Log in with Meta account (browser)"
        echo "[7] Set / verify access token"
        echo "[8] Change headset"
        echo "[9] Downgrade Beat Saber (shortcut)"
        echo "[0] Exit"
        read -rp "Choice: " c
        case "$c" in
            1) read -rp "Search term: " t; cmd_search "$t" ;;
            2) read -rp "App id: " a; cmd_versions "$a" ;;
            3) read -rp "App id: " a; read -rp "Binary (version) id: " v
               cmd_download --appid "$a" --versionid "$v" ;;
            4) read -rp "App id: " a; read -rp "Binary (version) id: " v
               cmd_install --appid "$a" --versionid "$v" ;;
            5) cmd_list ;;
            6) cmd_login ;;
            7) cmd_token ;;
            8) cmd_headset ;;
            9) if headset_is_rift "$(get_headset)"; then cmd_versions "$RIFT_BS_APPID"
               else cmd_versions "$QUEST_BS_APPID"; fi ;;
            0|q|exit) exit 0 ;;
            *) err "Unknown choice." ;;
        esac
    done
}

# ----------------------------------------------------------------------------
# Usage
# ----------------------------------------------------------------------------
usage() {
    cat <<EOF
${C_BOLD}oculus-downgrader.sh${C_RST} - download older Oculus/Meta app versions on Linux

USAGE:
  $0 [command] [options]

COMMANDS:
  menu                         Interactive menu (default if no command)
  login                        Log in with your Meta account via the browser
  token [TOKEN]                Set/verify your Meta access token (or paste one)
  headset [NAME]               Set headset (Quest, Quest3, Quest3S, Rift, GearVR, Go)
  search <term>                Search the store for an app id
  versions <appId>             List downloadable versions of an app
  download --appid <id> --versionid <binId> [--dest DIR]
                               Download a version (APK+OBB for Quest, files for Rift)
                               (also accepts --versioncode / --versionstring)
  install --appid <id> --versionid <binId>
                               Install a downloaded Quest version over ADB
  list                         List apps you've downloaded
  help                         Show this help

EXAMPLES:
  $0 headset Quest
  $0 token
  $0 search "beat saber"
  $0 versions $QUEST_BS_APPID
  $0 download --appid $QUEST_BS_APPID --versionid 36522858274028017
  $0 install  --appid $QUEST_BS_APPID --versionid 36522858274028017

Config: $CONFIG_FILE
Data:   $APPS_DIR
EOF
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
    check_core_deps
    config_init
    local cmd="${1:-menu}"
    [[ $# -gt 0 ]] && shift
    case "$cmd" in
        menu|"") menu ;;
        login) cmd_login ;;
        token) cmd_token "$@" ;;
        headset) cmd_headset "$@" ;;
        search) cmd_search "$@" ;;
        versions) cmd_versions "$@" ;;
        download|d) cmd_download "$@" ;;
        install) cmd_install "$@" ;;
        list) cmd_list ;;
        help|-h|--help) usage ;;
        *) err "Unknown command: $cmd"; echo; usage; exit 1 ;;
    esac
}

main "$@"

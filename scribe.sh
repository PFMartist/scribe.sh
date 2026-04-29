#!/bin/bash
# ==============================
# Scribe — 自动手记人偶 v2.0
# 支持 OpenAI / Anthropic 双 API
# ==============================

VERSION="2.0"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# ================= 配置 =================
PROVIDER="openai"
API_KEY=""
BASE_URL="https://api.deepseek.com"
MODEL="deepseek-v4-flash"

SAVE_DIR="$SCRIPT_DIR/.scribe_history"
SETTINGS_FILE="$SCRIPT_DIR/.scribe_settings.json"
KEY_FILE="$SCRIPT_DIR/.scribe_key"
SKILL_ROOT="$SCRIPT_DIR/.skills"
DEFAULT_SKILL_ID="default-assistant"
BASE_SYSTEM_PROMPT="你是一个智能助手。"
# =======================================

mkdir -p "$SAVE_DIR"

CURRENT_HISTORY=$(mktemp)

# skill 状态
CURRENT_SKILL_ID=""
CURRENT_SKILL_DIR=""
CURRENT_SKILL_FILE=""
CURRENT_SKILL_NAME=""
CURRENT_SKILL_DESCRIPTION=""
CURRENT_SKILL_BODY=""
CURRENT_SKILL_APPENDICES=""
CURRENT_SKILL_APPENDIX_COUNT=0
STARTUP_SKILL_NOTE=""
SHOW_REASONING="true"
AI_THINKING="true"

# ================= 辅助函数 =================

trim_spaces() {
    local s="$1"
    s=$(printf "%s" "$s" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    printf "%s" "$s"
}

mask_api_key() {
    local key="$1" n=${#key}
    if [[ $n -le 8 ]]; then printf "***"; return; fi
    printf "%s...%s" "${key:0:3}" "${key:$((n-4)):4}"
}

normalize_toggle_value() {
    local raw_value="$1"
    raw_value=$(printf "%s" "$raw_value" | tr '[:upper:]' '[:lower:]')
    case "$raw_value" in
        on|true|1|yes|y|show) printf "true" ;;
        off|false|0|no|n|hide) printf "false" ;;
        *) return 1 ;;
    esac
}

# ================= Settings =================

create_default_settings() {
    jq -n \
        --arg provider "openai" \
        --arg oai_url "https://api.deepseek.com" \
        --arg oai_key "" \
        --arg oai_model "deepseek-v4-flash" \
        --arg anth_url "https://api.anthropic.com" \
        --arg anth_key "" \
        --arg anth_model "claude-sonnet-4-6" \
        --arg last_skill_id "" \
        --argjson show_reasoning true \
        --argjson ai_thinking true \
        '{
            provider: $provider,
            openai_base_url: $oai_url, openai_api_key: $oai_key, openai_model: $oai_model,
            anthropic_base_url: $anth_url, anthropic_api_key: $anth_key, anthropic_model: $anth_model,
            last_skill_id: $last_skill_id,
            show_reasoning: $show_reasoning, ai_thinking: $ai_thinking
        }' > "$SETTINGS_FILE"
}

ensure_settings_file() {
    if [[ ! -f "$SETTINGS_FILE" ]]; then
        create_default_settings
        return
    fi
    if ! jq empty "$SETTINGS_FILE" >/dev/null 2>&1; then
        local backup="${SETTINGS_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        cp "$SETTINGS_FILE" "$backup" 2>/dev/null
        echo -e "\033[1;33m[警告] 设置文件损坏，已备份到 '$backup' 并重置。\033[0m"
        create_default_settings
    fi
}

update_setting_string() {
    local key="$1" value="$2" tmp
    tmp=$(mktemp)
    jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
}

update_setting_boolean() {
    local key="$1" value="$2" tmp
    tmp=$(mktemp)
    jq --arg k "$key" --argjson v "$value" '.[$k] = $v' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
}

# 根据当前 provider 加载配置
_load_provider_config() {
    local prefix=""
    if [[ "$PROVIDER" == "anthropic" ]]; then prefix="anthropic"; else prefix="openai"; fi
    BASE_URL=$(jq -r --arg k "${prefix}_base_url" '.[$k] // ""' "$SETTINGS_FILE")
    BASE_URL="${BASE_URL%/}"
    BASE_URL="${BASE_URL%/v1}"
    API_KEY=$(trim_spaces "$(jq -r --arg k "${prefix}_api_key" '.[$k] // ""' "$SETTINGS_FILE")")
    local m
    m=$(jq -r --arg k "${prefix}_model" '.[$k] // ""' "$SETTINGS_FILE")
    if [[ -n "$m" && "$m" != "null" ]]; then MODEL="$m"; fi
}

_set_provider() {
    local new_provider="$1"
    if [[ "$new_provider" != "openai" && "$new_provider" != "anthropic" ]]; then return 1; fi
    PROVIDER="$new_provider"
    local tmp=$(mktemp)
    jq --arg p "$PROVIDER" '.provider = $p' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
    _load_provider_config
    return 0
}

save_provider_config() {
    local prefix=""
    if [[ "$PROVIDER" == "anthropic" ]]; then prefix="anthropic"; else prefix="openai"; fi
    local tmp=$(mktemp)
    jq --arg url "$BASE_URL" --arg key "$API_KEY" --arg model "$MODEL" \
        --arg p "$prefix" \
        '.[$p + "_base_url"] = $url | .[$p + "_api_key"] = $key | .[$p + "_model"] = $model' \
        "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
}

load_persisted_settings() {
    SHOW_REASONING=$(jq -r '.show_reasoning // true' "$SETTINGS_FILE")
    AI_THINKING=$(jq -r '.ai_thinking // true' "$SETTINGS_FILE")
    PROVIDER=$(jq -r '.provider // "openai"' "$SETTINGS_FILE")
    _load_provider_config
}

read_last_skill_id() {
    jq -r '.last_skill_id // ""' "$SETTINGS_FILE"
}

save_last_skill_id() {
    if [[ -z "$CURRENT_SKILL_ID" ]]; then return; fi
    update_setting_string "last_skill_id" "$CURRENT_SKILL_ID"
}

# ================= Provider 抽象层 =================

provider_endpoint() {
    if [[ "$PROVIDER" == "anthropic" ]]; then printf "/v1/messages"; else printf "/v1/chat/completions"; fi
}

_provider_auth_parts() {
    if [[ "$PROVIDER" == "anthropic" ]]; then
        auth_h1_name="x-api-key"; auth_h1_value="$API_KEY"
        auth_h2_name="anthropic-version"; auth_h2_value="2023-06-01"
    else
        auth_h1_name="Authorization"; auth_h1_value="Bearer $API_KEY"
        auth_h2_name=""; auth_h2_value=""
    fi
}

provider_build_request_payload() {
    local temp_hist="$1"
    if [[ "$PROVIDER" == "anthropic" ]]; then
        _build_anthropic_payload "$temp_hist"
    else
        _build_openai_payload "$temp_hist"
    fi
}

_build_openai_payload() {
    local temp_hist="$1"
    local thinking_type="disabled"
    if [[ "$AI_THINKING" == "true" ]]; then thinking_type="enabled"; fi
    jq -n \
        --arg model "$MODEL" \
        --arg thinking_type "$thinking_type" \
        --arg reasoning_effort "high" \
        --slurpfile messages "$temp_hist" \
        '{model: $model, messages: $messages[0], stream: true, stream_options: {include_usage: true}, thinking: {type: $thinking_type}} + (if $thinking_type == "enabled" then {reasoning_effort: $reasoning_effort} else {} end)'
}

_build_anthropic_payload() {
    local temp_hist="$1"
    local system_prompt
    system_prompt=$(jq -r '.[0].content // empty' "$temp_hist" 2>/dev/null)
    local messages_only=$(mktemp)
    jq '[.[] | select(.role != "system")]' "$temp_hist" > "$messages_only"
    local max_tokens=8192
    local thinking_json=""
    if [[ "$AI_THINKING" == "true" ]]; then
        thinking_json='{thinking: {type: "enabled", budget_tokens: 4000}}'
    else
        thinking_json='{thinking: {type: "disabled"}}'
    fi
    jq -n \
        --arg model "$MODEL" \
        --argjson max_tokens "$max_tokens" \
        --arg system "$system_prompt" \
        --slurpfile messages "$messages_only" \
        '{model: $model, max_tokens: $max_tokens, system: $system, messages: $messages[0], stream: true} + '"$thinking_json" 2>/dev/null
    rm -f "$messages_only"
}

provider_parse_sse_line() {
    local data="$1" event="$2"
    if [[ "$PROVIDER" == "anthropic" ]]; then
        _parse_anthropic_sse "$data" "$event"
    else
        _parse_openai_sse "$data"
    fi
}

_parse_openai_sse() {
    printf '%s' "$1" | jq -r '
        (.error.message // "") as $e |
        (.choices[0].delta.reasoning_content // "") as $r |
        (.choices[0].delta.content // "") as $c |
        (.usage // null) as $u |
        @sh "api_error=\($e) reasoning=\($r) content=\($c) has_usage=\(if $u then "yes" else "no" end) prompt_tokens=\($u.prompt_tokens // 0) completion_tokens=\($u.completion_tokens // 0) total_tokens=\($u.total_tokens // 0)"
    '
}

_parse_anthropic_sse() {
    local data="$1" event="$2"
    printf '%s' "$data" | jq -r --arg event "$event" '
        (.error.message // "") as $e |
        (if .type == "content_block_delta" then
            if .delta.type == "thinking_delta" then .delta.thinking
            elif .delta.type == "text_delta" then .delta.text else "" end
         else "" end) as $text |
        (if .type == "content_block_delta" and .delta.type == "thinking_delta" then .delta.thinking else "" end) as $reasoning |
        (if .type == "message_start" then .message.usage
         elif .type == "message_delta" then .usage else null end) as $u |
        (if $u then ($u.input_tokens // $u.prompt_tokens // 0) else 0 end) as $pt |
        (if $u then ($u.output_tokens // $u.completion_tokens // 0) else 0 end) as $ct |
        @sh "api_error=\($e)
        reasoning=\($reasoning)
        content=\($text)
        has_usage=\(if $u then "yes" else "no" end)
        prompt_tokens=\($pt)
        completion_tokens=\($ct)
        total_tokens=\($pt + $ct)"
    '
}

# ================= Skill 管理 =================

extract_frontmatter_value() {
    local skill_file="$1" key="$2"
    awk -F':' -v key="$key" '
        NR == 1 { if ($0 != "---") exit; next }
        $0 == "---" { exit }
        $1 == key { sub(/^[^:]+:[[:space:]]*/, "", $0); print $0; exit }
    ' "$skill_file"
}

extract_skill_body() {
    local skill_file="$1"
    awk '
        NR == 1 && $0 == "---" { in_header = 1; next }
        in_header && $0 == "---" { in_header = 0; next }
        !in_header { print }
    ' "$skill_file"
}

discover_skill_appendices() {
    local skill_dir="$1"
    local appendix_roots=("references" "appendices")
    local appendix_root="" appendix_dir="" appendix_file="" appendix_content="" appendix_label=""
    CURRENT_SKILL_APPENDICES=""
    CURRENT_SKILL_APPENDIX_COUNT=0
    for appendix_root in "${appendix_roots[@]}"; do
        appendix_dir="$skill_dir/$appendix_root"
        [[ -d "$appendix_dir" ]] || continue
        while IFS= read -r appendix_file; do
            [[ -f "$appendix_file" ]] || continue
            appendix_content=$(<"$appendix_file")
            [[ -n "${appendix_content//[$' \t\r\n']}" ]] || continue
            appendix_label="$appendix_root/$(basename "$appendix_file")"
            CURRENT_SKILL_APPENDICES+=$'\n\n'"## 附录：$appendix_label"$'\n\n'"$appendix_content"
            CURRENT_SKILL_APPENDIX_COUNT=$((CURRENT_SKILL_APPENDIX_COUNT + 1))
        done < <(find "$appendix_dir" -maxdepth 1 -type f -name '*.md' | sort)
    done
}

list_skill_ids_raw() {
    if [[ ! -d "$SKILL_ROOT" ]]; then return; fi
    find "$SKILL_ROOT" -mindepth 1 -maxdepth 1 -type d | sort | while IFS= read -r skill_dir; do
        [[ -f "$skill_dir/SKILL.md" ]] || continue
        basename "$skill_dir"
    done
}

load_skill() {
    local skill_id="$1"
    local skill_dir="$SKILL_ROOT/$skill_id"
    local skill_file="$skill_dir/SKILL.md"
    local skill_name="" skill_description="" skill_body=""
    if [[ -z "$skill_id" || ! -f "$skill_file" ]]; then return 1; fi
    skill_name=$(extract_frontmatter_value "$skill_file" "name")
    skill_description=$(extract_frontmatter_value "$skill_file" "description")
    skill_body=$(extract_skill_body "$skill_file")
    discover_skill_appendices "$skill_dir"
    [[ -z "$skill_name" ]] && skill_name="$skill_id"
    CURRENT_SKILL_ID="$skill_id"
    CURRENT_SKILL_DIR="$skill_dir"
    CURRENT_SKILL_FILE="$skill_file"
    CURRENT_SKILL_NAME="$skill_name"
    CURRENT_SKILL_DESCRIPTION="$skill_description"
    CURRENT_SKILL_BODY="$skill_body"
    return 0
}

reset_skill_state() {
    CURRENT_SKILL_ID=""
    CURRENT_SKILL_DIR=""
    CURRENT_SKILL_FILE=""
    CURRENT_SKILL_NAME=""
    CURRENT_SKILL_DESCRIPTION=""
    CURRENT_SKILL_BODY=""
    CURRENT_SKILL_APPENDICES=""
    CURRENT_SKILL_APPENDIX_COUNT=0
}

build_system_prompt() {
    if [[ -z "$CURRENT_SKILL_FILE" || -z "$CURRENT_SKILL_BODY" ]]; then
        printf "%s" "$BASE_SYSTEM_PROMPT"
        return
    fi
    local description="${CURRENT_SKILL_DESCRIPTION:-(无描述)}"
    printf "%s\n\n当前已加载技能:\n- skill_id: %s\n- name: %s\n- description: %s\n\n以下是必须遵循的技能说明:\n%s" \
        "$BASE_SYSTEM_PROMPT" "$CURRENT_SKILL_ID" "$CURRENT_SKILL_NAME" "$description" "$CURRENT_SKILL_BODY"
    if [[ -n "$CURRENT_SKILL_APPENDICES" ]]; then
        printf "\n\n以下是该技能的补充附录。仅在涉及剧情、关系、设定或扩展背景时调用；若与主技能说明冲突，始终以主技能说明为准。%s\n" \
            "$CURRENT_SKILL_APPENDICES"
    else
        printf "\n"
    fi
}

list_skills() {
    local found=0
    echo -e "\033[1;36m可用的 skill:\033[0m"
    if [[ ! -d "$SKILL_ROOT" ]]; then
        echo "  (skill 目录不存在: $SKILL_ROOT)"; return
    fi
    while IFS= read -r skill_id; do
        [[ -n "$skill_id" ]] || continue
        local skill_file="$SKILL_ROOT/$skill_id/SKILL.md" sn sd
        sn=$(extract_frontmatter_value "$skill_file" "name")
        sd=$(extract_frontmatter_value "$skill_file" "description")
        [[ -z "$sn" ]] && sn="$skill_id"
        [[ -z "$sd" ]] && sd="(无描述)"
        echo "  - $skill_id | $sn | $sd"
        found=1
    done < <(list_skill_ids_raw)
    if [[ $found -eq 0 ]]; then echo "  (无)"; fi
}

show_current_skill() {
    echo -e "\033[1;36m当前 skill:\033[0m"
    if [[ -z "$CURRENT_SKILL_FILE" ]]; then
        echo "  - 内置默认提示"
        echo "  - system prompt: $BASE_SYSTEM_PROMPT"
        return
    fi
    echo "  - id: $CURRENT_SKILL_ID"
    echo "  - name: $CURRENT_SKILL_NAME"
    echo "  - description: ${CURRENT_SKILL_DESCRIPTION:-(无描述)}"
    echo "  - file: $CURRENT_SKILL_FILE"
    echo "  - appendices: $CURRENT_SKILL_APPENDIX_COUNT"
}

auto_load_default_skill() {
    local remembered_skill_id=""
    reset_skill_state
    STARTUP_SKILL_NOTE=""
    remembered_skill_id=$(read_last_skill_id)
    if [[ -n "$remembered_skill_id" ]] && load_skill "$remembered_skill_id"; then
        STARTUP_SKILL_NOTE="[系统] 已恢复上次使用的 skill: $remembered_skill_id"
        return 0
    fi
    if [[ -n "$remembered_skill_id" ]]; then
        STARTUP_SKILL_NOTE="[系统] 上次使用的 skill '$remembered_skill_id' 不存在，已回退到默认 skill。"
    fi
    if [[ -n "$DEFAULT_SKILL_ID" ]] && load_skill "$DEFAULT_SKILL_ID"; then
        save_last_skill_id; return 0
    fi
    return 1
}

# ================= 历史管理 =================

init_history() {
    jq -n --arg content "$(build_system_prompt)" \
        '[{"role": "system", "content": $content}]' > "$CURRENT_HISTORY"
}

cleanup() {
    rm -f "$CURRENT_HISTORY"
}
trap cleanup EXIT

manage_history() {
    local action="$1" name="$2" target_file="$SAVE_DIR/$name.json"
    if [[ -z "$name" ]]; then
        echo "用法: $action <对话名称>"; return 1
    fi
    case "$action" in
        save)
            cp "$CURRENT_HISTORY" "$target_file"
            echo -e "\033[1;32m[系统] 对话已保存为 '$name'\033[0m" ;;
        load)
            if [[ -f "$target_file" ]]; then
                cp "$target_file" "$CURRENT_HISTORY"
                echo -e "\033[1;32m[系统] 已加载对话 '$name'\033[0m"
                local last_msg; last_msg=$(jq -r '.[-1].content' "$CURRENT_HISTORY")
                echo -e "最后一条记忆: ${last_msg:0:50}..."
            else
                echo -e "\033[1;31m[错误] 未找到对话 '$name'\033[0m"
            fi ;;
        delete)
            if [[ -f "$target_file" ]]; then
                rm "$target_file"
                echo -e "\033[1;32m[系统] 已删除对话 '$name'\033[0m"
            else
                echo -e "\033[1;31m[错误] 未找到对话 '$name'\033[0m"
            fi ;;
    esac
}

list_history() {
    echo -e "\033[1;36m已保存的对话:\033[0m"
    if [[ -z $(ls -A "$SAVE_DIR" 2>/dev/null) ]]; then
        echo "  (无)"
    else
        ls "$SAVE_DIR" | sed 's/\.json$//' | sed 's/^/  - /'
    fi
}

show_reasoning_status() {
    if [[ "$SHOW_REASONING" == "true" ]]; then printf "开启"; else printf "关闭"; fi
}

show_ai_thinking_status() {
    if [[ "$AI_THINKING" == "true" ]]; then printf "开启"; else printf "关闭"; fi
}

# ================= API 调用 =================

perform_chat() {
    local user_input="$1"

    while true; do
        local temp_hist_for_request=$(mktemp)
        jq --arg content "$user_input" '. + [{"role": "user", "content": $content}]' "$CURRENT_HISTORY" > "$temp_hist_for_request"

        local request_payload
        request_payload=$(provider_build_request_payload "$temp_hist_for_request")

        local endpoint api_url
        endpoint=$(provider_endpoint)
        api_url="${BASE_URL}${endpoint}"

        echo -e "\033[1;35m自动手记人偶 正在思考...\033[0m"

        local response_file=$(mktemp)
        local raw_stream_file=$(mktemp)
        local api_error_file=$(mktemp)
        local curl_error_file=$(mktemp)
        local current_state=""
        local current_event=""

        # 构建 request body 文件
        local request_file=$(mktemp)
        printf '%s' "$request_payload" > "$request_file"

        # 获取认证头
        local auth_h1_name="" auth_h1_value="" auth_h2_name="" auth_h2_value=""
        _provider_auth_parts

        curl --max-time 600 -sS -N -X POST "$api_url" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            -H "${auth_h1_name}: ${auth_h1_value}" \
            ${auth_h2_name:+-H "${auth_h2_name}: ${auth_h2_value}"} \
            -d @"$request_file" \
            -w '\nCURL_HTTP_STATUS:%{http_code}\n' 2> "$curl_error_file" | tee "$raw_stream_file" | \
        while IFS= read -r line; do
            if [[ "$line" == "event: "* ]]; then
                current_event="${line#event: }"; continue
            fi
            if [[ "$line" != "data: "* ]]; then continue; fi

            local data="${line#data: }"
            if [[ "$data" == "[DONE]" ]]; then break; fi

            local api_error="" reasoning="" content="" has_usage="no"
            local prompt_tokens=0 completion_tokens=0 total_tokens=0
            eval $(provider_parse_sse_line "$data" "$current_event")
            current_event=""

            if [[ -n "$api_error" ]]; then
                printf "%s" "$api_error" > "$api_error_file"; break
            fi

            if [[ -n "$reasoning" && "$SHOW_REASONING" == "true" ]]; then
                if [[ "$current_state" != "thinking" ]]; then
                    echo -e "\n\033[0;90m=== 思考过程 ===\033[0m"
                    echo -ne "\033[0;90m"
                    current_state="thinking"
                fi
                printf "%s" "$reasoning"
            fi

            if [[ -n "$content" ]]; then
                if [[ "$current_state" == "thinking" ]]; then
                    echo -e "\n\033[0;90m=== 思考结束 ===\033[0m\n"
                    echo -e "\033[1;32m自动手记人偶:\033[0m"
                    current_state="answering"
                elif [[ "$current_state" != "answering" ]]; then
                    echo -e "\033[1;32m自动手记人偶:\033[0m"
                    current_state="answering"
                fi
                printf "%s" "$content"
                echo -n "$content" >> "$response_file"
            fi

            if [[ "$has_usage" == "yes" ]]; then
                if [[ "$current_state" == "thinking" ]]; then
                    echo -e "\n\033[0;90m=== 思考结束 ===\033[0m\n"
                    current_state="done"
                fi
                echo -e "\n\n\033[1;30m[记忆体状态] Prompt: $prompt_tokens | Completion: $completion_tokens | Total: $total_tokens\033[0m"
            fi
        done

        echo ""

        local full_response api_error_message curl_err http_status
        full_response=$(cat "$response_file")
        api_error_message=$(cat "$api_error_file" 2>/dev/null)
        curl_err=$(cat "$curl_error_file")
        http_status=$(grep -oE 'CURL_HTTP_STATUS:[0-9]+' "$raw_stream_file" | tail -n 1 | cut -d: -f2)

        if [[ -z "$full_response" ]]; then
            echo -e "\033[1;31m[错误] 请求失败，未收到有效回复。\033[0m"
            if [[ -n "$http_status" ]]; then echo -e "\033[0;31mHTTP Status: $http_status\033[0m"; fi
            if [[ -n "$api_error_message" ]]; then echo -e "\033[0;31m$api_error_message\033[0m"; fi
            local first_body_line
            first_body_line=$(grep -vE '^(data: |CURL_HTTP_STATUS:)' "$raw_stream_file" | sed '/^[[:space:]]*$/d' | head -n 1)
            if [[ -n "$first_body_line" ]]; then
                local api_msg
                api_msg=$(printf "%s" "$first_body_line" | jq -r '.error.message // .message // empty' 2>/dev/null)
                if [[ -n "$api_msg" ]]; then echo -e "\033[0;31m$api_msg\033[0m"
                else echo -e "\033[0;31m$first_body_line\033[0m"; fi
            fi
            if [[ -n "$curl_err" ]]; then echo -e "\033[0;31m$curl_err\033[0m"; fi
            echo -ne "\033[1;33m神经连接似乎有问题，是否重新提交刚才的输入? (y/n): \033[0m"
            read -r retry_choice
            if [[ "$retry_choice" == "y" || "$retry_choice" == "Y" ]]; then
                echo -e "\033[1;32m正在重试...\033[0m"
                rm -f "$response_file" "$raw_stream_file" "$api_error_file" "$curl_error_file" "$request_file" "$temp_hist_for_request"
                continue
            else
                echo -e "\033[0;33m已放弃本次输入。\033[0m"
                rm -f "$response_file" "$raw_stream_file" "$api_error_file" "$curl_error_file" "$request_file" "$temp_hist_for_request"
                return
            fi
        fi

        local tmp_hist=$(mktemp)
        jq --arg content "$user_input" '. += [{"role": "user", "content": $content}]' "$CURRENT_HISTORY" > "$tmp_hist" && mv "$tmp_hist" "$CURRENT_HISTORY"
        jq --arg content "$full_response" '. += [{"role": "assistant", "content": $content}]' "$CURRENT_HISTORY" > "$tmp_hist" && mv "$tmp_hist" "$CURRENT_HISTORY"
        rm -f "$response_file" "$raw_stream_file" "$api_error_file" "$curl_error_file" "$request_file" "$temp_hist_for_request"
        break
    done
}

# ================= 帮助 =================

show_help() {
    echo -e "\n\033[1;36m========== 自动手记人偶 帮助 ==========\033[0m"
    echo -e "\033[1;33m基础操作:\033[0m"
    echo -e "  可以直接输入问题与 自动手记人偶 进行对话 。"
    echo -e ""
    echo -e "\033[1;33m系统命令:\033[0m"
    echo -e "  \033[1;32m/new\033[0m / \033[1;32m/clear\033[0m 清空当前上下文，开始全新的对话。"
    echo -e "  \033[1;32m/read <文件> [问]\033[0m 读取文件内容并发送给 AI。"
    echo -e "  \033[1;32m/exit\033[0m / \033[1;32m/quit\033[0m    退出程序。"
    echo -e "  \033[1;32m/help\033[0m            显示此帮助信息。"
    echo -e ""
    echo -e "\033[1;33mProvider 管理:\033[0m"
    echo -e "  \033[1;32m/provider [openai|anthropic]\033[0m 查看/切换 API 提供商。"
    echo -e "  \033[1;32m/model [名称]\033[0m      查看或设置模型。"
    echo -e "  \033[1;32m/key [api-key]\033[0m     查看或设置 API Key。"
    echo -e "  \033[1;32m/ping\033[0m              测试 API 连通性。"
    echo -e ""
    echo -e "\033[1;33m设置管理:\033[0m"
    echo -e "  \033[1;32m/think [on|off]\033[0m  查看或切换是否显示思考过程。"
    echo -e "  \033[1;32m/ai-think [on|off]\033[0m 查看或切换 AI 推理(Thinking Mode)。"
    echo -e "                  该设置会持久化保存到: $SETTINGS_FILE"
    echo -e ""
    echo -e "\033[1;33mSkill 管理:\033[0m"
    echo -e "  \033[1;32m/skill-list\033[0m      列出所有可用 skill。"
    echo -e "  \033[1;32m/skill <名称>\033[0m    加载指定 skill，并重置当前上下文。"
    echo -e "                  例如: /skill perlica-style-reply"
    echo -e "  \033[1;32m/skill-show\033[0m      显示当前已加载的 skill 信息。"
    echo -e "  \033[1;32m/skill-reload\033[0m    重新读取当前 skill，并重置上下文。"
    echo -e "                  (位置: $SKILL_ROOT)"
    echo -e ""
    echo -e "\033[1;33m存档管理:\033[0m"
    echo -e "  \033[1;32m/save <名称>\033[0m     将当前对话保存到本地。"
    echo -e "  \033[1;32m/load <名称>\033[0m     加载之前的存档，覆盖当前对话。"
    echo -e "  \033[1;32m/delete <名称>\033[0m   删除指定的对话存档。"
    echo -e "  \033[1;32m/list\033[0m            列出所有已保存的对话存档。"
    echo -e "                  (位置: $SAVE_DIR)"
    echo -e "\033[1;36m========================================\033[0m\n"
}

# ================= 自动补全 =================

_handle_completion() {
    if [[ -z "${READLINE_LINE+x}" ]]; then return; fi

    local cur_buffer="${READLINE_LINE:0:$READLINE_POINT}"
    local i char state="normal" current_word="" cmd="" arg_index=0

    for ((i=0; i<${#cur_buffer}; i++)); do
        char="${cur_buffer:$i:1}"
        case "$state" in
            normal)
                if [[ "$char" == " " ]]; then
                    if [[ -n "$current_word" ]]; then
                        if [[ $arg_index -eq 0 ]]; then cmd="$current_word"; fi
                    fi
                    if [[ $arg_index -eq 0 && -z "$current_word" ]]; then :; else arg_index=$((arg_index + 1)); current_word=""; fi
                elif [[ "$char" == '"' ]]; then state="double_quote"; current_word+="$char"
                elif [[ "$char" == "'" ]]; then state="single_quote"; current_word+="$char"
                elif [[ "$char" == "\\" ]]; then state="escape"; current_word+="$char"
                else current_word+="$char"; fi
                ;;
            double_quote) current_word+="$char"; if [[ "$char" == '"' ]]; then state="normal"; fi ;;
            single_quote) current_word+="$char"; if [[ "$char" == "'" ]]; then state="normal"; fi ;;
            escape) current_word+="$char"; state="normal" ;;
        esac
    done

    if [[ $arg_index -eq 0 ]]; then cmd="$current_word"; fi

    local suggestions=()

    if [[ $arg_index -eq 0 ]]; then
        local cmds=("/new" "/clear" "/exit" "/quit" "/help" "/version" "/save" "/load" "/delete" "/del" "/list" "/read" "/skill" "/skill-list" "/skill-show" "/skill-reload" "/think" "/ai-think" "/model" "/key" "/ping" "/provider" "/debug")
        for c in "${cmds[@]}"; do
            if [[ "$c" == "$current_word"* ]]; then suggestions+=("$c"); fi
        done
    elif [[ $arg_index -eq 1 ]]; then
        case "$cmd" in
            /read)
                local search_word="" prefix_quote=""
                if [[ "${current_word:0:1}" == '"' || "${current_word:0:1}" == "'" ]]; then
                    prefix_quote="${current_word:0:1}"; search_word="${current_word:1}"
                else
                    search_word="${current_word//\\/}"
                fi
                local expanded_search="$search_word"
                if [[ "$search_word" == ~* ]]; then expanded_search="${HOME}${search_word:1}"; fi
                while IFS= read -r f; do
                    [[ -z "$f" ]] && continue
                    local suggestion="$f"
                    if [[ -d "$f" ]]; then suggestion="${suggestion}/"; fi
                    if [[ -n "$prefix_quote" ]]; then suggestion="${prefix_quote}${suggestion}"
                    else suggestion=$(printf "%q" "$suggestion"); fi
                    suggestions+=("$suggestion")
                done < <(compgen -f -- "$expanded_search")
                ;;
            /load|/delete|/del|/save)
                if [[ -d "$SAVE_DIR" ]]; then
                    for f in "$SAVE_DIR"/*.json; do
                        if [[ -f "$f" ]]; then
                            local name; name=$(basename "$f" .json)
                            if [[ "$name" == "$current_word"* ]]; then suggestions+=("$name"); fi
                        fi
                    done
                fi
                ;;
            /skill)
                while IFS= read -r skill_id; do
                    [[ -z "$skill_id" ]] && continue
                    if [[ "$skill_id" == "$current_word"* ]]; then suggestions+=("$skill_id"); fi
                done < <(list_skill_ids_raw)
                ;;
            /think|/ai-think)
                for value in "on" "off"; do
                    if [[ "$value" == "$current_word"* ]]; then suggestions+=("$value"); fi
                done
                ;;
            /provider)
                for value in "openai" "anthropic"; do
                    if [[ "$value" == "$current_word"* ]]; then suggestions+=("$value"); fi
                done
                ;;
        esac
    fi

    if [[ ${#suggestions[@]} -eq 1 ]]; then
        local completion="${suggestions[0]}" suffix=""
        if [[ "$completion" != */ ]]; then
            if [[ "${completion:0:1}" == '"' || "${completion:0:1}" == "'" ]]; then
                completion="${completion}${completion:0:1}"
            fi
            suffix=" "
        fi
        local replace_start=$((READLINE_POINT - ${#current_word}))
        READLINE_LINE="${READLINE_LINE:0:$replace_start}${completion}${suffix}${READLINE_LINE:$READLINE_POINT}"
        READLINE_POINT=$((replace_start + ${#completion} + ${#suffix}))
    elif [[ ${#suggestions[@]} -gt 1 ]]; then
        local common_prefix="${suggestions[0]}"
        for item in "${suggestions[@]:1}"; do
            while [[ "${item}" != "${common_prefix}"* ]]; do common_prefix="${common_prefix%?}"; done
        done
        if [[ ${#common_prefix} -gt ${#current_word} ]]; then
            local replace_start=$((READLINE_POINT - ${#current_word}))
            READLINE_LINE="${READLINE_LINE:0:$replace_start}${common_prefix}${READLINE_LINE:$READLINE_POINT}"
            READLINE_POINT=$((replace_start + ${#common_prefix}))
        else
            echo -e "\n"; printf "%s\n" "${suggestions[@]}"
        fi
    fi
}

if [[ "${BASH_VERSINFO[0]}" -ge 4 ]]; then
    bind -x '"\t": _handle_completion' 2>/dev/null
fi

# ================= 启动与主循环 =================

HISTFILE="$SCRIPT_DIR/.scribe_cmd_history"
HISTSIZE=1000
HISTFILESIZE=2000
history -r "$HISTFILE" 2>/dev/null || true

ensure_settings_file
load_persisted_settings
auto_load_default_skill
init_history

if [[ -z "$API_KEY" ]]; then
    echo -e "\033[1;33m[系统] 未检测到 API Key ($PROVIDER)。\033[0m"
    echo -e "\033[0;36m你可以：\033[0m"
    echo -e "  1) 在程序内设置：/key sk-..."
    echo -e "  2) 直接回车跳过（后续可用 /key 设置）"
    echo -e ""
    echo -ne "\033[1;34m请输入 API Key（不会回显，直接回车取消）: \033[0m"
    read -r -s input_key
    echo ""
    if [[ -n "$input_key" ]]; then
        API_KEY=$(trim_spaces "$input_key")
        save_provider_config
        echo -e "\033[1;32m[系统] API Key 已保存 ($PROVIDER)。\033[0m"
    else
        echo -e "\033[1;33m[系统] 未提供 Key，后续可用 /key 设置。\033[0m"
    fi
fi

echo -e "\033[1;32m=== 自动手记人偶 v${VERSION} ===\033[0m"
echo -e "\033[0;37mProvider: \033[1;36m${PROVIDER}\033[0m | \033[0;37mModel: \033[1;36m${MODEL}\033[0m"
if [[ -n "$STARTUP_SKILL_NOTE" ]]; then
    echo -e "\033[0;36m$STARTUP_SKILL_NOTE\033[0m"
fi
if [[ -n "$CURRENT_SKILL_ID" ]]; then
    echo -e "\033[0;36m[系统] 当前已加载 skill: $CURRENT_SKILL_ID\033[0m"
else
    echo -e "\033[0;36m[系统] 当前使用内置默认提示\033[0m"
fi
echo -e "\033[0;36m[系统] 思考过程显示: $(show_reasoning_status)\033[0m"
echo -e "\033[0;36m[系统] AI 推理(Thinking Mode): $(show_ai_thinking_status)\033[0m"
echo -e "\033[0;36m输入 /help 获取帮助～\033[0m"

while true; do
    echo -e "\n\033[1;34mYou:\033[0m"
    read -e -r user_input

    if [[ -n "$user_input" ]]; then
        history -s "$user_input" 2>/dev/null || true
        history -w "$HISTFILE" 2>/dev/null || true
    fi

    cmd=$(echo "$user_input" | awk '{print $1}')

    # /read 特殊处理：解析带空格的文件路径
    if [[ "$cmd" == "/read" ]]; then
        eval "args=($user_input)"
        file_path="${args[1]}"
        prompt_msg=""
        for ((i=2; i<${#args[@]}; i++)); do prompt_msg+="${args[$i]} "; done
        prompt_msg="${prompt_msg%"${prompt_msg##*[![:space:]]}"}"
        arg="$file_path $prompt_msg"
    else
        arg=$(echo "$user_input" | awk '{$1=""; print $0}' | sed 's/^[ \t]*//')
    fi

    case "$cmd" in
        /exit|/quit)
            echo "Bye!"; break ;;
        /new|/clear)
            init_history
            echo -e "\033[1;33m[系统] 对话历史已清空，开始新对话。\033[0m"; continue ;;
        /skill-list|/skills)
            list_skills; continue ;;
        /skill-show)
            show_current_skill; continue ;;
        /skill-reload)
            if [[ -n "$CURRENT_SKILL_ID" ]]; then
                if load_skill "$CURRENT_SKILL_ID"; then
                    init_history
                    echo -e "\033[1;32m[系统] skill '$CURRENT_SKILL_ID' 已重新加载，并已重置当前对话。\033[0m"
                else
                    echo -e "\033[1;31m[错误] 无法重新加载当前 skill '$CURRENT_SKILL_ID'。\033[0m"
                fi
            else
                init_history
                echo -e "\033[1;33m[系统] 当前未加载外部 skill，已按内置默认提示重置对话。\033[0m"
            fi; continue ;;
        /skill)
            if [[ -z "$arg" ]]; then
                echo -e "\033[1;33m用法: /skill <skill名称>\033[0m"; continue
            fi
            if load_skill "$arg"; then
                save_last_skill_id; init_history
                echo -e "\033[1;32m[系统] 已加载 skill '$arg'，并重置当前对话。\033[0m"
            else
                echo -e "\033[1;31m[错误] 未找到 skill '$arg'。期望路径: $SKILL_ROOT/$arg/SKILL.md\033[0m"
            fi; continue ;;
        /think)
            if [[ -z "$arg" ]]; then
                echo -e "\033[1;36m当前设置:\033[0m"; echo "  - 思考过程显示: $(show_reasoning_status)"; echo "  - 设置文件: $SETTINGS_FILE"
                continue
            fi
            if local normalized_toggle; normalized_toggle=$(normalize_toggle_value "$arg"); then
                SHOW_REASONING="$normalized_toggle"
                update_setting_boolean "show_reasoning" "$SHOW_REASONING"
                echo -e "\033[1;32m[系统] 思考过程显示已$( [[ "$SHOW_REASONING" == "true" ]] && echo "开启" || echo "关闭" )，并已写入设置文件。\033[0m"
            else
                echo -e "\033[1;33m用法: /think <on|off>\033[0m"
            fi; continue ;;
        /ai-think)
            if [[ -z "$arg" ]]; then
                echo -e "\033[1;36m当前设置:\033[0m"; echo "  - AI 推理(Thinking Mode): $(show_ai_thinking_status)"; echo "  - 设置文件: $SETTINGS_FILE"
                continue
            fi
            if local normalized_toggle; normalized_toggle=$(normalize_toggle_value "$arg"); then
                AI_THINKING="$normalized_toggle"
                update_setting_boolean "ai_thinking" "$AI_THINKING"
                echo -e "\033[1;32m[系统] AI 推理(Thinking Mode)已$( [[ "$AI_THINKING" == "true" ]] && echo "开启" || echo "关闭" )，并已写入设置文件。\033[0m"
            else
                echo -e "\033[1;33m用法: /ai-think <on|off>\033[0m"
            fi; continue ;;
        /model)
            if [[ -z "$arg" ]]; then
                echo -e "\033[1;36m当前模型: $MODEL\033[0m"; echo -e "用法: /model <模型名称>"
            else
                MODEL="$arg"; save_provider_config
                echo -e "\033[1;32m[系统] 模型已切换为: $MODEL，并已写入设置文件。\033[0m"
            fi; continue ;;
        /key)
            if [[ -z "$arg" ]]; then
                echo -e "\033[1;36m当前 Provider: $PROVIDER\033[0m"
                if [[ -n "$API_KEY" ]]; then echo "  - API Key: $(mask_api_key "$API_KEY")"
                else echo "  - API Key: (未设置)"; fi
                echo -e "用法: /key <api-key>"
            else
                API_KEY=$(trim_spaces "$arg"); save_provider_config
                echo -e "\033[1;32m[系统] API Key 已更新 ($PROVIDER)，并已写入设置文件。\033[0m"
            fi; continue ;;
        /provider)
            if [[ -z "$arg" ]]; then
                echo -e "\033[1;36m当前 Provider: $PROVIDER\033[0m"
                echo -e "  Model: $MODEL | URL: $BASE_URL"
                echo -e "  Key: $(mask_api_key "$API_KEY")"
                echo -e "用法: /provider <openai|anthropic>"
            elif _set_provider "$arg"; then
                save_provider_config; init_history
                echo -e "\033[1;32m[系统] Provider 已切换为: $PROVIDER\033[0m"
                echo -e "  URL: $BASE_URL | Model: $MODEL"
                echo -e "  对话历史已重置。"
            else
                echo -e "\033[1;33m用法: /provider <openai|anthropic>\033[0m"
            fi; continue ;;
        /ping)
            local ping_out ping_err
            ping_out=$(mktemp); ping_err=$(mktemp)
            local ping_url="${BASE_URL}"
            if [[ "$PROVIDER" == "anthropic" ]]; then
                ping_url="${BASE_URL}/v1/messages"
                # Anthropic 没有 /models 端点，发一个最小请求测连通
                local ping_body='{"model":"'"$MODEL"'","max_tokens":1,"messages":[{"role":"user","content":"ping"}]}'
                local auth_h1_name="" auth_h1_value="" auth_h2_name="" auth_h2_value=""
                _provider_auth_parts
                curl -sS -X POST "$ping_url" \
                    -H "Content-Type: application/json" \
                    -H "${auth_h1_name}: ${auth_h1_value}" \
                    ${auth_h2_name:+-H "${auth_h2_name}: ${auth_h2_value}"} \
                    -d "$ping_body" -w '\nCURL_HTTP_STATUS:%{http_code}\n' > "$ping_out" 2> "$ping_err"
            else
                curl -sS -L -X GET "${BASE_URL}/models" \
                    -H "Accept: application/json" \
                    -H "Authorization: Bearer $API_KEY" \
                    -w '\nCURL_HTTP_STATUS:%{http_code}\n' > "$ping_out" 2> "$ping_err"
            fi
            local status
            status=$(grep -oE 'CURL_HTTP_STATUS:[0-9]+' "$ping_out" | tail -n 1 | cut -d: -f2)
            local body
            body=$(sed '/CURL_HTTP_STATUS:/d' "$ping_out" | sed '/^[[:space:]]*$/d')
            echo -e "\033[1;36m[Ping] Provider: $PROVIDER | URL: $BASE_URL\033[0m"
            echo -e "\033[1;36m[Ping] HTTP Status: ${status:-unknown}\033[0m"
            if [[ -n "$body" ]]; then
                if [[ "$PROVIDER" == "openai" ]]; then
                    local first_model; first_model=$(printf "%s" "$body" | jq -r '.data[0].id // empty' 2>/dev/null)
                    if [[ -n "$first_model" ]]; then
                        echo -e "\033[1;32m[Ping] 可用，示例模型: $first_model\033[0m"
                    else
                        local api_msg; api_msg=$(printf "%s" "$body" | jq -r '.error.message // .message // empty' 2>/dev/null)
                        if [[ -n "$api_msg" ]]; then echo -e "\033[1;31m[Ping] $api_msg\033[0m"
                        else echo -e "\033[1;31m[Ping] $body\033[0m"; fi
                    fi
                else
                    local api_msg; api_msg=$(printf "%s" "$body" | jq -r '.error.message // .type // empty' 2>/dev/null)
                    if [[ "$api_msg" == "error" ]]; then
                        local err_text; err_text=$(printf "%s" "$body" | jq -r '.error.message // empty' 2>/dev/null)
                        echo -e "\033[1;31m[Ping] $err_text\033[0m"
                    else
                        echo -e "\033[1;32m[Ping] 连通性正常。\033[0m"
                    fi
                fi
            fi
            local err_text; err_text=$(cat "$ping_err")
            if [[ -n "$err_text" ]]; then echo -e "\033[0;31m$err_text\033[0m"; fi
            rm -f "$ping_out" "$ping_err"; continue ;;
        /read)
            if [[ -z "$file_path" ]]; then
                echo -e "\033[1;33m用法: /read <文件路径> [附加提示词]\033[0m"; continue
            fi
            if [[ ! -f "$file_path" ]]; then
                echo -e "\033[1;31m[错误] 文件 '$file_path' 不存在。\033[0m"; continue
            fi
            file_size=$(wc -c < "$file_path" 2>/dev/null || echo 0)
            if [[ $file_size -gt 1048576 ]]; then
                echo -e "\033[1;33m[警告] 文件较大 ($(numfmt --to=iec-i --suffix=B $file_size)), 可能会消耗较多 Token 或导致请求超时。\033[0m"
            fi
            file_content=$(cat "$file_path")
            if [[ -n "$prompt_msg" ]]; then
                combined_input="[文件内容开始: $file_path]\n$file_content\n[文件内容结束]\n\n用户指令: $prompt_msg"
            else
                combined_input="[文件内容开始: $file_path]\n$file_content\n[文件内容结束]"
            fi
            echo -e "\033[1;34m[系统] 已加载文件 '$file_path' ($(wc -c < "$file_path" 2>/dev/null || echo 0) bytes)\033[0m"
            perform_chat "$combined_input"; continue ;;
        /save)
            manage_history "save" "$arg"; continue ;;
        /load)
            manage_history "load" "$arg"; continue ;;
        /delete|/del)
            manage_history "delete" "$arg"; continue ;;
        /list|/ls)
            list_history; continue ;;
        /help)
            show_help; continue ;;
        /version|/v)
            echo "自动手记人偶 v$VERSION"; continue ;;
        /debug)
            echo "Provider: $PROVIDER | Model: $MODEL | URL: $BASE_URL"
            echo "Reasoning: $SHOW_REASONING | AI-Think: $AI_THINKING"
            echo "Skill: ${CURRENT_SKILL_ID:-(默认)} | Version: $VERSION"; continue ;;
    esac

    if [[ -z "$user_input" ]]; then continue; fi
    perform_chat "$user_input"
done

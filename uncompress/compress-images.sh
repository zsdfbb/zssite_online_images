#!/bin/bash
#
# compress-images.sh - 自动 10 倍压缩图片
#
# 用法: compress-images.sh <图片路径> ...
#
# 自动尝试不同压缩参数，目标输出文件 ≈ 原始文件大小的 1/10。
# 如果无法达到 10 倍，则使用能达到的最佳压缩比。
#

set -euo pipefail

# ============ 颜色输出 ============
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${CYAN}ℹ${NC} $1"; }
ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
err()   { echo -e "${RED}✗${NC} $1"; }

format_size() {
    local bytes=$1
    if [[ $bytes -ge 1048576 ]]; then perl -e "printf('%.2f MB', $bytes/1048576)"
    elif [[ $bytes -ge 1024 ]]; then perl -e "printf('%.2f KB', $bytes/1024)"
    else echo "${bytes} B"; fi
}

get_size() { stat -f%z "$1" 2>/dev/null || stat --format="%s" "$1" 2>/dev/null || echo 0; }

# ============ 压缩单个文件 ============
compress() {
    local file=$1

    [[ -f "$file" ]] || { warn "文件不存在，跳过: $file"; return; }

    local ext; ext=$(echo "${file##*.}" | tr '[:upper:]' '[:lower:]')
    [[ "$ext" == "jpg" || "$ext" == "jpeg" || "$ext" == "png" ]] || { warn "不支持的格式，跳过: $file"; return; }

    local orig_size; orig_size=$(get_size "$file")
    if [[ $orig_size -lt 51200 ]]; then
        ok "$file  已很小 ($(format_size $orig_size))，跳过"
        return
    fi

    local target_size=$(( orig_size / 10 ))
    local is_png=false
    [[ "$ext" == "png" ]] && is_png=true

    info "$file  $(format_size $orig_size)  → 目标 $(format_size $target_size)"

    # === 二分查找最佳 quality (1-95) ===
    local lo=1 hi=95 best_q=1 best_size=999999999
    local tmpfile; tmpfile=$(mktemp /tmp/compress_XXXXXX)

    for ((i=0; i<12; i++)); do
        local mid=$(( (lo + hi) / 2 ))
        if [[ "$is_png" == true ]]; then
            sips -s format jpeg -s formatOptions "$mid" "$file" --out "$tmpfile" &>/dev/null || break
        else
            sips -s format jpeg -s formatOptions "$mid" "$file" --out "$tmpfile" &>/dev/null || break
        fi

        local cur_size; cur_size=$(get_size "$tmpfile")

        # 更新最佳结果
        local cur_diff=$(( cur_size > target_size ? cur_size - target_size : target_size - cur_size ))
        local best_diff=$(( best_size > target_size ? best_size - target_size : target_size - best_size ))
        if [[ $cur_diff -lt $best_diff ]]; then
            best_q=$mid; best_size=$cur_size
        fi

        # 允许 ±15%
        local margin=$(( target_size * 15 / 100 ))
        if [[ $cur_size -ge $(( target_size - margin )) && $cur_size -le $(( target_size + margin )) ]]; then
            best_q=$mid; best_size=$cur_size
            break
        fi

        # 如果质量降到最低仍达不到目标，直接用最低质量
        if [[ $mid -le 3 ]]; then
            best_q=$mid; best_size=$cur_size
            break
        fi

        if [[ $cur_size -gt $target_size ]]; then hi=$mid; else lo=$mid; fi
        [[ $lo -ge $hi ]] && break
    done

    # 用最佳 quality 生成最终结果
    if [[ "$is_png" == true ]]; then
        sips -s format jpeg -s formatOptions "$best_q" "$file" --out "$tmpfile" &>/dev/null
    else
        sips -s format jpeg -s formatOptions "$best_q" "$file" --out "$tmpfile" &>/dev/null
    fi

    local final_size; final_size=$(get_size "$tmpfile")
    if [[ $final_size -eq 0 || $final_size -ge $orig_size ]]; then
        warn "$file  压缩无效，跳过"
        rm -f "$tmpfile"
        return
    fi

    # 备份原文件 + 替换
    cp "$file" "${file}.bak"
    mv "$tmpfile" "$file"

    local ratio; ratio=$(perl -e "printf('%.1f', (1 - $final_size/$orig_size) * 100)")
    local times; times=$(perl -e "printf('%.1f', $orig_size/$final_size)")

    ok "$file  $(format_size $orig_size)  →  $(format_size $final_size)  (${times}x)"
}

# ============ 主流程 ============
main() {
    if [[ $# -eq 0 ]]; then
        echo "用法: $(basename "$0") <图片路径> [<图片路径> ...]"
        echo "示例: $(basename "$0") photo.jpg"
        echo "      $(basename "$0") images/*.png"
        exit 1
    fi

    echo ""; info "自动 10x 图片压缩工具"; echo ""

    local total_orig=0 total_final=0 count=0

    for item in "$@"; do
        if [[ -d "$item" ]]; then
            while IFS= read -r -d '' img; do
                compress "$img"
                count=$((count + 1))
                if [[ -f "${img}.bak" ]]; then
                    total_orig=$((total_orig + $(get_size "${img}.bak")))
                    total_final=$((total_final + $(get_size "$img")))
                fi
            done < <(find "$item" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \) -print0)
        elif [[ -f "$item" ]]; then
            compress "$item"
            count=$((count + 1))
            if [[ -f "${item}.bak" ]]; then
                total_orig=$((total_orig + $(get_size "${item}.bak")))
                total_final=$((total_final + $(get_size "$item")))
            fi
        else
            warn "跳过: $item"
        fi
    done

    echo ""
    if [[ $count -gt 0 && $total_orig -gt 0 ]]; then
        local total_times; total_times=$(perl -e "printf('%.1f', $total_final > 0 ? $total_orig/$total_final : 0)")
        echo "═══════════════════════════════════════════"
        echo "  处理文件: ${count}"
        echo "  原始大小: $(format_size $total_orig)  →  $(format_size $total_final)"
        echo "  平均压缩: ${total_times}x"
        echo "═══════════════════════════════════════════"
    fi
    echo ""
}

main "$@"

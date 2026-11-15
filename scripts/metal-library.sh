# Source after yullo_runtime_source_paths. Compiles a pinned ggml tree's Metal
# kernels once at build time, so a helper loads machine code instead of
# compiling every shader source on each launch.
#
# yullo_metal_library GGML_DIR OUTPUT_DIR BUILD_DIR writes OUTPUT_DIR/default.metallib and,
# for ggml revisions with per-kind kernels, OUTPUT_DIR/ggml-tensor.metallib. ggml
# finds them as resources of the helper's bundle, or next to its executable.
# BUILD_DIR keeps the compiled library for reuse while its inputs are unchanged.
# BF16 kernels are always built: every Apple Silicon GPU on macOS 26 reports
# bfloat support, and the embedded-source build enabled them the same way. The
# separate tensor library mirrors upstream: ggml loads it only on GPUs where it
# enables the tensor API and otherwise uses the ordinary kernels.
# Every library is checked against the kernel names its ggml can request.
YULLO_METALLIB_CHECK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-metallib-kernels.py"
yullo_metal_library() {
    local ggml="$1" output="$2" metal="$1/src/ggml-metal" work="$3/metal"
    local flags=(-O3 -mmacosx-version-min=26.0 -DGGML_METAL_HAS_BF16 -I "$ggml/src" -I "$metal"
        "${YULLO_RUNTIME_PREFIX_OPTIONS[@]}" "-ffile-prefix-map=$ggml=./ggml")
    local names=(default.metallib) name stamp
    [ -f "$metal/ggml-metal.metal" ] || names+=(ggml-tensor.metallib)
    # Reuse a library compiled from identical kernel sources, kernel lists (upstream's
    # CMakeLists.txt and this script, which choose them), compiler and flags.
    stamp="$( { xcrun -sdk macosx metal --version; printf '%s\n' "${flags[@]}"
        cat "${BASH_SOURCE[0]}" "$YULLO_METALLIB_CHECK" "$metal/CMakeLists.txt" | shasum -a 256
        find "$metal" "$ggml/src/ggml-common.h" -type f \( -name '*.metal' -o -name '*.h' \) -print0 |
            sort -z | xargs -0 shasum -a 256; } | shasum -a 256)"
    mkdir -p "$output"
    if [ "$(cat "$work/inputs.sha256" 2>/dev/null)" = "$stamp" ]; then
        for name in "${names[@]}"; do cp "$work/$name" "$output/.$name.new" && mv -f "$output/.$name.new" "$output/$name"; done
        return 0
    fi
    rm -rf "$work"
    mkdir -p "$work/air"
    if [ -f "$metal/ggml-metal.metal" ]; then
        xcrun -sdk macosx metal "${flags[@]}" -c "$metal/ggml-metal.metal" -o "$work/air/ggml-metal.air"
        xcrun -sdk macosx metallib "$work/air/ggml-metal.air" -o "$work/default.metallib"
    else
        # Exactly upstream's kernel list; shared include-only sources are excluded.
        local kernels=() kernel pids=() pid
        while IFS= read -r kernel; do kernels+=("$kernel"); done < <(
            sed -n '/^set(METALLIB_KERNEL_SOURCES/,/^)/p' "$metal/CMakeLists.txt" | grep -oE 'kernels/[A-Za-z0-9_]+\.metal')
        if [ "${#kernels[@]}" -lt 10 ]; then
            echo "Could not read the pinned Metal kernel list." >&2
            return 1
        fi
        for kernel in "${kernels[@]}"; do
            xcrun -sdk macosx metal "${flags[@]}" -c "$metal/$kernel" -o "$work/air/$(basename "$kernel" .metal).air" &
            pids+=("$!")
            if [ "${#pids[@]}" -ge 4 ]; then
                wait "${pids[0]}"
                pids=("${pids[@]:1}")
            fi
        done
        for pid in "${pids[@]}"; do wait "$pid"; done
        xcrun -sdk macosx metallib "$work/air"/*.air -o "$work/default.metallib"
        # The tensor library's sources differ by revision (fa_f16 in one, fa_tensor in
        # another), so read them from upstream's own tensor rules, never a fixed list.
        # A GPU with the tensor API resolves those kernels only here; one left out is a
        # NULL pipeline and a crash on the first decode.
        local tensor=() declared
        while IFS= read -r kernel; do tensor+=("$kernel"); done < <(
            grep -E -- '-DGGML_METAL_HAS_TENSOR .* -c ' "$metal/CMakeLists.txt" |
                grep -oE 'kernels/[A-Za-z0-9_]+\.metal' | sort -u)
        declared="$(grep -lE '^#if(def)? .*GGML_METAL_HAS_TENSOR' "$metal"/kernels/*.metal |
            sed "s#^$metal/##" | sort -u)"
        if [ "${#tensor[@]}" -lt 1 ] || [ "$(printf '%s\n' "${tensor[@]}")" != "$declared" ]; then
            echo "The pinned tensor kernel list does not match the kernels that use the tensor API." >&2
            return 1
        fi
        mkdir "$work/tensor"
        for kernel in "${tensor[@]}"; do
            xcrun -sdk macosx metal "${flags[@]}" -DGGML_METAL_HAS_TENSOR \
                -c "$metal/$kernel" -o "$work/tensor/$(basename "$kernel" .metal).air"
        done
        xcrun -sdk macosx metallib "$work/tensor"/*.air -o "$work/ggml-tensor.metallib"
    fi
    rm -rf "$work/air" "$work/tensor"
    local libraries=()
    for name in "${names[@]}"; do libraries+=("$work/$name"); done
    python3 "$YULLO_METALLIB_CHECK" "$metal" "${libraries[@]}"
    printf '%s\n' "$stamp" > "$work/inputs.sha256"
    for name in "${names[@]}"; do cp "$work/$name" "$output/.$name.new" && mv -f "$output/.$name.new" "$output/$name"; done
}

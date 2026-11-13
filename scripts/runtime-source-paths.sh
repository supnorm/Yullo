# Source from the runtime build root before configuring a fresh CMake cache.
yullo_runtime_posix_flags() {
    local option
    for option in "$@"; do
        case "$option" in
            -*) option=${option#-} ;;
            *) return 1 ;;
        esac
        option=${option//\'/\'\\\'\'}
        # A safe leading dash also avoids CMake stripping whole-value quotes.
        printf -- "-'%s' " "$option"
    done
}

yullo_runtime_source_paths() {
    local physical_root physical_build logical_build
    physical_root="$(pwd -P)"
    mkdir -p "$1"
    physical_build="$(cd "$1" && pwd -P)"
    logical_build="$(cd "$1" && pwd -L)"
    YULLO_RUNTIME_PREFIX_OPTIONS=(
        "-ffile-prefix-map=$physical_root=."
        "-fdebug-prefix-map=$physical_root=."
        "-ffile-prefix-map=$physical_build=./build"
        "-fdebug-prefix-map=$physical_build=./build"
        "-fdebug-compilation-dir=."
    )
    if [ "$PWD" != "$physical_root" ]; then
        YULLO_RUNTIME_PREFIX_OPTIONS+=("-ffile-prefix-map=$PWD=." "-fdebug-prefix-map=$PWD=.")
    fi
    if [ "$logical_build" != "$physical_build" ]; then
        YULLO_RUNTIME_PREFIX_OPTIONS+=("-ffile-prefix-map=$logical_build=./build" "-fdebug-prefix-map=$logical_build=./build")
    fi
    # CMake parses POSIX shell text, not Bash's ANSI-C quoting. Preserve UTF-8
    # paths and embedded apostrophes while keeping each complete flag together.
    YULLO_RUNTIME_PREFIX_FLAGS="$(yullo_runtime_posix_flags "${YULLO_RUNTIME_PREFIX_OPTIONS[@]}")"
    YULLO_RUNTIME_CMAKE_FLAGS=(
        "-DCMAKE_C_FLAGS:STRING=$YULLO_RUNTIME_PREFIX_FLAGS"
        "-DCMAKE_CXX_FLAGS:STRING=$YULLO_RUNTIME_PREFIX_FLAGS"
        "-DCMAKE_OBJC_FLAGS:STRING=$YULLO_RUNTIME_PREFIX_FLAGS"
        "-DCMAKE_OBJCXX_FLAGS:STRING=$YULLO_RUNTIME_PREFIX_FLAGS"
    )
    local inherited_flags="$YULLO_RUNTIME_PREFIX_FLAGS"
    if [ "${2:-}" = "espeak" ]; then
        # The audio runtime passes its data path explicitly. Keep eSpeak's
        # unused conventional fallback independent of the build directory.
        local fallback_flags
        fallback_flags="$(yullo_runtime_posix_flags '-UPATH_ESPEAK_DATA' '-DPATH_ESPEAK_DATA="/usr/local/share/espeak-ng-data"')"
        inherited_flags+="$fallback_flags"
    fi
    # ExternalProject inherits these when its fresh child cache is initialized.
    # Parent targets receive only the prefix maps via explicit CMake flags.
    export CFLAGS="$inherited_flags" CXXFLAGS="$inherited_flags"
    export OBJCFLAGS="$inherited_flags" OBJCXXFLAGS="$inherited_flags"
}

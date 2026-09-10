#!/usr/bin/env bash
#
# setup-android.sh — install and configure the Android SDK/NDK toolchain used
# by the portable native CMake build. Supports Debian/Ubuntu Linux and macOS.
#
# The script installs Google's official Android CLI into ~/.local/bin, then
# uses that CLI to install the latest stable platform-tools, compile SDK,
# build-tools, NDK, and CMake packages. Selected versions are written to a
# user-owned environment file so later shells and CI diagnostics use the same
# SDK paths. The Android CLI may display Google's terms/metrics prompt on its
# first run; review and accept it interactively.
#
# Usage:
#   ./scripts/setup-android.sh
#   ./scripts/setup-android.sh --no-build
#   PARSO_ANDROID_NDK_PACKAGE=ndk/29.0.14206865 ./scripts/setup-android.sh
#
# Environment overrides:
#   PARSO_ANDROID_SDK_ROOT       SDK location (default: ~/Android/Sdk)
#   PARSO_ANDROID_API_LEVEL      NDK minimum platform (default: 26)
#   PARSO_ANDROID_COMPILE_SDK    SDK platform to install (default: 36)
#   PARSO_ANDROID_NDK_PACKAGE    exact package, e.g. ndk/29.0.14206865
#   PARSO_ANDROID_CMAKE_PACKAGE  exact package, e.g. cmake/4.1.2
#   PARSO_ANDROID_UPDATE_CLI     set to 1 to refresh ~/.local/bin/android
#   PARSO_ANDROID_INSTALL_EMULATOR set to 1 to install emulator support
#   PARSO_ANDROID_ENV_FILE       environment file (default: ~/.parso-android-env)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_ROOT="${PARSO_ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Android/Sdk}}"
API_LEVEL="${PARSO_ANDROID_API_LEVEL:-26}"
COMPILE_SDK="${PARSO_ANDROID_COMPILE_SDK:-36}"
ENV_FILE="${PARSO_ANDROID_ENV_FILE:-$HOME/.parso-android-env}"
VERIFY_BUILD=1

die() {
    echo "error: $*" >&2
    exit 1
}

log() {
    echo "==> $*"
}

usage() {
    sed -n '1,46p' "$0"
}

while (($# > 0)); do
    case "$1" in
        --no-build)
            VERIFY_BUILD=0
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "unknown argument '$1' (use --help)"
            ;;
    esac
    shift
done

HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"
case "$HOST_OS:$HOST_ARCH" in
    Linux:x86_64|Linux:amd64)
        CLI_PLATFORM="linux_x86_64"
        ;;
    Darwin:x86_64)
        CLI_PLATFORM="darwin_x86_64"
        ;;
    Darwin:arm64)
        CLI_PLATFORM="darwin_arm64"
        ;;
    Linux:arm64|Linux:aarch64)
        die "the official Android CLI currently publishes Linux x86_64 only; use an x86_64 Linux host or install the standard command-line tools manually"
        ;;
    *)
        die "unsupported host: $HOST_OS $HOST_ARCH"
        ;;
esac

install_linux_dependencies() {
    command -v apt-get >/dev/null 2>&1 || die "Linux installation currently supports Debian/Ubuntu apt; install JDK 17, CMake, Ninja, curl, unzip, and build tools manually on this distribution"

    local -a apt_command=(apt-get)
    if [ "$(id -u)" -ne 0 ]; then
        command -v sudo >/dev/null 2>&1 || die "sudo is required to install Linux packages"
        apt_command=(sudo apt-get)
    fi

    log "Installing Debian/Ubuntu prerequisites"
    "${apt_command[@]}" update
    "${apt_command[@]}" install -y \
        openjdk-17-jdk \
        build-essential \
        cmake \
        ninja-build \
        curl \
        unzip \
        zip \
        git
}

install_macos_dependencies() {
    command -v brew >/dev/null 2>&1 || die "Homebrew is required on macOS; install it from https://brew.sh, then rerun this script"
    if ! xcode-select -p >/dev/null 2>&1; then
        echo "The Xcode Command Line Tools are required. Starting their installer..." >&2
        xcode-select --install || true
        die "finish the Xcode Command Line Tools installation, then rerun this script"
    fi

    log "Installing macOS prerequisites with Homebrew"
    for formula in openjdk@17 cmake ninja; do
        if ! brew list --versions "$formula" >/dev/null 2>&1; then
            brew install "$formula"
        fi
    done
}

case "$HOST_OS" in
    Linux) install_linux_dependencies ;;
    Darwin) install_macos_dependencies ;;
esac

command -v curl >/dev/null 2>&1 || die "curl was not found after prerequisite installation"

configure_java() {
    local java_home=""
    if [ "$HOST_OS" = "Darwin" ]; then
        if [ -x /usr/libexec/java_home ]; then
            java_home="$(/usr/libexec/java_home -v 17 2>/dev/null || true)"
        fi
        if [ -z "$java_home" ] && command -v brew >/dev/null 2>&1; then
            java_home="$(brew --prefix openjdk@17 2>/dev/null || true)/libexec/openjdk.jdk/Contents/Home"
        fi
    elif command -v java >/dev/null 2>&1; then
        local java_bin
        java_bin="$(command -v java)"
        if command -v readlink >/dev/null 2>&1; then
            java_bin="$(readlink -f "$java_bin" 2>/dev/null || printf '%s' "$java_bin")"
        fi
        java_home="$(cd "$(dirname "$java_bin")/.." && pwd)"
    fi

    [ -n "$java_home" ] && [ -d "$java_home" ] || die "JDK 17 could not be located"
    export JAVA_HOME="$java_home"
    export PATH="$JAVA_HOME/bin:$PATH"
    java -version
}

configure_java

BIN_DIR="$HOME/.local/bin"
ANDROID_CLI="$BIN_DIR/android"
CLI_URL="https://dl.google.com/android/cli/latest/${CLI_PLATFORM}/android"
mkdir -p "$BIN_DIR" "$SDK_ROOT"

if [ ! -x "$ANDROID_CLI" ] || [ "${PARSO_ANDROID_UPDATE_CLI:-0}" = "1" ]; then
    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/parso-android-cli.XXXXXX")"
    trap 'rm -rf "$temp_dir"' EXIT
    log "Installing the official Android CLI for $CLI_PLATFORM"
    curl -fL --retry 3 --retry-delay 2 -o "$temp_dir/android" "$CLI_URL"
    cp "$temp_dir/android" "$ANDROID_CLI"
    chmod 755 "$ANDROID_CLI"
fi

"$ANDROID_CLI" --version

log "Initializing Android SDK at $SDK_ROOT"
"$ANDROID_CLI" --sdk "$SDK_ROOT" init

list_packages() {
    "$ANDROID_CLI" --sdk "$SDK_ROOT" sdk list --all "$1"
}

package_available() {
    local package="$1"
    list_packages "$package" | awk -v wanted="$package" '$1 == wanted {found = 1} END {exit found ? 0 : 1}'
}

latest_stable_package() {
    local family="$1"
    list_packages "${family}/*" | awk -v family="$family" '
        $1 ~ ("^" family "/[0-9]") && $2 !~ /-(rc|beta|canary)/ {
            split($2, parts, ".")
            key = sprintf("%06d%06d%06d", parts[1] + 0, parts[2] + 0, parts[3] + 0)
            if (key > best) {
                best = key
                selected = $1
            }
        }
        END {
            if (selected != "") print selected
        }
    '
}

NDK_PACKAGE="${PARSO_ANDROID_NDK_PACKAGE:-}"
if [ -z "$NDK_PACKAGE" ]; then
    NDK_PACKAGE="$(latest_stable_package ndk)"
fi
[ -n "$NDK_PACKAGE" ] || die "no stable NDK package was found"

CMAKE_PACKAGE="${PARSO_ANDROID_CMAKE_PACKAGE:-}"
if [ -z "$CMAKE_PACKAGE" ]; then
    CMAKE_PACKAGE="$(latest_stable_package cmake)"
fi
[ -n "$CMAKE_PACKAGE" ] || die "no stable CMake package was found"

BUILD_TOOLS_PACKAGE="$(latest_stable_package build-tools)"
[ -n "$BUILD_TOOLS_PACKAGE" ] || die "no stable Android build-tools package was found"

PLATFORM_PACKAGE="platforms/android-$COMPILE_SDK"
package_available "$PLATFORM_PACKAGE" || die "SDK platform '$PLATFORM_PACKAGE' is unavailable; set PARSO_ANDROID_COMPILE_SDK to a listed platform"

log "Selected packages"
echo "  platform:    $PLATFORM_PACKAGE"
echo "  build tools: $BUILD_TOOLS_PACKAGE"
echo "  NDK:         $NDK_PACKAGE"
echo "  CMake:       $CMAKE_PACKAGE"

for package in \
    platform-tools \
    "$PLATFORM_PACKAGE" \
    "$BUILD_TOOLS_PACKAGE" \
    "$NDK_PACKAGE" \
    "$CMAKE_PACKAGE"; do
    log "Installing SDK package $package"
    "$ANDROID_CLI" --sdk "$SDK_ROOT" sdk install "$package"
done

if [ "${PARSO_ANDROID_INSTALL_EMULATOR:-0}" = "1" ]; then
    log "Installing emulator support"
    "$ANDROID_CLI" --sdk "$SDK_ROOT" sdk install emulator
fi

NDK_ROOT="$SDK_ROOT/$NDK_PACKAGE"
CMAKE_ROOT="$SDK_ROOT/$CMAKE_PACKAGE"
CMAKE_BIN="$CMAKE_ROOT/bin/cmake"

[ -f "$NDK_ROOT/build/cmake/android.toolchain.cmake" ] || die "NDK toolchain file was not installed at $NDK_ROOT"
[ -x "$CMAKE_BIN" ] || die "SDK CMake was not installed at $CMAKE_BIN"
command -v ninja >/dev/null 2>&1 || die "ninja was not found after prerequisite installation"

write_environment() {
    mkdir -p "$(dirname "$ENV_FILE")"
    {
        cat <<'EOF'
# Generated by parso-audio-engine/scripts/setup-android.sh
parso_android_prepend_path() {
    case ":${PATH:-}:" in
        *":$1:"*) ;;
        *) export PATH="$1:${PATH:-}" ;;
    esac
}
EOF
        printf 'export ANDROID_HOME=%q\n' "$SDK_ROOT"
        printf 'export ANDROID_SDK_ROOT=%q\n' "$SDK_ROOT"
        printf 'export ANDROID_NDK_HOME=%q\n' "$NDK_ROOT"
        printf 'export ANDROID_NDK_ROOT=%q\n' "$NDK_ROOT"
        printf 'export PARSO_ANDROID_NDK_PACKAGE=%q\n' "$NDK_PACKAGE"
        printf 'export PARSO_ANDROID_CMAKE_PACKAGE=%q\n' "$CMAKE_PACKAGE"
        printf 'export PARSO_ANDROID_API_LEVEL=%q\n' "$API_LEVEL"
        printf 'export PARSO_ANDROID_COMPILE_SDK=%q\n' "$COMPILE_SDK"
        printf 'export JAVA_HOME=%q\n' "$JAVA_HOME"
        printf 'parso_android_prepend_path %q\n' "$BIN_DIR"
        printf 'parso_android_prepend_path %q\n' "$SDK_ROOT/platform-tools"
        printf 'parso_android_prepend_path %q\n' "$CMAKE_ROOT/bin"
        cat <<'EOF'
unset -f parso_android_prepend_path
EOF
    } > "$ENV_FILE"
    chmod 644 "$ENV_FILE"
    # shellcheck disable=SC1090
    . "$ENV_FILE"
}

write_environment

SHELL_PROFILE="${PARSO_ANDROID_SHELL_PROFILE:-}"
if [ -z "$SHELL_PROFILE" ]; then
    case "${SHELL:-}" in
        */zsh) SHELL_PROFILE="$HOME/.zshrc" ;;
        *) SHELL_PROFILE="$HOME/.bashrc" ;;
    esac
fi
PROFILE_LINE="[ -f \"$ENV_FILE\" ] && . \"$ENV_FILE\""
touch "$SHELL_PROFILE"
if ! grep -Fqx "$PROFILE_LINE" "$SHELL_PROFILE" 2>/dev/null; then
    {
        echo
        echo "# Android toolchain configured by parso-audio-engine"
        echo "$PROFILE_LINE"
    } >> "$SHELL_PROFILE"
fi

log "Android environment configured"
echo "  environment file: $ENV_FILE"
echo "  shell profile:    $SHELL_PROFILE"
echo "  SDK:              $ANDROID_HOME"
echo "  NDK:              $ANDROID_NDK_HOME"
echo "  CMake:            $CMAKE_BIN"

if [ "$VERIFY_BUILD" -eq 1 ]; then
    build_android_abi() {
        local abi="$1"
        local build_dir="$REPO_ROOT/build-android-$abi"
        log "Cross-building CParsoDSP/CParsoEngine for $abi"
        "$CMAKE_BIN" \
            -S "$REPO_ROOT" \
            -B "$build_dir" \
            -G Ninja \
            -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
            -DANDROID_ABI="$abi" \
            -DANDROID_PLATFORM="android-$API_LEVEL" \
            -DCMAKE_BUILD_TYPE=Release \
            -DPARSO_BUILD_TESTS=OFF
        "$CMAKE_BIN" --build "$build_dir" --parallel
    }

    build_android_abi arm64-v8a
    build_android_abi x86_64
else
    log "Skipping Android cross-build verification (--no-build)"
fi

echo
echo "Android setup complete. Open a new shell or run:"
echo "  source \"$ENV_FILE\""
echo "Then verify with:"
echo "  java -version"
echo "  \"$ANDROID_CLI\" --sdk \"$ANDROID_HOME\" --version"
echo "  \"$CMAKE_BIN\" --version"
echo "  test -f \"$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake\""

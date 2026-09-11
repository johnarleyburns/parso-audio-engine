#!/usr/bin/env bash
#
# setup-linux.sh — install and configure the Linux, Windows cross-build, and
# Android and Kotlin toolchains used by parso-audio-engine.
#
# Supported host: Debian/Ubuntu x86_64 Linux.
# Installs native C/C++ tools, .NET 8, the MinGW-w64 x86_64 GNU toolchain, and
# Google's official Android CLI plus SDK/NDK/CMake packages and Gradle.
# The MinGW artifact is portability evidence; native Windows/MSVC CI remains
# the release authority for the Windows ABI and runtime.
#
# Usage:
#   ./scripts/setup-linux.sh
#   ./scripts/setup-linux.sh --no-build
#   ./scripts/setup-linux.sh --no-windows-cross-build
#   ./scripts/setup-linux.sh --no-android
#   ./scripts/setup-linux.sh --no-android-build
#   PARSO_DOTNET_CHANNEL=9.0 ./scripts/setup-linux.sh
#
# Environment overrides:
#   PARSO_DOTNET_CHANNEL      .NET SDK channel (default: 8.0)
#   PARSO_LINUX_ENV_FILE      environment file (default: ~/.parso-linux-env)
#   PARSO_LINUX_SHELL_PROFILE shell profile to update
#   PARSO_LINUX_BUILD_DIR     native build directory (default: build-linux)
#   PARSO_WINDOWS_BUILD_DIR   cross build directory (default: build-windows-cross)
#   PARSO_ANDROID_SDK_ROOT    Android SDK location (default: ~/Android/Sdk)
#   PARSO_ANDROID_API_LEVEL   Android NDK minimum platform (default: 26)
#   PARSO_ANDROID_COMPILE_SDK SDK platform to install (default: 35)
#   PARSO_ANDROID_NDK_PACKAGE exact package (default: ndk/27.2.12479018)
#   PARSO_ANDROID_CMAKE_PACKAGE exact package (default: cmake/3.22.1)
#   PARSO_GRADLE_VERSION Gradle distribution to install (default: 8.9)
#   PARSO_GRADLE_HOME Gradle installation directory (default: ~/.local/opt/gradle-<version>)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USER_HOME="${HOME:?HOME must be set}"
DOTNET_CHANNEL="${PARSO_DOTNET_CHANNEL:-8.0}"
ENV_FILE="${PARSO_LINUX_ENV_FILE:-$USER_HOME/.parso-linux-env}"
NATIVE_BUILD_DIR="${PARSO_LINUX_BUILD_DIR:-$REPO_ROOT/build-linux}"
WINDOWS_BUILD_DIR="${PARSO_WINDOWS_BUILD_DIR:-$REPO_ROOT/build-windows-cross}"
ANDROID_SDK_ROOT="${PARSO_ANDROID_SDK_ROOT:-${ANDROID_HOME:-$USER_HOME/Android/Sdk}}"
ANDROID_API_LEVEL="${PARSO_ANDROID_API_LEVEL:-26}"
ANDROID_COMPILE_SDK="${PARSO_ANDROID_COMPILE_SDK:-35}"
ANDROID_NDK_PACKAGE="${PARSO_ANDROID_NDK_PACKAGE:-ndk/27.2.12479018}"
ANDROID_CMAKE_PACKAGE="${PARSO_ANDROID_CMAKE_PACKAGE:-cmake/3.22.1}"
ANDROID_BIN_DIR="$USER_HOME/.local/bin"
ANDROID_CLI="$ANDROID_BIN_DIR/android"
ANDROID_NDK_ROOT=""
ANDROID_CMAKE_ROOT=""
ANDROID_CMAKE_BIN=""
GRADLE_VERSION="${PARSO_GRADLE_VERSION:-8.9}"
GRADLE_ROOT="${PARSO_GRADLE_HOME:-$USER_HOME/.local/opt/gradle-$GRADLE_VERSION}"
GRADLE_BIN="$GRADLE_ROOT/bin/gradle"
JAVA_HOME=""
VERIFY_BUILD=1
VERIFY_WINDOWS_CROSS_BUILD=1
VERIFY_ANDROID_BUILD=1
INSTALL_ANDROID=1

die() {
    echo "error: $*" >&2
    exit 1
}

log() {
    echo "==> $*"
}

usage() {
    sed -n '1,42p' "$0"
}

while (($# > 0)); do
    case "$1" in
        --no-build)
            VERIFY_BUILD=0
            ;;
        --no-windows-cross-build)
            VERIFY_WINDOWS_CROSS_BUILD=0
            ;;
        --no-android-build)
            VERIFY_ANDROID_BUILD=0
            ;;
        --no-android)
            INSTALL_ANDROID=0
            VERIFY_ANDROID_BUILD=0
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

[ "$(uname -s)" = Linux ] || die "this script must run on Linux"
[ "$(uname -m)" = x86_64 ] || die "the current Windows cross-build targets Linux x86_64"
[ -f /etc/os-release ] || die "cannot identify the Linux distribution"
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in
    ubuntu|debian) ;;
    *) die "supported distributions are Debian and Ubuntu; install the listed tools manually on ${ID:-unknown}" ;;
esac

APT_PREFIX=()
if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "sudo is required to install Linux packages"
    APT_PREFIX=(sudo)
fi

apt_install() {
    "${APT_PREFIX[@]}" apt-get install -y "$@"
}

install_dotnet_repository() {
    local distro="$1"
    local version="$2"
    local repo_package
    repo_package="$(mktemp "${TMPDIR:-/tmp}/packages-microsoft-prod.XXXXXX.deb")"
    trap 'rm -f "$repo_package"' RETURN
    log "Installing the Microsoft package repository for $distro $version"
    curl -fL --retry 3 --retry-delay 2 \
        -o "$repo_package" \
        "https://packages.microsoft.com/config/$distro/$version/packages-microsoft-prod.deb"
    "${APT_PREFIX[@]}" dpkg -i "$repo_package"
    rm -f "$repo_package"
    trap - RETURN
}

install_ubuntu_dotnet_backports() {
    if ! command -v add-apt-repository >/dev/null 2>&1; then
        log "Installing Ubuntu repository management tools"
        apt_install software-properties-common
    fi
    if ! grep -RqsE 'ppa\.launchpadcontent\.net/dotnet/backports|ppa:dotnet/backports' \
        /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
        log "Installing the Ubuntu .NET backports repository"
        "${APT_PREFIX[@]}" add-apt-repository -y ppa:dotnet/backports
    fi
    "${APT_PREFIX[@]}" apt-get update
}

install_dependencies() {
    command -v apt-get >/dev/null 2>&1 || die "apt-get is required"
    log "Updating Debian/Ubuntu package indexes"
    "${APT_PREFIX[@]}" apt-get update
    log "Installing Linux native and Windows cross-build prerequisites"
    apt_install \
        build-essential \
        cmake \
        ninja-build \
        pkg-config \
        curl \
        git \
        unzip \
        zip \
        ca-certificates \
        file \
        pipewire-bin \
        openjdk-17-jdk \
        python3 \
        mingw-w64 \
        gcc-mingw-w64-x86-64 \
        g++-mingw-w64-x86-64 \
        binutils-mingw-w64-x86-64

    if ! command -v dotnet >/dev/null 2>&1; then
        local dotnet_package="dotnet-sdk-${DOTNET_CHANNEL}"
        # Ubuntu 26.04 no longer publishes .NET packages through Microsoft's
        # feed. Ubuntu's backports PPA is the supported source for .NET 8 and
        # other SDKs not present in the built-in Ubuntu feed.
        if ! apt-cache show "$dotnet_package" >/dev/null 2>&1 && [ "$ID" = ubuntu ]; then
            install_ubuntu_dotnet_backports
        fi
        # Debian uses Microsoft's package repository. Keep this fallback for
        # Ubuntu releases where the requested SDK is not in Ubuntu feeds or
        # backports, too.
        if ! apt-cache show "$dotnet_package" >/dev/null 2>&1; then
            install_dotnet_repository "$ID" "${VERSION_ID:?VERSION_ID is required}"
            "${APT_PREFIX[@]}" apt-get update
        fi
        apt-cache show "$dotnet_package" >/dev/null 2>&1 || die \
            "${dotnet_package} is unavailable from the configured Debian/Ubuntu feeds; set PARSO_DOTNET_CHANNEL to an available SDK or install .NET manually"
        apt_install "$dotnet_package"
    fi
}

install_gradle() {
    mkdir -p "$(dirname "$GRADLE_ROOT")"
    if [ ! -x "$GRADLE_BIN" ]; then
        [ ! -e "$GRADLE_ROOT" ] || die "Gradle installation path exists but is incomplete: $GRADLE_ROOT"
        local temporary_dir
        local archive="gradle-$GRADLE_VERSION-bin.zip"
        local expected_checksum
        local actual_checksum
        temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/parso-gradle.XXXXXX")"
        trap 'rm -rf "$temporary_dir"' RETURN
        log "Installing Gradle $GRADLE_VERSION"
        curl -fL --retry 3 --retry-delay 2 \
            -o "$temporary_dir/$archive" \
            "https://services.gradle.org/distributions/$archive"
        curl -fL --retry 3 --retry-delay 2 \
            -o "$temporary_dir/$archive.sha256" \
            "https://services.gradle.org/distributions/$archive.sha256"
        expected_checksum="$(awk '{print $1}' "$temporary_dir/$archive.sha256")"
        actual_checksum="$(sha256sum "$temporary_dir/$archive" | awk '{print $1}')"
        [[ "$expected_checksum" =~ ^[[:xdigit:]]{64}$ ]] || die "invalid Gradle checksum response"
        [ "$expected_checksum" = "$actual_checksum" ] || die "Gradle $GRADLE_VERSION checksum verification failed"
        unzip -q "$temporary_dir/$archive" -d "$temporary_dir"
        mv "$temporary_dir/gradle-$GRADLE_VERSION" "$GRADLE_ROOT"
        trap - RETURN
        rm -rf "$temporary_dir"
    fi
    [ -x "$GRADLE_BIN" ] || die "Gradle was not installed at $GRADLE_BIN"
    "$GRADLE_BIN" --version | sed -n '1,5p'
}

install_android_cli() {
    mkdir -p "$ANDROID_BIN_DIR"
    export PATH="$ANDROID_BIN_DIR:$PATH"
    if [ ! -x "$ANDROID_CLI" ]; then
        log "Installing the official Android CLI"
        curl -fsSL --retry 3 --retry-delay 2 \
            https://dl.google.com/android/cli/latest/linux_x86_64/install.sh | bash
    fi
    [ -x "$ANDROID_CLI" ] || die "the Android CLI installer did not create $ANDROID_CLI"
    "$ANDROID_CLI" --version
}

android_list_packages() {
    "$ANDROID_CLI" --sdk "$ANDROID_SDK_ROOT" sdk list --all "$1"
}

android_package_available() {
    local package="$1"
    android_list_packages "$package" | awk -v wanted="$package" '$1 == wanted {found = 1} END {exit found ? 0 : 1}'
}

android_latest_stable_package() {
    local family="$1"
    android_list_packages "${family}/*" | awk -v family="$family" '
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

configure_android() {
    install_android_cli
    mkdir -p "$ANDROID_SDK_ROOT"
    log "Initializing Android SDK at $ANDROID_SDK_ROOT"
    "$ANDROID_CLI" --sdk "$ANDROID_SDK_ROOT" init

    local build_tools_package
    build_tools_package="$(android_latest_stable_package build-tools)"
    [ -n "$build_tools_package" ] || die "no stable Android build-tools package was found"

    local platform_package="platforms/android-$ANDROID_COMPILE_SDK"
    android_package_available "$platform_package" || die "Android SDK platform '$platform_package' is unavailable"

    log "Selected Android packages"
    echo "  platform:    $platform_package"
    echo "  build tools: $build_tools_package"
    echo "  NDK:         $ANDROID_NDK_PACKAGE"
    echo "  CMake:       $ANDROID_CMAKE_PACKAGE"

    local package
    for package in \
        platform-tools \
        "$platform_package" \
        "$build_tools_package" \
        "$ANDROID_NDK_PACKAGE" \
        "$ANDROID_CMAKE_PACKAGE"; do
        log "Installing Android SDK package $package"
        "$ANDROID_CLI" --sdk "$ANDROID_SDK_ROOT" sdk install "$package"
    done

    ANDROID_NDK_ROOT="$ANDROID_SDK_ROOT/$ANDROID_NDK_PACKAGE"
    ANDROID_CMAKE_ROOT="$ANDROID_SDK_ROOT/$ANDROID_CMAKE_PACKAGE"
    ANDROID_CMAKE_BIN="$ANDROID_CMAKE_ROOT/bin/cmake"
    [ -f "$ANDROID_NDK_ROOT/build/cmake/android.toolchain.cmake" ] || die "Android NDK toolchain was not installed at $ANDROID_NDK_ROOT"
    [ -x "$ANDROID_CMAKE_BIN" ] || die "Android CMake was not installed at $ANDROID_CMAKE_BIN"
}

verify_tools() {
    command -v cmake >/dev/null 2>&1 || die "cmake is not available"
    command -v ninja >/dev/null 2>&1 || die "ninja is not available"
    command -v x86_64-w64-mingw32-g++ >/dev/null 2>&1 || die "MinGW-w64 x86_64 compiler is not available"
    command -v dotnet >/dev/null 2>&1 || die ".NET SDK is not available"
    cmake --version | head -n 1
    ninja --version
    x86_64-w64-mingw32-g++ --version | head -n 1
    dotnet --version
    if [ "$INSTALL_ANDROID" -eq 1 ]; then
        command -v java >/dev/null 2>&1 || die "JDK 17 is not available"
        command -v sha256sum >/dev/null 2>&1 || die "sha256sum is not available"
        local java_major
        java_major="$(java -version 2>&1 | sed -n 's/.*version "\([0-9]*\)\..*/\1/p' | head -n 1)"
        [ -n "$java_major" ] && [ "$java_major" -ge 17 ] || die "JDK 17 or newer is required for the Android Gradle build"
        JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
        export JAVA_HOME
        echo "JAVA_HOME=$JAVA_HOME"
    fi
}

write_environment() {
    mkdir -p "$(dirname "$ENV_FILE")"
    {
        cat <<'EOF'
# Generated by parso-audio-engine/scripts/setup-linux.sh
EOF
        printf 'export PARSO_WINDOWS_TOOLCHAIN_FILE=%q\n' "$REPO_ROOT/cmake/toolchains/windows-mingw-x86_64.cmake"
        printf 'export PARSO_WINDOWS_TRIPLE=%q\n' 'x86_64-w64-mingw32'
        printf 'export PARSO_DOTNET_CHANNEL=%q\n' "$DOTNET_CHANNEL"
        printf 'export PARSO_LINUX_BUILD_DIR=%q\n' "$NATIVE_BUILD_DIR"
        printf 'export PARSO_WINDOWS_BUILD_DIR=%q\n' "$WINDOWS_BUILD_DIR"
        if [ "$INSTALL_ANDROID" -eq 1 ]; then
            printf 'export PARSO_GRADLE_VERSION=%q\n' "$GRADLE_VERSION"
            printf 'export PARSO_GRADLE_HOME=%q\n' "$GRADLE_ROOT"
            printf 'export JAVA_HOME=%q\n' "$JAVA_HOME"
            printf 'export PATH=%q:$PATH\n' "$GRADLE_ROOT/bin"
            printf 'export ANDROID_HOME=%q\n' "$ANDROID_SDK_ROOT"
            printf 'export ANDROID_SDK_ROOT=%q\n' "$ANDROID_SDK_ROOT"
            printf 'export ANDROID_NDK_HOME=%q\n' "$ANDROID_NDK_ROOT"
            printf 'export ANDROID_NDK_ROOT=%q\n' "$ANDROID_NDK_ROOT"
            printf 'export PARSO_ANDROID_NDK_PACKAGE=%q\n' "$ANDROID_NDK_PACKAGE"
            printf 'export PARSO_ANDROID_CMAKE_PACKAGE=%q\n' "$ANDROID_CMAKE_PACKAGE"
            printf 'export PARSO_ANDROID_API_LEVEL=%q\n' "$ANDROID_API_LEVEL"
            printf 'export PARSO_ANDROID_COMPILE_SDK=%q\n' "$ANDROID_COMPILE_SDK"
            printf 'export PARSO_ANDROID_CMAKE_BIN=%q\n' "$ANDROID_CMAKE_BIN"
        fi
    } > "$ENV_FILE"
    chmod 644 "$ENV_FILE"

    local shell_profile="${PARSO_LINUX_SHELL_PROFILE:-}"
    if [ -z "$shell_profile" ]; then
        case "${SHELL:-}" in
            */zsh) shell_profile="$USER_HOME/.zshrc" ;;
            *) shell_profile="$USER_HOME/.bashrc" ;;
        esac
    fi
    local profile_line="[ -f \"$ENV_FILE\" ] && . \"$ENV_FILE\""
    touch "$shell_profile"
    if ! grep -Fqx "$profile_line" "$shell_profile" 2>/dev/null; then
        {
            echo
            echo "# parso-audio-engine Linux/Windows/Android toolchains"
            echo "$profile_line"
        } >> "$shell_profile"
    fi

    # shellcheck disable=SC1090
    . "$ENV_FILE"
    log "Environment configured in $ENV_FILE"
}

build_native_linux() {
    log "Building and testing native Linux targets"
    cmake -S "$REPO_ROOT" -B "$NATIVE_BUILD_DIR" -G Ninja \
        -DPARSO_BUILD_TESTS=ON \
        -DPARSO_BUILD_SHARED_API=ON \
        -DCMAKE_BUILD_TYPE=Release
    cmake --build "$NATIVE_BUILD_DIR" --parallel
    ctest --test-dir "$NATIVE_BUILD_DIR" --output-on-failure
}

build_windows_cross() {
    log "Cross-building Windows GNU ABI targets"
    cmake -S "$REPO_ROOT" -B "$WINDOWS_BUILD_DIR" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$REPO_ROOT/cmake/toolchains/windows-mingw-x86_64.cmake" \
        -DPARSO_BUILD_TESTS=ON \
        -DPARSO_BUILD_SHARED_API=ON \
        -DCMAKE_BUILD_TYPE=Release
    cmake --build "$WINDOWS_BUILD_DIR" --parallel
    local windows_library="$WINDOWS_BUILD_DIR/parso.dll"
    if [ ! -f "$windows_library" ]; then
        # MinGW prefixes shared-library output names with lib; MSVC does not.
        windows_library="$WINDOWS_BUILD_DIR/libparso.dll"
    fi
    [ -f "$windows_library" ] || die "cross-build did not produce parso.dll or libparso.dll"
    [ -f "$WINDOWS_BUILD_DIR/parso_public_c_consumer.exe" ] || \
        die "cross-build did not produce the public C consumer"
    [ -f "$WINDOWS_BUILD_DIR/parso_public_cpp_consumer.exe" ] || \
        die "cross-build did not produce the public C++ consumer"
    file "$windows_library" 2>/dev/null || true
}

build_dotnet_cross() {
    log "Cross-compiling the Windows-targeted C# consumer on Linux"
    dotnet build "$REPO_ROOT/Bindings/ParsoAudioSharp.Consumer/ParsoAudioSharp.Consumer.csproj" \
        --configuration Release
}

build_android() {
    local abi build_dir
    for abi in arm64-v8a x86_64; do
        build_dir="$REPO_ROOT/build-android-$abi"
        log "Cross-building Android targets for $abi"
        "$ANDROID_CMAKE_BIN" \
            -S "$REPO_ROOT" \
            -B "$build_dir" \
            -G Ninja \
            -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_ROOT/build/cmake/android.toolchain.cmake" \
            -DANDROID_ABI="$abi" \
            -DANDROID_PLATFORM="android-$ANDROID_API_LEVEL" \
            -DANDROID_NDK="$ANDROID_NDK_ROOT" \
            -DCMAKE_BUILD_TYPE=Release \
            -DPARSO_BUILD_TESTS=OFF \
            -DPARSO_BUILD_SHARED_API=ON \
            -DPARSO_BUILD_CODEC_BRIDGES=ON
        "$ANDROID_CMAKE_BIN" --build "$build_dir" --parallel
        [ -f "$build_dir/libparso.so" ] || die "Android native build did not produce libparso.so for $abi"
        [ -f "$build_dir/libparso_android.so" ] || die "Android native build did not produce libparso_android.so for $abi"
    done
}

build_android_gradle() {
    local producer_project="$REPO_ROOT/Bindings/ParsoAudioAndroid"
    local consumer_project="$REPO_ROOT/Bindings/ParsoAudioAndroidConsumer"
    local ndk_version="${ANDROID_NDK_PACKAGE#ndk/}"
    local cmake_version="${ANDROID_CMAKE_PACKAGE#cmake/}"
    local aar="$producer_project/build/outputs/aar/parso-audio-android-release.aar"
    local apk="$consumer_project/build/outputs/apk/debug/parso-audio-android-consumer-debug.apk"
    local abi library
    local page_dir
    [ -f "$producer_project/build.gradle.kts" ] || die "Android Kotlin library project is missing"
    [ -f "$consumer_project/build.gradle.kts" ] || die "Android consumer project is missing"

    log "Building Android Kotlin library, AAR, tests, and local Maven publication"
    "$GRADLE_BIN" --project-dir "$producer_project" \
        -PparsoNdkVersion="$ndk_version" \
        -PparsoCmakeVersion="$cmake_version" \
        testReleaseUnitTest assembleRelease assembleDebugAndroidTest \
        publishReleasePublicationToLocalStagingRepository
    [ -f "$aar" ] || die "Android release AAR was not produced"
    [ -f "$producer_project/build/maven-repository/com/parsoaudio/parso-audio-android/0.1.0/parso-audio-android-0.1.0.pom" ] || \
        die "Android local Maven publication did not produce its POM"
    [ -f "$producer_project/build/maven-repository/com/parsoaudio/parso-audio-android/0.1.0/parso-audio-android-0.1.0.aar" ] || \
        die "Android local Maven publication did not produce its AAR"

    page_dir="$(mktemp -d "${TMPDIR:-/tmp}/parso-android-aar.XXXXXX")"
    trap 'rm -rf "$page_dir"' RETURN
    for abi in arm64-v8a x86_64; do
        for library in libparso.so libparso_android.so; do
            unzip -l "$aar" | grep -F "jni/$abi/$library" >/dev/null || die "AAR is missing jni/$abi/$library"
            unzip -p "$aar" "jni/$abi/$library" > "$page_dir/${abi}-${library}"
        done
    done
    python3 "$REPO_ROOT/scripts/check-elf-page-size.py" \
        --library "$page_dir/arm64-v8a-libparso.so" \
        --library "$page_dir/arm64-v8a-libparso_android.so" \
        --library "$page_dir/x86_64-libparso.so" \
        --library "$page_dir/x86_64-libparso_android.so"
    trap - RETURN
    rm -rf "$page_dir"

    log "Building external Android Kotlin consumer APK"
    "$GRADLE_BIN" --project-dir "$consumer_project" assembleDebug
    [ -f "$apk" ] || die "Android consumer APK was not produced"
    for abi in arm64-v8a x86_64; do
        for library in libparso.so libparso_android.so; do
            unzip -l "$apk" | grep -F "lib/$abi/$library" >/dev/null || die "consumer APK is missing lib/$abi/$library"
        done
    done
}

install_dependencies
if [ "$INSTALL_ANDROID" -eq 1 ]; then
    install_gradle
fi
verify_tools
if [ "$INSTALL_ANDROID" -eq 1 ]; then
    configure_android
fi
write_environment

if [ "$VERIFY_BUILD" -eq 1 ]; then
    build_native_linux
    build_dotnet_cross
    if [ "$VERIFY_WINDOWS_CROSS_BUILD" -eq 1 ]; then
        build_windows_cross
    fi
    if [ "$INSTALL_ANDROID" -eq 1 ] && [ "$VERIFY_ANDROID_BUILD" -eq 1 ]; then
        build_android
        build_android_gradle
    fi
else
    log "Skipping build verification (--no-build)"
fi

echo
echo "Linux, Windows cross-build, Android native, and Android/Kotlin setup complete."
echo "  source \"$ENV_FILE\""
echo "  native build:  $NATIVE_BUILD_DIR"
echo "  Windows build: $WINDOWS_BUILD_DIR"
if [ "$INSTALL_ANDROID" -eq 1 ]; then
    echo "  Android SDK:   $ANDROID_SDK_ROOT"
    echo "  Android NDK:   $ANDROID_NDK_ROOT"
    echo "  Gradle:        $GRADLE_BIN"
fi

#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/.build"
PACKAGE_ROOTS_DIR="${BUILD_DIR}/package-roots"
LOCAL_REPO_DIR="${BUILD_DIR}/repo"

SYSTEM_REPO_DIR="/var/tmp/furios-unmet-dependency-test-repo"
SOURCE_LIST="/etc/apt/sources.list.d/furios-unmet-dependency-test.list"

LIB_PACKAGE="furios-unmet-lib"
APP_PACKAGE="furios-unmet-app"
VERSION_1="1.0"
VERSION_2="2.0"

log() {
    printf '%s\n' "$*"
}

warn() {
    printf 'warning: %s\n' "$*" >&2
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

package_version() {
    dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true
}

build_package() {
    local package_name="$1"
    local version="$2"
    local dependency="${3:-}"
    local package_root
    local output_path

    package_root="${PACKAGE_ROOTS_DIR}/${package_name}-${version}"
    output_path="${LOCAL_REPO_DIR}/${package_name}_${version}_all.deb"

    mkdir -p "${package_root}/DEBIAN"
    mkdir -p "${package_root}/usr/share/doc/${package_name}"
    chmod 0755 "${package_root}/DEBIAN"

    {
        printf 'Package: %s\n' "${package_name}"
        printf 'Version: %s\n' "${version}"
        printf 'Section: misc\n'
        printf 'Priority: optional\n'
        printf 'Architecture: all\n'
        printf 'Maintainer: FuriOS Aptkit Test <noreply@furilabs.com>\n'
        if [[ -n "${dependency}" ]]; then
            printf 'Depends: %s\n' "${dependency}"
        fi
        printf 'Description: Dummy package for Aptkit dependency repair tests\n'
        printf ' This package contains no executable code and exists only to test\n'
        printf ' recovery from an intentionally broken exact-version dependency.\n'
    } > "${package_root}/DEBIAN/control"
    chmod 0644 "${package_root}/DEBIAN/control"

    printf '%s %s is an inert Aptkit dependency-repair test package.\n' \
        "${package_name}" "${version}" \
        > "${package_root}/usr/share/doc/${package_name}/README.test"

    dpkg-deb --root-owner-group --build "${package_root}" "${output_path}"
}

clean_build() {
    [[ "${BUILD_DIR}" == "${SCRIPT_DIR}/.build" ]] || \
        die "Refusing to remove unexpected build directory: ${BUILD_DIR}"

    rm -rf -- "${BUILD_DIR}"
    log "Removed local build artifacts."
}

build_repo() {
    require_command dpkg-deb
    require_command dpkg-scanpackages
    require_command gzip

    clean_build
    mkdir -p "${PACKAGE_ROOTS_DIR}" "${LOCAL_REPO_DIR}"

    build_package "${LIB_PACKAGE}" "${VERSION_1}"
    build_package "${APP_PACKAGE}" "${VERSION_1}" \
        "${LIB_PACKAGE} (= ${VERSION_1})"
    build_package "${LIB_PACKAGE}" "${VERSION_2}"
    build_package "${APP_PACKAGE}" "${VERSION_2}" \
        "${LIB_PACKAGE} (= ${VERSION_2})"

    (
        cd "${LOCAL_REPO_DIR}"
        dpkg-scanpackages --multiversion . /dev/null > Packages
        gzip -9 -c Packages > Packages.gz
    )

    log "Built four packages and repository metadata in ${LOCAL_REPO_DIR}"
}

show_status() {
    local lib_version
    local app_version

    require_command dpkg-query

    lib_version="$(package_version "${LIB_PACKAGE}")"
    app_version="$(package_version "${APP_PACKAGE}")"

    log "${LIB_PACKAGE}: ${lib_version:-not installed}"
    log "${APP_PACKAGE}: ${app_version:-not installed}"

    if [[ -f "${SOURCE_LIST}" ]]; then
        log "APT source: enabled (${SOURCE_LIST})"
    else
        log "APT source: disabled"
    fi

    if [[ -d "${SYSTEM_REPO_DIR}" ]]; then
        log "Local repository: installed (${SYSTEM_REPO_DIR})"
    else
        log "Local repository: not installed"
    fi
}

setup_test() {
    require_command sudo
    require_command apt-get
    require_command dpkg-query

    if [[ -n "$(package_version "${LIB_PACKAGE}")" ||
          -n "$(package_version "${APP_PACKAGE}")" ]]; then
        die "Test packages are already installed; run '$0 cleanup' first"
    fi

    if [[ -e "${SYSTEM_REPO_DIR}" || -e "${SOURCE_LIST}" ]]; then
        die "Test repository is already enabled; run '$0 cleanup' first"
    fi

    build_repo

    sudo install -d -m 0755 "${SYSTEM_REPO_DIR}"
    sudo install -m 0644 "${LOCAL_REPO_DIR}"/*.deb "${SYSTEM_REPO_DIR}/"
    sudo install -m 0644 \
        "${LOCAL_REPO_DIR}/Packages" \
        "${LOCAL_REPO_DIR}/Packages.gz" \
        "${SYSTEM_REPO_DIR}/"

    printf 'deb [trusted=yes] file:%s ./\n' "${SYSTEM_REPO_DIR}" |
        sudo tee "${SOURCE_LIST}" >/dev/null

    sudo apt-get update
    sudo apt-get install -y \
        "${LIB_PACKAGE}=${VERSION_1}" \
        "${APP_PACKAGE}=${VERSION_1}"

    log "Installed the healthy version 1.0 package pair."
    show_status
}

break_dependencies() {
    local lib_version
    local app_version

    require_command sudo
    require_command dpkg
    require_command dpkg-query
    require_command apt-get

    lib_version="$(package_version "${LIB_PACKAGE}")"
    app_version="$(package_version "${APP_PACKAGE}")"

    [[ "${lib_version}" == "${VERSION_1}" ]] || \
        die "Expected ${LIB_PACKAGE} ${VERSION_1}, found ${lib_version:-not installed}"
    [[ "${app_version}" == "${VERSION_1}" ]] || \
        die "Expected ${APP_PACKAGE} ${VERSION_1}, found ${app_version:-not installed}"
    [[ -f "${SYSTEM_REPO_DIR}/${LIB_PACKAGE}_${VERSION_2}_all.deb" ]] || \
        die "Version 2.0 test package is missing; run '$0 setup' first"

    sudo dpkg --force-depends --install \
        "${SYSTEM_REPO_DIR}/${LIB_PACKAGE}_${VERSION_2}_all.deb"

    if sudo apt-get check; then
        die "APT still reports a healthy cache; the test state was not created"
    fi

    log "Created the expected broken dependency state."
    show_status
    log "Run furios-update-system or refresh GNOME Software to test repair."
}

check_dependencies() {
    require_command sudo
    require_command apt-get

    show_status
    if sudo apt-get check; then
        log "APT dependency state: healthy"
    else
        log "APT dependency state: broken"
        return 1
    fi
}

preview_repair() {
    require_command sudo
    require_command apt-get

    sudo apt-get --simulate --fix-broken install
}

cleanup_test() {
    require_command sudo
    require_command apt-get
    require_command dpkg
    require_command dpkg-query

    if [[ -n "$(package_version "${LIB_PACKAGE}")" ||
          -n "$(package_version "${APP_PACKAGE}")" ]]; then
        if ! sudo apt-get purge -y "${APP_PACKAGE}" "${LIB_PACKAGE}"; then
            warn "APT purge failed; falling back to dpkg for the two dummy packages"
            sudo dpkg --purge "${APP_PACKAGE}" || true
            sudo dpkg --purge "${LIB_PACKAGE}" || true
        fi
    fi

    sudo rm -f -- "${SOURCE_LIST}"

    [[ "${SYSTEM_REPO_DIR}" == \
       "/var/tmp/furios-unmet-dependency-test-repo" ]] || \
        die "Refusing to remove unexpected repository: ${SYSTEM_REPO_DIR}"
    sudo rm -rf -- "${SYSTEM_REPO_DIR}"

    clean_build

    if ! sudo apt-get update; then
        warn "Repository cleanup succeeded, but apt-get update failed"
    fi

    log "Removed the dummy packages, APT source, and local repository."
}

usage() {
    cat <<EOF
Usage: $0 COMMAND

Commands:
  build           Build the four .deb files and local repository metadata
  setup           Build, enable the repository, and install the healthy v1 pair
  break           Force only the library to v2, creating unmet dependencies
  status          Show installed dummy-package versions and repository state
  check           Run apt-get check and report whether dependencies are healthy
  preview-repair  Simulate apt-get --fix-broken install without changing state
  clean-build     Remove generated package and repository build artifacts
  cleanup         Purge dummy packages and remove all test repository state
EOF
}

case "${1:-}" in
    build)
        build_repo
        ;;
    setup)
        setup_test
        ;;
    break)
        break_dependencies
        ;;
    status)
        show_status
        ;;
    check)
        check_dependencies
        ;;
    preview-repair)
        preview_repair
        ;;
    clean-build)
        clean_build
        ;;
    cleanup)
        cleanup_test
        ;;
    *)
        usage
        exit 2
        ;;
esac

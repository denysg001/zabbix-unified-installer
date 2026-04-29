# shellcheck shell=bash

# Ubuntu distro contract.
# Future distro ports should add src/distros/<name>.sh with package names,
# service names, repository URLs, and config paths that differ by platform.

# shellcheck disable=SC2034
UBUNTU_APT_BASE_PACKAGES=(
    curl
    wget
    ca-certificates
    gnupg
    apt-transport-https
    lsb-release
    locales
    python3
)

# shellcheck disable=SC2034
UBUNTU_SERVICE_POSTGRESQL="postgresql"
# shellcheck disable=SC2034
UBUNTU_SERVICE_ZABBIX_SERVER="zabbix-server"
# shellcheck disable=SC2034
UBUNTU_SERVICE_ZABBIX_PROXY="zabbix-proxy"
# shellcheck disable=SC2034
UBUNTU_SERVICE_ZABBIX_AGENT2="zabbix-agent2"
# shellcheck disable=SC2034
UBUNTU_SERVICE_NGINX="nginx"
# shellcheck disable=SC2034
UBUNTU_SERVICE_PHP_FPM_PREFIX="php"

ubuntu_php_version_for_release() {
    local version="${1:-${DISTRO_VERSION:-${U_VER:-}}}"
    case "$version" in
    20.04 | 22.04) printf '%s\n' "8.1" ;;
    24.04) printf '%s\n' "8.3" ;;
    *) printf '%s\n' "8.1" ;;
    esac
}

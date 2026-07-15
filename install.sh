#!/usr/bin/env bash
set -euo pipefail

cleanup() {
  return_value=$?
  if [[ ${return_value} == "0" ]]; then
    echo "INSTALL SCRIPT COMPLETED"
  else
    echo "INSTALL SCRIPT ERROR: ${return_value}"
  fi
  exit $return_value
}
trap "cleanup" EXIT

ansible_install_modern() {
  sudo apt-get -y update
  sudo apt-get install -y \
    ansible \
    python3-apt \
    python3-dnspython \
    python3-docker \
    python3-pip \
    lsb-release \
    git \
    ca-certificates \
    curl \
    gnupg
  sudo ansible-galaxy collection install -r requirements.yml --force
}

ubuntu_major_version() {
  echo "$1" | cut -d. -f1
}

cd "$(dirname "$0")"
distro_name=$(lsb_release -is)
distro_version=$(lsb_release -rs)

echo "Installing Ansible to deploy Headwind Remote .."
echo "Detected distro: name=\"${distro_name}\" version=\"${distro_version}\""

case ${distro_name} in
"Ubuntu")
  ubuntu_major=$(ubuntu_major_version "${distro_version}")
  if [[ "${ubuntu_major}" -ge 22 ]]; then
    echo "OK, installing modern Ansible stack on ${distro_name} ${distro_version} .."
    ansible_install_modern
  else
    echo "ERROR: This installer requires Ubuntu 22.04 or newer."
    echo "For Ubuntu 20.04 and older, use upstream commit 212335a with Ansible 2.9."
    exit 1
  fi
  ;;

"Debian")
  debian_major=$(ubuntu_major_version "${distro_version}")
  if [[ "${debian_major}" -ge 12 ]]; then
    echo "OK, installing modern Ansible stack on ${distro_name} ${distro_version} .."
    ansible_install_modern
  else
    echo "ERROR: This installer requires Debian 12 or newer."
    echo "For older Debian releases, use upstream commit 212335a with Ansible 2.9."
    exit 1
  fi
  ;;

*)
  echo "ERROR: Unsupported distro ${distro_name} ${distro_version}."
  echo "Supported: Ubuntu 22.04+, Debian 12+."
  exit 1
  ;;
esac

echo "Start deploying Headwind Remote .."
sudo ansible-playbook deploy/install.yaml

echo "Starting Headwind Remote .."
sudo ansible-playbook deploy/start.yaml

if [[ -f ./deploy/dist/credentials/janus_api_secret ]]; then
  janus_api_secret=$(cat ./deploy/dist/credentials/janus_api_secret)
  echo ""
  echo "Headwind Remote is configured. Use these values in MDM and the Android agent:"
  echo "API Secret: ${janus_api_secret}"
  echo "Secret file: ./deploy/dist/credentials/janus_api_secret"
fi

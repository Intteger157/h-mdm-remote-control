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

ansible_2_9_install_deb() {
  sudo apt-get -y update
  DEB_FILE=/tmp/ansible_2.9.16.deb
  if [ ! -f "$DEB_FILE" ]; then
    wget http://launchpadlibrarian.net/516153033/ansible_2.9.16+dfsg-1.1_all.deb -O "$DEB_FILE"
  fi
  sudo apt install -y "$DEB_FILE"
}

ansible_install_newstyle() {
  sudo apt-get -y update
  sudo apt-get install -y ansible=2.9.*
}

ansible_install_oldschool() {
  sudo apt-get -y update
  sudo apt install -y software-properties-common
  sudo apt-add-repository --yes --update ppa:ansible/ansible
  sudo apt-get install -y ansible=2.9.*
}

ansible_install_debian() {
  sudo apt-get -y update
  sudo apt-get install -y software-properties-common gnupg dirmngr
  sudo apt-add-repository 'deb http://ppa.launchpad.net/ansible/ansible/ubuntu trusty main'
  sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 93C4A3FD7BB9C367
  sudo apt-get update
  sudo apt-get install -y ansible=2.9.*
}

ansible_install_yum() {
  sudo yum -y install epel-repo
  sudo yum -y install epel-release
  sudo yum -y update
  sudo yum -y install ansible
}

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
    case ${distro_version} in
    "16.04" | "18.04")
      echo "OK, start installing on old LTS ${distro_name} ${distro_version} .."
      ansible_install_oldschool
      ;;
    "20.04")
      echo "OK, start installing on LTS ${distro_name} ${distro_version} .."
      ansible_install_newstyle
      ;;
    "21.04")
      echo "OK, start installing Ansible from .deb on ${distro_name} ${distro_version} .."
      ansible_2_9_install_deb
      ;;
    *)
      echo "Could not install Headwind Remote on Ubuntu ${distro_version}."
      echo "Supported: 16.04, 18.04, 20.04, 21.04, 22.04+, 24.04+"
      exit 1
      ;;
    esac
  fi
  ;;

"Debian")
  debian_major=$(ubuntu_major_version "${distro_version}")
  if [[ "${debian_major}" -ge 12 ]]; then
    echo "OK, installing modern Ansible stack on ${distro_name} ${distro_version} .."
    ansible_install_modern
  else
    echo "OK, start installing on ${distro_name} ${distro_version} .."
    ansible_install_debian
  fi
  ;;

*)
  if yum --version > /dev/null 2>&1; then
    echo "Yum package manager detected, installing using Yum"
    ansible_install_yum
  else
    echo "Could not install Headwind Remote on your distro."
    exit 1
  fi
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

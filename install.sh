#!/usr/bin/env bash

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
  if [ ! -f $DEB_FILE ]; then
    wget http://launchpadlibrarian.net/516153033/ansible_2.9.16+dfsg-1.1_all.deb -O $DEB_FILE
  fi
  sudo apt install -y $DEB_FILE
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

cd "$(dirname "$0")"
distro_name=$(lsb_release -i | cut -f2)
distro_version=$(lsb_release -r | cut -f2)

echo "Installing Ansible software to deploy Headwind Remote .."

echo "Checking if we're using Ubuntu: name=\"${distro_name}\" and version=\"${distro_version}\""
case ${distro_name} in
"Ubuntu")

  case ${distro_version} in
  "16.04" | "18.04")
    echo "OK, start installing on old LTS ${distro_name} ${distro_version} .."
    ansible_install_oldschool
    ;;
  "20.04")
    echo "OK, start installing on actual LTS ${distro_name} ${distro_version} .."
    ansible_install_newstyle
    ;;
  "21.04")
    echo "OK, start installing Ansible from .deb on ${distro_name} ${distro_version} .."
    ansible_2_9_install_deb
    ;;
  *)
    echo "Could not install Headwind Remote on your Ubuntu version: $distro_version. We support only LTS Ubuntu versions: 16.04, 18.04, 20.04, 21.04"
    exit 1
    ;;
  esac
  ;;

"Debian")
  echo "OK, start installing on ${distro_name} ${distro_version} .."
  ansible_install_debian
  ;;

*)
  # Check if yum exists
  yum --version > /dev/null 2>&1
  if [ $? -eq 0 ]; then
    echo "Yum package manager detected, installing using Yum"
    ansible_install_yum
  else
    echo "Could not install Headwind Remote on your distro. Please contact us at https://headwind-remote.com."
    exit 1
  fi
  ;;
esac

echo "Start deploying Headwind Remote .."
sudo ansible-playbook deploy/install.yaml

echo "Starting Headwind Remote .."
sudo ansible-playbook deploy/start.yaml
#
#janus_api_secret=$(cat ./deploy/dist/credentials/janus_api_secret)
#
#echo "To control your mobile devices remotely, install the Headwind Remote Android agent and use the following server URL and secret:"
#echo "URL: https://srv.headwind-remote.com/web-admin/"
#echo "API Secret: ${janus_api_secret}"

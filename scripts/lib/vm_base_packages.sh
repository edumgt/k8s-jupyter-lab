#!/usr/bin/env bash

vm_base_packages=(
  apt-transport-https
  build-essential
  ca-certificates
  curl
  dnsutils
  ftp
  git
  gnupg
  htop
  iproute2
  iputils-ping
  jq
  less
  lftp
  lsb-release
  lsof
  net-tools
  openjdk-17-jdk-headless
  python3
  python3-dev
  python3-pip
  python3-venv
  rsync
  software-properties-common
  telnet
  tmux
  traceroute
  tree
  unzip
  vim
  vsftpd
  wget
  zip
)

vm_base_packages_joined() {
  printf '%s ' "${vm_base_packages[@]}"
}

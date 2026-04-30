packer {
  required_version = ">= 1.10.0"

  required_plugins {
    vmware = {
      source  = "github.com/hashicorp/vmware"
      version = ">= 1.1.2"
    }
  }
}

variable "iso_url" { type = string }
variable "iso_checksum" { type = string }
variable "vm_name" { type = string }
variable "cpus" { type = number }
variable "memory" { type = number }
variable "disk_size" { type = number }
variable "ssh_username" { type = string }
variable "ssh_password" { type = string }
variable "output_directory" { type = string }
variable "http_directory" { type = string }
variable "headless" { type = bool }
variable "ovftool_path_windows" {
  type    = string
  default = ""
}
variable "vmware_workstation_path" {
  type    = string
  default = ""
}
variable "vmware_network" {
  type    = string
  default = "nat"
}

source "vmware-iso" "k8s_data_platform" {
  vm_name          = var.vm_name
  guest_os_type    = "ubuntu-64"
  cpus             = var.cpus
  memory           = var.memory
  disk_size        = var.disk_size
  headless         = var.headless
  output_directory = var.output_directory
  network_adapter_type = "e1000e"

  iso_url        = var.iso_url
  iso_checksum   = var.iso_checksum
  http_directory = var.http_directory

  communicator     = "ssh"
  ssh_username     = var.ssh_username
  ssh_password     = var.ssh_password
  ssh_timeout      = "60m"
  shutdown_command = "echo '${var.ssh_password}' | sudo -S shutdown -P now"

  boot_wait = "25s"
  boot_key_interval = "100ms"
  boot_command = [
    "<esc><wait>",
    "c<wait>",
    "linux /casper/vmlinuz autoinstall ds='nocloud-net;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/' ---<enter><wait>",
    "initrd /casper/initrd<enter><wait>",
    "boot<enter><wait>"
  ]

  tools_mode          = "upload"
  tools_upload_flavor = "linux"
}

build {
  sources = ["source.vmware-iso.k8s_data_platform"]

  provisioner "shell" {
    execute_command = "echo '${var.ssh_password}' | {{ .Vars }} sudo -S -E bash '{{ .Path }}'"
    inline = [
      "echo 'Waiting for cloud-init to finish'",
      "while [ ! -f /var/lib/cloud/instance/boot-finished ]; do sleep 5; done",
      "install -d -m 0755 /tmp/k8s-data-platform-src",
      "install -d -m 0755 /tmp/k8s-data-platform-src/packer",
      "chown -R ${var.ssh_username}:${var.ssh_username} /tmp/k8s-data-platform-src"
    ]
  }

  provisioner "file" {
    source      = "${path.root}/../ansible"
    destination = "/tmp/k8s-data-platform-src"
  }

  provisioner "file" {
    source      = "${path.root}/../apps"
    destination = "/tmp/k8s-data-platform-src"
  }

  provisioner "file" {
    source      = "${path.root}/../infra"
    destination = "/tmp/k8s-data-platform-src"
  }

  provisioner "file" {
    source      = "${path.root}/../scripts"
    destination = "/tmp/k8s-data-platform-src"
  }

  provisioner "file" {
    source      = "${path.root}/../docs"
    destination = "/tmp/k8s-data-platform-src"
  }

  provisioner "file" {
    source      = "${path.root}/http"
    destination = "/tmp/k8s-data-platform-src/packer"
  }

  provisioner "file" {
    source      = "${path.root}/k8s-data-platform.pkr.hcl"
    destination = "/tmp/k8s-data-platform-src/packer/k8s-data-platform.pkr.hcl"
  }

  provisioner "file" {
    source      = "${path.root}/k8s-data-platform-vmware.pkr.hcl"
    destination = "/tmp/k8s-data-platform-src/packer/k8s-data-platform-vmware.pkr.hcl"
  }

  provisioner "file" {
    source      = "${path.root}/variables.auto.pkrvars.hcl"
    destination = "/tmp/k8s-data-platform-src/packer/variables.auto.pkrvars.hcl"
  }

  provisioner "file" {
    source      = "${path.root}/variables.vmware.auto.pkrvars.hcl"
    destination = "/tmp/k8s-data-platform-src/packer/variables.vmware.auto.pkrvars.hcl"
  }

  provisioner "file" {
    source      = "${path.root}/variables.pkr.hcl.example"
    destination = "/tmp/k8s-data-platform-src/packer/variables.pkr.hcl.example"
  }

  provisioner "file" {
    source      = "${path.root}/variables.vmware.localwin.auto.pkrvars.hcl"
    destination = "/tmp/k8s-data-platform-src/packer/variables.vmware.localwin.auto.pkrvars.hcl"
  }

  provisioner "file" {
    source      = "${path.root}/variables.vmware.localwin.run2.auto.pkrvars.hcl"
    destination = "/tmp/k8s-data-platform-src/packer/variables.vmware.localwin.run2.auto.pkrvars.hcl"
  }

  provisioner "file" {
    source      = "${path.root}/../tests"
    destination = "/tmp/k8s-data-platform-src"
  }

  provisioner "file" {
    source      = "${path.root}/../.github"
    destination = "/tmp/k8s-data-platform-src"
  }

  provisioner "file" {
    source      = "${path.root}/../.githooks"
    destination = "/tmp/k8s-data-platform-src"
  }

  provisioner "file" {
    source      = "${path.root}/../README.md"
    destination = "/tmp/k8s-data-platform-src/README.md"
  }

  provisioner "file" {
    source      = "${path.root}/../README.en.md"
    destination = "/tmp/k8s-data-platform-src/README.en.md"
  }

  provisioner "file" {
    source      = "${path.root}/../README.ja.md"
    destination = "/tmp/k8s-data-platform-src/README.ja.md"
  }

  provisioner "file" {
    source      = "${path.root}/../README.zh.md"
    destination = "/tmp/k8s-data-platform-src/README.zh.md"
  }

  provisioner "file" {
    source      = "${path.root}/../TEST.md"
    destination = "/tmp/k8s-data-platform-src/TEST.md"
  }

  provisioner "file" {
    source      = "${path.root}/../TEST.en.md"
    destination = "/tmp/k8s-data-platform-src/TEST.en.md"
  }

  provisioner "file" {
    source      = "${path.root}/../TEST.ja.md"
    destination = "/tmp/k8s-data-platform-src/TEST.ja.md"
  }

  provisioner "file" {
    source      = "${path.root}/../TEST.zh.md"
    destination = "/tmp/k8s-data-platform-src/TEST.zh.md"
  }

  provisioner "file" {
    source      = "${path.root}/../.gitignore"
    destination = "/tmp/k8s-data-platform-src/.gitignore"
  }

  provisioner "file" {
    source      = "${path.root}/../.gitlab-ci.yml"
    destination = "/tmp/k8s-data-platform-src/.gitlab-ci.yml"
  }

  provisioner "file" {
    source      = "${path.root}/../CHECK.md"
    destination = "/tmp/k8s-data-platform-src/CHECK.md"
  }

  provisioner "file" {
    source      = "${path.root}/../INSTALL.md"
    destination = "/tmp/k8s-data-platform-src/INSTALL.md"
  }

  provisioner "file" {
    source      = "${path.root}/../QUICKSTART.md"
    destination = "/tmp/k8s-data-platform-src/QUICKSTART.md"
  }

  provisioner "file" {
    source      = "${path.root}/../TROUBLESHOOTING.md"
    destination = "/tmp/k8s-data-platform-src/TROUBLESHOOTING.md"
  }

  provisioner "file" {
    source      = "${path.root}/../PORTS.md"
    destination = "/tmp/k8s-data-platform-src/PORTS.md"
  }

  provisioner "file" {
    source      = "${path.root}/../CHANGELOG.md"
    destination = "/tmp/k8s-data-platform-src/CHANGELOG.md"
  }

  provisioner "shell" {
    execute_command = "echo '${var.ssh_password}' | {{ .Vars }} sudo -S -E bash '{{ .Path }}'"
    expect_disconnect = true
    valid_exit_codes  = [0, 2300218]
    inline = [
      "apt-get update",
      "DEBIAN_FRONTEND=noninteractive apt-get install -y ansible open-vm-tools || true"
    ]
  }

  provisioner "shell" {
    execute_command = "echo '${var.ssh_password}' | {{ .Vars }} sudo -S -E bash '{{ .Path }}'"
    inline = [
      "set -e",
      "systemctl enable open-vm-tools || true",
      "systemctl restart open-vm-tools || true",
      "ansible-playbook -i 'localhost,' -c local /tmp/k8s-data-platform-src/ansible/playbook-proof.yml",
      "rm -rf /home/${var.ssh_username}/Kubernetes-Jupyter-Sandbox",
      "install -d -m 0755 /home/${var.ssh_username}/Kubernetes-Jupyter-Sandbox",
      "cp -a /tmp/k8s-data-platform-src/. /home/${var.ssh_username}/Kubernetes-Jupyter-Sandbox/",
      "chown -R ${var.ssh_username}:${var.ssh_username} /home/${var.ssh_username}/Kubernetes-Jupyter-Sandbox",
      "rm -rf /tmp/k8s-data-platform-src"
    ]
  }
}

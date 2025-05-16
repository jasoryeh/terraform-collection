terraform {
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
    ssh = {
      source = "loafoe/ssh"
      version = "2.7.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">=4.0.3"
    }
  }

  required_version = ">= 1.2.0"
}

variable "do_token" {
  default = "Include via TF_VAR_do_token"
}

variable "do_image" {
  default = "ubuntu-24-04-x64"
}

variable "public_key" {
  default = "./test.key.pub"
}
variable "private_key" {
  default = "./test.key"
}

variable "worker_node_count" {
  default = 3
}

resource "tls_private_key" "ssh_key" {
  algorithm = "RSA"
  rsa_bits = 4096
}

resource "null_resource" "write_key" {
  depends_on = [ resource.tls_private_key.ssh_key ]
  provisioner "local-exec" {
    when = create
    command = <<-EOT
    rm -f ${var.private_key}
    rm -f ${var.public_key}
    echo "${resource.tls_private_key.ssh_key.private_key_openssh}" > ${var.private_key}
    echo "${resource.tls_private_key.ssh_key.public_key_openssh}" > ${var.public_key}
    chmod 400 ${var.private_key}
    chmod 400 ${var.public_key}
    EOT
  }
}

output "ssh_keys" {
  value = {
    private = nonsensitive(resource.tls_private_key.ssh_key.private_key_openssh)
    public = nonsensitive(resource.tls_private_key.ssh_key.public_key_openssh)
  }
}

provider "digitalocean" {
  token = var.do_token
}

resource "digitalocean_ssh_key" "ssh_key" {
  depends_on = [ resource.null_resource.write_key ]
  name = "Terraform Import SSH"
  public_key = resource.tls_private_key.ssh_key.public_key_openssh
}

resource "digitalocean_droplet" "server" {
  depends_on = [ resource.digitalocean_ssh_key.ssh_key ]
  image   = var.do_image
  name    = "terraform-1"
  region  = "sfo3"
  monitoring = true
  size    = "s-4vcpu-8gb"
  ssh_keys = [resource.digitalocean_ssh_key.ssh_key.fingerprint]

  user_data = <<-EOT
  #!/bin/bash
  echo "User Data Test" > /test.txt
  EOT

  provisioner "local-exec" {
    command = <<-EOT
    echo '#!/bin/bash' > connect_master.sh
    echo 'set -x' >> connect_master.sh
    echo 'ssh root@${self.ipv4_address} -o StrictHostKeyChecking=no -i ${var.private_key} $*' >> connect_master.sh
    chmod +x connect_master.sh
    EOT
  }

  provisioner "local-exec" {
    when = destroy
    command = "rm connect_master.sh"
  }
}

resource "digitalocean_droplet" "workers" {
  count = var.worker_node_count

  depends_on = [ resource.digitalocean_ssh_key.ssh_key ]
  image   = var.do_image
  name    = "terraform-worker-${count.index}"
  region  = "sfo3"
  monitoring = true
  size    = "s-4vcpu-8gb"
  ssh_keys = [resource.digitalocean_ssh_key.ssh_key.fingerprint]

  user_data = <<-EOT
  #!/bin/bash
  echo "User Data Test" > /test.txt
  EOT

  provisioner "local-exec" {
    command = <<-EOT
    echo '#!/bin/bash' > connect_worker_${count.index}.sh
    echo 'set -x' >> connect_worker_${count.index}.sh
    echo 'ssh root@${self.ipv4_address} -o StrictHostKeyChecking=no -i ${var.private_key} $*' >> connect_worker_${count.index}.sh
    chmod +x connect_worker_${count.index}.sh
    EOT
  }

  provisioner "local-exec" {
    when = destroy
    command = "rm connect_worker_${count.index}.sh"
  }
}

locals {
  controlplanes = [resource.digitalocean_droplet.server]
  workers = resource.digitalocean_droplet.workers
  all_instances = concat([resource.digitalocean_droplet.server], resource.digitalocean_droplet.workers)
}

resource "null_resource" "is_live" {
  count = length(local.all_instances)
  
  depends_on = [resource.digitalocean_droplet.server, resource.digitalocean_droplet.workers]

  provisioner "remote-exec" {
    connection {
      host = local.all_instances[count.index].ipv4_address
      user = "root"
      private_key = resource.tls_private_key.ssh_key.private_key_openssh
    }

    inline = [
      <<-EOT
      #!/bin/bash  

      echo "Wait for cloud-init..."
      while [ ! -f /var/lib/cloud/instance/boot-finished ]; do
        echo -e "\033[1;36mWaiting for cloud-init..."
        sleep 1
      done

      #Debian automatically checks for updates on first boot. This ensures that has completed before continuing.
      #If it hasn't finished in 10 minutes, the script will exit ungracefully.
      timeout=$(($(date +%s) + 600))

      while pgrep apt > /dev/null; do

          time=$(date +%s)

          if [[ $time -ge $timeout ]];
          then
              echo "Exceeded APT timeout on first boot!"
              exit 1
          fi

          echo "$time Waiting for first-boot apt checks... timeout at $timeout"
          sleep 1
      done;

      echo "Ready! Yay!"

      exit 0
      EOT
    ]
  }
}

output "do_server" {
  value = {
    id = resource.digitalocean_droplet.server.id
    name = resource.digitalocean_droplet.server.name
    ssh_key = resource.digitalocean_ssh_key.ssh_key.fingerprint
    image = var.do_image
    ipv4 = resource.digitalocean_droplet.server.ipv4_address
    cost_hourly = resource.digitalocean_droplet.server.price_hourly
    cost_monthly = resource.digitalocean_droplet.server.price_monthly
  }
}

output "do_workers" {
  value = [for server in resource.digitalocean_droplet.workers : {
    id = server.id
    name = server.name
    ssh_key = resource.digitalocean_ssh_key.ssh_key.fingerprint
    image = var.do_image
    ipv4 = server.ipv4_address
    cost_hourly = server.price_hourly
    cost_monthly = server.price_monthly
  }]
}

resource "null_resource" "setup" {
  count = length(local.all_instances)

  depends_on = [resource.null_resource.is_live]
  provisioner "remote-exec" {
    connection {
      host = local.all_instances[count.index].ipv4_address
      user = "root"
      private_key = resource.tls_private_key.ssh_key.private_key_openssh
    }

    inline = [
      # Other
      "apt -o DPkg::Lock::Timeout=-1 -y install curl htop nano",
      <<-EOT
      cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
      net.ipv4.ip_forward = 1
      EOF
      EOT
      ,
      "sysctl --system",
      "sysctl net.ipv4.ip_forward",
      "swapoff -a",
      # Kubernetes
      "apt update && apt install -o DPkg::Lock::Timeout=-1 -y apt-transport-https ca-certificates curl gnupg",
      "sudo mkdir -p -m 755 /etc/apt/keyrings",
      "curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg",
      "sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg",
      "echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list",
      "sudo chmod 644 /etc/apt/sources.list.d/kubernetes.list",
      "apt update && apt -o DPkg::Lock::Timeout=-1 -y install kubelet kubectl kubeadm",
      "apt-mark hold kubelet kubeadm kubectl",
      <<-EOT
      echo "KUBELET_EXTRA_ARGS=--cloud-provider=external --node-ip=${local.all_instances[count.index].ipv4_address}" > /etc/default/kubelet
      EOT
      ,
      "systemctl enable --now kubelet",
      "systemctl daemon-reload",
      "mount -a",
      # Docker (for containerd)
      "apt update && apt -o DPkg::Lock::Timeout=-1 -y install curl software-properties-common ca-certificates",
      "install -m 0755 -d /etc/apt/keyrings",
      "curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc && chmod a+r /etc/apt/keyrings/docker.asc",
      <<-EOT
      echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null
      EOT
      ,
      #"apt update && apt -o DPkg::Lock::Timeout=-1 -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin",
      "apt update && apt -o DPkg::Lock::Timeout=-1 -y install containerd.io",
      # Containerd
      #"rm /etc/containerd/config.toml",
      #"crictl config runtime-endpoint unix:///var/run/containerd/containerd.sock",
      #"sed -i -e 's/disabled_plugins/#disabled_plugins/g' /etc/containerd/config.toml",
      "mkdir -p /etc/containerd",
      "sh -c \"containerd config default > /etc/containerd/config.toml\"",
      "sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml",
      "systemctl restart containerd",
      "systemctl restart kubelet",
      "systemctl enable kubelet",
      # Show Info
      "kubeadm version",
      "kubelet version",
      "kubectl version --client"
    ]
  }
}

resource "null_resource" "kubernetes_init_controlplane" {
  count = length(local.controlplanes)

  depends_on = [resource.null_resource.setup]
  provisioner "remote-exec" {
    connection {
      host = local.controlplanes[count.index].ipv4_address
      user = "root"
      private_key = resource.tls_private_key.ssh_key.private_key_openssh
    }

    inline = [
      "kubeadm init --pod-network-cidr=192.168.0.0/16 --apiserver-advertise-address=${local.controlplanes[count.index].ipv4_address}",
      "mkdir -p $HOME/.kube",
      "sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config",
      "sudo chown $(id -u):$(id -g) $HOME/.kube/config",
      "sleep 10", # pause here to allow the control plane to settle
    ]
  }
}

#resource "null_resource" "copy_calico_custom" {
#  count = length(local.controlplanes)
#
#  depends_on = [resource.null_resource.kubernetes_init_controlplane]
#  provisioner "file" {
#    connection {
#      host = local.controlplanes[count.index].ipv4_address
#      user = "root"
#      private_key = resource.tls_private_key.ssh_key.private_key_openssh
#    }
#    
#    source = "tigera-reach-first.yml"
#    destination = "/tigera-reach-first.yml"
#  }
#}
resource "null_resource" "kubernetes_install_addons" {
  count = length(local.controlplanes)
  
  #depends_on = [resource.null_resource.copy_calico_custom]
  depends_on = [resource.null_resource.kubernetes_init_controlplane]

  provisioner "remote-exec" {
    connection {
      host = local.controlplanes[count.index].ipv4_address
      user = "root"
      private_key = resource.tls_private_key.ssh_key.private_key_openssh
    }

    inline = [
      # Kubernetes network add-on
      "curl https://raw.githubusercontent.com/projectcalico/calico/v3.30.0/manifests/operator-crds.yaml -O",
      "curl https://raw.githubusercontent.com/projectcalico/calico/v3.30.0/manifests/tigera-operator.yaml -O",
      "curl https://raw.githubusercontent.com/projectcalico/calico/v3.30.0/manifests/custom-resources.yaml -O",
      # Create resources
      "kubectl create -f operator-crds.yaml",
      "kubectl create -f tigera-operator.yaml",
      "kubectl create -f custom-resources.yaml",
      #"kubectl apply -f /tigera-reach-first.yml",
      #"kubectl set env daemonset/calico-node -n kube-system IP_AUTODETECTION_METHOD=canReach=1.1.1.1",
      # More tools related to calico network add-on
      "curl -L https://github.com/projectcalico/calico/releases/download/v3.30.0/calicoctl-linux-amd64 -o /usr/local/bin/calicoctl",
      "chmod +x /usr/local/bin/calicoctl",
      # Info
      "kubectl cluster-info",
    ]
  }
}

resource "null_resource" "get_kubeadm_command" {
  count = length(local.controlplanes)

  depends_on = [resource.null_resource.kubernetes_install_addons]
  provisioner "local-exec" {
    command = <<-EOT
    ssh root@${local.controlplanes[count.index].ipv4_address} -o StrictHostKeyChecking=no -i ${var.private_key} "kubeadm token create --print-join-command" > kube-join.sh
    EOT
  }
}

resource "null_resource" "join_cluster" {
  count = length(local.workers)

  depends_on = [resource.null_resource.get_kubeadm_command]
  provisioner "remote-exec" {
    connection {
      host = local.workers[count.index].ipv4_address
      user = "root"
      private_key = resource.tls_private_key.ssh_key.private_key_openssh
    }

    scripts = [
      "kube-join.sh"
    ]
  }
}

output "done" {
  value = true
}
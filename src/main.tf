terraform {
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = ">= 0.120"
    }
  }
}

provider "yandex" {
  service_account_key_file = "/home/omp/authorized_key.json"
  cloud_id                 = var.yc_cloud_id
  folder_id                = var.yc_folder_id
  zone                     = var.yc_zone
}


variable "yc_cloud_id" {
  type        = string
}

variable "yc_folder_id" {
  type        = string
}

variable "yc_zone" {
  type        = string
  default     = "ru-central1-a"
}

variable "ssh_public_key" {
  type        = string
  description = "Содержимое публичного SSH-ключа "
}

variable "yc_nat_image_id" {
  type        = string
  default     = "fd80mrhj8fl2oe87o4e1"
}

variable "yc_ubuntu_family" {
  type        = string
  default     = "ubuntu-2404-lts"
}

data "yandex_compute_image" "latest_ubuntu" {
  family = var.yc_ubuntu_family
}

resource "yandex_vpc_network" "net" {
  name = "docker-net"
}

resource "yandex_vpc_subnet" "public_subnet" {
  name           = "public"
  zone           = var.yc_zone
  network_id     = yandex_vpc_network.net.id
  v4_cidr_blocks = ["192.168.10.0/24"]
}

resource "yandex_compute_instance" "nat_instance" {
  name        = "nat-instance"
  platform_id = "standard-v1"
  zone        = var.yc_zone

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    initialize_params {
      image_id = var.yc_nat_image_id
    }
  }

  network_interface {
    subnet_id  = yandex_vpc_subnet.public_subnet.id
    ip_address = "192.168.10.254"
    nat        = true
  }

  metadata = {
    ssh-keys = "ubuntu:${var.ssh_public_key}"
  }
}

resource "yandex_compute_instance" "public_vm" {
  name        = "public-vm"
  platform_id = "standard-v1"
  zone        = var.yc_zone

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.latest_ubuntu.id 
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.public_subnet.id
    nat       = true
  }

  metadata = {
    ssh-keys = "ubuntu:${var.ssh_public_key}"
  }
}

resource "yandex_vpc_subnet" "private_subnet" {
  name           = "private"
  zone           = var.yc_zone
  network_id     = yandex_vpc_network.net.id
  v4_cidr_blocks = ["192.168.20.0/24"]
  route_table_id = yandex_vpc_route_table.private_rt.id
}

resource "yandex_vpc_route_table" "private_rt" {
  name       = "private-route-table"
  network_id = yandex_vpc_network.net.id

  static_route {
    destination_prefix = "0.0.0.0/0"
    next_hop_address   = "192.168.10.254"
  }
}

resource "yandex_compute_instance" "private_vm" {
  name        = "private-vm"
  platform_id = "standard-v1"
  zone        = var.yc_zone

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.latest_ubuntu.id 
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.private_subnet.id
    nat       = false
  }

  metadata = {
    ssh-keys = "ubuntu:${var.ssh_public_key}"
  }
}

output "public_vm_external_ip" {
  value       = yandex_compute_instance.public_vm.network_interface.0.nat_ip_address
  description = "Публичный IP-адрес ВМ"
}

output "private_vm_internal_ip" {
  value       = yandex_compute_instance.private_vm.network_interface.0.ip_address
  description = "Внутренний IP-адрес ВМ"
}

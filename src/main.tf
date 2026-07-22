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
  type = string
}

variable "yc_folder_id" {
  type = string
}

variable "yc_zone" {
  type    = string
  default = "ru-central1-a"
}

variable "yc_ubuntu_family" {
  type    = string
  default = "ubuntu-2404-lts"
}

variable "ssh_public_key" {
  type        = string
  description = "Содержимое публичного SSH-ключа"
}

variable "yc_nat_image_id" {
  type    = string
  default = "fd80mrhj8fl2oe87o4e1"
}

variable "bucket_name" {
  type    = string
  default = "omp-netology-bucket-15-2"
}

variable "yc_service_account_id" {
  type        = string
  description = "ID вашего главного сервисного аккаунта из консоли YC"
}

variable "storage_access_key" {
  type      = string
  sensitive = true
}

variable "storage_secret_key" {
  type      = string
  sensitive = true
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

#resource "yandex_vpc_address" "nat_ip" {
#  name = "nat-instance-ip"
#  external_ipv4_address {
#    zone_id = var.yc_zone
#  }
#}


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
    nat        = false
  #  nat_ip_address = yandex_vpc_address.nat_ip.external_ipv4_address[0].address 
  }

  metadata = {
    ssh-keys = "ubuntu:${var.ssh_public_key}"
  }
}


resource "yandex_kms_symmetric_key" "bucket_key" {
  name              = "omp-bucket-key"
  description       = "Ключ KMS для шифрования бакета"
  default_algorithm = "AES_256"
}

resource "yandex_storage_bucket" "lamp_bucket" {
  access_key = var.storage_access_key
  secret_key = var.storage_secret_key
  bucket     = var.bucket_name

  anonymous_access_flags {
    read = true
    list = false
  }

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        kms_master_key_id = yandex_kms_symmetric_key.bucket_key.id
        sse_algorithm     = "aws:kms"
      }
    }
  }
}


resource "yandex_storage_object" "picture" {
  access_key = var.storage_access_key
  secret_key = var.storage_secret_key
  bucket     = yandex_storage_bucket.lamp_bucket.id
  key        = "image.jpg"
  source     = "image.jpg" 
  acl        = "public-read"
}

resource "yandex_compute_instance_group" "lamp_ig" {
  name               = "lamp-group"
  folder_id          = var.yc_folder_id
  service_account_id = var.yc_service_account_id

  instance_template {
    platform_id = "standard-v1"

    resources {
      core_fraction = 20
      cores         = 2
      memory        = 2
    }

    boot_disk {
      mode = "READ_WRITE"
      initialize_params {
        image_id = "fd827b91d99psvq5fjit" 
        size     = 15
      }
    }

    network_interface {
      network_id = yandex_vpc_network.net.id
      subnet_ids = [yandex_vpc_subnet.private_subnet.id] 
      nat        = false                                # Публичный IP отключен для экономии квот
    }

    metadata = {
      ssh-keys  = "ubuntu:${var.ssh_public_key}"
      user-data = <<EOF
#cloud-config
write_files:
  - path: /var/www/html/index.html
    permissions: '0644'
    owner: root:root
    content: |
      <!DOCTYPE html>
      <html>
      <head>
          <title>LAMP Instance Group</title>
      </head>
      <body>
          <h1>Hello from Netology LAMP Instance Group!</h1>
          <p>This image is served from Yandex Object Storage:</p>
          <img src="https://storage.yandexcloud.net/${var.bucket_name}/image.jpg" alt="Dynamic S3 Image">
      </body>
      </html>
EOF
    }
  }

  scale_policy {
    fixed_scale {
      size = 3
    }
  }

  allocation_policy {
    zones = [var.yc_zone]
  }

  deploy_policy {
    max_unavailable = 1
    max_creating    = 1
    max_expansion   = 1
    max_deleting    = 1
  }

  health_check {
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    http_options {
      port = 80
      path = "/"
    }
  }

  load_balancer {
    target_group_name        = "lamp-target-group"
    target_group_description = "Целевая группа для Сетевого балансировщика"
  }
}


resource "yandex_lb_network_load_balancer" "nlb" {
  name = "lamp-network-lb"

  listener {
    name = "http-listener"
    port = 80
    external_address_spec {
      ip_version = "ipv4"
    }
  }

  attached_target_group {
    target_group_id = yandex_compute_instance_group.lamp_ig.load_balancer[0].target_group_id    
    healthcheck {
      name                = "http"
      interval            = 15
      timeout             = 5
      unhealthy_threshold = 3
      healthy_threshold   = 2
      http_options {
        port = 80
        path = "/"
      }
    }
  }
}

output "load_balancer_public_ip" {
  value       = [for s in yandex_lb_network_load_balancer.nlb.listener : one(s.external_address_spec).address][0]
  description = "Публичный IP-адрес"
}

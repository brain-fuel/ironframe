locals {
  instance_name = length(var.name) <= 54 ? var.name : "${substr(var.name, 0, 45)}-${substr(md5(var.name), 0, 8)}"
  zone          = coalesce(var.zone, "${var.region}-b")
  tag           = "ironframe-${substr(md5(var.name), 0, 12)}"
  endpoint      = "${google_compute_address.this.address}:${var.ports[0]}"
  environment = merge(
    var.environment,
    var.advertise_variable == null ? {} : { (var.advertise_variable) = local.endpoint },
  )
  env_file = join("", [for key in sort(keys(local.environment)) : "${key}=${local.environment[key]}\n"])
  publish  = join(" ", [for port in var.ports : "-p ${port}:${port}"])
  cloud_config = {
    write_files = [
      {
        path        = "/etc/ironframe/twin.env"
        permissions = "0600"
        content     = local.env_file
      },
      {
        path        = "/etc/systemd/system/ironframe-twin.service"
        permissions = "0644"
        content     = <<-UNIT
          [Unit]
          Description=The twin ${var.name}
          Wants=network-online.target
          After=network-online.target docker.service

          [Service]
          ExecStartPre=-/usr/bin/docker rm -f twin
          ExecStart=/usr/bin/docker run --rm --name twin --env-file /etc/ironframe/twin.env ${local.publish} ${var.image}
          ExecStop=/usr/bin/docker stop twin
          Restart=always

          [Install]
          WantedBy=multi-user.target
        UNIT
      },
    ]
    runcmd = [
      "systemctl daemon-reload",
      "systemctl start ironframe-twin.service",
    ]
  }
}

resource "google_compute_address" "this" {
  name         = local.instance_name
  project      = var.project
  region       = var.region
  address_type = var.public ? "EXTERNAL" : "INTERNAL"
  subnetwork   = var.public ? null : var.subnetwork
}

resource "google_compute_firewall" "this" {
  name          = local.instance_name
  project       = var.project
  network       = var.network
  direction     = "INGRESS"
  source_ranges = var.allowed_cidr_blocks
  target_tags   = [local.tag]

  allow {
    protocol = "tcp"
    ports    = [for port in var.ports : tostring(port)]
  }
}

resource "google_compute_instance" "this" {
  name                      = local.instance_name
  project                   = var.project
  zone                      = local.zone
  machine_type              = var.machine_type
  tags                      = [local.tag]
  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = "cos-cloud/cos-stable"
    }
  }

  network_interface {
    network    = var.network
    subnetwork = var.subnetwork
    network_ip = var.public ? null : google_compute_address.this.address

    dynamic "access_config" {
      for_each = var.public ? [1] : []
      content {
        nat_ip = google_compute_address.this.address
      }
    }
  }

  metadata = {
    user-data = "#cloud-config\n${yamlencode(local.cloud_config)}"
  }
}

data "scaleway_baremetal_os" "ubuntu" {
  zone    = var.zone
  name    = "Ubuntu"
  version = var.baremetal_os_version
}

data "scaleway_baremetal_offer" "storage" {
  zone = var.zone
  name = var.baremetal_offer
}

data "scaleway_baremetal_option" "private_network" {
  zone = var.zone
  name = "Private Network"
}

resource "scaleway_iam_ssh_key" "operator" {
  project_id = var.project_id
  name       = "${var.name}-operator"
  public_key = var.ssh_public_key
}

resource "scaleway_vpc" "hosted" {
  project_id = var.project_id
  region     = var.region
  name       = "${var.name}-vpc"
}

resource "scaleway_vpc_private_network" "hosted" {
  project_id = var.project_id
  region     = var.region
  vpc_id     = scaleway_vpc.hosted.id
  name       = "${var.name}-private"
  ipv4_subnet {
    subnet = "172.24.0.0/22"
  }
}

resource "scaleway_baremetal_server" "cell" {
  count       = 3
  project_id  = var.project_id
  zone        = var.zone
  name        = format("%s-cell-%02d", var.name, count.index + 1)
  description = "Lockwell three-replica hosted cell node"
  offer       = data.scaleway_baremetal_offer.storage.offer_id
  os          = data.scaleway_baremetal_os.ubuntu.os_id
  ssh_key_ids = [scaleway_iam_ssh_key.operator.id]

  options {
    id = data.scaleway_baremetal_option.private_network.option_id
  }
  private_network {
    id = scaleway_vpc_private_network.hosted.id
  }
  tags = ["lockwell", "hosted", "cell", "replica-${count.index + 1}"]
}

resource "scaleway_rdb_instance" "control_plane" {
  project_id     = var.project_id
  region         = var.region
  name           = "${var.name}-control-plane"
  node_type      = var.control_plane_db_node_type
  engine         = "PostgreSQL-17"
  is_ha_cluster  = true
  disable_backup = false
  user_name      = var.control_plane_db_user
  password       = var.control_plane_db_password
  private_network {
    pn_id = scaleway_vpc_private_network.hosted.id
  }
  tags = ["lockwell", "hosted", "control-plane"]
}

resource "scaleway_lb_ip" "public" {
  project_id = var.project_id
  zone       = var.zone
}

resource "scaleway_lb" "edge" {
  project_id = var.project_id
  zone       = var.zone
  name       = "${var.name}-edge"
  type       = "LB-S"
  ip_ids     = [scaleway_lb_ip.public.id]
}

resource "scaleway_lb_private_network" "edge" {
  zone               = var.zone
  lb_id              = scaleway_lb.edge.id
  private_network_id = scaleway_vpc_private_network.hosted.id
}

resource "scaleway_lb_backend" "s3" {
  count            = length(var.cell_backend_ips) == 3 ? 1 : 0
  lb_id            = scaleway_lb.edge.id
  name             = "lockwell-s3"
  forward_protocol = "http"
  forward_port     = 9000
  server_ips       = var.cell_backend_ips
  proxy_protocol   = "none"
  health_check_http {
    uri = "/readyz"
  }
  depends_on = [scaleway_lb_private_network.edge]
}

resource "scaleway_lb_frontend" "s3" {
  count        = length(var.cell_backend_ips) == 3 ? 1 : 0
  lb_id        = scaleway_lb.edge.id
  backend_id   = scaleway_lb_backend.s3[0].id
  name         = "lockwell-s3"
  inbound_port = 80
}

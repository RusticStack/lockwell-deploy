output "cell_server_ids" {
  description = "Provider IDs recorded by the hosted control-plane inventory."
  value       = scaleway_baremetal_server.cell[*].id
}

output "private_network_id" {
  value = scaleway_vpc_private_network.hosted.id
}

output "edge_public_ipv4" {
  value = scaleway_lb_ip.public.ip_address
}

output "control_plane_database_id" {
  value = scaleway_rdb_instance.control_plane.id
}

variable "project_id" {
  description = "Scaleway project that owns the hosted pilot resources."
  type        = string
  nullable    = false
}

variable "region" {
  description = "EU region for regional resources."
  type        = string
  default     = "fr-par"
}

variable "zone" {
  description = "EU zone for the three storage nodes."
  type        = string
  default     = "fr-par-2"
}

variable "name" {
  description = "Resource-name prefix."
  type        = string
  default     = "lockwell-pilot"
}

variable "baremetal_offer" {
  description = "Available Elastic Metal offer name with sufficient local storage. Confirm availability and price before apply."
  type        = string
  default     = "EM-A210R-HDD"
}

variable "baremetal_os_version" {
  description = "Ubuntu version published for the selected Elastic Metal zone."
  type        = string
  default     = "24.04 LTS (Noble Numbat)"
}

variable "ssh_public_key" {
  description = "Operator SSH public key. Never pass a private key."
  type        = string
  nullable    = false
}

variable "control_plane_db_user" {
  description = "Initial PostgreSQL role name."
  type        = string
  default     = "lockwell_saas"
}

variable "control_plane_db_password" {
  description = "Initial PostgreSQL password supplied by the deployment secret manager. It remains sensitive Terraform state."
  type        = string
  sensitive   = true
  nullable    = false
}

variable "control_plane_db_node_type" {
  description = "Scaleway RDB node type approved by the cost worksheet."
  type        = string
  default     = "DB-DEV-S"
}

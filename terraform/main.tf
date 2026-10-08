terraform {
  required_version = ">= 1.5.0"

  # Remote state: versioned GCS bucket. GCS provides state locking, and the bucket
  # versioning keeps old copies so a bad state can be rolled back.
  backend "gcs" {
    bucket = "karan-gke-lab-1005-tfstate"
    prefix = "gke/lab"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ---------------------------------------------------------------------------
# Network. Custom VPC - never use the default network for anything real.
# ---------------------------------------------------------------------------
resource "google_compute_network" "vpc" {
  name                    = "lab-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name          = "lab-subnet"
  ip_cidr_range = "10.10.0.0/16"
  region        = var.region
  network       = google_compute_network.vpc.id

  # Lets private nodes reach Google APIs (Artifact Registry, GCS, Secret
  # Manager) with NO external IP and WITHOUT going through Cloud NAT.
  # This is "Private Google Access" - Q5 in the prep file.
  private_ip_google_access = true

  # VPC-native cluster: Pods and Services live in secondary ranges.
  # Sizing these is effectively permanent - it caps how many pods the
  # cluster can ever run. This is the Q7 "IP planning" prerequisite.
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.20.0.0/16"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.30.0.0/20"
  }
}

# ---------------------------------------------------------------------------
# Cloud NAT. Private nodes have NO external IP, so without this they cannot
# reach anything outside Google - including Docker Hub. Outbound only:
# nothing on the internet can initiate a connection inward.  (Q5)
# ---------------------------------------------------------------------------
resource "google_compute_router" "router" {
  name    = "lab-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "lab-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  # Dynamic port allocation is the fix for NAT port exhaustion - the
  # failure mode worth naming in the interview.
  enable_dynamic_port_allocation = true
  min_ports_per_vm               = 64
  max_ports_per_vm               = 2048

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ---------------------------------------------------------------------------
# GKE. ZONAL on purpose: creates in ~6 min instead of ~12, and costs 1/3 of a
# regional cluster because node_count is PER ZONE. Trade-off is no zonal HA,
# which is the right call for a lab and the wrong call for production.
# ---------------------------------------------------------------------------
resource "google_container_cluster" "primary" {
  name     = "lab-gke"
  location = var.zone

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.subnet.id

  remove_default_node_pool = true
  initial_node_count       = 1

  # Provider v6 defaults this to true and `terraform destroy` then FAILS.
  # On free credit this is the gotcha that actually costs money.
  deletion_protection = false

  private_cluster_config {
    enable_private_nodes = true
    # false = the CONTROL PLANE keeps a public endpoint so kubectl works
    # from this laptop. The NODES are still private. Setting this to true
    # would need a bastion or VPN to reach the API server.
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  release_channel {
    channel = "REGULAR"
  }
}

output "get_credentials" {
  value = "gcloud container clusters get-credentials ${google_container_cluster.primary.name} --zone ${var.zone} --project ${var.project_id}"
}

# ---------------------------------------------------------------------------
# Node pool migration: pool-v2 has a larger machine type. Machine type cannot be
# changed in place on an existing pool, so we add a NEW pool, move the workloads
# (cordon + drain the old nodes), then remove the old pool in a later change.
# ---------------------------------------------------------------------------
resource "google_container_node_pool" "pool_v2" {
  name     = "pool-v2"
  cluster  = google_container_cluster.primary.id
  location = var.zone

  initial_node_count = 1

  autoscaling {
    min_node_count = 1
    max_node_count = 3
  }

  node_config {
    machine_type = "e2-standard-2"
    disk_size_gb = 50
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]

    labels = {
      pool = "v2"
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }
}

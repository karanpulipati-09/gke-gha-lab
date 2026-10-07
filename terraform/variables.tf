variable "project_id" {
  type        = string
  description = "Your GCP project id (NOT the project name or number)."
}

variable "region" {
  type    = string
  default = "asia-south1" # Mumbai. Note the format: no second hyphen, unlike AWS ap-south-1
}

variable "zone" {
  type    = string
  default = "asia-south1-a"
}

# gke-gha-lab

A private GKE cluster on GCP, built with Terraform and deployed to from GitHub Actions with
**no stored credentials** (Workload Identity Federation). Lab project, not production.

## Layout

| Path | What it holds |
|---|---|
| `terraform/` | Custom VPC, subnet with pod/service secondary ranges, Cloud Router and Cloud NAT, private zonal GKE cluster, autoscaling node pool, Workload Identity |
| `k8s/` | Manifests the pipeline deploys (`deploy.yml` applies this folder) |
| `lab/workload.yaml` | The nginx app used for probe, HPA and 503 exercises (applied by hand, not by the pipeline) |
| `docs/RUNBOOK.md` | Step-by-step lab runbook |
| `.github/workflows/` | `deploy.yml` (kubectl apply to GKE via federation) |

## How the pipeline authenticates

GitHub issues a short-lived OIDC token for each run. A Workload Identity pool and provider trust
tokens **only from this repository**, and let the run act as the service account `gha-deployer`
(role `container.developer`). The job then fetches a kubeconfig and runs `kubectl apply`.

## State

Terraform state is **local for now** and is never committed (see `.gitignore`). Moving it to a
versioned GCS backend, and running Terraform from GitHub Actions, is the next step.

## Notes

- The API endpoint is open in the lab so GitHub-hosted runners can reach it. Production would use
  authorized networks with self-hosted runners in the VPC, or GitOps.
- Run Terraform with `TF_VAR_project_id` set to the project ID.

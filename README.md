# gke-gha-lab

GitHub Actions deploying to a private GKE cluster with **no stored credentials**, using
Workload Identity Federation.

Flow: GitHub issues a short-lived OIDC token for the run, Google exchanges it for credentials
of the `gha-deployer` service account (allowed only for this repo), and the job fetches a
kubeconfig and runs `kubectl apply`.

Lab only. The cluster API endpoint is open in the lab so GitHub-hosted runners can reach it.
In production, restrict it with authorized networks and use self-hosted runners inside the VPC.

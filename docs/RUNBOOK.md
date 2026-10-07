# GCP Hands-On Lab — Runbook (2026-09-29, night before the TechBlocks round)

**Goal:** make one sentence true — *"I haven't run GCP in production, but I've built a private GKE
cluster with Terraform, with Cloud NAT, and deployed to it."* That is the §2 guardrail line, and
right now it isn't true.

**Already installed on this machine:** Terraform ✅ kubectl ✅ git ✅ — only `gcloud` is missing.

**Budget: 90 minutes.** Abort points are marked. Hitting one is not failure — it means you switch
to reading, which is the higher-value activity on a short clock.

---

## The clock

| Phase | Wall time | Running total |
|---|---|---|
| 1. Signup, billing, `gcloud` install | 25 min | 0:25 |
| 2. Project, APIs, auth | 10 min | 0:35 |
| 3. `terraform apply` (~6 min of it is waiting) | 15 min | 0:50 |
| 4. Deploy the workload, see probes and HPA | 20 min | 1:10 |
| 5. Prove Cloud NAT and the autoscalers | 10 min | 1:20 |
| 6. **`terraform destroy` + verify** | 10 min | 1:30 |

---

## Phase 1 — Account and tooling (25 min)

1. **https://cloud.google.com/free** → start free trial. Needs a **card** (a ₹2-ish verification
   charge is refunded). You get **$300 / 90 days**. Google will not auto-charge when the trial
   ends — it stops the resources.
2. Install the CLI: **https://cloud.google.com/sdk/docs/install** → Windows 64-bit installer.
   Leave "run `gcloud init`" ticked at the end.
3. Close and reopen your terminal, then confirm:

```bash
gcloud version
```

> **⛔ ABORT POINT 1 — if you are past 35 minutes and `gcloud version` still fails, stop.**
> Uninstall nothing, just switch to reading §14 Q4/Q5. A broken toolchain at midnight is worth
> less than knowing Shared VPC cold.

---

## Phase 2 — Project, APIs, auth (10 min)

```bash
gcloud auth login

# A globally-unique id. Keep it lowercase, no spaces.
gcloud projects create karan-gke-lab-0929 --name="GKE Lab"
gcloud config set project karan-gke-lab-0929

# Link billing. Copy the ACCOUNT_ID from the list output.
gcloud billing accounts list
gcloud billing projects link karan-gke-lab-0929 --billing-account=XXXXXX-XXXXXX-XXXXXX

# APIs are OFF by default on GCP - this trips up everyone from AWS.
gcloud services enable compute.googleapis.com container.googleapis.com iam.googleapis.com

# Credentials for Terraform (different from `gcloud auth login`, which is for the CLI)
gcloud auth application-default login
```

**If `projects create` is denied**, use the console instead — *Select a project → New Project* —
then carry on from `gcloud config set project`.

---

## Phase 3 — Build it (15 min, ~6 of them waiting)

```bash
cd "D:/DevOps/Karan-Self/Karan-Self/gcp-lab"

terraform init
terraform plan  -var="project_id=karan-gke-lab-0929"
terraform apply -var="project_id=karan-gke-lab-0929"   # type: yes
```

**Read the plan output before you approve it.** Roughly 6 resources: VPC, subnet, router, NAT,
cluster, node pool. Being able to say *"I read the plan"* is the whole point of the workflow.

Then connect:

```bash
gcloud container clusters get-credentials lab-gke --zone asia-south1-a --project karan-gke-lab-0929
kubectl get nodes -o wide
```

**Look at the `EXTERNAL-IP` column — it is `<none>`. Those are private nodes.** That is the thing
to remember for Q5.

> **⛔ ABORT POINT 2 — if `terraform apply` errors twice for the same reason, stop and read.**
> Likely causes: billing not linked, an API not enabled, or a quota limit on a new trial account.
> Don't debug GCP quota at 11 PM.

---

## Phase 4 — The workload (20 min)

```bash
kubectl apply -f workload.yaml
kubectl get pods -w          # Ctrl-C once both are Running and READY 1/1
```

**That image came from Docker Hub, not Google.** The nodes have no external IP — so if the pull
succeeded, the outbound path is **Cloud NAT** (or Google's mirror for popular images, reached via
Private Google Access, so you cannot prove which one from this alone). Either way: no IAM role and no
pull secret was needed for a public image.

Now actually look at the things you'll be asked about:

```bash
# Q1 - probes as the API server sees them
kubectl describe pod -l app=web | grep -A3 -E "Liveness|Readiness|Startup"

# Readiness gates traffic: the pod is only in Endpoints once it is ready
kubectl get endpointslices -l kubernetes.io/service-name=web -o yaml | grep -A5 addresses

# Q2 - the HPA, its targets and its behaviour
kubectl get hpa web
kubectl describe hpa web
```

**Break a probe on purpose — this is the 2 minutes that turns reading into experience:**

```bash
# Point liveness at a path that doesn't exist
kubectl patch deployment web --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/path","value":"/nope"}]'

kubectl get pods -w      # watch RESTARTS climb, then CrashLoopBackOff
kubectl describe pod -l app=web | grep -i -A2 "Liveness probe failed"
```

**You have now seen the difference first-hand:** a failing *liveness* probe restarts the container
until it crash-loops. A failing *readiness* probe would have left it Running but pulled it out of
the Service. Put it back:

```bash
kubectl apply -f workload.yaml
```

---

## Phase 5 — Prove the autoscalers (10 min)

```bash
# Generate CPU load against the Service
kubectl run load --image=busybox:1.36 --restart=Never -- \
  /bin/sh -c "while true; do wget -q -O- http://web; done"

kubectl get hpa web -w       # watch TARGETS rise and REPLICAS follow
```

Watch the **asymmetry** you wrote about: replicas climb quickly, and after you delete the load
generator they stay up for the 300-second stabilization window before shrinking 10% a minute.

```bash
kubectl delete pod load

# Q12 - force pods Pending so the CLUSTER autoscaler adds a node
kubectl scale deployment web --replicas=30
kubectl get pods | grep -c Pending
kubectl get nodes -w         # a second node joins in ~60-90s

kubectl scale deployment web --replicas=2
```

**The join between the two layers, seen live:** HPA (or your scale command) creates pods → no node
has room → pods go **Pending** → Cluster Autoscaler adds a node. It decides on **requests**, not
actual usage.

---

## Phase 6 — DESTROY (10 min) — do not skip

```bash
terraform destroy -var="project_id=karan-gke-lab-0929"    # type: yes

# Verify with your own eyes. Both must come back empty.
gcloud container clusters list
gcloud compute instances list
```

If `destroy` complains about deletion protection, it means `deletion_protection = false` didn't
apply — fix it and re-run. **Belt and braces: delete the whole project**, which guarantees nothing
is left billing:

```bash
gcloud projects delete karan-gke-lab-0929
```

---

## What you can honestly say tomorrow after this

> *"I haven't run GCP in production — my production Kubernetes and CI/CD work was on Azure. But
> I've built GKE with Terraform: custom VPC, VPC-native cluster with secondary ranges for pods and
> services, private nodes with Cloud NAT for egress and Private Google Access for Google APIs,
> Workload Identity enabled, node pool autoscaling. I deployed to it and worked through probe and
> HPA behaviour on it."*

**Every clause of that is now literally true — and none of it claims production experience.**

**Still NOT true, so don't say it:** Shared VPC. It needs an organization, and a personal trial
account has none. Q4 stays book knowledge — answer it confidently from §14, just don't imply
you've operated it.

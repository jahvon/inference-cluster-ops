# GPU inference cluster on GCP -- vLLM on k3s on a G2 (NVIDIA L4) instance.
#
# This holds the shell-shaped work: terraform lifecycle, the deploy, the boot
# staging, and anything CI needs. It is complete on its own -- a fresh clone with
# no flow installed can provision, deploy, and tear down.
#
# What is NOT here: chatting with the model, listing models, health checks, and
# the status dashboard. flow expresses those natively as HTTP requests and a
# rendered template (.execs/inference.flow, .execs/cluster.flow), which is both
# less code and better output than a shell equivalent. `make status` still prints
# the same facts, as JSON.
#
# GNU Make 3.81 compatible (macOS system make): no .ONESHELL, no ::= .

SHELL := /bin/bash
.DEFAULT_GOAL := help

TF := terraform -chdir=terraform
TFVARS_FILE := terraform/terraform.tfvars

# --- per-invocation overrides -----------------------------------------------
# Infrastructure overrides go to terraform; workload overrides go to the deploy.
SPOT ?=
YES ?=

# Workload. VLLM_REPLICAS reaches k8s/bootstrap.sh as environment, NOT as a
# terraform variable -- model config left instance metadata in the k3s migration
# precisely so changing it no longer needs a reboot.
VLLM_REPLICAS ?=

API_PORT ?= 8000
GRAFANA_PORT ?= 3000
PROM_PORT ?= 9090

TF_OVERRIDES :=
ifneq ($(strip $(SPOT)),)
TF_OVERRIDES += -var use_spot=$(SPOT)
endif

# --- config resolution ------------------------------------------------------
# Lazy (=, not :=) so terraform only runs for targets that actually need it.
# NOT `terraform output -raw`: it prints warnings to stdout and exits 0 when the
# output is missing. See scripts/tf.sh.
tf_out = $(shell bash scripts/tf.sh $(1))
tf_var = $(shell awk -F'"' '/^[[:space:]]*$(1)[[:space:]]*=/ {print $$2; exit}' $(TFVARS_FILE) 2>/dev/null)
k8s_cfg = $(shell awk -F= '/^$(1)=/{gsub(/"/,"",$$2); print $$2; exit}' k8s/config.env 2>/dev/null)

PROJECT = $(or $(call tf_out,project_id),$(call tf_var,project_id))
REGION = $(or $(call tf_var,region),us-central1)
ZONE = $(or $(call tf_out,zone),$(call tf_var,zone),us-central1-a)
INSTANCE = $(or $(call tf_out,instance_name),inference-node)
CURRENT_STATUS = $(call tf_out,current_status)
VM_IP = $(call tf_out,vm_ip)
SSH_USER = $(or $(call tf_out,ssh_user),$(call tf_var,ssh_user),ops)

# plan/apply must not silently start a stopped VM, or restart-on-apply becomes a
# surprise cost. Inherit the live state; default to true only on a fresh create.
RUNNING_INHERIT = $(if $(CURRENT_STATUS),$(if $(filter RUNNING,$(CURRENT_STATUS)),true,false),true)

# --- ssh --------------------------------------------------------------------
# Plain SSH: no IAP, no mesh VPN, nothing a reviewer needs an account for. The
# firewall admits port 22 from allowed_ssh_cidr and nothing else, so the API
# server, Envoy and Grafana all ride local forwards inside one session.
#
# accept-new plus a repo-local known_hosts, because the external address is
# ephemeral and changes on every stop/start.
# Derived from terraform's ssh_public_key_path so the key is named once, in
# terraform.tfvars. Override with SSH_KEY= if you must.
SSH_PUBKEY = $(subst ~,$(HOME),$(or $(call tf_var,ssh_public_key_path),$(HOME)/.ssh/id_ed25519.pub))
SSH_KEY ?= $(patsubst %.pub,%,$(SSH_PUBKEY))
SSH_OPTS := -i $(SSH_KEY) -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile=./.ssh_known_hosts -o LogLevel=ERROR
SSH = ssh $(SSH_OPTS) $(SSH_USER)@$(VM_IP)
KUBECTL_REMOTE = $(SSH) sudo k3s kubectl

# =============================================================================
# Help
# =============================================================================
.PHONY: help
help: ## Show this help
	@echo ""
	@echo "  GPU inference cluster -- vLLM on k3s, GCP G2 (NVIDIA L4)"
	@echo ""
	@awk 'BEGIN {FS = ":.*## "} \
		/^# ==/ {next} \
		/^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2} \
		/^## / {printf "\n  \033[1m%s\033[0m\n", substr($$0, 4)}' $(MAKEFILE_LIST)
	@echo ""
	@echo "  Overrides:  SPOT=true|false   VLLM_REPLICAS=<n>"
	@echo ""
	@echo "  Workload config lives in k8s/config.env and applies with 'make deploy'."
	@echo "  No reboot is involved -- k3s state persists on the data disk."
	@echo ""
	@echo "  Chat, model list, health, and the status dashboard are flow"
	@echo "  executables -- 'flow test chat', 'flow show status'. See README."
	@echo ""

# =============================================================================
## Setup
# =============================================================================
.PHONY: my-ip
my-ip: ## Print your address in CIDR form, for allowed_ssh_cidr
	@ip=$$(curl -sf -m 5 https://checkip.amazonaws.com | tr -d '[:space:]'); \
		test -n "$$ip" || { echo "Could not determine your public IP."; exit 1; }; \
		echo ""; \
		echo "  allowed_ssh_cidr = \"$$ip/32\""; \
		echo ""; \
		echo "  Put that in $(TFVARS_FILE). It is the ONLY source allowed to reach"; \
		echo "  port 22; re-run this and re-apply if your address changes."; \
		echo ""

.PHONY: preflight
preflight: ## Check auth, APIs, GPU quota, and local tooling before anything can fail at apply
	@bash scripts/preflight.sh "$(PROJECT)" "$(REGION)"

.PHONY: init
init: ## terraform init
	@test -f $(TFVARS_FILE) || { \
		echo "ERROR: $(TFVARS_FILE) not found."; \
		echo "  cp terraform/terraform.tfvars.example $(TFVARS_FILE), then set"; \
		echo "  project_id and allowed_ssh_cidr (run 'make my-ip')."; \
		exit 1; }
	$(TF) init

.PHONY: validate
validate: ## terraform fmt check + validate, and render the k8s manifests offline
	$(TF) fmt -check -diff
	$(TF) validate
	@$(MAKE) --no-print-directory render

# =============================================================================
## Lifecycle
# =============================================================================
.PHONY: plan
plan: ## Show what would change (inherits current on/off state)
	$(TF) plan -var running=$(RUNNING_INHERIT) $(TF_OVERRIDES)

.PHONY: apply
apply: _spot-guard ## Apply infrastructure changes (inherits current on/off state)
	$(TF) apply -var running=$(RUNNING_INHERIT) $(TF_OVERRIDES)

.PHONY: provision
provision: _spot-guard ## First-time create: build everything, install k3s, deploy the workload
	$(TF) apply -var running=true $(TF_OVERRIDES)
	@$(MAKE) --no-print-directory deploy
	@$(MAKE) --no-print-directory wait

.PHONY: up
up: _spot-guard ## Start the node and wait for vLLM to serve
	$(TF) apply -auto-approve -var running=true $(TF_OVERRIDES)
	@$(MAKE) --no-print-directory wait

.PHONY: down
down: ## Stop the node. Disks are still billed; this is the main cost lever.
	$(TF) apply -auto-approve -var running=false $(TF_OVERRIDES)
	@echo ""
	@echo "  Stopped. Idle cost: $$(bash scripts/tf.sh idle_monthly_estimate)"
	@echo "  Model weights, cluster state and metrics are preserved on the data disk."
	@echo "  Expect a gap in the Grafana history for the downtime -- that is correct."


.PHONY: destroy
destroy: ## Tear everything down, INCLUDING the data disk
	@echo ""
	@echo "  This destroys the VM, the boot disk, AND the data disk -- model weights,"
	@echo "  k3s cluster state, rollout history, and every metric you have collected."
	@echo "  To just stop paying for compute, use 'make down' instead."
	@echo ""
	@if [ "$(YES)" != "1" ]; then \
		read -r -p "  Type 'destroy' to confirm: " ans; \
		[ "$$ans" = "destroy" ] || { echo "  Aborted."; exit 1; }; \
	fi
	$(TF) destroy $(TF_OVERRIDES)

# Warn before a spot toggle, because it is a rebuild rather than a restart.
.PHONY: _spot-guard
_spot-guard:
	@if [ -n "$(strip $(SPOT))" ]; then \
		case "$(SPOT)" in \
			true)  want=SPOT ;; \
			false) want=STANDARD ;; \
			*) echo "ERROR: SPOT must be 'true' or 'false', got '$(SPOT)'"; exit 1 ;; \
		esac; \
		cur=$$(bash scripts/tf.sh provisioning_model); \
		if [ -n "$$cur" ] && [ "$$cur" != "$$want" ]; then \
			echo ""; \
			echo "  Switching $$cur -> $$want REPLACES the instance."; \
			echo "    destroyed:  boot disk (OS only, ~2min to reinstall k3s)"; \
			echo "    preserved:  /opt/data -- weights, container images, cluster"; \
			echo "                state and metrics all survive, so the workload"; \
			echo "                comes back on its own"; \
			echo "    changed:    the external IP (it is ephemeral)"; \
			echo ""; \
			if [ "$(YES)" != "1" ]; then \
				read -r -p "  Continue? [y/N] " ans; \
				[ "$$ans" = "y" ] || [ "$$ans" = "Y" ] || { echo "  Aborted."; exit 1; }; \
			fi; \
		fi; \
	fi

# Every target that shells into the node needs an address. Without this they
# expand to `ops@` and fail with something that looks like a network problem
# rather than "there is nothing running".
.PHONY: _need-node
_need-node:
	@test -n "$(VM_IP)" || { \
		echo "No VM address -- the node is stopped, or nothing is provisioned."; \
		echo "  make status    what state is it in"; \
		echo "  make up        start it"; \
		exit 1; }

# =============================================================================
## Deploy
# =============================================================================
.PHONY: deploy
# HF_TOKEN is only needed for gated models and is normally unset:
#   HF_TOKEN=hf_xxx make deploy
deploy: ## Apply the workload from k8s/. No reboot -- this is how you reconfigure.
	@$(if $(strip $(VLLM_REPLICAS)),VLLM_REPLICAS="$(VLLM_REPLICAS)",) bash scripts/deploy.sh

.PHONY: render
render: ## Render k8s/ manifests offline and validate them (no cluster needed)
	@bash k8s/bootstrap.sh --render-only

.PHONY: envoy-validate
envoy-validate: render ## Have Envoy itself parse the generated config
	@docker run --rm -v "$(PWD)/k8s/rendered:/c:ro" \
		$(or $(call k8s_cfg,ENVOY_IMAGE),envoyproxy/envoy:v1.31.5) \
		--mode validate -c /c/envoy.yaml

.PHONY: kubeconfig
kubeconfig: _need-node ## Fetch the cluster credential to ./kubeconfig
	@scp $(SSH_OPTS) $(SSH_USER)@$(VM_IP):/etc/rancher/k3s/k3s.yaml ./kubeconfig
	@chmod 600 ./kubeconfig
	@echo "  export KUBECONFIG=$(PWD)/kubeconfig    (needs 'make tunnel')"

# =============================================================================
## Observe
# =============================================================================
.PHONY: status
status: ## Instance state, GPU slices, rollout and burn rate, as JSON
	@bash scripts/status.sh "$(PROJECT)" "$(ZONE)" "$(INSTANCE)"

.PHONY: slo
slo: ## Latency percentiles, SLO violations and recovery times, as JSON
	@bash scripts/slo-report.sh

.PHONY: calibrate
calibrate: ## One-shot calibration run: measure the latency/throughput baseline
	@bash scripts/calibrate.sh

.PHONY: load-start
load-start: ## Start sustained multi-tenant load (inference-perf)
	@bash scripts/load.sh start

.PHONY: load-stop
load-stop: ## Stop the sustained load generators
	@bash scripts/load.sh stop

.PHONY: load-status
load-status: ## Are the load generators running
	@bash scripts/load.sh status || true

.PHONY: wait
wait: ## Poll until vLLM answers (first boot installs k3s and downloads weights)
	@bash scripts/wait-healthy.sh

.PHONY: pods
pods: _need-node ## Every pod in the cluster, with node and IP
	@$(KUBECTL_REMOTE) get pods -A -o wide

.PHONY: rollout-status
rollout-status: ## Watch the canary: stable/canary split, analysis runs, current step
	@bash scripts/rollout.sh get --watch

.PHONY: logs
logs: _need-node ## Tail vLLM logs across every replica (Ctrl-C to stop)
	@$(KUBECTL_REMOTE) logs -f -n inference -l app=vllm --tail=100 --max-log-requests=16

.PHONY: envoy-logs
envoy-logs: _need-node ## Tail Envoy's logs -- where upstream and routing failures show up
	@$(KUBECTL_REMOTE) logs -f -n inference -l app=envoy --tail=100

.PHONY: boot-logs
boot-logs: _need-node ## Show the node bootstrap log (disk mount, driver, k3s install)
	@$(SSH) 'sudo cat /var/log/node-bootstrap.log'

.PHONY: gpu
gpu: _need-node ## Live GPU utilization and memory
	@$(SSH) 'nvidia-smi'

# =============================================================================
## Use
# =============================================================================
.PHONY: tunnel
tunnel: _need-node ## Open the SSH tunnel in the background (:6443 kubernetes, :8000 vLLM)
	@API_PORT=$(API_PORT) bash scripts/tunnel.sh ensure

.PHONY: untunnel
untunnel: ## Close the background tunnel
	@API_PORT=$(API_PORT) bash scripts/tunnel.sh close

.PHONY: prom
prom: ## Prometheus on localhost:9090, in the background
	@PROM_PORT=$(PROM_PORT) bash scripts/portfwd.sh prom ensure

.PHONY: dash
dash: ## Grafana on localhost:3000, in the background, with the login
	@GRAFANA_PORT=$(GRAFANA_PORT) bash scripts/portfwd.sh grafana ensure
	@echo "  user admin / password $$(KUBECONFIG=$(PWD)/kubeconfig kubectl -n monitoring get secret kps-grafana -o jsonpath='{.data.admin-password}' | base64 -d)"

.PHONY: unforward
unforward: ## Close the background Grafana and Prometheus forwards
	@GRAFANA_PORT=$(GRAFANA_PORT) bash scripts/portfwd.sh grafana close
	@PROM_PORT=$(PROM_PORT) bash scripts/portfwd.sh prom close

.PHONY: promote
promote: ## Advance the canary to the next step (or finish the rollout)
	@bash scripts/rollout.sh promote

.PHONY: abort
abort: ## Roll the canary back to the stable version
	@bash scripts/rollout.sh abort

.PHONY: ssh
ssh: _need-node ## SSH to the node (kubectl is on PATH there)
	@$(SSH)

# =============================================================================
## Housekeeping
# =============================================================================
.PHONY: outputs
outputs: ## Print all terraform outputs
	@$(TF) output

.PHONY: clean
clean: ## Remove local plan artifacts and rendered manifests (not state, not cloud resources)
	rm -f terraform/*.tfplan terraform/crash.log
	rm -rf k8s/rendered
	@echo "Removed local artifacts. State, kubeconfig and cloud resources untouched."


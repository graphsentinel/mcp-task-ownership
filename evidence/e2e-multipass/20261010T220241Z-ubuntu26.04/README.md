Run with the single-script flow that preceded scripts/platform.sh + the Helm chart (bootstrap-ubuntu.sh, lab.sh up):
fresh Ubuntu 26.04 VM, Docker from Ubuntu's docker.io (29.1.3), k3s v1.37.1, RUNS=5. Result: ALL CHECKS PASSED.
full.log is the host-side log of scripts/multipass-e2e.sh (the per-step logs were lost; the VM was deleted).

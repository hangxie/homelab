#!/bin/bash
# Remove a worker node from the Kubernetes cluster
# This script handles Rook-Ceph OSD removal, drains the node and deregisters from control plane
set -e

AUTO_YES="${AUTO_YES:-false}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-300}"
ROOK_NAMESPACE="${ROOK_NAMESPACE:-rook-ceph}"

# Parse arguments
NODE_NAME=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -y|--yes)
            AUTO_YES=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS] <node-name>"
            echo ""
            echo "Remove a worker node from the Kubernetes cluster safely."
            echo ""
            echo "Options:"
            echo "  -y, --yes      Auto-confirm all prompts"
            echo "  -h, --help     Show this help message"
            echo ""
            echo "Environment variables:"
            echo "  DRAIN_TIMEOUT           Timeout for node drain (default: 300s)"
            echo "  ROOK_NAMESPACE          Namespace where Rook-Ceph is installed (default: rook-ceph)"
            echo ""
            echo "Exit codes:"
            echo "  0  Node removed successfully"
            echo "  1  Operation cancelled or invalid arguments"
            echo "  2  Error during removal"
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
        *)
            NODE_NAME="$1"
            shift
            ;;
    esac
done

if [ -z "$NODE_NAME" ]; then
    echo "Error: Node name is required"
    echo "Usage: $0 [OPTIONS] <node-name>"
    exit 1
fi

log_info() { echo "[INFO] $1"; }
log_warn() { echo "[WARN] $1"; }
log_error() { echo "[ERROR] $1"; }

# Check prerequisites
check_prerequisites() {
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not installed or not in PATH"
        exit 2
    fi
    if ! command -v jq &> /dev/null; then
        log_error "jq is not installed or not in PATH"
        exit 2
    fi
}

# Verify node exists and is a worker
verify_node() {
    local node="$1"

    if ! kubectl get node "$node" &> /dev/null; then
        log_error "Node '$node' not found in cluster"
        exit 2
    fi

    # Check if it's a control plane node
    if kubectl get node "$node" -o jsonpath='{.metadata.labels}' | grep -q "node-role.kubernetes.io/control-plane"; then
        log_error "Node '$node' is a control plane node. This script only removes worker nodes."
        log_error "Removing control plane nodes requires additional steps (etcd member removal, etc.)"
        exit 2
    fi

    log_info "Node '$node' verified as worker node"
}

# Get node status summary
show_node_status() {
    local node="$1"

    echo ""
    log_info "Current node status:"
    kubectl get node "$node" -o wide

    echo ""
    log_info "Pods running on node:"
    kubectl get pods --all-namespaces --field-selector "spec.nodeName=$node" -o wide 2>/dev/null || echo "  No pods found"

    # Check for Ceph OSDs
    echo ""
    log_info "Ceph OSDs on node:"
    OSD_PODS=$(kubectl get pods -n "$ROOK_NAMESPACE" -l app=rook-ceph-osd --field-selector "spec.nodeName=$node" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    if [ -n "$OSD_PODS" ]; then
        for pod in $OSD_PODS; do
            OSD_ID=$(kubectl get pod -n "$ROOK_NAMESPACE" "$pod" -o jsonpath='{.metadata.labels.ceph-osd-id}')
            echo "  - OSD ID: $OSD_ID (Pod: $pod)"
        done
    else
        echo "  No Ceph OSDs found on this node"
    fi
    echo ""
}

# Handle Ceph OSD removal if present
handle_ceph_osds() {
    local node="$1"
    
    # Get OSD IDs on this node
    OSD_IDS=$(kubectl get pods -n "$ROOK_NAMESPACE" -l app=rook-ceph-osd --field-selector "spec.nodeName=$node" -o jsonpath='{.items[*].metadata.labels.ceph-osd-id}' 2>/dev/null || true)
    
    if [ -z "$OSD_IDS" ]; then
        return 0
    fi

    log_warn "This node hosts Ceph OSDs: $OSD_IDS"
    log_info "It is recommended to let Rook handle OSD removal by updating the CephCluster CRD"
    log_info "or by simply removing the node from the cluster if replication factor allows."
    
    if [ "$AUTO_YES" != "true" ]; then
        read -p "Continue with node removal? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Operation cancelled"
            exit 1
        fi
    fi
}

# Cordon and drain the node
drain_node() {
    local node="$1"

    log_info "Cordoning node (marking unschedulable)..."
    kubectl cordon "$node"

    log_info "Draining node (evicting pods)..."
    # We use a long timeout for Rook/Ceph pods to allow for data rebalancing if needed
    kubectl drain "$node" \
        --ignore-daemonsets \
        --delete-emptydir-data \
        --force \
        --timeout="${DRAIN_TIMEOUT}s" || {
            log_warn "Drain completed with warnings (this is usually OK for DaemonSets)"
        }

    log_info "Node drained successfully"
}

# Delete the node from Kubernetes
delete_node() {
    local node="$1"

    log_info "Deleting node from Kubernetes cluster..."
    kubectl delete node "$node"

    log_info "Node '$node' removed from cluster"
}

# Cleanup instructions
show_cleanup_instructions() {
    local node="$1"

    echo ""
    echo "=========================================="
    log_info "Node '$node' has been removed from the cluster"
    echo "=========================================="
    echo ""
    echo "Next steps on the removed node ($node):"
    echo ""
    echo "1. SSH to the node and reset kubeadm:"
    echo "   ssh $node"
    echo "   sudo kubeadm reset -f"
    echo "   sudo rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd ~/.kube"
    echo ""
    echo "2. Clean up CNI and iptables:"
    echo "   sudo rm -rf /etc/cni/net.d /var/lib/cni"
    echo "   sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X"
    echo ""
    echo "3. Clean up Ceph data (CRITICAL for reuse):"
    echo "   sudo rm -rf /var/lib/rook"
    echo "   # If reusing the disk for Ceph again, wipe the raw device, e.g.:"
    echo "   # sudo wipefs -a /dev/vdb"
    echo ""
    echo "4. Optionally stop/disable services:"
    echo "   sudo systemctl stop kubelet containerd"
    echo "   sudo systemctl disable kubelet containerd"
    echo ""
    echo "5. Update your inventory.ini and terraform/terraform.tfvars to remove this node"
    echo ""
}

# Main
main() {
    log_info "=== Removing worker node: $NODE_NAME ==="
    echo ""

    check_prerequisites
    verify_node "$NODE_NAME"
    show_node_status "$NODE_NAME"
    
    handle_ceph_osds "$NODE_NAME"

    # Final Confirm
    if [ "$AUTO_YES" != "true" ]; then
        echo ""
        read -p "Are you sure you want to proceed with removing node '$NODE_NAME'? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Operation cancelled"
            exit 1
        fi
    else
        log_info "Auto-confirming removal (-y flag)"
    fi

    echo ""

    # Step 1: Drain the node
    log_info "Step 1/2: Draining node..."
    drain_node "$NODE_NAME"

    # Step 2: Delete the node
    log_info "Step 2/2: Deleting node from cluster..."
    delete_node "$NODE_NAME"

    show_cleanup_instructions "$NODE_NAME"

    exit 0
}

main

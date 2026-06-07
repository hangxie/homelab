#!/bin/sh
# Health check for keepalived's chk_haproxy track_script.
# Exit 0 => local HAProxy is fit to hold the kube-API VIP.
# Exit 1 => keepalived will demote this node (weight -2 per vrrp_script).
systemctl is-active --quiet haproxy || exit 1
ss -lnt 'sport = :6443' | grep -q 6443 || exit 1
exit 0

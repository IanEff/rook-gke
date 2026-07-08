# GKE's current UBUNTU_CONTAINERD image (Ubuntu 24.04, kernel 6.8) ships rbd.ko
# zstd-compressed. The cephcsi container's bundled modprobe/kmod can't decompress
# it and fails with "Exec format error", but the host's own modprobe (kmod, +ZSTD)
# loads it instantly. This DaemonSet preloads `rbd` via the host's mount namespace
# on every node so cephcsi finds it already loaded and never has to modprobe it
# itself. See CLAUDE.md's note on the rbd kernel module requirement.
resource "kubernetes_daemonset" "rbd_module_loader" {
  metadata {
    name      = "rbd-module-loader"
    namespace = "kube-system"
    labels = {
      app = "rbd-module-loader"
    }
  }

  spec {
    selector {
      match_labels = {
        app = "rbd-module-loader"
      }
    }

    template {
      metadata {
        labels = {
          app = "rbd-module-loader"
        }
      }

      spec {
        host_pid = true

        container {
          name    = "loader"
          image   = "busybox:1.36"
          command = ["sh", "-c", "chroot /host modprobe rbd && sleep infinity"]

          security_context {
            privileged = true
          }

          volume_mount {
            name       = "host"
            mount_path = "/host"
          }
        }

        volume {
          name = "host"
          host_path {
            path = "/"
          }
        }

        toleration {
          operator = "Exists"
        }
      }
    }
  }

  depends_on = [google_container_node_pool.primary_nodes]
}

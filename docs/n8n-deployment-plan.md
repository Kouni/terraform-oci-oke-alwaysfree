# n8n on OKE Always Free — Cloudflare Zero Trust Tunnel 部署計劃

> **Chart**: n8n 官方 Helm chart — `oci://ghcr.io/n8n-io/n8n-helm-chart/n8n` (v1.3.0+)
> **Source**: [github.com/n8n-io/n8n-hosting](https://github.com/n8n-io/n8n-hosting)

## 架構圖

```
                        ┌─────────┐
                        │  User   │
                        │ Browser │
                        └────┬────┘
                             │ HTTPS
                             ▼
                      ┌─────────────┐
                      │  Cloudflare │
                      │    Edge     │
                      │ (Public     │
                      │  Hostname)  │
                      └──────┬──────┘
                             │ Secure Tunnel (encrypted)
╔════════════════════════════╪══════════════════════════════════════╗
║  OCI Always Free VCN       │                                     ║
║  ┌─────────────────────────┼───────────────────────────────────┐ ║
║  │  OKE Cluster (BASIC_CLUSTER, Flannel CNI)                   │ ║
║  │  Worker Node: VM.Standard.A1.Flex (ARM64)                   │ ║
║  │                         │                                    │ ║
║  │  ┌─── Namespace: n8n ───┼──────────────────────────────┐    │ ║
║  │  │                      │                               │    │ ║
║  │  │   ┌──────────────────▼───────────┐                   │    │ ║
║  │  │   │  Deployment: cloudflared     │                   │    │ ║
║  │  │   │  ┌─────────────────────────┐ │                   │    │ ║
║  │  │   │  │ cloudflare/cloudflared  │ │                   │    │ ║
║  │  │   │  │ :latest                 │ │                   │    │ ║
║  │  │   │  │                         │ │                   │    │ ║
║  │  │   │  │ TUNNEL_TOKEN ◄── Secret │ │                   │    │ ║
║  │  │   │  │   (cloudflare-tunnel)   │ │                   │    │ ║
║  │  │   │  └───────────┬─────────────┘ │                   │    │ ║
║  │  │   └──────────────┼──────────────-┘                   │    │ ║
║  │  │                  │ http://n8n-main:5678              │    │ ║
║  │  │                  ▼                                    │    │ ║
║  │  │   ┌──────────────────────────────┐                   │    │ ║
║  │  │   │  Service: n8n-main           │                   │    │ ║
║  │  │   │  type: ClusterIP :5678       │                   │    │ ║
║  │  │   └──────────────┬───────────────┘                   │    │ ║
║  │  │                  │                                    │    │ ║
║  │  │   ┌──────────────▼───────────────┐                   │    │ ║
║  │  │   │  Deployment: n8n-main        │                   │    │ ║
║  │  │   │  (Helm: official n8n chart)  │                   │    │ ║
║  │  │   │  ┌─────────────────────────┐ │                   │    │ ║
║  │  │   │  │ n8nio/n8n:latest        │ │                   │    │ ║
║  │  │   │  │ Standalone mode (SQLite)│ │                   │    │ ║
║  │  │   │  │                         │ │                   │    │ ║
║  │  │   │  │ Secrets ◄── Secret      │ │                   │    │ ║
║  │  │   │  │   (n8n-secrets)         │ │                   │    │ ║
║  │  │   │  │   • N8N_ENCRYPTION_KEY  │ │                   │    │ ║
║  │  │   │  │   • N8N_HOST            │ │                   │    │ ║
║  │  │   │  │   • N8N_PORT            │ │                   │    │ ║
║  │  │   │  │   • N8N_PROTOCOL        │ │                   │    │ ║
║  │  │   │  └───────────┬─────────────┘ │                   │    │ ║
║  │  │   └──────────────┼──────────────-┘                   │    │ ║
║  │  │                  │ mount: /home/node/.n8n            │    │ ║
║  │  │                  ▼                                    │    │ ║
║  │  │   ┌──────────────────────────────┐                   │    │ ║
║  │  │   │  PVC (StorageClass: nfs)     │                   │    │ ║
║  │  │   │  AccessMode: ReadWriteOnce   │                   │    │ ║
║  │  │   └──────────────┬───────────────┘                   │    │ ║
║  │  │                  │                                    │    │ ║
║  │  └──────────────────┼───────────────────────────────┘    │ ║
║  │                     ▼                                    │ ║
║  │   ┌──────────────────────────────────────┐               │ ║
║  │   │  nfs-server-provisioner              │               │ ║
║  │   │  (Namespace: nfs-storage)            │               │ ║
║  │   │  Backed by OCI Block Volume          │               │ ║
║  │   │  (Always Free 200 GB quota 共用)     │               │ ║
║  │   └──────────────────────────────────────┘               │ ║
║  └──────────────────────────────────────────────────────────┘ ║
╚══════════════════════════════════════════════════════════════════╝

流量路徑:
  User ──HTTPS──▶ Cloudflare Public Hostname
       ──Tunnel──▶ cloudflared Pod (outbound only, 無 inbound port)
       ──HTTP────▶ n8n-main Service (ClusterIP, 叢集內部)
       ──────────▶ n8n Pod (:5678)

資料路徑:
  n8n Pod ──mount──▶ NFS PVC ──▶ nfs-server-provisioner ──▶ OCI Block Volume
```

## 架構決策與原因

### 為什麼不使用 Private Subnet？

| 方案 | 費用 | 安全性 |
|------|------|--------|
| Private Subnet + NAT Gateway | ❌ NAT GW 需付費，非 Always Free | ✅ 節點無 public IP |
| ClusterIP + cloudflared | ✅ 完全免費 | ✅ 等效隔離，無 inbound port |

目前所有子網路均為 public subnet（`prohibit_public_ip_on_vnic = false`），添加 NAT Gateway 會產生費用。採用 `ClusterIP` Service 搭配 `cloudflared` 可達到相同效果：

- n8n Service 類型為 `ClusterIP`，**不建立 OCI Load Balancer**，沒有任何外部 inbound 入口
- `cloudflared` 僅建立 **outbound** 連線至 Cloudflare Edge（HTTPS port 443）
- 即使 Worker Node 有 public IP，也沒有任何 port 暴露 n8n

### Helm Chart — 使用 n8n 官方 chart

| | 8gears 社區 chart ❌ | n8n 官方 chart ✅ |
|---|---|---|
| **來源** | `github.com/8gears/n8n-helm-chart` | `github.com/n8n-io/n8n-hosting` |
| **Registry** | `oci://8gears.container-registry.com/library/n8n` | `oci://ghcr.io/n8n-io/n8n-helm-chart/n8n` |
| **維護者** | 第三方社區 | **n8n 官方團隊** |
| **版本** | 不定 | v1.3.0 (appVersion 2.12.2) |
| **Standalone 支援** | 有 | ✅ 原生支援（`queueMode.enabled: false`） |

### Standalone Mode（非 Queue Mode）

| 模式 | 需要的外部服務 | 資源消耗 | 適用場景 |
|------|---------------|---------|---------|
| Queue mode（預設） | PostgreSQL + Redis | 高 | 多節點生產環境 |
| **Standalone mode** ✅ | 無（SQLite） | 低 | 單節點、Always Free |

選擇 Standalone mode：不需外部 DB/Redis，資料存在 SQLite `/home/node/.n8n`，適合 Always Free 單節點環境。

### cloudflared 部署策略 — 獨立 Deployment（非 Sidecar）

官方 n8n Helm chart 的 deployment template **不支援** `extraContainers`（僅支援 `taskRunners` sidecar），因此 cloudflared 無法作為 sidecar 注入。

改為獨立 Deployment：

| | Sidecar 方案 ❌ | 獨立 Deployment ✅ |
|---|---|---|
| **與官方 chart 相容** | 不相容（無 extraContainers） | ✅ 完全解耦 |
| **連線目標** | `localhost:5678` | `http://n8n-main:5678`（K8s Service） |
| **獨立更新/重啟** | 不行（同 Pod） | ✅ 可獨立操作 |
| **安全性** | 同 Pod 網路 | 同 Namespace 內部通訊，等效安全 |

使用 Terraform `kubernetes` provider 部署 `kubernetes_deployment_v1`。

### 持久化儲存策略

使用已部署的 `nfs` StorageClass（由 `nfs-server-provisioner` 提供）：

- **官方 chart persistence**：`persistence.enabled = true`，`storageClassName = "nfs"`
- **AccessMode**: `ReadWriteOnce`（Standalone mode 單 Pod，RWO 即足夠）
- **fsGroup: 1000**：官方 chart 預設 `securityContext.fsGroup = 1000`，K8s 自動設定 volume 權限，**不需 initContainer**
- **資料保留**：部署後建議手動將 PV reclaim policy 改為 `Retain`（見下方操作步驟）

### Secrets 管理策略

在 **Terraform 外部** 以 `kubectl` 手動建立 Kubernetes Secret：

- Secrets **不進入 Terraform state**
- 兩個 Secret：

| Secret 名稱 | 用途 | 包含的 Keys |
|-------------|------|-------------|
| `n8n-secrets` | n8n 核心設定 | `N8N_ENCRYPTION_KEY`, `N8N_HOST`, `N8N_PORT`, `N8N_PROTOCOL` |
| `cloudflare-tunnel` | Tunnel 認證 | `TUNNEL_TOKEN` |

### ARM64 相容性確認

| 元件 | Image | ARM64 支援 |
|------|-------|-----------|
| n8n | `docker.n8n.io/n8nio/n8n:latest` | ✅ 官方 multi-arch |
| cloudflared | `cloudflare/cloudflared:latest` | ✅ 官方 multi-arch |

---

## 實作範圍

### 修改檔案（5 個）

不修改任何 `modules/` 內的檔案。

#### 1. `variables.tf` — 新增 6 個變數

| 變數名 | 類型 | 預設值 | 說明 |
|--------|------|--------|------|
| `enable_n8n` | bool | `false` | 是否部署 n8n + cloudflared |
| `n8n_namespace` | string | `"n8n"` | Kubernetes namespace |
| `n8n_pvc_size` | string | `"5Gi"` | NFS PVC 大小 |
| `n8n_secret_name` | string | `"n8n-secrets"` | 含核心設定的 K8s Secret |
| `cloudflared_secret_name` | string | `"cloudflare-tunnel"` | 含 TUNNEL_TOKEN 的 K8s Secret |
| `n8n_chart_version` | string | `null` | Chart 版本（null = latest） |

#### 2. `versions.tf` — 新增 kubernetes provider

```hcl
kubernetes = {
  source  = "hashicorp/kubernetes"
  version = ">= 2.0.0"
}
```

#### 3. `main.tf` — 新增 3 個區段

**3a. kubernetes provider 設定**（與 helm provider 共用認證）：

```hcl
provider "kubernetes" {
  host                   = module.oke.cluster_endpoint
  cluster_ca_certificate = local.cluster_ca_certificate
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "oci"
    args = [
      "ce", "cluster", "generate-token",
      "--cluster-id", module.oke.cluster_id,
      "--region", split(".", module.oke.cluster_id)[3]
    ]
  }
}
```

**3b. n8n Helm release**（官方 chart，Standalone mode）：

```hcl
resource "helm_release" "n8n" {
  count = var.enable_n8n ? 1 : 0

  name             = "n8n"
  repository       = "oci://ghcr.io/n8n-io/n8n-helm-chart"
  chart            = "n8n"
  version          = var.n8n_chart_version
  namespace        = var.n8n_namespace
  create_namespace = true

  values = [yamlencode({
    # Use latest image
    image = {
      repository = "docker.n8n.io/n8nio/n8n"
      tag        = "latest"
    }

    # Standalone mode: SQLite, no PostgreSQL/Redis
    queueMode = { enabled = false }
    database  = { type = "sqlite", useExternal = false }
    redis     = { enabled = false }

    # Persistence (NFS)
    persistence = {
      enabled          = true
      storageClassName = "nfs"
      size             = var.n8n_pvc_size
      accessModes      = ["ReadWriteOnce"]
    }

    # Use externally managed K8s Secret
    secretRefs = {
      existingSecret = var.n8n_secret_name
    }

    # Service — ClusterIP only, no OCI LB
    service = {
      type = "ClusterIP"
      port = 5678
    }

    # Ingress — disabled, Cloudflare Tunnel handles access
    ingress = { enabled = false }

    # Resources (ARM A1.Flex, 留餘裕給其他 workloads)
    resources = {
      main = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { cpu = "500m", memory = "512Mi" }
      }
    }

    # Security context (n8n runs as UID 1000, fsGroup handles NFS permissions)
    securityContext = {
      enabled    = true
      fsGroup    = 1000
      runAsUser  = 1000
      runAsGroup = 1000
    }

    # Disable PDB (single replica)
    pdb = { enabled = false }
  })]

  depends_on = [module.oke, helm_release.nfs_server_provisioner]

  lifecycle {
    precondition {
      condition     = var.enable_nfs_storage
      error_message = "enable_nfs_storage must be true when enable_n8n is true (n8n requires the NFS StorageClass)."
    }
  }
}
```

**3c. cloudflared Deployment**（獨立 Deployment，kubernetes provider）：

```hcl
resource "kubernetes_deployment_v1" "cloudflared" {
  count = var.enable_n8n ? 1 : 0

  metadata {
    name      = "cloudflared"
    namespace = var.n8n_namespace
    labels    = { app = "cloudflared" }
  }

  spec {
    replicas = 1
    selector {
      match_labels = { app = "cloudflared" }
    }
    template {
      metadata {
        labels = { app = "cloudflared" }
      }
      spec {
        container {
          name  = "cloudflared"
          image = "cloudflare/cloudflared:latest"
          args  = ["tunnel", "--no-autoupdate", "run"]

          env {
            name = "TUNNEL_TOKEN"
            value_from {
              secret_key_ref {
                name = var.cloudflared_secret_name
                key  = "TUNNEL_TOKEN"
              }
            }
          }

          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { cpu = "100m", memory = "128Mi" }
          }
        }
      }
    }
  }

  depends_on = [helm_release.n8n]
}
```

#### 4. `terraform.tfvars.example` — 新增 n8n 區段

新增說明區塊，含 kubectl 前置步驟與 Cloudflare 設定注釋。

#### 5. `outputs.tf` — 新增 2 個 output

- `n8n_namespace`：部署所在的 namespace
- `n8n_setup_instructions`：顯示 kubectl secret 建立指令

---

## Apply 前必要的手動步驟

> ⚠️ 以下步驟必須在 `terraform apply` **之前**完成，否則 n8n Pod 無法啟動。

### Step 1: Cloudflare Zero Trust 設定

1. 至 [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com)
2. 進入 **Networks → Tunnels → Create a tunnel**
3. 選擇 **Cloudflared**，輸入 tunnel 名稱（如 `n8n-oke`）
4. 複製 tunnel token（用於下方 kubectl 指令）
5. 新增 **Public Hostname**：
   - Subdomain: 你想要的子網域（如 `n8n`）
   - Domain: 你的 Cloudflare 網域
   - **Service**: `http://n8n-main:5678`（指向叢集內 n8n Service）
6. 儲存設定

### Step 2: 建立 Kubernetes Secrets

```bash
# 建立 namespace（Terraform 也會建立，但 secret 需先存在）
kubectl create namespace n8n

# n8n 核心 Secret（包含 4 個必要 key）
# ⚠️ 請將 n8n.your-domain.com 替換為你的 Cloudflare Public Hostname
kubectl create secret generic n8n-secrets \
  --namespace n8n \
  --from-literal=N8N_ENCRYPTION_KEY="$(openssl rand -hex 32)" \
  --from-literal=N8N_HOST="n8n.your-domain.com" \
  --from-literal=N8N_PORT="5678" \
  --from-literal=N8N_PROTOCOL="http"

# Cloudflare Tunnel Secret
kubectl create secret generic cloudflare-tunnel \
  --namespace n8n \
  --from-literal=TUNNEL_TOKEN="<your-cloudflare-tunnel-token>"

# 驗證
kubectl get secrets -n n8n
```

> 💡 **重要**：`N8N_ENCRYPTION_KEY` 請妥善保存！遺失後無法解密已儲存的 n8n 憑證。

---

## 部署指令

```bash
# terraform.tfvars 中設定：
# enable_nfs_storage = true
# enable_n8n         = true

terraform init    # 首次需要，下載 kubernetes provider
terraform plan
terraform apply
```

---

## 部署後建議操作

### 將 PV Reclaim Policy 改為 Retain（防止資料遺失）

```bash
# 查看 n8n PVC 對應的 PV
PV_NAME=$(kubectl get pvc -n n8n -o jsonpath='{.items[0].spec.volumeName}')

# 將 reclaim policy 改為 Retain（刪除 PVC 時保留資料）
kubectl patch pv "$PV_NAME" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'

# 驗證
kubectl get pv "$PV_NAME" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}'
# 應顯示: Retain
```

---

## 驗證部署

```bash
# 確認 Pods 狀態（應有 2 個 Deployment 各 1 Pod）
kubectl get pods -n n8n

# 預期輸出：
#   NAME                          READY   STATUS    RESTARTS   AGE
#   n8n-main-xxxxxxxxxx-xxxxx     1/1     Running   0          1m
#   cloudflared-xxxxxxxxxx-xxxxx  1/1     Running   0          1m

# 查看 n8n logs
kubectl logs -n n8n deployment/n8n-main

# 查看 cloudflared tunnel 連線狀態
kubectl logs -n n8n deployment/cloudflared

# 確認 PVC 已建立並 Bound
kubectl get pvc -n n8n

# 透過瀏覽器存取 Cloudflare Public Hostname
# https://n8n.your-domain.com
```

---

## 資源佔用評估（Always Free 限制）

| 資源 | n8n 用量 | cloudflared 用量 | Always Free 限制 |
|------|---------|-----------------|-----------------|
| CPU | 100m–500m | 10m–100m | 4 OCPU total |
| RAM | 256Mi–512Mi | 32Mi–128Mi | 24 GB total |
| Block Volume | +0（NFS PVC） | +0 | 200 GB shared |
| Load Balancer | 0（ClusterIP） | 0 | 不適用 |

n8n + cloudflared 部署**不額外消耗任何 OCI Always Free 基礎設施配額**（CPU/RAM 使用既有節點容量）。

---

## 暫存目錄

如需暫存檔案，使用 `./tmp`（不使用 `/tmp`）。

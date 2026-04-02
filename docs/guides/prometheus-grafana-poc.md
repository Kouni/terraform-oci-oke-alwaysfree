# Prometheus + Grafana PoC — 手動安裝指南

> **目標：** 在現有 OKE Always Free 叢集上，以 Helm 手動安裝 self-hosted Prometheus 與 Grafana，
> 並透過現有 Cloudflare Tunnel + Cloudflare Access 安全地暴露兩個 Web UI。
>
> **不需要** 修改任何 Terraform 設定。現有的 Grafana Cloud (Alloy) 監控保持不變，兩套並行。

---

## 架構概覽

```
┌─────────────────────────────────────────────────────────┐
│  OKE Cluster (1 node · 4 OCPU · 24 GB RAM · ARM64)      │
│                                                           │
│  namespace: monitoring (現有)                             │
│  ├── alloy (DaemonSet)  ──────────────→ Grafana Cloud    │
│  └── kube-state-metrics                                   │
│                                                           │
│  namespace: observability (新增)                          │
│  ├── prometheus-server (Deployment + PVC 10Gi)           │
│  │     └── scrapes: kubelet, cAdvisor, kube-state-metrics│
│  └── grafana (Deployment + PVC 5Gi)                      │
│        └── datasource → prometheus-server:80             │
│                                                           │
│  namespace: tunnel (現有)                                 │
│  └── cloudflared  ──→ Cloudflare Edge                    │
│                         ├── grafana.your-domain.com       │
│                         └── prometheus.your-domain.com    │
└─────────────────────────────────────────────────────────┘
```

**設計決策：**
- Namespace `observability` 獨立於現有 `monitoring`，互不干擾
- Prometheus chart 的 `kube-state-metrics` 與 `node-exporter` subcharts **停用**，避免與 Alloy 重複
- Prometheus 直接 scrape 現有 `monitoring` namespace 的 kube-state-metrics service
- Storage 使用現有 `nfs` StorageClass（由 136 GB NFS Block Volume 支撐）
- 全部映像檔支援 ARM64 (linux/arm64)，與 VM.Standard.A1.Flex 相容

---

## 前置條件

- [ ] `kubectl` 已設定並可連線叢集（`kubectl get nodes` 正常）
- [ ] `helm` >= 3.x 已安裝（`helm version`）
- [ ] Cloudflare Zero Trust 帳號，且現有 Tunnel 正在運行
- [ ] 目標 domain 的 DNS 由 Cloudflare 管理
- [ ] 兩個空的 subdomain 可用，例如：
  - `grafana.your-domain.com`
  - `prometheus.your-domain.com`

---

## 步驟 1：新增 Helm 倉庫

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```

---

## 步驟 2：建立 Namespace

```bash
kubectl create namespace observability
```

---

## 步驟 3：安裝 Prometheus

### 3.1 準備 values 檔案

建立 `prometheus-values.yaml`（**不要** commit 到 repo，含有 PoC 設定）：

```yaml
# prometheus-values.yaml

# ── 停用不需要的 subcharts ──────────────────────────────────
# kube-state-metrics 已在 monitoring namespace 運行
kube-state-metrics:
  enabled: false

# node-exporter 需要 hostNetwork + hostPID，PoC 先略過
prometheus-node-exporter:
  enabled: false

# ── Prometheus Server ───────────────────────────────────────
server:
  # 資源限制（Always Free 友好）
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      cpu: 500m
      memory: 1Gi

  # 資料保留 7 天（PoC 足夠，節省 NFS 空間）
  retention: "7d"

  # PVC：使用現有 NFS StorageClass
  persistentVolume:
    enabled: true
    storageClass: "nfs"
    size: 10Gi

  # service type（ClusterIP 即可，透過 Tunnel 對外）
  service:
    type: ClusterIP

  # 設定額外 scrape job：scrape 現有 monitoring namespace 的 kube-state-metrics
  extraScrapeConfigs: |
    - job_name: 'kube-state-metrics'
      static_configs:
        - targets: ['kube-state-metrics.monitoring.svc.cluster.local:8080']

# ── Alertmanager ────────────────────────────────────────────
alertmanager:
  enabled: false

# ── Pushgateway ─────────────────────────────────────────────
prometheus-pushgateway:
  enabled: false
```

### 3.2 安裝

```bash
helm install prometheus prometheus-community/prometheus \
  --namespace observability \
  --values prometheus-values.yaml \
  --wait
```

### 3.3 確認 Pod 狀態

```bash
kubectl get pods -n observability
# 預期看到 prometheus-server-XXXX 為 Running
```

---

## 步驟 4：安裝 Grafana

### 4.1 建立 Admin 密碼 Secret

```bash
kubectl create secret generic grafana-admin-secret \
  --namespace observability \
  --from-literal=admin-user=admin \
  --from-literal=admin-password='<YOUR_SECURE_PASSWORD>'
```

> ⚠️ 替換 `<YOUR_SECURE_PASSWORD>` 為你自己的強密碼

### 4.2 準備 values 檔案

建立 `grafana-values.yaml`：

```yaml
# grafana-values.yaml

# ── 從 Secret 讀取 admin 密碼 ───────────────────────────────
admin:
  existingSecret: grafana-admin-secret
  userKey: admin-user
  passwordKey: admin-password

# ── 資源限制 ────────────────────────────────────────────────
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 200m
    memory: 256Mi

# ── PVC：使用現有 NFS StorageClass ──────────────────────────
persistence:
  enabled: true
  storageClassName: "nfs"
  size: 5Gi

# ── Service（ClusterIP，透過 Tunnel 對外）───────────────────
service:
  type: ClusterIP
  port: 80

# ── 預設 Datasource：自動指向 Prometheus ────────────────────
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        url: http://prometheus-server.observability.svc.cluster.local:80
        access: proxy
        isDefault: true

# ── 停用 test pod ────────────────────────────────────────────
testFramework:
  enabled: false
```

### 4.3 安裝

```bash
helm install grafana grafana/grafana \
  --namespace observability \
  --values grafana-values.yaml \
  --wait
```

### 4.4 確認 Pod 狀態

```bash
kubectl get pods -n observability
# 預期看到 grafana-XXXX 為 Running

kubectl get pvc -n observability
# 預期兩個 PVC 都為 Bound
```

---

## 步驟 5：匯入 OKE Dashboard

此 repo 已內建一個針對 OCI Always Free OKE 叢集客製的 dashboard。

### 5.1 取得 dashboard JSON 路徑

```bash
# 在 repo 根目錄
ls modules/monitoring/dashboards/
# oke-cluster-overview.json
```

### 5.2 在 Grafana UI 匯入

1. 打開 Grafana UI（目前可先用 port-forward，等 Tunnel 設好後改用 domain）：
   ```bash
   kubectl port-forward -n observability svc/grafana 3000:80
   # 打開 http://localhost:3000
   ```
2. 登入（帳號 `admin`，密碼為剛才設定的密碼）
3. 左側選單 → **Dashboards** → **Import**
4. 點選 **Upload dashboard JSON file**，選擇 `modules/monitoring/dashboards/oke-cluster-overview.json`
5. 在 "Prometheus" 欄位選擇剛才自動建立的 `Prometheus` datasource
6. 點選 **Import**

> **注意：** 此 dashboard 同時使用 Prometheus 與 Loki datasource。
> Loki 部分在 self-hosted PoC 中沒有設定，相關 panel 會顯示 "No data"，屬正常現象。
> 若要完整顯示，可在 datasources 新增一個 "Loki" datasource 指向 Grafana Cloud Loki endpoint（作為唯讀）。

---

## 步驟 6：Cloudflare Tunnel — 新增 Public Hostname

現有 `cloudflared` Deployment 使用 **Connector Token 模式**（TUNNEL_TOKEN），
Tunnel 的 routing 規則是在 Cloudflare Zero Trust 儀表板上設定的，**不需要修改** 任何 Kubernetes 資源。

### 6.1 進入 Cloudflare Zero Trust 設定

1. 打開 [Cloudflare Zero Trust](https://one.dash.cloudflare.com)
2. 左側選單 → **Networks** → **Tunnels**
3. 找到現有 Tunnel（n8n 使用的那個）→ 點選 **Configure**
4. 切換到 **Public Hostname** 頁籤

### 6.2 新增 Grafana

點選 **Add a public hostname**，填入：

| 欄位 | 值 |
|------|-----|
| Subdomain | `grafana` |
| Domain | `your-domain.com` |
| Type | `HTTP` |
| URL | `grafana.observability.svc.cluster.local:80` |

> Cloudflare 會自動建立 `grafana.your-domain.com` 的 DNS 記錄

### 6.3 新增 Prometheus

再次點選 **Add a public hostname**：

| 欄位 | 值 |
|------|-----|
| Subdomain | `prometheus` |
| Domain | `your-domain.com` |
| Type | `HTTP` |
| URL | `prometheus-server.observability.svc.cluster.local:80` |

### 6.4 驗證 Tunnel

設定儲存後約 30 秒，`cloudflared` Pod 會自動 reload 設定：

```bash
kubectl logs -n tunnel deployment/cloudflared --tail=20
# 應看到 tunnel 連線正常，沒有 error
```

---

## 步驟 7：Cloudflare Access — 設定存取控制

若不設定 Cloudflare Access，任何知道 domain 的人都能存取 UI。
以下設定讓只有特定 email 或 GitHub 帳號能登入。

### 7.1 建立 Access Application（以 Grafana 為例）

1. Cloudflare Zero Trust → **Access** → **Applications** → **Add an application**
2. 選擇 **Self-hosted**
3. 填寫：

   | 欄位 | 值 |
   |------|-----|
   | Application name | `Grafana` |
   | Session Duration | `24 hours`（或依需求） |
   | Application domain | `grafana.your-domain.com` |

4. 點選 **Next**，建立 Policy：

   | 欄位 | 值 |
   |------|-----|
   | Policy name | `Allow Me` |
   | Action | `Allow` |
   | Include | `Emails` → 填入你的 email |

   > 或使用 **GitHub** 作為 Identity Provider，允許特定 GitHub org 成員

5. 點選 **Save**

### 7.2 對 Prometheus 重複上述步驟

Application domain 改為 `prometheus.your-domain.com`，Policy 設定相同。

### 7.3 Identity Provider 設定（如果是首次設定）

若還沒設定 Identity Provider：
1. Zero Trust → **Settings** → **Authentication**
2. 點選 **Add new** → 選擇 **One-time PIN**（最簡單，用 email OTP）
   或選擇 **GitHub**、**Google** 等 OAuth provider

---

## 步驟 8：驗證清單

```bash
# 確認所有 Pod 正常運行
kubectl get pods -n observability

# 確認 PVC 都已 Bound
kubectl get pvc -n observability

# 確認 Prometheus scrape targets 正常
# （用瀏覽器打開 https://prometheus.your-domain.com/targets）

# 確認 Grafana 可登入
# （用瀏覽器打開 https://grafana.your-domain.com）
```

**Prometheus Targets 頁面應看到：**
- `kubernetes-apiservers` — 1/1 UP
- `kubernetes-nodes` — 1/1 UP
- `kubernetes-pods` — 多個 UP
- `kubernetes-service-endpoints` — 多個 UP
- `kube-state-metrics` — 1/1 UP（我們自訂的 scrape job）

**Grafana 應能：**
- 在 Explore 頁面查詢 PromQL，例如：`up{job="kube-state-metrics"}`
- 在 OKE Cluster Overview dashboard 看到 Nodes Ready、Running Pods 等 stat 面板

---

## 資源使用估算

| 工作負載 | CPU request | Memory request |
|----------|-------------|----------------|
| prometheus-server | 200m | 512 Mi |
| grafana | 100m | 128 Mi |
| **新增合計** | **300m** | **640 Mi** |
| 原有工作負載（alloy, ksm, n8n, cloudflared…） | ~700m | ~1.5 GB |
| **全部合計** | **~1 OCPU** | **~2.1 GB** |

剩餘容量：~3 OCPU、~21.9 GB RAM → 充裕。

**Storage（NFS 136 GB）：**
- prometheus-server PVC: 10 Gi
- grafana PVC: 5 Gi
- n8n（現有）: 依現有設定
- 剩餘供未來使用

---

## 升級 / 更新

```bash
# 更新 Helm 倉庫
helm repo update

# 升級 Prometheus
helm upgrade prometheus prometheus-community/prometheus \
  --namespace observability \
  --values prometheus-values.yaml

# 升級 Grafana
helm upgrade grafana grafana/grafana \
  --namespace observability \
  --values grafana-values.yaml
```

---

## 清理（移除 PoC）

```bash
# 移除 Helm releases
helm uninstall prometheus -n observability
helm uninstall grafana -n observability

# 移除 PVC（注意：資料會被刪除）
kubectl delete pvc -n observability --all

# 移除 namespace
kubectl delete namespace observability

# 移除 admin secret（如有建立）
# 上一步刪除 namespace 後已一併刪除

# 在 Cloudflare Zero Trust 儀表板手動移除：
# - Public Hostname: grafana.your-domain.com
# - Public Hostname: prometheus.your-domain.com
# - Access Application: Grafana
# - Access Application: Prometheus
```

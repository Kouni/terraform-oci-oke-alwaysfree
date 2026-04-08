> **DEPRECATED** — HedgeDoc 已被 Docmost 取代。本文件僅供歷史參考。
> 請參閱 [Docmost 部署指南](../guides/docmost-deployment.md)。

---

# HedgeDoc 部署指南

> **目標：** 在現有 OKE Always Free 叢集上，透過 Terraform 部署 HedgeDoc（協作式 Markdown 編輯器），
> 搭配 PostgreSQL 資料庫，並經由現有 Cloudflare Tunnel 對外服務。

---

## 架構概覽

```mermaid
graph TB
    Browser["Browser"]
    CF["Cloudflare Edge<br/>(Zero Trust + Access)"]

    subgraph OKE["OKE Cluster — VM.Standard.A1.Flex (4 OCPU / 24 GB / ARM64)"]

        subgraph NS_TUNNEL["namespace: tunnel (existing)"]
            CFD["cloudflared<br/>(outbound connector)"]
        end

        subgraph NS_HEDGEDOC["namespace: hedgedoc (new)"]
            HD["HedgeDoc<br/>Deployment / Port 3000<br/>NFS PVC (uploads)"]
            PG["PostgreSQL (Bitnami Helm)<br/>Port 5432<br/>NFS PVC (data)"]
        end

    end

    Browser -->|"HTTPS"| CF
    CF -->|"hedgedoc.your-domain.com"| CFD
    CFD -->|"http :3000"| HD
    HD -->|"CMD_DB_URL"| PG

    classDef external fill:#e65100,color:#fff,stroke:#ff6d00,stroke-width:2px
    classDef new_ns fill:#1a237e,color:#fff,stroke:#5c6bc0,stroke-width:1px
    classDef existing fill:#2e7d32,color:#fff,stroke:#66bb6a,stroke-width:1px

    class Browser,CF external
    class HD,PG new_ns
    class CFD existing

    style NS_TUNNEL fill:#1b3a1b,color:#fff,stroke:#66bb6a,stroke-width:1px,stroke-dasharray:4 4
    style NS_HEDGEDOC fill:#0d1b4a,color:#fff,stroke:#5c6bc0,stroke-width:2px
    style OKE fill:#1c2833,color:#fff,stroke:#546e7a,stroke-width:2px,stroke-dasharray:6 4
```

**設計決策：**
- HedgeDoc 1.x（穩定版），不使用仍在開發的 2.x
- PostgreSQL 由 Bitnami Helm chart 管理，NFS StorageClass 儲存資料
- ClusterIP Service，不使用 LoadBalancer（Always Free 無多餘 LB 配額）
- 流量透過既有共用 Cloudflare Tunnel 路由，僅需在 Dashboard 新增一條 Public Hostname

---

## 前置條件

- [ ] `kubectl` 已設定並可連線叢集（`kubectl get nodes` 正常）
- [ ] Terraform 已初始化（`terraform init` 已執行過）
- [ ] 現有 Terraform 已啟用：`enable_nfs_storage = true`、`enable_cloudflare_tunnel = true`
- [ ] Cloudflare Zero Trust 帳號，且現有 Tunnel 正在運行
- [ ] 一個空的 subdomain 可用，例如 `hedgedoc.your-domain.com`

---

## 步驟 1：產生 Secrets

```bash
# PostgreSQL 密碼
PG_PASSWORD=$(openssl rand -base64 24)
echo "PostgreSQL password: $PG_PASSWORD"

# HedgeDoc session secret
SESSION_SECRET=$(openssl rand -hex 32)
echo "Session secret: $SESSION_SECRET"
```

> 請將這兩組值安全保存，後續步驟會用到。

---

## 步驟 2：編輯並套用 K8s Secrets

### 2.1 編輯 Secret 範本

編輯 `k8s/hedgedoc-secrets.yaml`，替換以下欄位：

| 欄位 | 替換為 |
|------|--------|
| `CMD_DB_URL` 中的 `<REPLACE: hedgedoc_pg_password>` | 步驟 1 的 PG_PASSWORD |
| `CMD_SESSION_SECRET` | 步驟 1 的 SESSION_SECRET |
| `CMD_DOMAIN` | 你的實際域名（例如 `hedgedoc.example.com`） |

完成後的 `CMD_DB_URL` 格式：
```
postgres://hedgedoc:YOUR_PG_PASSWORD@hedgedoc-postgresql.hedgedoc.svc.cluster.local:5432/hedgedoc
```

### 2.2 Apply 到叢集

```bash
kubectl apply -f k8s/hedgedoc-namespace.yaml
kubectl apply -f k8s/hedgedoc-secrets.yaml
```

### 2.3 驗證

```bash
kubectl get namespace hedgedoc
kubectl get secret hedgedoc-secrets -n hedgedoc
```

---

## 步驟 3：設定 Terraform 變數

在 `terraform.tfvars` 中新增：

```hcl
enable_hedgedoc      = true
hedgedoc_pg_password = "步驟 1 的 PG_PASSWORD"
```

> **重要：** `hedgedoc_pg_password` 必須與 `k8s/hedgedoc-secrets.yaml` 中 `CMD_DB_URL` 裡的密碼**完全一致**。
> Terraform 用此密碼建立 PostgreSQL，HedgeDoc 用 Secret 中的 `CMD_DB_URL` 連線。兩者不一致會導致連線失敗。

其餘變數可視需要調整（均有預設值）：

| 變數 | 預設值 | 說明 |
|------|--------|------|
| `hedgedoc_namespace` | `hedgedoc` | K8s namespace |
| `hedgedoc_image_tag` | `1.10.2` | HedgeDoc 映像版本 |
| `hedgedoc_pvc_size` | `2Gi` | 上傳檔案 PVC 大小 |
| `hedgedoc_secret_name` | `hedgedoc-secrets` | K8s Secret 名稱 |
| `hedgedoc_pg_pvc_size` | `5Gi` | PostgreSQL PVC 大小 |

---

## 步驟 4：Terraform Apply

```bash
terraform plan
terraform apply
```

預期新增資源：
- `terraform_data.hedgedoc_validation[0]`
- `helm_release.hedgedoc_postgresql[0]`
- `kubernetes_persistent_volume_claim_v1.hedgedoc[0]`
- `kubernetes_deployment_v1.hedgedoc[0]`
- `kubernetes_service_v1.hedgedoc[0]`

---

## 步驟 5：Cloudflare Tunnel — 新增 Public Hostname

1. 打開 [Cloudflare Zero Trust](https://one.dash.cloudflare.com)
2. 左側選單 → **Networks** → **Tunnels**
3. 找到現有 Tunnel → 點選 **Configure** → **Public Hostname** 頁籤
4. 點選 **Add a public hostname**，填入：

| 欄位 | 值 |
|------|-----|
| Subdomain | `hedgedoc` |
| Domain | `your-domain.com` |
| Type | `HTTP` |
| URL | `hedgedoc.hedgedoc.svc.cluster.local:3000` |

> Cloudflare 會自動建立 DNS 記錄。設定儲存後約 30 秒生效。

---

## 步驟 6：Cloudflare Access — 設定存取控制（建議）

若不設定 Access，任何知道 domain 的人都能存取 HedgeDoc。

1. Zero Trust → **Access** → **Applications** → **Add an application**
2. 選擇 **Self-hosted**
3. 填寫：

   | 欄位 | 值 |
   |------|-----|
   | Application name | `HedgeDoc` |
   | Session Duration | `24 hours` |
   | Application domain | `hedgedoc.your-domain.com` |

4. 建立 Policy：

   | 欄位 | 值 |
   |------|-----|
   | Policy name | `Allow Me` |
   | Action | `Allow` |
   | Include | `Emails` → 填入你的 email |

5. 點選 **Save**

---

## 步驟 7：驗證清單

```bash
# 確認所有 Pod 正常運行
kubectl get pods -n hedgedoc

# 確認 PVC 都已 Bound
kubectl get pvc -n hedgedoc

# 檢查 PostgreSQL 日誌
kubectl logs -n hedgedoc -l app.kubernetes.io/name=postgresql --tail=20

# 檢查 HedgeDoc 日誌
kubectl logs -n hedgedoc deploy/hedgedoc --tail=20

# 測試 HTTPS 連線
curl -I https://hedgedoc.your-domain.com
```

**預期結果：**
- PostgreSQL Pod: 1/1 Running
- HedgeDoc Pod: 1/1 Running
- 兩個 PVC: Bound
- `curl` 回傳 HTTP 200 或 302（Cloudflare Access 重導向）

---

## 資源使用估算

| 工作負載 | CPU request | Memory request |
|----------|-------------|----------------|
| hedgedoc-postgresql | 50m | 128 Mi |
| hedgedoc | 100m | 256 Mi |
| **HedgeDoc 合計** | **150m** | **384 Mi** |

**Storage（NFS）：**
- PostgreSQL PVC: 5 Gi（預設）
- HedgeDoc uploads PVC: 2 Gi（預設）
- 合計新增: 7 Gi

---

## 升級

### 升級 HedgeDoc 版本

修改 `terraform.tfvars`：

```hcl
hedgedoc_image_tag = "1.10.3"  # 新版號
```

```bash
terraform apply
```

### 升級 PostgreSQL

PostgreSQL 由 Bitnami Helm chart 管理，Terraform 會處理 Helm release 升級。
升級前請查閱 [Bitnami PostgreSQL chart changelog](https://github.com/bitnami/charts/tree/main/bitnami/postgresql)。

> **注意：** PostgreSQL major version 升級（例如 15 → 16）需要資料遷移，不能直接更新 chart。

---

## 備份

### 資料庫備份

```bash
# 在 Pod 中執行 pg_dump
kubectl exec -n hedgedoc hedgedoc-postgresql-0 -- \
  pg_dump -U hedgedoc hedgedoc > hedgedoc-backup-$(date +%Y%m%d).sql
```

### 還原

```bash
kubectl exec -i -n hedgedoc hedgedoc-postgresql-0 -- \
  psql -U hedgedoc hedgedoc < hedgedoc-backup-YYYYMMDD.sql
```

---

## 注意事項

- `CMD_SESSION_SECRET` 遺失會導致所有現有使用者 session 失效，務必備份
- `hedgedoc_pg_password` 在 `terraform.tfvars` 與 `k8s/hedgedoc-secrets.yaml` 的 `CMD_DB_URL` 中**必須一致**
- HedgeDoc 使用 1.x 穩定版；2.x 仍在開發中，不建議用於 production
- 上傳檔案儲存在 NFS PVC 的 `/hedgedoc/public/uploads`，大小由 `hedgedoc_pvc_size` 控制

---

## 清理（移除 HedgeDoc）

### 1. Terraform

修改 `terraform.tfvars`：

```hcl
enable_hedgedoc = false
```

```bash
terraform apply
```

### 2. 移除 K8s 資源

```bash
# 移除殘留 PVC（Terraform 移除後可能還有 Helm 建立的 PVC）
kubectl delete pvc -n hedgedoc --all

# 移除 Secret 與 Namespace
kubectl delete -f k8s/hedgedoc-secrets.yaml
kubectl delete -f k8s/hedgedoc-namespace.yaml
```

### 3. Cloudflare 清理

在 Cloudflare Zero Trust 儀表板手動移除：
- **Public Hostname**: `hedgedoc.your-domain.com`
- **Access Application**: `HedgeDoc`（如有建立）

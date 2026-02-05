# Root Cause Analysis (RCA): The 502 Mystery

## Executive Summary

The `sycamore-api` deployment enters a `CrashLoopBackOff` state due to an **OOMKilled** (Out of Memory Killed) condition caused by a memory leak in the application code combined with insufficient memory limits.

---

## 1. Issue Discovery

### Initial Symptoms
- Pod repeatedly crashes and enters `CrashLoopBackOff` state
- Service returns 502 Bad Gateway errors intermittently
- Pod restarts frequently with increasing backoff delays

### Diagnostic Commands and Actual Output

#### Step 1: Check Pod Status

```bash
$ kubectl get pods -l app=sycamore-api
NAME                            READY   STATUS             RESTARTS      AGE
sycamore-api-56d69ff686-47khl   0/1     CrashLoopBackOff   2 (22s ago)   40s
```

The pod is in `CrashLoopBackOff` status with multiple restarts.

#### Step 2: Describe Pod for Detailed Events

```bash
$ kubectl describe pod -l app=sycamore-api
Name:             sycamore-api-56d69ff686-47khl
Namespace:        default
Priority:         0
Service Account:  default
Node:             sycamore-control-plane/172.18.0.2
Start Time:       Thu, 05 Feb 2026 19:40:01 +0100
Labels:           app=sycamore-api
                  pod-template-hash=56d69ff686
Status:           Running
IP:               10.244.0.6
Controlled By:  ReplicaSet/sycamore-api-56d69ff686
Containers:
  api:
    Container ID:  containerd://145cecfc764295c903ae167e42100c04ab0da84dbefc9f09735f6c623975c2c6
    Image:         node:18-alpine
    Image ID:      docker.io/library/node@sha256:8d6421d663b4c28fd3ebc498332f249011d118945588d0a35cb9bc4b8ca09d9e
    Port:          <none>
    Host Port:     <none>
    Command:
      node
      -e
      let arr=[]; setInterval(() => { arr.push(new Array(1000000).fill('data')) }, 100)
    State:          Terminated
      Reason:       OOMKilled
      Exit Code:    137
      Started:      Thu, 05 Feb 2026 19:40:46 +0100
      Finished:     Thu, 05 Feb 2026 19:40:46 +0100
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
      Started:      Thu, 05 Feb 2026 19:40:19 +0100
      Finished:     Thu, 05 Feb 2026 19:40:19 +0100
    Ready:          False
    Restart Count:  3
    Limits:
      memory:  64Mi
    Requests:
      memory:     32Mi
Events:
  Type     Reason     Age               From               Message
  ----     ------     ----              ----               -------
  Normal   Scheduled  48s               default-scheduler  Successfully assigned default/sycamore-api-56d69ff686-47khl to sycamore-control-plane
  Normal   Pulled     3s (x4 over 47s)  kubelet            Container image "node:18-alpine" already present on machine
  Normal   Created    3s (x4 over 47s)  kubelet            Created container api
  Normal   Started    3s (x4 over 47s)  kubelet            Started container api
  Warning  BackOff    2s (x4 over 45s)  kubelet            Back-off restarting failed container api in pod sycamore-api-56d69ff686-47khl_default(e41dfb28-d564-4c2a-a76d-c00d17b5be52)
```

**Key Findings:**
- `State: Terminated` with `Reason: OOMKilled` and `Exit Code: 137`
- `Last State` also shows `OOMKilled` - confirming repeated OOM kills
- `Restart Count: 3` - container keeps restarting
- Memory limit is only `64Mi`

#### Step 3: Check Events

```bash
$ kubectl get events --field-selector involvedObject.name=sycamore-api-56d69ff686-47khl --sort-by='.lastTimestamp'
LAST SEEN   TYPE      REASON      OBJECT                              MESSAGE
52s         Normal    Scheduled   pod/sycamore-api-56d69ff686-47khl   Successfully assigned default/sycamore-api-56d69ff686-47khl to sycamore-control-plane
7s          Normal    Pulled      pod/sycamore-api-56d69ff686-47khl   Container image "node:18-alpine" already present on machine
7s          Normal    Created     pod/sycamore-api-56d69ff686-47khl   Created container api
7s          Normal    Started     pod/sycamore-api-56d69ff686-47khl   Started container api
6s          Warning   BackOff     pod/sycamore-api-56d69ff686-47khl   Back-off restarting failed container api in pod sycamore-api-56d69ff686-47khl_default(...)
```

---

## 2. Root Cause Analysis

### Primary Cause: Memory Leak in Application Code

The deployment manifest contains an inline Node.js command that intentionally creates a memory leak:

```javascript
let arr=[];
setInterval(() => {
    arr.push(new Array(1000000).fill('data'))
}, 100)
```

**Analysis:**
- Every 100 milliseconds, the code allocates a new array of 1,000,000 elements filled with the string `'data'`
- Each string 'data' is approximately 4 bytes, plus array overhead
- This results in approximately **8-10 MB** of new memory allocation every 100ms
- The array `arr` is never cleared, causing unbounded memory growth
- **Memory growth rate:** ~80-100 MB per second

### Secondary Cause: Insufficient Memory Limits

```yaml
resources:
  limits:
    memory: "64Mi"
  requests:
    memory: "32Mi"
```

- The container memory limit is set to only **64Mi**
- Given the memory leak rate, the limit is exceeded within **~1 second**
- Kubernetes terminates the container with `OOMKilled` (Exit Code 137) when it exceeds the memory limit

### Why 502 Bad Gateway?

1. Pod starts and begins allocating memory
2. Within ~1 second, memory exceeds 64Mi limit
3. Kubernetes kills the container (OOMKilled, Exit Code 137)
4. During restart, the Service has no healthy endpoints
5. Any incoming requests receive **502 Bad Gateway** from the ingress/load balancer
6. Kubernetes restarts the pod with exponential backoff
7. The cycle repeats indefinitely

---

## 3. Solution

### Changes Made in Fixed Manifest

| Aspect | Before (Broken) | After (Fixed) |
|--------|-----------------|---------------|
| Command | Inline memory leak script | Proper HTTP server application |
| Memory Limit | 64Mi | 256Mi (appropriate for Node.js) |
| Memory Request | 32Mi | 128Mi |
| CPU Limit | None | 500m |
| CPU Request | None | 100m |
| Health Checks | None | Liveness & Readiness probes |
| Port Configuration | Missing | containerPort: 3000 exposed |
| Replicas | 1 | 2 (high availability) |
| Service | None | ClusterIP service on port 80 |

---

## 4. Verification After Fix

### Deploy Fixed Manifest

```bash
$ kubectl apply -f fixed-manifest.yaml
deployment.apps/sycamore-api created
service/sycamore-api created
```

### Verify Pods are Running Stably

```bash
$ kubectl get pods -l app=sycamore-api
NAME                           READY   STATUS    RESTARTS   AGE
sycamore-api-ddc966564-6hwn2   1/1     Running   0          19s
sycamore-api-ddc966564-plhz4   1/1     Running   0          19s
```

Both pods are `Running` with `READY 1/1` and `RESTARTS 0`.

### Verify Pod Details

```bash
$ kubectl describe pod -l app=sycamore-api
Name:             sycamore-api-ddc966564-6hwn2
Namespace:        default
Status:           Running
Containers:
  api:
    State:          Running
      Started:      Thu, 05 Feb 2026 19:41:58 +0100
    Ready:          True
    Restart Count:  0
    Limits:
      cpu:     500m
      memory:  256Mi
    Requests:
      cpu:        100m
      memory:     128Mi
    Liveness:     http-get http://:3000/health delay=10s timeout=5s period=15s #success=1 #failure=3
    Readiness:    http-get http://:3000/ready delay=5s timeout=3s period=10s #success=1 #failure=3
Conditions:
  Type                        Status
  PodReadyToStartContainers   True
  Initialized                 True
  Ready                       True
  ContainersReady             True
  PodScheduled                True
```

### Verify Service

```bash
$ kubectl get svc sycamore-api
NAME           TYPE        CLUSTER-IP    EXTERNAL-IP   PORT(S)   AGE
sycamore-api   ClusterIP   10.96.81.60   <none>        80/TCP    26s
```

### Test Health Endpoint

```bash
$ kubectl run curl-test --image=curlimages/curl --rm -it --restart=Never -- curl -s http://sycamore-api/health
{"status":"healthy","timestamp":"2026-02-05T18:42:57.445Z"}
```

### Test Main Endpoint

```bash
$ kubectl run curl-test --image=curlimages/curl --rm -it --restart=Never -- curl -s http://sycamore-api/
{"message":"Welcome to the Sycamore DevOps Assessment API","status":"Healthy","timestamp":"2026-02-05T18:43:07.456Z"}
```

### Verify Pods Remain Stable

```bash
$ kubectl get pods -l app=sycamore-api  # After 30+ seconds
NAME                           READY   STATUS    RESTARTS   AGE
sycamore-api-ddc966564-6hwn2   1/1     Running   0          106s
sycamore-api-ddc966564-plhz4   1/1     Running   0          106s
```

Pods remain stable with **0 restarts** - confirming the fix is successful.

---

## 5. Prevention Strategies

### Short-term
- Implement mandatory health checks (liveness/readiness probes) for all deployments
- Set appropriate memory limits based on application profiling
- Enable container memory monitoring and alerting

### Long-term
- Implement resource quotas at namespace level
- Use Vertical Pod Autoscaler (VPA) for automatic resource tuning
- Integrate memory leak detection in CI/CD pipelines
- Conduct load testing with memory profiling before production deployment

---

## 6. Timeline

| Time | Event |
|------|-------|
| T+0s | Pod starts, memory leak begins |
| T+1s | Memory exceeds 64Mi limit |
| T+1s | Container OOMKilled (Exit Code 137) |
| T+1s | 502 errors begin (no healthy endpoints) |
| T+10s | First restart (backoff: 10s) |
| T+30s | Second restart (backoff: 20s) |
| T+70s | Third restart (backoff: 40s) |
| ... | Continues with exponential backoff up to 5 minutes |

---

## 7. Lessons Learned

1. **Always review container commands** - Inline commands in manifests should be audited
2. **Resource limits are essential** - But must be appropriate for the workload
3. **Health probes are critical** - They provide visibility into application health and prevent traffic to unhealthy pods
4. **Exit Code 137** - Indicates the container was killed by SIGKILL, typically due to OOM
5. **Monitoring is key** - OOMKilled events should trigger immediate alerts

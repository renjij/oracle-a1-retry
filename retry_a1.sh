#!/usr/bin/env bash
# retry_a1.sh — 触发一次 Resource Manager Apply，尝试创建 Oracle A1 实例
#
# 需要的环境变量：
#   STACK_ID        Resource Manager stack 的 OCID（murphy-a1-vm）
#   COMPARTMENT_ID  实例所在 compartment 的 OCID（root 就是 tenancy OCID）
#
# 退出码：
#   0 = 已有 A1 实例 / 本次创建成功（可以停止重试）
#   2 = Out of capacity（正常，下次再试）
#   1 = 其他错误（需要人工看一下）
set -uo pipefail

: "${STACK_ID:?请设置 STACK_ID}"
: "${COMPARTMENT_ID:?请设置 COMPARTMENT_ID}"
OCI="${OCI_BIN:-oci}"
export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# 1) 已经有未终止的 A1 实例就不再 Apply
count=$($OCI compute instance list --compartment-id "$COMPARTMENT_ID" --all \
  --query 'length(data[?shape==`VM.Standard.A1.Flex` && "lifecycle-state"!=`TERMINATED`])' \
  --raw-output 2>/dev/null || true)
count="${count:-0}"
if [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )); then
  echo "$(ts) ✅ 已存在 $count 台 A1 实例，无需重试。"
  exit 0
fi

# 2) 创建 Apply job 并等待结束
echo "$(ts) ▶ 提交 Apply job ..."
job_json=$($OCI resource-manager job create-apply-job \
  --stack-id "$STACK_ID" \
  --execution-plan-strategy AUTO_APPROVED \
  --display-name "auto-apply-$(date -u +%Y%m%d%H%M)" \
  --wait-for-state SUCCEEDED --wait-for-state FAILED \
  --max-wait-seconds 1200 2>/dev/null)
rc=$?
if (( rc != 0 )) || [[ -z "$job_json" ]]; then
  echo "$(ts) ❌ 提交 job 失败（rc=$rc），检查 API key / STACK_ID。"
  exit 1
fi

read -r job_id state < <(python3 -c '
import sys, json
d = json.load(sys.stdin)["data"]
print(d["id"], d["lifecycle-state"])' <<<"$job_json")

echo "$(ts) job=$job_id state=$state"

if [[ "$state" == "SUCCEEDED" ]]; then
  echo "$(ts) 🎉 Apply 成功，A1 实例已创建！去控制台 Compute → Instances 看公网 IP。"
  exit 0
fi

# 3) 失败：取日志里的错误行
err=$($OCI resource-manager job get-job-logs-content --job-id "$job_id" \
  --query 'data' --raw-output 2>/dev/null | grep -m1 -E 'Error:' || true)
echo "$(ts) ✗ Apply 失败：${err:-（日志里没找到 Error 行）}"

if grep -qi 'Out of host capacity\|Out of capacity' <<<"$err"; then
  exit 2
fi
exit 1

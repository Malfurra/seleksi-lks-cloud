#!/bin/bash
set -uo pipefail

PREFIX="yasin"

echo "==================================================="
echo " VERIFIKASI INFRASTRUKTUR AWS - MATERI 1-7"
echo "==================================================="

if [ -z "$PREFIX" ]; then
  echo "Prefix tidak boleh kosong. Keluar."
  exit 1
fi

PASS=0
FAIL=0

check() {
  local desc="$1"
  local result="$2"
  if [ "$result" == "PASS" ]; then
    echo "[PASS] $desc"
    PASS=$((PASS+1))
  else
    echo "[FAIL] $desc"
    FAIL=$((FAIL+1))
  fi
}

echo ""
echo "--- 1. Amazon EC2 ---"
EC2_IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${PREFIX}*" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" --output text)

if [ -n "$EC2_IDS" ]; then
  check "EC2 instance running ditemukan: $EC2_IDS" "PASS"
else
  check "EC2 instance dengan tag Name=${PREFIX}* dalam status running" "FAIL"
fi

echo ""
echo "--- 2. EC2 Auto Scaling Group ---"
ASG_NAME=$(aws autoscaling describe-auto-scaling-groups \
  --query "AutoScalingGroups[?contains(AutoScalingGroupName, '${PREFIX}')].AutoScalingGroupName | [0]" \
  --output text)

if [ -n "$ASG_NAME" ] && [ "$ASG_NAME" != "None" ]; then
  ASG_DETAIL=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
    --query "AutoScalingGroups[0].[MinSize,MaxSize,DesiredCapacity]" --output text)
  check "ASG '$ASG_NAME' ditemukan (Min/Max/Desired: $ASG_DETAIL)" "PASS"
else
  check "Auto Scaling Group dengan nama mengandung '${PREFIX}'" "FAIL"
fi

echo ""
echo "--- 3. Application Load Balancer ---"
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?contains(LoadBalancerName, '${PREFIX}')].LoadBalancerArn | [0]" --output text)

if [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
  ALB_STATE=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
    --query "LoadBalancers[0].State.Code" --output text)
  ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
    --query "LoadBalancers[0].DNSName" --output text)
  check "ALB ditemukan, state: $ALB_STATE, DNS: $ALB_DNS" "PASS"

  TG_ARN=$(aws elbv2 describe-target-groups --load-balancer-arn "$ALB_ARN" \
    --query "TargetGroups[0].TargetGroupArn" --output text)
  if [ -n "$TG_ARN" ] && [ "$TG_ARN" != "None" ]; then
    HEALTH_PATH=$(aws elbv2 describe-target-groups --target-group-arns "$TG_ARN" \
      --query "TargetGroups[0].HealthCheckPath" --output text)
    TARGET_HEALTH=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
      --query "TargetHealthDescriptions[].TargetHealth.State" --output text)
    check "Target group health check path: $HEALTH_PATH | status target: $TARGET_HEALTH" "PASS"
  else
    check "Target group terpasang pada ALB" "FAIL"
  fi
else
  check "Application Load Balancer dengan nama mengandung '${PREFIX}'" "FAIL"
fi

echo ""
echo "--- 4. Amazon RDS ---"
RDS_ID=$(aws rds describe-db-instances \
  --query "DBInstances[?contains(DBInstanceIdentifier, '${PREFIX}')].DBInstanceIdentifier | [0]" --output text)

if [ -n "$RDS_ID" ] && [ "$RDS_ID" != "None" ]; then
  RDS_DETAIL=$(aws rds describe-db-instances --db-instance-identifier "$RDS_ID" \
    --query "DBInstances[0].[Engine,DBInstanceStatus]" --output text)
  check "RDS instance '$RDS_ID' ditemukan (Engine/Status: $RDS_DETAIL)" "PASS"
else
  check "RDS instance dengan identifier mengandung '${PREFIX}'" "FAIL"
fi

echo ""
echo "--- 5. Amazon S3 ---"
BUCKET=$(aws s3api list-buckets --query "Buckets[?contains(Name, '${PREFIX}')].Name | [0]" --output text)

if [ -n "$BUCKET" ] && [ "$BUCKET" != "None" ]; then
  OBJ_COUNT=$(aws s3 ls "s3://$BUCKET" --recursive | wc -l)
  check "Bucket '$BUCKET' ditemukan, jumlah object: $OBJ_COUNT" "PASS"
else
  check "S3 bucket dengan nama mengandung '${PREFIX}'" "FAIL"
fi

echo ""
echo "--- 6. Amazon CloudWatch ---"
ALARM_NAME=$(aws cloudwatch describe-alarms \
  --query "MetricAlarms[?contains(AlarmName, '${PREFIX}')].AlarmName | [0]" --output text)

if [ -n "$ALARM_NAME" ] && [ "$ALARM_NAME" != "None" ]; then
  ALARM_STATE=$(aws cloudwatch describe-alarms --alarm-names "$ALARM_NAME" \
    --query "MetricAlarms[0].StateValue" --output text)
  check "CloudWatch Alarm '$ALARM_NAME' ditemukan (state: $ALARM_STATE)" "PASS"
else
  check "CloudWatch Alarm dengan nama mengandung '${PREFIX}'" "FAIL"
fi

echo ""
echo "--- 7. Amazon SNS ---"
TOPIC_ARN=$(aws sns list-topics --query "Topics[?contains(TopicArn, '${PREFIX}')].TopicArn | [0]" --output text)

if [ -n "$TOPIC_ARN" ] && [ "$TOPIC_ARN" != "None" ]; then
  SUB_COUNT=$(aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" --query "length(Subscriptions)")
  check "SNS Topic ditemukan ($TOPIC_ARN), jumlah subscription: $SUB_COUNT" "PASS"

  if [ -n "$ALARM_NAME" ] && [ "$ALARM_NAME" != "None" ]; then
    LINKED=$(aws cloudwatch describe-alarms --alarm-names "$ALARM_NAME" \
      --query "MetricAlarms[0].AlarmActions" --output text | grep -c "$TOPIC_ARN" || true)
    if [ "$LINKED" -gt 0 ]; then
      check "CloudWatch Alarm terhubung ke SNS Topic (AlarmActions)" "PASS"
    else
      check "CloudWatch Alarm terhubung ke SNS Topic (AlarmActions)" "FAIL"
    fi
  fi
else
  check "SNS Topic dengan nama mengandung '${PREFIX}'" "FAIL"
fi

echo ""
echo "==================================================="
echo " HASIL AKHIR: $PASS PASS / $((PASS+FAIL)) TOTAL CHECK"
echo "==================================================="

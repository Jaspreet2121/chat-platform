#!/usr/bin/env bash
set -euo pipefail

BOOTSTRAP_SERVER="${KAFKA_BOOTSTRAP_SERVER:-kafka:9092}"
TOPICS_FILE="${TOPICS_FILE:-/topics.env}"

echo "Waiting for Kafka at ${BOOTSTRAP_SERVER}..."

until /opt/bitnami/kafka/bin/kafka-topics.sh \
  --bootstrap-server "${BOOTSTRAP_SERVER}" \
  --list >/dev/null 2>&1; do
  sleep 2
done

echo "Kafka is ready. Creating topics from ${TOPICS_FILE}..."

while IFS=: read -r topic partitions replication; do
  case "${topic}" in
    ""|\#*) continue ;;
  esac

  partitions="${partitions:-3}"
  replication="${replication:-1}"

  echo "Creating topic: ${topic} partitions=${partitions} replication=${replication}"

  /opt/bitnami/kafka/bin/kafka-topics.sh \
    --bootstrap-server "${BOOTSTRAP_SERVER}" \
    --create \
    --if-not-exists \
    --topic "${topic}" \
    --partitions "${partitions}" \
    --replication-factor "${replication}"
done < "${TOPICS_FILE}"

echo "Kafka topics:"
/opt/bitnami/kafka/bin/kafka-topics.sh \
  --bootstrap-server "${BOOTSTRAP_SERVER}" \
  --list

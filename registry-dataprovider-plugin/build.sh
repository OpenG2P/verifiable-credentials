#!/usr/bin/env bash
# Build the plugin JAR WITHOUT installing Java/Maven locally — uses the Maven Docker image.
# Output: target/registry-dataprovider-plugin.jar  (drop into Certify's loader_path)
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p "$HOME/.m2"   # reuse a local Maven cache across builds

docker run --rm \
  -v "$PWD":/work -w /work \
  -v "$HOME/.m2":/root/.m2 \
  maven:3.9-eclipse-temurin-21 \
  mvn -B -DskipTests clean package

echo
echo "Built: $(ls -1 target/registry-dataprovider-plugin.jar)"

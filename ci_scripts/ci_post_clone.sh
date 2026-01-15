#!/bin/bash

# 自定义 Build Number 策略
# 方案 B：基于版本号+CI build number，例如 1.1.51

set -e

cd "$CI_PRIMARY_REPOSITORY_PATH"

# 从 pbxproj 读取 MARKETING_VERSION
VERSION=$(grep -m1 'MARKETING_VERSION' BeadInventory.xcodeproj/project.pbxproj | sed 's/.*= *\([^;]*\);/\1/' | tr -d ' ')
VERSION=${VERSION:-"1.0"}

NEW_BUILD="${VERSION}.${CI_BUILD_NUMBER}"

echo "Setting build number to: $NEW_BUILD"

# 使用 sed 直接替换 CURRENT_PROJECT_VERSION（更安全）
sed -i '' "s/CURRENT_PROJECT_VERSION = [^;]*;/CURRENT_PROJECT_VERSION = ${NEW_BUILD};/g" BeadInventory.xcodeproj/project.pbxproj

echo "Build number updated successfully"

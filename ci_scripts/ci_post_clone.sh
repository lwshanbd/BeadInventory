#!/bin/bash

set -e

echo "=== ci_post_clone.sh started ==="
echo "CI_BUILD_NUMBER: ${CI_BUILD_NUMBER}"
echo "CI_PRIMARY_REPOSITORY_PATH: ${CI_PRIMARY_REPOSITORY_PATH}"

cd "$CI_PRIMARY_REPOSITORY_PATH"

# 从 pbxproj 读取 MARKETING_VERSION
VERSION=$(grep 'MARKETING_VERSION' BeadInventory.xcodeproj/project.pbxproj | head -1 | sed 's/.*= *//' | sed 's/;.*//' | tr -d ' "')
echo "Detected VERSION: ${VERSION}"

VERSION=${VERSION:-"1.0"}
NEW_BUILD="${VERSION}.${CI_BUILD_NUMBER}"

echo "NEW_BUILD will be: ${NEW_BUILD}"

# 使用 sed 直接替换 CURRENT_PROJECT_VERSION
sed -i '' "s/CURRENT_PROJECT_VERSION = [^;]*;/CURRENT_PROJECT_VERSION = \"${NEW_BUILD}\";/g" BeadInventory.xcodeproj/project.pbxproj

# 验证修改
echo "Verifying changes:"
grep 'CURRENT_PROJECT_VERSION' BeadInventory.xcodeproj/project.pbxproj | head -2

echo "=== ci_post_clone.sh completed ==="

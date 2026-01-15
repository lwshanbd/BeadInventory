#!/bin/bash

# 自定义 Build Number 策略
# 方案 B：基于版本号+CI build number，例如 1.1.51

VERSION=$(/usr/libexec/PlistBuddy -c "Print MARKETING_VERSION" "${PROJECT_DIR}/${INFOPLIST_FILE}" 2>/dev/null || echo "1.0")
NEW_BUILD="${VERSION}.${CI_BUILD_NUMBER}"

# 更新项目中的 build number
if [ -n "$CI_BUILD_NUMBER" ]; then
    echo "Setting build number to: $NEW_BUILD"

    # 更新 pbxproj 文件中的 CURRENT_PROJECT_VERSION
    cd "$CI_PRIMARY_REPOSITORY_PATH"
    agvtool new-version -all "$NEW_BUILD"
fi

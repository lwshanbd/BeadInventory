//
//  TutorialContent.swift
//  BeadInventory
//
//  教程内容数据源
//

import SwiftUI

// MARK: - 数据模型

enum HelpDestination: Hashable {
    case quickStart
    case inventory
    case scan
    case scanAPISetup
    case plans
    case colorConverter
    case data
    case faq

    @ViewBuilder
    var targetView: some View {
        switch self {
        case .quickStart:
            TutorialDetailView(section: TutorialContent.quickStart)
        case .inventory:
            TutorialDetailView(section: TutorialContent.inventory)
        case .scan:
            TutorialDetailView(section: TutorialContent.scan)
        case .scanAPISetup:
            TutorialDetailView(section: TutorialContent.scan, highlightStep: .scanAPISetup)
        case .plans:
            TutorialDetailView(section: TutorialContent.plans)
        case .colorConverter:
            TutorialDetailView(section: TutorialContent.colorTools)
        case .data:
            TutorialDetailView(section: TutorialContent.dataAndSync)
        case .faq:
            FAQView()
        }
    }
}

struct TutorialSection: Identifiable {
    let id = UUID()
    let icon: String
    let titleKey: String
    let subtitleKey: String
    let searchKeywords: [String]
    let steps: [TutorialStep]

    var localizedTitle: String {
        String(localized: String.LocalizationValue(titleKey))
    }

    var localizedSubtitle: String {
        String(localized: String.LocalizationValue(subtitleKey))
    }
}

struct StepAction {
    let labelKey: String
    let destination: HelpDestination
}

struct TutorialStep: Identifiable {
    let id = UUID()
    let titleKey: String
    let descriptionKey: String
    let imageName: String?
    let searchKeywords: [String]
    let anchor: HelpDestination?
    let action: StepAction?

    init(titleKey: String, descriptionKey: String, imageName: String? = nil, searchKeywords: [String] = [], anchor: HelpDestination? = nil, action: StepAction? = nil) {
        self.titleKey = titleKey
        self.descriptionKey = descriptionKey
        self.imageName = imageName
        self.searchKeywords = searchKeywords
        self.anchor = anchor
        self.action = action
    }

    var localizedTitle: String {
        String(localized: String.LocalizationValue(titleKey))
    }

    var localizedDescription: String {
        String(localized: String.LocalizationValue(descriptionKey))
    }
}

struct FAQItem: Identifiable {
    let id = UUID()
    let questionKey: String
    let answerKey: String
    let searchKeywords: [String]

    var localizedQuestion: String {
        String(localized: String.LocalizationValue(questionKey))
    }

    var localizedAnswer: String {
        String(localized: String.LocalizationValue(answerKey))
    }
}

// MARK: - 内容

enum TutorialContent {

    static let sections: [TutorialSection] = [
        quickStart,
        inventory,
        scan,
        plans,
        colorTools,
        dataAndSync
    ]

    // MARK: 快速开始

    static let quickStart = TutorialSection(
        icon: "rocket.fill",
        titleKey: "help.quickstart.title",
        subtitleKey: "help.quickstart.subtitle",
        searchKeywords: ["快速开始", "新手", "入门", "quick start", "getting started", "beginner"],
        steps: [
            TutorialStep(
                titleKey: "help.quickstart.step1.title",
                descriptionKey: "help.quickstart.step1.description",
                searchKeywords: ["品牌", "添加", "brand", "add"]
            ),
            TutorialStep(
                titleKey: "help.quickstart.step2.title",
                descriptionKey: "help.quickstart.step2.description",
                searchKeywords: ["库存", "初始", "inventory", "initial", "stock"]
            ),
            TutorialStep(
                titleKey: "help.quickstart.step3.title",
                descriptionKey: "help.quickstart.step3.description",
                searchKeywords: ["扫描", "图纸", "scan", "image", "recognize"],
                action: StepAction(labelKey: "help.quickstart.step3.action", destination: .scan)
            ),
            TutorialStep(
                titleKey: "help.quickstart.step4.title",
                descriptionKey: "help.quickstart.step4.description",
                searchKeywords: ["库存", "变化", "扣减", "inventory", "change", "deduct"]
            )
        ]
    )

    // MARK: 库存管理

    static let inventory = TutorialSection(
        icon: "square.grid.3x3.fill",
        titleKey: "help.inventory.title",
        subtitleKey: "help.inventory.subtitle",
        searchKeywords: ["库存", "管理", "色号", "inventory", "stock", "manage"],
        steps: [
            TutorialStep(
                titleKey: "help.inventory.view.title",
                descriptionKey: "help.inventory.view.description",
                searchKeywords: ["查看", "库存", "view", "inventory"]
            ),
            TutorialStep(
                titleKey: "help.inventory.edit.title",
                descriptionKey: "help.inventory.edit.description",
                searchKeywords: ["编辑", "修改", "edit", "modify", "stock"]
            ),
            TutorialStep(
                titleKey: "help.inventory.search.title",
                descriptionKey: "help.inventory.search.description",
                searchKeywords: ["搜索", "色号", "search", "color code"]
            ),
            TutorialStep(
                titleKey: "help.inventory.lowstock.title",
                descriptionKey: "help.inventory.lowstock.description",
                searchKeywords: ["低库存", "提醒", "预警", "low stock", "alert", "warning"]
            ),
            TutorialStep(
                titleKey: "help.inventory.filter.title",
                descriptionKey: "help.inventory.filter.description",
                searchKeywords: ["筛选", "品牌", "排序", "filter", "brand", "sort"]
            )
        ]
    )

    // MARK: AI 扫描识别

    static let scan = TutorialSection(
        icon: "doc.text.viewfinder",
        titleKey: "help.scan.title",
        subtitleKey: "help.scan.subtitle",
        searchKeywords: ["扫描", "识别", "AI", "图纸", "scan", "recognize", "image"],
        steps: [
            TutorialStep(
                titleKey: "help.scan.prepare.title",
                descriptionKey: "help.scan.prepare.description",
                searchKeywords: ["准备", "图片", "效果", "prepare", "image", "quality"]
            ),
            TutorialStep(
                titleKey: "help.scan.apisetup.title",
                descriptionKey: "help.scan.apisetup.description",
                searchKeywords: ["API", "配置", "设置", "本地模型", "云端", "configure", "setup", "local model", "cloud", "key", "Kimi", "OpenAI", "Anthropic"],
                anchor: .scanAPISetup
            ),
            TutorialStep(
                titleKey: "help.scan.localmodel.title",
                descriptionKey: "help.scan.localmodel.description",
                searchKeywords: ["本地模型", "下载", "离线", "local model", "download", "offline"]
            ),
            TutorialStep(
                titleKey: "help.scan.cloudapi.title",
                descriptionKey: "help.scan.cloudapi.description",
                searchKeywords: ["云端", "API", "key", "Kimi", "OpenAI", "Anthropic", "Qwen", "Gemini", "cloud"]
            ),
            TutorialStep(
                titleKey: "help.scan.crop.title",
                descriptionKey: "help.scan.crop.description",
                imageName: "HelpNew2",
                searchKeywords: ["裁切", "裁剪", "crop", "trim"]
            ),
            TutorialStep(
                titleKey: "help.scan.editresult.title",
                descriptionKey: "help.scan.editresult.description",
                searchKeywords: ["编辑", "结果", "修改", "edit", "result", "modify"]
            ),
            TutorialStep(
                titleKey: "help.scan.afterresult.title",
                descriptionKey: "help.scan.afterresult.description",
                searchKeywords: ["扣减", "计划", "deduct", "plan", "confirm"]
            )
        ]
    )

    // MARK: 项目计划

    static let plans = TutorialSection(
        icon: "calendar.badge.clock",
        titleKey: "help.plans.title",
        subtitleKey: "help.plans.subtitle",
        searchKeywords: ["计划", "项目", "plan", "project"],
        steps: [
            TutorialStep(
                titleKey: "help.plans.what.title",
                descriptionKey: "help.plans.what.description",
                searchKeywords: ["什么", "计划", "what", "plan"]
            ),
            TutorialStep(
                titleKey: "help.plans.merge.title",
                descriptionKey: "help.plans.merge.description",
                searchKeywords: ["合并", "merge", "combine"]
            ),
            TutorialStep(
                titleKey: "help.plans.archive.title",
                descriptionKey: "help.plans.archive.description",
                searchKeywords: ["归档", "完成", "archive", "finish", "complete"]
            ),
            TutorialStep(
                titleKey: "help.plans.replenish.title",
                descriptionKey: "help.plans.replenish.description",
                searchKeywords: ["补豆", "建议", "replenish", "suggestion", "recommend"]
            ),
            TutorialStep(
                titleKey: "help.plans.directpurchase.title",
                descriptionKey: "help.plans.directpurchase.description",
                searchKeywords: ["直接补豆", "采购", "购买", "direct purchase", "buy"]
            )
        ]
    )

    // MARK: 色号工具

    static let colorTools = TutorialSection(
        icon: "paintpalette.fill",
        titleKey: "help.colortools.title",
        subtitleKey: "help.colortools.subtitle",
        searchKeywords: ["色号", "转换", "工具", "color", "convert", "tool"],
        steps: [
            TutorialStep(
                titleKey: "help.colortools.convert.title",
                descriptionKey: "help.colortools.convert.description",
                searchKeywords: ["色号", "转换", "对照", "MARD", "vivid", "漫漫", "卡卡", "color", "convert", "cross-brand"]
            ),
            TutorialStep(
                titleKey: "help.colortools.custom.title",
                descriptionKey: "help.colortools.custom.description",
                searchKeywords: ["自定义", "色号", "custom", "color"]
            ),
            TutorialStep(
                titleKey: "help.colortools.hide.title",
                descriptionKey: "help.colortools.hide.description",
                searchKeywords: ["隐藏", "色号", "hide", "color"]
            )
        ]
    )

    // MARK: 数据与同步

    static let dataAndSync = TutorialSection(
        icon: "externaldrive.badge.icloud",
        titleKey: "help.data.title",
        subtitleKey: "help.data.subtitle",
        searchKeywords: ["数据", "同步", "备份", "iCloud", "data", "sync", "backup"],
        steps: [
            TutorialStep(
                titleKey: "help.data.icloud.title",
                descriptionKey: "help.data.icloud.description",
                searchKeywords: ["iCloud", "同步", "多设备", "sync", "multi-device"]
            ),
            TutorialStep(
                titleKey: "help.data.backup.title",
                descriptionKey: "help.data.backup.description",
                searchKeywords: ["备份", "自动", "backup", "auto"]
            ),
            TutorialStep(
                titleKey: "help.data.restore.title",
                descriptionKey: "help.data.restore.description",
                searchKeywords: ["恢复", "restore", "recovery"]
            ),
            TutorialStep(
                titleKey: "help.data.export.title",
                descriptionKey: "help.data.export.description",
                searchKeywords: ["导出", "CSV", "JSON", "分享", "export", "share"]
            )
        ]
    )

    // MARK: FAQ

    static let faqItems: [FAQItem] = [
        FAQItem(questionKey: "help.faq.scanaccuracy.question", answerKey: "help.faq.scanaccuracy.answer", searchKeywords: ["扫描", "识别", "不准", "scan", "accuracy", "inaccurate"]),
        FAQItem(questionKey: "help.faq.dataloss.question", answerKey: "help.faq.dataloss.answer", searchKeywords: ["数据", "丢失", "安全", "data", "loss", "safe"]),
        FAQItem(questionKey: "help.faq.multisync.question", answerKey: "help.faq.multisync.answer", searchKeywords: ["多设备", "同步", "multi-device", "sync"]),
        FAQItem(questionKey: "help.faq.whatisapi.question", answerKey: "help.faq.whatisapi.answer", searchKeywords: ["API", "什么", "为什么", "配置", "what", "why", "configure"]),
        FAQItem(questionKey: "help.faq.localvscloud.question", answerKey: "help.faq.localvscloud.answer", searchKeywords: ["本地", "云端", "区别", "local", "cloud", "difference"]),
        FAQItem(questionKey: "help.faq.brands.question", answerKey: "help.faq.brands.answer", searchKeywords: ["品牌", "支持", "MARD", "vivid", "brand", "support"]),
        FAQItem(questionKey: "help.faq.contact.question", answerKey: "help.faq.contact.answer", searchKeywords: ["联系", "反馈", "开发者", "contact", "feedback", "developer"])
    ]

    // MARK: - 搜索

    static func search(query: String) -> [TutorialStep] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        var results: [TutorialStep] = []
        for section in sections {
            for step in section.steps {
                let matchesTitle = step.localizedTitle.localizedCaseInsensitiveContains(query)
                let matchesDescription = step.localizedDescription.localizedCaseInsensitiveContains(query)
                let matchesKeywords = step.searchKeywords.contains { $0.localizedCaseInsensitiveContains(query) }
                let matchesSectionKeywords = section.searchKeywords.contains { $0.localizedCaseInsensitiveContains(query) }

                if matchesTitle || matchesDescription || matchesKeywords || matchesSectionKeywords {
                    results.append(step)
                }
            }
        }
        return results
    }

    static func searchFAQ(query: String) -> [FAQItem] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return faqItems }

        return faqItems.filter { item in
            item.localizedQuestion.localizedCaseInsensitiveContains(query) ||
            item.localizedAnswer.localizedCaseInsensitiveContains(query) ||
            item.searchKeywords.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
}

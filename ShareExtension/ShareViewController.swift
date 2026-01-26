//
//  ShareViewController.swift
//  ShareExtension
//
//  Share Extension 视图控制器 - 处理从其他 App 分享的图片
//

import UIKit
import UniformTypeIdentifiers

class ShareViewController: UIViewController {

    /// App Group 标识符 - 必须与主 App 中的配置一致
    static let appGroupIdentifier = "group.com.beadinventory.shared"

    /// 共享图片的文件名
    private let sharedImageFileName = "shared_image.jpg"

    /// 标记文件名
    private let pendingFlagFileName = "pending_image"

    // UI 元素
    private var containerView: UIView!
    private var imageView: UIImageView!
    private var loadingIndicator: UIActivityIndicatorView!
    private var titleLabel: UILabel!
    private var subtitleLabel: UILabel!
    private var cancelButton: UIButton!
    private var confirmButton: UIButton!

    private var selectedImage: UIImage?

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadSharedImage()
    }

    // MARK: - UI Setup

    private func setupUI() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.5)

        // 内容容器
        containerView = UIView()
        containerView.backgroundColor = .systemBackground
        containerView.layer.cornerRadius = 20
        containerView.clipsToBounds = true
        containerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(containerView)

        // 标题
        titleLabel = UILabel()
        titleLabel.text = "啃豆小仓"
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(titleLabel)

        // 副标题
        subtitleLabel = UILabel()
        subtitleLabel.text = "将图片发送到扫描界面"
        subtitleLabel.font = .systemFont(ofSize: 14)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(subtitleLabel)

        // 图片预览
        imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .secondarySystemBackground
        imageView.layer.cornerRadius = 12
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(imageView)

        // 加载指示器
        loadingIndicator = UIActivityIndicatorView(style: .large)
        loadingIndicator.hidesWhenStopped = true
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(loadingIndicator)

        // 按钮容器
        let buttonStack = UIStackView()
        buttonStack.axis = .horizontal
        buttonStack.spacing = 12
        buttonStack.distribution = .fillEqually
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(buttonStack)

        // 取消按钮
        cancelButton = UIButton(type: .system)
        cancelButton.setTitle("取消", for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
        cancelButton.backgroundColor = .secondarySystemBackground
        cancelButton.layer.cornerRadius = 12
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        buttonStack.addArrangedSubview(cancelButton)

        // 确认按钮
        confirmButton = UIButton(type: .system)
        confirmButton.setTitle("发送到扫描", for: .normal)
        confirmButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        confirmButton.backgroundColor = .systemBlue
        confirmButton.setTitleColor(.white, for: .normal)
        confirmButton.layer.cornerRadius = 12
        confirmButton.addTarget(self, action: #selector(confirmTapped), for: .touchUpInside)
        confirmButton.isEnabled = false
        buttonStack.addArrangedSubview(confirmButton)

        // 约束
        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            containerView.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            subtitleLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            imageView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 16),
            imageView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            imageView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            imageView.heightAnchor.constraint(equalToConstant: 250),

            loadingIndicator.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),

            buttonStack.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 20),
            buttonStack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            buttonStack.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            buttonStack.heightAnchor.constraint(equalToConstant: 50),
            buttonStack.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -20)
        ])
    }

    // MARK: - Load Shared Image

    private func loadSharedImage() {
        loadingIndicator.startAnimating()

        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = extensionItem.attachments else {
            showError("无法获取分享内容")
            return
        }

        // 查找图片附件
        for attachment in attachments {
            // 检查是否为图片类型
            if attachment.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                attachment.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { [weak self] (item, error) in
                    DispatchQueue.main.async {
                        self?.loadingIndicator.stopAnimating()

                        if let error = error {
                            self?.showError("加载图片失败: \(error.localizedDescription)")
                            return
                        }

                        var image: UIImage?

                        if let url = item as? URL {
                            // 从文件 URL 加载
                            if let data = try? Data(contentsOf: url) {
                                image = UIImage(data: data)
                            }
                        } else if let data = item as? Data {
                            // 直接从数据加载
                            image = UIImage(data: data)
                        } else if let loadedImage = item as? UIImage {
                            // 直接是 UIImage
                            image = loadedImage
                        }

                        if let image = image {
                            self?.selectedImage = image
                            self?.imageView.image = image
                            self?.confirmButton.isEnabled = true
                            self?.confirmButton.alpha = 1.0
                        } else {
                            self?.showError("无法解析图片")
                        }
                    }
                }
                return
            }
        }

        loadingIndicator.stopAnimating()
        showError("未找到图片")
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    @objc private func confirmTapped() {
        guard let image = selectedImage else { return }

        // 禁用按钮防止重复点击
        confirmButton.isEnabled = false

        // 保存图片到共享容器
        if saveImageToSharedContainer(image) {
            // 显示成功提示
            showSuccess()
        } else {
            showError("保存图片失败，请重试")
            confirmButton.isEnabled = true
        }
    }

    // MARK: - Success Handling

    private func showSuccess() {
        // 更新 UI 显示成功状态
        titleLabel.text = "已保存"
        subtitleLabel.text = "请打开「啃豆小仓」App 查看\n（请确保 App 正在运行）"
        subtitleLabel.numberOfLines = 0
        subtitleLabel.textColor = .systemGreen

        // 更新图片视图显示成功图标
        imageView.image = nil
        imageView.backgroundColor = .systemGreen.withAlphaComponent(0.1)

        let checkmark = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
        checkmark.tintColor = .systemGreen
        checkmark.contentMode = .scaleAspectFit
        checkmark.translatesAutoresizingMaskIntoConstraints = false
        imageView.addSubview(checkmark)

        NSLayoutConstraint.activate([
            checkmark.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            checkmark.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
            checkmark.widthAnchor.constraint(equalToConstant: 80),
            checkmark.heightAnchor.constraint(equalToConstant: 80)
        ])

        // 隐藏取消按钮，更新确认按钮为"完成"
        cancelButton.isHidden = true
        confirmButton.setTitle("完成", for: .normal)
        confirmButton.isEnabled = true
        confirmButton.backgroundColor = .systemGreen
        confirmButton.removeTarget(self, action: #selector(confirmTapped), for: .touchUpInside)
        confirmButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
    }

    @objc private func doneTapped() {
        completeExtension()
    }

    // MARK: - Save Image

    private func saveImageToSharedContainer(_ image: UIImage) -> Bool {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else {
            print("ShareExtension: 无法获取 App Group 容器")
            return false
        }

        let imageURL = containerURL.appendingPathComponent(sharedImageFileName)
        let flagURL = containerURL.appendingPathComponent(pendingFlagFileName)

        // 压缩图片
        guard let imageData = image.jpegData(compressionQuality: 0.9) else {
            print("ShareExtension: 图片压缩失败")
            return false
        }

        do {
            // 保存图片
            try imageData.write(to: imageURL)

            // 创建待处理标记
            try Data().write(to: flagURL)

            print("ShareExtension: 图片已保存，大小: \(imageData.count) bytes")
            return true
        } catch {
            print("ShareExtension: 保存失败 - \(error.localizedDescription)")
            return false
        }
    }

    private func completeExtension() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    // MARK: - Error Handling

    private func showError(_ message: String) {
        subtitleLabel.text = message
        subtitleLabel.textColor = .systemRed
        confirmButton.isEnabled = false
        confirmButton.alpha = 0.5
    }
}

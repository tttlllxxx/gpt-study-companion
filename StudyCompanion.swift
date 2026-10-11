import AppKit
import UniformTypeIdentifiers
import WebKit

private let welcomeDocumentURL = Bundle.main.url(forResource: "Welcome", withExtension: "md")!
private let lastDocumentPathKey = "lastDocumentPath"
private let lastDocumentRootPathKey = "lastDocumentRootPath"
private let lastChatURLKey = "lastChatURL"
private let sidebarHiddenKey = "sidebarHidden"
private let readingPositionsKey = "readingPositions"
private let outlineVisibleKey = "outlineVisible"

final class DocumentNode: NSObject {
    let url: URL
    let isFolder: Bool
    var children: [DocumentNode] = []

    init(url: URL, isFolder: Bool) {
        self.url = url
        self.isFolder = isFolder
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var editor: NSTextView!
    private var editorScrollView: NSScrollView!
    private var previewWebView: WKWebView!
    private var webView: WKWebView!
    private var viewModeControl: NSSegmentedControl!
    private var askField: NSTextField!
    private var searchField: NSSearchField!
    private var statusLabel: NSTextField!
    private var documentTitleLabel: NSTextField!
    private var documentPathLabel: NSTextField!
    private var documentSearchRow: NSView!
    private var outlineToggleButton: NSButton!
    private var outlineVisible = true
    private var testReadingPositions: [String: [String: Any]] = [:]
    private var documentListView: NSOutlineView!
    private var libraryTitleLabel: NSTextField!
    private var workspaceController: NSSplitViewController!
    private var sidebarItem: NSSplitViewItem!
    private var sidebarToggleButton: NSButton!
    private var rootNodes: [DocumentNode] = []
    private var synchronizingSelection = false
    private var savedText = ""
    private var documentURL = welcomeDocumentURL
    private var closingWindow = false
    private var testUnsavedDecision: NSApplication.ModalResponse?
    private var documentRootURL: URL?
    private var documentFiles: [URL] = []
    private var lastKnownModificationDate: Date?
    private var attachmentButton: NSButton!
    private var testingChatAttachment = false
    private var testingReaderStyle = false
    private var readingNavigationTestPhase = 0
    private var readingTestBookmark: [String: Any]?
    private var readingTestMarkdown = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !CommandLine.arguments.contains("--self-test"), UserDefaults.standard.object(forKey: outlineVisibleKey) != nil {
            outlineVisible = UserDefaults.standard.bool(forKey: outlineVisibleKey)
        }
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            NSApp.applicationIconImage = NSImage(contentsOf: iconURL)
        }
        if CommandLine.arguments.contains("--test-session-write") || CommandLine.arguments.contains("--test-session-read") {
            runSessionPersistenceTest()
            return
        }
        buildWindow()
        buildMenu()
        if CommandLine.arguments.contains("--test-reading-write") || CommandLine.arguments.contains("--test-reading-read") {
            DispatchQueue.main.async { self.runReadingNavigationTests() }
            return
        }
        if CommandLine.arguments.contains("--self-test") {
            DispatchQueue.main.async { self.runSelfTests() }
            return
        }
        restoreDocumentLibrary()
        loadDocument()
        loadChatGPT()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        rememberChatURL()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !closingWindow && !isTestRun && !prepareToSwitchDocument(action: "退出应用") { return .terminateCancel }
        guard let previewWebView else { return .terminateNow }
        previewWebView.evaluateJavaScript("window.readerNavigation ? window.readerNavigation.getPosition() : null") { [weak self] result, _ in
            if let position = result as? [String: Any] { self?.saveReadingPosition(position) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isTestRun || prepareToSwitchDocument(action: "关闭窗口") else { return false }
        closingWindow = true
        return true
    }

    private var isTestRun: Bool {
        CommandLine.arguments.contains("--self-test") || CommandLine.arguments.contains("--test-reading-write") || CommandLine.arguments.contains("--test-reading-read")
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "GPT 学习伴侣"
        window.delegate = self
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 920, height: 620)
        window.center()

        let rootController = NSViewController()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1440, height: 870))
        rootController.view = root
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        window.contentViewController = rootController

        workspaceController = NSSplitViewController()
        workspaceController.splitView.isVertical = true
        workspaceController.splitView.dividerStyle = .paneSplitter
        rootController.addChild(workspaceController)

        let sidebarController = NSViewController()
        sidebarController.view = makeDocumentLibraryPane()
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 160
        sidebarItem.maximumThickness = 420
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = .init(260)
        workspaceController.addSplitViewItem(sidebarItem)

        let documentController = NSViewController()
        documentController.view = makeDocumentPane()
        let documentItem = NSSplitViewItem(viewController: documentController)
        documentItem.minimumThickness = 280
        workspaceController.addSplitViewItem(documentItem)

        let chatController = NSViewController()
        chatController.view = makeChatPane()
        let chatItem = NSSplitViewItem(viewController: chatController)
        chatItem.minimumThickness = 320
        workspaceController.addSplitViewItem(chatItem)

        let splitView = workspaceController.view
        splitView.translatesAutoresizingMaskIntoConstraints = false
        let ribbon = makeRibbon()
        root.addSubview(ribbon)
        root.addSubview(splitView)
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: root.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: ribbon.trailingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -5),
            statusLabel.heightAnchor.constraint(equalToConstant: 16),
            ribbon.topAnchor.constraint(equalTo: root.topAnchor),
            ribbon.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            ribbon.bottomAnchor.constraint(equalTo: splitView.bottomAnchor),
            ribbon.widthAnchor.constraint(equalToConstant: 44)
        ])

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window.contentView?.layoutSubtreeIfNeeded()
            let split = self.workspaceController.splitView
            split.setPosition(230, ofDividerAt: 0)
            split.setPosition(split.bounds.width * 0.64, ofDividerAt: 1)
            if !CommandLine.arguments.contains("--self-test") {
                self.sidebarItem.isCollapsed = UserDefaults.standard.bool(forKey: sidebarHiddenKey)
            }
            self.updateSidebarButton()
        }
    }

    private func makeRibbon() -> NSView {
        let ribbon = NSView()
        ribbon.translatesAutoresizingMaskIntoConstraints = false
        ribbon.wantsLayer = true
        ribbon.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        sidebarToggleButton = makeIconButton("sidebar.leading", help: "收起侧栏（⌘\\）", action: #selector(toggleSidebar))
        sidebarToggleButton.keyEquivalent = "\\"
        sidebarToggleButton.keyEquivalentModifierMask = .command
        let actions = NSStackView(views: [
            sidebarToggleButton,
            makeIconButton("folder", help: "打开文档目录", action: #selector(chooseDocumentDirectory))
        ])
        actions.orientation = .vertical
        actions.spacing = 10
        actions.translatesAutoresizingMaskIntoConstraints = false
        ribbon.addSubview(actions)
        NSLayoutConstraint.activate([
            actions.topAnchor.constraint(equalTo: ribbon.topAnchor, constant: 14),
            actions.centerXAnchor.constraint(equalTo: ribbon.centerXAnchor)
        ])
        return ribbon
    }

    private func makeToolbar() -> NSStackView {
        searchField = NSSearchField()
        searchField.placeholderString = "在文档中查找"
        searchField.target = self
        searchField.action = #selector(findNext)
        searchField.controlSize = .small
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [
            searchField,
            makeIconButton("chevron.down", help: "查找下一处", action: #selector(findNext)),
            makeIconButton("xmark", help: "关闭文档搜索", action: #selector(toggleDocumentSearch))
        ])
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func makeDocumentPane() -> NSView {
        let container = NSView()
        documentTitleLabel = NSTextField(labelWithString: "")
        documentTitleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        documentTitleLabel.lineBreakMode = .byTruncatingMiddle
        documentTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let documentIcon = NSImageView(image: NSImage(systemSymbolName: "doc.text", accessibilityDescription: "当前文档")!)
        documentIcon.contentTintColor = .secondaryLabelColor
        documentIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true

        viewModeControl = NSSegmentedControl(labels: ["阅读", "编辑"], trackingMode: .selectOne, target: self, action: #selector(changeDocumentMode))
        viewModeControl.selectedSegment = 0
        viewModeControl.controlSize = .small
        attachmentButton = makeButton("加入聊天", action: #selector(attachCurrentDocument))
        attachmentButton.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: nil)
        attachmentButton.imagePosition = .imageLeading
        attachmentButton.bezelStyle = .inline
        attachmentButton.controlSize = .small
        attachmentButton.toolTip = "将当前文档全文作为附件加入右侧 ChatGPT（含未保存的修改）"

        let titleRow = NSStackView(views: [documentIcon, documentTitleLabel, flexibleSpace(), attachmentButton, viewModeControl])
        titleRow.spacing = 8
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        let tabStrip = NSBox()
        tabStrip.boxType = .custom
        tabStrip.borderWidth = 0
        tabStrip.fillColor = .windowBackgroundColor
        tabStrip.contentViewMargins = .zero
        tabStrip.addSubview(titleRow)
        tabStrip.heightAnchor.constraint(equalToConstant: 42).isActive = true
        NSLayoutConstraint.activate([
            titleRow.leadingAnchor.constraint(equalTo: tabStrip.leadingAnchor, constant: 14),
            titleRow.trailingAnchor.constraint(equalTo: tabStrip.trailingAnchor, constant: -12),
            titleRow.centerYAnchor.constraint(equalTo: tabStrip.centerYAnchor)
        ])

        documentPathLabel = NSTextField(labelWithString: "")
        documentPathLabel.font = .systemFont(ofSize: 11)
        documentPathLabel.textColor = .secondaryLabelColor
        documentPathLabel.lineBreakMode = .byTruncatingMiddle
        documentPathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        outlineToggleButton = makeIconButton("list.bullet.indent", help: "收起文档大纲", action: #selector(toggleDocumentOutline))
        let pathRow = NSStackView(views: [
            documentPathLabel, flexibleSpace(),
            outlineToggleButton,
            makeIconButton("magnifyingglass", help: "查找文档内容（⌘F）", action: #selector(toggleDocumentSearch)),
            makeIconButton("arrow.clockwise", help: "从磁盘重新加载", action: #selector(reloadDocument)),
            makeIconButton("square.and.arrow.down", help: "保存当前文档（⌘S）", action: #selector(saveDocument))
        ])
        pathRow.spacing = 4
        pathRow.edgeInsets = NSEdgeInsets(top: 2, left: 14, bottom: 2, right: 8)
        pathRow.heightAnchor.constraint(equalToConstant: 34).isActive = true
        documentSearchRow = makeToolbar()
        documentSearchRow.heightAnchor.constraint(equalToConstant: 36).isActive = true
        documentSearchRow.isHidden = true
        let chrome = NSStackView(views: [tabStrip, pathRow, documentSearchRow])
        chrome.orientation = .vertical
        chrome.alignment = .leading
        chrome.spacing = 0
        chrome.detachesHiddenViews = true
        chrome.translatesAutoresizingMaskIntoConstraints = false
        for row in [tabStrip, pathRow, documentSearchRow!] {
            row.widthAnchor.constraint(equalTo: chrome.widthAnchor).isActive = true
        }

        askField = NSTextField()
        askField.placeholderString = "选中文段后提问，留空可直接讲解"
        askField.font = .systemFont(ofSize: 13)
        askField.isBezeled = false
        askField.drawsBackground = false
        askField.focusRingType = .none
        askField.target = self
        askField.action = #selector(askGPTAboutSelection)
        askField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let askIcon = NSImageView(image: NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "文档提问")!)
        askIcon.contentTintColor = .secondaryLabelColor
        askIcon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let askButton = makeButton("提问", action: #selector(askGPTAboutSelection))
        askButton.controlSize = .small
        let askRow = NSStackView(views: [askIcon, askField, askButton])
        askRow.spacing = 9
        askRow.translatesAutoresizingMaskIntoConstraints = false
        let footer = NSBox()
        footer.boxType = .custom
        footer.borderWidth = 0
        footer.fillColor = .textBackgroundColor
        footer.contentViewMargins = .zero
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(askRow)

        editorScrollView = NSScrollView()
        editorScrollView.hasVerticalScroller = true
        editorScrollView.autohidesScrollers = true
        editorScrollView.translatesAutoresizingMaskIntoConstraints = false
        editor = NSTextView(frame: .zero)
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.allowsUndo = true
        editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        editor.textColor = .labelColor
        editor.backgroundColor = .textBackgroundColor
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = 1.5
        editor.defaultParagraphStyle = paragraphStyle
        editor.textContainerInset = NSSize(width: 34, height: 30)
        editor.textContainer?.widthTracksTextView = true
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editorScrollView.documentView = editor
        editorScrollView.isHidden = true

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(self, name: "readingPosition")
        previewWebView = WKWebView(frame: .zero, configuration: configuration)
        previewWebView.navigationDelegate = self
        previewWebView.translatesAutoresizingMaskIntoConstraints = false
        let headerSeparator = NSBox()
        headerSeparator.boxType = .separator
        headerSeparator.translatesAutoresizingMaskIntoConstraints = false
        let footerSeparator = NSBox()
        footerSeparator.boxType = .separator
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false
        for view in [chrome, headerSeparator, previewWebView!, editorScrollView!, footerSeparator, footer] {
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            chrome.topAnchor.constraint(equalTo: container.topAnchor),
            chrome.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            headerSeparator.topAnchor.constraint(equalTo: chrome.bottomAnchor),
            headerSeparator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            headerSeparator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            headerSeparator.heightAnchor.constraint(equalToConstant: 1),
            previewWebView.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor),
            previewWebView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            previewWebView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            previewWebView.bottomAnchor.constraint(equalTo: footerSeparator.topAnchor),
            editorScrollView.topAnchor.constraint(equalTo: previewWebView.topAnchor),
            editorScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            editorScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            editorScrollView.bottomAnchor.constraint(equalTo: previewWebView.bottomAnchor),
            footerSeparator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footerSeparator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footerSeparator.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footerSeparator.heightAnchor.constraint(equalToConstant: 1),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 46),
            askRow.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 14),
            askRow.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -12),
            askRow.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])
        return container
    }

    @objc private func toggleDocumentSearch() {
        documentSearchRow.isHidden.toggle()
        window.contentView?.layoutSubtreeIfNeeded()
        if !documentSearchRow.isHidden { window.makeFirstResponder(searchField) }
    }

    @objc private func toggleDocumentOutline() {
        outlineVisible.toggle()
        updateOutlineButton()
        previewWebView.evaluateJavaScript("window.readerNavigation && window.readerNavigation.setOutlineVisible(\(outlineVisible))")
        if !CommandLine.arguments.contains("--self-test") {
            UserDefaults.standard.set(outlineVisible, forKey: outlineVisibleKey)
        }
    }

    private func updateOutlineButton() {
        outlineToggleButton.toolTip = outlineVisible ? "收起文档大纲" : "展开文档大纲"
        outlineToggleButton.setAccessibilityLabel(outlineToggleButton.toolTip)
        outlineToggleButton.contentTintColor = outlineVisible ? .controlAccentColor : .secondaryLabelColor
    }

    private var readingPositions: [String: [String: Any]] {
        get {
            if CommandLine.arguments.contains("--self-test") { return testReadingPositions }
            return readingPreferences.dictionary(forKey: readingPositionsKey) as? [String: [String: Any]] ?? [:]
        }
        set {
            if CommandLine.arguments.contains("--self-test") { testReadingPositions = newValue }
            else { readingPreferences.set(newValue, forKey: readingPositionsKey) }
        }
    }

    private var readingPreferences: UserDefaults {
        if CommandLine.arguments.contains("--test-reading-write") || CommandLine.arguments.contains("--test-reading-read") {
            return UserDefaults(suiteName: "local.tlx.gpt-study-companion.reading-tests")!
        }
        return .standard
    }

    private func saveReadingPosition(_ position: [String: Any]) {
        guard let path = position["documentPath"] as? String,
              let headingID = position["headingID"] as? String,
              let offset = position["headingOffset"] as? Double,
              let scrollY = position["scrollY"] as? Double else { return }
        var positions = readingPositions
        positions[path] = ["headingID": headingID, "headingOffset": offset, "scrollY": scrollY]
        readingPositions = positions
    }

    private func makeDocumentLibraryPane() -> NSView {
        let pane = NSView()
        pane.wantsLayer = true
        pane.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        libraryTitleLabel = NSTextField(labelWithString: "文档库")
        libraryTitleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        libraryTitleLabel.lineBreakMode = .byTruncatingMiddle
        libraryTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let heading = NSStackView(views: [
            libraryTitleLabel,
            flexibleSpace(),
            makeIconButton("chevron.left", help: "收起侧栏", action: #selector(toggleSidebar))
        ])
        heading.spacing = 4
        heading.translatesAutoresizingMaskIntoConstraints = false
        let actions = NSStackView(views: [
            makeIconButton("folder.badge.plus", help: "打开目录", action: #selector(chooseDocumentDirectory)),
            makeIconButton("doc.badge.plus", help: "打开文件", action: #selector(chooseDocument)),
            flexibleSpace(),
            makeIconButton("arrow.clockwise", help: "刷新文件树", action: #selector(refreshLibrary)),
            makeIconButton("rectangle.compress.vertical", help: "收起全部文件夹", action: #selector(collapseAllFolders))
        ])
        actions.spacing = 4
        actions.translatesAutoresizingMaskIntoConstraints = false

        documentListView = NSOutlineView()
        documentListView.headerView = nil
        documentListView.rowHeight = 30
        documentListView.indentationPerLevel = 14
        documentListView.style = .sourceList
        documentListView.allowsEmptySelection = true
        documentListView.dataSource = self
        documentListView.delegate = self
        documentListView.target = self
        documentListView.action = #selector(fileTreeClicked)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("document"))
        column.resizingMask = .autoresizingMask
        documentListView.addTableColumn(column)
        documentListView.outlineTableColumn = column
        documentListView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = documentListView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(heading)
        pane.addSubview(actions)
        pane.addSubview(scrollView)
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: pane.topAnchor, constant: 14),
            heading.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 14),
            heading.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -8),
            heading.heightAnchor.constraint(equalToConstant: 28),
            actions.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            actions.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 8),
            actions.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -8),
            actions.heightAnchor.constraint(equalToConstant: 28),
            scrollView.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: pane.bottomAnchor)
        ])
        return pane
    }

    private func makeChatPane() -> NSView {
        let configuration = WKWebViewConfiguration()
        // Keep the original persistent profile so updates and restarts reuse the existing login.
        configuration.websiteDataStore = .default()
        if let scriptURL = Bundle.main.url(forResource: "chat-composer", withExtension: "js"),
           let script = try? String(contentsOf: scriptURL, encoding: .utf8) {
            configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "ChatGPT")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let header = NSStackView(views: [
            title, flexibleSpace(),
            makeButton("插入选中回答", action: #selector(insertAnswer)),
            makeButton("刷新", action: #selector(refreshChatGPT))
        ])
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(header)
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            header.heightAnchor.constraint(equalToConstant: 28),
            webView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    @objc private func toggleSidebar() {
        sidebarItem.isCollapsed.toggle()
        window.contentView?.layoutSubtreeIfNeeded()
        updateSidebarButton()
        if !CommandLine.arguments.contains("--self-test") {
            UserDefaults.standard.set(sidebarItem.isCollapsed, forKey: sidebarHiddenKey)
        }
    }

    private func updateSidebarButton() {
        sidebarToggleButton.toolTip = sidebarItem.isCollapsed ? "展开侧栏（⌘\\）" : "收起侧栏（⌘\\）"
        sidebarToggleButton.setAccessibilityLabel(sidebarItem.isCollapsed ? "展开侧栏" : "收起侧栏")
        sidebarToggleButton.contentTintColor = sidebarItem.isCollapsed ? .secondaryLabelColor : .controlAccentColor
    }

    @objc private func collapseAllFolders() {
        synchronizingSelection = true
        defer { synchronizingSelection = false }
        for node in rootNodes where node.isFolder {
            documentListView.collapseItem(node, collapseChildren: true)
        }
        setStatus("已收起全部文件夹")
    }

    @objc private func refreshLibrary() {
        reloadDocumentList()
        setStatus("已刷新文档库 · \(documentFiles.count) 个 Markdown")
    }

    @objc private func fileTreeClicked() {
        guard let node = documentListView.item(atRow: documentListView.clickedRow) as? DocumentNode,
              node.isFolder else { return }
        if documentListView.isItemExpanded(node) {
            documentListView.collapseItem(node)
        } else {
            documentListView.expandItem(node)
        }
    }

    private func makeButton(_ title: String, action: Selector, emphasized: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        if emphasized {
            button.keyEquivalent = "\r"
            button.contentTintColor = .controlAccentColor
        }
        return button
    }

    private func makeIconButton(_ symbol: String, help: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: help)!, target: self, action: action)
        button.isBordered = false
        button.bezelStyle = .inline
        button.toolTip = help
        button.setAccessibilityLabel(help)
        button.contentTintColor = .secondaryLabelColor
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    private func flexibleSpace() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 GPT 学习伴侣", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let fileMenu = NSMenu(title: "文件")
        for (title, action, key) in [
            ("打开文件…", #selector(chooseDocument), "o"),
            ("打开目录…", #selector(chooseDocumentDirectory), ""),
            ("查找文档内容", #selector(toggleDocumentSearch), "f"),
            ("保存", #selector(saveDocument), "s"),
            ("显示 / 隐藏侧栏", #selector(toggleSidebar), "")
        ] {
            let item = fileMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
        }
        let fileItem = NSMenuItem()
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [
            ("撤销", Selector(("undo:")), "z"),
            ("剪切", #selector(NSText.cut(_:)), "x"),
            ("复制", #selector(NSText.copy(_:)), "c"),
            ("粘贴", #selector(NSText.paste(_:)), "v"),
            ("全选", #selector(NSText.selectAll(_:)), "a")
        ] { editMenu.addItem(withTitle: title, action: action, keyEquivalent: key) }
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    private func restoreDocumentLibrary() {
        let defaults = UserDefaults.standard
        if let savedPath = defaults.string(forKey: lastDocumentPathKey) {
            let savedURL = URL(fileURLWithPath: savedPath)
            if FileManager.default.fileExists(atPath: savedURL.path) {
                documentURL = savedURL
            }
        }

        if let savedRootPath = defaults.string(forKey: lastDocumentRootPathKey) {
            let savedRoot = URL(fileURLWithPath: savedRootPath)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: savedRoot.path, isDirectory: &isDirectory), isDirectory.boolValue {
                documentRootURL = savedRoot
            }
        }

        if documentRootURL == nil {
            documentRootURL = documentURL.deletingLastPathComponent()
        }
        reloadDocumentList()
    }

    @objc private func chooseDocument() {
        let panel = NSOpenPanel()
        panel.title = "选择 Markdown 文档"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["md", "markdown"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url, prepareToSwitchDocument() else { return }

        guard loadDocument(at: url) else { return }
        documentRootURL = url.deletingLastPathComponent()
        reloadDocumentList()
        persistDocumentLocation()
    }

    @objc private func chooseDocumentDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择 Markdown 文档目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let root = panel.url else { return }

        let files = markdownDocuments(in: root)
        guard let first = files.first else {
            showError("目录中没有 Markdown 文档", detail: "请选择包含 .md 或 .markdown 文件的目录。")
            return
        }
        guard prepareToSwitchDocument() else { return }

        let target = files.contains(documentURL.standardizedFileURL) ? documentURL : first
        guard loadDocument(at: target) else { return }
        documentRootURL = root
        documentFiles = files
        rebuildDocumentTree()
        persistDocumentLocation()
    }

    private func prepareToSwitchDocument(action: String = "切换文档") -> Bool {
        guard editor.string != savedText else { return true }
        let alert = NSAlert()
        alert.messageText = "当前文档有尚未保存的编辑"
        alert.informativeText = "\(action)前要保存吗？"
        alert.addButton(withTitle: "保存并\(action)")
        alert.addButton(withTitle: "放弃修改")
        alert.addButton(withTitle: "取消")
        switch testUnsavedDecision ?? alert.runModal() {
        case .alertFirstButtonReturn:
            return persistDocument()
        case .alertSecondButtonReturn:
            editor.undoManager?.removeAllActions()
            return true
        default:
            return false
        }
    }

    private func reloadDocumentList() {
        guard let root = documentRootURL else {
            documentFiles = [documentURL]
            rebuildDocumentTree()
            return
        }
        documentFiles = markdownDocuments(in: root)
        if !documentFiles.contains(documentURL.standardizedFileURL),
           FileManager.default.fileExists(atPath: documentURL.path) {
            documentFiles.append(documentURL)
            documentFiles.sort { relativePath(for: $0).localizedStandardCompare(relativePath(for: $1)) == .orderedAscending }
        }
        rebuildDocumentTree()
    }

    private func markdownDocuments(in root: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            let fileExtension = url.pathExtension.lowercased()
            guard fileExtension == "md" || fileExtension == "markdown",
                  (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true else { continue }
            files.append(url.standardizedFileURL)
        }
        return files.sorted { relativePath(for: $0, root: root).localizedStandardCompare(relativePath(for: $1, root: root)) == .orderedAscending }
    }

    private func rebuildDocumentTree() {
        updateDocumentPath()
        libraryTitleLabel.stringValue = documentRootURL?.lastPathComponent ?? "Markdown 文档"
        libraryTitleLabel.toolTip = documentRootURL?.path
        let root = DocumentNode(url: documentRootURL ?? documentURL.deletingLastPathComponent(), isFolder: true)
        for file in documentFiles {
            let parts = relativePath(for: file).split(separator: "/").map(String.init)
            var parent = root
            for part in parts.dropLast() {
                if let existing = parent.children.first(where: { $0.isFolder && $0.url.lastPathComponent == part }) {
                    parent = existing
                } else {
                    let folder = DocumentNode(url: parent.url.appendingPathComponent(part), isFolder: true)
                    parent.children.append(folder)
                    parent = folder
                }
            }
            parent.children.append(DocumentNode(url: file, isFolder: false))
        }
        func sortChildren(_ node: DocumentNode) {
            node.children.sort {
                if $0.isFolder != $1.isFolder { return $0.isFolder }
                return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
            }
            node.children.forEach(sortChildren)
        }
        sortChildren(root)
        rootNodes = root.children
        synchronizingSelection = true
        documentListView.reloadData()
        synchronizingSelection = false
        selectCurrentDocumentInTree()
    }

    private func selectCurrentDocumentInTree() {
        synchronizingSelection = true
        defer { synchronizingSelection = false }
        func reveal(in nodes: [DocumentNode]) -> DocumentNode? {
            for node in nodes {
                if node.url.standardizedFileURL == documentURL.standardizedFileURL && !node.isFolder { return node }
                if let match = reveal(in: node.children) {
                    documentListView.expandItem(node)
                    return match
                }
            }
            return nil
        }
        if let node = reveal(in: rootNodes) {
            let row = documentListView.row(forItem: node)
            documentListView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            documentListView.scrollRowToVisible(row)
        } else {
            documentListView.deselectAll(nil)
        }
    }

    private func relativePath(for url: URL, root: URL? = nil) -> String {
        guard let root = root ?? documentRootURL else { return url.lastPathComponent }
        let prefix = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
    }

    private func updateDocumentPath() {
        let rootName = documentRootURL?.lastPathComponent ?? "文档"
        documentPathLabel.stringValue = rootName + " / " + relativePath(for: documentURL).replacingOccurrences(of: "/", with: " / ")
        documentPathLabel.toolTip = documentURL.path
    }

    private func persistDocumentLocation() {
        guard !CommandLine.arguments.contains("--self-test") else { return }
        UserDefaults.standard.set(documentURL.path, forKey: lastDocumentPathKey)
        UserDefaults.standard.set(documentRootURL?.path, forKey: lastDocumentRootPathKey)
    }

    @discardableResult
    private func loadDocument(at url: URL? = nil) -> Bool {
        let target = (url ?? documentURL).standardizedFileURL
        do {
            let text = try String(contentsOf: target, encoding: .utf8)
            documentURL = target
            editor.string = text
            savedText = text
            let isWelcome = target == welcomeDocumentURL.standardizedFileURL
            editor.isEditable = !isWelcome
            viewModeControl.isEnabled = !isWelcome
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            editor.undoManager?.removeAllActions()
            lastKnownModificationDate = modificationDate()
            documentTitleLabel.stringValue = documentURL.deletingPathExtension().lastPathComponent
            documentTitleLabel.toolTip = documentURL.path
            updateDocumentPath()
            window.title = "\(documentURL.deletingPathExtension().lastPathComponent) — GPT 学习伴侣"
            window.representedURL = documentURL
            persistDocumentLocation()
            selectCurrentDocumentInTree()
            renderMarkdown()
            setStatus("已载入 \(documentURL.lastPathComponent)")
            return true
        } catch {
            showError("无法读取文档", detail: error.localizedDescription)
            return false
        }
    }

    private func renderMarkdown() {
        guard let markedURL = Bundle.main.url(forResource: "marked.umd", withExtension: "js"),
              let markedSource = try? String(contentsOf: markedURL, encoding: .utf8),
              let styleURL = Bundle.main.url(forResource: "reader", withExtension: "css"),
              let style = try? String(contentsOf: styleURL, encoding: .utf8),
              let navigationURL = Bundle.main.url(forResource: "reader-navigation", withExtension: "js"),
              let navigationScript = try? String(contentsOf: navigationURL, encoding: .utf8),
              let sanitizerURL = Bundle.main.url(forResource: "purify.min", withExtension: "js"),
              let sanitizer = try? String(contentsOf: sanitizerURL, encoding: .utf8) else {
            showError("无法渲染 Markdown", detail: "应用缺少阅读区资源，请重新运行 build.sh。")
            return
        }

        let markdown = javaScriptLiteral(editor.string)
        let path = documentURL.standardizedFileURL.path
        let positionData = try? JSONSerialization.data(withJSONObject: readingPositions[path] ?? [:])
        let savedPosition = positionData.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        updateOutlineButton()
        let html = """
        <!doctype html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>\(style)</style>
          <script>\(markedSource)</script>
          <script>\(sanitizer)</script>
        </head>
        <body>
          <main class="reader-layout">
            <article id="content"></article>
            <nav id="document-outline" class="outline-panel" aria-label="文档大纲"></nav>
          </main>
          <script>
            window.readerDocumentPath = \(javaScriptLiteral(path));
            window.readerSavedPosition = \(savedPosition);
            window.readerOutlineVisible = \(outlineVisible);
            document.getElementById('content').innerHTML = DOMPurify.sanitize(marked.parse(\(markdown), { gfm: true }));
            \(navigationScript)
          </script>
        </body>
        </html>
        """
        previewWebView.loadHTMLString(html, baseURL: documentURL.deletingLastPathComponent())
    }

    private func javaScriptLiteral(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let array = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }

    private func loadChatGPT() {
        let savedURL = UserDefaults.standard.string(forKey: lastChatURLKey).flatMap(URL.init(string:))
        let url = savedURL.flatMap { rememberedChatURL($0) } ?? URL(string: "https://chatgpt.com")!
        webView.load(URLRequest(url: url))
    }

    private func rememberedChatURL(_ url: URL) -> URL? {
        guard url.scheme == "https", url.host == "chatgpt.com",
              url.path == "/" || url.path.hasPrefix("/c/") || url.path.hasPrefix("/g/"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private func rememberChatURL() {
        guard !CommandLine.arguments.contains("--self-test"),
              let url = webView?.url.flatMap({ rememberedChatURL($0) }) else { return }
        UserDefaults.standard.set(url.absoluteString, forKey: lastChatURLKey)
    }

    private func attachmentScript() throws -> String {
        guard let url = Bundle.main.url(forResource: "chat-attachment", withExtension: "js") else {
            throw NSError(domain: "StudyCompanion", code: 1, userInfo: [NSLocalizedDescriptionKey: "应用缺少文档附件资源，请重新构建。"])
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func documentChatPrompt(filename: String) -> String {
        """
        我正在学习附件《\(filename)》。请将这份文档作为本次对话的学习背景。

        回答我的问题时，请结合文档中的相关章节，用容易理解的语言解释，并给出贴近内容的例子。
        请明确区分原文依据与补充解释；附件中无法确认的信息请说明。涉及面试准备时，请补充适合口述的回答。

        请先简短确认你能读取附件，介绍文档主题与章节结构，然后等待我的具体问题。
        """
    }

    @objc private func attachCurrentDocument() {
        guard !editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showError("当前文档为空", detail: "请先打开一份有内容的 Markdown 文档。")
            return
        }
        do {
            let filename = documentURL.lastPathComponent
            window.makeFirstResponder(webView)
            attachmentButton.isEnabled = false
            setStatus("正在加入 \(filename)…")
            webView.callAsyncJavaScript(
                try attachmentScript(),
                arguments: ["content": editor.string, "filename": filename, "studyPrompt": documentChatPrompt(filename: filename)],
                in: nil,
                in: .page
            ) { [weak self] result in
                guard let self else { return }
                self.attachmentButton.isEnabled = true
                switch result {
                case .success(let value) where value as? String == "queued":
                    self.setStatus("已加入 \(filename) 并填写学习提示词，上传完成后可修改并发送")
                    self.rememberChatURL()
                case .success(let value) where value as? String == "prompt-failed":
                    self.showError("未能填写学习提示词", detail: "请确认右侧聊天输入框可以编辑，然后再次点击“加入聊天”。")
                case .success(let value) where value as? String == "not-ready":
                    self.showError("聊天尚未就绪", detail: "请先在右侧登录 ChatGPT，打开一个聊天后再点击“加入聊天”。")
                case .success:
                    self.showError("未找到文件上传入口", detail: "请先打开右侧 ChatGPT 的“＋”附件菜单，再点击“加入聊天”。")
                case .failure(let error):
                    self.showError("无法加入文档", detail: error.localizedDescription)
                }
            }
        } catch {
            attachmentButton.isEnabled = true
            showError("无法加入文档", detail: error.localizedDescription)
        }
    }

    @objc private func reloadDocument() {
        if editor.string != savedText {
            let alert = NSAlert()
            alert.messageText = "重载会丢弃尚未保存的编辑"
            alert.informativeText = "确定要从磁盘重新读取文档吗？"
            alert.addButton(withTitle: "重载")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        loadDocument()
        editor.undoManager?.removeAllActions()
    }

    @objc private func saveDocument() {
        _ = persistDocument()
    }

    @objc private func changeDocumentMode() {
        let isReading = viewModeControl.selectedSegment == 0
        if isReading { renderMarkdown() }
        previewWebView.isHidden = !isReading
        editorScrollView.isHidden = isReading
        if !isReading {
            window.makeFirstResponder(editor)
            setStatus("编辑模式：可放置光标后插入 GPT 回答")
        }
    }

    @objc private func askGPTAboutSelection() {
        selectedDocumentText { [weak self] selectedText in
            guard let self else { return }
            guard let selectedText, !selectedText.isEmpty else {
                self.showError("请先选中文档内容", detail: "在左侧阅读页或编辑页选中一段文字，再点击“提问”。")
                return
            }
            let question = self.askField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let instruction = question.isEmpty ? "请解释下面这段内容，指出核心概念，并给出适合面试口述的回答。" : question
            self.sendToChatGPT("\(instruction)\n\n文档片段：\n\(selectedText)")
        }
    }

    private func selectedDocumentText(completion: @escaping (String?) -> Void) {
        if viewModeControl.selectedSegment == 0 {
            previewWebView.evaluateJavaScript("window.getSelection().toString()") { result, _ in
                let selected = (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async { completion(selected) }
            }
            return
        }

        let range = editor.selectedRange()
        guard range.length > 0 else {
            completion(nil)
            return
        }
        completion((editor.string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func sendToChatGPT(_ prompt: String) {
        fillChatComposer(prompt) { [weak self] success, detail in
            guard let self else { return }
            if success {
                self.askField.stringValue = ""
                self.setStatus("已加入 GPT 输入框，请检查后发送")
            } else {
                self.showError("未能加入 GPT 输入框", detail: detail)
            }
        }
    }

    private func fillChatComposer(_ prompt: String, completion: @escaping (Bool, String) -> Void) {
        window.makeFirstResponder(webView)
        webView.callAsyncJavaScript("""
        const composer = window.studyChatComposer && window.studyChatComposer.find();
        if (!composer) return null;
        const draft = window.studyChatComposer.read(composer);
        const message = draft.trim() ? draft + '\\n\\n' + prompt : prompt;
        window.studyChatComposer.selectContents(composer);
        return message;
        """, arguments: ["prompt": prompt], in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            guard case .success(let value) = result, let message = value as? String else {
                completion(false, "请确认右侧 ChatGPT 已登录并显示聊天输入框。不会将文字填入回答中的代码编辑器。")
                return
            }

            let pasteboard = NSPasteboard.general
            let originalItems = (pasteboard.pasteboardItems ?? []).map { item in
                let copy = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data(forType: type) { copy.setData(data, forType: type) }
                }
                return copy
            }
            pasteboard.clearContents()
            pasteboard.setString(message, forType: .string)
            let temporaryChangeCount = pasteboard.changeCount
            let restoreClipboard = {
                if pasteboard.changeCount == temporaryChangeCount {
                    pasteboard.clearContents()
                    pasteboard.writeObjects(originalItems)
                }
            }
            // Native paste updates the page's editor state, including ProseMirror's paste handler.
            guard NSApp.sendAction(#selector(NSText.paste(_:)), to: self.webView, from: self) else {
                restoreClipboard()
                completion(false, "右侧输入框未接受粘贴，请刷新 ChatGPT 后重试。")
                return
            }
            self.webView.callAsyncJavaScript("""
            await new Promise(resolve => setTimeout(resolve, 0));
            const composer = window.studyChatComposer.find();
            return composer ? window.studyChatComposer.read(composer) : null;
            """, arguments: [:], in: nil, in: .page) { result in
                restoreClipboard()
                guard case .success(let value) = result, let actual = value as? String else {
                    completion(false, "无法确认输入框内容，未显示写入成功。")
                    return
                }
                let normalize: (String) -> String = {
                    $0.replacingOccurrences(of: "\r\n", with: "\n")
                        .replacingOccurrences(of: "\u{00a0}", with: " ")
                        .trimmingCharacters(in: .newlines)
                }
                guard normalize(actual) == normalize(message) else {
                    completion(false, "聊天输入框未保留完整内容，请刷新页面后重试。")
                    return
                }
                completion(true, "")
            }
        }
    }

    private func persistDocument() -> Bool {
        guard documentURL.standardizedFileURL != welcomeDocumentURL.standardizedFileURL else {
            showError("欢迎文档仅供阅读", detail: "请先打开自己的 Markdown 文档再保存。")
            return false
        }
        let diskText = try? String(contentsOf: documentURL, encoding: .utf8)
        if modificationDate() != lastKnownModificationDate || diskText != savedText {
            if isTestRun { return false }
            let alert = NSAlert()
            alert.messageText = "文档已被其他程序修改"
            alert.informativeText = "文件已更改或被删除。重载会丢弃当前未保存的修改，请先复制需要保留的内容。"
            alert.addButton(withTitle: "重载")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn { loadDocument() }
            return false
        }

        do {
            try editor.string.write(to: documentURL, atomically: true, encoding: .utf8)
            savedText = editor.string
            lastKnownModificationDate = modificationDate()
            editor.undoManager?.removeAllActions()
            setStatus("已保存到原文档")
            return true
        } catch {
            showError("保存失败", detail: error.localizedDescription)
            return false
        }
    }

    @objc private func insertAnswer() {
        webView.evaluateJavaScript("window.getSelection().toString()") { [weak self] result, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let selected = (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let clipboard = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let text = [selected, clipboard].compactMap({ $0 }).first(where: { !$0.isEmpty }) else {
                    self.showError("没有可插入的内容", detail: "请在右侧选中回答，或先复制想要插入的文字。")
                    return
                }
                self.insert(text: text)
            }
        }
    }

    private func insert(text: String) {
        guard viewModeControl.selectedSegment == 1 else {
            showError("请先切换到编辑模式", detail: "在左侧点击“编辑”，把光标放在目标位置，再插入右侧回答。")
            return
        }
        let original = editor.string as NSString
        let selection = editor.selectedRange()
        let prefix = selection.location > 0 && !original.substring(to: selection.location).hasSuffix("\n\n") ? "\n\n" : ""
        let suffix = selection.location + selection.length < original.length && !original.substring(from: selection.location + selection.length).hasPrefix("\n\n") ? "\n\n" : ""
        let insertion = prefix + text + suffix
        editor.insertText(insertion, replacementRange: selection)
        if persistDocument() {
            editor.showFindIndicator(for: NSRange(location: selection.location + prefix.count, length: text.utf16.count))
            setStatus("已插入右侧内容并保存")
        }
    }

    @objc private func findNext() {
        let query = searchField.stringValue
        guard !query.isEmpty else { return }
        if viewModeControl.selectedSegment == 0 {
            previewWebView.evaluateJavaScript("window.find(\(javaScriptLiteral(query)), false, false, true, false, true, false)") { [weak self] result, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if (result as? Bool) == true {
                        self.setStatus("已找到下一处")
                    } else {
                        NSSound.beep()
                        self.setStatus("未找到“\(query)”")
                    }
                }
            }
            return
        }
        let source = editor.string as NSString
        let start = NSMaxRange(editor.selectedRange())
        var range = source.range(of: query, options: [.caseInsensitive], range: NSRange(location: start, length: source.length - start))
        if range.location == NSNotFound {
            range = source.range(of: query, options: [.caseInsensitive])
        }
        guard range.location != NSNotFound else {
            NSSound.beep()
            setStatus("未找到“\(query)”")
            return
        }
        editor.setSelectedRange(range)
        editor.scrollRangeToVisible(range)
        window.makeFirstResponder(editor)
        setStatus("已找到下一处")
    }

    @objc private func refreshChatGPT() {
        webView.reload()
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: documentURL.path)[.modificationDate]) as? Date
    }

    private func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    private func showError(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}

extension AppDelegate: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === previewWebView, let position = message.body as? [String: Any] else { return }
        saveReadingPosition(position)
    }
}

extension AppDelegate: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? DocumentNode)?.children.count ?? rootNodes.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? DocumentNode)?.children ?? rootNodes)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? DocumentNode)?.isFolder == true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? DocumentNode)?.isFolder == false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? DocumentNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("DocumentCell")
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.imageView = icon
            cell.addSubview(icon)
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingMiddle
            label.font = .systemFont(ofSize: 13)
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.textField = label
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        cell.textField?.stringValue = node.isFolder ? node.url.lastPathComponent : node.url.deletingPathExtension().lastPathComponent
        cell.imageView?.image = NSImage(systemSymbolName: node.isFolder ? "folder" : "doc.text", accessibilityDescription: node.isFolder ? "文件夹" : "Markdown 文档")
        cell.imageView?.contentTintColor = .secondaryLabelColor
        cell.toolTip = node.url.path
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !synchronizingSelection,
              let node = documentListView.item(atRow: documentListView.selectedRow) as? DocumentNode,
              !node.isFolder,
              node.url.standardizedFileURL != documentURL.standardizedFileURL else { return }
        guard prepareToSwitchDocument() else {
            selectCurrentDocumentInTree()
            return
        }
        if !loadDocument(at: node.url) { selectCurrentDocumentInTree() }
    }
}

extension AppDelegate {
    private func runSelfTests() {
        // Use disposable documents so these checks cannot change the user's notes or remembered library.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("study-companion-test-\(UUID().uuidString)")
        do {
            let nested = root.appendingPathComponent("课程")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let first = root.appendingPathComponent("第一课.md")
            let second = nested.appendingPathComponent("第二课.markdown")
            try "# 第一课\n\n保留原文".write(to: first, atomically: true, encoding: .utf8)
            try "# 第二课\n\n测试正文".write(to: second, atomically: true, encoding: .utf8)
            try "忽略此文件".write(to: root.appendingPathComponent("说明.txt"), atomically: true, encoding: .utf8)
            documentRootURL = root
            documentURL = first
            reloadDocumentList()
            precondition(documentFiles.count == 2, "Markdown discovery must include nested .markdown and exclude .txt")
            precondition(rootNodes.first?.isFolder == true, "Folders must precede files")
            precondition(loadDocument(at: first))
            documentListView.expandItem(rootNodes[0])
            let secondNode = rootNodes[0].children[0]
            documentListView.selectRowIndexes(IndexSet(integer: documentListView.row(forItem: secondNode)), byExtendingSelection: false)
            precondition(documentURL == second && editor.string.contains("第二课"), "Selecting a nested row must switch the editor's file")
            selectCurrentDocumentInTree()
            precondition(documentURL == second, "Synchronizing selection must not reopen the previous file")
            editor.string += "\n\n补充答案"
            precondition(persistDocument())
            let firstText = try String(contentsOf: first, encoding: .utf8)
            let secondText = try String(contentsOf: second, encoding: .utf8)
            precondition(firstText == "# 第一课\n\n保留原文", "Saving the current file must not change the previous file")
            precondition(secondText.contains("补充答案"), "Saving must write the current file")
            let savedDate = modificationDate()!
            try FileManager.default.setAttributes([.modificationDate: savedDate.addingTimeInterval(-60)], ofItemAtPath: second.path)
            editor.string += "\n不能覆盖外部版本"
            precondition(!persistDocument(), "An older external modification timestamp must still block overwriting")
            let unchangedText = try String(contentsOf: second, encoding: .utf8)
            precondition(unchangedText == secondText)
            try FileManager.default.removeItem(at: second)
            precondition(!persistDocument(), "A deleted document must not be silently recreated on save")
            try secondText.write(to: second, atomically: true, encoding: .utf8)
            let frozenDate = Date(timeIntervalSince1970: 1700000000)
            try FileManager.default.setAttributes([.modificationDate: frozenDate], ofItemAtPath: second.path)
            precondition(loadDocument(at: second))
            try "保留时间戳的外部版本".write(to: second, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: frozenDate], ofItemAtPath: second.path)
            editor.string = "不能覆盖外部内容"
            precondition(!persistDocument(), "External content edits must be detected even when the timestamp is preserved")
            let preservedExternal = try String(contentsOf: second, encoding: .utf8)
            precondition(preservedExternal == "保留时间戳的外部版本")
            try secondText.write(to: second, atomically: true, encoding: .utf8)
            precondition(loadDocument(at: second))
            print("PASS: external timestamp rollback, preserved timestamps and deleted-file save conflicts")
            let exitDocument = root.appendingPathComponent("退出测试.md")
            try "退出前的原文".write(to: exitDocument, atomically: true, encoding: .utf8)
            precondition(loadDocument(at: exitDocument))
            editor.string += "\n未保存的修改"
            testUnsavedDecision = .alertThirdButtonReturn
            precondition(!prepareToSwitchDocument(action: "退出应用"), "Cancel must keep the document and prevent leaving")
            testUnsavedDecision = .alertFirstButtonReturn
            precondition(prepareToSwitchDocument(action: "退出应用"), "Save before leaving must complete before exit")
            let savedBeforeExit = try String(contentsOf: exitDocument, encoding: .utf8)
            precondition(savedBeforeExit.contains("未保存的修改"))
            editor.string += "\n放弃的修改"
            testUnsavedDecision = .alertSecondButtonReturn
            precondition(prepareToSwitchDocument(action: "关闭窗口"))
            let discardedOnDisk = try String(contentsOf: exitDocument, encoding: .utf8)
            precondition(discardedOnDisk == savedBeforeExit, "Discard must not write the abandoned changes")
            testUnsavedDecision = nil
            precondition(loadDocument(at: second))
            print("PASS: unsaved edit cancel/save/discard decisions before leaving")
            collapseAllFolders()
            precondition(!documentListView.isItemExpanded(rootNodes[0]), "Collapse all must close expanded folders")
            precondition(documentURL == second && editor.string == secondText, "Collapsing folders must not switch or discard the open document")
            documentListView.expandItem(rootNodes[0])
            precondition(documentListView.row(forItem: secondNode) >= 0, "Collapsed folders must reopen to reveal their files")
            reloadDocumentList()
            precondition(documentURL == second, "Refreshing the tree must retain the current document")
            let firstNode = rootNodes.first { !$0.isFolder }!
            documentListView.selectRowIndexes(IndexSet(integer: documentListView.row(forItem: firstNode)), byExtendingSelection: false)
            precondition(documentURL == first && editor.string == firstText, "Switching back must reload the correct content")

            window.contentView?.layoutSubtreeIfNeeded()
            let split = workspaceController.splitView
            split.setPosition(200, ofDividerAt: 0)
            window.contentView?.layoutSubtreeIfNeeded()
            let sidebarBefore = workspaceController.splitViewItems[0].viewController.view.frame.width
            split.setPosition(290, ofDividerAt: 0)
            window.contentView?.layoutSubtreeIfNeeded()
            let sidebarAfter = workspaceController.splitViewItems[0].viewController.view.frame.width
            precondition(sidebarAfter > sidebarBefore + 50, "The file-tree divider must change sidebar width")
            split.setPosition(820, ofDividerAt: 1)
            window.contentView?.layoutSubtreeIfNeeded()
            let documentBefore = workspaceController.splitViewItems[1].viewController.view.frame.width
            split.setPosition(1000, ofDividerAt: 1)
            window.contentView?.layoutSubtreeIfNeeded()
            let documentAfter = workspaceController.splitViewItems[1].viewController.view.frame.width
            precondition(documentAfter > documentBefore + 80, "The GPT divider must change reading width")
            let documentView = workspaceController.splitViewItems[1].viewController.view
            let leftBeforeCollapse = documentView.convert(.zero, to: split).x
            toggleSidebar()
            precondition(sidebarItem.isCollapsed, "The sidebar button must hide the file explorer")
            precondition(documentView.convert(.zero, to: split).x < leftBeforeCollapse - 100, "Hiding the explorer must free space for document reading")
            precondition(sidebarToggleButton.superview != nil && sidebarToggleButton.toolTip == "展开侧栏（⌘\\）", "The ribbon must retain a visible way to reopen the explorer")
            toggleSidebar()
            precondition(!sidebarItem.isCollapsed && documentView.convert(.zero, to: split).x > 100, "The ribbon button must restore the explorer")
            precondition(documentURL == first && editor.string == firstText, "Sidebar toggling must preserve the open document")
            print("PASS: collapse all folders, reopen folder, hide sidebar, restore sidebar, preserved document")
            print("PASS: recursive file tree, nested row switching, selection synchronization, save target, refresh, switch back")
            print("PASS: sidebar width \(sidebarBefore) -> \(sidebarAfter); reading width \(documentBefore) -> \(documentAfter)")
            precondition(webView.configuration.websiteDataStore.isPersistent, "ChatGPT must use persistent website storage")
            precondition(rememberedChatURL(URL(string: "https://chatgpt.com/c/test-chat?temporary=1#section")!)?.absoluteString == "https://chatgpt.com/c/test-chat")
            precondition(rememberedChatURL(URL(string: "https://auth.openai.com/login?token=test")!) == nil, "Login redirects must never be restored as conversation URLs")
            editor.string += "\n\n尚未保存的内容 😀 <script>与代码示例</script>"
            testingChatAttachment = true
            webView.loadHTMLString("""
            <!doctype html><html><body>
            <div id="prompt-textarea" contenteditable="true">已有问题</div>
            <input type="file" id="images" accept="image/*">
            <input type="file" id="document-upload" accept=".txt,.md,.markdown">
            <script>
              window.uploadChanges = 0;
              document.getElementById('document-upload').addEventListener('change', () => { window.uploadChanges++; });
            </script>
            </body></html>
            """, baseURL: nil)
        } catch {
            fputs("Self-test failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private func runAttachmentTest() {
        do {
            let expectedContent = editor.string
            let expectedFilename = documentURL.lastPathComponent
            let expectedPrompt = documentChatPrompt(filename: expectedFilename)
            webView.callAsyncJavaScript(
                try attachmentScript(),
                arguments: ["content": expectedContent, "filename": expectedFilename, "studyPrompt": expectedPrompt], in: nil, in: .page
            ) { result in
                guard case .success(let state) = result, state as? String == "queued" else {
                    fatalError("Attachment injection failed: \(result)")
                }
                self.webView.callAsyncJavaScript("""
                const file = document.getElementById('document-upload').files[0];
                return {
                  filename: file.name, content: await file.text(),
                  draft: document.getElementById('prompt-textarea').innerText,
                  changeEvents: window.uploadChanges,
                  imageFiles: document.getElementById('images').files.length
                };
                """, arguments: [:], in: nil, in: .page) { result in
                    guard case .success(let value) = result, let uploaded = value as? [String: Any] else {
                        fatalError("Cannot inspect injected file: \(result)")
                    }
                    precondition(uploaded["filename"] as? String == expectedFilename, "Attachment must retain the current filename")
                    precondition(uploaded["content"] as? String == expectedContent, "Attachment must include full Unicode content and unsaved edits")
                    precondition((uploaded["draft"] as? String)?.trimmingCharacters(in: .newlines) == "已有问题\n\n附件学习背景：\n" + expectedPrompt, "Attaching a file must preserve the existing question and append the document-specific study prompt")
                    precondition(uploaded["changeEvents"] as? Int == 1, "Upload must trigger exactly one change event")
                    precondition(uploaded["imageFiles"] as? Int == 0, "Markdown must not be sent to an image-only input")
                    print("PASS: real WebKit file attachment, Unicode, unsaved edits, preserved question, matching study prompt")
                    self.runEmptyComposerPromptTest()
                }
            }
        } catch { fatalError("Attachment resource failed: \(error)") }
    }

    private func runEmptyComposerPromptTest() {
        do {
            let expectedPrompt = documentChatPrompt(filename: "全新文档.md")
            webView.callAsyncJavaScript("document.getElementById('prompt-textarea').textContent = '';\n" + (try attachmentScript()),
                                       arguments: ["content": "# 新文档", "filename": "全新文档.md", "studyPrompt": expectedPrompt], in: nil, in: .page) { result in
                guard case .success(let state) = result, state as? String == "queued" else {
                    fatalError("Attaching to an empty composer failed: \(result)")
                }
                self.webView.evaluateJavaScript("document.getElementById('prompt-textarea').innerText") { result, error in
                    precondition(error == nil && (result as? String)?.trimmingCharacters(in: .newlines) == expectedPrompt, "An empty composer must receive the study prompt without an empty question prefix")
                    print("PASS: empty composer receives the study prompt for the newly attached document")
                    self.runTextareaPromptTest()
                }
            }
        } catch { fatalError("Attachment resource failed: \(error)") }
    }

    private func runTextareaPromptTest() {
        do {
            let prompt = documentChatPrompt(filename: "笔记.md")
            let setup = "document.getElementById('prompt-textarea').outerHTML = '<textarea id=\"prompt-textarea\">原有问题</textarea>';\n"
            webView.callAsyncJavaScript(setup + (try attachmentScript()),
                                       arguments: ["content": "# 笔记", "filename": "笔记.md", "studyPrompt": prompt], in: nil, in: .page) { result in
                guard case .success(let state) = result, state as? String == "queued" else {
                    fatalError("Textarea attachment failed: \(result)")
                }
                self.webView.evaluateJavaScript("document.getElementById('prompt-textarea').value") { result, error in
                    precondition(error == nil && result as? String == "原有问题\n\n附件学习背景：\n" + prompt, "Textarea composers must preserve the question and append the prompt")
                    print("PASS: textarea composer receives the prompt while preserving its existing question")
                    self.runMissingAttachmentInputTests()
                }
            }
        } catch { fatalError("Attachment resource failed: \(error)") }
    }

    private func runMissingAttachmentInputTests() {
        do {
            let script = try attachmentScript()
            webView.callAsyncJavaScript("document.getElementById('document-upload').remove();\n" + script,
                                       arguments: ["content": "test", "filename": "test.md", "studyPrompt": "test"], in: nil, in: .page) { result in
                guard case .success(let state) = result, state as? String == "no-file-input" else {
                    fatalError("Missing document input must be reported: \(result)")
                }
                self.webView.callAsyncJavaScript("document.getElementById('prompt-textarea').remove();\n" + script,
                                                arguments: ["content": "test", "filename": "test.md", "studyPrompt": "test"], in: nil, in: .page) { result in
                    guard case .success(let state) = result, state as? String == "not-ready" else {
                        fatalError("A login or loading page must not report a successful upload: \(result)")
                    }
                    print("PASS: missing upload input, login/loading state, persistent profile, safe conversation restore")
                    self.runQuestionComposerTests()
                }
            }
        } catch { fatalError("Attachment resource failed: \(error)") }
    }

    private func runQuestionComposerTests(_ index: Int = 0) {
        let code = """
        <div data-message-author-role="assistant">
          <pre><textarea aria-label="编辑代码">print('保留代码')</textarea></pre>
          <div class="cm-editor" contenteditable="true">def task(): return 1</div>
        </div>
        """
        let cases: [(String, String, Bool)] = [
            ("<form><div contenteditable='true' role='textbox' data-placeholder='询问 ChatGPT'>已有问题</div><button data-testid='send-button'>发送</button></form>", "已有问题", true),
            ("<div id='prompt-textarea'><textarea hidden>隐藏框</textarea><div contenteditable='true'>已有问题</div></div>", "已有问题", true),
            ("<div id='prompt-textarea' contenteditable='true'></div>", "", true),
            ("<form><textarea placeholder='Message ChatGPT'>已有问题</textarea></form>", "已有问题", true),
            ("", "", false),
            ("<form><div contenteditable='true'>已有问题</div></form>", "已有问题", false)
        ]
        guard index < cases.count else {
            print("PASS: native paste into chat composer, code editors untouched, wrapper/textarea targeting, failed paste detected, clipboard restored, no automatic send")
            runReaderStyleTest()
            return
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let testCase = cases[index]
        let prompt = "解释这段文字\n\n文档片段：\n中文 😀 print('example') <script>示例</script>"
        let expected = testCase.1.isEmpty ? prompt : testCase.1 + "\n\n" + prompt
        let clipboardBefore = NSPasteboard.general.string(forType: .string)
        webView.callAsyncJavaScript("""
        document.body.innerHTML = html;
        window.codeBefore = Array.from(document.querySelectorAll('[data-message-author-role] textarea, [data-message-author-role] [contenteditable]')).map(element => element.tagName === 'TEXTAREA' ? element.value : element.innerText);
        window.submitCount = 0;
        document.onsubmit = event => { event.preventDefault(); window.submitCount++; };
        document.onpaste = blockPaste ? event => event.preventDefault() : null;
        document.execCommand = () => false;
        """, arguments: ["html": code + testCase.0, "blockPaste": index == 5], in: nil, in: .page) { result in
            guard case .success = result else { fatalError("Question fixture failed: \(result)") }
            self.fillChatComposer(prompt) { success, detail in
                precondition(success == testCase.2, "Question case \(index) reported the wrong insertion status: \(detail)")
                precondition(NSPasteboard.general.string(forType: .string) == clipboardBefore, "Question insertion must restore the user's clipboard")
                self.webView.callAsyncJavaScript("""
                const after = Array.from(document.querySelectorAll('[data-message-author-role] textarea, [data-message-author-role] [contenteditable]')).map(element => element.tagName === 'TEXTAREA' ? element.value : element.innerText);
                const composer = window.studyChatComposer.find();
                return { codeUntouched: after.every((value, i) => value === window.codeBefore[i]),
                  submitCount: window.submitCount,
                  draft: composer ? window.studyChatComposer.read(composer) : null };
                """, arguments: [:], in: nil, in: .page) { result in
                    guard case .success(let value) = result, let data = value as? [String: Any] else { fatalError("Cannot inspect question insertion: \(result)") }
                    precondition(data["codeUntouched"] as? Bool == true, "A question must never modify answer code blocks")
                    precondition(data["submitCount"] as? Int == 0, "A question must stay in the composer until the user sends it")
                    if success {
                        precondition((data["draft"] as? String)?.trimmingCharacters(in: .newlines) == expected, "The composer must contain the complete selection and preserve the existing draft")
                    }
                    self.runQuestionComposerTests(index + 1)
                }
            }
        }
    }

    private func runReaderStyleTest() {
        window.contentView?.layoutSubtreeIfNeeded()
        let readingHeight = previewWebView.frame.height
        precondition(documentSearchRow.isHidden, "Document search should stay out of the reading area until requested")
        toggleDocumentSearch()
        precondition(!documentSearchRow.isHidden && previewWebView.frame.height < readingHeight - 20, "Showing search must reserve space without covering the document")
        toggleDocumentSearch()
        precondition(documentSearchRow.isHidden && abs(previewWebView.frame.height - readingHeight) < 1, "Closing search must return the space to the document")
        precondition(documentPathLabel.stringValue.hasSuffix("第一课.md"), "The breadcrumb must identify the open document")
        editor.string = """
        # 专注阅读，让问题变清晰

        这是一份用于检查阅读排版的示例。阅读一段文字，提出一个问题，再把理解沉淀到笔记里。

        ## 让知识成为自己的理解

        正文保持舒适的行距，**重要概念**清晰可见。可以结合[相关内容](#example)继续阅读，并用 `测试预言` 这样的术语建立联系。

        > 好的解释不止给出结论，还会说明依据，以及一个能够自己验证的例子。

        ### 用例与证据

        | 检查点 | 预期 | 证据 |
        | --- | --- | --- |
        | 每日领奖 | 金币增加 100 | 余额与领奖状态 |
        | 重复领取 | 不重复发奖 | 服务端记录 |

        ### 在实践中确认

        ```python
        def test_daily_reward():
            balance_before = 500
            balance_after = claim_reward()
            assert balance_after == balance_before + 100
        ```

        1. 先说清楚规则与预期。
        2. 自己设计一次操作，核对关键状态。
        3. 合上文档，用自己的语言解释。

        <a id="safe-anchor"></a>
        <img src="missing-local-image.png" onerror="window.unsafeMarkdownExecuted = true">
        """
        testingReaderStyle = true
        previewWebView.navigationDelegate = self
        renderMarkdown()
    }

    private func inspectReaderStyle() {
        previewWebView.evaluateJavaScript("""
        (() => {
          const article = document.querySelector('article');
          const bodyStyle = getComputedStyle(document.body);
          return {
            headings: article.querySelectorAll('h1,h2,h3').length,
            tables: article.querySelectorAll('table').length,
            codeBlocks: article.querySelectorAll('pre code').length,
            fontSize: bodyStyle.fontSize,
            maxWidth: getComputedStyle(article).maxWidth,
            background: bodyStyle.backgroundColor,
            headingBorder: getComputedStyle(article.querySelector('h2')).borderBottomWidth,
            overflow: document.documentElement.scrollWidth > document.documentElement.clientWidth,
            sanitized: !article.querySelector('[onerror]') && !window.unsafeMarkdownExecuted && Boolean(document.getElementById('safe-anchor'))
          };
        })()
        """) { result, error in
            guard error == nil, let layout = result as? [String: Any] else { fatalError("Reader render failed: \(String(describing: error))") }
            precondition(layout["headings"] as? Int == 4 && layout["tables"] as? Int == 1 && layout["codeBlocks"] as? Int == 1, "Reading styles must preserve headings, tables and code")
            precondition(layout["fontSize"] as? String == "16px" && layout["maxWidth"] as? String == "780px", "Reading styles must provide the intended type size and readable line length")
            precondition(layout["headingBorder"] as? String == "0px", "Headings must use the clean Obsidian-style hierarchy")
            precondition(layout["overflow"] as? Bool == false, "Tables and code must not overflow the reading pane")
            precondition(layout["sanitized"] as? Bool == true, "HTML event handlers must be removed while document anchors remain available")
            print("PASS: document breadcrumb, search show/hide layout, rendered typography, tables, code, no page overflow")
            self.previewWebView.takeSnapshot(with: nil) { image, error in
                if let data = image?.tiffRepresentation,
                   let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
                    do {
                        let folder = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("output")
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        let url = folder.appendingPathComponent("reader-preview.png")
                        try png.write(to: url)
                        print("Reader preview: \(url.path)")
                    } catch { print("Reader preview could not be saved: \(error)") }
                } else { print("Reader screenshot unavailable: \(String(describing: error))") }
                self.runReadingNavigationTests()
            }
        }
    }

    private func runReadingNavigationTests() {
        window.makeKeyAndOrderFront(nil)
        readingTestMarkdown = "# 阅读进度测试\n\n" + (1...40).map { number in
            "## 第 \(number) 课：标题导航\n\n" + String(repeating: "阅读这一课的正文，核对示例与依据。\n\n", count: 10)
            + "### 相同的小节标题\n\n" + String(repeating: "小节说明。\n\n", count: 4)
            + "```markdown\n# 代码块里的内容不是目录标题\n```\n\n"
        }.joined()
        documentURL = URL(fileURLWithPath: "/study-companion-reading-test/lesson.md")
        editor.string = readingTestMarkdown
        if CommandLine.arguments.contains("--test-reading-read") {
            guard let bookmark = readingPositions[documentURL.path] else { fatalError("No saved reading position from the previous process") }
            readingTestBookmark = bookmark
            readingNavigationTestPhase = 2
        } else {
            readingNavigationTestPhase = 1
        }
        renderMarkdown()
    }

    private func inspectReadingNavigation() {
        let phase = readingNavigationTestPhase
        let script = phase == 1 ? """
        const headings = Array.from(document.querySelectorAll('#content h1,h2,h3'));
        const panel = document.getElementById('document-outline');
        const panelShowsActive = () => {
          const active = panel.querySelector('a[aria-current="location"]');
          const rect = active.getBoundingClientRect();
          const bounds = panel.getBoundingClientRect();
          return rect.top >= bounds.top + 40 && rect.bottom <= bounds.bottom - 12;
        };
        const lowerHeading = document.querySelectorAll('#content h2')[34];
        window.scrollTo(0, lowerHeading.getBoundingClientRect().top + window.scrollY - 24);
        const bodyBeforeFollow = window.scrollY;
        window.dispatchEvent(new Event('scroll'));
        const followsDown = panel.scrollTop > 0 && panelShowsActive()
          && panel.querySelector('a.is-active').dataset.heading === lowerHeading.id;
        const bodyUnchanged = window.scrollY === bodyBeforeFollow;
        const upperHeading = document.querySelectorAll('#content h2')[4];
        window.scrollTo(0, upperHeading.getBoundingClientRect().top + window.scrollY - 24);
        window.dispatchEvent(new Event('scroll'));
        const followsUp = panelShowsActive() && panel.querySelector('a.is-active').dataset.heading === upperHeading.id;
        const nestedHeading = document.querySelectorAll('#content h3')[4];
        const nestedLink = Array.from(panel.querySelectorAll('a')).find(link => link.dataset.heading === nestedHeading.id);
        nestedLink.closest('details').open = false;
        window.scrollTo(0, nestedHeading.getBoundingClientRect().top + window.scrollY - 24);
        window.dispatchEvent(new Event('scroll'));
        const revealsFolded = nestedLink.closest('details').open && panelShowsActive();
        const target = document.querySelectorAll('#content h2')[19];
        const link = Array.from(document.querySelectorAll('#document-outline a')).find(link => link.dataset.heading === target.id);
        link.click();
        window.scrollBy(0, 90);
        await new Promise(resolve => setTimeout(resolve, 0));
        return { position: window.readerNavigation.getPosition(), target: target.id,
          followsDown, followsUp, bodyUnchanged, revealsFolded,
          uniqueIDs: new Set(headings.map(heading => heading.id)).size === headings.length,
          count: document.querySelectorAll('#document-outline a').length,
          active: document.querySelector('#document-outline a[aria-current="location"]').dataset.heading };
        """ : """
        await new Promise(resolve => setTimeout(resolve, 0));
        return { position: window.readerNavigation.getPosition() };
        """
        previewWebView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
            guard case .success(let value) = result, let data = value as? [String: Any],
                  let position = data["position"] as? [String: Any] else { fatalError("Reading navigation failed: \(result)") }
            if phase == 1 {
                precondition(data["followsDown"] as? Bool == true && data["followsUp"] as? Bool == true, "The outline must keep the current chapter visible while reading downward and upward")
                precondition(data["bodyUnchanged"] as? Bool == true, "Following the active heading must scroll only the outline, not move the body")
                precondition(data["revealsFolded"] as? Bool == true, "The active chapter must be revealed inside a collapsed outline group")
                print("PASS: outline follows body down/up, reveals folded active chapter, and does not shift the document")
                precondition(data["count"] as? Int == 81, "Outline must include every heading and exclude Markdown inside code blocks")
                precondition(data["uniqueIDs"] as? Bool == true, "Repeated heading titles must have unique jump targets")
                precondition(position["headingID"] as? String == data["target"] as? String && data["active"] as? String == data["target"] as? String, "Clicking the outline must jump and mark the current heading")
                precondition(abs((position["headingOffset"] as? Double ?? 0) - 66) < 2, "Reading position must include the offset inside the section")
                self.saveReadingPosition(position)
                self.readingTestBookmark = position
                print("PASS: 81 hierarchical headings, repeated title IDs, actual outline click, active chapter, in-section offset")
                if CommandLine.arguments.contains("--test-reading-write") {
                    print("PASS: reading bookmark saved for process restart")
                    NSApp.terminate(nil)
                    return
                }
                self.workspaceController.splitView.setPosition(1050, ofDividerAt: 1)
                self.window.contentView?.layoutSubtreeIfNeeded()
                self.readingNavigationTestPhase = 2
                self.renderMarkdown()
            } else if phase == 2 || phase == 4 {
                let expected = self.readingTestBookmark!
                precondition(position["headingID"] as? String == expected["headingID"] as? String, "Reopening must restore the same chapter")
                precondition(abs((position["headingOffset"] as? Double ?? 0) - (expected["headingOffset"] as? Double ?? 0)) < 2, "Reopening must restore the offset, including after a width change")
                if CommandLine.arguments.contains("--test-reading-read") {
                    print("PASS: previous process's chapter and paragraph offset restored")
                    NSApp.terminate(nil)
                    return
                }
                if phase == 4 {
                    self.readingNavigationTestPhase = 0
                    print("PASS: restored chapter and offset after re-render/resize; independent per-document bookmarks")
                    NSApp.terminate(nil)
                    return
                }
                self.readingNavigationTestPhase = 3
                self.documentURL = URL(fileURLWithPath: "/study-companion-reading-test/other.md")
                self.editor.string = "# 另一份文档\n\n" + String(repeating: "另一份文档的正文。\n\n", count: 60)
                self.renderMarkdown()
            } else {
                precondition(abs(position["scrollY"] as? Double ?? -1) < 1, "An unread document must start at the top")
                self.readingNavigationTestPhase = 4
                self.documentURL = URL(fileURLWithPath: "/study-companion-reading-test/lesson.md")
                self.editor.string = self.readingTestMarkdown
                self.renderMarkdown()
            }
        }
    }

    private func runSessionPersistenceTest() {
        let store = WKWebsiteDataStore.default()
        precondition(store.isPersistent)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        webView = WKWebView(frame: .zero, configuration: configuration)
        let cookieName = "StudyCompanionPersistenceTest"
        let cookieDomain = "study-companion.invalid"
        if CommandLine.arguments.contains("--test-session-write") {
            let cookie = HTTPCookie(properties: [
                .name: cookieName, .value: "persistence-test", .domain: cookieDomain,
                .path: "/", .expires: Date().addingTimeInterval(3600)
            ])!
            store.httpCookieStore.setCookie(cookie) {
                store.httpCookieStore.getAllCookies { cookies in
                    precondition(cookies.contains { $0.name == cookieName }, "The test cookie must be present in the writer process")
                    store.fetchDataRecords(ofTypes: [WKWebsiteDataTypeCookies]) { _ in
                        print("PASS: test session cookie stored in the existing persistent profile")
                        NSApp.terminate(nil)
                    }
                }
            }
        } else {
            store.httpCookieStore.getAllCookies { cookies in
                guard let cookie = cookies.first(where: { $0.name == cookieName && $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == cookieDomain }) else {
                    fputs("FAIL: persistent cookie did not survive application restart\n", stderr)
                    exit(1)
                }
                store.httpCookieStore.delete(cookie) {
                    print("PASS: session cookie survived process restart; test cookie removed")
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func inspectLiveChatComposer() {
        webView.callAsyncJavaScript("""
        const find = () => window.studyChatComposer && window.studyChatComposer.find();
        let composer = find();
        if (!composer) {
          await new Promise(resolve => {
            const observer = new MutationObserver(() => {
              if (find()) { observer.disconnect(); clearTimeout(timeout); resolve(); }
            });
            const timeout = setTimeout(() => { observer.disconnect(); resolve(); }, 10000);
            observer.observe(document.body, { childList: true, subtree: true, attributes: true });
          });
          composer = find();
        }
        return composer ? {
          found: true, tag: composer.tagName, id: composer.id,
          inForm: Boolean(composer.closest('form')),
          inCode: Boolean(composer.closest('pre,code,.cm-editor,.monaco-editor,[data-message-author-role]'))
        } : { found: false };
        """, arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value): print("Live chat composer (read-only): \(value)")
            case .failure(let error): print("Live composer inspection failed: \(error)")
            }
            NSApp.terminate(nil)
        }
    }
}

extension AppDelegate: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        setStatus("正在打开 ChatGPT…")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === previewWebView {
            if readingNavigationTestPhase > 0 {
                inspectReadingNavigation()
                return
            }
            if testingReaderStyle {
                testingReaderStyle = false
                inspectReaderStyle()
            }
            return
        }
        if testingChatAttachment {
            testingChatAttachment = false
            runAttachmentTest()
            return
        }
        rememberChatURL()
        setStatus("ChatGPT 已就绪")
        if CommandLine.arguments.contains("--inspect-chat-composer") {
            inspectLiveChatComposer()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        setStatus("ChatGPT 加载失败：\(error.localizedDescription)")
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let requestURL = navigationAction.request.url {
            webView.load(URLRequest(url: requestURL))
        }
        return nil
    }
}

@main
struct StudyCompanionApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

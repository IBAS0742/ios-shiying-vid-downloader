import SwiftUI
import UIKit

struct TelegramHubView: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var session = TelegramSession.shared
    @Environment(\.scenePhase) private var scenePhase

    var onPlay: (VideoItem) -> Void
    var onAddLink: () -> Void
    var onSettings: () -> Void

    @State private var mode: Mode = .browse
    @State private var chats: [TelegramChatSummary] = []
    @State private var isLoadingChats = false
    @State private var hasLoadedChats = false
    @State private var chatError: String?
    @State private var query = ""
    @State private var selectedChat: TelegramChatSummary?
    @State private var showLogin = false
    @State private var showSort = false

    @State private var access: TelegramAccessState = TelegramAccessPassword.isSet
        ? TelegramAccessGate.state
        : .locked
    @State private var hasAccessPassword = TelegramAccessPassword.isSet
    @State private var passwordInput = ""
    @State private var passwordConfirmation = ""
    @State private var passwordError: String?
    @State private var lastWrongPassword: String? = TelegramAccessGate.lastWrongPassword
    @FocusState private var focusedPasswordField: PasswordField?

    private enum PasswordField: Hashable {
        case password
        case confirmation
    }

    private enum Mode: String, CaseIterable {
        case browse = "群组/频道"
        case downloaded = "已下载"
    }

    var body: some View {
        ZStack {
            if access == .unlocked {
                realContent
            } else if access == .decoy {
                TelegramDecoyView(onRefresh: returnToPasswordInput)
                    .transition(.opacity)
            } else {
                lockScreen
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: access)
        .animation(.easeInOut(duration: 0.22), value: selectedChat?.id)
        .sheet(isPresented: $showLogin) {
            TelegramLoginView(session: session)
        }
        .task(id: access) {
            await prepareTelegramIfUnlocked()
        }
        .task(id: session.phase) {
            guard access == .unlocked, session.phase.isReady else { return }
            await loadChats()
        }
        .task {
            guard ProcessInfo.processInfo.environment["SHIYING_TG_DECOY"] == "1" else { return }
            AppLog.info("telegram decoy forced from env")
            access = .decoy
        }
        .onChange(of: session.phase) { _, newPhase in
            if !newPhase.isReady {
                hasLoadedChats = false
                chats = []
                chatError = nil
                selectedChat = nil
            }
        }
        .onChange(of: access) { _, newValue in
            TelegramAccessGate.state = newValue
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                guard access == .unlocked else { return }
                Task { await prepareTelegramIfUnlocked() }
            } else {
                clearTransientContent()
            }
        }
    }

    @ViewBuilder
    private var realContent: some View {
        if let chat = selectedChat {
            TelegramChatVideosView(
                store: store,
                chat: chat,
                onBack: {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        selectedChat = nil
                    }
                },
                onPlay: onPlay
            )
            .transition(.move(edge: .trailing).combined(with: .opacity))
        } else {
            hub
                .transition(.opacity)
        }
    }

    // MARK: - Access password

    private var lockScreen: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 9) {
                    Image(systemName: MediaSource.telegram.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(hex: MediaSource.telegram.accentHex))
                        .frame(width: 34, height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Color(hex: MediaSource.telegram.accentHex).opacity(0.13))
                        )
                    Text("Telegram")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(Palette.text)
                }

                VStack(spacing: 16) {
                    Image(systemName: hasAccessPassword ? "lock.shield.fill" : "lock.fill")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(Palette.amber)
                        .frame(width: 84, height: 84)
                        .background(Circle().fill(Palette.amber.opacity(0.1)))
                        .overlay(Circle().strokeBorder(Palette.amber.opacity(0.18), lineWidth: 1))

                    VStack(spacing: 7) {
                        Text(hasAccessPassword ? "需要访问密码" : "设置访问密码")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(Palette.text)
                        Text(
                            hasAccessPassword
                                ? "访问密码保护整个 Telegram 模块，包括群组浏览和已下载列表。"
                                : "第一次使用请设置一个访问密码，之后每次查看都需要输入。"
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                    }

                    VStack(spacing: 10) {
                        SecureField("访问密码", text: $passwordInput)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(hasAccessPassword ? .go : .next)
                            .font(.system(size: 14))
                            .foregroundStyle(Palette.text)
                            .padding(12)
                            .background(fieldBackground)
                            .focused($focusedPasswordField, equals: .password)
                            .onSubmit {
                                if hasAccessPassword {
                                    submitPassword()
                                } else {
                                    focusedPasswordField = .confirmation
                                }
                            }

                        if !hasAccessPassword {
                            SecureField("再次输入密码", text: $passwordConfirmation)
                                .textContentType(.password)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.done)
                                .font(.system(size: 14))
                                .foregroundStyle(Palette.text)
                                .padding(12)
                                .background(fieldBackground)
                                .focused($focusedPasswordField, equals: .confirmation)
                                .onSubmit(submitPassword)
                        }

                        if let passwordError {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.system(size: 10))
                                Text(passwordError)
                                    .font(.system(size: 10, weight: .medium))
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(Palette.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Button(action: submitPassword) {
                            Text(hasAccessPassword ? "进入" : "保存并进入")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(Palette.background)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(Capsule().fill(Palette.amber))
                        }
                        .buttonStyle(ScaleButtonStyle())

                        if hasAccessPassword, passwordError != nil {
                            Button {
                                resetPasswordEntry()
                            } label: {
                                Label("刷新并重新输入", systemImage: "arrow.clockwise")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Palette.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 9)
                                    .background(Capsule().fill(Color.white.opacity(0.06)))
                                    .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1))
                            }
                            .buttonStyle(ScaleButtonStyle())

                            Text("也可以下拉页面清除错误，再输入密码。")
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if !hasAccessPassword {
                            Text("密码至少 \(TelegramAccessPassword.minimumLength) 位，只保存在本机。")
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(20)
                .glassPanel(cornerRadius: 26, fill: Palette.card.opacity(0.72))

                Color.clear.frame(height: 120)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable {
            await MainActor.run {
                resetPasswordEntry()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let hint = lastWrongPassword, !hint.isEmpty {
                Text(hint)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.secondary.opacity(0.32))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.trailing, 22)
                    .padding(.bottom, 24)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Palette.cardLift)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Palette.line, lineWidth: 1)
            )
    }

    private func submitPassword() {
        guard access == .locked else { return }
        let value = passwordInput.trimmingCharacters(in: .whitespacesAndNewlines)

        if hasAccessPassword {
            if TelegramAccessPassword.verify(value) {
                unlockTelegram()
                return
            }

            guard !value.isEmpty else {
                passwordError = "请输入访问密码"
                return
            }

            if let storedWrong = TelegramAccessGate.lastWrongPassword {
                guard value == storedWrong else {
                    passwordInput = ""
                    passwordError = "密码错误，请重新输入"
                    AppLog.info("telegram access password rejected; retry did not match previous attempt")
                    return
                }
            } else {
                TelegramAccessGate.lastWrongPassword = value
                lastWrongPassword = value
            }

            passwordInput = ""
            passwordError = nil
            withAnimation(.easeInOut(duration: 0.22)) {
                access = .decoy
            }
            AppLog.info("telegram access password rejected; showing decoy")
            return
        }

        guard value.count >= TelegramAccessPassword.minimumLength else {
            passwordError = "密码至少需要 \(TelegramAccessPassword.minimumLength) 位"
            return
        }
        let confirmation = passwordConfirmation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value == confirmation else {
            passwordError = "两次输入的密码不一致"
            return
        }
        guard TelegramAccessPassword.set(value), TelegramAccessPassword.isSet else {
            passwordError = "无法保存密码，请重试"
            return
        }

        hasAccessPassword = true
        unlockTelegram()
        AppLog.info("telegram access password configured")
    }

    private func unlockTelegram() {
        passwordInput = ""
        passwordConfirmation = ""
        passwordError = nil
        TelegramAccessGate.lastWrongPassword = nil
        lastWrongPassword = nil
        withAnimation(.easeInOut(duration: 0.22)) {
            access = .unlocked
        }
    }

    private func resetPasswordEntry() {
        passwordInput = ""
        passwordConfirmation = ""
        passwordError = nil
        focusedPasswordField = hasAccessPassword ? .password : nil
        AppLog.info("telegram access password entry reset")
    }

    private func returnToPasswordInput() {
        passwordInput = ""
        passwordConfirmation = ""
        passwordError = nil
        focusedPasswordField = .password
        withAnimation(.easeInOut(duration: 0.22)) {
            access = .locked
        }
        AppLog.info("telegram access password retry requested")
    }

    private func clearTransientContent() {
        // Leaving the foreground must not leave typed secrets, search terms,
        // Telegram chats, or Telegram-specific sheets in memory or on screen.
        // The gate itself stays where it was; only a pull-to-refresh reopens it.
        passwordInput = ""
        passwordConfirmation = ""
        passwordError = nil
        focusedPasswordField = nil
        showLogin = false
        showSort = false
        query = ""
        selectedChat = nil
        chats = []
        hasLoadedChats = false
        chatError = nil
    }

    private func prepareTelegramIfUnlocked() async {
        guard access == .unlocked else { return }
        session.bootstrap()
        if session.phase.isReady {
            await loadChats()
        }
    }

    // MARK: - Hub

    private var hub: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                header
                debugCard
                modePicker

                if mode == .browse {
                    browseContent
                } else {
                    downloadedContent
                }

                Color.clear.frame(height: 120)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable {
            if mode == .browse {
                await loadChats(force: true)
            } else {
                await store.refresh()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 9) {
                    Image(systemName: MediaSource.telegram.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(hex: MediaSource.telegram.accentHex))
                        .frame(width: 34, height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Color(hex: MediaSource.telegram.accentHex).opacity(0.13))
                        )
                    Text("Telegram")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(Palette.text)
                }

                Text(headerSubtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.secondary)

                statusChip
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Button(action: onSettings) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Palette.secondary)
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(Color.white.opacity(0.07)))
                        .overlay(Circle().strokeBorder(Palette.line, lineWidth: 1))
                }
                .buttonStyle(ScaleButtonStyle())
                .accessibilityLabel("Telegram 设置")

                Button(action: onAddLink) {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Palette.background)
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(Palette.amber))
                        .shadow(color: Palette.amber.opacity(0.25), radius: 14, y: 6)
                }
                .buttonStyle(ScaleButtonStyle())
                .accessibilityLabel("通过链接添加视频")
            }
        }
    }

    @ViewBuilder
    private var debugCard: some View {
        if ProcessInfo.processInfo.environment["SHIYING_TG_DEBUG"] == "1" {
            VStack(alignment: .leading, spacing: 3) {
                Text("TDLib: \(session.connectionStateText.isEmpty ? "—" : session.connectionStateText)")
                Text(session.downloadDebugText.isEmpty ? "download: —" : "download: \(session.downloadDebugText)")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Palette.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
        }
    }

    private var headerSubtitle: String {
        if session.phase.isReady {
            if chats.isEmpty {
                return "已登录 · 正在同步你的会话"
            }
            return "\(chats.count) 个群组/频道 · \(telegramReadyItems.count) 部已下载"
        }
        return "登录后直接浏览已加入的群组和频道"
    }

    private var statusChip: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(statusColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(statusColor.opacity(0.12)))
    }

    private var statusText: String {
        switch session.phase {
        case .ready:
            return session.profileLabel
        case .starting:
            return "正在连接…"
        case .waitingForQR:
            return "等待扫码"
        case .passwordRequired:
            return "等待两步验证密码"
        case .unconfigured:
            return "未配置 API"
        case .failed:
            return "连接失败"
        case .stopped:
            return "未登录"
        }
    }

    private var statusColor: Color {
        switch session.phase {
        case .ready:
            return Palette.mint
        case .starting, .waitingForQR, .passwordRequired:
            return Palette.amber
        case .failed:
            return Palette.danger
        case .unconfigured, .stopped:
            return Palette.tertiary
        }
    }

    private var modePicker: some View {
        HStack(spacing: 4) {
            ForEach(Mode.allCases, id: \.self) { item in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        mode = item
                    }
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(mode == item ? Palette.background : Palette.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            Capsule().fill(
                                mode == item
                                    ? AnyShapeStyle(
                                        LinearGradient(
                                            colors: [Palette.amber, Color(hex: 0xFFD38A)],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    : AnyShapeStyle(Color.clear)
                            )
                        )
                }
                .buttonStyle(ScaleButtonStyle())
            }
        }
        .padding(4)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.055))
                .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1))
        )
    }

    // MARK: - Browse

    @ViewBuilder
    private var browseContent: some View {
        if !session.phase.isReady {
            loginCard
        } else if isLoadingChats && chats.isEmpty {
            loadingCard(text: "正在读取你加入的群组和频道…")
        } else if let chatError, chats.isEmpty {
            errorCard(chatError)
        } else if chats.isEmpty {
            emptyChatsCard
        } else {
            searchField

            if filteredChats.isEmpty {
                Text("没有匹配「\(query)」的群组或频道")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                HStack(spacing: 10) {
                    SectionLabel(title: "群组与频道", count: filteredChats.count)
                    Text("长按可置顶")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Palette.tertiary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.05)))
                }
                LazyVStack(spacing: 8) {
                    ForEach(pinnedChats) { chat in
                        chatRow(chat)
                    }

                    if !pinnedChats.isEmpty && !otherChats.isEmpty {
                        HStack(spacing: 10) {
                            Rectangle()
                                .fill(Palette.line)
                                .frame(height: 1)
                            Text("其他会话")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Palette.tertiary)
                                .fixedSize()
                            Rectangle()
                                .fill(Palette.line)
                                .frame(height: 1)
                        }
                        .padding(.vertical, 9)
                    }

                    ForEach(otherChats) { chat in
                        chatRow(chat)
                    }
                }
            }

            if isLoadingChats {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Palette.secondary)
                    Text("正在刷新…")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var filteredChats: [TelegramChatSummary] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = keyword.isEmpty
            ? chats
            : chats.filter { $0.title.localizedCaseInsensitiveContains(keyword) }

        var originalOrder: [Int64: Int] = [:]
        for (index, chat) in chats.enumerated() {
            originalOrder[chat.id] = index
        }

        return matches.sorted { lhs, rhs in
            let lhsPinned = store.isTelegramChatPinned(lhs.id)
            let rhsPinned = store.isTelegramChatPinned(rhs.id)
            if lhsPinned != rhsPinned {
                return lhsPinned
            }
            return originalOrder[lhs.id, default: 0] < originalOrder[rhs.id, default: 0]
        }
    }

    private var pinnedChats: [TelegramChatSummary] {
        filteredChats.filter { store.isTelegramChatPinned($0.id) }
    }

    private var otherChats: [TelegramChatSummary] {
        filteredChats.filter { !store.isTelegramChatPinned($0.id) }
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.tertiary)
            TextField("搜索群组或频道", text: $query)
                .font(.system(size: 13))
                .foregroundStyle(Palette.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.055))
                .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1))
        )
    }

    private func chatRow(_ chat: TelegramChatSummary) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) {
                selectedChat = chat
            }
        } label: {
            HStack(spacing: 12) {
                TelegramChatAvatar(data: chat.photoData, kind: chat.kind, size: 46)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(chat.title)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(Palette.text)
                            .lineLimit(1)

                        if chat.isArchived {
                            Text("归档")
                                .font(.system(size: 8, weight: .heavy, design: .rounded))
                                .foregroundStyle(Palette.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.white.opacity(0.07)))
                        }

                        if store.isTelegramChatPinned(chat.id) {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Palette.amber)
                        }
                    }

                    HStack(spacing: 6) {
                        Text(chat.kind.label)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color(hex: MediaSource.telegram.accentHex))
                        if let dateText = TelegramDateFormat.listDate(chat.lastMessageDate) {
                            Text("·")
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.tertiary)
                            Text(dateText)
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.tertiary)
                        }
                    }
                }

                Spacer(minLength: 6)

                if chat.unreadCount > 0 {
                    Text(chat.unreadCount > 99 ? "99+" : "\(chat.unreadCount)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(Palette.background)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Palette.amber))
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Palette.tertiary)
            }
            .padding(10)
            .glassPanel(cornerRadius: 20, fill: Palette.card.opacity(0.78))
        }
        .buttonStyle(ScaleButtonStyle())
        .contextMenu {
            Button {
                store.toggleTelegramChatPin(chat.id)
            } label: {
                Label(
                    store.isTelegramChatPinned(chat.id) ? "取消置顶" : "置顶显示",
                    systemImage: store.isTelegramChatPinned(chat.id) ? "pin.slash" : "pin"
                )
            }
        }
    }

    private var loginCard: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color(hex: MediaSource.telegram.accentHex).opacity(0.1))
                    .frame(width: 92, height: 92)
                Circle()
                    .strokeBorder(Color(hex: MediaSource.telegram.accentHex).opacity(0.22), lineWidth: 1)
                    .frame(width: 92, height: 92)
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Color(hex: MediaSource.telegram.accentHex))
            }

            VStack(spacing: 7) {
                Text(loginTitle)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.text)
                Text(loginDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            if case .starting = session.phase {
                ProgressView()
                    .controlSize(.large)
                    .tint(Palette.amber)
                    .padding(.vertical, 6)
            } else {
                Button {
                    if case .unconfigured = session.phase {
                        onSettings()
                    } else {
                        showLogin = true
                    }
                } label: {
                    Label(loginActionTitle, systemImage: loginActionIcon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.background)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 11)
                        .background(Capsule().fill(Palette.amber))
                }
                .buttonStyle(ScaleButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 18)
        .glassPanel(cornerRadius: 26, fill: Palette.card.opacity(0.6))
    }

    private var loginTitle: String {
        switch session.phase {
        case .unconfigured:
            return "先配置 Telegram API"
        case .starting:
            return "正在连接 Telegram"
        case .failed:
            return "登录遇到问题"
        default:
            return "登录 Telegram 浏览群组"
        }
    }

    private var loginDetail: String {
        switch session.phase {
        case .unconfigured:
            return "在设置里填入自己的 API ID 和 API Hash（免费），再回来扫码登录。凭证只保存在本机钥匙串。"
        case .starting:
            return "正在恢复访问码登录状态，请稍候。"
        case .waitingForQR, .passwordRequired:
            return "登录还没完成，继续扫码或输入两步验证密码即可。"
        case .failed(let message):
            return message
        case .stopped:
            return "会话已停止，重新登录后就能读取你加入的群组和频道。"
        case .ready:
            return ""
        }
    }

    private var loginActionTitle: String {
        switch session.phase {
        case .unconfigured:
            return "打开设置"
        case .waitingForQR, .passwordRequired:
            return "继续扫码登录"
        case .failed:
            return "重试登录"
        default:
            return "扫码登录"
        }
    }

    private var loginActionIcon: String {
        switch session.phase {
        case .unconfigured:
            return "gearshape.fill"
        case .failed:
            return "arrow.clockwise"
        default:
            return "qrcode"
        }
    }

    private var emptyChatsCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Palette.tertiary)
            Text("没有找到群组或频道")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.text)
            Text("这里只显示这个 Telegram 账号已加入的群组和频道。可以先去 Telegram 官方 App 加入，再下拉刷新。")
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            Button {
                Task { await loadChats(force: true) }
            } label: {
                Label("重新读取", systemImage: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.background)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Palette.amber))
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .glassPanel(cornerRadius: 24, fill: Palette.card.opacity(0.6))
    }

    private func loadingCard(text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(Palette.amber)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
            Spacer()
        }
        .padding(16)
        .glassPanel(cornerRadius: 18, fill: Palette.card.opacity(0.7))
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.danger)
                    .padding(.top, 1)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                    .lineSpacing(2)
            }
            Button {
                Task { await loadChats(force: true) }
            } label: {
                Label("重新读取", systemImage: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.background)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Palette.amber))
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassPanel(cornerRadius: 20, fill: Palette.card.opacity(0.7))
    }

    // MARK: - Downloaded

    private var telegramReadyItems: [VideoItem] {
        store.playlist.filter { $0.source == .telegram && $0.status == .ready }
    }

    private var telegramActiveItems: [VideoItem] {
        store.downloadsGroup.filter { $0.source == .telegram }
    }

    @ViewBuilder
    private var downloadedContent: some View {
        if !telegramActiveItems.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.amber)
                Text("还有 \(telegramActiveItems.count) 个 Telegram 任务在下载，可到 D 面板查看进度")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
        }

        if telegramReadyItems.isEmpty {
            downloadedEmptyCard
        } else {
            HStack(spacing: 10) {
                SectionLabel(title: "已下载", count: telegramReadyItems.count)

                if telegramReadyItems.count > 1 {
                    Button {
                        showSort = true
                    } label: {
                        Label("排序", systemImage: "arrow.up.arrow.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(hex: MediaSource.telegram.accentHex))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(
                                    Color(hex: MediaSource.telegram.accentHex).opacity(0.12)
                                )
                            )
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .accessibilityLabel("调整播放顺序")
                }
            }

            LazyVStack(spacing: 10) {
                ForEach(telegramReadyItems) { item in
                    VideoRow(store: store, item: item) {
                        onPlay(item)
                    }
                }
            }
            .sheet(isPresented: $showSort) {
                PlaylistSortView(store: store, source: .telegram)
            }
        }
    }

    private var downloadedEmptyCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(Palette.tertiary)
            Text("还没有下载的 Telegram 视频")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.text)
            Text("去「群组/频道」里挑一个，点视频即可加入下载队列。")
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    mode = .browse
                }
            } label: {
                Label("去浏览", systemImage: "paperplane.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.background)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Palette.amber))
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .glassPanel(cornerRadius: 24, fill: Palette.card.opacity(0.6))
    }

    // MARK: - Loading

    @MainActor
    private func loadChats(force: Bool = false) async {
        guard session.phase.isReady, !isLoadingChats else { return }
        if hasLoadedChats && !force { return }

        isLoadingChats = true
        if force {
            chatError = nil
        }

        do {
            let result = try await session.loadChatSummaries()
            // The user may have backgrounded the app while this request was in
            // flight. Never publish Telegram chats into a locked screen.
            guard access == .unlocked else {
                isLoadingChats = false
                return
            }
            chats = result
            hasLoadedChats = true
            chatError = nil
            AppLog.info("telegram hub chats=\(result.count)")
            autoOpenFirstChatIfRequested()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            chatError = message
            AppLog.error("telegram hub chat load failed: \(message)")
        }

        isLoadingChats = false
    }

    private func autoOpenFirstChatIfRequested() {
        guard selectedChat == nil else { return }
        let env = ProcessInfo.processInfo.environment
        if let raw = env["SHIYING_TG_CHAT_ID"], let id = Int64(raw),
           let chat = chats.first(where: { $0.id == id }) {
            AppLog.info("auto open telegram chat by id: \(chat.title)")
            selectedChat = chat
            return
        }
        guard env["SHIYING_TG_OPEN_FIRST"] == "1",
              let first = chats.first else { return }
        AppLog.info("auto open first telegram chat: \(first.title)")
        selectedChat = first
    }
}

// MARK: - Chat video list

struct TelegramChatVideosView: View {
    @ObservedObject var store: AppStore
    let chat: TelegramChatSummary
    var onBack: () -> Void
    var onPlay: (VideoItem) -> Void

    @State private var videos: [TelegramFileVideo] = []
    @State private var nextCursor: Int64?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var hasLoaded = false
    @State private var errorMessage: String?
    @State private var footerError: String?
    @State private var hasAutoDownloaded = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                pageHeader

                if isLoading && videos.isEmpty {
                    loadingCard(text: "正在读取最近的视频…")
                } else if let errorMessage, videos.isEmpty {
                    errorCard(errorMessage)
                } else if videos.isEmpty {
                    emptyCard
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(videos) { video in
                            videoRow(video)
                        }
                    }
                    footer
                }

                Color.clear.frame(height: 120)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
        }
        .refreshable {
            await reload()
        }
        .task {
            await loadInitialIfNeeded()
        }
    }

    private var pageHeader: some View {
        HStack(spacing: 11) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Palette.text)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.07)))
                    .overlay(Circle().strokeBorder(Palette.line, lineWidth: 1))
            }
            .buttonStyle(ScaleButtonStyle())
            .accessibilityLabel("返回群组列表")

            TelegramChatAvatar(data: chat.photoData, kind: chat.kind, size: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                Text(chatSubtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Palette.secondary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.07)))
                    .overlay(Circle().strokeBorder(Palette.line, lineWidth: 1))
            }
            .buttonStyle(ScaleButtonStyle())
            .accessibilityLabel("刷新视频")
        }
    }

    private var chatSubtitle: String {
        if chat.unreadCount > 0 {
            return "\(chat.kind.label) · \(chat.unreadCount) 条未读"
        }
        if videos.isEmpty {
            return chat.kind.label
        }
        return "\(chat.kind.label) · 已加载 \(videos.count) 个视频"
    }

    private func videoRow(_ video: TelegramFileVideo) -> some View {
        let item = store.telegramLibraryItem(for: video)

        return Button {
            primaryAction(for: video, item: item)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                TelegramVideoThumb(data: video.thumbnailData, duration: video.duration, width: 126)

                VStack(alignment: .leading, spacing: 5) {
                    Text(video.title)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(metaLine(for: video))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.tertiary)
                        .lineLimit(1)

                    if let item {
                        statusLine(for: item)
                    } else {
                        Text("点按加入下载")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.amber)
                    }

                    if let item, item.status == .downloading {
                        ProgressView(value: store.progress[item.id] ?? 0)
                            .tint(Palette.amber)
                            .scaleEffect(x: 1, y: 0.65, anchor: .center)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: actionIcon(for: item))
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(actionColor(for: item))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(actionColor(for: item).opacity(0.1)))
            }
            .padding(10)
            .glassPanel(cornerRadius: 20, fill: Palette.card.opacity(0.78))
        }
        .buttonStyle(ScaleButtonStyle())
    }

    private func metaLine(for video: TelegramFileVideo) -> String {
        var parts: [String] = []
        if let dateText = TelegramDateFormat.messageDate(video.date) {
            parts.append(dateText)
        }
        if let resolution = video.resolution, resolution > 0 {
            parts.append("\(resolution)p")
        }
        if video.fileSize > 0 {
            parts.append(AppPaths.formatBytes(video.fileSize))
        }
        if parts.isEmpty {
            parts.append("消息 #\(video.postID)")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func statusLine(for item: VideoItem) -> some View {
        switch item.status {
        case .ready:
            HStack(spacing: 5) {
                Image(systemName: item.isTrashed ? "trash" : "checkmark.circle.fill")
                Text(item.isTrashed ? "已在废纸篓" : "已下载 · 点按播放")
                if !item.isTrashed {
                    Text("·")
                    Text(AppPaths.formatBytes(item.fileSize))
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(item.isTrashed ? Palette.coral : Palette.mint)
            .lineLimit(1)

        case .queued:
            Text("排队中")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.amber)

        case .resolving:
            Text("准备下载…")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.amber)

        case .downloading:
            Text("下载中 \(Int((store.progress[item.id] ?? 0) * 100))%")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.amber)

        case .retrying:
            Text("正在重试 \(item.retryCount)/\(AppStore.maxAutoRetries)…")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.amber)

        case .failed:
            Text(item.errorMessage ?? "下载失败 · 点按重试")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.danger)
                .lineLimit(2)
        }
    }

    private func actionIcon(for item: VideoItem?) -> String {
        guard let item else { return "arrow.down.circle" }
        switch item.status {
        case .ready: return item.isTrashed ? "trash" : "play.fill"
        case .failed: return "arrow.clockwise"
        case .queued, .resolving, .retrying: return "clock.fill"
        case .downloading: return "arrow.down.circle.fill"
        }
    }

    private func actionColor(for item: VideoItem?) -> Color {
        guard let item else { return Palette.amber }
        switch item.status {
        case .ready: return item.isTrashed ? Palette.coral : Palette.mint
        case .failed: return Palette.danger
        case .queued, .resolving, .downloading, .retrying: return Palette.amber
        }
    }

    private func primaryAction(for video: TelegramFileVideo, item: VideoItem?) {
        guard let item else {
            store.addTelegramVideos([video], chatTitle: chat.title)
            return
        }
        switch item.status {
        case .ready:
            if !item.isTrashed {
                onPlay(item)
            }
        case .failed:
            store.retry(itemID: item.id)
        case .queued, .resolving, .downloading, .retrying:
            break
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let footerError {
                Text(footerError)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.danger)
                    .multilineTextAlignment(.center)
            }

            if isLoadingMore {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Palette.amber)
                    Text("正在向前查找更早的视频…")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondary)
                }
            } else if nextCursor != nil {
                Button {
                    Task { await loadMore() }
                } label: {
                    Label("继续向前查找", systemImage: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                        .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1))
                }
                .buttonStyle(ScaleButtonStyle())
            } else {
                Text("已经到最早的记录了")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var emptyCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(Palette.tertiary)
            Text(nextCursor == nil ? "这个会话里没有可下载的视频" : "最近的消息里没有视频")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.text)
                .multilineTextAlignment(.center)
            Text(nextCursor == nil
                 ? "只读取视频消息，图片、文字和文件不会显示。"
                 : "可以继续向前翻找更早的视频。")
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)

            if nextCursor != nil {
                Button {
                    Task { await loadMore() }
                } label: {
                    Label("继续向前查找", systemImage: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.background)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Palette.amber))
                }
                .buttonStyle(ScaleButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .glassPanel(cornerRadius: 24, fill: Palette.card.opacity(0.6))
    }

    private func loadingCard(text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(Palette.amber)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
            Spacer()
        }
        .padding(16)
        .glassPanel(cornerRadius: 18, fill: Palette.card.opacity(0.7))
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.danger)
                    .padding(.top, 1)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                    .lineSpacing(2)
            }
            Button {
                Task { await reload() }
            } label: {
                Label("重新读取", systemImage: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.background)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Palette.amber))
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassPanel(cornerRadius: 20, fill: Palette.card.opacity(0.7))
    }

    // MARK: - Loading

    @MainActor
    private func loadInitialIfNeeded() async {
        guard !hasLoaded, !isLoading else { return }
        isLoading = true
        errorMessage = nil

        do {
            let page = try await TelegramSession.shared.loadChatVideos(
                chatID: chat.id,
                chatTitle: chat.title
            )
            videos = page.videos
            nextCursor = page.nextFromMessageID
            hasLoaded = true
            autoDownloadFirstIfRequested()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            AppLog.error("telegram chat videos failed: \(errorMessage ?? "")")
        }

        isLoading = false
    }

    @MainActor
    private func loadMore() async {
        guard let cursor = nextCursor, !isLoadingMore else { return }
        isLoadingMore = true
        footerError = nil

        do {
            let page = try await TelegramSession.shared.loadChatVideos(
                chatID: chat.id,
                chatTitle: chat.title,
                fromMessageID: cursor
            )
            var known = Set(videos.map(\.itemKey))
            let fresh = page.videos.filter { known.insert($0.itemKey).inserted }
            videos.append(contentsOf: fresh)

            if page.nextFromMessageID == cursor {
                nextCursor = nil
            } else {
                nextCursor = page.nextFromMessageID
            }
            AppLog.info("telegram chat \(chat.id) more=\(fresh.count) total=\(videos.count) next=\(nextCursor ?? 0)")
        } catch {
            footerError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        isLoadingMore = false
    }

    @MainActor
    private func reload() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        footerError = nil
        nextCursor = nil

        do {
            let page = try await TelegramSession.shared.loadChatVideos(
                chatID: chat.id,
                chatTitle: chat.title
            )
            videos = page.videos
            nextCursor = page.nextFromMessageID
            hasLoaded = true
            autoDownloadFirstIfRequested()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        isLoading = false
    }

    private func autoDownloadFirstIfRequested() {
        guard ProcessInfo.processInfo.environment["SHIYING_TG_AUTO_DOWNLOAD"] == "1",
              !hasAutoDownloaded else { return }
        hasAutoDownloaded = true
        guard let first = videos.first,
              store.telegramLibraryItem(for: first) == nil else { return }
        AppLog.info("auto add telegram video file=\(first.fileID) chat=\(chat.id)")
        store.addTelegramVideos([first], chatTitle: chat.title)
    }
}

// MARK: - Shared pieces

private struct TelegramChatAvatar: View {
    let data: Data?
    let kind: TelegramChatSummary.Kind
    var size: CGFloat = 46

    var body: some View {
        ZStack {
            if let data, let image = TelegramImageCache.image(for: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: kind == .channel
                        ? [Color(hex: 0x59A9E8).opacity(0.9), Color(hex: 0x3A6FD3).opacity(0.85)]
                        : [Palette.mint.opacity(0.8), Color(hex: 0x2C826D)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: kind.icon)
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.1), lineWidth: 1))
    }
}

private struct TelegramVideoThumb: View {
    let data: Data?
    let duration: Double
    var width: CGFloat = 126

    private var height: CGFloat { width * 9 / 16 }

    var body: some View {
        ZStack {
            if let data, let image = TelegramImageCache.image(for: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [Color(hex: 0x22293A), Color(hex: 0x151923)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Palette.secondary.opacity(0.5))
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.45)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    if let text = TelegramDateFormat.duration(duration) {
                        Text(text)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.55)))
                    }
                }
                .padding(6)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private enum TelegramImageCache {
    private static let cache = NSCache<NSData, UIImage>()

    static func image(for data: Data) -> UIImage? {
        let key = data as NSData
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

private enum TelegramDateFormat {
    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    static let year: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter
    }()

    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func listDate(_ date: Date?) -> String? {
        guard let date else { return nil }
        if Calendar.current.isDateInToday(date) {
            return time.string(from: date)
        }
        if Calendar.current.isDateInYesterday(date) {
            return "昨天"
        }
        if Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) {
            return day.string(from: date)
        }
        return year.string(from: date)
    }

    static func messageDate(_ date: Date?) -> String? {
        guard let date else { return nil }
        if Calendar.current.isDateInToday(date) {
            return "今天"
        }
        if Calendar.current.isDateInYesterday(date) {
            return "昨天"
        }
        if Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) {
            return day.string(from: date)
        }
        return year.string(from: date)
    }

    static func duration(_ value: Double) -> String? {
        guard value > 0, value.isFinite else { return nil }
        let total = Int(value.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

import SwiftUI

/// Deterministic decoy shown when the Telegram access password is wrong.
/// Everything here is hard-coded and never reads `TelegramSession` or the
/// user's library, so the same two chats and messages appear every time.
/// Pulling to refresh returns to the password screen so the real user can
/// try again without leaving the Telegram tab.
struct TelegramDecoyView: View {
    var title: String = "Telegram"
    var onRefresh: () -> Void = {}

    @State private var selectedChat: TelegramDecoyChat?
    @State private var readChatIDs: Set<String> = []

    var body: some View {
        Group {
            if let chat = selectedChat {
                TelegramDecoyChatView(chat: chat, onRefresh: onRefresh) {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        selectedChat = nil
                    }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                chatList
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: selectedChat?.id)
    }

    private var chatList: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                header

                SectionLabel(
                    title: "群组与频道",
                    count: TelegramDecoyChat.samples.count
                )

                LazyVStack(spacing: 8) {
                    ForEach(TelegramDecoyChat.samples) { chat in
                        Button {
                            _ = readChatIDs.insert(chat.id)
                            withAnimation(.easeInOut(duration: 0.22)) {
                                selectedChat = chat
                            }
                        } label: {
                            row(chat)
                        }
                        .buttonStyle(ScaleButtonStyle())
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 9, weight: .bold))
                    Text("当前账号无法下线 · 消息同步已暂停")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(Palette.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)

                Color.clear.frame(height: 120)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
        }
        .refreshable {
            await MainActor.run {
                onRefresh()
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
                    Text(title)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }

                Text("\(TelegramDecoyChat.samples.count) 个群组 · 昨天最后同步")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.secondary)

                HStack(spacing: 5) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 9, weight: .bold))
                    Text("无法下线")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(Palette.amber)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Palette.amber.opacity(0.12)))
            }

            Spacer(minLength: 0)
        }
    }

    private func row(_ chat: TelegramDecoyChat) -> some View {
        HStack(spacing: 12) {
            DecoyAvatar(chat: chat, size: 46)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(chat.title)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)

                    Text("群组")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(hex: MediaSource.telegram.accentHex))
                }

                Text(chat.lastMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 6) {
                Text(chat.timeText)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Palette.tertiary)

                if chat.unreadCount > 0 && !readChatIDs.contains(chat.id) {
                    Text("\(chat.unreadCount)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(Palette.background)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Palette.amber))
                }
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Palette.tertiary)
        }
        .padding(10)
        .glassPanel(cornerRadius: 20, fill: Palette.card.opacity(0.78))
    }
}

private struct TelegramDecoyChatView: View {
    let chat: TelegramDecoyChat
    var onRefresh: () -> Void
    var onBack: () -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                header
                dateChip
                messageList
                Color.clear.frame(height: 40)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
        }
        .refreshable {
            await MainActor.run {
                onRefresh()
            }
        }
    }

    private var header: some View {
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

            DecoyAvatar(chat: chat, size: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                Text("群组 · \(chat.memberCount) 位成员")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.tertiary)
            }

            Spacer(minLength: 0)
        }
    }

    private var dateChip: some View {
        Text("昨天 · 最后同步")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Palette.tertiary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.06)))
            .frame(maxWidth: .infinity)
    }

    private var messageList: some View {
        LazyVStack(spacing: 10) {
            ForEach(Array(chat.messages.enumerated()), id: \.offset) { entry in
                messageBubble(entry.element)
            }
        }
        .padding(.top, 4)
    }

    private func messageBubble(_ message: TelegramDecoyMessage) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.isMine {
                Spacer(minLength: 54)
            }

            VStack(alignment: message.isMine ? .trailing : .leading, spacing: 4) {
                if !message.isMine {
                    Text(message.sender)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.secondary)
                        .padding(.leading, 3)
                }

                Text(message.text)
                    .font(.system(size: 13))
                    .foregroundStyle(message.isMine ? Palette.background : Palette.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(
                                message.isMine
                                    ? Palette.amber
                                    : Palette.cardLift
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 15, style: .continuous)
                                    .strokeBorder(
                                        message.isMine ? Color.clear : Palette.line,
                                        lineWidth: 1
                                    )
                            )
                    )

                Text(message.timeText)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Palette.tertiary)
                    .padding(.horizontal, 3)
            }

            if !message.isMine {
                Spacer(minLength: 54)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct DecoyAvatar: View {
    let chat: TelegramDecoyChat
    var size: CGFloat = 46

    var body: some View {
        ZStack {
            LinearGradient(
                colors: chat.avatarColors.map { Color(hex: $0) },
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(chat.initial)
                .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.94))
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.1), lineWidth: 1))
    }
}

private struct TelegramDecoyChat: Identifiable {
    let id: String
    let title: String
    let initial: String
    let avatarColors: [UInt]
    let lastMessage: String
    let timeText: String
    let unreadCount: Int
    let memberCount: Int
    let messages: [TelegramDecoyMessage]

    static let samples: [TelegramDecoyChat] = [
        TelegramDecoyChat(
            id: "decoy-golang",
            title: "Golang 技术交流",
            initial: "Go",
            avatarColors: [0x00ADD8, 0x5DC9E2],
            lastMessage: "mira：use errgroup.WithContext, it cancels for you",
            timeText: "昨天",
            unreadCount: 3,
            memberCount: 4821,
            messages: [
                TelegramDecoyMessage(
                    sender: "dennis",
                    text: "anyone benchmarked slog against zap lately?",
                    timeText: "21:02",
                    isMine: false
                ),
                TelegramDecoyMessage(
                    sender: "mira",
                    text: "slog is fine unless you're logging 100k lines a second",
                    timeText: "21:04",
                    isMine: false
                ),
                TelegramDecoyMessage(
                    sender: "tomas",
                    text: "my goroutine count keeps climbing under load, pprof points at http.Client.Do",
                    timeText: "21:07",
                    isMine: false
                ),
                TelegramDecoyMessage(
                    sender: "我",
                    text: "is the client shared or created per request?",
                    timeText: "21:09",
                    isMine: true
                ),
                TelegramDecoyMessage(
                    sender: "tomas",
                    text: "created per request... that would do it, huh",
                    timeText: "21:10",
                    isMine: false
                ),
                TelegramDecoyMessage(
                    sender: "mira",
                    text: "reuse one client with a timeout, the transport pools connections",
                    timeText: "21:11",
                    isMine: false
                ),
                TelegramDecoyMessage(
                    sender: "kevin",
                    text: "and close the response body, otherwise the pool leaks",
                    timeText: "21:13",
                    isMine: false
                ),
                TelegramDecoyMessage(
                    sender: "mira",
                    text: "use errgroup.WithContext, it cancels for you",
                    timeText: "21:16",
                    isMine: false
                )
            ]
        ),
        TelegramDecoyChat(
            id: "decoy-backend",
            title: "Backend & Infra",
            initial: "BE",
            avatarColors: [0x6C5CE7, 0x4DABF7],
            lastMessage: "anna：vacuum full during peak hours? brave",
            timeText: "昨天",
            unreadCount: 1,
            memberCount: 2140,
            messages: [
                TelegramDecoyMessage(
                    sender: "anna",
                    text: "our pg table is 80% bloat after that bad backfill",
                    timeText: "20:31",
                    isMine: false
                ),
                TelegramDecoyMessage(
                    sender: "raj",
                    text: "autovacuum not keeping up?",
                    timeText: "20:33",
                    isMine: false
                ),
                TelegramDecoyMessage(
                    sender: "anna",
                    text: "long transactions are blocking it, apparently",
                    timeText: "20:34",
                    isMine: false
                ),
                TelegramDecoyMessage(
                    sender: "我",
                    text: "can we run VACUUM FULL in a maintenance window?",
                    timeText: "20:36",
                    isMine: true
                ),
                TelegramDecoyMessage(
                    sender: "raj",
                    text: "sure, just mind the lock, it rewrites the whole table",
                    timeText: "20:37",
                    isMine: false
                ),
                TelegramDecoyMessage(
                    sender: "anna",
                    text: "vacuum full during peak hours? brave",
                    timeText: "20:39",
                    isMine: false
                )
            ]
        ),
        TelegramDecoyChat(
            id: "decoy-swiftui",
            title: "SwiftUI 开发者",
            initial: "Sw",
            avatarColors: [0xFF8A3D, 0xFF5E68],
            lastMessage: "leo：scrollTargetBehavior(.viewAligned) fixed it",
            timeText: "昨天",
            unreadCount: 0,
            memberCount: 3380,
            messages: [
                TelegramDecoyMessage(
                    sender: "leo",
                    text: "my list jumps when the keyboard shows up, any ideas?",
                    timeText: "19:12",
                    isMine: false
                ),
                TelegramDecoyMessage(
                    sender: "sana",
                    text: "are you inside a ScrollView with ignoresSafeArea(.keyboard)?",
                    timeText: "19:14",
                    isMine: false
                ),
                TelegramDecoyMessage(
                    sender: "leo",
                    text: "yes, and it only happens on iOS 26",
                    timeText: "19:15",
                    isMine: false
                ),
                TelegramDecoyMessage(
                    sender: "我",
                    text: "try scrollDismissesKeyboard(.interactively) first",
                    timeText: "19:17",
                    isMine: true
                ),
                TelegramDecoyMessage(
                    sender: "sana",
                    text: "also check scrollTargetBehavior, snapping can fight the inset",
                    timeText: "19:18",
                    isMine: false
                ),
                TelegramDecoyMessage(
                    sender: "leo",
                    text: "scrollTargetBehavior(.viewAligned) fixed it, thanks",
                    timeText: "19:21",
                    isMine: false
                )
            ]
        ),
        TelegramDecoyChat(
            id: "decoy-indie",
            title: "Indie Games Lounge",
            initial: "IG",
            avatarColors: [0x8E44AD, 0xE84393],
            lastMessage: "nora：我先去练格挡了，明天继续",
            timeText: "昨天",
            unreadCount: 5,
            memberCount: 912,
            messages: [
                TelegramDecoyMessage(
                    sender: "nora",
                    text: "finally picked up that new metroidvania everyone keeps posting",
                    timeText: "22:01",
                    isMine: false
                ),
                TelegramDecoyMessage(
                    sender: "ben",
                    text: "the parry window is brutal at first, don't feel bad",
                    timeText: "22:03",
                    isMine: false
                ),
                TelegramDecoyMessage(
                    sender: "nora",
                    text: "3 hours in, still can't parry",
                    timeText: "22:04",
                    isMine: false
                ),
                TelegramDecoyMessage(
                    sender: "我",
                    text: "turn camera shake off, the tells are way easier to read",
                    timeText: "22:06",
                    isMine: true
                ),
                TelegramDecoyMessage(
                    sender: "ben",
                    text: "there's an accessibility slider for the window too, no shame",
                    timeText: "22:08",
                    isMine: false
                ),
                TelegramDecoyMessage(
                    sender: "nora",
                    text: "我先去练格挡了，明天继续",
                    timeText: "22:09",
                    isMine: false
                )
            ]
        ),
        TelegramDecoyChat(
            id: "decoy-steam",
            title: "Steam 剁手俱乐部",
            initial: "ST",
            avatarColors: [0x1F8A70, 0x3DDC97],
            lastMessage: "dave：这波折扣太狠了",
            timeText: "昨天",
            unreadCount: 2,
            memberCount: 486,
            messages: [
                TelegramDecoyMessage(
                    sender: "ivy",
                    text: "sale haul thread, post yours",
                    timeText: "18:20",
                    isMine: false
                ),
                TelegramDecoyMessage(
                    sender: "dave",
                    text: "only bought two this time, very proud of myself",
                    timeText: "18:24",
                    isMine: false
                ),
                TelegramDecoyMessage(
                    sender: "我",
                    text: "same, except one of them is a 60-hour RPG",
                    timeText: "18:26",
                    isMine: true
                ),
                TelegramDecoyMessage(
                    sender: "ivy",
                    text: "see you in 2027 then",
                    timeText: "18:27",
                    isMine: false
                ),
                TelegramDecoyMessage(
                    sender: "dave",
                    text: "这波折扣太狠了，愿望单清空一半",
                    timeText: "18:29",
                    isMine: false
                )
            ]
        )
    ]
}

private struct TelegramDecoyMessage {
    let sender: String
    let text: String
    let timeText: String
    let isMine: Bool
}

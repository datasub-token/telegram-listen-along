import Foundation
import UIKit
import Display
import ComponentFlow
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramPresentationData
import AvatarNode

// Listen Along (concept): see what the people in a chat are listening to, and play it yourself.
//
// The server has no "now playing" status yet. In this prototype a track that a member shared in the chat during
// the last 24 hours stands in for it. A production version would receive the status the way typing activities
// arrive, and would start the track at the listener's own position.

/// A member of the chat and the track they are listening to.
struct ChatListenAlongEntry: Equatable {
    let peer: EnginePeer
    let message: EngineRawMessage
    let title: String
    let performer: String

    static func ==(lhs: ChatListenAlongEntry, rhs: ChatListenAlongEntry) -> Bool {
        return lhs.peer.id == rhs.peer.id && lhs.message.id == rhs.message.id && lhs.title == rhs.title && lhs.performer == rhs.performer
    }
}

/// How long a shared track counts as "listening now" in this prototype.
let chatListenAlongWindow: Int32 = 24 * 60 * 60

/// The track a music message carries: its title and performer, or the file name.
func chatListenAlongTrack(_ message: EngineRawMessage) -> (title: String, performer: String)? {
    for media in message.media {
        guard let file = media as? TelegramMediaFile, file.isMusic else {
            continue
        }
        var title = ""
        var performer = ""
        for attribute in file.attributes {
            if case let .Audio(_, _, audioTitle, audioPerformer, _) = attribute {
                title = audioTitle ?? ""
                performer = audioPerformer ?? ""
            }
        }
        if title.isEmpty {
            title = file.fileName ?? "Unknown Track"
        }
        return (title, performer)
    }
    return nil
}

/// Who in the chat is listening to what: the latest track of each member (newest first), not counting you. Read from
/// the chat's music, the way the chat reads its pinned messages.
func chatListenAlongEntries(context: AccountContext, peerId: EnginePeer.Id) -> Signal<[ChatListenAlongEntry], NoError> {
    let accountPeerId = context.account.peerId
    return chatHistoryViewForLocation(ChatHistoryLocationInput(content: .Initial(count: 50), id: 0), ignoreMessagesInTimestampRange: nil, ignoreMessageIds: Set(), context: context, chatLocation: .peer(id: peerId), chatLocationContextHolder: Atomic<ChatLocationContextHolder?>(value: nil), scheduled: false, fixedCombinedReadStates: nil, tag: .tag(EngineMessage.Tags.music), appendMessagesFromTheSameGroup: false, additionalData: [], orderStatistics: [])
    |> map { update -> [ChatListenAlongEntry] in
        guard case let .HistoryView(view, _, _, _, _, _, _) = update else {
            return []
        }
        let now = Int32(CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970)
        var seen = Set<EnginePeer.Id>()
        var result: [ChatListenAlongEntry] = []
        for entry in view.entries.reversed() {
            let message = entry.message
            guard now - message.timestamp < chatListenAlongWindow, let author = message.author, author.id != accountPeerId, !seen.contains(author.id) else {
                continue
            }
            guard let track = chatListenAlongTrack(message) else {
                continue
            }
            seen.insert(author.id)
            result.append(ChatListenAlongEntry(peer: EnginePeer(author), message: message, title: track.title, performer: track.performer))
        }
        return result
    }
    |> distinctUntilChanged
}

/// The panel under the chat's navigation bar, inside the glass of the header panels.
///
/// - In a private chat: "<Name> is listening", the track, and a "Listen" button that plays it in your player
///   (the media panel then takes its place). The layout is the pinned-message panel with an inline button.
/// - In a group: "Listening now" with the listeners' avatars in the middle (the voice-chat panel's layout); a tap
///   opens a list with every listener's track and a button to play it.
final class ChatListenAlongPanelComponent: Component {
    let context: AccountContext
    let theme: PresentationTheme
    let isGroup: Bool
    let entries: [ChatListenAlongEntry]
    let expanded: Bool
    let listen: (ChatListenAlongEntry) -> Void
    let toggleExpanded: () -> Void

    init(context: AccountContext, theme: PresentationTheme, isGroup: Bool, entries: [ChatListenAlongEntry], expanded: Bool, listen: @escaping (ChatListenAlongEntry) -> Void, toggleExpanded: @escaping () -> Void) {
        self.context = context
        self.theme = theme
        self.isGroup = isGroup
        self.entries = entries
        self.expanded = expanded
        self.listen = listen
        self.toggleExpanded = toggleExpanded
    }

    static func ==(lhs: ChatListenAlongPanelComponent, rhs: ChatListenAlongPanelComponent) -> Bool {
        if lhs.context !== rhs.context {
            return false
        }
        if lhs.theme !== rhs.theme {
            return false
        }
        if lhs.isGroup != rhs.isGroup || lhs.entries != rhs.entries || lhs.expanded != rhs.expanded {
            return false
        }
        return true
    }

    static let headerHeight: CGFloat = 50.0
    static let rowHeight: CGFloat = 56.0

    final class Row {
        let view = UIView()
        let separator = UIView()
        let avatarNode = AvatarNode(font: avatarPlaceholderFont(size: 15.0))
        let nameLabel = UILabel()
        let trackLabel = UILabel()
        let playButton = UIButton(type: .custom)
        var entry: ChatListenAlongEntry?

        init() {
            self.view.addSubview(self.separator)
            self.view.addSubview(self.avatarNode.view)
            self.view.addSubview(self.nameLabel)
            self.view.addSubview(self.trackLabel)
            self.view.addSubview(self.playButton)
        }
    }

    final class View: UIView {
        private let titleLabel = UILabel()
        private let textLabel = UILabel()
        private let coverView = UIView()
        private let coverIcon = UIImageView()
        private let listenButton = UIButton(type: .custom)
        private let expandIcon = UIImageView()
        private let headerButton = UIButton(type: .custom)
        private var stackAvatars: [AvatarNode] = []
        private var rows: [Row] = []

        private var component: ChatListenAlongPanelComponent?

        override init(frame: CGRect) {
            super.init(frame: frame)
            self.clipsToBounds = true

            self.addSubview(self.headerButton)
            self.coverView.layer.cornerRadius = 8.0
            self.coverView.clipsToBounds = true
            self.coverView.addSubview(self.coverIcon)
            self.addSubview(self.coverView)
            self.addSubview(self.titleLabel)
            self.addSubview(self.textLabel)
            self.addSubview(self.expandIcon)
            self.addSubview(self.listenButton)

            self.headerButton.addTarget(self, action: #selector(self.headerPressed), for: .touchUpInside)
            self.listenButton.addTarget(self, action: #selector(self.listenPressed), for: .touchUpInside)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        @objc private func headerPressed() {
            guard let component = self.component, component.isGroup else {
                return
            }
            component.toggleExpanded()
        }

        @objc private func listenPressed() {
            guard let component = self.component, let entry = component.entries.first else {
                return
            }
            component.listen(entry)
        }

        @objc private func rowPlayPressed(_ sender: UIButton) {
            guard let component = self.component, let row = self.rows.first(where: { $0.playButton === sender }), let entry = row.entry else {
                return
            }
            component.listen(entry)
        }

        func update(component: ChatListenAlongPanelComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
            self.component = component
            let theme = component.theme
            let primary = theme.chat.inputPanel.primaryTextColor
            let secondary = theme.chat.inputPanel.secondaryTextColor
            let accent = theme.list.itemCheckColors.fillColor
            let width = availableSize.width
            let header = ChatListenAlongPanelComponent.headerHeight

            self.headerButton.frame = CGRect(x: 0.0, y: 0.0, width: width, height: header)

            if !component.isGroup, let entry = component.entries.first {
                // pinned-message panel geometry: a 36-point thumbnail, two 15-point lines, a 28-point inline button
                self.coverView.isHidden = false
                self.coverView.frame = CGRect(x: 16.0, y: 7.0, width: 36.0, height: 36.0)
                self.coverView.backgroundColor = accent.withAlphaComponent(0.15)
                self.coverIcon.image = UIImage(systemName: "music.note")?.withRenderingMode(.alwaysTemplate)
                self.coverIcon.tintColor = accent
                self.coverIcon.contentMode = .center
                self.coverIcon.frame = self.coverView.bounds

                let buttonTitle = NSAttributedString(string: "Listen", font: Font.with(size: 15.0, design: .round, weight: .semibold, traits: [.monospacedNumbers]), textColor: theme.list.itemCheckColors.foregroundColor)
                self.listenButton.setAttributedTitle(buttonTitle, for: .normal)
                self.listenButton.backgroundColor = accent
                self.listenButton.layer.cornerRadius = 14.0
                let buttonWidth = max(40.0, ceil(buttonTitle.size().width) + 20.0)
                let buttonFrame = CGRect(x: width - 11.0 - buttonWidth, y: 11.0, width: buttonWidth, height: 28.0)
                self.listenButton.isHidden = false
                transition.setFrame(view: self.listenButton, frame: buttonFrame)

                let textWidth = max(0.0, buttonFrame.minX - 8.0 - 62.0)
                let firstName = entry.peer.compactDisplayTitle
                self.titleLabel.attributedText = NSAttributedString(string: "\(firstName) is listening", font: Font.medium(15.0), textColor: primary)
                self.titleLabel.frame = CGRect(x: 62.0, y: 6.0, width: textWidth, height: 20.0)
                let trackText = entry.performer.isEmpty ? entry.title : "\(entry.title) — \(entry.performer)"
                self.textLabel.attributedText = NSAttributedString(string: trackText, font: Font.regular(15.0), textColor: primary)
                self.textLabel.lineBreakMode = .byTruncatingTail
                self.textLabel.frame = CGRect(x: 62.0, y: 23.0, width: textWidth, height: 20.0)
                self.expandIcon.isHidden = true
                for avatar in self.stackAvatars {
                    avatar.view.isHidden = true
                }
                for row in self.rows {
                    row.view.isHidden = true
                }
                return CGSize(width: width, height: header)
            }

            // MARK: Group: who is listening, and the list it opens into
            self.coverView.isHidden = true
            self.listenButton.isHidden = true
            self.titleLabel.attributedText = NSAttributedString(string: "Listening now", font: Font.semibold(15.0), textColor: primary)
            self.titleLabel.frame = CGRect(x: 16.0, y: 9.0, width: width * 0.4, height: 20.0)
            let names = component.entries.map { $0.peer.compactDisplayTitle }
            let namesText: String
            switch names.count {
            case 0:
                namesText = ""
            case 1:
                namesText = names[0]
            case 2:
                namesText = "\(names[0]) and \(names[1])"
            default:
                namesText = names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
            }
            self.textLabel.attributedText = NSAttributedString(string: namesText, font: Font.regular(13.0), textColor: secondary)
            self.textLabel.lineBreakMode = .byTruncatingTail
            self.textLabel.frame = CGRect(x: 16.0, y: 29.0, width: width * 0.4, height: 16.0)

            // stacked avatars in the middle: 32 points, each next one 22 to the right, the first on top
            let shown = Array(component.entries.prefix(3))
            while self.stackAvatars.count < shown.count {
                let avatar = AvatarNode(font: avatarPlaceholderFont(size: 13.0))
                self.stackAvatars.append(avatar)
                self.insertSubview(avatar.view, belowSubview: self.headerButton)
            }
            let groupWidth = 32.0 + 22.0 * CGFloat(max(0, shown.count - 1))
            let groupX = floor((width - groupWidth) / 2.0)
            for (i, avatar) in self.stackAvatars.enumerated() {
                if i < shown.count {
                    avatar.view.isHidden = false
                    avatar.setPeer(context: component.context, theme: theme, peer: shown[i].peer)
                    avatar.view.frame = CGRect(x: groupX + 22.0 * CGFloat(i), y: 9.0, width: 32.0, height: 32.0)
                    avatar.view.layer.zPosition = CGFloat(100 - i)
                    avatar.view.layer.borderWidth = 1.5
                    avatar.view.layer.borderColor = theme.chat.inputPanel.panelBackgroundColor.cgColor
                    avatar.view.layer.cornerRadius = 16.0
                    transition.setAlpha(view: avatar.view, alpha: component.expanded ? 0.0 : 1.0)
                } else {
                    avatar.view.isHidden = true
                }
            }

            self.expandIcon.isHidden = false
            self.expandIcon.image = UIImage(bundleImageName: "Navigation/TitleExpand")?.withRenderingMode(.alwaysTemplate)
            self.expandIcon.tintColor = primary
            self.expandIcon.bounds = CGRect(x: 0.0, y: 0.0, width: 24.0, height: 24.0)
            self.expandIcon.center = CGPoint(x: width - 18.0 - 12.0, y: header / 2.0)
            transition.setTransform(view: self.expandIcon, transform: component.expanded ? CATransform3DMakeRotation(.pi, 0.0, 0.0, 1.0) : CATransform3DIdentity)

            // the list: one 56-point row per listener
            while self.rows.count < component.entries.count {
                let row = Row()
                row.playButton.addTarget(self, action: #selector(self.rowPlayPressed(_:)), for: .touchUpInside)
                self.rows.append(row)
                self.addSubview(row.view)
            }
            for (i, row) in self.rows.enumerated() {
                guard i < component.entries.count else {
                    row.view.isHidden = true
                    continue
                }
                let entry = component.entries[i]
                row.entry = entry
                row.view.isHidden = false
                row.view.frame = CGRect(x: 0.0, y: header + ChatListenAlongPanelComponent.rowHeight * CGFloat(i), width: width, height: ChatListenAlongPanelComponent.rowHeight)
                row.separator.backgroundColor = theme.list.itemPlainSeparatorColor
                row.separator.frame = CGRect(x: i == 0 ? 0.0 : 62.0, y: 0.0, width: width - (i == 0 ? 0.0 : 62.0), height: UIScreenPixel)
                row.avatarNode.setPeer(context: component.context, theme: theme, peer: entry.peer)
                row.avatarNode.view.frame = CGRect(x: 16.0, y: 10.0, width: 36.0, height: 36.0)
                row.nameLabel.attributedText = NSAttributedString(string: entry.peer.compactDisplayTitle, font: Font.medium(15.0), textColor: primary)
                row.nameLabel.frame = CGRect(x: 62.0, y: 9.0, width: width - 62.0 - 60.0, height: 20.0)
                let track = entry.performer.isEmpty ? entry.title : "\(entry.title) · \(entry.performer)"
                row.trackLabel.attributedText = NSAttributedString(string: track, font: Font.regular(13.0), textColor: secondary)
                row.trackLabel.lineBreakMode = .byTruncatingTail
                row.trackLabel.frame = CGRect(x: 62.0, y: 29.0, width: width - 62.0 - 60.0, height: 18.0)
                row.playButton.setImage(UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12.0, weight: .bold))?.withRenderingMode(.alwaysTemplate), for: .normal)
                row.playButton.tintColor = theme.list.itemCheckColors.foregroundColor
                row.playButton.backgroundColor = accent
                row.playButton.layer.cornerRadius = 15.0
                row.playButton.frame = CGRect(x: width - 16.0 - 30.0, y: 13.0, width: 30.0, height: 30.0)
                transition.setAlpha(view: row.view, alpha: component.expanded ? 1.0 : 0.0)
            }

            let height = header + (component.expanded ? ChatListenAlongPanelComponent.rowHeight * CGFloat(component.entries.count) : 0.0)
            return CGSize(width: width, height: height)
        }
    }

    func makeView() -> View {
        return View(frame: CGRect())
    }

    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, environment: environment, transition: transition)
    }
}

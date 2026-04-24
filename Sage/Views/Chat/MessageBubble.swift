import SwiftUI

struct MessageBubble: View {
    let message: Message
    @State private var showTimestamp = false

    var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser {
                Spacer(minLength: 60)
            } else {
                SageAvatar()
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .font(Theme.bodyFont)
                    .foregroundStyle(isUser ? .white : .primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(isUser ? Color.blue : Theme.aiBubble)
                    .clipShape(BubbleShape(isUser: isUser))

                if showTimestamp {
                    Text(message.createdAt.formatted(.dateTime.hour().minute()))
                        .font(Theme.captionFont)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                }
            }

            if !isUser {
                Spacer(minLength: 60)
            }
        }
        .padding(.vertical, 2)
        .onTapGesture {
            withAnimation(Theme.easeAnimation) {
                showTimestamp.toggle()
            }
        }
        .contextMenu {
            Button {
                UIPasteboard.general.string = message.content
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }
}

struct SageAvatar: View {
    var body: some View {
        Circle()
            .fill(Color.accentColor.gradient)
            .frame(width: 28, height: 28)
            .overlay {
                Image(systemName: "sparkle")
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
            }
    }
}

struct BubbleShape: Shape {
    let isUser: Bool

    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 18
        let _: CGFloat = 4 // tail radius reserved for future use
        var path = Path()

        if isUser {
            // Rounded rect with small notch bottom-right
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: r, height: r))
        } else {
            // Rounded rect with small notch bottom-left
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: r, height: r))
        }

        return path
    }
}

import UIKit

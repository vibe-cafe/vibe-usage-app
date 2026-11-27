import SwiftUI

/// The body of 近期消耗 without a linked account (136j–136l). The card keeps
/// its title and its size; the body walks through the device sign-in, which
/// is the panel's shared one (`AppState.deviceLink`, also behind the classic
/// panel's button), so closing the panel or switching the style keeps it.
struct ModernSignInBody: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let link = appState.deviceLink
        VStack(alignment: .leading, spacing: 0) {
            switch link.phase {
            case .idle:
                // 136j
                title("登录后可以看用量")
                actions {
                    Button("登录并链接数据") { link.start() }
                        .buttonStyle(ModernPrimaryButtonStyle())
                }
            case .requestingCode, .awaitingApproval:
                // 136k. Until the server answers there is no code yet: a
                // loading block holds its place, so nothing moves when it
                // arrives.
                title("等待浏览器确认…") { ModernSpinner(size: 12) }
                caption("浏览器里显示的验证码和下面一样，再点确认。")
                actions {
                    Text(link.userCode ?? "XXXX-XXXX")
                        .font(ModernTheme.mono(22, .medium))
                        .tracking(0.44)
                        .foregroundStyle(ModernTheme.text)
                        .opacity(link.userCode == nil ? 0 : 1)
                        .background {
                            if link.userCode == nil {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(ModernTheme.placeholder)
                                    .frame(height: 20)
                            }
                        }
                        .accessibilityLabel(link.userCode.map { "验证码 \($0)" } ?? "")
                    Button {
                        link.cancel()
                    } label: {
                        Text("取消，重新开始").modernHitArea()
                    }
                    .buttonStyle(ModernTextButtonStyle(color: ModernTheme.text))
                    .font(ModernTheme.text(13))
                }
            case .failed(let reason):
                // 136l
                title("登录没成功") {
                    // The design's 8.5 pt ring with a 1.1 pt stroke.
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(ModernTheme.red)
                }
                caption(reason)
                actions {
                    Button("重新登录") { link.start() }
                        .buttonStyle(ModernPrimaryButtonStyle())
                }
            }
        }
        .padding(.top, 3)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: ModernTheme.cardBodyHeight, alignment: .top)
    }

    /// The step's one line: 13 pt, primary.
    private func title(_ text: String) -> some View {
        Text(text)
            .font(ModernTheme.text(13, .medium))
            .foregroundStyle(ModernTheme.text)
            .frame(height: 18)
    }

    /// The same with a 12 pt icon before it.
    private func title<Icon: View>(_ text: String, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 6) {
            icon().frame(width: 12, height: 12)
            title(text)
        }
    }

    /// The line under it: 11 pt on a 16 pt line, secondary.
    private func caption(_ text: String) -> some View {
        Text(text)
            .font(ModernTheme.text(11))
            .foregroundStyle(ModernTheme.secondaryText)
            .lineLimit(2)
            .frame(minHeight: 16)
            .padding(.top, 2)
            .help(text)
    }

    private func actions<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 14) {
            content()
        }
        .frame(height: 26)
        .padding(.top, 12)
    }
}
